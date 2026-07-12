# Reverse-Engineering Google's TPUv1

Reimplementing the core datapath of Google's first-generation Tensor Processing Unit
(as described in *In-Datacenter Performance Analysis of a Tensor Processing Unit*)
as synthesizable SystemVerilog with a fully parameterized array shape: verified in
simulation (19 testbenches), and validated end-to-end on real hardware on a
[pico2-ice](https://pico2-ice.tinyvision.ai/) (iCE40UP5K) board over a 1 Mbaud UART —
including hardware-side K-dim matmul tiling, a batched wire protocol, DSP-backed PEs,
and a real-time MNIST digit classification demo at ~240 ms/image on-silicon
(33x down from the first working bring-up) — see §3.2 and §4.

## 1. TPU Design

The TPUv1 is designed around the idea of keeping weights stationary inside the
MMU and streaming activations through it, so weights
(which are reused many times) never have to be re-fetched from memory between uses.
Here are the major blocks, and how data moves between them:

- **Host I/O** — in the original TPUv1, a PCIe link to the host and DDR3 channels. In
  this implementation, a UART over two GPIO pins (1 Mbaud by default — a synthesis-time
  knob, see §3.1) replaces the PCIe/DDR path. `tpu_host.py` is the Python driver that
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

## 2. TPU

### Repo layout
```
TPU/
├── README.md
├── Makefile                    # RTL sim automation (make test, make hw-test, ...)
├── run_tests.sh
├── requirements.txt             # tpu_host.py deps: pyserial, numpy
├── tpu_host.py                  # host-side UART driver + CLI
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
│   ├── tpu_sequencer.sv         # UART command protocol + pipeline orchestration
│   └── tpu_top.sv               # top-level: wires the datapath + sequencer together
├── tests/                       # SystemVerilog testbenches (simulation)
│   ├── *_tb.sv                  # unit + integration tbs, incl. tpu_sequencer_{4x2,2x4}_tb.sv
│   │                            #   proving the parameterized sequencer at non-2x2 shapes
│   └── hw_regression.py         # real-hardware regression suite (see §3.1)
├── sim/                         # simulation build output (gitignored)
│   ├── *.vvp
│   ├── *.vcd
│   └── logs/
├── fpga/                          # iCE40 build target (yosys/nextpnr-ice40/icepack), see §3.1
├── firmware/                      # RP2350 firmware: USB-CDC <-> FPGA UART bridge
│   └── pico-ice-sdk/              # vendored SDK, git submodule -- see docs/FPGA.md §6
├── mnist/
│   ├── train_mnist.py            # trains + quantizes the 144->64->10 MLP
│   ├── infer.py                  # multi-layer tiled inference driver (hardware + offline backends)
│   ├── draw_demo.py              # interactive drawing demo, LED feedback
│   ├── model/mnist_2x2_int8.npz  # quantized weights (committed, ~5KB)
│   └── data/                     # downloaded MNIST idx files, gitignored
└── docs/
    ├── REPO_MAP.md               # file-by-file guide to this repo
    ├── FPGA.md                   # pico2-ice architecture + end-to-end build/flash/validate runbook
    ├── sequencer_uart_design.md  # tpu_sequencer/uart_rx/uart_tx FSM + timing writeup
    ├── SEQUENCER_REDESIGN.md     # sequencer parameterization + batched-protocol design & status log
    ├── HARDWARE_COMPARISON.md    # pico2-ice vs. local Mac: speed/accuracy/power/size, same model
    └── PERFORMANCE_ANALYSIS.md   # UART vs RTL time breakdown, LUT budget, array-scaling feasibility
```

### 2.1 Simulation workflow

**Prerequisites** — Icarus Verilog (`iverilog`/`vvp`), and `gtkwave` if you
want to open waveforms via `make wave-<name>`:
```bash
brew install icarus-verilog gtkwave     # macOS
sudo apt install iverilog gtkwave       # Debian/Ubuntu
```

**To run everything:**
```bash
make test            # build + run all 19 testbenches, print a pass/fail summary table
# or, equivalently and usable outside make:
./run_tests.sh
./run_tests.sh fifo mmu     # ...or just a subset
```

**Per-testbench commands** — every testbench gets a matching `build-`,
`test-`, and `wave-` target. RTL dependencies are resolved automatically.
```bash
make build-<name>    # compile one testbench to sim/<name>.vvp (e.g. make build-mmu)
make test-<name>     # build (if stale) + run it, log to sim/logs/, dump VCD to sim/
make wave-<name>     # run it, then open its VCD in gtkwave
```

**Other targets:**
```bash
make list      # print every registered test name and its available targets
make clean     # remove sim/ (compiled binaries, logs, waveform dumps)
make hw-test PORT=/dev/cu.usbmodemXXXX [ARRAY_ROWS=2] [NUM_COLS=2] [M_TILE=2]
               # real-hardware regression (see §3.1); PORT is required, and the
               # three shape flags must match the flashed bitstream's build knobs
               # (defaults match the default 2x2 build)
```

## 3. FPGA Targets

### 3.1 pico2-ice (iCE40UP5K) — bring-up complete, hardware-validated

A parameterized `ARRAY_ROWS × NUM_COLS` systolic array (default 2×2;
hardware-validated at 2×2 and 2×4, the latter with all 8 of the UP5K's `SB_MAC16`
DSP blocks backing the PEs) runs the full datapath (UART RX → sequencer →
weight FIFO → unified buffer → systolic data setup → MMU → accumulator → bias →
ReLU → UART TX) on real silicon. Architecture, code layout, build/flash/validate
steps, board gotchas, and the wire protocol are all in `docs/FPGA.md`; the
sequencer/UART FSM design and cycle-by-cycle timing are in
`docs/sequencer_uart_design.md`; the batched-protocol and array-scaling design
history is in `docs/SEQUENCER_REDESIGN.md`.

```bash
cd fpga && make && make prog             # build + flash the gateware (2x2, 1 Mbaud defaults)
python3 tpu_host.py --port /dev/cu.usbmodemXXXX --selftest
                                         # add --rows/--cols/--m-tile for a non-2x2 bitstream,
                                         # --baud for a non-1M one (see tpu_host.py --help)
make hw-test PORT=/dev/cu.usbmodemXXXX   # broader regression suite (see tests/hw_regression.py);
                                         # same shape rule: ARRAY_ROWS=/NUM_COLS=/M_TILE=
```

**`fpga/` make targets** (run from `fpga/`; the yosys → nextpnr-ice40 →
icepack flow, staged so each intermediate can be inspected):
```bash
make            # full build to tpu_top.bin (equivalent to make bin)
make json       # synthesize only, up to tpu_top.json (yosys, with -dsp)
make asc        # place & route only, up to tpu_top.asc (nextpnr-ice40)
make bin        # pack only, up to tpu_top.bin (icepack)
make stat       # yosys post-synth cell/LUT/FF-type breakdown
make util       # nextpnr device utilisation (LCs, DSPs, BRAM, IO vs. the UP5K's budget)
make time       # icetime static timing report (post-PnR fMax vs. the clock constraint)
make prog       # flash tpu_top.bin over USB DFU (board in normal run mode; ignore
                #   dfu-util's "firmware corrupt" message -- known false alarm, docs/FPGA.md §8.3)
make clean      # remove tpu_top.json/.asc/.bin
```
Build knobs (accepted by every target above; all `chparam`'d into the
bitstream at synthesis time — the matching host-side flags must agree, see
`tpu_host.py --help`):
```bash
make CLK_FREQ=12000000        # must match firmware/main.c's ice_fpga_init() request
make BAUD_RATE=1000000        # must match tpu_host.py's --baud (default 1M, exact /12 of 12 MHz)
make ARRAY_ROWS=2 NUM_COLS=4 M_TILE=2   # array shape; hosts then need --rows/--cols/--m-tile
```
If `make time` fails with "Can't find chipdb file" (some Homebrew icestorm
installs), point it at the file directly:
```bash
make time ICETIME_CHIPDB=$(brew --prefix icestorm)/share/icestorm/chipdb/chipdb-5k.txt
```

### 3.2 MNIST digit classification demo

Runs a trained+quantized 144→64→10 MLP through the real systolic array, tile
by tile, via `mnist/infer.py`'s `matmul_tiled()` driver (built on the K-dim
tiling from §3.1/§4; any layer shape works — non-multiples of the array size
are zero-padded on the wire and sliced off the result) — either against real
hardware or, with `--offline`, in pure numpy with no board at all.
`mnist/model/mnist_2x2_int8.npz` is already trained and committed, so steps
1–2 below are only needed if you want to retrain it. Both scripts below take
`--rows/--cols/--m-tile` to match a non-2×2 bitstream, same as `tpu_host.py`.

