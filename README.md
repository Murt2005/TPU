# Reverse-Engineering Google's TPUv1

Reimplementing the core of Google's first-generation Tensor Processing Unit (as
described in *In-Datacenter Performance Analysis of a Tensor Processing Unit*) as
synthesizable SystemVerilog, running on a real FPGA.

The TPU executes a stream of 64-bit instructions on four concurrent engines (load,
weight fetch, matrix multiply, activate). Weights and layer outputs stay on chip
between instructions, and a hardware requantizer turns one layer's 32-bit sums into
the next layer's int8 input. The weight-stationary 8×8 systolic array
double-buffers its weights, so a new tile starts every `max(m, 8)` cycles and the
array is fed every cycle.

It runs on a **Terasic DE1-SoC** (Cyclone V) at 50 MHz, driven by the board's own
ARM. MNIST classifies in **about 110 µs per image end to end** over the full
10,000-image test set: 97.50%, every prediction equal to the reference model. A
drawing demo shows the digit on the board's seven-segment displays.

It's the repo's second core. The first ran on a pico2-ice (iCE40UP5K) and reached
63.8 ms/image; its measured weak spots shaped this design (§7). Design notes live
in [`docs/`](docs/), starting at [`docs/README.md`](docs/README.md).

**Where to start:**

| You have… | Go to |
|---|---|
| A DE1-SoC | [§1 Quick start](#1-quick-start-on-the-de1-soc) |
| No board — just want to see it work | [§2 Without a board](#2-without-a-board) |
| Curiosity about how a TPU actually works | [§3 How the design works](#3-how-the-design-works), then [`docs/architecture.md`](docs/architecture.md) |
| A change to make | [§5 Build reference](#5-build-reference) and [`CONTRIBUTING.md`](CONTRIBUTING.md) |

---

## 1. Quick start on the DE1-SoC

Two stages. **§1.4** gets the TPU running and self-checking on the FPGA with
nothing but a USB cable. **§1.5–1.6** put it behind the board's ARM Linux, where
the test suite, MNIST and the drawing demo run. Everything here was done on an
Apple Silicon Mac. On x86 Linux, skip the VM and run Quartus directly.
[`docs/de1soc.md`](docs/de1soc.md) has the detail and the gotchas.

### 1.1 What you need

- **A DE1-SoC.** Tested on **rev H**; its USB-UART is a CP2105 with two ports.
  §1.5 uses Terasic's reference design (GHRD) for your revision.
- **Quartus Prime Lite** (free; Cyclone V support). It's x86 Linux or Windows
  only, so on a Mac it runs in an OrbStack VM (§1.3).
- From Terasic's DE1-SoC page (Resources): the **System CD** for your revision
  (`DE1-SoC_v.6.0.0_HWrevH_SystemCD.zip` for rev H), and, for §1.5, the
  **"Linux Console with framebuffer"** SD-card image.
- For §1.5: a **microSD card** (4–32 GB), and cables to the board's USB-Blaster
  and USB-UART ports.

### 1.2 Get the code and the Python environment

```bash
git clone https://github.com/Murt2005/TPU.git && cd TPU
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt          # numpy, pyserial, and the host/ package
```
> ⚠️ Create the venv in `.venv/`, **not** the repo root. `venv` writes a
> `.gitignore` containing `*` into its target directory, which would silently hide
> the entire repo from git.

Python 3.11+. The drawing demo needs `tkinter` (`brew install python-tk` on
Homebrew Python).

### 1.3 Toolchain

```bash
brew install verilator openfpgaloader         # simulation, lint, JTAG programming
brew install --cask orbstack                    # x86 Linux VM for Quartus (Apple Silicon)
orb create --arch amd64 ubuntu:22.04 quartus
```

Inside the VM (`orb -m quartus`), install Quartus Prime Lite with only the
components needed. Using Intel's online installer:
```bash
./qinst-lite-linux-23.1std.1-993.run --nox11 -- --cli --accept-eula \
    --install-dir ~/intelFPGA_lite/23.1std --components quartus,cyclonev
sudo apt install -y make unzip python3 gcc-arm-linux-gnueabihf libglib2.0-0 libfontconfig1 \
    libsm6 libxrender1 libxext6 libxft2 libxtst6 libxi6
```

OrbStack shares `/Users` at the same path, so the VM builds straight from your
checkout. From the Mac, run builds as
`orb -m quartus bash -c 'export PATH=$HOME/intelFPGA_lite/23.1std/quartus/bin:$PATH; cd <dir>; make'`.
The USB-Blaster II needs Intel's firmware file, which ships inside Quartus. Copy
`~/intelFPGA_lite/23.1std/quartus/linux64/blaster_6810.hex` out of the VM for
`openFPGALoader`.

Tested with Verilator 5.032, Quartus Prime Lite 23.1std.1, openFPGALoader 1.1.1
and Python 3.13.

### 1.4 First light: the self-test over JTAG

No SD card, no Linux. The FPGA replays the core's tests from an on-chip ROM and
checks every result against the reference model:

```bash
make selftest-sim                             # Mac: generate the ROM, run it in Verilator — must PASS
make -C boards/de1soc/fpga/selftest           # VM: ~10 min -> output_files/tpu-selftest.rbf
openFPGALoader -b de1Soc --probe-firmware blaster_6810.hex \
    boards/de1soc/fpga/selftest/output_files/tpu-selftest.rbf
```

HEX3–0 should read **`PASS`**, with LEDR0 lit. A failure shows the failing test's
number and a mismatch count instead. With **SW9** up, SW4–0 pick a
performance-counter capture to show on HEX5–0; each must equal the Verilator run
(`make selftest-sim ST_SLOTS=21` prints them).

### 1.5 The TPU behind the ARM

**Build** the bitstream (Terasic's reference design plus the TPU at `0xFF200000`
and a HEX display register) and the ARM programs in the VM. Build the MNIST data
on the Mac:

```bash
make -C boards/de1soc/fpga/hps CD_ZIP=/Users/<you>/Downloads/DE1-SoC_v.6.0.0_HWrevH_SystemCD.zip   # VM
make -C software/mnist/de1soc arm                                                                 # VM
make -C software/mnist/de1soc data                                                                # Mac
```

**Prepare the SD card.** Write the Linux image (`DE1_SoC_FB.img`), then copy onto
its FAT partition:
- `boards/de1soc/fpga/hps/build/soc_system.rbf`. Keep Terasic's original under
  another name.
- `boards/de1soc/fpga/hps/build/isa_mmio` and `build/setbaud`.
- `software/mnist/de1soc/build/{mnist_tpu,model.bin,testset.bin}`.

```bash
diskutil list                                          # find the card — check the size!
diskutil unmountDisk /dev/diskN
sudo dd if=DE1_SoC_FB.img of=/dev/rdiskN bs=4m status=progress && sync
```

**Boot.** Set **MSEL (SW10, underside) to `00000`** (positions 1–5 ON), insert the
card, and power on. The HEX displays going blank means U-Boot loaded the new
bitstream. The Linux console is the CP2105's first port
(`/dev/cu.usbserial-<id>0`, 115200 baud, user `root`, no password).

**Run the core's full test suite on the hardware**, from the Mac:
```bash
python3 -u tests/isa/test_isa_rtl.py serial:/dev/cu.usbserial-<id>0
```
It logs in over the console, starts `isa_mmio` (a register server on the ARM),
and drives the real core exactly as it drives Verilator. Expect about 15 minutes
at 115200 baud and all 30 checks passing; over this link the cycle-rate check
only checks beats and stalls, and the self-test checks the rate on chip.

### 1.6 MNIST and the drawing demo

On the board's console (`screen /dev/cu.usbserial-<id>0 115200`, or any
terminal):
```bash
mount /dev/mmcblk0p1 /mnt/boot
/mnt/boot/mnist_tpu bench /mnt/boot/model.bin /mnt/boot/testset.bin
```
Expect 97.50% on all 10,000 test images, every prediction equal to the reference
model, about 110 µs/image one at a time and 80 µs/image in batches of 8.

Then the drawing demo, from the Mac (close any terminal on the console port
first):
```bash
python3 software/mnist/draw_demo.py --de1soc /dev/cu.usbserial-<id>0 --baud 1562500
```
Draw a digit and click **Predict**. The board runs the whole inference on its TPU
and shows the digit on **HEX0**; **Clear** puts back the dashes. `--baud 1562500`
runs the console about 13× faster than the default 115200, bringing the round
trip from about 74 ms to 7.5 ms.

### 1.7 Troubleshooting

| Symptom | Fix |
|---|---|
| Quartus synthesis hangs, idle, for many minutes | Its parallel helpers deadlock under Rosetta. The projects set `NUM_PARALLEL_PROCESSORS 1`; keep it in any new project |
| `openFPGALoader` can't find the cable | Pass `--probe-firmware blaster_6810.hex`; it loads the USB-Blaster II's firmware |
| HEX displays don't blank after boot | U-Boot didn't load our `.rbf`: check MSEL is `00000` and the file is named `soc_system.rbf` |
| Console prints garbage | A session died at 1.5625 Mbaud. Any `BoardConsole` connection (the test link, the demo) detects and resets it, or open the port at 1562500 and type `stty sane 115200` |
| A console upload never finishes | Big files overflow: there's no flow control and the board writes ~6 KB/s. `upload()` paces at 4 KB/s; put bitstreams on the SD card |
| Ethernet comes up but receives nothing | Known, unsolved on the 2014 image + rev H; everything uses the console instead |

More in [`docs/de1soc.md`](docs/de1soc.md) §6.

---

## 2. Without a board

Everything except the FPGA runs on your laptop with Verilator:

```bash
make test           # the unit benches, one per datapath module
make sim-test       # the reference model's checks, then the RTL vs the model word for word, N = 8 and 4
make selftest-sim   # the board's self-test ROM, exactly as the FPGA will replay it
make check          # all of the above, plus lint
make -C software/mnist/de1soc data sim-bench    # MNIST's ARM program against Verilator (make rtl-sim first)
python3 software/mnist/draw_demo.py --offline   # the drawing demo on the host reference
```

---

## 3. How the design works

The TPUv1 keeps weights stationary inside the matrix unit and streams activations
through it, so weights, which are reused many times, are never re-fetched between
uses. Its blocks, as this design builds them:

- **Host interface.** In the TPUv1, PCIe to a host and DDR3 for weights. Here
  it's a 12-register Avalon-MM bridge on the DE1-SoC's lightweight HPS→FPGA
  bridge. The board's ARM pushes 64-bit instructions and 32-bit data words into
  FIFOs and reads results from an out FIFO.
- **Instructions and the dispatcher.** 64-bit instructions (`WR_WMEM`, `WR_UB`,
  `MATMUL`, `ACTIVATE`, `WAIT`, `SIGNAL`, …). The dispatcher decodes and
  range-checks each one and queues it to one of four engines that run
  concurrently. `WAIT` orders the engines where data flows between them;
  `SIGNAL` fences the program and raises `DONE`.
- **Weight memory and the weight FIFO.** All of a network's weights live on chip
  in WMEM. The weight FIFO holds two tiles: one streams into the array while the
  next is fetched.
- **Unified buffer.** On-chip activations. A layer's output is written back here
  and becomes the next layer's input without leaving the chip, so the host sends
  only the network input and reads only the final scores.
- **Systolic data setup.** Skews each activation row in time (element *i*
  delayed *i* cycles), so it enters the array as a diagonal wavefront.
- **Matrix unit.** An N×N grid of PEs (8×8 on the board), each multiplying its
  stationary weight by the passing activation and adding into the partial sum
  from above. Each PE also holds the *next* tile's weight. The first activation
  of a tile carries a flip bit that swaps it in on exactly the right cycle, so
  tiles run back to back.
- **Accumulators.** De-skew the array's column outputs back into rows, and
  write or add them into a 32-bit ACC memory, summing a large reduction across
  tiles.
- **Activation.** Bias, ReLU, then a hardware **requantizer** (saturate,
  multiply by a 24-bit scale, round, shift, clamp) that turns 32-bit sums into
  the next layer's int8 input.

Each block is one file in `rtl/core/`, with control in separate engine files.
[`docs/architecture.md`](docs/architecture.md) has the modules, timing and
overlap scheme, and [`docs/isa.md`](docs/isa.md) the instructions, registers and
data layouts.

---

## 4. Repo layout

```
TPU/
├── rtl/
│   ├── core/          the TPU: dispatch + four engines, and the TPUv1 datapath files
│   └── peripherals/   host_bridge: the 12-register Avalon-MM host interface
├── boards/de1soc/     top/ (tpu_top, the self-test, hex_display) · fpga/ (selftest/, hps/
│                      = Terasic's GHRD + the TPU) · sw/ (ARM: isa_mmio, setbaud)
├── host/              the `tpu` Python package: encoder, reference model, compiler,
│                      WAIT checker, device and board-console links
├── tests/
│   ├── unit/          self-checking unit benches (make test)
│   ├── isa/           the reference-model and RTL-vs-model suites (sim, or on the board)
│   └── verilator/     C++ benches: the register transport, the self-test runner
├── software/mnist/    144→64→10 MLP: training, the host reference, the drawing demo;
│                      de1soc/ = MNIST end to end on the ARM
├── docs/              design reference — start at docs/README.md
├── mk/                the Makefile's rules
└── Makefile, verilator.vlt, requirements.txt
```

[`docs/repo-map.md`](docs/repo-map.md) has every file.

---

## 5. Build reference

| Command | Where | Does |
|---|---|---|
| `make test` | Mac | the unit benches (`make unit-<name>` for one) |
| `make sim-test` | Mac | `model-test`, then `rtl-test` at N = 8 and 4 (`make rtl-test N=4` for one size) |
| `make lint` | Mac | Verilator lint: `tpu_top` at N = 8 and 4, `tpu_selftest` |
| `make selftest-sim [ST_SLOTS=21]` | Mac | the self-test ROM in Verilator, optionally reading the perf captures back |
| `make check` | Mac | lint + test + sim-test + selftest-sim |
| `make -C boards/de1soc/fpga/selftest` | VM | the FPGA-only self-test bitstream |
| `make -C boards/de1soc/fpga/hps CD_ZIP=…` | VM | Terasic's GHRD + the TPU + `hex_pio` → `build/soc_system.rbf`, plus `build/isa_mmio` and `build/setbaud` |
| `make -C software/mnist/de1soc data` / `arm` / `sim-bench` | Mac / VM / Mac | MNIST model + test data / the ARM program / the ARM program against Verilator |

The array size is `ARRAY_SIZE` on `tpu_top` (8 in both board builds; set in
`tpu-selftest.sv` and `boards/de1soc/fpga/hps/tpu_hw.tcl`), with the memory depths
beside it. 8×8 uses 78 of the Cyclone V's 87 DSP blocks, so a bigger array needs
DSP packing ([`docs/backlog.md`](docs/backlog.md)). Measured fit and timing are in
[`docs/de1soc.md`](docs/de1soc.md) §1.

Board files can be updated without moving the SD card:
`tpu.isa_device.BoardConsole(port).upload(local, remote)` copies a file over the
console, paced at 4 KB/s and MD5-checked. That's fine for programs, but put
bitstreams on the card.

---

## 6. Status and future work

- **On the DE1-SoC (hardware):**
  - **Self-test:** passes, with the per-tile cycle rate checked on chip.
  - **Test suite:** all 30 checks pass when run from the board's ARM.
  - **MNIST:** 97.50% on 10,000 images, every prediction equal to the
    reference model, about 110 µs/image.
  - **Demo:** the drawing demo shows the digit on HEX0.
  - **Timing:** closes at 50 MHz with about 3 ns of slack.
- **In simulation:**
  - **Correctness:** the RTL matches the reference model word for word at
    N = 8 and 4, including random programs with the engines running
    concurrently.
  - **Throughput:** each tile costs exactly `max(m, N)` cycles with no
    steady-state stalls.
  - **Unit benches:** every datapath module has one, each checked against an
    injected bug.
- **Next** ([`docs/backlog.md`](docs/backlog.md)):
  - faster ARM preprocessing and fewer bridge accesses, which together make up
    most of the 110 µs;
  - a 16×16 array;
  - DDR3;
  - a transformer on the core;
  - Ethernet on the rev H board's Linux image.

---

## 7. History: the first core

The first design was a byte-protocol core with a single serial sequencer, on a
[pico2-ice](https://pico2-ice.tinyvision.ai/) (iCE40UP5K + RP2350). It was
hardware-validated at 2×2, 2×4 and 4×4. A measured performance campaign took
MNIST from **8.0 s to 63.8 ms per image (125×)**: batched wire commands, DSP-mapped
multipliers, a faster link, an SPI interface, and an RP2350-offloaded tiling loop.
In simulation, it also ran a small transformer (TinyStories-1M) with every linear
layer on the array.

Tracing it showed its array **idle 84–93% of the time**, weights re-sent every
tile, and every layer returning to the host to be requantized. Those
measurements are what this design fixes ([`docs/utilization.md`](docs/utilization.md),
[`docs/performance.md`](docs/performance.md)).

Its code, firmware, docs and bring-up guide are preserved at the git tag
**`pico2-ice-final`** (`git checkout pico2-ice-final`). The current core reuses its
datapath files, rewritten for the new instruction set.

---

## 8. Contributing

Contributions are welcome: bug fixes, benches, docs. See
[CONTRIBUTING.md](CONTRIBUTING.md) for setup, the local gates (`make check`, plus
the board tiers for anything touching synthesis; there's no hosted CI by
choice), how to add a unit bench, and the house style.

## 9. License

Released under the [MIT License](LICENSE) — © 2026 Murat Acar. You are free to
use, modify, and distribute this design; attribution is appreciated.
