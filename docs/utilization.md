# Utilization

How much of the array actually does work, how much of the wire actually
carries operands, and what a command interface designed around those answers
would look like.

Every cycle count here was measured by tracing the RTL (`viz/trace_tb.cpp` →
`viz/vcd_to_trace.py`). Byte counts are computed from the shipped tiling in
`tpu_host.py`. Projections say so.

## 1. The array is idle 84–93% of the time

One `RUN_TILE` pass, by phase:

| Shape | Pass | Load | Stream | Drain | Cycles feeding rows |
|---|---|---|---|---|---|
| 2×2 M_TILE=2 | 19 | 7 | 2 | 10 | **11%** |
| 4×4 M_TILE=4 | 29 | 11 | 4 | 14 | **14%** |
| 8×8 M_TILE=4 | 45 | 19 | 4 | 22 | **9%** |
| 8×8 M_TILE=8 | 49 | 19 | 8 | 22 | **16%** |

MAC-slot utilization over a pass — useful multiplies divided by
`PEs × cycles` — runs 7.4% to 16.3%.

**The structure that causes it:** useful work is `O(M_TILE)`, overhead is
`O(ARRAY_ROWS + NUM_COLS)`.

```
pass = load(ARRAY_ROWS+3) + stream(M_TILE) + drain(ARRAY_ROWS+NUM_COLS+6)
```

A weight-stationary array is supposed to amortize one weight load across many
activation rows. This one amortizes it across four or eight. The drain is the
wavefront physics — the last activation still has to cross the array — and
cannot be removed, only overlapped.

**A bigger array is worse, not better.** 8×8/M_TILE=4 (9%) is less efficient
than 4×4/M_TILE=4 (14%), because `R+C` grew while `M_TILE` did not. This is
the number to watch on the DE1-SoC scale-up: raising `ARRAY_ROWS`/`NUM_COLS`
without raising `M_TILE` buys compute density and spends it on fill and drain.

## 2. The double-buffering already exists and is not wired up

`rtl/weight_fifo.sv` implements full ping-pong banks — its header describes
loading the shadow bank while the active bank drains. `rtl/tpu_core.sv` ties
`shadow_loaded`, `active_bank` and `any_shadow_full` to nothing, and the
sequencer never pulses `swap_banks` early. Every pass loads, computes, and
drains to completion before the next begins.

The second-order cost is the one that matters. Because the sequencer
serializes *receive → compute → receive*, it stops consuming RX between
tiles — and that is the **sole** reason the SPI write clock is capped at
`CLK/6` ([`protocol.md`](protocol.md) §3). One change lifts both ceilings:

- per-tile cost falls from 45–49 cycles toward the `M_TILE`-cycle streaming
  limit (**3–6×**, projected)
- the write clock could approach `CLK/2` instead of `CLK/6` (**~3×** wire,
  projected — inferred from the stated cause of the cap, not measured)

Cost: it is the most invasive change available to `tpu_sequencer.sv`, whose
counter-driven FSM replays exact cycle sequences against fixed datapath
latencies. [`verification.md`](verification.md)'s Tier 4 is the only tier that
would catch a mistake in it.

> `backlog.md` files this as low-value, worth "~2 ms at most". That estimate
> predates these measurements and misses the SPI-clock coupling entirely.

## 3. Where the bytes go

MNIST 144→64→10 at 4×4/M_TILE=2, 20 images:

| | KB over the wire |
|---|---|
| As shipped | 292.5 |
| Weights resident (sent once) | 107.2 |
| Resident **and** batched at M_TILE=4 | 58.5 |

**Weight residency alone is only 2.7×, and that is the surprise.** Once
weights stop repeating, *padded activations* dominate: 97.5 KB of the
remaining 107.2 KB. The two fixes are not independent and neither is
sufficient — together they are ~5×.

The padding is severe. Layer 1 needs **144** activation bytes for one image;
the wire carries **4,608**, because every tile ships `M_TILE × ARRAY_ROWS`
bytes whether the rows are real or zero. At M=1 that is a **32× blowup**,
identical at 4×4 and 8×8.

**Frame efficiency collapses as the array grows**, because one tile must fit
inside a 255-byte `LEN`:

| Shape | Tile bytes | Tiles per frame |
|---|---|---|
| 2×2 M_TILE=2 | 8 | 31 |
| 4×4 M_TILE=2 | 24 | 10 |
| 8×8 M_TILE=4 | 96 | **2** |

At 8×8 a round trip carries 196 payload bytes. This is why `llm/infer.py`
needs ~28k frames per token.

## 4. What to do, in order

