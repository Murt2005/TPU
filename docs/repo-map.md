# Repository map

File-by-file. The root [`README.md`](../README.md) §5 has the directory-level
version; this is the complete one.

## Root

| File | What |
|---|---|
| `README.md` | Entry point: quick start, toolchain, architecture walkthrough, status |
| `CONTRIBUTING.md` | Dev setup, local quality gates, how to register a testbench, RTL house style |
| `Makefile` | Entry point for simulation, lint, the Verilator suite, the sim bridge and hardware tests; defines the shared file sets and includes `mk/` |
| `mk/sim.mk` | Icarus testbenches: the RTL dependency graph (`DEPS_<name>`), the test list (built from `tests/sv/*_tb.sv`), and `make test` |
| `mk/isa.mk` | The instruction-stream core: `make isa-test` (model + RTL at N = 8 and 4), `make isa-sim`, `make isa-lint`, and the DE1-SoC self-test's `make isa-selftest-rom` / `isa-selftest-sim` |
| `mk/verilator.mk` | `make check-protocol`, `make lint` (5 configs), `make verilate-test` (12 combos), `make sim-bridge` |
| `mk/hw.mk` | `make hw-test` and `make host-flags`, both taking `CONFIG=` |
| `run_tests.sh` | Builds and runs every (or a named subset of) testbench, printing a pass/fail summary. Gets the test list from `make print-tests` |
| `tpu_host.py` | Compatibility wrapper: `python3 tpu_host.py` runs the `tpu` CLI and `import tpu_host` still works, with or without the package installed |
| `verilator.vlt` | Verilator lint waivers |
| `requirements.txt` | `pyserial`, `numpy`, and `-e ./host` (the driver package) |
| `.gitmodules` | Pins `boards/pico2-ice/firmware/pico-ice-sdk` to tinyvision-ai-inc's SDK |
| `.gitignore` | Sim output, FPGA artifacts, Quartus output, firmware build dirs, MNIST data, `.venv/`, `olddocs/` |

`.venv/` is the Python virtual environment (README §1.2) and `__pycache__/`
holds bytecode caches. Both gitignored.

## `rtl/` — board-neutral SystemVerilog

Everything here is shared by every board. Nothing in it names a pin or a
vendor primitive.

**`rtl/core/` — datapath and control**

| File | What |
|---|---|
| `pe.sv` | One processing element: stationary weight × streaming activation, partial sum forwarded down |
| `mmu.sv` | The `ARRAY_ROWS`×`NUM_COLS` systolic array; instantiates `pe`, or `pe_pair` when `USE_MAC16_PAIR=1` |
| `systolic_data_setup.sv` | Skews an activation row in time to match the array's diagonal wavefront |
| `weight_fifo.sv` | Ping-pong weight store; drains the active bank while the next streams into the shadow |
| `unified_buffer.sv` | Double-banked activation SRAM, BRAM-inferred. Its layer-to-layer write-back port exists but is tied off in `tpu_core` |
| `accumulator.sv` | Reassembles time-skewed column partial sums into rows; persistent non-saturating `PSUM_WIDTH` PSUM for K-tiling |
| `bias.sv` | Registered per-column `PSUM_WIDTH` add |
| `activation.sv` | Registered ReLU, bypassable per pass (`flags[2]`) |
| `fifo.sv` | Generic synchronous circular queue used by `accumulator`, `weight_fifo` and `spi_slave` |
| `tpu_sequencer.sv` | Command decoder + pipeline orchestrator; implements [`protocol.md`](protocol.md) |
| `tpu_pkg.sv` | Shared wire-protocol constants; must be read before `tpu_sequencer.sv` |
| `tpu_core.sv` | Sequencer + datapath behind the byte-stream interface; no host PHY |

**`rtl/peripherals/` — host-link PHYs**

All four present the same byte-stream interface to `tpu_core`.

| File | What |
|---|---|
| `uart_rx.sv` | 8N1 receiver, 16× oversampling, mid-bit sample |
| `uart_tx.sv` | 8N1 transmitter |
| `spi_slave.sv` | Mode-0 SPI slave |
| `hps_bridge.sv` | Avalon-MM slave for the DE1-SoC's HPS; fixed read latency 1, no CDC |
| `isa_bridge.sv` | The instruction-stream core's 12-register Avalon-MM slave (instructions, data, out, status, perf) |

**`rtl/isa/` — the instruction-stream core (DE1-SoC, hardware-validated)**

The 64-bit instruction set, through spec phase 3: requantizer, layers chained through the UB, and tiles overlapped one per `max(m, N)` cycles. No DDR3 yet. Reuses `rtl/core/`'s `fifo` and `systolic_data_setup`; the array is its own (`isa_pe`, `isa_array`). Reference: [`isa.md`](isa.md).

