# Architecture

The datapath, how it's parameterized, and how the board-neutral core is
wrapped for two different FPGA targets.

## 1. Shape of the design

```
              ┌─────────────────── board top ───────────────────┐
              │                                                  │
  host PHY ──►│  uart_rx/uart_tx   OR   spi_slave   OR  hps_bridge
              │            │                                     │
              │       tpu_sequencer  (protocol decode + control)  │
              │            │                                     │
              │  ┌─────────┴──────── tpu_core ─────────────────┐  │
              │  │ unified_buffer ─► systolic_data_setup ─► mmu │  │
              │  │ weight_fifo ────────────────────────────►┘   │  │
              │  │                     mmu ─► accumulator ─►    │  │
              │  │                     bias ─► activation ─►    │  │
              │  └──────────────────────────────────────────────┘  │
              └──────────────────────────────────────────────────┘
```

`tpu_core.sv` is board-neutral and contains no host interface. Everything
target-specific lives in the top level:

| Top | Target | Host PHY |
|---|---|---|
| `rtl/tpu_top.sv` | pico2-ice (iCE40UP5K) | `uart_rx`/`uart_tx`, or `spi_slave` when `USE_SPI=1` |
| `rtl/tpu_top_hps.sv` | DE1-SoC (Cyclone V) | `hps_bridge` (Avalon-MM slave on `h2f_lw`) |

Adding a third target means writing a top level and a PHY, not touching the
datapath.

## 2. Datapath modules

Weight-stationary systolic array, in dataflow order:

| Module | Role | Latency |
|---|---|---|
| `unified_buffer.sv` | Double-banked activation SRAM; one layer's output feeds the next without leaving the chip. Two per-bank 1W1R memories with flat row words, `ram_style="block"` — maps to BRAM on both targets | host write 1 cy; UB read 2 cy |
| `weight_fifo.sv` | Ping-pong weight store; drains the active bank into the MMU during `loading_phase` while the next matrix streams into the shadow bank | 1 cy drain |
| `systolic_data_setup.sv` | Skews an activation row in time so column *i* arrives *i* cycles late, matching the array's diagonal wavefront | row *i*: *i* cycles |
| `mmu.sv` | The array itself — `ARRAY_ROWS`×`NUM_COLS` PEs. Instantiates `pe.sv`, or `pe_pair.sv` when `USE_MAC16_PAIR=1` | col *c*: 2+*c* cycles |
| `pe.sv` | One cell: stationary weight × streaming activation, partial sum forwarded down. Fully registered — no combinational path through a PE | 1 cy |
| `pe_pair.sv` | Two PEs in one hand-instantiated `SB_MAC16` (dual-8×8 signed mode). iCE40-only; bit-exact vs. two `pe.sv` | 1 cy |
| `accumulator.sv` | Reassembles the MMU's time-skewed per-column partial sums into whole rows, and holds a persistent PSUM across K-tiles | 2 cy |
| `bias.sv` | Registered per-column int16 add | 1 cy |
| `activation.sv` | Registered ReLU clamp. Applied unconditionally on every layer — there is no bypass | 1 cy |
| `fifo.sv` | Generic synchronous circular queue; used by `accumulator` and `weight_fifo` | — |

**End-to-end per-row latency**, row entering SDS → result valid: **7 cycles**
(3 MMU + 2 accumulator + 1 bias + 1 activation). Back-to-back rows follow one
cycle apart — the pipeline runs at full throughput once primed.

## 3. Parameterization

Three parameters define the shape. Every module takes them; nothing is
hardcoded to 2×2.

| Parameter | Meaning | Constraint |
|---|---|---|
| `ARRAY_ROWS` | K-tile depth — how much of the reduction dimension one pass covers | even if `USE_MAC16_PAIR=1` |
| `NUM_COLS` | N-tile width — output columns computed per pass | — |
| `M_TILE` | Activation rows streamed per `RUN` | — |
| `FIFO_DEPTH` | `tpu_top.sv` only | power of 2, ≥ `max(ARRAY_ROWS, M_TILE)` |

One `RUN` computes `Y = ReLU(A @ W + bias)` for an `M_TILE × ARRAY_ROWS`
activation block against an `ARRAY_ROWS × NUM_COLS` weight block. A matmul
of any shape is decomposed host-side (or firmware-side) into these blocks,
with zero-padding on all three axes.

The shape is a **build knob, not a rebuild of the design** — set in
`fpga/ice40/Makefile` and threaded via yosys `chparam`. The host must be
told the same shape (`tpu_host.py --rows/--cols/--m-tile`); a mismatch
produces wrong-length frames, not a clean error.

**Where the shape is asserted, and it must agree everywhere:**
`fpga/ice40/Makefile` → the bitstream → `tpu_host.py` flags → `make hw-test
ARRAY_ROWS=/NUM_COLS=/M_TILE=`.

## 4. K-dimension tiling

When a layer's K exceeds `ARRAY_ROWS`, the reduction is split across several
weight-reload passes and summed **in hardware**, before bias/ReLU ever fire.

`accumulator.sv` holds a persistent per-row PSUM register controlled by two
flags carried in the command frame:

- `TILE_FIRST=1` — overwrite the running sum (start a new K-reduction).
  `0` — add to it.
- `TILE_LAST=1` — forward the now-final sum through bias/ReLU and return
  results. `0` — update the running sum only; bias and activation never
  fire and the response is a bare ACK.

A K-run is therefore `first=1,last=0` → `0,0` → … → `0,last=1`.

**The PSUM register is 16 bits wide and does not saturate — it wraps.** This
is true regardless of tiling depth, and it is the constraint that sizes the
MNIST model (see [`mnist.md`](mnist.md)).

## 5. Two structural details worth knowing

**Weights go over the wire bottom-row-first** for the legacy
`LOAD_WEIGHTS` command (`[w10,w11,w00,w01]` at 2×2). This matches
`weight_fifo`'s staggered-loading contract: each PE must capture the top-row
weight one cycle after the bottom-row weight for the vertical propagation to
line up. The newer `RUN_TILE`/`STREAM_RUN` commands take **natural row-major**
order and do the reorder inside the sequencer — new code should use those.

**The sequencer's control FSM is counter-driven, not one-state-per-cell.**
The datapath modules have no handshakes or backpressure beyond fixed
registered latencies, so the sequencer replays an exact cycle sequence.
Changing any module's latency means changing the sequencer to match.

## 6. Where to go next

- Command frames and status codes → [`protocol.md`](protocol.md)
- Per-target build details → [`pico2-ice.md`](pico2-ice.md), [`de1soc.md`](de1soc.md)
- Resource cost of a given shape → [`performance.md`](performance.md)
