# UART Command Interface & Pipeline Orchestration

Covers `rtl/tpu_sequencer.sv`, `rtl/uart_rx.sv`, and `rtl/uart_tx.sv` — the host-facing
control plane that sits on top of the `tpu_core` datapath (`unified_buffer`, `weight_fifo`,
`systolic_data_setup`, `mmu`, `accumulator`, `bias`, `activation`). All line/cycle references
are to the current files on `main`.

## 1. `uart_rx.sv` — 8N1 receiver

16x-oversampling design with a mid-bit sample point for noise margin.

- **Synchronizer**: two-flop `rx_sync_0 → rx_sync`, plus `rx_sync_prev` for edge detection
  (`rtl/uart_rx.sv:40-46`). Standard CDC hygiene for an async pin.
- **FSM**: `S_IDLE → S_START → S_DATA → S_STOP`.
  - `S_IDLE` only advances on a true `1→0` transition (`rx_sync_prev && !rx_sync`,
    `uart_rx.sv:77-81`), not just "line is low" — this is what prevents a stuck-low line
    (e.g. after a framing error) from being reinterpreted as an endless run of start bits.
  - `S_START` samples at `SAMPLE_TICK = TICKS_PER_BIT/2`. If the line isn't still low at that
    point, it's a glitch and the FSM bails back to `S_IDLE` (`uart_rx.sv:92-95`) rather than
    trying to resync mid-frame.
  - `S_DATA` shifts in 8 bits LSB-first, one per `TICKS_PER_BIT` window.
  - `S_STOP` re-samples at the bit's midpoint; a `0` sets `rx_error` (sticky until the next
    successful byte) but the FSM still returns to `S_IDLE` either way — there's no attempt to
    resynchronize to a corrupted stream beyond that.
- **Output contract**: `rx_valid` is a single-cycle pulse with `rx_data` held stable that cycle.

**Latency per byte**: `10 × TICKS_PER_BIT` clock cycles (start + 8 data + stop), i.e.
`10 × (CLK_FREQ / BAUD_RATE)`. At the DE1-SoC defaults (50 MHz / 115200 baud):
`TICKS_PER_BIT = 434`, so **4340 cycles/byte ≈ 86.8 µs/byte**.

**Note**: `rx_error` is never consumed — `tpu_top.sv` doesn't wire it to the sequencer, so a
framing error is silently absorbed (the corrupt byte is simply dropped, `rx_valid` never
pulses for it) with no NACK back to the host. See §5.7.

## 2. `uart_tx.sv` — 8N1 transmitter

Simpler mirror of the RX FSM: `S_IDLE → S_START → S_DATA → S_STOP`, shifting `tx_data` out
LSB-first once `tx_valid` is pulsed while `tx_busy` is low. `tx_busy` stays high for the full
frame so a producer (the sequencer) knows not to pulse `tx_valid` again until the byte is
fully clocked out.

**Latency per byte**: same formula as RX, **4340 cycles/byte ≈ 86.8 µs/byte** at 50 MHz/115200.

Both UART blocks are latency-dominant relative to everything else in this design — see §4.

## 3. `tpu_sequencer.sv` — protocol decoder + pipeline orchestrator

### 3.1 Role

Sits between the UART pair and the `tpu_core` datapath. It has no arithmetic of its own; it's
a byte-protocol FSM (`S_IDLE`/`S_RECV_LEN`/`S_RECV_PAYLOAD`/`S_EXEC_DISPATCH`) glued to a
second FSM that replays the exact cycle-accurate control sequence `tests/tpu_core_tb.sv`'s
tasks (`write_activations_to_ub`, `load_weights`, `trigger_weight_load`,
`stream_activations_from_ub`) use to drive the datapath by hand. Because the datapath modules
have no handshake/backpressure signals beyond fixed registered latencies, this replay only
works if the sequencer's state timing matches the testbench's `@(posedge clk)` spacing
exactly — which is why the state machine looks over-explicit (`S_LD_WF_GAP`, three separate
`S_LOADING_*` states, etc.) instead of using counters.

### 3.2 Command/response protocol

Command frame: `[CMD][LEN][payload...]`. Response frame: `[STATUS][LEN][payload...]`,
`STATUS ∈ {0xAA=OK, 0xFF=error}`. Five commands: `LOAD_WEIGHTS(01)`, `LOAD_BIAS(02)`,
`LOAD_ACT(03)`, `RUN(04)`, `RESET(05)`. `LOAD_*` commands just latch bytes into a persistent
register file (`reg_weights`, `reg_bias`, `reg_act`) and ACK immediately — no datapath
activity happens until `RUN`.

