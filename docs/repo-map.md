# Repository map

Every tracked file and what it's for. The root [`README.md`](../README.md) §4
has the directory-level version.

## Root

| File | What |
|---|---|
| `README.md` | Entry point: what this is, the DE1-SoC quick start, the design in brief, status |
| `CONTRIBUTING.md` | Dev setup, the local gates, adding a unit bench, house style |
| `Makefile` | `make test`, `make check`, `make list`; defines `CORE_RTL` (the core's files in compile order) and includes `mk/` |
| `mk/unit.mk` | the unit benches: `make test` / `make unit`, `make unit-<name>` |
| `mk/core.mk` | `make model-test`, `rtl-sim`, `rtl-test`, `sim-test` (N = 8 and 4); `selftest-rom`, `selftest-sim` |
| `mk/verilator.mk` | `make lint`: `tpu_top` at N = 8 and 4, and `tpu_selftest` |
| `verilator.vlt` | lint waivers, each with a reason |
| `requirements.txt` | `pyserial`, `numpy`, and `-e ./host` |
| `LICENSE` | MIT |

`.venv/` (the Python environment), `sim/` (simulation output) and
`__pycache__/` are gitignored.

## `rtl/` — the core

Everything under `rtl/` is board-neutral. See
[`architecture.md`](architecture.md).

| File | What |
|---|---|
| `tpu-core.sv` | host FIFOs, dispatcher, engine queues, WMEM and the parameter tables, the datapath wiring, status and perf counters |
| `common/tpu-pkg.sv` | opcodes, engines, error codes, legal-bit masks, `wait_counts_reached` (mirrors `host/tpu/isa.py`) |
| `common/fifo.sv` | the generic show-ahead FIFO (host FIFOs, engine queues, the accumulator's column and tag FIFOs) |
| `control/dispatch.sv` | in-order decode, range checks, routing, `WAIT` snapshots, the `SIGNAL` fence |
| `control/load-engine.sv`, `weight-engine.sv`, `matmul-engine.sv`, `activate-engine.sv` | the four engines (control only) |
| `datapath/unified-buffer.sv` | the UB memory and its port priorities |
| `datapath/systolic-data-setup.sv` | the row skew (element *i* delayed *i* cycles) |
| `datapath/pe.sv`, `mmu.sv` | the PE (`weight_current`/`weight_next`, flip) and the N × N array with the skewed weight bus |
| `datapath/weight-fifo.sv` | the two-slot tile buffer between WMEM and the array |
| `datapath/accumulator.sv` | column de-skew, row tags, the ACC memory, read-modify-write |
| `datapath/bias.sv`, `activation.sv` | bias add; ReLU and the requantizer |
| `peripherals/host-bridge.sv` | the 12-register Avalon-MM slave the host drives ([`isa.md`](isa.md) §4) |

## `boards/de1soc/` — the board

| Path | What |
|---|---|
| `top/tpu-top.sv` | `host_bridge` + `tpu_core` + power-on reset |
| `top/tpu-selftest.sv`, `top/replay.sv` | the FPGA-only self-test: a ROM-fed Avalon master, results on LEDs/HEX, perf captures on SW9 + SW4..0 |
| `top/hex-display.sv` | six seven-segment digits from 5-bit codes, behind the GHRD design's `hex_pio` |
| `fpga/README.md` | index of the FPGA builds |
| `fpga/selftest/` | the self-test's Quartus project (`tpu-selftest.qpf/.qsf/.sdc`), `Makefile`, `gen_selftest.py` (the ROM transcript, expected words from the model), `README.md` |
| `fpga/hps/` | the GHRD integration: `tpu_hw.tcl` (Platform Designer component), `add-tpu.tcl` (adds `tpu` + `hex_pio`), `patch_top.py` (wires the HEX decoder), `Makefile` (extract the GHRD from the rev H CD → generate → compile → `.rbf`; ARM tools), `README.md` |
| `sw/isa-mmio.c` | ARM `/dev/mem` register server speaking `tb_isa`'s protocol |
| `sw/setbaud.c` | 636-byte libc-free console baud setter (`termios2`) |

## `host/` — the Python package

| File | What |
|---|---|
| `pyproject.toml` | the `tpu` package (installed by `requirements.txt`) |
| `tpu/isa.py` | the encoder and decoder from one field table; `quant_params`, data packing |
| `tpu/isa_model.py` | the reference model |
| `tpu/isa_layout.py` | data layouts (weight tiles, K-chunk-major UB, outputs) |
| `tpu/isa_compile.py` | an int8 MLP → load and infer programs |
| `tpu/isa_waits.py` | per-engine read/write sets; `check_waits`, `insert_waits` |
| `tpu/isa_device.py` | `IsaDevice`; `IsaSimLink` (Verilator), `IsaSerialLink` and `BoardConsole` (the board's console: login, launch, paced `upload()`, baud switching), `open_link()` |
| `tpu/golden.py` | reference numerics: exact int matmul, wrap, requant |

## `tests/`

| Path | What |
|---|---|
| `unit/*-tb.sv`, `unit/check.svh` | the unit benches and their shared check header |
| `uvm/common/`, `uvm/blocks/` | the UVM environments: shared coverage bins and base test; one package and interface per block, all in `blocks-top.sv` (`make uvm`) |
| `uvm/uvm-verilator/` | the UVM library, a pinned submodule |
| `unit/gen_requant.py` | requantizer vectors from `tpu.golden` for `activation_tb` |
| `isa/test_isa_model.py` | the model against independent references (`make model-test`) |
| `isa/test_isa_rtl.py` | the RTL against the model, word for word (`make rtl-test`), or the board with `serial:<port>` |
| `isa/isa_progs.py` | random legal programs for the concurrency tests |
| `verilator/tb-isa.cpp` | `tpu_top` as a register-level transport for `isa_device.py` |
| `verilator/tb-isa-selftest.cpp` | runs the self-test top and reads its LEDs, HEX and capture slots back |

See [`verification.md`](verification.md).

## `software/mnist/`

| Path | What |
|---|---|
| `train_mnist.py` | train and quantize the 144 → 64 → 10 model |
| `mnist_model.py` | the host reference: `load_model`, `quantize`, `predict_batch_offline`, `OfflineModel` |
| `draw_demo.py` | the drawing demo: `--de1soc PORT [--baud]` or `--offline` |
| `model/mnist-2x2-int8.npz` | the committed weights |
| `de1soc/` | MNIST on the board's ARM: `make_data.py`, `mnist-tpu.c`, `Makefile`, `README.md` |

See [`mnist.md`](mnist.md).

## `docs/`

This documentation; [`README.md`](README.md) is the index. `olddocs/` is an
earlier set kept locally and gitignored.
