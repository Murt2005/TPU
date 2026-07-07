# Reverse-Engineering Google's TPUv1

Reimplementing the core datapath of Google's first-generation Tensor Processing Unit
(as described in *In-Datacenter Performance Analysis of a Tensor Processing Unit*)
as synthesizable SystemVerilog: verified in simulation (18 testbenches), and validated
end-to-end on real hardware on a [pico2-ice](https://pico2-ice.tinyvision.ai/)
(iCE40UP5K) board over UART. A Terasic DE1-SoC (Cyclone V) target for full MNIST
digit classification is planned next — see §4.

## 1. TPU Design

The TPUv1 is designed around the idea of keeping weights stationary inside the
MMU and streaming activations through it, so weights
(which are reused many times) never have to be re-fetched from memory between uses.
Here are the major blocks, and how data moves between them:

- **Host I/O** — in the original TPUv1, a PCIe link to the host and DDR3 channels. In
  this implementation, a 115 200-baud UART over two GPIO pins replaces the PCIe/DDR path.
  `tpu_host.py` is the Python driver that sends weights/activations from the PC and reads
  back results.
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
│   ├── weight_loader.sv
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
│   ├── *_tb.sv
│   └── hw_regression.py         # real-hardware regression suite (see §3.1)
├── sim/                         # simulation build output (gitignored)
│   ├── *.vvp
│   ├── *.vcd
│   └── logs/
├── fpga/                          # iCE40 build target (yosys/nextpnr-ice40/icepack)
├── firmware/                      # RP2350 firmware: USB-CDC <-> FPGA UART bridge
├── docs/
│   ├── FPGA.md                   # pico2-ice architecture + end-to-end build/flash/validate runbook
│   ├── sequencer_uart_design.md  # tpu_sequencer/uart_rx/uart_tx FSM + timing writeup
│   └── reference/de1_soc_user_manual/  # vendored Terasic DE1-SoC manual
└── pico-ice-sdk/                 # vendored, gitignored -- see docs/FPGA.md §6
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
make test            # build + run all 18 testbenches, print a pass/fail summary table
# or, equivalently and usable outside make:
./run_tests.sh
./run_tests.sh fifo mmu     # ...or just a subset
```

**Per-testbench commands** — every testbench gets a matching `build-`,
`test-`, and `wave-` target. RTL dependencies are resolved automatically.

**Other targets:**
```bash
make list      # print every registered test name and its available targets
make clean     # remove sim/ (compiled binaries, logs, waveform dumps)
```

## 3. FPGA Targets

### 3.1 pico2-ice (iCE40UP5K) — bring-up complete, hardware-validated

A 2×2 systolic array runs the full datapath (UART RX → sequencer → weight FIFO →
unified buffer → systolic data setup → MMU → accumulator → bias → ReLU → UART TX) on
real silicon. Architecture, code layout, build/flash/validate steps, board gotchas,
and the wire protocol are all in `docs/FPGA.md`; the sequencer/UART FSM design and
cycle-by-cycle timing are in `docs/sequencer_uart_design.md`.

```bash
cd fpga && make && make prog   # build + flash the gateware
python3 tpu_host.py --port /dev/cu.usbmodemXXXX --selftest
make hw-test PORT=/dev/cu.usbmodemXXXX   # broader regression suite (see tests/hw_regression.py)
```


## 4. Current Status and Future Work

- **Simulation** — full datapath implemented and passing all 18 SystemVerilog
  testbenches (`make test`).
- **pico2-ice hardware** — bring-up complete; `tests/hw_regression.py` (`make hw-test`)
  replays every simulation test vector plus int8/int16 boundary cases and a randomized
  stress run against real silicon.
- **K-dim tiling** — `accumulator.sv` now holds a persistent per-row PSUM register that
  survives across separate `RUN`s (`tile_first`/`tile_last` control, `pass_done` status),
  so a matmul with K larger than the 2x2 array can be tiled into multiple weight-reload
  passes summed in hardware before bias/ReLU ever runs — see its header comment and
  `docs/sequencer_uart_design.md` §3.2 for the wire-protocol side (`RUN`'s optional
  `LEN=1` flags byte). Verified in sim (`accumulator_tb`, `tpu_core_tb` Test 8,
  `tpu_sequencer_tb` Test 7) and on real pico2-ice hardware (`tpu_host.py`'s
  `TPU.matmul_tiled()`, `tests/hw_regression.py`'s randomized multi-tile stress case).
- **MNIST** — `mnist/train_mnist.py` trains and quantizes a small 64→32→10 MLP (int8
  weights/activations, int16 bias) sized and empirically verified against the
  accumulator's non-saturating int16 width; 94.95% quantized test accuracy.
- **Future work** — extending `tpu_host.py` with a tiled multi-layer inference driver
  that feeds the trained MNIST model's weights through `matmul_tiled()` layer by layer,
  and an interactive drawing demo on top of that.