1. **(Optional) Retrain/requantize the model** — downloads MNIST (~11 MB,
   cached in `mnist/data/`, gitignored) and overwrites
   `mnist/model/mnist_2x2_int8.npz`:
   ```bash
   python3 mnist/train_mnist.py
   ```

2. **Board must already be flashed** — firmware + gateware, per §3.1 above
   (`docs/FPGA.md` §7 for the full runbook). Pure RTL/software changes here
   don't need a firmware reflash, just the gateware.

3. **Find the board's two USB-CDC ports**:
   ```bash
   python3 -c "import serial.tools.list_ports as p; [print(x) for x in p.comports()]"
   ```
   Both may show identically as `pico-ice` on macOS (see `docs/FPGA.md`
   §8.5) — try the higher-numbered `/dev/cu.usbmodemN` for `--port` (the
   TPU/"iCE40 UART" link) first; the other is `--led-port` ("RP2040 logs",
   used only for the demo's LED feedback in step 5).

4. **Sanity-check accuracy on real hardware** — classifies N random real
   MNIST test images end-to-end over UART (~240 ms/image measured at the
   2×4/1 Mbaud build, ~316 ms at the default 2×2 — see §4's latency note and
   `docs/PERFORMANCE_ANALYSIS.md` for where the time goes):
   ```bash
   python3 mnist/infer.py --port /dev/cu.usbmodemXXXX --test-n 20
   # flashed a non-default shape (e.g. make ARRAY_ROWS=2 NUM_COLS=4)? match it:
   python3 mnist/infer.py --port /dev/cu.usbmodemXXXX --test-n 20 --cols 4
   # no board handy? pure-numpy backend, same fixed-point math, no LED:
   python3 mnist/infer.py --offline --test-n 200
   # want both, on the exact same images, side by side (hardware vs local Mac,
   # one-at-a-time vs batched)? see docs/HARDWARE_COMPARISON.md:
   python3 mnist/infer.py --port /dev/cu.usbmodemXXXX --compare --test-n 20
   ```

5. **Launch the interactive drawing demo** — draw a digit, click Predict,
   watch the board's LED flip green→blue when the on-chip inference
   completes:
   ```bash
   python3 mnist/draw_demo.py --port /dev/cu.usbmodemXXXX --led-port /dev/cu.usbmodemYYYY
   # --led-port is optional (skips LED feedback); --offline works here too:
   python3 mnist/draw_demo.py --offline
   ```
   Needs `tkinter` (bundled with most Python installs; on macOS via
   Homebrew Python, `brew install python-tk` if `import tkinter` fails).


## 4. Current Status and Future Work

- **Simulation** — full datapath implemented and passing all 19 SystemVerilog
  testbenches (`make test`).
- **pico2-ice hardware** — bring-up complete; `tests/hw_regression.py` (`make hw-test`)
  replays every simulation test vector plus int8/int16 boundary cases and a randomized
  stress run against real silicon, at whatever array shape the bitstream was built with
  (validated at 2×2 and 2×4).
- **Parameterized array shape** — every module including the sequencer takes
  `ARRAY_ROWS`/`NUM_COLS`/`M_TILE`; the shape is a build knob (§3.1) threaded from
  `fpga/Makefile` through `tpu_host.py`. 2×4 (8 PEs, all DSP-backed, 67% of the UP5K's
  LUTs) is the largest shape that fits — 4×4 needs 16 multipliers against the chip's
  8 `SB_MAC16` blocks. See `docs/PERFORMANCE_ANALYSIS.md` §3.
- **K-dim tiling** — `accumulator.sv` holds a persistent per-row PSUM register that
  survives across separate `RUN`s (`tile_first`/`tile_last` control, `pass_done` status),
  so a matmul with K larger than the array can be tiled into multiple weight-reload
  passes summed in hardware before bias/ReLU ever runs — see its header comment and
  `docs/sequencer_uart_design.md` §3.2 for the wire-protocol side (`RUN`'s optional
  `LEN=1` flags byte). Verified in sim (`accumulator_tb`, `tpu_core_tb` Test 8,
  `tpu_sequencer_tb` Test 7) and on real pico2-ice hardware (`tpu_host.py`'s
  `TPU.matmul_tiled()`, `tests/hw_regression.py`'s randomized multi-tile stress case).
- **Inference latency: 8.0 s → 0.24 s/image (33x)** — measured on real hardware, in
  four stacked steps: batched wire commands (`CMD_RUN_TILE`, then `CMD_STREAM_RUN`
  streaming a whole K-run per round trip, 3.3x), `-dsp` synthesis (PE multiplies onto
  hard `SB_MAC16` blocks, ~7x fewer LUTs/PE), the UART at 1 Mbaud instead of 115200
  (7.8x), and the 2×4 array (1.3x). Remaining budget is ~66% UART wire time / ~33%
  USB+Python overhead / ~1% actual RTL compute — full measurement trail in
  `docs/PERFORMANCE_ANALYSIS.md` and `docs/SEQUENCER_REDESIGN.md`.
- **MNIST** — `mnist/train_mnist.py` trains and quantizes a 144→64→10 MLP (12×12
  downsampled input, int8 weights/activations, int16 bias) sized and empirically
  verified against the accumulator's non-saturating int16 width (5% calibration
  safety margin, zero overflow across the full 10k-image test set); 97.50%
  quantized test accuracy in sim, 95.00% (19/20) on a real-hardware sample
  (`mnist/infer.py --port ... --test-n 20`), at ~240 ms/image end-to-end over UART
  (see the latency bullet above).
- **Interactive demo** — `mnist/draw_demo.py`: draw a digit, classify it end-to-end on
  real pico2-ice silicon via `mnist/infer.py`'s multi-layer `matmul_tiled()` driver, with
  the board's LED flipping green→blue on completion (`firmware/main.c`'s LED command
  listener on the second, otherwise-idle USB-CDC port). `--offline` runs the same
  pipeline in pure numpy with no board attached.
- **Future work** — a bigger/better MNIST model (current one is deliberately tiny to
  stay provably inside the accumulator's int16 width — see `mnist/train_mnist.py`'s
  header comment); batching `M_TILE` images per inference call in `mnist/infer.py` so a
  single image stops wasting the padded activation rows; and the wire-format ideas in
  `docs/SEQUENCER_REDESIGN.md` §6 (packed instruction headers, int4 payload packing —
  the latter gated on a software-only accuracy experiment).
