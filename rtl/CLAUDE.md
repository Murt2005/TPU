# rtl/ — synthesizable SystemVerilog

## House style (match it; `make lint` enforces some of it)

- `snake_case` signals. `in_*` / `out_*` port prefixes. Every data bus gets a
  `*_valid` companion.
- Synchronous, **active-high** `reset` inside modules; only the top level
  exposes active-low `reset_n`. Every sequential block is
  `if (reset) ... else ...`.
- Tunables are `parameter int`; derived values are `localparam`.
- Shared constants (opcodes, status bytes, data/psum widths) live in
  `tpu_pkg.sv` — reuse them, never re-declare literals.
- Every module opens with a header comment stating **role, contract, and
  latency**. Keep new ones consistent.
- `import tpu_pkg::*;` goes at compilation-unit scope, *before* the module —
  the one form yosys's frontend accepts. `tpu_pkg.sv` must be read first;
  the build dep lists guarantee that.

## The parameterization pattern

Four parameters thread through every module. Nothing is hardcoded to 2×2.

| Parameter | Meaning | Constraint |
|---|---|---|
| `ARRAY_ROWS` | K-tile depth (systolic rows) | even if `USE_MAC16_PAIR=1` |
| `NUM_COLS` | N-tile width (systolic columns) | — |
| `M_TILE` | activation rows streamed per `RUN` | — |
| `PSUM_WIDTH` | accumulate/bias/result width | multiple of 8; 16 if `USE_MAC16_PAIR=1` |
| `FIFO_DEPTH` | `tpu_top.sv` only | power of 2, ≥ `max(ARRAY_ROWS, M_TILE)` |

Rules when touching parameterized code:

- **Index the right axis.** `ARRAY_ROWS` and `NUM_COLS` are interchangeable
  only at 2×2, which is why the `unified_buffer` ROWS/COLS bug survived so
  long. Any new loop must be checked at a shape where all three axes differ.
- **Add a shape variant test** for anything shape-sensitive.
  `tests/tpu_sequencer_4x2_tb.sv` (`ARRAY_ROWS=4, NUM_COLS=2, M_TILE=3`) is
  the all-axes-distinct bench — a row/col confusion cannot pass by
  coincidence there.
- Sizes derive from parameters, never from literals: weight frames are
  `ARRAY_ROWS*NUM_COLS`, activation frames `M_TILE*ARRAY_ROWS`, results
  `PSUM_BYTES*M_TILE*NUM_COLS` (`PSUM_BYTES = PSUM_WIDTH/8`).

## Latency is a contract

The datapath has **no handshakes or backpressure** beyond fixed registered
latencies, and `tpu_sequencer.sv` replays an exact cycle sequence against
them. **Changing any module's latency breaks the sequencer silently.** If you
add or remove a register stage, update the sequencer's states and the latency
table in the module header and in `docs/architecture.md` §2.

Current: UB write 1 · UB read 2 · SDS row *i*: *i* · WF drain 1 · PE 1 ·
MMU col *c*: 2+*c* · accumulator 2 · bias 1 · activation 1. End-to-end
per-row: **7 cycles**.

## Testbench conventions

- One `tests/<name>_tb.sv` per module, self-checking, `int errors = 0`.
- Print `PASSED` on success; use `$error`/`$fatal` or a `[FAIL]` string on
  failure — `run_tests.sh` classifies on those strings.
- `uut (.*)` connection style; `always #5 clk = ~clk;` (100 MHz / 10 ns).
- Drive inputs on one edge, check outputs on the next; wrap it in a
  self-checking `task` rather than inlining assertions.
- **Every testbench pulses reset at time zero.** That is exactly why sim
  could not catch the power-on-reset bug (`tpu_top.sv`'s POR counter exists
  because `reset_n` idles high from configuration on real hardware). Don't
  assume sim-green means silicon-green.
- Register a new bench in **three** places in the root `Makefile`: a
  `DEPS_<name>` line, an entry in `TESTS`, and a `build-<name>` +
  `$(SIM_DIR)/<name>.vvp` rule pair.

## Target-specific code

`tpu_core.sv` is board-neutral and must stay that way — no host interface, no
vendor primitives. Everything target-specific lives in a top level
(`tpu_top.sv` / `tpu_top_hps.sv`) or a PHY (`uart_*`, `spi_slave`,
`hps_bridge`).

`pe_pair.sv` is the exception: it hand-instantiates Lattice `SB_MAC16` and is
**iCE40-only**. It is guarded by `USE_MAC16_PAIR` and must never be reachable
from a Cyclone V build. Its bit-exactness vs. two `pe.sv` instances is
verified cycle-accurate in `tests/pe_pair_tb.sv` against yosys's own
primitive model (extracted at build time to `sim/sb_mac16_sim.v` — single
source of truth; don't vendor a second copy).

## Before trusting an RTL change

`make test` + `make lint`. Add `make verilate-test` for anything touching a
PHY or the sequencer. Add `make hw-test` for anything touching synthesis
flags, primitives, or memory inference — the netlist tiers are trusted on
that suite passing bit-exactly, not on inspection.
