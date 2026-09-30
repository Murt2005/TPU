# Contributing

Thanks for your interest in this TPU design! This is a research/educational
reimplementation of the Google TPUv1 datapath in synthesizable SystemVerilog.
Contributions — bug fixes, new testbenches, board ports, docs — are welcome.

## Development setup

You need an open-source RTL toolchain (see the Prerequisites section of the
[README](README.md) for tested versions):

- **Icarus Verilog** (`iverilog`/`vvp`) — unit/integration simulation
- **Verilator** — lint + full-chip C++ simulation
- **Yosys** — synthesis; also supplies the `SB_MAC16` sim model the `pe_pair`
  tests extract at build time (so yosys is needed even for pure simulation of
  the DSP-pair path)
- **GTKWave** (optional) — waveform viewing
- **Python 3.11+** with `pip install -r requirements.txt` — the host driver

The FPGA build additionally needs board-specific tools (`nextpnr-ice40` +
`icestorm` + `dfu-util` for the pico2-ice target; see `boards/pico2-ice/fpga/`).

## Running the checks

All quality gates are local `make` targets (this project intentionally does not
use hosted CI). Before opening a PR, run:

```sh
make test           # build + run all testbenches, prints a pass/fail summary
make lint           # protocol-constant check + Verilator lint (UART + SPI + 4x4 + HPS configs)
make verilate-test  # full-chip C++ simulation across 12 shape/PHY/width combos
```

`make test` (via `run_tests.sh`) returns a non-zero exit code if any testbench
fails, so it is safe to gate on. Use `make list` to see individual targets, and
`make test-<name>` / `make wave-<name>` to run or waveform-view one testbench.

If you have the hardware, `make hw-test PORT=/dev/cu.usbmodemXXXX` replays the
sim vectors against a flashed board (the `ARRAY_ROWS`/`NUM_COLS`/`M_TILE`/`LINK`
knobs must match the bitstream).

## Adding a testbench

1. Write `tests/<name>_tb.sv`. Print `PASSED` on success; use `$error`/`$fatal`
   (or a `[FAIL]` string) on failure — `run_tests.sh` classifies by those.
2. Add one `DEPS_<name>` line to `mk/sim.mk` listing the RTL it
   needs. That's all — the test list is built from the `tests/*_tb.sv` files,
   and a bench without a `DEPS_` line stops the build with an error naming it.

## Style conventions

The RTL follows a consistent house style — please match it:

- `snake_case` signals; `*_valid` companion for each data bus; `in_*` / `out_*`
  port prefixes.
- Synchronous, active-high `reset` inside modules (only the top level exposes
  active-low `reset_n`); every sequential block is `if (reset) ... else ...`.
- Tunables are `parameter int`; derived values are `localparam`.
- Shared wire-protocol constants (command opcodes, flag bits, status bytes) live in
  `rtl/core/tpu_pkg.sv` — reuse them rather than re-declaring literals.
- Each module opens with a header comment stating its role, contract, and
  latency. Please keep new modules consistent.

## Commit / PR notes

- Keep commits focused and messages short and descriptive.
- Make sure `make test`, `make lint`, and `make verilate-test` all pass.
