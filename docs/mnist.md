# MNIST demo

The end-to-end proof that the array computes something real: a digit
classifier whose forward pass runs on actual silicon.

## 1. The model

**144 → 64 → 10**, two layers, ReLU on both.

- Input: MNIST digit downsampled 28×28 → **12×12** = 144 features.
- Hidden: 64 units.
- Output: 10 class scores.
- int8 weights and activations, int16 bias — matching the wire format in
  `rtl/core/tpu_sequencer.sv`.

Both K values (144, 64) and both N values (64, 10) are even, so every layer
tiles cleanly into 2×2 blocks with no padding. Larger shapes pad on the
axes that don't divide.

Trained and quantized by `software/mnist/train_mnist.py`, which writes
`software/mnist/model/mnist_2x2_int8.npz` (~5 KB, committed — the demo works out of
the box). Retraining downloads MNIST (~11 MB, cached in `software/mnist/data/`,
gitignored).

## 2. Why the model is this small

**It is deliberately tiny, and the constraint is hardware, not accuracy.**

`rtl/core/accumulator.sv`'s PSUM register is `PSUM_WIDTH=16` and **does not
saturate — it silently wraps**, exactly like `tests/hw/hw_regression.py`'s
golden model. That holds regardless of K-dim tiling: the persistent
`psum_reg` is 16 bits whether one `RUN` or seventy-two passes feed it.

So a layer's K (its input width) cannot be large enough that realistic
int8-range weights and activations push the true sum past ±32,767. K=144 and
K=64 were chosen against that ceiling and then **empirically verified: zero
overflow across the full 10,000-image test set, with a 5% calibration safety
margin.**

Growing the model means either proving the wider sum still fits, or raising
`PSUM_WIDTH`. That is now a build knob rather than an RTL edit — it widens
the wire format with it, and `tpu_host.py --psum-width` must agree — but no
bitstream has been built or hardware-validated with it. The committed MNIST
model is sized for `PSUM_WIDTH=16` and is unaffected.

## 3. Three quantization details the RTL forces

These are why `train_mnist.py` doesn't look like a normal quantization
script:

**ReLU is applied on every layer**, including the output. When the model
was trained, `rtl/core/activation.sv` had no bypass mode, so the network was
trained with ReLU on the output logits too — the loss landscape matches what
the hardware actually produces (argmax over ReLU'd scores) rather than
training a standard logits-then-softmax network and hoping ReLU doesn't
disturb the decision boundary afterwards. The RTL has since gained a
per-pass bypass (`flags[2]`, [`protocol.md`](protocol.md) §2), but the
committed model and `infer.py` still use ReLU everywhere, and the
`FW_MATMUL` offload path cannot carry the bypass at all. Retraining with a
linear output layer is possible now; nobody has done it.

**There is no on-chip requantization unit.** `unified_buffer` stores int8
(`DATA_WIDTH=8`), but a layer's output arrives as int16 post-ReLU. The
**host** must rescale each layer's output down to int8 before it becomes the
next layer's input. `train_mnist.py` calibrates that per-layer rescale
(`hidden_scale`) empirically and bakes it into the saved model.

**Bias is int16 LE on the wire** and is loaded once per output block, not
per K-tile — `RUN_TILE` and `STREAM_RUN` deliberately don't touch
`reg_bias`.

## 4. Accuracy

| Where | Accuracy |
|---|---|
| Quantized model, full 10k test set (sim) | 97.50% |
| Real hardware, 20 sampled images | 95.00% (19/20) |
| Local numpy, same 20 images | 95.00% (19/20) — **identical** |

Hardware and host agree exactly, because they run the same fixed-point math.
Any divergence is a bug, not rounding.

## 5. Running it

```bash
# accuracy on real hardware, N random test images end-to-end
python3 software/mnist/infer.py --port /dev/cu.usbmodemXXXX --test-n 20

# hardware vs. local numpy on identical images, side by side
python3 software/mnist/infer.py --port /dev/cu.usbmodemXXXX --compare --test-n 20

# no board at all — same pipeline, pure numpy
python3 software/mnist/infer.py --offline --test-n 20

# draw a digit with the mouse; the board's LED flips green → blue on completion
python3 software/mnist/draw_demo.py --port /dev/cu.usbmodemXXXX

# retrain + requantize (overwrites the committed model)
python3 software/mnist/train_mnist.py
```

Add `--rows/--cols/--m-tile` and `--link` to match the flashed bitstream.

## 6. Files

| File | What |
|---|---|
| `software/mnist/train_mnist.py` | Train + quantize; the header comment is the authoritative note on all the constraints above |
| `software/mnist/infer.py` | Multi-layer driver; `HardwareBackend` (via `tpu_host.py`'s `matmul_tiled()`) and `OfflineBackend` (numpy), plus `--compare` and `--no-offload` |
| `software/mnist/draw_demo.py` | Tkinter drawing demo; `--offline` runs boardless |
| `software/mnist/model/mnist_2x2_int8.npz` | Committed pre-trained weights |
| `software/mnist/data/` | Downloaded IDX files (gitignored) |

The LED flip in `draw_demo.py` goes over the **second, otherwise-idle**
USB-CDC port, handled by `boards/pico2-ice/firmware/main.c`'s one-byte LED command listener —
it does not disturb the TPU link.

## 7. Open work

The single biggest remaining win is **batching `M_TILE` images per inference
call**. A lone image wastes the padded activation rows: at 4×4/M_TILE=4,
three of four streamed rows are zeros, which is why that shape measures
*worse* single-image (80.3 ms) than M_TILE=2 (63.8 ms) despite being
strictly more capable. Batched, layer 1 costs 30.6 ms per 2 rows vs. 44.6 —
projecting to **~17 ms/image**.

A bigger/better model is gated on §2's accumulator width: either prove it
still fits int16, or build a `PSUM_WIDTH=32` bitstream (never built so far).
See [`backlog.md`](backlog.md).
