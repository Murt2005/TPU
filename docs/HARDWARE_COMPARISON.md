# pico2-ice vs. local Mac (M2 Pro): speed, accuracy, power, size

Runs the same 144→64→10 MNIST model (`mnist/model/mnist_2x2_int8.npz`), on the
same sampled test images, through three execution paths:

1. **pico2-ice hardware** — the real 2×2 systolic array on the iCE40UP5K,
   driven over UART by `tpu_host.py`/`mnist/infer.py`'s `HardwareBackend`.
2. **Mac, one image at a time** — the exact same fixed-point math
   (`train_mnist.hw_layer`) run locally in numpy, called once per image
   (`OfflineBackend`) — the fairest latency comparison, since it matches the
   hardware path's one-request-at-a-time call pattern.
3. **Mac, batched/vectorized** — the same math, but run as one matrix
   operation over the whole batch (`predict_batch_offline`) instead of a
   Python loop — shows what the CPU can actually do when not artificially
   forced into a single-image-at-a-time protocol.

Reproduce with:
```bash
python3 mnist/infer.py --port /dev/cu.usbmodemXXXX --compare --test-n 20
```

## Measured results (2026-07-07, 20 sampled MNIST test images, seed=0)

| Path | Accuracy | Latency |
|---|---|---|
| pico2-ice hardware | 19/20 (95.00%) | 7975.62 ms/image |
| Mac (M2 Pro), one image at a time | 19/20 (95.00%) | 0.09 ms/image |
| Mac (M2 Pro), batched/vectorized | 19/20 (95.00%) | 0.01 ms/image |

Accuracy is identical across all three (same int8/int16 fixed-point math,
same images) — this isn't a numerics question, it's purely about where the
arithmetic physically happens. The gap is **~90,000x** one-at-a-time and
**~800,000x** batched, and it is *not* the systolic array being slow: the
2×2 MMU computes a tile in a handful of clock cycles. It's the 115200-baud
UART link — `docs/sequencer_uart_design.md` §4/§5 already identifies UART
framing, not the datapath, as the dominant cost, and this model's ~2,464
tiled `RUN`s/image (vs. the original tiny model's ~592) means ~2,464 UART
round-trips of load-weights/load-activation/run/read-back, each bottlenecked
by a handful of ~87 µs/byte serial transfers rather than compute.

## Why compare them at all

They're solving different problems. The Mac number is "how fast can a
general-purpose CPU run this tiny model" — trivially fast, because a 2026
laptop CPU is enormously overprovisioned for a 144→64→10 MLP. The pico2-ice
number is "how fast can a **fully custom, from-scratch systolic-array
datapath running on a $30 FPGA dev board, talking over a slow serial link**"
do the same job — and the interesting result isn't the latency, it's that a
hand-built TPU clone gets the *same answer* end-to-end on real silicon.

## Hardware, side by side

| | pico2-ice (iCE40UP5K + RP2350B) | Apple M2 Pro (MacBook Pro 14", 2023) |
|---|---|---|
| Role in this repo | Runs the actual TPU datapath (`rtl/*.sv` synthesized to `fpga/tpu_top.bin`) + USB↔UART bridge firmware | Runs the *host* driver (`tpu_host.py`, `mnist/infer.py`) and, in this comparison, a plain numpy re-implementation of the same math |
| Process node | iCE40UP5K: 40nm (Lattice/TSMC); RP2350: 40nm | TSMC N5P (5nm-class) |
| Compute resources used | A 2×2 systolic array carved out of the iCE40UP5K's 5,280 4-input LUTs; RP2350B's dual Cortex-M33/Hazard3 cores just bridge USB↔UART, not involved in compute | 1 CPU core (of 12: 8P+4E) running a numpy matmul; GPU/Neural Engine unused entirely |
| Transistor / gate scale | 5,280 LUTs (iCE40UP5K) — a few thousand logic elements total | ~40 billion transistors (M2 Pro die) |
| Typical power draw | iCE40UP5K: ~75 µW static; RP2350 active current ~90-95 mA @ 5V (~450-475 mW) bridging USB↔UART — whole board is sub-watt class | M2 Pro SoC package power in the 20-30W range under sustained CPU load; MacBook Pro 14" ships with a 67-96W adapter for the *whole laptop* (display, SSD, etc. included) |
| Physical size | Pico-form-factor board, ~51 × 21 mm footprint, no display/battery | 31.3 × 22.1 × 1.55 cm, 1.55-1.63 kg (whole laptop, with 14.2" display and battery) |
| Approx. price | ~$30-40 dev board | $1,999+ laptop |
| This benchmark | 95.00% acc, ~7,976 ms/image (UART-framing-bound, not compute-bound) | 95.00% acc, 0.01-0.09 ms/image (numpy on one CPU core) |

**Caveats**: the power/size numbers compare a bare microcontroller+FPGA dev
board against an entire laptop (display, battery, SSD, 11 unused CPU cores,
GPU, Neural Engine) — genuinely different categories of thing, not an
apples-to-apples SoC-vs-SoC teardown. The point isn't "pico2-ice wins" or
"Mac wins," it's the trade-off: a few thousand LUTs and sub-watt power can
reproduce a real (if tiny) TPU datapath's exact numerical behavior, at a
UART-bound latency cost that a general-purpose CPU makes irrelevant by just
being enormously overprovisioned for the job.

Sources:
- [iCE40 UltraPlus Family Data Sheet](https://www.latticesemi.com/-/media/LatticeSemi/Documents/DataSheets/iCE/iCE40-UltraPlus-Family-Data-Sheet.ashx)
- [tinyvision-ai-inc/ice40_power power analysis](https://github.com/tinyvision-ai-inc/ice40_power)
- [RP2350 datasheet](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf)
- [RP2350: the brains of Raspberry Pi Pico 2](https://www.raspberrypi.com/news/rp2350-the-brains-of-raspberry-pi-pico-2/)
- [Apple M2 Pro chip specs — Low End Mac](https://lowendmac.com/1234/apple-silicon-m2-pro-chip-specs/)
- [Apple boosts transistor count in 5nm M2 chip — eeNews Europe](https://www.eenewseurope.com/en/apple-boosts-transistor-count-in-5nm-m2-chip/)
- [MacBook Pro (14-inch, 2023) — Tech Specs, Apple Support](https://support.apple.com/en-us/111340)
