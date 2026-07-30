# mnist/ — the end-to-end demo

144 → 64 → 10 MLP, int8, running its forward pass on the real array.

## Commands

```bash
python3 mnist/infer.py --port /dev/cu.usbmodemXXXX --test-n 20     # accuracy on silicon
python3 mnist/infer.py --port ... --compare --test-n 20            # hw vs local numpy
python3 mnist/infer.py --port ... --timing-breakdown               # where the time goes
python3 mnist/infer.py --offline --test-n 20                       # no board needed
python3 mnist/draw_demo.py --port ... --led-port ...               # draw a digit
python3 mnist/train_mnist.py                                       # retrain + requantize
```

All three scripts take `--rows/--cols/--m-tile` and `--link`, which **must
match the flashed bitstream**.

## The hard constraint: a 16-bit non-saturating accumulator

`rtl/accumulator.sv`'s PSUM register is `PSUM_WIDTH=16` and **wraps silently
on overflow** — it does not saturate. That holds regardless of K-tiling depth
(the persistent `psum_reg` is 16 bits whether one `RUN` or 72 passes feed it),
and `tests/hw_regression.py`'s golden model wraps identically.

So **a layer's K cannot be large enough that realistic int8 weights and
activations push the true sum past ±32,767.** K=144 and K=64 were chosen
against that ceiling and empirically verified: zero overflow across the full
10k-image test set, with a 5% calibration safety margin.

**This is why the model is tiny — accuracy was never the limiter.** Growing it
means either proving the wider sum still fits, or widening `PSUM_WIDTH` in the
RTL *and* the wire format *and* the host.

## Three quantization details the RTL forces

Don't "fix" these to look like a normal quantization script:

- **ReLU is applied on every layer, including the output.**
  `rtl/activation.sv` has no bypass. The net is therefore *trained* with ReLU
  on the output logits, so the loss landscape matches argmax-over-ReLU'd-
  scores rather than hoping ReLU doesn't move the decision boundary later.
- **There is no on-chip requantization.** `unified_buffer` stores int8, but a
  layer's output arrives int16 post-ReLU. The **host** rescales each layer's
  output down to int8 for the next layer; `train_mnist.py` calibrates that
  factor (`hidden_scale`) empirically and bakes it into the `.npz`.
- **Bias is int16 LE, loaded once per output block** — not per K-tile.
  `RUN_TILE` and `STREAM_RUN` deliberately don't touch `reg_bias`.

Both K values (144, 64) and both N values (64, 10) are even, so every layer
tiles cleanly into 2×2 blocks with no padding.

## Expected numbers

| | |
|---|---|
| Quantized, full 10k test set (sim) | 97.50% |
| Real hardware, 20 sampled images | 19/20 (95.00%) |
| Local numpy, same images | 19/20 — **bit-identical** |
| Latency | ~63.8 ms/image at 4×4/M_TILE=2 over SPI with offload |

Hardware and host run the same fixed-point math. **Any divergence is a bug,
not rounding.**

## Files

`train_mnist.py` (its header comment is the authoritative constraint note) ·
`infer.py` (`HardwareBackend` via `tpu_host.py`'s `matmul_tiled()`,
`OfflineBackend` in numpy) · `draw_demo.py` (Tkinter; `--offline` works
boardless) · `model/mnist_2x2_int8.npz` (committed, ~5 KB — retraining is
optional and overwrites it) · `data/` (downloaded IDX, gitignored).

The draw demo's LED flip goes over the **second, otherwise-idle** CDC port,
so it doesn't disturb the TPU link.

## Open work

Batching `M_TILE` images per call is the highest-value item left in the repo:
a single image wastes the padded activation rows, which is why 4×4/M_TILE=4
measures *worse* single-image (80.3 ms) than M_TILE=2 (63.8 ms). Batched,
projected ~17 ms/image.

@../docs/mnist.md
