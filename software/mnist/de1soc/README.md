# MNIST on the DE1-SoC

Runs entirely on the board: the ARM reads raw 28×28 pixels, downsamples and
quantizes them (byte-identical to the host's numpy), runs both layers on the
instruction-stream TPU over the lightweight bridge (the hidden layer stays in
the core's UB), and takes the argmax.

| File | Role |
|---|---|
| `make_data.py` | `model.bin` (compiled load + infer programs) and `testset.bin` (pixels, label, host quantized input, reference-model and host predictions) |
| `mnist_tpu.c` | `bench` over the test set; `serve` for `../draw_demo.py --de1soc`, digit on HEX0 |
| `Makefile` | `data`, `arm` (in the Quartus VM), `sim-bench` (the same C against Verilator via `-DSIM`) |

Deploy `mnist_tpu`, `model.bin` and `testset.bin` to the SD card's FAT
partition, next to a bitstream built from `boards/de1soc/fpga/hps` (it has the
`hex_pio` the demo uses).

## Measured on the board (2026-10-01, 8×8 core, 50 MHz)

| | m = 1 | m = 8 |
|---|---|---|
| accuracy, 10,000 test images | 97.50% | 97.50% |
| == reference model | 10,000 / 10,000 | 10,000 / 10,000 |
| TPU path per image | 60.6 µs | 28.7 µs |
| end to end, incl. 48.9 µs ARM preprocessing | **109.5 µs** (9,132/s) | **77.6 µs** (12,880/s) |

## Drawing demo

From the Mac, with the console port free:

```sh
.venv/bin/python software/mnist/draw_demo.py --de1soc /dev/cu.usbserial-<id>0
```
