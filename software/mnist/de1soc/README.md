# MNIST on the DE1-SoC

Runs entirely on the board: the ARM reads raw 28×28 pixels, downsamples and
quantizes them (byte-identical to the host's numpy), runs both layers on the
instruction-stream TPU over the lightweight bridge (the hidden layer stays in
the core's UB), and takes the argmax.

| File | Role |
|---|---|
| `make_data.py` | `model.bin` (compiled load + infer programs) and `testset.bin` (pixels, label, host quantized input, reference-model and host predictions) |
| `mnist-tpu.c` | `bench` over the test set; `serve` for `../draw_demo.py --de1soc`, digit on HEX0 |
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
.venv/bin/python software/mnist/draw_demo.py --de1soc /dev/cu.usbserial-<id>0 [--baud 1562500]
```

`--baud 1562500` switches the console for the session. That rate is 6.25 MHz / 4,
the fastest the HPS UART and the CP2105 both produce: its 2 Mbps neighbour,
2,083,333, doesn't link. The board needs `setbaud` on its FAT partition, since
the board's busybox `stty` stops at 921,600.

Measured with 10 test images: 117 µs on the board either way; the round trip
from the Mac is 73.5 ms at 115,200 and **7.5 ms at 1,562,500**.

## Updating the board without the SD card

`BoardConsole.upload(local, remote)` (in `tpu.isa_device`) copies a file over
the console: the tty goes raw, `dd bs=1 count=N` receives the bytes, and the
`.part` file is renamed only once its md5 matches. It runs at 1,562,500 baud
when `setbaud` is on the board.
