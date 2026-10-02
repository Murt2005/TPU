# MNIST demo

A digit classifier whose whole forward pass runs on the TPU: the end-to-end
proof that the array computes something real.

## 1. The model

**144 → 64 → 10**, two layers, ReLU on both.

- Input: an MNIST digit downsampled 28×28 → **12×12** = 144 features.
- Hidden: 64 units.
- Output: 10 class scores.
- int8 weights and activations, int16 bias.

`software/mnist/train_mnist.py` trains and quantizes it into
`software/mnist/model/mnist-2x2-int8.npz` (~5 KB, committed, so nothing needs
training). Retraining downloads MNIST (~11 MB, cached in
`software/mnist/data/`, gitignored).

## 2. Why it's this small

The model was designed for the first core, whose accumulator was a 16-bit
register that **wrapped silently** on overflow. So a layer's K had to stay
small enough that realistic int8 weights and activations never pushed the
true sum past ±32,767. K = 144 and K = 64 were chosen against that ceiling
and then **verified: zero overflow across the whole 10,000-image test set,
with a 5% calibration margin**.

The current core accumulates in 32 bits, so that limit is gone. A bigger
model is in [`backlog.md`](backlog.md).

## 3. Quantization details

These are why `train_mnist.py` doesn't look like an ordinary quantization
script.

**ReLU on every layer, including the output.** The first core's activation
unit had no bypass when the model was trained, so it learned with ReLU on
its logits; argmax over ReLU'd scores is what it was optimised for. The
current core has `func = identity`, but the committed model keeps ReLU.

**The requantization between layers.** `train_mnist.py` calibrates a hidden
scale (`hidden_scale = 20900 / 127`) that maps layer 1's sums to int8.
- **The host reference** divides and rounds half to even:
  `np.round(v / hidden_scale)`.
- **The core** does it in hardware: `M = 1 / hidden_scale` becomes
  `M0 = 13,049,303`, `shift = 31` ([`isa.md`](isa.md) §5), rounding half
  up.

The two differ only on the tie at v = 10,450, which no image in the test set
hits.

**Bias** is stored as int16 and loaded into the core as int32 entries, one
per output block.

## 4. Accuracy

| Where | Result |
|---|---|
| Quantized model, host reference, full 10k test set | 97.50% |
| **DE1-SoC, full 10k test set, end to end on the board** | **97.50%**, 10,000/10,000 equal to the reference model and to the host reference |
| (history) pico2-ice, 20 sampled images | 95.00% (19/20), identical to the host on the same images |

## 5. How it runs on the DE1-SoC

- **Compiled once.** `tpu.isa_compile.compile_mlp` turns the two layers into
  a **load program** (weights, biases and requantization words into WMEM and
  the parameter tables) and an 11-instruction **infer program**.
- **Layer 1 never leaves the core.** Its sums are requantized in hardware and
  written into the UB, exactly where layer 2's `MATMUL` reads them.
- **The host is the board's ARM.** `software/mnist/de1soc/mnist_tpu` reads
  raw 28×28 pixels, downsamples and quantizes them (byte-identical to numpy),
  pushes the infer program and the input over the lightweight bridge, reads
  the 10 scores back, and takes the argmax.

Measured over all 10,000 test images: **109.5 µs/image** end to end one at a
time, 77.6 µs in batches of 8 ([`performance.md`](performance.md) §0).

**The drawing demo** (`software/mnist/draw_demo.py --de1soc`) sends a drawing
to `mnist_tpu serve`, which predicts it on the TPU and lights the digit on
HEX0. `--offline` runs the host reference instead.

## 6. Running it

```bash
make -C software/mnist/de1soc data          # Mac: model.bin + testset.bin
make -C software/mnist/de1soc sim-bench     # Mac: the ARM program against Verilator (make rtl-sim first)
make -C software/mnist/de1soc arm           # VM: the ARM binary
# copy build/{mnist_tpu,model.bin,testset.bin} to the SD card, then on the board:
/mnt/boot/mnist_tpu bench /mnt/boot/model.bin /mnt/boot/testset.bin
# the drawing demo, from the Mac (the console port must be free):
python3 software/mnist/draw_demo.py --de1soc /dev/cu.usbserial-<id>0 --baud 1562500
python3 software/mnist/draw_demo.py --offline        # no board
python3 software/mnist/train_mnist.py                # retrain (overwrites the committed model)
```

## 7. Files

| File | What |
|---|---|
| `software/mnist/train_mnist.py` | train and quantize, around §2–3; `downsample`, `hw_layer` |
| `software/mnist/mnist_model.py` | `load_model`, `quantize`, `predict_batch_offline` (the host reference), `OfflineModel` for the demo |
| `software/mnist/draw_demo.py` | the Tkinter drawing demo: `--de1soc PORT [--baud]` or `--offline` |
| `software/mnist/de1soc/` | `make_data.py`, `mnist-tpu.c` (`bench`, `serve`), `Makefile`, and its own README |
| `software/mnist/model/mnist-2x2-int8.npz` | the committed weights |

## 8. Open work

On the DE1-SoC, see [`backlog.md`](backlog.md):
- faster ARM preprocessing, which is half of each image;
- fewer bridge accesses;
- a bigger model now that the accumulator is 32 bits wide;
- retraining without ReLU on the output.