| # | Change | Payoff | Cost |
|---|---|---|---|
| 1 | Batch images into `M_TILE` | ~3× wire on inference | Host only, no RTL |
| 2 | Addressable resident weights | ~1.7× more on top of #1 | Protocol + RTL |
| 3 | Shadow-bank overlap | 3–6× compute **and** ~3× wire | Sequencer rework |
| 4 | Raise `M_TILE` | 8.9% → 16.3% at 8×8 | Free, but see below |
| 5 | Accumulator lockstep gate | `NUM_COLS−1` cycles/pass | Needs row tagging |

**#1 first.** On the real workload the wire is ~97% of wall-clock
([`performance.md`](performance.md) §1), so the host-side change with no RTL
risk is also the largest win per hour of work.

**#4 has a trap.** Result bytes are `PSUM_BYTES × M_TILE × NUM_COLS` against
the 255-byte `LEN` cap. At 8×8, `M_TILE=8` fits at `PSUM_WIDTH=16` (128
bytes) but **not** at 32 (256). The `llm/` path cannot take this lever
without a protocol change — which §5 is.

## 5. The command interface

### What is actually wrong with it

Not the opcodes. Three structural properties:

**Operands are positional, never named.** `RUN_TILE` and `STREAM_RUN` carry
weights *inline*, by construction. There is no way to say "multiply by the
weights you already have", so every invocation re-ships all of them. This is
not an oversight to patch — it is the reason §3's first row exists.

**`LEN` is one byte.** Every cap in §3 traces to it. It also forces
`STREAM_RUN`'s cross-frame `TILE_FIRST`/`TILE_LAST` chaining, which exists
only to reassemble a K-run that did not fit.

**Decode is expensive.** `performance.md` §2 attributes ~1,050 FFs to staging
matrix bytes twice — an RX payload buffer plus the decoded register copies.
That is a consequence of variable-length framing with a buffered payload.

### A sketch of an instruction stream

Fixed 32-bit instructions, no length prefix, bulk data following the
instruction that consumes it. Closer to TPUv1's own ISA, which separates
`Read_Weights` from `MatrixMultiply` rather than bundling them.

```
 31    27 26                                    0
+--------+--------------------------------------+
| opcode |              operands                |
+--------+--------------------------------------+
```

| Op | Operands | Meaning |
|---|---|---|
| `LDW` | bank[1], n[10] | next `n × ARRAY_ROWS × NUM_COLS` bytes are weight tiles → `bank` |
| `LDA` | addr[8], n[10] | next `n × ARRAY_ROWS` bytes are activation rows → UB at `addr` |
| `LDB` | n[8] | bias vector follows |
| `MM` | bank[1], addr[8], n[10], flags[4] | run `n` tiles from `bank`, activations at `addr` |
| `ST` | n[10] | stream `n` result rows back |
| `SYNC` | — | block until the pipeline drains |

What this buys, directly against §3 and §4:

- **Weights become nameable.** `MM bank=0` reuses what is already on-chip.
  That is the mechanism §4 #2 needs; nothing in today's framing can express
  it.
- **The 255-byte cap disappears.** `n` is 10 bits, so one `LDW` covers 1023
  tiles. No `LEN`, no cross-frame chaining, no `TILE_FIRST`/`TILE_LAST`
  bookkeeping for K-runs that merely overflowed a frame.
- **Instruction density.** At 8×8 a tile costs 96 inline bytes today; an
  addressed `MM` naming bank, address and count is 4 bytes — **24× denser**.
- **Load and compute become separable**, which is the protocol half of §2's
  shadow-bank overlap. `LDW bank=1` can execute while `MM bank=0` runs.
- **Decode gets cheaper.** Fixed width needs a 4-byte shift register and no
  payload buffer.

### What it costs, and why not yet

A stream has no frame boundary to resynchronize on. Today a framing error
answers `STATUS_ERR` and the sequencer returns to `S_IDLE`; a desynced
instruction stream is unrecoverable without a distinguished sync word and a
recovery path. That is real design work, not a detail.

It is also a rewrite of `tpu_sequencer.sv`, `tpu_host.py` and
`firmware/tpu_tile.c` together, with Tier 4 unavailable to catch mistakes.

**The staged path is better.** Most of §4 #2's win needs exactly one new
thing: naming weights that are already loaded. That is a single opcode on the
existing framing — a `RUN_TILE` variant carrying `bank` instead of inline
weights — and it is a fraction of the risk. Take the full instruction stream
when the DE1-SoC scale-up makes the 255-byte cap and the decode cost bind,
not before.

## 6. Caveats

Cycle counts are exact, from RTL traces. The wire figures are computed from
the shipped tiling, not measured on a board. The `CLK/2` SPI figure is
inferred from the documented cause of the `CLK/6` cap, and the 3–6× overlap
figure is a projection from the phase breakdown in §1 — neither has been
built or measured.
