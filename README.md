# Reverse-Engineering Google's TPUv1

Reimplementing the core of Google's first-generation Tensor Processing Unit (as
described in *In-Datacenter Performance Analysis of a Tensor Processing Unit*) as
synthesizable SystemVerilog, running on real FPGAs.

The current design is an **instruction-stream core**: a 64-bit instruction set
executed by four concurrent engines (load, weight fetch, matrix multiply,
activate). Weights and layer outputs stay on chip between instructions, and a
hardware requantizer turns one layer's 32-bit sums into the next layer's int8
input. The weight-stationary 8×8 systolic array double-buffers its weights, so a
new tile starts every `max(m, 8)` cycles and the array is fed every cycle.

It runs on a **Terasic DE1-SoC** (Cyclone V) at 50 MHz, driven by the board's own
ARM. MNIST classifies in **109.5 µs/image end to end** over the full 10,000-image
test set: 97.50%, with every prediction equal to the reference model. A drawing
demo shows the digit on the board's seven-segment displays.

The first design, a byte-protocol core on a [pico2-ice](https://pico2-ice.tinyvision.ai/)
(iCE40UP5K), is still here and still works: 63.8 ms/image, 125× faster than its
first bring-up. Its measured weak spots, an array idle 84–93% of the time and
weights re-sent for every tile, are what the second design fixes. Design notes
live in [`docs/`](docs/), starting at [`docs/README.md`](docs/README.md).

**Where to start:**

| You have… | Go to |
|---|---|
| A DE1-SoC | [§1 Quick start on the DE1-SoC](#1-quick-start-on-the-de1-soc) |
| A pico2-ice | [§2 Quick start on a pico2-ice (legacy)](#2-quick-start-on-a-pico2-ice-legacy) |
| No board — just want to see it work | [§3 Without a board](#3-without-a-board-simulation--offline-mnist) |
| Curiosity about how a TPU actually works | [§4 How the design works](#4-how-the-design-works), then [`docs/isa.md`](docs/isa.md) |
| A build to change, or an array to resize | [§6 FPGA build reference](#6-fpga-build-reference) |

---

## 1. Quick start on the DE1-SoC

Two stages. **§1.4** gets the TPU running and self-checking on the FPGA with
nothing but a USB cable. **§1.5–1.6** put it behind the board's ARM Linux,
where the test suite, MNIST and the drawing demo run. Everything here was done
on an Apple Silicon Mac. On x86 Linux, skip the VM and run Quartus directly.
[`docs/de1soc.md`](docs/de1soc.md) has the detail and the gotchas.

### 1.1 What you need

- **A DE1-SoC.** Tested on **rev H**; its USB-UART is a CP2105 with two ports.
  §1.5 uses Terasic's reference design for your revision, from its System CD.
- **Quartus Prime Lite** (free; Cyclone V support). It's x86 Linux or Windows
  only, so on a Mac it runs in an OrbStack VM (§1.3).
- From Terasic's [DE1-SoC page](https://www.terasic.com.tw/) (Resources): the
  **System CD** for your board revision (`DE1-SoC_v.6.0.0_HWrevH_SystemCD.zip`
  for rev H), and, for §1.5, the **"Linux Console with framebuffer"** SD-card
  image.
- For §1.5: a **microSD card** (4–32 GB), and cables to the board's USB-Blaster
  and USB-UART ports.

### 1.2 Get the code and the Python environment

```bash
git clone --recurse-submodules https://github.com/Murt2005/TPU.git
cd TPU
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt          # pyserial, numpy, and the host/ driver package
```
> ⚠️ Create the venv in `.venv/`, **not** the repo root. `venv` writes a
> `.gitignore` containing `*` into its target directory, which would silently hide
> the entire repo from git.

Python 3.11+. The drawing demo needs `tkinter` (`brew install python-tk` on
Homebrew Python).

### 1.3 Toolchain

```bash
brew install icarus-verilog verilator openfpgaloader       # sim, lint, JTAG programming
brew install --cask orbstack                                 # x86 Linux VM for Quartus (Apple Silicon)
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
checkout. Run builds from the Mac as
`orb -m quartus bash -c 'export PATH=$HOME/intelFPGA_lite/23.1std/quartus/bin:$PATH; cd <dir>; make'`.
The board's USB-Blaster II needs Intel's firmware file, which ships inside
Quartus. Copy `~/intelFPGA_lite/23.1std/quartus/linux64/blaster_6810.hex` out
of the VM for `openFPGALoader`.

### 1.4 First light: the self-test over JTAG

No SD card, no Linux. The FPGA replays the core's test suite from an on-chip ROM
and checks every result against the reference model:

```bash
make isa-selftest-sim                         # Mac: generate the ROM, run it in Verilator — must PASS
make -C boards/de1soc/fpga/selftest           # VM: ~10 min -> output_files/tpu_isa_selftest.rbf
openFPGALoader -b de1Soc --probe-firmware blaster_6810.hex \
    boards/de1soc/fpga/selftest/output_files/tpu_isa_selftest.rbf
```

HEX3–0 should read **`PASS`**, with LEDR0 lit. A failure shows the failing
test's number and a mismatch count instead. With **SW9** up, SW4–0 pick a
performance-counter capture to show on HEX5–0; each must equal the Verilator
run (`make isa-selftest-sim ISA_ST_SLOTS=21` prints them).

### 1.5 The TPU behind the ARM

**Build** the bitstream (Terasic's reference design plus the TPU at `0xFF200000`
and a HEX-display register) and the ARM programs in the VM. Build the MNIST
data on the Mac:

```bash
make -C boards/de1soc/fpga/hps CD_ZIP=/Users/<you>/Downloads/DE1-SoC_v.6.0.0_HWrevH_SystemCD.zip   # VM
make -C software/mnist/de1soc arm                                                                 # VM
make -C software/mnist/de1soc data                                                                # Mac
```

**Prepare the SD card.** Write the Linux image (`DE1_SoC_FB.img`), then copy onto
its FAT partition:
- `boards/de1soc/fpga/hps/build/soc_system.rbf`. Keep Terasic's original
  under another name.
- `boards/de1soc/fpga/hps/build/isa_mmio` and `build/setbaud`.
- `software/mnist/de1soc/build/{mnist_tpu,model.bin,testset.bin}`.

```bash
diskutil list                                          # find the card — check the size!
diskutil unmountDisk /dev/diskN
sudo dd if=DE1_SoC_FB.img of=/dev/rdiskN bs=4m status=progress && sync
```

**Boot.** Set **MSEL (SW10, underside) to `00000`** (positions 1–5 ON), insert
the card, and power on. The HEX displays going blank means U-Boot loaded the
new bitstream. The Linux console is the CP2105's first port
(`/dev/cu.usbserial-<id>0`, 115200 baud, user `root`, no password).

**Run the core's full test suite on the hardware**, from the Mac:
```bash
python3 -u tests/isa/test_isa_rtl.py serial:/dev/cu.usbserial-<id>0
```
It logs in over the console, starts `isa_mmio` (a register server on the
ARM), and drives the real core exactly as it drives Verilator. Expect about
15 minutes at 115200 baud. Every check passes except the cycle-rate one, which
over this link only checks beats and stalls; the self-test checks the rate on
chip.

### 1.6 MNIST and the drawing demo

On the board's console (`screen /dev/cu.usbserial-<id>0 115200`, or any
terminal):
```bash
mount /dev/mmcblk0p1 /mnt/boot
/mnt/boot/mnist_tpu bench /mnt/boot/model.bin /mnt/boot/testset.bin
```
Expect 97.50% on all 10,000 test images, every prediction equal to the
reference model, about 110 µs/image (one at a time) and 78 µs/image (batches
of 8).

Then the drawing demo, from the Mac (close any terminal on the console port
first):
```bash
python3 software/mnist/draw_demo.py --de1soc /dev/cu.usbserial-<id>0 --baud 1562500
```
Draw a digit and click **Predict**. The board runs the whole inference on its
TPU and shows the digit on **HEX0**. **Clear** puts back the dashes.
`--baud 1562500` runs the console about 13× faster than the default 115200,
bringing the round trip from about 74 ms to 7.5 ms.

### 1.7 Troubleshooting

| Symptom | Fix |
|---|---|
| Quartus synthesis hangs, idle, for many minutes | Its parallel helpers deadlock under Rosetta. The projects already set `NUM_PARALLEL_PROCESSORS 1`; keep it in any new project |
| `openFPGALoader` can't find the cable | Pass `--probe-firmware blaster_6810.hex`; it loads the USB-Blaster II's firmware |
| HEX displays don't blank after boot | U-Boot didn't load our `.rbf`: check MSEL is `00000` and the file is named `soc_system.rbf` |
| Console prints garbage | A session died at 1.5625 Mbaud. Any `BoardConsole` connection (the test link, the demo) detects and resets it, or open the port at 1562500 and type `stty sane 115200` |
| Ethernet comes up but receives nothing | Known, unsolved on the 2014 image + rev H; everything uses the console instead |

More in [`docs/de1soc.md`](docs/de1soc.md) §6.

---

## 2. Quick start on a pico2-ice (legacy)

The first target, kept working but no longer developed. By the end of this
section you'll have the legacy byte-protocol core running on real silicon,
classifying hand-drawn MNIST digits. Budget ~30 minutes the first time, most of
it toolchain installation.

### 2.1 The one thing to understand first

pico2-ice is **two chips**, and the FPGA is a peripheral of the microcontroller:

```
   Your PC  ──USB──►  RP2350 (MCU)  ──►  iCE40UP5K (FPGA)
                        │  exports the FPGA's CLOCK (it has no crystal)
                        │  pushes the FPGA's BITSTREAM (USB-DFU)
                        │  bridges your bytes to the FPGA's UART pins
                        └  drives the onboard LED
```

Three consequences that will save you an evening of debugging:

- **You flash two separate things**: firmware onto the RP2350 (§2.4, once), and
  gateware onto the iCE40 (§2.5, every time you change the RTL). **Firmware
  first** — the DFU interface that accepts the bitstream lives *in* the firmware.
- **The FPGA's clock frequency is chosen by the firmware**, and the UART's baud
  divider is baked into the bitstream at synthesis time against that same number.
  If you change one, change both. The defaults here already agree (12 MHz / 1 Mbaud).
- **The board exposes two identical-looking USB serial ports.** One talks to the
  FPGA, one doesn't. You'll pick the right one by trial in §2.6.

### 2.2 Get the code

As in §1.2. The RP2350 SDK is a git submodule, so the firmware build needs
`git submodule update --init --recursive` if you cloned without
`--recurse-submodules`.

### 2.3 Install the toolchain

**macOS (Homebrew):**
```bash
brew install yosys nextpnr-ice40 icestorm dfu-util   # FPGA build + flash
brew install icarus-verilog verilator gtkwave         # simulation (optional but recommended)
brew install cmake ninja                             # firmware build
brew tap riscv-software-src/riscv && brew install riscv-gnu-toolchain   # RP2350 compiler
```

**Debian/Ubuntu:**
```bash
sudo apt install yosys nextpnr-ice40 fpga-icestorm dfu-util cmake ninja-build
sudo apt install iverilog verilator gtkwave             # simulation (optional but recommended)
sudo apt install gcc-arm-none-eabi     # RP2350 compiler (ARM path, see §2.4)
```
If your distro's yosys/nextpnr packages are old, the prebuilt
[oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build/releases) bundle is
the easiest fix — it ships all of the above in one tarball.

**Python host driver**: as in §1.2.

Tested versions (other recent releases are likely fine): Yosys 0.63, Verilator
5.032, Icarus Verilog 13.0, Python 3.13.

### 2.4 Build and flash the RP2350 firmware (once)

This is the USB↔UART bridge. You only ever redo this if you change something in
`boards/pico2-ice/firmware/` — pure RTL changes need only a gateware reflash.

```bash
cd boards/pico2-ice/firmware && mkdir -p build && cd build
cmake -DPICO_BOARD=pico2_ice -DPICO_PLATFORM=rp2350-riscv \
      -DPICO_GCC_TRIPLE=riscv64-unknown-elf -G Ninja ..
ninja                                    # -> pico2_ice_bridge.uf2
```
Prefer ARM? `-DPICO_PLATFORM=rp2350-arm-s` and drop `-DPICO_GCC_TRIPLE`, with
`arm-none-eabi-gcc` on `PATH`. The first configure builds `picotool` from source,
so it takes noticeably longer than later ones.

Then flash it:

1. Hold the **BOOTSEL** button while plugging in USB. The board mounts as a drive.
2. Copy `pico2_ice_bridge.uf2` onto that drive. The board reboots on its own.
3. **Check the LED**: red is expected right now — no gateware is loaded yet.

> After this first flash you never need BOOTSEL again: opening the TPU serial port
> at 1200 baud reboots the board into the UF2 bootloader.

### 2.5 Build and flash the gateware

```bash
cd boards/pico2-ice/fpga/
make            # yosys -> nextpnr-ice40 -> icepack, produces tpu_top.bin
make prog       # flash it over USB-DFU (board in normal run mode, no button needed)
```

Two things to expect here:

- `dfu-util` prints **"Device's firmware is corrupt"** on every single flash. It is
  a known false alarm from an SDK bug (it reports a return value that's always
  falsy instead of polling the FPGA's `CDONE` pin). Ignore it.
- **Replug the board** afterwards, so the firmware's boot-time `CDONE` check re-runs
  against the new bitstream. The LED should now be **green** = FPGA configured and
  running. Red means it isn't — see §2.8.

This builds the default 2×2 array at 12 MHz / 1 Mbaud. Other shapes and the SPI
link are build knobs — see §6.2.

### 2.6 Find the board's serial port

```bash
python3 -c "import serial.tools.list_ports as p; [print(x) for x in p.comports()]"
```

You'll see two ports. On macOS both report the same product string (`pico-ice`), so
there's no reliable way to tell them apart programmatically:

- **`--port`** → the one bridged to the FPGA (`"iCE40 UART"`). On macOS, try the
  **higher-numbered** `/dev/cu.usbmodemN` first.
- **`--led-port`** → the other one (`"RP2040 logs"`), used only for the demo's LED
  feedback in §2.7. Entirely optional.

On Linux they're usually `/dev/ttyACM0` and `/dev/ttyACM1`.

Picked the wrong one? The host driver probes on connect and fails with an explicit
error rather than hanging — just try the other port.

### 2.7 Talk to it

Work up this ladder; each rung tells you something different if it fails.

```bash
# 1. One known-golden matmul vector, straight from the simulation test suite.
python3 tpu_host.py --port /dev/cu.usbmodemXXXX --selftest

# 2. The full hardware regression: every sim vector, int8/int16 boundary cases,
#    and a randomized multi-tile stress run, all against real silicon.
make hw-test PORT=/dev/cu.usbmodemXXXX

# 3. Real MNIST digits classified end-to-end on the array.
python3 software/mnist/infer.py --port /dev/cu.usbmodemXXXX --test-n 20

# 4. The fun one: draw a digit with your mouse, watch the board's LED flip
#    green -> blue as the on-chip inference completes.
python3 software/mnist/draw_demo.py --port /dev/cu.usbmodemXXXX --led-port /dev/cu.usbmodemYYYY
```

Step 3 runs a trained, quantized 144→64→10 MLP tile-by-tile through the physical
array — ~316 ms/image on this default 2×2 UART build (see §6.3 for the faster
configurations and [`docs/performance.md`](docs/performance.md) for where the time goes). The model is committed, so there's
nothing to train.

Step 4 needs `tkinter`; on Homebrew Python, `brew install python-tk` if
`import tkinter` fails. `--led-port` is optional.

> **Built a non-default configuration?** The host tools need flags that match the
> bitstream (`--rows` / `--cols` / `--m-tile` / `--psum-width` / `--link`), or the
> driver refuses to run. If you built with a named config (§6.2),
> `make host-flags CONFIG=<name>` prints them, and `make hw-test CONFIG=<name>`
> uses them.

### 2.8 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| LED red after flashing gateware | FPGA didn't configure | Replug the board so the boot-time `CDONE` check re-runs; confirm `make prog` actually completed |
| `dfu-util`: *"Device's firmware is corrupt"* | Known SDK false alarm, printed on **every** flash | Ignore it; trust the LED |
| Nothing responds on either port | Firmware not flashed, or FPGA not configured | `dfu-util -l` should list two DFU alt interfaces; check LED is green |
| Board responds, but data is **garbled** (not absent) | `CLK_FREQ` in `boards/pico2-ice/fpga/Makefile` ≠ `ice_fpga_init()` in `boards/pico2-ice/firmware/main.c` — the baud divider is baked in at synthesis | Change both together, reflash both images |
| Selftest fails with a shape mismatch error | Host flags don't match the flashed bitstream | Pass `--rows/--cols/--m-tile` matching your build knobs |
| Both serial ports look identical | macOS shows the USB product string, not per-interface descriptions | Trial and error; higher-numbered port first |
| `make time`: *"Can't find chipdb file"* | Some Homebrew icestorm installs can't resolve `-d up5k` | `make time ICETIME_CHIPDB=$(brew --prefix icestorm)/share/icestorm/chipdb/chipdb-5k.txt` |
| Long commands lose their tail; short ones are fine | You're on stock SDK bridge code | This repo's `boards/pico2-ice/firmware/main.c` already fixes it (blocking CDC→UART write) — make sure you flashed *this* firmware |

Still stuck? Open an issue — please include your LED state, the output of
`dfu-util -l`, and the exact `make`/`tpu_host.py` commands you ran.

---

---

## 3. Without a board: simulation & offline MNIST

Everything except the physical array runs on your laptop.

**The instruction-stream core** (needs Verilator):
```bash
make isa-test                 # reference model checks, then the RTL vs the model word for word, at N = 8 and 4
make isa-selftest-sim         # the DE1-SoC self-test ROM in Verilator, as the FPGA will run it
make -C software/mnist/de1soc data sim-bench   # MNIST's ARM program, built for the Mac, against Verilator
```

**The legacy core's test suite** (needs only Icarus Verilog):
```bash
make test                    # build + run the testbench suite, pass/fail summary table
./run_tests.sh fifo mmu      # ...or just a subset, without make
```

**Classify real MNIST digits in pure numpy**, with the exact same fixed-point math
the hardware does — no board, no FPGA toolchain:
```bash
python3 software/mnist/infer.py --offline --test-n 200
python3 software/mnist/draw_demo.py --offline          # the drawing demo works offline too
```

**Simulate the whole chip through its real UART pins**, at the hardware's actual
12 MHz / 1 Mbaud ratio (needs Verilator):
```bash
make verilate-test
```

Have hardware later? The same test vectors run against silicon via `make hw-test`,
so a passing sim is a genuine predictor.

**Drive a simulated TPU with the real host driver.** `make sim-bridge` builds the
Verilator model as a transport, and every host tool that takes `--link sim` talks
to it exactly as it would to a board:
```bash
make sim-bridge                                   # 8x8 array, M_TILE=4, PSUM_WIDTH=32
python3 tests/hw/hw_regression.py --link sim --port sim/verilator/bridge/tb_tpu_top \
    --rows 8 --cols 8 --m-tile 4 --psum-width 32
```

**Run a transformer on it.** TinyStories-1M with every linear layer on the
simulated array (see [`software/llm/README.md`](software/llm/README.md); ~48 MB download):
```bash
./software/llm/fetch.sh
python3 software/llm/infer.py --link sim --port sim/verilator/bridge/tb_tpu_top \
    --prompt "Once upon a time" -n 20
```

### 3.1 Simulation workflow reference

**Prerequisites** — Icarus Verilog (`iverilog`/`vvp`), plus `gtkwave` for
waveforms. `make lint` / `make verilate-test` additionally need **Verilator**, and
the `pe_pair`/4x4 tests extract their `SB_MAC16` model from an installed **Yosys**
(so yosys is required even for pure simulation of the DSP-pair path).

**Per-testbench commands** — every testbench gets a matching `build-`, `test-`, and
`wave-` target. RTL dependencies are resolved automatically.
```bash
make build-<name>    # compile one testbench to sim/<name>.vvp (e.g. make build-mmu)
make test-<name>     # build (if stale) + run it, log to sim/logs/, dump VCD to sim/
make wave-<name>     # run it, then open its VCD in gtkwave
```

**Other targets:**
```bash
make lint      # protocol-constant check, then verilator --lint-only -Wall over each
               #   board's file set (audited waivers live in verilator.vlt, each with
               #   a comment saying why)
make verilate-test
               # Verilator C++ full-chip testbench (tests/verilator/): drives
               #   tpu_top through its real host pins (UART at the hardware's
               #   12 MHz / 1 Mbaud ratio, and real SPI) across twelve
               #   shape/PHY/width combinations -- 2x2, 2x4, 4x2/M_TILE=3, the
               #   two 4x4 SB_MAC16-pair SPI builds, 8x8, three PSUM_WIDTH=32
               #   builds, and two direct byte-injection shapes -- replaying
               #   the hw_regression.py vector set plus a UART framing-error
               #   injection only sim can do
make sim-bridge
               # build the Verilator model as a --link sim transport
               #   (SIM_ROWS/SIM_COLS/SIM_MTILE/SIM_PSUM pick the shape)
make list      # print every registered test name and its available targets
make clean     # remove sim/ (compiled binaries, logs, waveform dumps)
make hw-test PORT=/dev/cu.usbmodemXXXX [CONFIG=<name> | ARRAY_ROWS=2 NUM_COLS=2 M_TILE=2 LINK=uart]
make host-flags CONFIG=<name>
               # print the host flags matching a named config
               # real-hardware regression (§2.7); PORT is required, and the shape
               # flags must match the flashed bitstream's build knobs
```

---

## 4. How the design works

The TPUv1 keeps weights stationary inside the matrix unit and streams activations
through it, so weights (reused many times) are never re-fetched between uses.
Here are its blocks as the instruction-stream core builds them, and how data
moves:

- **Host interface.** In the TPUv1, PCIe to a host and DDR3 for weights. Here
  it's a 12-register Avalon-MM bridge (`isa_bridge`) on the DE1-SoC's
  lightweight HPS→FPGA bridge. The board's ARM pushes 64-bit instructions and
  32-bit data words into FIFOs and reads results from an out FIFO.
- **Instructions and the dispatcher.** The TPUv1 runs a short CISC program;
  here it's 64-bit instructions (`WR_WMEM`, `WR_UB`, `MATMUL`, `ACTIVATE`,
  `WAIT`, `SIGNAL`, …). The dispatcher decodes and range-checks each one and
  queues it to one of four engines that run concurrently. `WAIT` orders the
  engines where data flows between them; `SIGNAL` fences the program and
  raises `DONE`.
- **Weight memory and fetcher (WT).** All of a network's weights live on chip
  in WMEM. The WT engine streams the next weight tile into a two-slot buffer
  while the current one computes.
- **Unified Buffer.** On-chip activations. As in the TPUv1, a layer's output
  is written back here and becomes the next layer's input without leaving the
  chip, so the host sends only the network input and reads only the final
  scores.
- **Systolic data setup.** Skews each activation row in time (element *i*
  delayed *i* cycles), so it enters the array as a diagonal wavefront.
- **Matrix unit.** An N×N grid of PEs (8×8 on the board), each multiplying its
  stationary weight by the passing activation and adding into the partial sum
  from above. Each PE also holds the *next* tile's weight; the first
  activation of a tile carries a flip bit that swaps it in on exactly the
  right cycle, so tiles run back to back.
- **Accumulators.** De-skew the array's column outputs back into rows, and add
  into a 32-bit ACC memory (read-modify-write), summing a large reduction
  across tiles.
- **Activation.** Bias, ReLU, then a hardware **requantizer** (saturate,
  multiply by a 24-bit scale, round, shift, clamp) that turns 32-bit sums into
  the next layer's int8 input.

The [legacy core](docs/architecture.md) has the same datapath, but driven by
framed byte commands through one serial sequencer: weights are re-sent for
every tile, layers return to the host to be requantized, and each tile loads,
computes and drains before the next. [`docs/utilization.md`](docs/utilization.md)
measured what that costs.

The instruction set, register map, memory layouts and overlap scheme are in
[`docs/isa.md`](docs/isa.md).

---

## 5. Repo layout

```
TPU/
├── rtl/
│   ├── isa/           the instruction-stream core: dispatcher, LD/WT/MM/ACT engines, PE + array
│   ├── core/          the legacy core (datapath + sequencer); fifo + systolic_data_setup shared
│   └── peripherals/   host interfaces: isa_bridge, UART, SPI slave, legacy HPS bridge
├── boards/
│   ├── de1soc/        top/ (tpu_isa_top, the self-test top, isa_replay, hex_display) ·
│   │                  fpga/ (selftest/, hps/ = GHRD integration) · sw/ (ARM: isa_mmio, setbaud)
│   └── pico2-ice/     top/ · fpga/ (yosys/nextpnr) · firmware/ (RP2350; pico-ice-sdk submodule)
├── host/              the `tpu` Python package: ISA encoder, reference model, compiler,
│                      WAIT checker, device + board-console links; and the legacy driver
├── tests/
│   ├── isa/           the instruction-stream model + RTL suites (sim, or on the board)
│   ├── sv/            23 Icarus testbenches for the legacy core (make test)
│   ├── verilator/     C++ benches: tb_isa, tb_isa_selftest, legacy tb_tpu_top
│   └── hw/            the legacy hw_regression.py (make hw-test)
├── software/
│   ├── mnist/         144→64→10 MLP: train, infer, draw demo; de1soc/ = the ARM program
│   └── llm/           TinyStories-1M transformer on the legacy array (sim)
├── docs/              design reference — start at docs/README.md
├── mk/                the Makefile's rules, split by tier
├── tpu_host.py        legacy CLI wrapper: `python3 tpu_host.py` = `python3 -m tpu`
└── Makefile, run_tests.sh, verilator.vlt, requirements.txt
```

`rtl/` holds only what every board shares; anything specific to one board (its
top level, pins, build flow, firmware or ARM programs) lives under
`boards/<board>/`. [`docs/repo-map.md`](docs/repo-map.md) has every file.

---

## 6. FPGA build reference

### 6.1 DE1-SoC (Cyclone V) — the active target

| Command | Where | Does |
|---|---|---|
| `make isa-test` / `make isa-lint` | Mac | the core vs its reference model (N = 8 and 4) / Verilator lint |
| `make isa-selftest-rom` / `isa-selftest-sim` | Mac | generate the self-test ROM / run it in Verilator (`ISA_ST_SLOTS=21` prints the perf captures) |
| `make -C boards/de1soc/fpga/selftest` | VM | the FPGA-only self-test bitstream (`output_files/tpu_isa_selftest.rbf`) |
| `make -C boards/de1soc/fpga/hps CD_ZIP=…` | VM | Terasic's GHRD + the TPU + `hex_pio` → `build/soc_system.rbf`, plus `build/isa_mmio` and `build/setbaud` |
| `make -C software/mnist/de1soc data` / `arm` / `sim-bench` | Mac / VM / Mac | MNIST model + test data / the ARM program / the ARM program against Verilator |

The array size is `N` on `tpu_isa_top` (8 in both builds; set in
`tpu_isa_selftest.sv` and `boards/de1soc/fpga/hps/tpu_isa_hw.tcl`), with the
memory depths beside it. 8×8 uses 78 of the Cyclone V's 87 DSP blocks, so a
bigger array needs DSP packing; see [`docs/backlog.md`](docs/backlog.md).
Measured fit and timing: [`docs/de1soc.md`](docs/de1soc.md) §1.

Board files can be updated without moving the SD card:
`tpu.isa_device.BoardConsole(port).upload(local, remote)` copies a file over
the console at 1.5625 Mbaud and checks its MD5.

### 6.2 pico2-ice (iCE40UP5K) — legacy, hardware-validated

A parameterized `ARRAY_ROWS × NUM_COLS` systolic array (default 2×2;
hardware-validated at 2×2, 2×4, and 4×4 — 2×4 puts one PE on each of the UP5K's
8 `SB_MAC16` DSP blocks, 4×4 puts *two* PEs on each via `boards/pico2-ice/top/pe_pair.sv`'s
dual-8×8 mode) runs the full datapath (UART RX → sequencer →
weight FIFO → unified buffer → systolic data setup → MMU → accumulator → bias →
ReLU → UART TX) on real silicon.

**iCE40 make targets** (run from `boards/pico2-ice/fpga/`; the yosys →
nextpnr-ice40 → icepack flow, staged so each intermediate can be inspected):
```bash
make            # full build to tpu_top.bin (equivalent to make bin)
make json       # synthesize only, up to tpu_top.json (yosys, with -dsp)
make asc        # place & route only, up to tpu_top.asc (nextpnr-ice40)
make bin        # pack only, up to tpu_top.bin (icepack)
make stat       # yosys post-synth cell/LUT/FF-type breakdown
make util       # nextpnr device utilisation (LCs, DSPs, BRAM, IO vs. the UP5K's budget)
make time       # icetime static timing report (post-PnR fMax vs. the clock constraint)
make prog       # flash tpu_top.bin over USB DFU (board in normal run mode; ignore
                #   dfu-util's "firmware corrupt" message -- known false alarm)
make clean      # remove tpu_top.json/.asc/.bin
```

**Named configurations** (`boards/pico2-ice/configs/`) set every knob at once, one
per build that has been validated on hardware:

| Config | Shape | Link, core clock | Firmware | Measured |
|---|---|---|---|---|
| `2x2_uart` | 2×2, M_TILE=2 | UART 1 Mbaud, 12 MHz | `build/` | default; ~316 ms/image |
| `2x4_uart` | 2×4, M_TILE=2 | UART 1 Mbaud, 12 MHz | `build/` | ~240 ms/image |
| `2x4_spi` | 2×4, M_TILE=2 | SPI, 24 MHz | `build-spi/` | 64.1 ms/image (offload) |
| `4x4m2_spi` | 4×4, M_TILE=2, `pe_pair` | SPI, 24 MHz | `build-spi/` | 63.8 ms/image — fastest single-image |
| `4x4_spi` | 4×4, M_TILE=4, `pe_pair` | SPI, 24 MHz | `build-spi/` | 80.3 ms/image single; the batching shape |

```bash
make CONFIG=4x4m2_spi && make prog CONFIG=4x4m2_spi
make show-config CONFIG=4x4m2_spi       # the knobs, the firmware it needs, the host flags
```
Switching config rebuilds automatically — a settings stamp stops a bitstream
from a previous config being reused.

**Build knobs** (set individually, or on top of a `CONFIG`; all `chparam`'d into the
bitstream at synthesis time — the matching host-side flags must agree, see
`tpu_host.py --help`):
```bash
make CLK_FREQ=12000000        # must match boards/pico2-ice/firmware/main.c's ice_fpga_init() request
make BAUD_RATE=1000000        # must match tpu_host.py's --baud (default 1M, exact /12 of 12 MHz)
make ARRAY_ROWS=2 NUM_COLS=4 M_TILE=2   # array shape; hosts then need --rows/--cols/--m-tile
                                        #   (ARRAY_ROWS and M_TILE <= 4 unless FIFO_DEPTH is
                                        #   raised in boards/pico2-ice/top/tpu_top.sv)
make PSUM_WIDTH=32                      # accumulate/bias/result width (default 16); hosts need
                                        #   --psum-width. Not usable with USE_MAC16_PAIR=1, and
                                        #   no bitstream has been built with it yet
make USE_SPI=1 CLK_FREQ=24000000        # SPI host link (rtl/peripherals/spi_slave.sv) on the RP2350<->iCE40
                                        #   config bus instead of the UART; pair with the
                                        #   TPU_LINK_SPI=ON firmware build and hosts' --link spi.
                                        #   24 MHz works because the SPI slave, unlike the UART,
                                        #   has no synthesis-baked baud divider (fMax ~32 MHz)
make USE_MAC16_PAIR=1 ARRAY_ROWS=4 NUM_COLS=4 M_TILE=2
                                        # build the MMU from boards/pico2-ice/top/pe_pair.sv (hand-instantiated
                                        #   SB_MAC16 in dual-8x8 mode: two PEs per DSP, so 16 PEs
                                        #   fit on the UP5K's 8 blocks). Requires even ARRAY_ROWS;
                                        #   -dsp is dropped automatically (nothing left to infer)
```

**The fastest configuration** (4×4 array over SPI, ~63.8 ms/image on MNIST) needs
all three sides rebuilt and reflashed together:
```bash
# 1. Firmware, with the SPI bridge compiled in (separate build dir keeps the UART one intact)
cd boards/pico2-ice/firmware && mkdir -p build-spi && cd build-spi
cmake -DPICO_BOARD=pico2_ice -DPICO_PLATFORM=rp2350-riscv \
      -DPICO_GCC_TRIPLE=riscv64-unknown-elf -DTPU_LINK_SPI=ON -G Ninja ..
ninja                                  # then flash pico2_ice_bridge.uf2 as in §2.4

# 2. Gateware, matching link + clock + shape
cd ../../fpga && make CONFIG=4x4m2_spi && make prog CONFIG=4x4m2_spi

# 3. Host, matching all three
cd ../../.. && python3 software/mnist/infer.py --port /dev/cu.usbmodemXXXX \
     --link spi --rows 4 --cols 4 --m-tile 2 --test-n 20
make hw-test CONFIG=4x4m2_spi PORT=/dev/cu.usbmodemXXXX
```
Keep the UART build around as a bisect fallback — if the SPI path misbehaves, reflashing
`make CONFIG=2x2_uart` gateware plus the `build/` firmware gets you back to a known-good state.

### 6.3 MNIST on the pico2-ice

Runs a trained+quantized 144→64→10 MLP through the real systolic array, tile
by tile, via `software/mnist/infer.py`'s `matmul_tiled()` driver (built on the K-dim
tiling in [`docs/architecture.md`](docs/architecture.md) §6; any layer shape works — non-multiples of the array size
are zero-padded on the wire and sliced off the result) — either against real
hardware or, with `--offline`, in pure numpy with no board at all.
`software/mnist/model/mnist_2x2_int8.npz` is already trained and committed, so retraining
is entirely optional. All three scripts take `--rows/--cols/--m-tile` to match a
non-2×2 bitstream.

```bash
# Accuracy on real hardware, N random real MNIST test images end-to-end:
python3 software/mnist/infer.py --port /dev/cu.usbmodemXXXX --test-n 20

# Hardware vs. local numpy on the exact same images, side by side:
python3 software/mnist/infer.py --port /dev/cu.usbmodemXXXX --compare --test-n 20

# Interactive drawing demo (LED flips green->blue when inference completes):
python3 software/mnist/draw_demo.py --port /dev/cu.usbmodemXXXX --led-port /dev/cu.usbmodemYYYY

# (Optional) retrain + requantize — downloads MNIST (~11 MB, cached in software/mnist/data/,
# gitignored) and overwrites software/mnist/model/mnist_2x2_int8.npz:
python3 software/mnist/train_mnist.py
```

Per-image latency depends on the build: ~316 ms at the default 2×2 over 1 Mbaud
UART, ~240 ms at 2×4 over UART, ~64 ms at 2×4 over SPI with firmware offload, and
~63.8 ms at 4×4/M_TILE=2. (4×4/M_TILE=4 fits too, but measures *worse* on a single
image — 80.3 ms — because three of its four streamed activation rows are padding;
it wins once `infer.py` batches images. See [`docs/performance.md`](docs/performance.md).)

---

---

## 7. Current status and future work

- **DE1-SoC, hardware.** The instruction-stream core (8×8, 50 MHz) passes:
  - its FPGA-only self-test, with the per-tile cycle rate checked on chip;
  - the full `test_isa_rtl.py` suite run from the board's ARM: every decode
    error, random layers, MNIST, requantizer sweeps, and random concurrent
    programs;
  - MNIST end to end on the ARM: **97.50% over 10,000 images, every
    prediction equal to the reference model, 109.5 µs/image** (77.6 µs
    batched).

  The drawing demo shows the digit on HEX0 with a 7.5 ms round trip from the
  Mac. Timing closes at 50 MHz (Fmax 57.9 MHz). See
  [`docs/de1soc.md`](docs/de1soc.md).
- **The instruction-stream core in simulation.** The RTL matches the reference
  model word for word at N = 8 and 4 (`make isa-test`), including 400 random
  concurrent programs per size. Each tile costs exactly `max(m, N)` cycles
  with no steady-state stalls, so the array is fed every cycle at m ≥ N. The
  legacy core fed it 9–16% of the time, and its 49-cycle 8×8 pass is 8 cycles
  here.
- **The pico2-ice (legacy, no longer developed).** Hardware-validated at 2×2,
  2×4 and 4×4 (`make hw-test` 14/14 each).
  - **MNIST latency:** 8.0 s → **63.8 ms/image (125×)** over seven measured
    steps, from batched wire commands to an RP2350-offloaded tiling loop.
  - **Accuracy:** 19/20 on a hardware sample.
  - **4×4 fit:** 16 PEs on the UP5K's 8 DSP blocks, via hand-instantiated
    dual-8×8 `SB_MAC16`.
  - **Transformer:** TinyStories-1M runs with every linear layer on the
    simulated array (`PSUM_WIDTH=32`, sim only).

  See [`docs/performance.md`](docs/performance.md).
- **Simulation of the legacy core.** 23 SystemVerilog testbenches, lint-clean
  across 5 configurations, and a full-chip Verilator suite across 12
  shape/PHY/width combinations.
- **Next** ([`docs/backlog.md`](docs/backlog.md)):
  - one core, by moving the instruction-stream core into `rtl/core/` and
    retiring the legacy one;
  - faster ARM preprocessing and fewer bridge accesses, which together make up
    most of the 109.5 µs;
  - a 16×16 array;
  - DDR3, spec phase 5;
  - the transformer on the new core;
  - Ethernet on the rev H board's Linux image.

---

## 8. Contributing

Contributions — bug fixes, new testbenches, board ports, docs — are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) for development setup, the local quality gates
(`make test` / `make lint` / `make verilate-test` — this project deliberately uses
no hosted CI), how to register a new testbench, and the RTL house style.

Questions and issues are welcome too, especially bring-up problems §1.7 and §2.8 don't cover.

## 9. License

Released under the [MIT License](LICENSE) — © 2026 Murat Acar. You are free to
use, modify, and distribute this design; attribution is appreciated.
