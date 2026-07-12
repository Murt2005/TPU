# `tpu_sequencer.sv` FSM redesign + UART batch-command redesign

Companion to `docs/PERFORMANCE_ANALYSIS.md` §3 (scaling the array) and §4 (shrinking
the UART bottleneck). Both of those sections point at the same two pieces of
unfinished work — `tpu_sequencer.sv` is the one core datapath-adjacent module that
is *not* parameterized, and the UART protocol is still single-shot
request/response with no batching (Tier 2/3 there). This doc lays out concrete
RTL and protocol changes for both, since they interact: a bigger array only pays
off if the sequencer can drive it *and* the host can feed it without paying a
UART round-trip per tile.

**Status (2026-07-10): §0, §2, §4, §3.1 (`CMD_RUN_TILE`), both §3.3 cleanups,
and validation steps §5.1–5.4 are implemented and verified on hardware.**
- The `unified_buffer` ROWS/COLS bug is fixed; `tpu_sequencer.sv` is fully
  parameterized (`ARRAY_ROWS`/`NUM_COLS`/`M_TILE`, counter-driven loop states,
  array ports); `tpu_top.sv` threads the parameters through every submodule
  (scalar glue deleted). `tests/tpu_sequencer_4x2_tb.sv` proves the
  generalization at `ARRAY_ROWS=4, NUM_COLS=2, M_TILE=3` (all three axes
  distinct), including K-tiling and `RUN_TILE` at that shape.