`RUN` optionally takes a 1-byte payload (`LEN=1`, `[flags]`) for K-dim tiling: `flags[0]`
(`TILE_FIRST`) and `flags[1]` (`TILE_LAST`) are threaded straight into `accumulator.sv`'s
`tile_first`/`tile_last` inputs (`reg_tile_first`/`reg_tile_last`, latched at dispatch same as
the other registers). `LEN=0` latches `first=last=1'b1` — the original single-shot behavior,
still what every existing host (`tpu_host.py`, `hw_regression.py`) sends. When `tile_last=0`,
`bias`/`activation` never fire for that pass (`accumulator.sv` gates `out_row_valid` on
`tile_last`), so `S_WAIT` can't use the usual two-`final_row_valid` wait; it instead waits on a
new `accum_pass_done` input (wired straight from `accumulator.sv`'s `pass_done` output, which
pulses once per pass regardless of `tile_first`/`tile_last`) and replies with a bare
`STATUS_OK, LEN=0` ACK. See `rtl/accumulator.sv`'s header comment for the accumulation
semantics this enables (summing partial sums across weight-reload passes before bias/ReLU, for
a matmul whose K dimension exceeds `ARRAY_ROWS`).

One asymmetry worth calling out: weights are stored **bottom-row-first**
(`[w10, w11, w00, w01]`) over the wire, matching `weight_fifo`'s documented staggered-loading
contract (`weight_fifo.sv:20-32`) — the top-row weight must be captured by each PE one cycle
after the bottom-row weight so the systolic vertical propagation lines up. This is the
sequencer/host protocol leaking an internal MMU timing detail into the wire format; see §5.5.

### 3.3 `RUN` orchestration — full cycle-by-cycle walkthrough

Below, `c1` is the first cycle the FSM spends in `S_WR_UB_0` (i.e. one cycle after
`S_EXEC_DISPATCH` decodes `CMD_RUN`). Every arrow is one registered clock edge; nothing here
is combinational passthrough except where noted.

