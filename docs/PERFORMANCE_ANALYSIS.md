# Where the time and the LUTs actually go

> **Status update (2026-07-11):** §2's `-dsp` finding and §4's Tier 1 are now
> **implemented and hardware-verified** (see `docs/SEQUENCER_REDESIGN.md`'s
> status block for the full trail). Measured: `-dsp` takes the whole design
> 2,592 → 2,138 LCs (40%) with 4/8 `SB_MAC16` used, fMax 30.66 MHz;
> Tier 1 landed at **1,000,000 baud** (exact ÷12 divisor, not the 921600
> assumed below) for **315.6 ms/image** — better than this doc's ~1,690 ms
> Tier-1+2 projection because Tiers 2+3 had already landed first, and the
> firmware reflash + faster pacing also shrank the per-transaction overhead
> term (632 → 102 ms/image). The numbers below are the pre-Tier-1/2/3
> baseline measurements and remain valid as the analysis trail.
>
> §3's scale-up also landed, with two corrections to its budget: yosys
> `-dsp` maps *all* PE multiplies to `SB_MAC16` with no per-instance
> opt-out, so the "mix DSP and LUT PEs" ceiling of ~20 PEs is not reachable
> — 4×4 needs 16 DSPs (8 exist) and 5,610 LCs (106%). The real ceiling is
> **8 PEs, all DSP-backed**; of those shapes 2×4 beats §3's recommended
> 4×2-style deepening because act wire bytes scale as 1/NUM_COLS. Shipped:
> **2×4/M_TILE=2**, 3,538 LCs (67%), 8/8 DSPs, fMax 31.61 MHz,
> **239.65 ms/image** (33x from this doc's 8,001 ms baseline). See
> SEQUENCER_REDESIGN.md's status block for the firmware race this exposed.

Three questions, answered with real measurements from this repo's hardware and
toolchain, not estimates: (1) of the ~8s/image on pico2-ice, how much is
actual TPU RTL execution vs. communication overhead? (2) how much of the
iCE40UP5K is this 2×2 array actually using, and could it be bigger? (3) what
would it take to shrink the communication bottleneck?

Each section below has its own "Reproduce" block. §1 needs a pico2-ice
board plugged in and flashed with `fpga/tpu_top.bin`; §2 and §3 only need
`yosys`/`nextpnr-ice40` (`brew install yosys nextpnr-ice40 icestorm`); §4 is
analysis derived from §1 and §2's numbers, nothing new to run.

## 1. Splitting pico2-ice's latency into UART time vs. RTL time vs. "other"

Reproduce (prints both the UART-wire/RTL/overhead breakdown table and the
Mac one-at-a-time-vs-batched table in "Mac's side of the same question"
below):
```bash
python3 mnist/infer.py --port /dev/cu.usbmodemXXXX --compare --test-n 20
```

`tpu_host.TPU` now tracks exactly how many bytes and command round-trips
cross the wire per command type (`self.stats`, keyed by command byte). One
classification image through the 144→64→10 model measured on real hardware:

| Command | Calls | Bytes tx | Bytes rx |
|---|---|---|---|
| `LOAD_BIAS` | 37 | 222 | 74 |
| `LOAD_WEIGHTS` | 2,464 | 14,784 | 4,928 |
| `LOAD_ACT` | 2,464 | 14,784 | 4,928 |
| `RUN` | 2,464 | 7,392 | 5,224 |
| **Total** | **7,429** | **37,182** | **15,154** |

That's **52,336 bytes and 7,429 separate command/response round-trips per
image** — one 2×2 tile at a time, exactly as `tpu_host.matmul_tiled()` is
written (§5 of `docs/sequencer_uart_design.md` already flagged this: the
protocol is single-shot request/response, no pipelining).

Breaking the measured ~8,001 ms/image down three ways (`TPU.uart_wire_seconds()`
and `TPU.estimated_rtl_seconds()`, both new):

| Component | Time/image | Share | How it's computed |
|---|---|---|---|
| UART wire time | 4,543 ms | 56.8% | `total_bytes × 10 bits/byte ÷ 115200 baud` — real bit-shifting time, independent of clock speed |
| RTL execution | **5.14 ms** | **0.1%** | `num_RUNs × 21 cycles ÷ 12 MHz` — 21 cycles is the cycle-accurate dispatch-to-result count from `docs/sequencer_uart_design.md` §3.3 |
| USB/pyserial/Python overhead | 3,453 ms | 43.2% | measured total minus the two above |

**The actual systolic array computation is 0.1% of the wall-clock time.**
Everything else is protocol: more than half is literal UART bit-shifting at
115200 baud, and — this is the more interesting result — a nearly-equal
43% is *not* UART at all, it's the round-trip cost of doing 7,429 separate
Python `serial.write()`/`serial.read()` calls (each one crossing USB from
the Mac to the RP2350's TinyUSB CDC stack and back). That works out to
**≈0.465 ms of pure software/USB overhead per transaction**, on top of
whatever time the bytes themselves take to shift out. Likely contributors
(not independently isolated here): pyserial syscall overhead, USB
full-speed frame granularity, and TinyUSB's CDC buffering — a packet-level
USB capture would be needed to attribute the 43% precisely, but the
transaction-count-not-byte-count pattern (see §3 below) makes "per-call
overhead" the right mental model regardless of which layer contributes most.

### Mac's side of the same question

The Mac path has no analogous external bus, but it does have its own
call-dispatch cost: `mnist/infer.py --compare` also reports the gap between
running the model one image at a time (`OfflineBackend`, one Python
call/image, mirroring the hardware's call pattern) and running the exact
same math as a single batched numpy op:

| Path | Time/image |
|---|---|
| Mac, one image at a time | 0.20 ms |
| Mac, batched/vectorized | 0.01 ms |
| → Python/numpy dispatch overhead | 0.19 ms (95% of the one-at-a-time number) |

Same shape of finding, five orders of magnitude smaller: even on a laptop,
almost all of the "one at a time" cost is call/dispatch overhead, not
arithmetic. The RTL-only vs. Mac-only comparison that actually isolates
compute is **5.14 ms/image (FPGA) vs. 0.01–0.20 ms/image (Mac)** — a
25–500x gap, not the ~90,000x gap in the raw wall-clock numbers. That's the
honest "just the arithmetic" comparison, and the FPGA still loses it
decisively (expected: a 2×2 array does 4 int8 MACs/cycle at 12 MHz = 48
MMAC/s; one Apple Silicon CPU core does orders of magnitude more per cycle
via SIMD). The wall-clock gap is almost entirely a protocol tax, but the
protocol tax isn't hiding a competitive datapath underneath — see §4.

## 2. Current LUT usage on the iCE40UP5K

Reproduce:
```bash
cd fpga && make clean && make
nextpnr-ice40 --up5k --package sg48 --pcf tpu_top.pcf \
    --json tpu_top.json --asc /tmp/out.asc 2>&1 | grep -A15 "Device utilisation"
```

Rebuilt from source with the real toolchain (`yosys`/`nextpnr-ice40`, not
estimated):

| Resource | Used | Available | % |
|---|---|---|---|
| ICESTORM_LC (LUT4+FF logic cells) | 2,592 | 5,280 | 49% |
| SB_GB (global buffers) | 8 | 8 | **100%** |
| ICESTORM_DSP (hard 16×16 MAC) | **0** | 8 | **0%** |
| ICESTORM_RAM (4Kb EBR blocks) | 0 | 30 | 0% |
| SB_IO | 4 | 96 | 4% |

Two things jump out. **All 8 global buffers are already claimed** by a
design this small — worth watching if scaling adds more high-fanout control
signals (`loading_phase`, `swap_banks`, per-row/per-column enables), since
nextpnr will fall back to regular (slower, more congested) routing once
they're gone, not fail outright. And **zero of the 8 hardware DSP
multiply-accumulate blocks are used** — every int8 multiply in `pe.sv` is
currently being built out of raw LUTs. That second one turned out to be the
single biggest lever in this whole investigation:

### The `-dsp` finding

Reproduce (run from the repo root, `rtl/pe.sv` standalone, both ways):
```bash
yosys -p "read_verilog -sv rtl/pe.sv; synth_ice40 -top pe -json /dev/null" \
    2>&1 | grep -E "SB_LUT4|SB_DFF|SB_MAC16"

yosys -p "read_verilog -sv rtl/pe.sv; synth_ice40 -top pe -dsp -json /dev/null" \
    2>&1 | grep -E "SB_LUT4|SB_DFF|SB_MAC16"
```

`synth_ice40` (yosys) only infers the iCE40UP5K's hard `SB_MAC16` blocks
when passed `-dsp`; `fpga/Makefile` doesn't pass it today. Synthesizing
`pe.sv` standalone both ways:

| | LUT4 | DFF | Hard MAC |
|---|---|---|---|
| without `-dsp` (current) | 251 | 43 | 0 |
| with `-dsp` | 36 | 43 | 1 (`SB_MAC16`) |

**A single PE drops from ~251 LUTs to 36 LUTs — a ~7x reduction — by
changing one synthesis flag, no RTL changes at all.** Applied to the
current 4-PE array, that's roughly 860 → 144 LUTs for the MMU alone
(measured standalone-module cost, see table below), which would pull the
*whole design* from 2,592 down to somewhere around 1,700–1,900 LC (~32–36%
utilization) with identical behavior. This should be validated against
`make test`/`make hw-test` before trusting it (DSP-mapped multiply should
be bit-exact, but "should be" isn't "verified" — the existing regression
suite would need to pass against the `-dsp` bitstream to actually adopt this).

### Per-module standalone LUT footprint

Reproduce each row with `yosys -p "read_verilog -sv <files>; synth_ice40 -top
<module> -json /dev/null" 2>&1 | grep SB_LUT4 | tail -1` — `<files>` includes
a module's own internal instantiations (`mmu` needs `pe.sv`; `accumulator`
and `weight_fifo` need `fifo.sv`), everything else stands alone:

```bash
# run from the repo root
yosys -p "read_verilog -sv rtl/pe.sv rtl/mmu.sv; synth_ice40 -top mmu -json /dev/null" 2>&1 | grep SB_LUT4 | tail -1
yosys -p "read_verilog -sv rtl/tpu_sequencer.sv; synth_ice40 -top tpu_sequencer -json /dev/null" 2>&1 | grep SB_LUT4 | tail -1
yosys -p "read_verilog -sv rtl/fifo.sv rtl/accumulator.sv; synth_ice40 -top accumulator -json /dev/null" 2>&1 | grep SB_LUT4 | tail -1
yosys -p "read_verilog -sv rtl/fifo.sv rtl/weight_fifo.sv; synth_ice40 -top weight_fifo -json /dev/null" 2>&1 | grep SB_LUT4 | tail -1
yosys -p "read_verilog -sv rtl/unified_buffer.sv; synth_ice40 -top unified_buffer -json /dev/null" 2>&1 | grep SB_LUT4 | tail -1
yosys -p "read_verilog -sv rtl/uart_rx.sv; synth_ice40 -top uart_rx -json /dev/null" 2>&1 | grep SB_LUT4 | tail -1
yosys -p "read_verilog -sv rtl/uart_tx.sv; synth_ice40 -top uart_tx -json /dev/null" 2>&1 | grep SB_LUT4 | tail -1
yosys -p "read_verilog -sv rtl/bias.sv; synth_ice40 -top bias -json /dev/null" 2>&1 | grep SB_LUT4 | tail -1
yosys -p "read_verilog -sv rtl/activation.sv; synth_ice40 -top activation -json /dev/null" 2>&1 | grep SB_LUT4 | tail -1
yosys -p "read_verilog -sv rtl/systolic_data_setup.sv; synth_ice40 -top systolic_data_setup -json /dev/null" 2>&1 | grep -E "SB_LUT4|SB_DFF" | tail -1
```

Each module synthesized alone (not the flattened whole-design numbers,
which are lower due to cross-module optimization — these are for relative
sizing, not exact budget accounting):

| Module | LUT4 | Note |
|---|---|---|
| `mmu` (2×2, 4 PEs) | 860 | dominant cost today; → ~144 with `-dsp` |
| `tpu_sequencer` | 289 | protocol FSM, hardcoded per-row states |
| `accumulator` (NUM_COLS=2) | 293 | includes 2 embedded `fifo` instances |
| `weight_fifo` (2 cols) | 228 | includes its own `fifo` instances |
| `unified_buffer` (2×2) | 176 | |
| `uart_rx` | 73 | |
| `uart_tx` | 43 | |
| `bias` | 33 | |
| `activation` | 31 | |
| `systolic_data_setup` | 0 (9 DFF only) | pure shift-register, no LUT logic |

## 3. Can the array actually be scaled up? (Pushing back on 256×256)

This section is arithmetic on §2's measured LUT counts (no new synthesis
runs); the module-readiness table below is reproduced by inspecting each
file's parameter list directly:
```bash
grep -n "^module\|parameter" rtl/unified_buffer.sv rtl/systolic_data_setup.sv \
    rtl/accumulator.sv rtl/bias.sv rtl/activation.sv rtl/weight_fifo.sv \
    rtl/mmu.sv rtl/tpu_sequencer.sv rtl/tpu_top.sv
```

**No — not on this chip, and not close.** A 256×256 array is 65,536 PEs.
Even at the optimized ~36 LUT/PE (`-dsp`) rate, that's ~2.36 million LUTs;
the iCE40UP5K has 5,280 total. You'd need a chip roughly **450x** bigger
than this one, which means a different, much larger (and non-hobbyist-priced)
FPGA family entirely — this is not an RTL-efficiency problem, it's off by
two and a half orders of magnitude on device size. Worth being blunt about
so no redesign effort gets spent chasing it on this board.

**A modest scale-up is genuinely feasible, though.** Rough budget, using the
`-dsp` PE cost and treating everything else as ~1,700 LUTs of roughly-fixed
overhead (it will grow somewhat with array size — wider buses, more
per-column FIFOs — but the PE count dominates the delta):

- 5,280 total − ~1,700 non-PE overhead ≈ 3,580 LUTs available for PEs.
- First 8 PEs (all 8 available `SB_MAC16` blocks): ~36 LUT/PE ≈ 288 LUTs.
- Remaining ~3,290 LUTs at the no-DSP ~251 LUT/PE rate (once hardware DSPs
  run out): ~13 more PEs.
- **Rough ceiling: ~20 PEs** — e.g. a 4×4 (16 PEs, all DSP-backed) or
  stretching toward 4×5/5×4 (mixing DSP and LUT-based PEs) is a believable
  target; anything approaching even 8×8 (64 PEs) is already tight, and
  16×16 (256 PEs) is out of reach on this device, let alone 256×256.

A 4×4 array is the concrete recommendation: quadruples the per-RUN tile
size, cutting the *number* of `RUN`/`LOAD_WEIGHTS`/`LOAD_ACT` round-trips
for this model by roughly 4x (fewer, larger tiles), which — per §1's
breakdown — directly attacks the 43% "per-transaction overhead" term
without touching baud rate at all.

### What actually needs redesigning to get there

Checked each module's parameter list directly rather than assuming:

| Module | Status | Work needed |
|---|---|---|
| `unified_buffer.sv` | already parameterized (`ROWS`, `COLS`, `DATA_WIDTH`) | fix the existing bug flagged in `docs/sequencer_uart_design.md` §5.4: its UB-read loop indexes `mem[bank][addr][c]` over `0..ROWS-1`, should be `COLS` — silently correct today only because `ROWS==COLS==2` |
| `systolic_data_setup.sv` | already parameterized (`ARRAY_ROWS`) | none |
| `accumulator.sv` | already parameterized (`NUM_COLS`, `ARRAY_ROWS`, `PSUM_WIDTH`, `FIFO_DEPTH`) | none functionally; the "all columns non-empty" pop gate (§5.3 of the sequencer doc) costs a bigger bubble as columns grow — still correct, just a fixed-cost tax that scales with `N-1` |
| `bias.sv` / `activation.sv` | already parameterized (`NUM_COLS`) | none |
| `weight_fifo.sv` | already parameterized (`WEIGHT_WIDTH`, `FIFO_DEPTH`, `NUM_COLS`) | none — ports are a generate-block array (`out_col[NUM_COLS]`, `write_enable_col[NUM_COLS]`, etc.), not individually-named per-column signals |
| `mmu.sv` | already parameterized (`ARRAY_ROWS`, `NUM_COLS`, `DATA_WIDTH`, `PSUM_WIDTH`) | none — rewritten as a `generate`-based `ARRAY_ROWS x NUM_COLS` grid of `pe` instances with packed-array ports (`in_row[]`, `in_col[]`, `out_partial_sum[]`, `capture_weight_col[]`), replacing the old `in_row_0/1`/`in_col_0/1`/`out_partial_sum_0/1` scalars |
| `tpu_sequencer.sv` | hardcoded control flow | the FSM has one named state per row/column (`S_WR_UB_0/1`, `S_LD_WF_0/1`, `S_STREAM_0/1`) *by design* — it deliberately mirrors `tests/tpu_core_tb.sv`'s hand-driven task sequence cycle-for-cycle (see design doc §3.1). Scaling rows/columns means replacing named states with counter-driven loops, which is real control-logic work, not a parameter bump |
| `tpu_top.sv` | wiring only | mechanical but tedious: rewire scalar per-column ports into arrays throughout |

So: 7 of 8 modules are ready today; the remaining work is `tpu_sequencer.sv`
(the riskiest one, since its current form is *intentionally* over-explicit
to guarantee cycle-exact parity with the testbenches it was built against).

## 4. Shrinking the UART/USB bottleneck

This section projects from §1's measured numbers — none of the three tiers
are implemented, so there's nothing new to run yet. Once any tier lands,
validate it with the existing regression suite before trusting the new
number:
```bash
make test                      # full RTL simulation regression
make hw-test PORT=/dev/cu.usbmodemXXXX   # real-hardware regression (tests/hw_regression.py)
python3 mnist/infer.py --port /dev/cu.usbmodemXXXX --compare --test-n 20   # re-measure the split
```

Three tiers, ordered by effort, each grounded in the §1 measurements
(4,543 ms/image wire time, 3,453 ms/image overhead at ≈0.465 ms/transaction,
7,429 transactions/image):

**Tier 1 — raise `BAUD_RATE` (trivial, ~2x).** Pure parameter change in
`rtl/uart_rx.sv`/`uart_tx.sv` + matching change in `firmware`/`fpga/Makefile`'s
`CLK_FREQ` relationship + `tpu_host.py --baud`. At 12 MHz, `TICKS_PER_BIT =
CLK_FREQ / BAUD_RATE`; going to ~921,600–1,000,000 baud leaves TICKS_PER_BIT
≈12–13 (still comfortable oversampling margin for the mid-bit sample
scheme in `docs/sequencer_uart_design.md` §1). That's ~8x less wire time
(4,543 → ~525 ms/image), but total only drops to **~3,983 ms/image (~2x)**
overall, because the 3,453 ms/image software overhead term is untouched —
it's driven by transaction *count*, not byte rate. Needs `make
hw-test`/`hw_regression.py` re-validation at the new baud before trusting it.

**Tier 2 — batch commands (moderate, ~4.7x combined with Tier 1).**
Right now each K-tile costs 3 separate round-trips
(`LOAD_WEIGHTS`→`LOAD_ACT`→`RUN`). A combined command that carries weight
+ activation + tiling flags in one frame cuts per-tile transactions from 3
to 1: total transactions/image would drop from 7,429 to ≈2,501 (bias calls
stay separate). At the measured ≈0.465 ms/transaction, overhead drops
≈3,453 → ≈1,162 ms/image. Combined with Tier 1's baud bump: **≈523 + 1,162
+ 5 ≈ 1,690 ms/image, a ~4.7x speedup from today's ~8,001 ms.** Requires a
new/extended sequencer command and matching `tpu_host.py` changes, but no
datapath changes.

**Tier 3 — stream a whole K-run per round-trip (larger redesign, ~14x
combined).** The host currently re-sends weights/activations once per
K-tile even though `matmul_tiled()`'s inner loop already knows the whole
K-run up front. If the sequencer instead accepted one command that streams
an entire row of K-tiles' weights+activations and internally drives
`weight_fifo`'s existing double-buffering to pipeline the loads (a
capability the module already has but the protocol doesn't use — see
`docs/sequencer_uart_design.md` §5.6), the *host* round-trip count collapses
to roughly one per `(m,n)` output block: 37 blocks for this model instead
of 7,429 total transactions. At ≈0.465 ms/transaction that's ≈17 ms/image
of overhead instead of 3,453 ms. Combined with Tier 1's baud bump: **≈523 +
17 + ~10 (compute grows slightly with buffering logic) ≈ 550 ms/image, a
~14x speedup.** This is a genuine sequencer/protocol redesign — new
buffering, a new command, host-side rewrite of `matmul_tiled()` — not a
tuning change, and the highest-value one of the three by a wide margin.

Even Tier 3's ~550 ms/image is still ~3 orders of magnitude slower than the
Mac's 0.01–0.20 ms/image — expected, and not really the point (§1). The
value of these tiers is making the *hardware's own* number reasonable for
interactive use (e.g. the drawing demo), not closing the gap with a
general-purpose CPU.

## Bottom line

- The 2×2 array's actual compute cost is real but tiny (5 ms/image, 0.1%
  of wall-clock) — this was never a "slow datapath" problem, it's a
  "chatty protocol" problem, confirmed with exact byte/transaction counts,
  not guesses.
- The single highest-leverage, lowest-risk change available today is
  turning on `-dsp` in synthesis — a ~7x per-PE LUT reduction for free,
  no RTL edits, pending regression re-validation.
- A 256×256 array is not on the table for this chip; a ~4×4 (16 PE) array
  is a believable, concretely-budgeted stretch goal, and even that needs a
  real rewrite of `tpu_sequencer.sv` (7 of 8 core modules are already
  parameterized and ready).
- UART/USB overhead has two independent levers (byte rate vs. transaction
  count) and the transaction-count lever (currently untouched) is worth
  about as much as the baud-rate lever people usually reach for first.