- `CMD_RUN_TILE` (0x06) is live: one frame per K-tile, weights in natural
  row-major order on the wire (§5.5's cleanup — the sequencer reorders
  internally), `rx_error` wired into the sequencer with an explicit
  `STATUS_ERR` on framing errors (§5.7's cleanup). `tpu_host.py` gained
  `run_tile()` and `matmul_tiled()` uses it; the legacy commands and
  `matmul()` are unchanged as a fallback.
- `CMD_STREAM_RUN` (0x07, §3.2) is live in its non-overlapped form (§5.5's
  ordering — the shadow-bank pipelining overlap from §3.2 step 3 is still
  open). Two deviations from §3.2's sketch, both forced by reality:
  - **A `flags` byte precedes `K_TILES`** (`payload = [flags, K_TILES,
    tiles…]`, flags = TILE_FIRST/TILE_LAST for the frame's first/last tile).
    §3.2's "31 tiles per frame is plenty for MNIST" claim is wrong — layer 1
    (K=144) needs 72 K-tiles per output block, so a K-run must chain across
    frames; the flags byte does that with the accumulator semantics RUN/
    RUN_TILE already have, keeping the uniform 1-byte-LEN framing instead
    of the 16-bit-LEN version bump.
  - **No whole-frame buffering in the sequencer** — a 255-byte register
    buffer would be prohibitive on the UP5K. The S_SR_* states deserialize
    each tile's bytes straight into `reg_weights`/`reg_act` and run the
    pipeline pass between tiles, relying on the UART byte cadence
    (~1042 cycles/byte at 12 MHz/115200) dwarfing the ~25–35-cycle pass.
  - Landing this on hardware exposed a real firmware bug: pico-ice-sdk's
    USB→UART bridge **silently drops bytes** once the RP2350's 32-deep UART
    TX FIFO fills, which any frame > 32 bytes triggers. Fixed two ways:
    `firmware/main.c` now swaps in a blocking bridge write (needs a manual
    BOOTSEL reflash of `firmware/build/pico2_ice_bridge.uf2` to take
    effect), and `tpu_host.py` paces >32-byte writes to wire speed, which
    works with the currently-flashed firmware and stays harmless after the
    reflash.
- Verified: `make test` 18/18; `make hw-test` 13/13 on the pico2-ice
  (RUN_TILE-vs-legacy bit-equivalence, and STREAM_RUN K-runs at the frame
  boundaries K_TILES ∈ {1, 3, 31, 32, 40}); `mnist/infer.py` measured
  **7727 → 3986 → 2454 ms/image** (legacy → Tier 2 → Tier 3, 3.15x
  cumulative). Post-Tier-3 breakdown: UART wire 1818 ms = 74%, USB/Python
  overhead 632 ms = 26%. Wire time is now the floor and is irreducible at
  115200 baud — **Tier 1 (baud bump) is decisively the next lever**; after
  that, the §3.2-step-3 shadow-bank overlap and §6's ideas remain.

**Status (2026-07-11): Tier 1 landed at 1,000,000 baud** (exact ÷12 of the
12 MHz clock, `TICKS_PER_BIT = 12`, zero baud error — cleaner than the
921600 the original analysis assumed). `fpga/Makefile` now `chparam`s
`BAUD_RATE` (default 1M) into the bitstream; `tpu_host.py`'s `DEFAULT_BAUD`
matches; the RP2350 bridge needed no change (pico-ice-sdk's
`tud_cdc_line_coding_cb` follows the host's CDC baud). The firmware
blocking-bridge fix from §above is now actually flashed (via the SDK's
1200-baud-touch UF2 reboot — no BOOTSEL press needed). Same session also
enabled `-dsp` synthesis (PE multiplies → `SB_MAC16`, 2592 → 2138 LCs,
fMax 30.66 MHz). Verified: `make test` 18/18, `make hw-test` 13/13 at 1M,
`mnist/infer.py --compare --test-n 20`: **2454 → 315.6 ms/image** (7.8x
this step, 25x cumulative from the 8.0 s baseline; accuracy unchanged).
New breakdown: wire 209.4 ms = 66.4% (exactly the projected 1818/8.68),
USB/Python overhead 101.8 ms = 32.3%, RTL 4.3 ms = 1.4%. Next lever: a
bigger array (§below / PERFORMANCE_ANALYSIS.md §3) cuts both remaining
terms at once — fewer, larger tiles.

**Status (2026-07-11, later): array scaled to 2×4 (8 PEs, all
SB_MAC16-backed) — 315.6 → 239.65 ms/image, 33x cumulative.** Findings:
- 4×4 does **not** fit the UP5K even with `-dsp`: 5,610 LCs (106%) and 16
  multipliers against 8 DSP sites (yosys maps *every* `pe` multiply to
  `SB_MAC16`; there is no per-instance opt-out, so "8 DSP + 8 LUT PEs"
  isn't reachable with a synthesis flag). PERFORMANCE_ANALYSIS §3's ~20-PE
  budget was optimistic on both counts; the practical ceiling is **8 PEs**.
- Of the 8-PE shapes, **2×4 beats 4×2** for this workload: total act bytes
  scale as `K·N·M_TILE/NUM_COLS`, so wider wins (159.3 vs unchanged-or-worse
  wire time; weight bytes = K·N are shape-invariant and now dominate).
  2×4/M_TILE=2 fits at 3,538 LCs (67%), 8/8 DSPs, fMax 31.61 MHz.
- Everything was already parameterized end-to-end: the scale-up needed zero
  RTL changes — just fpga/Makefile shape knobs (`ARRAY_ROWS`/`NUM_COLS`/
  `M_TILE` chparams), a hardware-shape testbench
  (`tests/tpu_sequencer_2x4_tb.sv`, incl. randomized full-int8-range stress
  with wrap-then-ReLU golden), and shape generalization in `tpu_host.py`
  (TPU(rows/cols/m_tile), derived frame sizes, `matmul_tiled()` now
  zero-pads any M/K/N and slices the result) + `tests/hw_regression.py` +
  the mnist drivers (`--rows/--cols/--m-tile`).
- Landing this exposed a **second, nastier firmware bug**: pico-ice-sdk's
  `ice_usb_uart0_to_cdc()` runs in the UART0 RX *interrupt* and calls
  `tud_cdc_n_write_char/_flush` — TinyUSB device APIs with no locking under
  `CFG_TUSB_OS=OPT_OS_NONE` — racing the main loop's `tud_task()`. Rarely
  hit at 115200; at 1 Mbaud (byte every ~10 µs) it wedged the whole USB
  stack (CDC *and* DFU dead, power cycle required) mid-regression.
  `firmware/main.c` now replaces that ISR with a ring-buffer producer and
  drains it to CDC from the main loop (the only TinyUSB caller). RTL was
  exonerated in sim first (tb Test 7/8 randomized stress).
- Verified: `make test` 19/19; `make hw-test NUM_COLS=4` 13/13 (incl. the
  exact stress run that previously wedged); post-scale-up breakdown:
  wire 159.3 ms = 66.5%, USB/Python 78.2 ms = 32.6%, RTL 2.2 ms = 0.9%.
- Remaining levers, in value order: batching `m_tile` images per call in
  `mnist/infer.py` (amortizes the padded act rows a single image wastes),
  §6.2's header packing, §6.3's int4 experiment, and the §3.2-step-3
  shadow-bank overlap (now worth ~2 ms/image at most — likely never).

The remainder below is the original design proposal. Any further work needs
`make test` and `make hw-test` (`tests/hw_regression.py`) to pass before being
trusted, per this repo's existing validation convention.

## 0. Where things actually stand today (re-verified by reading the source, not assumed)

- `rtl/mmu.sv`, `rtl/weight_fifo.sv`, `rtl/accumulator.sv`, `rtl/bias.sv`,
  `rtl/activation.sv`, `rtl/systolic_data_setup.sv`, `rtl/unified_buffer.sv` are
  all genuinely parameterized today (`ARRAY_ROWS`/`NUM_COLS`/`ROWS`/`COLS`,
  generate-block arrays, packed-array ports). This matches
  `PERFORMANCE_ANALYSIS.md`'s table.
- **`rtl/tpu_top.sv` is not actually parameterized for array size**, despite
  having a parameter list. Its four parameters (`CLK_FREQ`, `BAUD_RATE`,
  `WEIGHT_WIDTH`, `FIFO_DEPTH`) don't include `ARRAY_ROWS`/`NUM_COLS` at all —
  every submodule instantiation hardcodes `.ROWS(2)`/`.COLS(2)`/`.ARRAY_ROWS(2)`/
  `.NUM_COLS(2)` literally (`tpu_top.sv:214,234,250,259,272,285,295`), and the
  glue signals between `tpu_sequencer` and the datapath are fixed 2-wide
  (`seq_we_col_0`/`seq_we_col_1` as separate scalars, packed into a `[1:0]`
  array by hand at `tpu_top.sv:182-187`). So "should be parameterized already"
  doesn't hold for array size — only for the four listed scalars. This is
  exactly the "wiring only... mechanical but tedious" row in
  `PERFORMANCE_ANALYSIS.md`'s module table.
- `rtl/tpu_sequencer.sv` is fully hardcoded to 2×2, by design (see its own
  header comment and `docs/sequencer_uart_design.md` §3.1): one named FSM state
  per row/column (`S_WR_UB_0/1`, `S_LD_WF_0/1`, `S_STREAM_0/1`), fixed-size
  register-file arrays (`reg_weights[4]`, `reg_act[4]`, `payload[8]`), and
  scalar per-column ports (`write_enable_col_0`, `write_enable_col_1`) instead
  of the array-port convention every other module now uses. This is the one
  piece of real control-logic work left, and §2 below is about that.
- **Prerequisite bug, independent of everything else here**: `unified_buffer.sv`
  declares `ub_read_data` as `[ROWS-1:0][DATA_WIDTH-1:0]` and its UB-read loop
  indexes `mem[bank][addr][c]` for `c` in `0..ROWS-1`
  (`unified_buffer.sv:39,118-119`) — both should be `COLS`, since a single read
  returns one address's row of `COLS` elements, not `ROWS` of them. It's silently
  correct today only because `ROWS==COLS==2`. **Fix this before generalizing to
  non-square tiles** (e.g. `ARRAY_ROWS != NUM_COLS`, or a UB depth that differs
  from either) — otherwise the generalized sequencer will read garbage on any
  shape where the numbers diverge.

## 1. Parameter model for the redesign

Three independent size axes, all currently conflated at "2" in the 2×2 design:

| Parameter | Meaning | Currently | Lives in |
|---|---|---|---|
| `ARRAY_ROWS` | systolic rows = K-tile depth (weight rows, activation columns-per-row streamed into the array) | 2 | `mmu`, `accumulator`, `systolic_data_setup` |
| `NUM_COLS` | systolic columns = N-tile width (weight columns, output columns) | 2 | `mmu`, `weight_fifo`, `accumulator`, `bias`, `activation` |
| `M_TILE` | UB address depth = number of activation rows streamed per `RUN` (M-tile height) | 2 (`unified_buffer`'s `ROWS`) | `unified_buffer` |

`unified_buffer`'s `COLS` must equal `ARRAY_ROWS` (its read port feeds
`systolic_data_setup`'s `ARRAY_ROWS`-wide input) — that's a datapath contract,
not something the sequencer chooses independently. `M_TILE` is the number of
`S_WR_UB_*`/`S_STREAM_*` state repetitions, and is logically separate from
`ARRAY_ROWS`/`NUM_COLS` even though today all three happen to be 2.

`tpu_sequencer` should take `ARRAY_ROWS`, `NUM_COLS`, `M_TILE` (default `=
ARRAY_ROWS`, matching today's behavior) as parameters, matching the convention
`mmu`/`weight_fifo`/`accumulator` already use.

## 2. FSM redesign: named per-row/col states → counter-driven loops

### 2.1 Port list: scalars → arrays

Today (`tpu_sequencer.sv:93-107`):
```systemverilog
output logic              write_enable_col_0,
output logic signed [7:0] write_data_col_0,
output logic              write_enable_col_1,
output logic signed [7:0] write_data_col_1,
...
output logic signed [1:0][7:0] host_write_data,
...
output logic signed [1:0][15:0] out_bias,
```
Redesigned, matching `weight_fifo`/`mmu`/`bias`'s existing array-port style:
```systemverilog
output logic              [NUM_COLS-1:0]              write_enable_col,
output logic signed       [NUM_COLS-1:0][WEIGHT_WIDTH-1:0] write_data_col,
...
output logic signed       [ARRAY_ROWS-1:0][7:0]        host_write_data,
...
output logic signed       [NUM_COLS-1:0][15:0]         out_bias,
```
This also means `tpu_top.sv`'s hand-packing (`tpu_top.sv:182-187`, assigning
`seq_we_col[0] = seq_we_col_0` etc.) goes away entirely — the sequencer drives
the array directly, one less layer of scalar-to-array glue.

### 2.2 Register file: fixed 4/2-element arrays → 2-D arrays sized by parameter

```systemverilog
// today: logic signed [7:0] reg_weights [4];      // flat, order-encodes row/col
// today: logic signed [7:0] reg_act     [4];
// today: logic signed [15:0] reg_bias   [2];
logic signed [7:0]  reg_weights [ARRAY_ROWS][NUM_COLS];
logic signed [7:0]  reg_act     [M_TILE][ARRAY_ROWS];
logic signed [15:0] reg_bias    [NUM_COLS];
logic signed [15:0] result_rows [M_TILE][NUM_COLS];
```
`payload[8]` (`tpu_sequencer.sv:183`) needs to grow to
`max(ARRAY_ROWS*NUM_COLS, M_TILE*ARRAY_ROWS)` bytes to hold a full
`LOAD_WEIGHTS`/`LOAD_ACT` frame at the new size, and `byte_cnt`/`len_reg` (both
already 8-bit, so up to 255) comfortably cover any array this chip could
plausibly host (§3 of `PERFORMANCE_ANALYSIS.md`: ceiling is ~20 PEs total, so
`ARRAY_ROWS*NUM_COLS` payload bytes never gets near 255).

### 2.3 States: one-per-row/col → one loop state + counter

| Today (named, one state per index) | Redesigned (one state, counter 0..N-1) |
|---|---|
| `S_WR_UB_0`, `S_WR_UB_1` | `S_WR_UB`, counter `ub_row_cnt` over `0..M_TILE-1` |
| `S_LD_WF_0`, `S_LD_WF_1` | `S_LD_WF`, counter `wf_row_cnt` over `ARRAY_ROWS-1 downto 0` (bottom row first — see below) |
| `S_LD_WF_GAP` | unchanged (single fixed 1-cycle gap, no parameter needed) |
| `S_SWAP` | unchanged |
| `S_LOADING_0/1/2` (3 fixed states = `ARRAY_ROWS`(2) drain cycles + 1 guard) | `S_LOADING`, counter over `0..ARRAY_ROWS` inclusive (`ARRAY_ROWS+1` cycles total) |
| `S_STREAM_0`, `S_STREAM_1` | `S_STREAM`, counter `stream_cnt` over `0..M_TILE-1` |
| `S_WAIT` | unchanged in structure; `rows_got == 2'd2` becomes `rows_got == M_TILE[…]`, and `rows_got` widens from `logic [1:0]` to `logic [$clog2(M_TILE+1)-1:0]` |

Each loop state does the same thing the old named states did, indexed by the
counter instead of hardcoded into the state name, e.g.:

```systemverilog
S_WR_UB: begin
    host_write_addr    <= ub_row_cnt[ADDR_WIDTH-1:0];
    host_write_data    <= reg_act[ub_row_cnt];   // one M-row, ARRAY_ROWS-wide
    host_write_valid   <= 1'b1;
    if (ub_row_cnt == M_TILE-1) begin
        ub_row_cnt <= '0;
        state      <= S_LD_WF;
    end else begin
        ub_row_cnt <= ub_row_cnt + 1'b1;
    end
end
```

`S_LD_WF`'s bottom-row-first ordering (the "staggered loading contract" in
`weight_fifo.sv`'s header — bottom row must be presented before top row so it's
already shifted into place when the top row arrives) generalizes to: drive
`reg_weights[ARRAY_ROWS-1 - wf_row_cnt]` and count `wf_row_cnt` up from 0 to
`ARRAY_ROWS-1`, i.e. row index counts *down* while the loop counter counts up.
That's the one place where "just replace the literal index with a counter"
isn't quite enough — worth flagging in review since getting the direction
backwards silently transposes every weight matrix (no error, wrong answer —
exactly the class of bug `docs/sequencer_uart_design.md` §5.5 already warns
about for the wire format).

### 2.4 Response packing: unrolled 8-byte literal → nested loop

Today (`tpu_sequencer.sv:464-475`) is 8 hand-written `tx_payload[N] <=
result_rowM[c][hi/lo]` lines. Redesigned as a loop building
`tx_payload[2 + 2*(r*NUM_COLS + c) + {0,1}]` from `result_rows[r][c]` over
`r in 0..M_TILE-1, c in 0..NUM_COLS-1`, with `tx_len_reg <= 8'd2 +
8'(2*M_TILE*NUM_COLS)`. `tx_payload`'s fixed size (`tpu_sequencer.sv:188`,
currently `[10]`) grows to `2 + 2*M_TILE*NUM_COLS` bytes.

### 2.5 What does *not* need to change

`S_IDLE`/`S_RECV_LEN`/`S_RECV_PAYLOAD`/`S_EXEC_DISPATCH`, the TX serialization
loop (`S_TX_STATUS`/`S_TX_DATA`, already counter-driven), and `S_RESET_PULSE`
are already generic — they operate on `len_reg`/`byte_cnt`/`tx_byte_idx`
counters, not per-row/col literals. Only the RUN-orchestration substates
(§2.3) and the register file/response packing (§2.2/2.4) are hardcoded to 2.

## 3. UART batch-command redesign (Tiers 2 and 3 from `PERFORMANCE_ANALYSIS.md` §4)

The measured baseline (§1 of that doc, 144→64→10 MNIST model): **7,429
transactions/image**, 3 round trips per K-tile
(`LOAD_WEIGHTS`→`LOAD_ACT`→`RUN`), ≈0.465 ms/transaction of pure
software/USB overhead on top of wire time. Both tiers below cut *transaction
count*, independent of and stackable with the Tier 1 baud-rate bump.

All sizes below (`LEN`, `ARRAY_ROWS*NUM_COLS`, etc.) are **byte** counts, same
as the existing protocol (`tpu_sequencer.sv`'s header: `[1] LEN byte (number
of payload bytes that follow)`). Weights and activations are int8 — one byte
per element already — so there's no sub-byte packing anywhere in either new
command; see the worked byte-for-byte examples in §3.1 and §3.2.

### 3.1 Tier 2 — `CMD_RUN_TILE` (0x06): fold `LOAD_WEIGHTS`+`LOAD_ACT`+`RUN` into one frame

New command, one round trip per K-tile instead of three:

```
0x06  RUN_TILE   LEN = 1 + ARRAY_ROWS*NUM_COLS + M_TILE*ARRAY_ROWS
                  payload: [flags,
                            weight bytes  (ARRAY_ROWS*NUM_COLS, row-major top-to-bottom,
                                            natural order -- see §3.3 on reordering),
                            act bytes     (M_TILE*ARRAY_ROWS, row-major)]
                  flags[0] = TILE_FIRST, flags[1] = TILE_LAST  (same semantics as
                             today's CMD_RUN LEN=1 variant)
                  response: same as CMD_RUN today (STATUS, LEN, result bytes if
                             TILE_LAST, else STATUS/LEN=0 ACK)
```

For today's 2×2 shape: `LEN = 1 + 4 + 4 = 9` bytes, one frame, one response —
replacing `LOAD_WEIGHTS`(2+4) → `LOAD_ACT`(2+4) → `RUN`(2+1) = 3 round trips.
Sequencer-side, `S_EXEC_DISPATCH`'s `CMD_RUN_TILE` case does what
`CMD_LOAD_WEIGHTS`+`CMD_LOAD_ACT`+`CMD_RUN` do today combined — unpack
`payload` directly into `reg_weights`/`reg_act`, latch `tile_first`/`tile_last`
from `flags`, then fall into the same `S_WR_UB` sequence §2 already drives.
`LOAD_BIAS` stays a separate, infrequent command (once per output block, not
per K-tile — matches `PERFORMANCE_ANALYSIS.md`'s Tier 2 assumption).

Host-side (`tpu_host.py`), `matmul_tiled()`'s inner loop
(`tpu_host.py:213-219`, currently 3 calls per K-tile: `load_weights`,
`load_activations`, `run`) becomes one `run_tile(w, a, first, last)` call that
packs weights+activations+flags into a single `_send_cmd(CMD_RUN_TILE,
payload)`.

**Worked example**, today's 2×2 self-test values (`W=[[4,5],[2,3]]`,
`A=[[1,2],[3,4]]`, `bias=[100,200]` already loaded via `LOAD_BIAS`,
`first=last=1` so `flags=0x03`), all bytes in hex:

```
Host → FPGA:  06 09  03  04 05 02 03  01 02 03 04
              │  │   │   └─weights──┘ └──acts───┘
              │  │   └flags (TILE_FIRST|TILE_LAST)
              │  └LEN = 1 + 4 + 4 = 9
              └CMD_RUN_TILE

FPGA → Host:  AA 08  6C 00  D3 00  78 00  E3 00
              │  │   └r0c0=108┘└r0c1=211┘└r1c0=120┘└r1c1=227┘ (int16 LE)
              │  └LEN = 8
              └STATUS_OK
```

11 bytes out, 10 bytes back, **one round trip** — vs. today's
`LOAD_WEIGHTS`(2+4=6) → `LOAD_ACT`(2+4=6) → `RUN`(2+1=3) = 15 bytes out across
**three** round trips for the same tile.

Projected effect (from `PERFORMANCE_ANALYSIS.md` §4 Tier 2): transactions/image
7,429 → ≈2,501, overhead ≈3,453 → ≈1,162 ms/image; combined with Tier 1's baud
bump, ≈1,690 ms/image (~4.7x).

### 3.2 Tier 3 — `CMD_STREAM_RUN` (0x07): a whole K-run per round trip

`matmul_tiled()` already knows the entire K-run up front (`tpu_host.py:215`,
the `for ki, k0 in enumerate(...)` loop) before it ever talks to the device —
today it just throws that knowledge away and re-sends one tile at a time.
`weight_fifo`'s double-buffering (`weight_fifo.sv`'s shadow/active bank split)
exists precisely to let a new weight matrix load while the current one drains
— a capability `docs/sequencer_uart_design.md` §5.6 flags as unused by the
current protocol. `CMD_STREAM_RUN` uses it:

```
0x07  STREAM_RUN  LEN = 1 + K_TILES*(ARRAY_ROWS*NUM_COLS + M_TILE*ARRAY_ROWS)
                   payload: [K_TILES,
                             tile_0: weight bytes, act bytes,
                             tile_1: weight bytes, act bytes,
                             ...
                             tile_{K_TILES-1}: weight bytes, act bytes]
                   response: STATUS, LEN, result bytes (one final (M_TILE x NUM_COLS)
                             block -- same shape as CMD_RUN's result, sent once)
```

Sequencer-side control flow (new top-level loop state, `S_STREAM_RUN_TILE`,
wrapping the existing per-tile substates from §2):

1. Parse `K_TILES` from `payload[0]`; set `tile_idx = 0`.
2. For each `tile_idx` in `0..K_TILES-1`: unpack that tile's weight/act bytes
   from the (large) payload buffer into `reg_weights`/`reg_act`, run the
   existing `S_WR_UB → S_LD_WF → ... → S_STREAM` sequence, with
   `tile_first = (tile_idx == 0)`, `tile_last = (tile_idx == K_TILES-1)` fed
   into the accumulator exactly as today.
3. While tile `tile_idx` is draining/computing (`S_LOADING`/`S_STREAM`/`S_WAIT`
   with `accum_pass_done` low), the sequencer can — as a follow-on
   optimization once the basic loop works — write tile `tile_idx+1`'s weights
   into `weight_fifo`'s *shadow* bank concurrently (it's a different physical
   FIFO than the active bank being drained, per `weight_fifo.sv`'s own
   header), then pulse `swap_banks` right as `tile_idx`'s `S_LOADING` state
   would otherwise begin for `tile_idx+1`. This overlap is what actually
   hides the weight-load latency behind compute; without it, `CMD_STREAM_RUN`
   still wins (one UART round trip instead of `K_TILES` of them) but the
   per-tile RTL latency is unpipelined. Land the non-overlapped version first
   — correctness before the pipelining refinement.
4. Only on `tile_idx == K_TILES-1`'s `accum_pass_done`/`final_row_valid` does
   the sequencer build and send the response, identical in shape to today's
   `CMD_RUN` result.

**Worked example**, `K_TILES=2`, two arbitrary 2×2 weight/act tiles
(`tile0`: `W=[[1,0],[0,1]]`, `A=[[1,2],[3,4]]`; `tile1`: `W=[[1,0],[0,1]]`,
`A=[[5,6],[7,8]]`), all bytes in hex:

```
Host → FPGA:  07 11  02  01 00 00 01  01 02 03 04  01 00 00 01  05 06 07 08
              │  │   │   └─tile0 W──┘ └─tile0 A──┘ └─tile1 W──┘ └─tile1 A──┘
              │  │   └K_TILES = 2
              │  └LEN = 1 + 2*(4+4) = 17
              └CMD_STREAM_RUN

FPGA → Host:  AA 08  <8 result bytes for the final (tile1) accumulated pass>
```

19 bytes out, one round trip — vs. `CMD_RUN_TILE`'s 2 round trips (one per
tile) or today's 6 round trips (`LOAD_WEIGHTS`/`LOAD_ACT`/`RUN` × 2 tiles) for
the same 2-tile K-run.

**Sizing constraint worth calling out**: `LEN` is a single byte (max 255,
`tpu_sequencer.sv:11`/protocol header). For the 2×2 case, one tile costs 8
payload bytes, so `K_TILES` is capped at `(255-1)/8 ≈ 31` tiles per frame —
plenty for this MNIST model's K-dimensions (144, 64) once M/N-tiled down to
2-wide chunks means K_TILES per block is small, but worth checking against
whatever K this ends up applied to; if a model needs more, `LEN` would need to
widen to 16 bits, a small protocol version bump.

Projected effect (from `PERFORMANCE_ANALYSIS.md` §4 Tier 3): transactions
collapse to ~one per `(M,N)` output block (37 for this model, vs. 7,429
total), overhead ≈3,453 → ≈17 ms/image; combined with Tier 1, ≈550 ms/image
(~14x) — the highest-value change of the three tiers, and the one that
actually uses `weight_fifo`'s existing double-buffer once step 3 above lands.

### 3.3 Fold in the existing wire-format cleanups while touching this code

Two items from `docs/sequencer_uart_design.md` §5 are cheap to fix at the same
time as adding these commands, since both new commands touch the
weight-unpacking path anyway:

- **§5.5**: accept weights from the host in natural row-major order
  (`[w00,w01,w10,w11,...]`) and let the sequencer do the bottom-row-first
  reorder internally (§2.3 already has the sequencer indexing
  `reg_weights[ARRAY_ROWS-1-wf_row_cnt]`, so the reorder is free — just don't
  also require the *host* to pre-reverse it). Removes a footgun where a
  host-side row-order bug silently transposes results with no error.
- **§5.7**: wire `uart_rx`'s `rx_error` into the sequencer (currently
  dangling, `tpu_top.sv` never connects it) so a framing error mid-batch
  produces an explicit `STATUS_ERR` instead of a silent drop + eventual
  `WAIT_TIMEOUT`. This matters more once a single frame can be 200+ bytes
  (`CMD_STREAM_RUN`) — more bytes per frame means more exposure to a single-bit
  UART error silently corrupting one byte of a large batch.

## 4. `tpu_top.sv` changes required to support any of this

Mechanical but necessary, per `PERFORMANCE_ANALYSIS.md`'s own assessment:

- Add `ARRAY_ROWS`, `NUM_COLS`, `M_TILE` to `tpu_top`'s parameter list and
  thread them into every submodule instantiation (currently all hardcode `2`,
  `tpu_top.sv:214,234,250,259,272,285,295`) instead of relying on each
  submodule's own default.
- Delete the scalar glue signals (`seq_we_col_0/1`, `seq_wd_col_0/1`,
  `tpu_top.sv:98-99,182-187`) — once `tpu_sequencer`'s ports are arrays (§2.1),
  they connect directly to `weight_fifo`'s array ports with no packing step.
- `host_write_data`/`out_bias`/`final_row_out` widths (currently hand-sized
  `[1:0][...]` throughout `tpu_top.sv`) follow from `ARRAY_ROWS`/`NUM_COLS`
  instead of being written out as literal `2`s.

## 5. Validation plan before adopting any of this

1. Fix the `unified_buffer` `ROWS`/`COLS` bug (§0) first, independently —
   smallest possible change, and a prerequisite for everything else being
   correct on non-square shapes.
2. Generalize `tpu_sequencer.sv` per §2, but re-run it at `ARRAY_ROWS=2,
   NUM_COLS=2, M_TILE=2` first and diff behavior cycle-for-cycle against the
   existing `tests/tpu_sequencer_tb.sv`/`tests/tpu_core_tb.sv` — the whole
   point of the current hardcoded form is bit-exact parity with those
   testbenches, so the counter-driven version must reproduce it exactly at
   the old size before trusting it at a new size.
3. Add a second testbench instance (or parameterize the existing one) at a
   non-trivial size (e.g. `ARRAY_ROWS=4, NUM_COLS=4`) to actually exercise the
   generalized loops — 2×2 alone can't distinguish "generalized correctly"
   from "happens to still work because N=2".
4. Land `CMD_RUN_TILE` (§3.1) behind the existing `CMD_LOAD_WEIGHTS`/
   `CMD_LOAD_ACT`/`CMD_RUN` (don't remove the old commands — they're a useful
   fallback and `tpu_host.py`'s `matmul()` single-shot convenience wrapper has
   no reason to change), update `tpu_host.py`, re-run `make hw-test` and
   `mnist/infer.py --compare` to confirm the projected ~4.7x actually
   materializes.
5. Land `CMD_STREAM_RUN` (§3.2) without the shadow-bank pipelining overlap
   first (step 3 in §3.2), validate correctness, *then* add the overlap as a
   separate change with its own regression pass — the two are separable and
   the overlap is where the real risk of a subtle timing bug lives.

## 6. Looking further: a bit-packed instruction set (beyond §3's byte-oriented commands)

Everything in §3 is still byte-oriented — one field per byte, matching the
existing protocol's grain. That's a deliberate, low-risk choice (§3.3 already
folds in two wire-format cleanups precisely because touching the byte layout
is cheap when done carefully). This section is more speculative: is there
value in going a level deeper and packing multiple *logical* fields into
fewer *physical* bytes, i.e. an actual bit-level instruction encoding rather
than "one field, one byte"? Nothing here is a proposal at the same
confidence level as §2/§3 — it's a direction worth prototyping in software
before committing any RTL to it.

### 6.1 Where today's (and §3's) byte-oriented framing spends more bits than it needs

| Field | Bits spent | Bits actually needed | Waste |
|---|---|---|---|
| `CMD` byte | 8 | 3 (≤8 opcodes: 5 today + `RUN_TILE`/`STREAM_RUN` = 7) | 5 bits/frame |
| `flags` byte (`RUN`/`RUN_TILE`) | 8 | 2 (`TILE_FIRST`, `TILE_LAST`) | 6 bits/frame |
| `LEN` byte | 8 | 0, for any *fixed-shape* command | up to 8 bits/frame |
| `STATUS` byte | 8 | 1 (OK vs. error; 2 values used out of 256) | 7 bits/frame |

The `LEN`-is-redundant point is the biggest one: for `LOAD_WEIGHTS`,
`LOAD_ACT`, `LOAD_BIAS`, `RUN`, and `RUN_TILE`, the payload size is a
synthesis-time constant (`ARRAY_ROWS*NUM_COLS`, `M_TILE*ARRAY_ROWS`, etc.) —
both the host and the FPGA already know it from the opcode alone, so sending
it on every single frame is pure redundancy. Only a genuinely variable-length
command (`CMD_STREAM_RUN`'s `K_TILES`-dependent payload) needs to state a
length at all, and even there, one byte (`0..255`) is wider than
`$clog2(MAX_K_TILES+1)` bits actually requires (§3.2 computed `MAX_K_TILES ≈
31` for the 2×2 case — 5 bits, not 8).

### 6.2 A packed instruction-header idea

Replace the `[CMD][LEN]` two-byte header with a single instruction byte for
every *fixed-shape* opcode: `{3'b opcode, 2'b flags, 3'b reserved}`, no `LEN`
byte at all — the sequencer looks up the expected payload size from the
opcode in a small `case` (a synthesis-time constant table, not a runtime
computation) instead of trusting a host-supplied length. `CMD_STREAM_RUN`
keeps an explicit length field, but sized to `$clog2(MAX_K_TILES+1)` bits
instead of a flat byte.

Quantified against §3.1's worked example: today's `RUN_TILE` frame is `06 09
03 <8 payload bytes>` — 11 bytes, of which `CMD`+`LEN` = 2 header bytes (18%).
Folding `flags` into a shared header byte and dropping `LEN` entirely gets
that down to 1 header byte + 8 payload = 9 bytes, a ~18% reduction on that
command specifically (less across a full mixed traffic mix, since `LOAD_BIAS`
etc. are already small and infrequent). Worth stacking on top of §3, not
instead of it — this is a header-compression idea, orthogonal to §3's
transaction-count reduction.

### 6.3 Sub-byte payload packing: lower-precision weights/activations

`int8` for weights/activations isn't a hardware floor, it's a choice already
baked into `pe.sv` (`PERFORMANCE_ANALYSIS.md` §2 notes `pe.sv` hardcodes 8-bit
operands and would need its own parameterization to change). Quantized
inference accelerators routinely run weights at int4 or lower with an
acceptable accuracy hit. If that held here, two weights/activations pack into
one wire byte, halving `RUN_TILE`'s weight/act payload bytes
(`ARRAY_ROWS*NUM_COLS` → `ceil(ARRAY_ROWS*NUM_COLS/2)`, same for the
activation bytes).

The lower-risk version of this **doesn't touch the datapath at all**:
unpack-on-receive. `tpu_sequencer.sv`'s RX path splits each incoming byte into
two nibbles, sign-extends each back to a full int8, and writes that into
`reg_weights`/`reg_act` exactly as today — `weight_fifo`, `mmu`, `pe.sv`
never see anything but int8. Only the wire format and the sequencer's
deserialization logic change; the already-validated MMU/accumulator pipeline
is untouched. A "goes all the way to the datapath" version (native int4
multiply in `pe.sv`) is a much bigger, separate effort and not what this
section is proposing.

The real open question isn't RTL, it's **accuracy**: does whatever model runs
on this TPU (the MNIST classifier today) still classify correctly with int4
weights? That's a numpy experiment (`mnist/infer.py`, quantize the trained
weights to int4 and re-run the existing accuracy check), answerable in an
afternoon with zero hardware involvement, and it should be answered *before*
any unpacking logic gets written — there's no point building nibble-unpack
RTL for a precision the model can't tolerate.

### 6.4 The hard floor: UART only moves whole bytes

Important caveat on all of the above: `uart_tx`/`uart_rx` physically transmit
one byte per frame (start bit + 8 data bits + stop bit — the atomic transfer
unit described in `docs/sequencer_uart_design.md` §1-2). There's no such
thing as "send 3 bits" more cheaply than "send a byte" on this link — the
wire-time cost is always in whole-byte units. So §6.2/§6.3 only pay off
because they reduce the *count* of physical bytes crossing the wire (by
packing multiple logical fields, or multiple lower-precision values, into
each byte), not because bits below a byte are individually cheaper to send.
That framing is what keeps this distinct from — and compatible with — Tier
1's baud-rate change and Tier 2/3's transaction-count reduction: all three
levers (baud, transaction count, bytes/transaction) are independent and
stack.

### 6.5 Suggested investigation order

1. **§6.3's accuracy question first, in software, with zero RTL.** If int4
   doesn't hold accuracy for the target model, the sub-byte payload-packing
   idea is dead and only §6.2 (header packing) is worth pursuing.
2. **§6.2 (packed header, no `LEN` for fixed-shape commands) next.** Pure
   protocol change, no accuracy risk, small and mechanical — a natural
   companion patch alongside `CMD_RUN_TILE`/`CMD_STREAM_RUN` since both
   already touch the opcode-dispatch table.
3. **§6.3's unpack-on-receive nibble packing last, and only if step 1
   validates.** Bigger change than §6.2 (new RX deserialization logic,
   `tpu_host.py`-side quantization of the weight/activation arrays before
   sending), but still confined to the sequencer's byte-to-register
   unpacking — `weight_fifo`/`mmu`/`pe.sv` stay untouched either way.

As with everything else in this doc: `make test`/`make hw-test` must pass at
each step, and — uniquely for this section — step 1's software accuracy
check has to pass *before* step 3's RTL is even worth writing.
