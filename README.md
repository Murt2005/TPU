# Reverse-Engineering Google's TPUv1

Reimplementing the core datapath of Google's first-generation Tensor Processing Unit
(as described in *In-Datacenter Performance Analysis of a Tensor Processing Unit*)
as synthesizable SystemVerilog, verifying it in simulation, and deploying it on a
Terasic DE1-SoC to run MNIST digit classification
end-to-end on real hardware.

## 1. TPU Design

The TPUv1 is designed around the idea of keeping weights stationary inside the
MMU and streaming activations through it, so weights
(which are reused many times) never have to be re-fetched from memory between uses.
Here are the major blocks, and how data moves between them:

- **Host I/O** — in the original TPUv1, a PCIe link to the host and DDR3 channels. In
  this implementation, a 115 200-baud UART over two GPIO pins replaces the PCIe/DDR path.
  A `host.py` Python script will send weights and activations from the PC.
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
├── Makefile
├── run_tests.sh
├── rtl/
│   ├── pe.sv
│   ├── mmu.sv
│   ├── fifo.sv
│   ├── weight_fifo.sv
│   ├── systolic_data_setup.sv
│   ├── accumulator.sv
│   ├── bias.sv
│   ├── activation.sv
│   ├── weight_loader.sv
│   ├── unified_buffer.sv
│   ├── uart_rx.sv
│   └── uart_tx.sv
├── tests/
│   ├── pe_tb.sv
│   ├── mmu_tb.sv
│   ├── fifo_tb.sv
│   ├── weight_fifo_tb.sv
│   ├── systolic_data_setup_tb.sv
│   ├── accumulator_tb.sv
│   ├── bias_tb.sv
│   ├── activation_tb.sv
│   ├── mmu_accum_tb.sv
│   ├── accum_bias_tb.sv
│   ├── bias_activation_tb.sv
│   ├── unified_buffer_tb.sv
│   ├── weight_fifo_mmu_tb.sv
│   ├── weight_loader_tb.sv
│   ├── weight_loader_fifo_tb.sv
│   ├── uart_rx_tb.sv
│   ├── uart_tx_tb.sv
│   └── tpu_core_tb.sv
└── sim/
    ├── *.vvp
    ├── *.vcd
    └── logs/
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

## 3. FPGA Target: DE1-SoC

Target device: **Cyclone V 5CSEMA5F31C6** on the Terasic DE1-SoC board.
See `docs/de1_soc_hardware.md` for the full board reference.

| Resource | DE1-SoC (Cyclone V) | 2×2 array estimate | 8×8 array estimate |
|---|---|---|---|
| Adaptive Logic Modules (ALMs) | 32,070 (~85K LE equiv.) | ~500 | ~2,000 |
| M10K block RAM | 553 blocks (707 KB total) | ~2 blocks | ~12 blocks |
| DSP 18×18 MAC blocks | 87 | 4 (one per PE) | 64 (one per PE) |
| Fractional PLLs | 6 | 1 (50→100 MHz) | 1–2 |
| HPS-side DDR3 | 1 GB | not needed for v1 | not needed for v1 |
| FPGA-side SDRAM | 64 MB | not needed for v1 | not needed for v1 |

**MNIST weight memory:** 784×128 + 128×10 ≈ **99 KB** — fits in ~10 M10K blocks,
leaving 543 of the 553 blocks free for the Unified Buffer and other structures.
The entire network runs from on-chip BRAM; no DDR3 plumbing required for v1.

## 4. Current Status and Future Work

Currently the full TPU datapath is implemented and validated in simulation. Future work
includes programming the TPU onto the DE1-SoC using Quartus and training, quantizing
and running MNIST inference on the DE1-SoC.
