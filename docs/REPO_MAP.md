# Repository Map

A file-by-file/folder-by-folder guide to this repo: a from-scratch
SystemVerilog reimplementation of Google's first-generation TPU, simulated
and validated on real pico2-ice (iCE40UP5K) hardware. For the architecture
and usage story, see the root [README.md](../README.md); for the FPGA/firmware
bring-up, see [FPGA.md](FPGA.md); for the sequencer/UART FSM design, see
[sequencer_uart_design.md](sequencer_uart_design.md).

## Root

- **`README.md`** — project overview: TPU architecture walkthrough, repo
  layout, simulation workflow, FPGA/hardware bring-up, and current status.
- **`Makefile`** — RTL simulation automation (`make test`, `make test-<name>`,
  `make wave-<name>`, `make hw-test`); single-sources the RTL dependency
  graph used by `run_tests.sh`.
- **`run_tests.sh`** — builds and runs every (or a named subset of) RTL
  testbench via the Makefile, printing a pass/fail summary; safe for CI.
- **`tpu_host.py`** — host-side Python driver/CLI implementing the UART wire
  protocol spoken by `rtl/tpu_sequencer.sv` (load weights/bias/activations,
  `RUN`, including K-dim tiled matmuls).
- **`requirements.txt`** — Python dependencies for `tpu_host.py` and the
  `mnist/` scripts (`pyserial`, `numpy`).
- **`.gitmodules`** — declares `firmware/pico-ice-sdk` as a git submodule
  pointing at tinyvision-ai-inc's `pico-ice-sdk`.
- **`.gitignore`** — excludes simulation build output, FPGA synthesis
  artifacts, downloaded MNIST data, and the in-place Python venv
  (`bin/`, `lib/`, `include/`, `pyvenv.cfg`, `__pycache__/`).

## Venv / build / cache folders (not documented further, per repo convention)

- **`bin/`, `lib/`, `include/`, `pyvenv.cfg`** — a Python virtual environment
  created directly in the project root (`python3 -m venv .`); gitignored,
  holds the Python interpreter shims and installed packages (numpy, pyserial,
  pip).
- **`__pycache__/`** (root and under `mnist/`) — compiled `.pyc` bytecode
  caches generated automatically by running the Python scripts; gitignored.

## `rtl/` — synthesizable SystemVerilog datapath + control plane

- **`pe.sv`** — a single processing element: multiplies a stationary weight
  against a streaming activation and accumulates/forwards a partial sum to
  the PE below it.
- **`mmu.sv`** — the 2×2 systolic array itself, instantiating four `pe`
  modules and handling weight-column capture during the loading phase.
- **`fifo.sv`** — a generic, reusable synchronous circular-queue FIFO with no
  awareness of the TPU datapath; used by `accumulator.sv` and
  `weight_fifo.sv`.
- **`weight_fifo.sv`** — double-buffered (ping-pong) weight store: drains the
  active bank into the MMU during the loading phase while the next weight
  matrix streams into the shadow bank.
- **`systolic_data_setup.sv`** — reads an activation vector out of the
  Unified Buffer, skews/staggers it in time, and streams it into the MMU
  from the left.
- **`accumulator.sv`** — reassembles the MMU's time-skewed per-column partial
  sums back into complete output rows, and sums across multiple `RUN`s when
  a matmul's K dimension is tiled beyond the array's size.
- **`bias.sv`** — adds a per-output-column stationary bias term to each
  accumulated row, one cycle downstream of the accumulator.
- **`activation.sv`** — applies ReLU element-wise to the bias unit's output;
  the final pipeline stage before results are written back.
- **`unified_buffer.sv`** — double-banked on-chip SRAM holding activations,
  letting one layer's output become the next layer's input without leaving
  the chip.
- **`uart_rx.sv`** — 8N1 UART receiver with 16x oversampling and mid-bit
  sampling, turning the raw serial pin into byte-wide `rx_data`/`rx_valid`
  pulses.
- **`uart_tx.sv`** — 8N1 UART transmitter, shifting out a byte (start bit,
  8 data bits LSB-first, stop bit) whenever `tx_valid` is pulsed.
- **`tpu_sequencer.sv`** — decodes the host's UART command protocol
  (`LOAD_WEIGHTS`/`LOAD_BIAS`/`LOAD_ACT`/`RUN`/`RESET`) and orchestrates the
  whole datapath pipeline in response.
- **`tpu_top.sv`** — FPGA top-level; wires the UART pair, sequencer, and every
  datapath module above together into the complete design that gets
  synthesized.

## `tests/` — SystemVerilog testbenches (simulation) + hardware regression

- **`fifo_tb.sv`**, **`pe_tb.sv`**, **`mmu_tb.sv`**, **`bias_tb.sv`**,
  **`activation_tb.sv`**, **`accumulator_tb.sv`**, **`unified_buffer_tb.sv`**,
  **`systolic_data_setup_tb.sv`**, **`weight_fifo_tb.sv`**,
  **`uart_rx_tb.sv`**, **`uart_tx_tb.sv`** —
  standalone unit testbenches for the like-named `rtl/` module.
- **`mmu_accum_tb.sv`**, **`accum_bias_tb.sv`**, **`bias_activation_tb.sv`**,
  **`weight_fifo_mmu_tb.sv`** — integration
  testbenches proving two adjacent pipeline stages compose correctly (e.g.
  accumulator→bias, weight_fifo→mmu).
