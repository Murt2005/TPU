# Contributing

Thanks for your interest in this TPU design: a research and educational
reimplementation of the Google TPUv1 in synthesizable SystemVerilog, running on
a DE1-SoC. Bug fixes, benches and docs are welcome.

## Development setup

- **Verilator 5.052**, installed in `~/.local/verilator-5.052` (or set
  `VERILATOR_HOME`): every simulation and lint. 5.032 can't compile UVM.
- **z3** (`brew install z3`): Verilator's solver for constrained randomization.
- **The UVM library**, a pinned submodule (`tests/uvm/uvm-verilator`, CHIPS
  Alliance's UVM 2020-3.2 for Verilator): `git submodule update --init`.
- **Python 3.11+** with `pip install -r requirements.txt` (in `.venv/`): the
  reference model, the compiler and the test drivers.
- **For FPGA builds:** Quartus Prime Lite (Cyclone V), in an x86 VM on Apple
  Silicon, plus `openFPGALoader`. See [`docs/de1soc.md`](docs/de1soc.md) §3.

## Running the checks

The quality gates are local `make` targets; this project deliberately has no
hosted CI.

```sh
make test          # the unit benches, one per datapath module (fast)
make uvm           # the UVM environments (tests/uvm), ~1 min to build
make sim-test      # the reference model's checks, then the RTL vs the model at N = 8 and 4
make lint          # Verilator lint: tpu_top at N = 8 and 4, tpu_selftest
make selftest-sim  # the DE1-SoC self-test ROM, as the FPGA will replay it
make check         # all five
```

Every target exits non-zero on failure, so they're safe to gate on.
`make list` shows them all; `make unit-<name>` runs one bench and
`make uvm-<test>` one UVM test.

**Anything that could move a cycle:** compare `make selftest-sim ST_SLOTS=21`
with the captures before your change.

**Anything touching synthesis, memory inference or timing:** also rebuild both
Quartus designs and run the board tiers: the self-test **PASS**, then
`tests/isa/test_isa_rtl.py serial:<port>`.

[`docs/verification.md`](docs/verification.md) has the full ladder.

## Adding a unit bench

1. Write `tests/unit/<name>-tb.sv` as a module `<name>_tb`. `` `include
   "check.svh" `` inside it, then use `` `TEST("…") ``, `` `CHECK(cond, msg) ``
   and `` `CHECK_EQ(got, want, msg) ``, and end with `tb_done();`, which prints
   the summary and fails the run if any check did.
2. That's all. `mk/unit.mk` picks up every `tests/unit/*-tb.sv` and compiles it
   against the core's files.

Before trusting a new bench, break the module it tests on purpose and make sure
the bench fails.

## Style conventions

- Names are spelled out, with `_` between words: `lower_snake_case` for
  signals, ports, functions and instances (`u_` + the module name);
  `UPPER_SNAKE_CASE` for parameters, constants and states. A name says what
  the value is (`k_tile_index`, `destination_is_UB`, `words_to_emit`), not
  just its type or shape (`row`, `word`, `buffer`).
- Every module port ends in `_in` or `_out` by direction
  (`activate_read_address_in`, `read_data_out`), and a valid sits beside its data
  (`partial_sum_in` / `partial_sum_valid_in`). The exceptions keep their
  standard names: `clk`, `reset`, the board top's `reset_n`, and Avalon's
  `avs_*`.
- Four acronyms stay short, in capitals even inside a lower-case name:
  **UB** (unified buffer), **WMEM** (weight memory), **ACC** (accumulator
  memory) and **MMU** (the array), e.g. `activate_UB_write_address`. Opcode
  mnemonics stay as the ISA spells them (`OPCODE_WR_WMEM`).
- File names use dashes between words (`load-engine.sv`, `tb-isa.cpp`); the
  module inside keeps underscores (`load_engine`), since identifiers can't
  contain `-`. Python files stay snake_case so they can be imported, and
  Platform Designer's `tpu_hw.tcl` keeps the `_hw.tcl` suffix it requires.
- Ports, declarations and runs of assignments are aligned in columns.
- Synchronous, active-high `reset` inside modules (only the top exposes
  active-low `reset_n`); every sequential block is `if (reset) ... else ...`.
- Tunables are `parameter int`; derived values are `localparam`.
- The instruction encoding lives in one table, `host/tpu/isa.py`, mirrored by
  `rtl/common/tpu-pkg.sv`. Change both together, and reuse the constants rather
  than re-declaring literals.
- Each module opens with a short comment naming what it is. Beyond that,
  comments are sparse: short, lowercase (unless the first word is all caps),
  and about a decision or a low-level trap, not a restatement of the code.
  Explanations, contracts and latencies belong in `docs/`.

## Commit / PR notes

- Keep commits focused and messages short and descriptive.
- Make sure `make check` passes; say in the message whether a result came from
  simulation or the board.