| Cycle | State | What fires this cycle |
|---|---|---|
| c1 | `S_WR_UB_0` | `host_write_addr=0`, `host_write_data=[a00,a01]`, `host_write_valid=1` → written into UB active bank this edge |
| c2 | `S_WR_UB_1` | `host_write_addr=1`, `host_write_data=[a10,a11]`, `host_write_valid=1` |
| c3 | `S_LD_WF_0` | `write_enable_col_{0,1}=1`, data=`[w10,w11]` → enqueued into weight_fifo **shadow** bank |
| c4 | `S_LD_WF_1` | data=`[w00,w01]` → enqueued (shadow bank now holds both rows, bottom then top) |
| c5 | `S_LD_WF_GAP` | idle — mirrors the extra `@(posedge clk); #1;` gap in `tpu_core_tb.sv`'s `load_weights` task before `trigger_weight_load` starts |
| c6 | `S_SWAP` | `swap_banks=1` → `weight_fifo.active_bank_q` flips at this edge; the just-loaded bank becomes active |
| c7 | `S_LOADING_0` | `loading_phase=1`; weight_fifo pops bottom row (`w10,w11`) from the now-active bank (fifo non-empty) |
| c8 | `S_LOADING_1` | `loading_phase=1`; `out_col_{0,1}` present `w10/w11` (registered from c7's pop) → MMU `pe00`/`pe01` see `in_weight=w10/w11`, `capture_weight` high, so `weight_reg` samples them at the edge into c9; fifo pops the top row (`w00,w01`) this cycle |
| c9 | `S_LOADING_2` | `out_col_{0,1}` present `w00/w01` (registered from c8's pop); this feeds `pe00/pe01` directly (captured as their stationary weight) **and** feeds `pe10/pe11` one cycle later via the vertical `out_weight` chain, landing `w10/w11` in the bottom-row PEs at the edge into c10 — the two-row stagger is exactly what makes weight-stationary loading land in the right PEs |
| c10 | `S_STREAM_0` | `ub_read_addr=0`, `ub_read_en=1` — request row 0 of activations |
| c11 | `S_STREAM_1` | `ub_read_addr=1`, `ub_read_en=1` — request row 1 |
| c12 | `S_WAIT` (wait_cnt=1) | UB's 2-cycle read pipeline delivers row 0: `ub_read_valid=1`, data=`[a00,a01]`. SDS passes element 0 (`a00`) straight through (0-cycle skew) → `mmu_in_row[0]=a00` valid this cycle; element 1 (`a01`) enters SDS's 1-cycle shift register |
| c13 | `S_WAIT` | UB delivers row 1 (`[a10,a11]`) — `mmu_in_row[0]=a10` valid. Simultaneously SDS's shift register releases `a01` → `mmu_in_row[1]=a01` valid. (Row-0's second component and row-1's first component are in flight together — this interleaving is what keeps the pipeline at full throughput.) |
| c14 | `S_WAIT` | SDS releases `a11` → `mmu_in_row[1]=a11` valid. MMU column 0 finishes row 0: `pe10.out_partial_sum` (`out_partial_sum_0`) valid = `w00·a00 + w10·a01` |
| c15 | `S_WAIT` | MMU column 1 finishes row 0 (`out_partial_sum_1`, one hop further through `pe01→pe11`) = `w01·a00 + w11·a01`. MMU column 0 finishes row 1 = `w00·a10 + w10·a11`. Accumulator: row 0's col-0 result has been sitting in its FIFO since c14 but col-1's FIFO is still empty, so no pop yet |
| c16 | `S_WAIT` | MMU column 1 finishes row 1. Accumulator: **both** column FIFOs now hold row 0's pair simultaneously → `pop_row=1` this cycle |
| c17 | `S_WAIT` | `acc_row_valid=1` for row 0 (registered from c16's pop) → `bias` samples it |
| c18 | `S_WAIT` | `bias.out_row_valid=1` for row 0 → `activation` samples it. Accumulator pops row 1's pair this cycle (both its FIFOs non-empty by now) → `acc_row_valid=1` for row 1 |
| c19 | `S_WAIT` | `activation.out_row_valid=1` → **`final_row_valid` pulses for row 0** (sequencer latches `result_row0`, `rows_got=1`). `bias.out_row_valid=1` for row 1 |
| c20 | `S_WAIT` | **`final_row_valid` pulses for row 1** (`result_row1` latched, `rows_got=2`) |
| c21 | `S_WAIT` | FSM sees `rows_got==2`, packs `tx_payload` (`STATUS_OK`, `LEN=8`, 8 result bytes), moves to `S_TX_STATUS` |
| c22+ | `S_TX_STATUS`/`S_TX_DATA` | Serializes 10 bytes through `uart_tx`, one at a time, gated on `!tx_busy` |

**Minimum internal (non-UART) latency for one `RUN`: 21 cycles** from dispatch to
`rows_got==2` (c1→c21). `WAIT_TIMEOUT=200` (default) is roughly 20x that — deliberately
conservative per the header comment, and harmless since it only bounds a fault path.

### 3.4 Per-module latency reference

| Module | Latency | Note |
|---|---|---|
| `unified_buffer` host write | 1 cycle | data lands in active bank same edge `host_write_valid` is sampled |
| `unified_buffer` UB read (→SDS) | 2 cycles | `ub_read_en` → `ub_addr_r/ub_en_r` → `ub_read_valid`+data; models registered M10K output |
| `unified_buffer` host read (→ARM) | 1 cycle | single register stage |
| `systolic_data_setup` | row *i*: *i* cycles | row 0 combinational passthrough; row 1 gets one shift-register stage (generalizes to `ARRAY_ROWS-1` max skew) |
| `weight_fifo` drain | 1 cycle | `pop_col_N` (combinational on `loading_phase && !empty`) → registered `out_col_N`/`valid` |
| `pe` (single cell) | 1 cycle | weight capture, activation passthrough, and MAC are all registered — no combinational path through a PE |
| `mmu` (2×2, from SDS-aligned inputs) | col 0: 2 cycles, col 1: 3 cycles | col 1 output is one more systolic hop (`pe01→pe11`) than col 0 (`pe00→pe10`) |
| `accumulator` | 2 cycles | measured from the *slower* column's valid pulse for that row to `out_row_valid`; the "all FIFOs non-empty" gate means the whole row waits on the last-arriving column |
| `bias` | 1 cycle | plain registered add |
| `activation` (ReLU) | 1 cycle | plain registered clamp |

**End-to-end per-row latency** (row-vector entering SDS → `final_row_valid`): **7 cycles**
(3 MMU + 2 accumulator + 1 bias + 1 activation). With two activation rows streamed back to
back (as `RUN` does), the second row's `final_row_valid` follows the first by exactly 1 cycle
— the pipeline runs at full throughput once primed; the only "bubble" is the initial column
skew absorbed while row 0's result is assembling (§5.3).

## 4. UART dominates the timing budget

For a full `RUN` transaction over the wire at 50 MHz / 115200 baud:

- RX: `CMD`+`LEN` = 2 bytes × 4340 cycles = **8680 cycles**
- Internal orchestration: **21 cycles** (§3.3)
- TX: 10 response bytes × 4340 cycles = **43400 cycles**
- **Total ≈ 52,100 cycles (≈ 1.04 ms)** dominated >99.9% by UART bit-shifting, not compute.

The systolic array's 21-cycle burst is essentially free next to two round trips through a
115200-baud line. Any performance work should start at the transport, not the datapath.

## 5. Improvement opportunities

1. **UART throughput is the real bottleneck (§4).** Raising `BAUD_RATE`, batching multiple
   `LOAD_*`/`RUN` commands per transaction, or replacing the UART link with the DE1-SoC's
   HPS↔FPGA Avalon-MM bridge would cut latency by orders of magnitude with zero datapath
   changes.
2. **`WAIT_TIMEOUT=200` vs. actual worst case ~21 cycles.** Since datapath latency here is
   fixed and deterministic (no backpressure anywhere in `tpu_core`), the sequencer could
   replace the polling `wait_cnt`/`rows_got` comparison with a fixed-delay counter instead of
   watching for two `final_row_valid` pulses — functionally identical but removes the
   (unused) timeout/error path's complexity. Low priority; the current form is more robust to
   future datapath changes.
3. **Accumulator's "all columns non-empty" gate costs a fixed bubble per burst.** Because
   `pop_row` requires every column FIFO simultaneously non-empty (`accumulator.sv:47-56`), row
   0's col-0 result sits idle for 1 cycle waiting on col-1 (c14→c16 in the walkthrough). For a
   2×2 array this is one cycle out of 21; for a larger `N×N` array (`N-1` column skew) this
   scales up and would matter more. A per-column "count of rows produced" ledger with
   independent-row emission (rather than lockstep popping) would remove it, at the cost of
   needing explicit row-tagging instead of position-implied ordering.
4. **Hard-coded to 2×2.** `unified_buffer`'s UB-read loop indexes `mem[bank][addr][c]` for
   `c` in `0..ROWS-1` when it should index the `COLS` dimension
   (`unified_buffer.sv:118-119`) — only correct today because `ROWS==COLS==2`. Any future
   generalization to non-square activation tiles needs this fixed first, or it will silently
   read garbage/wrong-width data.
5. **Weight byte order encodes an MMU timing detail in the wire protocol.** `LOAD_WEIGHTS`
   requires the host to send `[w10,w11,w00,w01]` — bottom row before top row — because that's
   the order `weight_fifo` needs to drain into the systolic array correctly. This is a leaky
   abstraction: a host-side bug that reverses the two rows produces a matrix transposed along
   the wrong axis with no error indication. A `tpu_sequencer`-side reorder (accept natural
   `[w00,w01,w10,w11]` order from the host, re-sequence internally before writing to
   `weight_fifo`) would remove that foot-gun without changing `weight_fifo`'s contract.
6. **`weight_fifo`'s double-buffering is unused by the current protocol.** The module is
   explicitly built to let a new weight matrix stream into the shadow bank while the MMU
   drains/computes on the active one (`weight_fifo.sv:44-59`), but `tpu_sequencer`'s `RUN` is
   single-shot request/response — there's no command that lets the host push
   `LOAD_WEIGHTS` for matrix *N+1* while matrix *N* is still computing. Exploiting this would
   require a new command (or an implicit pipelining rule: allow `LOAD_WEIGHTS` while `busy`
   is high) plus host-side changes; today it's dead capability.
7. **`uart_rx.rx_error` is unwired.** `tpu_top.sv` never connects it to the sequencer, so a
   framing error just drops the byte silently — the host would see a hang (eventually a
   timeout in whatever state is waiting on that byte) rather than an explicit NACK. Wiring
   `rx_error` into an early abort → `STATUS_ERR` response would make failures visible instead
   of silent.