- **`tpu_core_tb.sv`** — integration test of the full datapath minus the
  sequencer/UART (unified_buffer through activation).
- **`tpu_sequencer_tb.sv`** — end-to-end test of the UART command protocol
  driving the full pipeline via direct `rx_data`/`rx_valid` injection.
- **`hw_regression.py`** — Python regression suite that replays the
  simulation test vectors (plus int8/int16 boundary cases and a randomized
  stress run) against real pico2-ice hardware over `tpu_host.py`.

## `fpga/` — iCE40 build target (pico2-ice)

- **`Makefile`** — builds `tpu_top.sv` through the open-source
  yosys → nextpnr-ice40 → icepack toolchain into a flashable bitstream, and
  flashes it over USB-DFU (`make prog`).
- **`tpu_top.pcf`** — pin constraints mapping `tpu_top`'s ports to physical
  iCE40 package pins on the pico2-ice board.
- **`tpu_top.asc`**, **`tpu_top.json`** — generated intermediate
  place-and-route/synthesis artifacts (ASCII bitstream and yosys netlist
  JSON) committed alongside the final binary.
- **`tpu_top.bin`** — the final flashable FPGA bitstream produced by
  `icepack`.

## `firmware/` — RP2350 firmware: USB-CDC ↔ FPGA UART bridge

- **`README.md`** — detailed walkthrough of every file in this directory,
  why the firmware exists, and how to build it.
- **`main.c`** — the entire bridge program: brings up USB, exports a 12 MHz
  clock to the FPGA, loads its bitstream, bridges its UART pins to a
  USB-CDC port, and drives the onboard LED from the real `CDONE` signal.
  Also listens for a one-byte LED command on the second CDC port (used by
  the MNIST drawing demo).
- **`usb_descriptors.c`** — TinyUSB descriptor tables defining the composite
  USB device: two CDC-ACM ports (`"RP2040 logs"`, `"iCE40 UART"`) plus one
  DFU interface for bitstream flashing.
- **`tusb_config.h`** — TinyUSB stack configuration (CDC/DFU interface
  counts, buffer sizes) matching what `usb_descriptors.c` declares.
- **`CMakeLists.txt`** — build definition for the `pico2_ice_bridge`
  executable, pointing at the vendored `pico-ice-sdk`/`pico-sdk`.
- **`pico_sdk_import.cmake`** — unmodified standard `pico-sdk` CMake import
  boilerplate, included before `project()`.
- **`.gitignore`** — ignores this directory's own `build/` output.
- **`build/`** *(gitignored, not documented further)* — out-of-tree
  CMake/Ninja build directory producing `pico2_ice_bridge.uf2` and other
  build artifacts.
- **`pico-ice-sdk/`** *(git submodule, not documented further)* — vendored
  tinyvision-ai-inc pico-ice-sdk providing `ice_usb`/`ice_fpga`/`ice_led` and
  the underlying `pico-sdk`, pinned via `.gitmodules`.

## `mnist/` — MNIST digit classification demo

- **`train_mnist.py`** — trains and quantizes a 144→64→10 MLP (int8
  weights/activations, int16 bias) sized to stay inside the hardware
  accumulator's non-saturating int16 width, producing `model/mnist_2x2_int8.npz`.
- **`infer.py`** — multi-layer inference driver that feeds the trained model
  through the real TPU layer-by-layer via `tpu_host.py`'s tiled-matmul
  driver, with an offline pure-numpy backend for running without hardware
  (`--offline`), and a `--compare` mode that runs the identical sampled
  images through hardware and the local backend (one-at-a-time and
  batched/vectorized) side by side — see `docs/HARDWARE_COMPARISON.md`.
- **`draw_demo.py`** — interactive Tkinter drawing demo: draw a digit,
  classify it end-to-end on real pico2-ice silicon (or offline), with the
  board's LED flipping green→blue on completion.
- **`model/`** — holds the committed, pre-trained
  `mnist_2x2_int8.npz` quantized weights (~5 KB) used by `infer.py` and
  `draw_demo.py` out of the box.
- **`data/`** *(gitignored)* — downloaded MNIST IDX dataset files
  (train/test images and labels, ~11 MB), fetched on demand by
  `train_mnist.py`.
- **`__pycache__/`** *(gitignored, not documented further)* — compiled
  `.pyc` bytecode caches for this directory's scripts.

## `docs/` — design and bring-up documentation

- **`REPO_MAP.md`** — this file.
- **`FPGA.md`** — pico2-ice architecture overview, what every file under
  `fpga/`/`firmware/` is for, the full build/flash/validate runbook, and
  hardware bring-up gotchas.
- **`sequencer_uart_design.md`** — cycle-by-cycle FSM and timing writeup for
  `tpu_sequencer.sv`, `uart_rx.sv`, and `uart_tx.sv`.
- **`HARDWARE_COMPARISON.md`** — measured accuracy/latency comparing pico2-ice
  hardware against running the same model locally on a Mac (one-at-a-time
  and batched), plus a chip-level power/size/process comparison between the
  iCE40UP5K+RP2350B and an Apple M2 Pro.
- **`PERFORMANCE_ANALYSIS.md`** — measured breakdown of pico2-ice's per-image
  latency into UART wire time / RTL execution time / USB-software overhead;
  current iCE40UP5K LUT utilization (including an unused-DSP finding); and a
  concrete feasibility analysis (with pushback) for scaling the systolic
  array past 2×2.
