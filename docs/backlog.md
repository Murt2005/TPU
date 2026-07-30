# Backlog

Open work, in rough value order. Anything here needs `make test` and
`make hw-test` green before it's trusted — see
[`verification.md`](verification.md).

## High value

**Batch `M_TILE` images per inference call** (`mnist/infer.py`).
The one remaining lever with a large, well-understood payoff. A single image
wastes the padded activation rows: at 4×4/M_TILE=4, three of four streamed
rows are zeros. Measured M-scaling says layer 1 costs 30.6 ms per 2 rows at
M_TILE=4 vs. 44.6 at M_TILE=2, projecting **~17 ms/image** batched, against
63.8 today. `FW_MATMUL`'s header already carries `rows`/`cols`/`m_tile` per
command, so the firmware needs no change.

**DE1-SoC bring-up.** Qsys/GHRD integration → cloud Quartus build → `.rbf`
on the board → `hw_regression.py --link hps` on the board → scale the array
up to whatever closes timing at 50 MHz. Full detail in
[`de1soc.md`](de1soc.md) §5. The 8×8 sim shape already proves the RTL is
ready for a much larger array than the UP5K allowed.

## Medium

**A bigger/better MNIST model.** Gated on `accumulator.sv`'s non-saturating
int16 PSUM — see [`mnist.md`](mnist.md) §2. Either prove a wider layer's true
sum still fits in ±32,767, or widen `PSUM_WIDTH` (which means touching the
wire format and the host too).

**Packed instruction headers.** Today's byte-oriented framing spends more
bits than it needs on `CMD`/`LEN`/`flags`. A packed header would shave
per-frame overhead — but that overhead is currently dwarfed by SPI tile
traffic and USB bulk, so the payoff is small until the transport gets faster.

## Low / speculative

**int4 payload packing.** Halves weight and activation wire bytes, which are
the dominant cost. **Gated on a software-only accuracy experiment first** —
find out whether int4 weights hold 95%+ on this model before touching any
RTL.

**`STREAM_RUN` shadow-bank overlap.** The originally-planned pipelining that
would stream tile *N+1*'s weights into the shadow bank while tile *N*
computes. `weight_fifo`'s double-buffering exists and is currently unused by
the protocol. Worth ~2 ms/image at most now — likely never worth doing.

**Replace the sequencer's `WAIT_TIMEOUT` polling with a fixed-delay
counter.** Datapath latency is fixed and deterministic (no backpressure
anywhere in `tpu_core`), so waiting a known number of cycles is functionally
identical to watching for `final_row_valid` pulses, and removes the unused
timeout path. Deliberately not done: the current form is more robust to
future datapath latency changes.

**Accumulator's lockstep column gate.** `pop_row` requires every column FIFO
simultaneously non-empty, so row 0's first column idles waiting on the last.
One cycle out of ~21 at 2×2; it scales with `NUM_COLS-1` skew. Removing it
needs explicit row tagging instead of position-implied ordering.

## Done — kept so the trail is legible

These were open items in earlier planning docs and have shipped. Details in
[`performance.md`](performance.md) §3.

- Full sequencer parameterization (`ARRAY_ROWS`/`NUM_COLS`/`M_TILE`)
- `unified_buffer`'s ROWS/COLS indexing bug
- `CMD_RUN_TILE`, then `CMD_STREAM_RUN` with cross-frame tiling flags
- `rx_error` wired into the sequencer with an explicit `STATUS_ERR`
- Natural row-major weight order on the newer commands
- 1 Mbaud UART, then the SPI link, then the RP2350 matmul offload
- `-dsp`, then `pe_pair.sv`'s dual-8×8 `SB_MAC16` (16 PEs on 8 blocks)
- The LC diet that made 4×4/M_TILE=4 fit (`-abc9 -dff` + BRAM UB)
