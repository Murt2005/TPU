# Reverse-Engineering Google's TPUv1

Reimplementing the core datapath of Google's first-generation Tensor Processing Unit
(as described in *In-Datacenter Performance Analysis of a Tensor Processing Unit*)
as synthesizable SystemVerilog with a fully parameterized array shape: verified in
simulation (22 testbenches), and validated end-to-end on real hardware on a
[pico2-ice](https://pico2-ice.tinyvision.ai/) (iCE40UP5K) board over a UART or SPI
host link — including hardware-side K-dim matmul tiling, a batched wire protocol,
DSP-backed PEs, an RP2350-offloaded tiling loop, and a real-time MNIST digit
classification demo at ~64 ms/image on-silicon (125x down from the first working
bring-up).

**Where to start:**

| You have… | Go to |
|---|---|
| A pico2-ice board and want to run this on it | [§1 Quick start](#1-quick-start-on-a-pico2-ice) |
| No board (yet) — just want to see it work | [§2 Without a board](#2-without-a-board-simulation--offline-mnist) |
| Curiosity about how a TPU actually works | [§3 How the design works](#3-how-the-design-works) |
| A different FPGA, or want to change the array shape | [§5 FPGA build reference](#5-fpga-build-reference) |

---

## 1. Quick start on a pico2-ice

By the end of this section you'll have a systolic array running on real silicon,
classifying hand-drawn MNIST digits. Budget ~30 minutes the first time, most of
it toolchain installation.

### 1.1 The one thing to understand first

pico2-ice is **two chips**, and the FPGA is a peripheral of the microcontroller:

```
   Your PC  ──USB──►  RP2350 (MCU)  ──►  iCE40UP5K (FPGA)
                        │  exports the FPGA's CLOCK (it has no crystal)
                        │  pushes the FPGA's BITSTREAM (USB-DFU)
                        │  bridges your bytes to the FPGA's UART pins
                        └  drives the onboard LED
```

Three consequences that will save you an evening of debugging:

- **You flash two separate things**: firmware onto the RP2350 (§1.4, once), and
  gateware onto the iCE40 (§1.5, every time you change the RTL). **Firmware
  first** — the DFU interface that accepts the bitstream lives *in* the firmware.
- **The FPGA's clock frequency is chosen by the firmware**, and the UART's baud
  divider is baked into the bitstream at synthesis time against that same number.
  If you change one, change both. The defaults here already agree (12 MHz / 1 Mbaud).
- **The board exposes two identical-looking USB serial ports.** One talks to the
  FPGA, one doesn't. You'll pick the right one by trial in §1.6.

### 1.2 Get the code

The RP2350 SDK is a git submodule, so clone recursively:

```bash
git clone --recurse-submodules https://github.com/Murt2005/TPU.git
cd TPU
```

Already cloned without it? `git submodule update --init --recursive`

### 1.3 Install the toolchain

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
sudo apt install gcc-arm-none-eabi     # RP2350 compiler (ARM path, see §1.4)
```
If your distro's yosys/nextpnr packages are old, the prebuilt
[oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build/releases) bundle is
the easiest fix — it ships all of the above in one tarball.

**Python host driver** (needs Python 3.11+):
```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt          # pyserial, numpy
```
> ⚠️ Create the venv in `.venv/`, **not** the repo root. `venv` writes a
> `.gitignore` containing `*` into its target directory, which would silently hide
> the entire repo from git.

Tested versions (other recent releases are likely fine): Yosys 0.63, Verilator
5.032, Icarus Verilog 13.0, Python 3.13.

### 1.4 Build and flash the RP2350 firmware (once)

This is the USB↔UART bridge. You only ever redo this if you change something in
`firmware/` — pure RTL changes need only a gateware reflash.

```bash
cd firmware && mkdir -p build && cd build
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

### 1.5 Build and flash the gateware

```bash
cd fpga/ice40
make            # yosys -> nextpnr-ice40 -> icepack, produces tpu_top.bin
make prog       # flash it over USB-DFU (board in normal run mode, no button needed)
```

Two things to expect here:

- `dfu-util` prints **"Device's firmware is corrupt"** on every single flash. It is
  a known false alarm from an SDK bug (it reports a return value that's always
  falsy instead of polling the FPGA's `CDONE` pin). Ignore it.
- **Replug the board** afterwards, so the firmware's boot-time `CDONE` check re-runs
  against the new bitstream. The LED should now be **green** = FPGA configured and
  running. Red means it isn't — see §1.8.

This builds the default 2×2 array at 12 MHz / 1 Mbaud. Other shapes and the SPI
link are build knobs — see §5.1.

### 1.6 Find the board's serial port

```bash
python3 -c "import serial.tools.list_ports as p; [print(x) for x in p.comports()]"
```

You'll see two ports. On macOS both report the same product string (`pico-ice`), so
there's no reliable way to tell them apart programmatically:

- **`--port`** → the one bridged to the FPGA (`"iCE40 UART"`). On macOS, try the
  **higher-numbered** `/dev/cu.usbmodemN` first.
- **`--led-port`** → the other one (`"RP2040 logs"`), used only for the demo's LED
  feedback in §1.7. Entirely optional.

On Linux they're usually `/dev/ttyACM0` and `/dev/ttyACM1`.

Picked the wrong one? The host driver probes on connect and fails with an explicit
error rather than hanging — just try the other port.

### 1.7 Talk to it

Work up this ladder; each rung tells you something different if it fails.

```bash
# 1. One known-golden matmul vector, straight from the simulation test suite.
python3 tpu_host.py --port /dev/cu.usbmodemXXXX --selftest

# 2. The full hardware regression: every sim vector, int8/int16 boundary cases,
#    and a randomized multi-tile stress run, all against real silicon.
make hw-test PORT=/dev/cu.usbmodemXXXX

# 3. Real MNIST digits classified end-to-end on the array.
python3 mnist/infer.py --port /dev/cu.usbmodemXXXX --test-n 20

# 4. The fun one: draw a digit with your mouse, watch the board's LED flip
#    green -> blue as the on-chip inference completes.
python3 mnist/draw_demo.py --port /dev/cu.usbmodemXXXX --led-port /dev/cu.usbmodemYYYY
```

Step 3 runs a trained, quantized 144→64→10 MLP tile-by-tile through the physical
array — ~316 ms/image on this default 2×2 UART build (see §5.2 for the faster
configurations and §6 for where the time goes). The model is committed, so there's
nothing to train.

Step 4 needs `tkinter`; on Homebrew Python, `brew install python-tk` if
`import tkinter` fails. `--led-port` is optional.

> **Built a non-default array shape?** Every host-side tool takes matching
> `--rows` / `--cols` / `--m-tile` flags, and `make hw-test` takes
> `ARRAY_ROWS=` / `NUM_COLS=` / `M_TILE=`. They must agree with what the bitstream
> was built with, or the driver will refuse to run. `tpu_host.py --help` lists them all.

### 1.8 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| LED red after flashing gateware | FPGA didn't configure | Replug the board so the boot-time `CDONE` check re-runs; confirm `make prog` actually completed |
| `dfu-util`: *"Device's firmware is corrupt"* | Known SDK false alarm, printed on **every** flash | Ignore it; trust the LED |
| Nothing responds on either port | Firmware not flashed, or FPGA not configured | `dfu-util -l` should list two DFU alt interfaces; check LED is green |
| Board responds, but data is **garbled** (not absent) | `CLK_FREQ` in `fpga/ice40/Makefile` ≠ `ice_fpga_init()` in `firmware/main.c` — the baud divider is baked in at synthesis | Change both together, reflash both images |
| Selftest fails with a shape mismatch error | Host flags don't match the flashed bitstream | Pass `--rows/--cols/--m-tile` matching your build knobs |
| Both serial ports look identical | macOS shows the USB product string, not per-interface descriptions | Trial and error; higher-numbered port first |
| `make time`: *"Can't find chipdb file"* | Some Homebrew icestorm installs can't resolve `-d up5k` | `make time ICETIME_CHIPDB=$(brew --prefix icestorm)/share/icestorm/chipdb/chipdb-5k.txt` |
| Long commands lose their tail; short ones are fine | You're on stock SDK bridge code | This repo's `firmware/main.c` already fixes it (blocking CDC→UART write) — make sure you flashed *this* firmware |

Still stuck? Open an issue — please include your LED state, the output of
`dfu-util -l`, and the exact `make`/`tpu_host.py` commands you ran.

---

## 2. Without a board: simulation & offline MNIST

Everything except the physical array runs on your laptop.

**Run the full test suite** (needs only Icarus Verilog):
```bash
make test                    # build + run all 22 testbenches, pass/fail summary table
./run_tests.sh fifo mmu      # ...or just a subset, without make
```

**Classify real MNIST digits in pure numpy**, with the exact same fixed-point math
the hardware does — no board, no FPGA toolchain:
```bash
python3 mnist/infer.py --offline --test-n 200
python3 mnist/draw_demo.py --offline          # the drawing demo works offline too
```

**Simulate the whole chip through its real UART pins**, at the hardware's actual
12 MHz / 1 Mbaud ratio (needs Verilator):
```bash
make verilate-test
```

Have hardware later? The same test vectors run against silicon via `make hw-test`,
so a passing sim is a genuine predictor.

### 2.1 Simulation workflow reference

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
make lint      # verilator --lint-only -Wall over all of rtl/ (audited waivers
               #   live in verilator.vlt, each with a comment saying why)
make verilate-test
               # Verilator C++ full-chip testbench (tests/verilator/): drives
               #   tpu_top through its real UART pins at the hardware's
               #   12 MHz / 1 Mbaud ratio, at three array shapes (2x2, 2x4,
               #   and 4x2/M_TILE=3), replaying the hw_regression.py vector
               #   set plus a UART framing-error injection only sim can do
make list      # print every registered test name and its available targets
make clean     # remove sim/ (compiled binaries, logs, waveform dumps)
make hw-test PORT=/dev/cu.usbmodemXXXX [ARRAY_ROWS=2] [NUM_COLS=2] [M_TILE=2] [LINK=uart]
               # real-hardware regression (§1.7); PORT is required, and the shape
               # flags must match the flashed bitstream's build knobs
```

---

## 3. How the design works

The TPUv1 is designed around the idea of keeping weights stationary inside the
MMU and streaming activations through it, so weights
(which are reused many times) never have to be re-fetched from memory between uses.
Here are the major blocks, and how data moves between them:

- **Host I/O** — in the original TPUv1, a PCIe link to the host and DDR3 channels. In
  this implementation, a UART over two GPIO pins (1 Mbaud by default — a synthesis-time
  knob, see §5.1) replaces the PCIe/DDR path. `tpu_host.py` is the Python driver that
  sends weights/activations from the PC and reads back results.
- **Weight FIFO (weight fetcher)** — in the original TPUv1, pulls weight tiles from DRAM.
  Here, weights are streamed over UART and pushed directly into the shadow bank of the
  Weight FIFO, then swapped in before each tile's compute phase.
- **Unified Buffer** — on-chip SRAM holding activations: the layer's input matrix
  going in, and the new layer output coming back in from the activation pipeline.
  This is also what makes multi-layer networks possible — layer *N*'s output becomes
  layer *N+1*'s input without ever leaving the chip.
- **Systolic Data Setup** — reads an activation vector out of the Unified Buffer,
  rotates and skews it, and streams it into the MMU from the left.
- **Matrix Multiply Unit (MXU)** — the systolic array of PEs itself. Each PE holds one
  weight value, multiplies it against a streaming activation, and accumulates a
  partial sum that gets passed to the PE below it.
- **Accumulators** — collect the staggered partial sums exiting the bottom of the
  array, de-skew them back into a proper matrix, and — critically — sum across
  multiple passes when the real weight matrix is larger than the array itself (tiling).
- **Bias unit → Activation unit → Normalize/Pool** — post-processing applied to each
  accumulated output before it's written back into the Unified Buffer as the next
  layer's input.
- **Control / instruction buffer** — sequences all of the above (when to load weights,
  when to stream activations, which tile is active) instead of a testbench wiggling
  signals by hand.

---

## 4. Repo layout

```
TPU/
├── README.md
├── Makefile                    # RTL sim automation (make test, make hw-test, ...)
├── run_tests.sh
├── requirements.txt             # tpu_host.py deps: pyserial, numpy
├── tpu_host.py                  # host-side driver + CLI (UART / SPI / HPS links)
├── rtl/                         # synthesizable SystemVerilog datapath + control plane
│   ├── pe.sv
│   ├── mmu.sv
│   ├── fifo.sv
│   ├── weight_fifo.sv
│   ├── systolic_data_setup.sv
│   ├── accumulator.sv
│   ├── bias.sv
│   ├── activation.sv
│   ├── unified_buffer.sv
│   ├── uart_rx.sv
│   ├── uart_tx.sv
│   ├── spi_slave.sv             # optional faster host PHY (see §5.1)
│   ├── tpu_sequencer.sv         # wire command protocol + pipeline orchestration
│   ├── tpu_core.sv              # board-neutral datapath + sequencer
│   └── tpu_top.sv               # pico2-ice top level: PHY + power-on reset + pins
├── verilator.vlt                # audited lint waivers for `make lint`
├── tests/                       # SystemVerilog testbenches (simulation)
│   ├── *_tb.sv                  # unit + integration tbs, incl. tpu_sequencer_{4x2,2x4}_tb.sv
│   │                            #   proving the parameterized sequencer at non-2x2 shapes
│   ├── verilator/               # C++ full-chip testbench (`make verilate-test`)
│   └── hw_regression.py         # real-hardware regression suite (§1.7)
├── sim/                         # simulation build output (gitignored)
├── fpga/                          # per-board FPGA build targets (dispatcher Makefile)
│   ├── ice40/                     # pico2-ice (iCE40UP5K): yosys/nextpnr-ice40/icepack, §5.1
│   └── de1soc/                    # DE1-SoC (Cyclone V): Quartus + HPS bridge (scaffolding)
├── firmware/                      # RP2350 firmware: USB-CDC <-> FPGA UART bridge (§1.4)
│   └── pico-ice-sdk/              # vendored SDK, git submodule
└── mnist/
    ├── train_mnist.py           # trains + quantizes the 144->64->10 MLP
    ├── infer.py                 # multi-layer tiled inference driver (hardware + offline)
    ├── draw_demo.py             # interactive drawing demo, LED feedback
    ├── model/mnist_2x2_int8.npz # quantized weights (committed, ~5KB)
    └── data/                    # downloaded MNIST idx files, gitignored
```

---

## 5. FPGA build reference

### 5.1 pico2-ice (iCE40UP5K) — bring-up complete, hardware-validated

A parameterized `ARRAY_ROWS × NUM_COLS` systolic array (default 2×2;
hardware-validated at 2×2 and 2×4, the latter with all 8 of the UP5K's `SB_MAC16`
DSP blocks backing the PEs) runs the full datapath (UART RX → sequencer →
weight FIFO → unified buffer → systolic data setup → MMU → accumulator → bias →
ReLU → UART TX) on real silicon.

**iCE40 make targets** (run from `fpga/ice40/`, or via the dispatcher as
`make -C fpga ice40 TARGET=<target>`; the yosys → nextpnr-ice40 → icepack flow,
staged so each intermediate can be inspected):
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

**Build knobs** (accepted by every target above; all `chparam`'d into the
bitstream at synthesis time — the matching host-side flags must agree, see
`tpu_host.py --help`):
```bash
make CLK_FREQ=12000000        # must match firmware/main.c's ice_fpga_init() request
make BAUD_RATE=1000000        # must match tpu_host.py's --baud (default 1M, exact /12 of 12 MHz)
make ARRAY_ROWS=2 NUM_COLS=4 M_TILE=2   # array shape; hosts then need --rows/--cols/--m-tile
make USE_SPI=1 CLK_FREQ=24000000        # SPI host link (rtl/spi_slave.sv) on the RP2350<->iCE40
                                        #   config bus instead of the UART; pair with the
                                        #   TPU_LINK_SPI=ON firmware build and hosts' --link spi.
                                        #   24 MHz works because the SPI slave, unlike the UART,
                                        #   has no synthesis-baked baud divider (fMax ~32 MHz)
```

**The fastest configuration** (2×4 array over SPI, ~64 ms/image on MNIST) needs
all three sides rebuilt and reflashed together:
```bash
# 1. Firmware, with the SPI bridge compiled in (separate build dir keeps the UART one intact)
cd firmware && mkdir -p build-spi && cd build-spi
cmake -DPICO_BOARD=pico2_ice -DPICO_PLATFORM=rp2350-riscv \
      -DPICO_GCC_TRIPLE=riscv64-unknown-elf -DTPU_LINK_SPI=ON -G Ninja ..
ninja                                  # then flash pico2_ice_bridge.uf2 as in §1.4

# 2. Gateware, matching link + clock + shape
cd ../../fpga/ice40 && make USE_SPI=1 CLK_FREQ=24000000 NUM_COLS=4 && make prog

# 3. Host, matching all three
python3 mnist/infer.py --port /dev/cu.usbmodemXXXX --link spi --cols 4 --test-n 20
```
Keep the UART build around as a bisect fallback — if the SPI path misbehaves, reflashing
the plain `make` gateware plus the `build/` firmware gets you back to a known-good state.

### 5.2 MNIST digit classification demo

Runs a trained+quantized 144→64→10 MLP through the real systolic array, tile
by tile, via `mnist/infer.py`'s `matmul_tiled()` driver (built on the K-dim
tiling from §5.1/§6; any layer shape works — non-multiples of the array size
are zero-padded on the wire and sliced off the result) — either against real
hardware or, with `--offline`, in pure numpy with no board at all.
`mnist/model/mnist_2x2_int8.npz` is already trained and committed, so retraining
is entirely optional. All three scripts take `--rows/--cols/--m-tile` to match a
non-2×2 bitstream.

```bash
# Accuracy on real hardware, N random real MNIST test images end-to-end:
python3 mnist/infer.py --port /dev/cu.usbmodemXXXX --test-n 20

# Hardware vs. local numpy on the exact same images, side by side:
python3 mnist/infer.py --port /dev/cu.usbmodemXXXX --compare --test-n 20

# Interactive drawing demo (LED flips green->blue when inference completes):
python3 mnist/draw_demo.py --port /dev/cu.usbmodemXXXX --led-port /dev/cu.usbmodemYYYY

# (Optional) retrain + requantize — downloads MNIST (~11 MB, cached in mnist/data/,
# gitignored) and overwrites mnist/model/mnist_2x2_int8.npz:
python3 mnist/train_mnist.py
```

Per-image latency depends on the build: ~316 ms at the default 2×2 over 1 Mbaud
UART, ~240 ms at 2×4 over UART, ~64 ms at 2×4 over SPI with firmware offload —
see §6's latency note for where the time actually goes.

---

## 6. Current status and future work

- **Simulation** — full datapath implemented and passing all 22 SystemVerilog
  testbenches (`make test`).
- **pico2-ice hardware** — bring-up complete; `tests/hw_regression.py` (`make hw-test`)
  replays every simulation test vector plus int8/int16 boundary cases and a randomized
  stress run against real silicon, at whatever array shape the bitstream was built with
  (validated at 2×2 and 2×4).
- **Parameterized array shape** — every module including the sequencer takes
  `ARRAY_ROWS`/`NUM_COLS`/`M_TILE`; the shape is a build knob (§5.1) threaded from
  `fpga/ice40/Makefile` through `tpu_host.py`. 2×4 (8 PEs, all DSP-backed, 67% of the UP5K's
  LUTs) is the largest shape that fits — 4×4 needs 16 multipliers against the chip's
  8 `SB_MAC16` blocks.
- **K-dim tiling** — `accumulator.sv` holds a persistent per-row PSUM register that
  survives across separate `RUN`s (`tile_first`/`tile_last` control, `pass_done` status),
  so a matmul with K larger than the array can be tiled into multiple weight-reload
  passes summed in hardware before bias/ReLU ever runs — see its header comment
  and the `RUN` command's optional `LEN=1` flags byte (`rtl/tpu_sequencer.sv`).
  Verified in sim (`accumulator_tb`, `tpu_core_tb` Test 8,
  `tpu_sequencer_tb` Test 7) and on real pico2-ice hardware (`tpu_host.py`'s
  `TPU.matmul_tiled()`, `tests/hw_regression.py`'s randomized multi-tile stress case).
- **Inference latency: 8.0 s → 64 ms/image (125x)** — measured on real hardware, in
  six stacked steps: batched wire commands (`CMD_RUN_TILE`, then `CMD_STREAM_RUN`
  streaming a whole K-run per round trip, 3.3x), `-dsp` synthesis (PE multiplies onto
  hard `SB_MAC16` blocks, ~7x fewer LUTs/PE), the UART at 1 Mbaud instead of 115200
  (7.8x), the 2×4 array (1.3x), replacing the UART with an SPI host link
  (`rtl/spi_slave.sv` + `TPU_LINK_SPI` firmware bridge) at a 24 MHz core clock
  (2.7x), and offloading the whole matmul tiling loop onto the RP2350
  (`firmware/tpu_tile.c`'s `FW_MATMUL` bulk command: one USB round trip per
  network layer instead of one per tile frame, 1.5x — bit-identical to the
  host-tiled path, A/B-verified in `tests/hw_regression.py`). The remaining
  budget is genuinely wire-bound: mostly SPI tile traffic at the CLK/6-capped
  4 MHz write clock, ~3% actual RTL compute.
- **MNIST** — `mnist/train_mnist.py` trains and quantizes a 144→64→10 MLP (12×12
  downsampled input, int8 weights/activations, int16 bias) sized and empirically
  verified against the accumulator's non-saturating int16 width (5% calibration
  safety margin, zero overflow across the full 10k-image test set); 97.50%
  quantized test accuracy in sim, 95.00% (19/20) on a real-hardware sample
  (`mnist/infer.py --port ... --test-n 20`), at ~64 ms/image end-to-end over the
  SPI link with firmware offload (see the latency bullet above).
- **Interactive demo** — `mnist/draw_demo.py`: draw a digit, classify it end-to-end on
  real pico2-ice silicon via `mnist/infer.py`'s multi-layer `matmul_tiled()` driver, with
  the board's LED flipping green→blue on completion (`firmware/main.c`'s LED command
  listener on the second, otherwise-idle USB-CDC port). `--offline` runs the same
  pipeline in pure numpy with no board attached.
- **Future work** — a bigger/better MNIST model (current one is deliberately tiny to
  stay provably inside the accumulator's int16 width — see `mnist/train_mnist.py`'s
  header comment); batching `M_TILE` images per inference call in `mnist/infer.py` so a
  single image stops wasting the padded activation rows; and wire-format ideas
  like packed instruction headers and int4 payload packing (the latter gated on
  a software-only accuracy experiment).
- **DE1-SoC (Cyclone V) target** — in progress. The board-neutral `tpu_core`,
  the HPS Avalon-MM bridge (`rtl/hps_bridge.sv` + `rtl/tpu_top_hps.sv`), and the
  memory-mapped host transport (`tpu_host.py --link hps`, driven over `/dev/mem`
  from the board's ARM Linux) are implemented and simulation-tested — including
  an 8×8 shape (64 PEs on generic-fabric multiply, well past the UP5K's 8-DSP
  ceiling; the iCE40-only `SB_MAC16` DSP-pair path drops to inferred DSPs on
  Cyclone V). The `fpga/de1soc/` Quartus build is scaffolded. Remaining steps:
  - **Cloud Quartus build.** Quartus has no macOS build, so the `.rbf` is
    produced on x86-64 Linux in AWS: an AWS CDK stack (S3 artifact bucket + an
    SSM-managed IAM instance profile, no SSH) plus an *ephemeral,
    self-terminating* EC2 build instance launched from a pre-baked Quartus AMI —
    spin up, `quartus_sh` compile, push the `.rbf` to S3, tear down (Spot to cut
    cost). The one-time Qsys/GHRD integration is baked into the AMI so per-build
    instances stay fully headless. See `fpga/de1soc/README.md` for the build and
    HPS-deploy runbook.
  - **On-board bring-up.** `scp` the `.rbf` to the board, let the ARM HPS
    configure the FPGA, then run `tests/hw_regression.py --link hps
    --port /dev/mem` *on the board* to validate the bridge end-to-end against
    the same vectors the sim and pico2-ice targets use.
  - **Scale up.** Once the flow is up, raise `ARRAY_ROWS`/`NUM_COLS` to the
    largest shape that closes timing at 50 MHz on the Cyclone V.

---

## 7. Contributing

Contributions — bug fixes, new testbenches, board ports, docs — are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) for development setup, the local quality gates
(`make test` / `make lint` / `make verilate-test` — this project deliberately uses
no hosted CI), how to register a new testbench, and the RTL house style.

Questions and issues are welcome too, especially bring-up problems §1.8 doesn't cover.

## 8. License

Released under the [MIT License](LICENSE) — © 2026 Murat Acar. You are free to
use, modify, and distribute this design; attribution is appreciated.
