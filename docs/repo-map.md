# Repository map

File-by-file. The root [`README.md`](../README.md) §4 has the short version;
this is the complete one.

## Root

| File | What |
|---|---|
| `README.md` | Entry point: quick start, toolchain, architecture walkthrough, status |
| `CONTRIBUTING.md` | Dev setup, local quality gates, how to register a testbench, RTL house style |
| `Makefile` | Simulation + lint + hardware-test automation; single-sources the RTL dependency graph `run_tests.sh` uses |
| `run_tests.sh` | Builds and runs every (or a named subset of) testbench, printing a pass/fail summary |
| `tpu_host.py` | Host driver + CLI: the wire protocol, `matmul_tiled()`, and the three link backends (UART / SPI / HPS MMIO) |
| `verilator.vlt` | Verilator lint waivers |
| `requirements.txt` | `pyserial`, `numpy` |
| `.gitmodules` | Pins `firmware/pico-ice-sdk` to tinyvision-ai-inc's SDK |
| `.gitignore` | Sim output, FPGA artifacts, Quartus output, firmware build dirs, MNIST data, the in-place venv, `olddocs/` |

`bin/`, `lib/`, `include/`, `pyvenv.cfg`, `__pycache__/` are an in-place
Python venv (`python3 -m venv .`) and bytecode caches. Gitignored, not
documented further.

## `rtl/` — synthesizable SystemVerilog

**Datapath**

| File | What |
|---|---|
| `pe.sv` | One processing element: stationary weight × streaming activation, partial sum forwarded down |
| `pe_pair.sv` | Two PEs in one hand-instantiated `SB_MAC16` (dual-8×8 signed). iCE40-only |
| `mmu.sv` | The `ARRAY_ROWS`×`NUM_COLS` systolic array; instantiates `pe` or `pe_pair` |
| `systolic_data_setup.sv` | Skews an activation row in time to match the array's diagonal wavefront |
| `weight_fifo.sv` | Ping-pong weight store; drains the active bank while the next streams into the shadow |
| `unified_buffer.sv` | Double-banked activation SRAM, BRAM-inferred; keeps layer-to-layer data on chip |
| `accumulator.sv` | Reassembles time-skewed column partial sums into rows; persistent non-saturating int16 PSUM for K-tiling |
| `bias.sv` | Registered per-column int16 add |
| `activation.sv` | Registered ReLU; no bypass mode |
| `fifo.sv` | Generic synchronous circular queue used by `accumulator` and `weight_fifo` |

**Control and host interface**

| File | What |
|---|---|
| `tpu_sequencer.sv` | Command decoder + pipeline orchestrator. Its header comment is the normative protocol spec |
| `tpu_pkg.sv` | Shared wire-protocol constants; must be read before `tpu_sequencer.sv` |
| `uart_rx.sv` | 8N1 receiver, 16× oversampling, mid-bit sample |
| `uart_tx.sv` | 8N1 transmitter |
| `spi_slave.sv` | Mode-0 SPI slave presenting the identical byte-stream interface |
| `hps_bridge.sv` | Avalon-MM slave for the DE1-SoC's HPS; fixed read latency 1, no CDC |

**Tops**

| File | Target |
|---|---|
| `tpu_core.sv` | Board-neutral datapath; no host interface |
| `tpu_top.sv` | pico2-ice: PHY + sequencer + core, plus the power-on-reset counter |
| `tpu_top_hps.sv` | DE1-SoC: `hps_bridge` + sequencer + core |

## `tests/` — 22 testbenches + hardware regression

**Unit** — `fifo_tb`, `pe_tb`, `pe_pair_tb`, `mmu_tb`, `bias_tb`,
`activation_tb`, `accumulator_tb`, `unified_buffer_tb`,
`systolic_data_setup_tb`, `weight_fifo_tb`, `uart_rx_tb`, `uart_tx_tb`,
`spi_slave_tb`, `hps_bridge_tb`.

**Pairwise integration** — `mmu_accum_tb`, `accum_bias_tb`,
`bias_activation_tb`, `weight_fifo_mmu_tb`.

**Full-path** — `tpu_core_tb` (datapath, no sequencer), `tpu_sequencer_tb`
(protocol → pipeline), and shape variants `tpu_sequencer_4x2_tb` (all three
axes distinct), `_2x4_tb`, `_4x4_tb` (through the `SB_MAC16` netlist path).

| File | What |
|---|---|
| `hw_regression.py` | 14-case regression against real silicon over `tpu_host.py` |
| `verilator/tb_tpu_top.cpp` | C++ full-chip bench driving `tpu_top`'s real host pins across 7 shape/PHY combos |

See [`verification.md`](verification.md).

## `fpga/` — synthesis targets

| Path | What |
|---|---|
| `Makefile` | Dispatches to the per-board makefiles |
| `ice40/Makefile` | yosys → nextpnr-ice40 → icepack; all build knobs live here |
| `ice40/tpu_top.pcf` | iCE40 package-pin constraints |
| `ice40/tpu_top.{json,asc,bin}` | Generated artifacts (gitignored) |
| `de1soc/Makefile` | Quartus command-line build + `.rbf` generation; set `PROJECT`/`REVISION` |
| `de1soc/README.md` | Quartus/Qsys integration and HPS deploy runbook |
| `de1soc/tpu_top_hps.sdc` | 50 MHz fabric clock constraint |
| `de1soc/tpu_top_hps.qsf` | Device + TPU-specific pin/settings skeleton |

## `firmware/` — RP2350

| File | What |
|---|---|
| `README.md` | Per-file walkthrough and build instructions |
| `main.c` | The bridge: USB up, 12/24 MHz clock to the FPGA, bitstream load, UART↔CDC (ring-buffered, not in the ISR), LED from real `CDONE`, and the second-port LED command listener |
| `tpu_tile.c` / `.h` | SPI builds only: SPI link + `FW_PROBE`/`FW_MATMUL` on-RP2350 tiling offload |
| `usb_descriptors.c` | TinyUSB tables: two CDC-ACM ports (`RP2040 logs`, `iCE40 UART`) + a DFU interface with two alt settings |
| `tusb_config.h` | TinyUSB stack config matching those descriptors |
| `CMakeLists.txt` | Builds `pico2_ice_bridge` against the vendored SDK |
| `pico_sdk_import.cmake` | Unmodified pico-sdk import boilerplate |
| `pico-ice-sdk/` | Vendored SDK (**git submodule**) |
| `build/`, `build-spi/` | Out-of-tree build dirs producing the `.uf2` (gitignored) |

## `mnist/`

| Path | What |
|---|---|
| `train_mnist.py` | Train + quantize the 144→64→10 int8 MLP |
| `infer.py` | Multi-layer driver: hardware and offline backends, `--compare`, `--timing-breakdown` |
| `draw_demo.py` | Tkinter draw-a-digit demo |
| `model/mnist_2x2_int8.npz` | Committed pre-trained weights (~5 KB) |
| `data/` | Downloaded IDX files (gitignored) |

See [`mnist.md`](mnist.md).

## `sim/` — generated

`sim/sb_mac16_sim.v` is yosys's own `SB_MAC16` model, extracted at build time
so `pe_pair_tb` and the Verilator builds check against a single source of
truth. `sim/verilator/` holds per-shape object dirs. Entirely gitignored.

## `docs/` and `olddocs/`

`docs/` is this documentation set — see [`README.md`](README.md) for the
index. `olddocs/` is the pre-reorganization set, kept locally and gitignored;
it holds the original analysis trail that `performance.md` consolidates.