| File | What |
|---|---|
| `isa_pkg.sv` | Opcodes, error codes, reserved-bit masks, the `WAIT` check (mirrors `host/tpu/isa.py`) |
| `isa_dispatch.sv` | In-order decode, error checks, routing to the four engine queues, `WAIT` snapshots, `SIGNAL` fence |
| `isa_ld.sv` | LD engine: data FIFO words into WMEM, UB and the bias/quant tables |
| `isa_wt.sv` | WT engine: `SET_WBASE`, and WMEM tiles into a two-slot tile buffer |
| `isa_mm.sv` | MM engine: overlapped windows (one tile's rows streamed while the next tile's weights load), column re-alignment, accumulator read-modify-write |
| `isa_pe.sv`, `isa_array.sv` | Overlap PE (`w_cur`/`w_next`, flipped by the tile's first activation) and the N×N grid with a per-column skewed row-select weight bus |
| `isa_act.sv` | ACT engine: `ACTIVATE` (bias, ReLU, requantize) to the UB or the host out FIFO, and `RD_UB` |
| `isa_core.sv` | Host FIFOs, dispatcher, engine queues, memories, status, perf counters |

## `boards/` — one directory per target

### `boards/pico2-ice/` — iCE40UP5K + RP2350 (hardware-validated, no longer developed)

| Path | What |
|---|---|
| `top/tpu_top.sv` | Top level: UART or SPI PHY + `tpu_core` + the power-on-reset counter |
| `top/pe_pair.sv` | Two PEs in one hand-instantiated `SB_MAC16` (dual-8×8 signed). iCE40-only, so it lives here rather than in `rtl/` |
| `config.mk` | Loads a named configuration; shared by `fpga/Makefile` and the root `mk/hw.mk` |
| `configs/*.mk` | One file per hardware-validated build: `2x2_uart`, `2x4_uart`, `2x4_spi`, `4x4m2_spi`, `4x4_spi` |
| `fpga/Makefile` | yosys → nextpnr-ice40 → icepack → dfu-util; all build knobs live here (`CONFIG=` sets them at once) |
| `fpga/tpu_top.pcf` | iCE40 package-pin constraints |
| `fpga/tpu_top.{json,asc,bin}`, `fpga/.knobs` | Generated artifacts and the settings stamp (gitignored) |
| `firmware/` | RP2350 firmware — below |

**`boards/pico2-ice/firmware/`**

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

### `boards/de1soc/` — Cyclone V SoC (hardware-validated, the active target)

| Path | What |
|---|---|
| `top/tpu_isa_top.sv` | Instruction-stream top: `isa_bridge` + `isa_core` + power-on reset |
| `top/tpu_isa_selftest.sv` | FPGA-only top: `tpu_isa_top` driven by `isa_replay`; LEDs/HEX report, SW9 + SW4..0 show perf captures |
| `top/isa_replay.sv` | ROM-fed Avalon master: replays a register transcript, checks reads, captures and bounds perf counters |
| `top/hex_display.sv` | Six seven-segment digits from 5-bit codes (hex, blank, dash); used by the GHRD design's `hex_pio` |
| `top/tpu_top_hps.sv` | Legacy byte-protocol core's top (`hps_bridge` + `tpu_core`); never built |
| `fpga/README.md` | Index of the FPGA builds |
| `fpga/selftest/` | The self-test: `gen_selftest.py` (ROM transcript from the reference model), Quartus `.qpf/.qsf/.sdc`, `Makefile`, `README.md` |
| `fpga/hps/` | The GHRD integration: `tpu_isa_hw.tcl` (Platform Designer component), `add_tpu.tcl` (qsys edit: TPU + `hex_pio`), `patch_top.py` (wires the HEX decoder into `ghrd_top.v`), `Makefile` (extract the GHRD from the rev H CD → generate → compile → `.rbf`; ARM tools), `README.md` |
| `fpga/{Makefile,tpu_top_hps.qsf,tpu_top_hps.sdc}` | Legacy core's Quartus scaffolding; never built |
| `sw/isa_mmio.c` | ARM `/dev/mem` register server speaking `tb_isa`'s protocol (`IsaSerialLink` runs it over the console) |
| `sw/setbaud.c` | 636-byte libc-free console baud setter (`termios2`/`BOTHER`), for rates busybox `stty` lacks |

## `host/` — the Python driver package

| File | What |
|---|---|
| `pyproject.toml` | Package `tpu-host`; installs the `tpu` package and a `tpu-host` command |
| `tpu/protocol.py` | Opcodes, flag bits, status bytes, link constants (mirrors `rtl/core/tpu_pkg.sv`; checked by `make check-protocol`) |
| `tpu/links.py` | `MmioLink` (DE1-SoC `/dev/mem`), `SimLink` (Verilator subprocess), `open_link()` |
| `tpu/driver.py` | The `TPU` class: legacy commands, `run_tile`, `stream_run`, `matmul_tiled()`, the `FW_MATMUL` offload |
| `tpu/golden.py` | The reference numerics every Python caller shares |
| `tpu/isa.py` | Instruction-stream encoder/decoder, from one field table |
| `tpu/isa_model.py` | The instruction-stream reference model the RTL is compared against |
| `tpu/isa_layout.py` | Host-side layout for the core's fixed strides (weight tiles, K-chunk-major UB) |
| `tpu/isa_compile.py` | Compiles an int8 MLP into the core's load and infer programs |
| `tpu/isa_waits.py` | Per-engine read/write sets; finds unordered hazards and inserts the minimal `WAIT`s |
| `tpu/isa_device.py` | `IsaDevice` (driver for `isa_bridge`'s registers); links `IsaSimLink` (Verilator) and `IsaSerialLink` (the board, via `isa_mmio`); `BoardConsole` (log in, launch, `upload()`, baud switching on the HPS console); `open_link()` |
| `tpu/cli.py` | Argument parsing and `--selftest`; `tpu/__main__.py` makes `python3 -m tpu` work |

## `tests/` — by verification tier

| Path | What |
|---|---|
| `sv/` | 23 Icarus testbenches (`make test`) — list below |
| `verilator/tb_tpu_top.cpp` | C++ full-chip bench: drives `tpu_top`'s real host pins (or injects bytes into `tpu_core` directly) across 12 shape/PHY/width combos; with `--bridge` it is the `--link sim` transport (`make sim-bridge`) |
| `isa/test_isa_model.py`, `isa/test_isa_rtl.py`, `isa/isa_progs.py` | The instruction-stream model, and the RTL against it word for word (`make isa-test`); `test_isa_rtl.py serial:<port>` runs the same suite on the board |
| `verilator/tb_isa.cpp` | `tpu_isa_top` as a register-level transport for `isa_device.py` |
| `verilator/tb_isa_selftest.cpp` | Runs the DE1-SoC self-test top and reads its LEDs/HEX and capture slots back (`make isa-selftest-sim`) |
| `check_protocol.py` | Checks the four copies of the wire-protocol constants agree (`make check-protocol`, part of `make lint`) |
| `hw/hw_regression.py` | 14-case regression against real silicon over the `tpu` driver (`make hw-test`) |

**Unit** — `fifo_tb`, `pe_tb`, `pe_pair_tb`, `mmu_tb`, `bias_tb`,
`activation_tb`, `accumulator_tb`, `unified_buffer_tb`,
`systolic_data_setup_tb`, `weight_fifo_tb`, `uart_rx_tb`, `uart_tx_tb`,
`spi_slave_tb`, `hps_bridge_tb`.

**Pairwise integration** — `mmu_accum_tb`, `accum_bias_tb`,
`bias_activation_tb`, `weight_fifo_mmu_tb`.

**Full-path** — `tpu_core_tb` (datapath, no sequencer), `tpu_sequencer_tb`
(protocol → pipeline), and shape variants `tpu_sequencer_4x2_tb` (all three
axes distinct), `_2x4_tb`, `_4x4_tb` (through the `SB_MAC16` netlist path).

See [`verification.md`](verification.md).

## `software/` — programs that run on the TPU

### `software/mnist/`

| Path | What |
|---|---|
| `train_mnist.py` | Train + quantize the 144→64→10 int8 MLP |
| `infer.py` | Multi-layer driver: hardware and offline backends, `--compare`, `--no-offload` |
| `draw_demo.py` | Tkinter draw-a-digit demo: the pico2-ice LED, or `--de1soc` (digit on the HEX displays, `--baud 1562500`) |
| `model/mnist_2x2_int8.npz` | Committed pre-trained weights (~5 KB) |
| `data/` | Downloaded IDX files (gitignored) |
| `de1soc/make_data.py` | `model.bin` (compiled load/infer programs) and `testset.bin` (pixels + expected values) for the board |
| `de1soc/mnist_tpu.c` | MNIST end to end on the DE1-SoC's ARM: `bench` over the test set, `serve` for the demo; `-DSIM` builds it against Verilator |
| `de1soc/Makefile`, `de1soc/README.md` | `data`, `arm`, `sim-bench`; measured results |

See [`mnist.md`](mnist.md).

### `software/llm/` — a transformer on the array

| File | What |
|---|---|
| `README.md` | Quick start, what runs where, quantization, cost |
| `fetch.sh` | Download TinyStories-1M and quantize it |
| `torch_bin.py` | Read a PyTorch `.bin` without PyTorch |
| `export.py` | Per-output-channel int8 quantization → `.npz` |
| `tokenizer.py` | GPT-2 byte-level BPE, pure Python |
| `infer.py` | Forward pass, backends (array / exact int8 emulation / float), `--compare`, CLI |
| `model/` | Downloaded + generated artifacts (gitignored) |

Targets the legacy byte-protocol core with `PSUM_WIDTH=32`, so it runs against `make sim-bridge` today; porting it to the instruction-stream core is in [`backlog.md`](backlog.md).

## `sim/` — generated

`sim/sb_mac16_sim.v` is yosys's own `SB_MAC16` model, extracted at build time
so `pe_pair_tb` and the Verilator builds check against a single source of
truth. `sim/verilator/` holds per-shape object dirs, plus `bridge/` (the
`--link sim` binary). Entirely gitignored.

## `docs/` and `olddocs/`

`docs/` is this documentation set — see [`README.md`](README.md) for the
index. `olddocs/` is the pre-reorganization set, kept locally and gitignored;
it holds the original analysis trail that `performance.md` consolidates.
