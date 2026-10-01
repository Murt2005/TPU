# Contributing

Thanks for your interest in this TPU design! This is a research/educational
reimplementation of the Google TPUv1 datapath in synthesizable SystemVerilog.
Contributions — bug fixes, new testbenches, board ports, docs — are welcome.

## Development setup

You need an open-source RTL toolchain (see the [README](README.md)'s
toolchain sections, §1.3 and §2.3, for install commands and tested versions):

- **Icarus Verilog** (`iverilog`/`vvp`) — unit/integration simulation
- **Verilator** — lint + full-chip C++ simulation
- **Yosys** — synthesis; also supplies the `SB_MAC16` sim model the `pe_pair`
  tests extract at build time (so yosys is needed even for pure simulation of
  the DSP-pair path)
- **GTKWave** (optional) — waveform viewing
- **Python 3.11+** with `pip install -r requirements.txt` — the host driver

The FPGA builds additionally need board-specific tools:
- **DE1-SoC** (the active target): Quartus Prime Lite, in an x86 VM on Apple
  Silicon, plus `openFPGALoader`. See [`docs/de1soc.md`](docs/de1soc.md) §3.
- **pico2-ice:** `nextpnr-ice40` + `icestorm` + `dfu-util`; see
  `boards/pico2-ice/fpga/`.

## Running the checks

All quality gates are local `make` targets (this project intentionally does not
use hosted CI). Before opening a PR, run:

```sh
make isa-test           # the instruction-stream core: reference model, then RTL vs model at N = 8 and 4
make isa-selftest-sim   # the DE1-SoC self-test ROM through Verilator
make lint               # protocol-constant check + Verilator lint (5 configs, incl. the instruction-stream top)
make test               # the legacy core's testbenches, pass/fail summary
make verilate-test      # the legacy core's full-chip C++ simulation, 12 shape/PHY/width combos
```

Changing the instruction-stream core? `make isa-test` + `make lint` +
`make isa-selftest-sim` in sim. Anything affecting synthesis or timing also
needs a board run (self-test PASS, then `tests/isa/test_isa_rtl.py
serial:<port>`); see [`docs/verification.md`](docs/verification.md).

`make test` (via `run_tests.sh`) returns a non-zero exit code if any testbench
fails, so it is safe to gate on. Use `make list` to see individual targets, and
`make test-<name>` / `make wave-<name>` to run or waveform-view one testbench.

If you have a pico2-ice, `make hw-test PORT=/dev/cu.usbmodemXXXX` replays the
legacy core's sim vectors against a flashed board. The host flags must match the
bitstream; pass the same `CONFIG=<name>` it was built with
(`boards/pico2-ice/configs/`), or the individual knobs.

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
- Each module opens with a one-line comment naming what it is. Beyond that,
  comments are sparse: short, lowercase (unless the first word is all caps),
  and about a decision or a low-level trap, not a restatement of the code.
  Explanations, contracts and latencies belong in `docs/`.

## Commit / PR notes

- Keep commits focused and messages short and descriptive.
- Make sure `make test`, `make lint`, and `make verilate-test` all pass.
