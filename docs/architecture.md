# Architecture

The whole system, top to bottom: what runs where, how a matmul gets from a
Python call to the systolic array and back, how every RTL module behaves and
why, and which parts of the hardware exist but are not yet wired up.

Protocol byte layouts live in [`protocol.md`](protocol.md), board specifics in
[`pico2-ice.md`](pico2-ice.md) / [`de1soc.md`](de1soc.md), measured numbers in
[`performance.md`](performance.md) / [`utilization.md`](utilization.md). This
page links out rather than repeating them.

## 1. The system in one picture

The accelerator does exactly one thing: `Y = act(A @ W + bias)` on one small
fixed-size tile. Everything else — tiling a real matmul into those tiles,
layer sequencing, requantization, softmax, LayerNorm — is software.

```
 ┌──────────── host (laptop / HPS Linux) ────────────┐
 │ software/mnist/infer.py   software/llm/infer.py   tests/hw_regression│
 │            └────────┬─────────┘                    │
 │           tpu package (host/)  TPU.matmul_tiled()  │  pads + tiles any M×K×N
 │     link: uart │ spi │ hps (MmioLink) │ sim (SimLink)
 └───────────┬────┴──┬──┴───────┬───────┴──────┬──────┘
         USB-CDC  USB-CDC   /dev/mem mmap   subprocess pipe
             │       │          │               │
 ┌───────────▼───────▼──┐       │        Verilator model of
 │ RP2350 firmware      │       │        tpu_core (make sim-bridge)
 │ main.c: clock, DFU,  │       │
 │  UART↔CDC bridge     │       │
 │ tpu_tile.c: SPI      │       │
 │  bridge + FW_MATMUL  │       │
 └──────┬───────┬───────┘       │
     UART pins  SPI bus         │ h2f_lw Avalon-MM
 ┌──────▼───────▼───────┐ ┌─────▼────────────────┐
 │ tpu_top.sv (iCE40)   │ │ tpu_top_hps.sv (CV)  │
 │ uart_rx/tx │spi_slave│ │ hps_bridge           │
 │      POR counter     │ │ POR counter          │
 └──────────┬───────────┘ └─────────┬────────────┘
            └──── byte stream ──────┘
                        │  rx_data/rx_valid/rx_error, tx_data/tx_valid/tx_busy
               ┌────────▼─────────┐
               │   tpu_core.sv    │  board-neutral: sequencer + datapath
               └──────────────────┘
```

Four ways to reach the same core, all speaking the identical byte protocol:

| Path | Host driver | Physical link | Status |
|---|---|---|---|
| pico2-ice, UART | `tpu_host.py --link uart` | USB-CDC → RP2350 → UART pins, 1 Mbaud, 12 MHz core | hardware-validated |
| pico2-ice, SPI | `--link spi` | USB-CDC → RP2350 → SPI config bus, 24 MHz core; optional `FW_MATMUL` offload | hardware-validated |
| DE1-SoC | `--link hps`, run *on the board* | ARM HPS → `/dev/mem` → lightweight H2F Avalon bridge | sim-tested only |
| Simulation | `--link sim` | pipe to a Verilator build of `tpu_core` | sim |

The key design decision: **every PHY presents the same byte-stream interface
to the sequencer**, so the sequencer and datapath never change when the
transport does, and every host-side program works on every path by changing
`--link`.

## 2. Inside `tpu_core`

```
 host bytes ─► tpu_sequencer ──┬─ host_write ─► unified_buffer ─ub_read─► systolic_data_setup ─┐
               (decode + FSM,  │                                                               │ skewed rows
                register file) ├─ write_col ──► weight_fifo ──out_col (= capture)──────────► mmu
                               │               (swap_banks, loading_phase)                     │ per-column psums
                               ├─ tile_first/tile_last ────────────────────────────────► accumulator
                               ├─ out_bias ───────────────────────────────────────────────► bias
                               ├─ act_bypass ───────────────────────────────────────► activation
                               ◄──────────────── final_row_out / final_row_valid ──────────┘
```

`tpu_core.sv` contains no host interface and no vendor primitive (the one
exception, `pe_pair`, is reachable only with `USE_MAC16_PAIR=1`). Everything
target-specific is in a top level or a PHY:

| Top | Target | Host PHY |
|---|---|---|
| `boards/pico2-ice/top/tpu_top.sv` | pico2-ice (iCE40UP5K) | `uart_rx`/`uart_tx`, or `spi_slave` when `USE_SPI=1` |
| `boards/de1soc/top/tpu_top_hps.sv` | DE1-SoC (Cyclone V) | `hps_bridge` (Avalon-MM slave on `h2f_lw`) |

The repo layout follows the same line: `rtl/core/` and `rtl/peripherals/` are
shared by every board, and everything specific to one board — its top level,
pins, build flow, firmware — lives under `boards/<board>/`. Adding a third
target means a new `boards/` directory with a top level (and a PHY in
`rtl/peripherals/` if none of the existing ones fits), not touching the
datapath.

**Resets.** Both tops hold an internal power-on reset for 256 cycles after
configuration, OR'd with `~reset_n` — without it the design never leaves its
power-up state on pico2-ice ([`pico2-ice.md`](pico2-ice.md) §5.5). Inside the
core, the datapath's reset is `reset | tpu_reset`, where `tpu_reset` is the
sequencer's 4-cycle soft reset for `CMD_RESET`. The sequencer itself only
takes the hard reset, so `CMD_RESET` clears the pipeline and accumulator but
keeps the register file (weights, activations, bias).

## 3. Datapath modules

Weight-stationary systolic array, in dataflow order. `R` = `ARRAY_ROWS`,
`C` = `NUM_COLS`, `M` = `M_TILE`.

| Module | Role | Latency |
|---|---|---|
| `unified_buffer.sv` | Activation SRAM: `M` addresses, one `R`-byte row each. Two per-bank 1W1R memories, `ram_style="block"` / `ramstyle="M10K"` — BRAM on both targets | host write 1 cy; UB read 2 cy |
| `weight_fifo.sv` | Ping-pong weight store: `C` column FIFOs × 2 banks. Host writes the shadow bank; `swap_banks` makes it active; `loading_phase` drains it into the array | 1 cy drain |
| `systolic_data_setup.sv` | Skews an activation row in time: element *i* is delayed *i* cycles (shift register of length *i*) | element *i*: *i* cy |
| `mmu.sv` | The `R`×`C` array of `pe.sv`, or `pe_pair.sv` when `USE_MAC16_PAIR=1` | column *c* output: `R + c` cy after the row enters SDS |
| `pe.sv` | One cell: stationary int8 weight × streaming int8 activation + incoming psum. Fully registered — no combinational path through a PE | 1 cy |
| `pe_pair.sv` | Two row-adjacent PEs in one hand-instantiated `SB_MAC16` (dual-8×8 signed). iCE40-only; bit-exact vs. two `pe.sv` | 1 cy |
| `accumulator.sv` | Per-column FIFOs that re-align the skewed column outputs into whole rows, plus the persistent PSUM register for K-tiling | 2 cy |
| `bias.sv` | Registered per-column add of a `PSUM_WIDTH` bias | 1 cy |
| `activation.sv` | Registered ReLU clamp, bypassable per pass (`flags[2]`); same latency either way | 1 cy |
| `fifo.sv` | Generic synchronous circular queue (power-of-2 depth); used by `weight_fifo`, `accumulator`, `spi_slave` | — |

**End-to-end per-row latency**, row entering SDS → `final_row_valid`:
**`R + C + 3` cycles** — `R+C−1` through the skew and the array to the last
column, then 2 accumulator + 1 bias + 1 activation. That is 7 at 2×2 and 11
at 4×4. Back-to-back rows follow one cycle apart once the pipeline is primed.

### 3.1 How one tile moves through the array

**Weights are loaded, then held.** The sequencer writes the weight rows into
the `weight_fifo` shadow bank **bottom row first**, swaps banks, and raises
`loading_phase` for `R+1` cycles. During loading, each PE registers the
incoming weight down to the PE below, and every PE in column *c* captures
whenever `out_col_valid[c]` is high (it doubles as the capture strobe). So
the bottom row's weights enter first, get pushed down one row per cycle, and
after `R` cycles every PE holds the right weight. Present them top-first and
the matrix loads flipped — that is why the legacy `LOAD_WEIGHTS` command
takes bottom-first wire order, and why the newer commands let the sequencer
do the reorder.

**Activations are skewed and streamed.** Each activation row (one row of `A`,
`R` bytes wide = one K-slice) is read from the unified buffer and fed through
`systolic_data_setup`, which delays element *i* by *i* cycles. Inside the
array activations shift right one PE per cycle and partial sums shift down
one PE per cycle. The skew makes these meet correctly: PE (*r*, *c*) sees
activation element *r* at the same moment the psum carrying rows 0..*r*−1 of
column *c* arrives from above.

**Results come out skewed too.** Column *c*'s finished dot product leaves the
bottom edge at cycle `R + c`, so the columns of one output row emerge on
different cycles. The accumulator pushes each column into its own FIFO and
pops a whole row the moment every FIFO is non-empty — the mirror image of the
input skew.

**The rest is per row:** the accumulator adds the row into (or overwrites)
its PSUM register, and on the last K-tile forwards it through bias and
activation to the sequencer.

### 3.2 `pe_pair`: two PEs per DSP

The iCE40UP5K has 8 `SB_MAC16` blocks. In dual-8×8 signed mode one block
contains two independent 8×8 multipliers, each with its own 16-bit adder and
output register — exactly two PE MACs. `pe_pair`'s port list is two `pe.sv`
interfaces, so `mmu.sv` drops one in place of PEs (*r*, *c*) and (*r*+1, *c*)
with no wiring changes. The fabric hop from the top half's output to the
bottom half's adder input *is* the inter-PE pipeline register.
Bit-exactness comes from gating the adder inputs instead of muxing the output
(details in [`performance.md`](performance.md) §2). Constraints: `R` must be even, and `PSUM_WIDTH` must
be 16, since the DSP accumulator is a hard 16 bits. The build drops `-dsp`
when pairing so yosys doesn't remap the hand-placed primitives.

## 4. The control plane: `tpu_sequencer.sv`

The sequencer is the whole "instruction unit": it parses command frames,
keeps a register file, and replays a fixed cycle schedule against the
datapath. **The datapath has no handshakes or backpressure**, so the sequencer
relies on the fixed latencies in §3. Changing any module's latency means
changing the sequencer to match.

### 4.1 State

A persistent register file that survives across commands:

| Register | Shape | Written by |
|---|---|---|
| `reg_weights` | `R × C` int8, natural row-major | `LOAD_WEIGHTS` (reordered from bottom-first), `RUN_TILE`, `STREAM_RUN` |
| `reg_act` | `M × R` int8 | `LOAD_ACT`, `RUN_TILE`, `STREAM_RUN` |
| `reg_bias` | `C × PSUM_WIDTH` | `LOAD_BIAS` only |
| `reg_tile_first/last`, `reg_act_bypass` | 1 bit each | the flags byte of each `RUN`-family command |
| `result_rows` | `M × C × PSUM_WIDTH` | captured from `final_row_valid` |

Plus an RX payload buffer for fixed-size frames and a TX buffer for the
response. These are why the sequencer is the largest block in the design
([`performance.md`](performance.md) §2); matrix bytes are staged twice — once
in the payload buffer, once in the register file.

### 4.2 The FSM

17 states, counter-driven (a loop counter per phase, not one state per
row/column — that is what makes the shape a parameter):

```
S_IDLE ─CMD─► S_RECV_LEN ─► S_RECV_PAYLOAD ─► S_EXEC_DISPATCH
                  │                               │
                  └─(STREAM_RUN)─► S_SR_FLAGS ─► S_SR_KT ─► S_SR_RECV_TILE ◄──┐
                                                               │ tile done    │
 LOAD_* ─► ACK                                                  ▼              │
 RUN/RUN_TILE ─► S_WR_UB ─► S_LD_WF ─► S_LD_WF_GAP ─► S_SWAP ─► S_LOADING ─►   │
                 S_STREAM ─► S_WAIT ──(more tiles in frame)────────────────────┘
                               └──► S_TX_STATUS ─► S_TX_DATA ─► S_IDLE
 RESET ─► S_RESET_PULSE ─► ACK
```

One **pass** (a RUN, or one tile of a STREAM_RUN):

1. `S_WR_UB` — write the `M` activation rows into the unified buffer.
2. `S_LD_WF` — write the `R` weight rows into the weight FIFO, bottom row first.
3. `S_LD_WF_GAP`, `S_SWAP` — one idle cycle, then pulse `swap_banks`.
4. `S_LOADING` — hold `loading_phase` for `R+1` cycles.
5. `S_STREAM` — read UB addresses 0..`M−1` into the skew/array.
6. `S_WAIT` — count `final_row_valid` pulses up to `M` (or wait for
   `accum_pass_done` on a non-last K-tile, since nothing reaches the output
   then). Guarded by `WAIT_TIMEOUT` (200 cycles) → `STATUS_ERR`.
7. Pack the result rows little-endian and transmit via `S_TX_*`, or return to
   `S_SR_RECV_TILE` for the next tile.

A pass costs `load(R+3) + stream(M) + drain(R+C+6)` cycles — 19 at 2×2,
29 at 4×4/M=4 ([`utilization.md`](utilization.md) §1 has the traced numbers).
Only `M` of those cycles feed new rows in, which is why array utilization is
low.

### 4.3 STREAM_RUN without a frame buffer

A `STREAM_RUN` frame carries up to 255 bytes of back-to-back tiles. Instead of
buffering it, `S_SR_RECV_TILE` writes each byte straight into `reg_weights`
then `reg_act` as it arrives, and on a tile's last byte starts a pass. During
that pass (19–49 cycles across the traced shapes) the sequencer **is not reading RX**. That is safe
only because the next byte takes longer than that to arrive — UART byte time
at 1 Mbaud/12 MHz is 120 cycles, and SPI writes are capped at `CLK/6` to keep
it so. **Any faster link or clock pairing must preserve this.**

### 4.4 Errors

`STATUS_ERR` (`0xFF`) answers an unknown command, a wrong `LEN` for a
fixed-size command, `K_TILES=0` or a mismatched `STREAM_RUN` length, a
`WAIT_TIMEOUT`, or a UART framing error (edge-detected `rx_error`, which
aborts the frame in progress). Every error returns to `S_IDLE`, so the host
can resynchronise — `tpu_host.py` does this on connect by sending 258 zero
bytes (enough to finish any half-received frame), discarding the error
chatter, sending `RESET`, then probing the result length to detect a shape
mismatch. `0xFF` in
`S_IDLE` is `NOP` and is silently ignored, which is what lets SPI read-polling
clock filler bytes through the same stream.

## 5. Parameterization

Four parameters define the shape and width. Every module takes them; nothing
is hardcoded to 2×2.

| Parameter | Meaning | Constraint |
|---|---|---|
| `ARRAY_ROWS` (`R`) | K-tile depth — how much of the reduction one pass covers; also the width of one activation row | even if `USE_MAC16_PAIR=1` |
| `NUM_COLS` (`C`) | N-tile width — output columns per pass | — |
| `M_TILE` (`M`) | Activation rows streamed per pass (UB depth; accumulator rows per pass) | — |
| `PSUM_WIDTH` | Width of the psum/accumulate/bias/result path, and the wire bytes per bias/result element (`PSUM_BYTES = PSUM_WIDTH/8`) | multiple of 8; `PSUM_BYTES*M*C ≤ 255`; 16 if `USE_MAC16_PAIR=1` |
| `FIFO_DEPTH` | Depth of the weight and accumulator FIFOs | power of 2, ≥ `max(R, M)`. Default 4, and **not** a `boards/pico2-ice/fpga/Makefile` knob — larger shapes need it raised |
| `USE_MAC16_PAIR` | `pe_pair` instead of `pe` | iCE40 only |
| `USE_SPI` (`tpu_top` only) | SPI PHY instead of UART | needs SPI firmware |
| `CLK_FREQ`, `BAUD_RATE` (`tpu_top` only) | UART divider, fixed at synthesis | must match firmware clock and host baud |

The sequencer checks `PSUM_WIDTH % 8`, the result-frame and bias-frame sizes
against the 255-byte `LEN` cap, and `mmu` checks the `pe_pair` constraints,
all at elaboration — a bad combination fails the build rather than
misbehaving.

One pass computes `Y = act(A @ W + bias)` for an `M × R` activation block
against an `R × C` weight block. A matmul of any shape is split into these
blocks by the host (or by the firmware), with zero-padding on all three axes.

The shape is a **build knob, not a redesign** — set in `boards/pico2-ice/fpga/Makefile`
and passed to yosys with `chparam`. The host must be told the same shape
(`tpu_host.py --rows/--cols/--m-tile/--psum-width`); a mismatch gives
wrong-length frames, not a clean error. **It must agree in four places:**
`boards/pico2-ice/fpga/Makefile` → the bitstream → the host flags → `make
hw-test`. Named configurations (`boards/pico2-ice/configs/*.mk`, loaded by
`boards/pico2-ice/config.mk`) make that one name: `make CONFIG=4x4_spi` builds
the bitstream, `make hw-test CONFIG=4x4_spi` tests it, and `make host-flags
CONFIG=4x4_spi` prints the flags for everything else.

## 6. K-dimension tiling

When a layer's K is larger than `ARRAY_ROWS`, the reduction is split across
several weight-reload passes and summed **in hardware**, before bias/ReLU
ever fire.

`accumulator.sv` keeps a persistent `psum_reg[M_TILE][NUM_COLS]`, controlled
by two flags in the command frame:

- `TILE_FIRST=1` — overwrite the running sum (start a new K-reduction).
  `0` — add to it.
- `TILE_LAST=1` — forward the now-final sum through bias/activation and
  return results. `0` — update the running sum only; bias and activation
  never fire and the response is a bare ACK.

A K-run is therefore `first=1,last=0` → `0,0` → … → `0,last=1`.
`STREAM_RUN` applies `first` to its frame's first tile and `last` to its
last, so a K-run can span several frames.

## 7. Numerics

- **int8 × int8 products, summed in `PSUM_WIDTH`**, signed two's complement
  throughout.
- **The PSUM does not saturate — it wraps.** This is true regardless of how
  many K-tiles feed it. At the default `PSUM_WIDTH=16` it is the constraint
  that sizes the MNIST model ([`mnist.md`](mnist.md) §2). `PSUM_WIDTH=32`
  raises it (the `software/llm/` transformer requires it), but no bitstream has been
  built at 32; it is covered in simulation only.
- **Bias** is a full `PSUM_WIDTH` value per column, added once per output
  block, not per K-tile.
- **Activation** is ReLU or bypass, chosen per pass. There is no other
  non-linearity and **no on-chip requantization**: results come back at
  `PSUM_WIDTH`, and the host rescales them to int8 before they become the
  next layer's input.

## 8. Host PHYs

All four turn a transport into `rx_data/rx_valid/rx_error` and
`tx_data/tx_valid/tx_busy`.

| PHY | Transport | Notes |
|---|---|---|
| `uart_rx.sv` / `uart_tx.sv` | 8-N-1 on two pins | 16× oversampling. The baud divider is fixed at synthesis from `CLK_FREQ/BAUD_RATE`. `rx_error` = bad stop bit |
| `spi_slave.sv` | Mode 0 on the RP2350↔iCE40 config bus | The RX shift register runs on SCK; bytes cross to `clk` via a toggle-flag synchronizer. TX goes through a 16-deep FIFO, with MISO driven from synchronized SCK edges. MISO reads `0x00` when idle, so the first non-zero byte of a poll is STATUS. Write ≤ `CLK/6`, read ≤ `CLK/8`. No `rx_error` |
| `hps_bridge.sv` | Avalon-MM slave, 3 word registers | `TXDATA` (write → one rx byte), `RXDATA` (read pops a tx byte), `STATUS` (bit 0 TX_SPACE, always 1; bit 1 RX_AVAIL). Fixed read latency 1, no waitrequest, single clock domain |

On pico2-ice the FPGA has no crystal: `clk` comes from the RP2350's `GPOUT0`,
which is why `CLK_FREQ` in the gateware must match the firmware's
`ice_fpga_init()` request (12 MHz for UART builds, 24 MHz for SPI builds).

## 9. Hardware that exists but isn't wired up

Several modules were written to the full TPUv1 design and have capabilities
`tpu_core` does not use yet. Knowing this avoids reading more into the
module ports than actually ships:

| Capability | Where | State in `tpu_core` |
|---|---|---|
| Layer-to-layer on-chip data: activation writes into the UB's shadow bank, then `bank_swap` | `unified_buffer` `act_write_*`, `bank_swap` | **Tied off.** Results always go back to the host, which requantizes and sends them in again |
| UB host read port | `unified_buffer` `host_read_*` | Tied off |
| Weight double-buffering (load tile *N+1* while tile *N* computes) | `weight_fifo` shadow bank, `shadow_loaded`, `any_shadow_full` | The bank swap is used, but the sequencer loads → computes → drains serially, and the status outputs are unconnected. See [`utilization.md`](utilization.md) §2 for what overlap would buy |
| FIFO-full status | `accumulator.any_fifo_full` | Unconnected |
| Busy flag | `tpu_sequencer.busy` | Unconnected |

These are the natural extension points; [`utilization.md`](utilization.md)
§4–5 and [`backlog.md`](backlog.md) rank them.

## 10. The software stack

### 10.1 `host/tpu/` — the driver

A small installable package (`pip install -e host`; `requirements.txt` does
it). `python3 -m tpu`, the `tpu-host` command and the root `tpu_host.py`
wrapper are the same CLI.

| Module | Holds |
|---|---|
| `protocol.py` | Opcodes, flag bits, status bytes, link constants — the Python copy of `rtl/core/tpu_pkg.sv` |
| `links.py` | `MmioLink`, `SimLink`, `open_link()` |
| `driver.py` | The `TPU` class |
| `golden.py` | The reference numerics: exact int8 matmul, wrap to `PSUM_WIDTH`, optional ReLU. The one Python copy — the regression suite, the selftest, `software/mnist` and `software/llm` all use it |
| `cli.py` | Argument parsing and `--selftest` |


- **Links**: pyserial for `uart`/`spi` (the RP2350 bridges both as USB-CDC;
  `spi` changes only pacing and wire accounting), `MmioLink` for `hps`
  (mmaps `/dev/mem`), `SimLink` for `sim` (runs the Verilator bridge as a
  subprocess). All are duck-typed `read`/`write`, so nothing above them
  knows which is in use.
- **On connect**: resynchronises the sequencer, probes the result length to
  catch a shape mismatch, and probes the firmware for `FW_MATMUL`.
- **`matmul_tiled(a, w, bias)`** is the real entry point: zero-pads M/K/N to
  the tile grid, then for each (`M_TILE` × `NUM_COLS`) output block sends
  `LOAD_BIAS` once and the block's whole K-run as chained `STREAM_RUN`
  frames, and slices the padding off. With SPI+offload firmware the same
  loop runs on the RP2350 instead (`FW_MATMUL`: one USB round trip per
  matmul, bit-identical results). A widened PSUM or `act_bypass=True` falls
  back to the host path, since the firmware is int16/ReLU-only.
- Legacy one-command API (`load_weights`, `run`, …), `run_tile`,
  `stream_run`, wire-byte accounting, and a CLI with `--selftest`.

### 10.2 `boards/pico2-ice/firmware/` — the RP2350

The FPGA is a peripheral of the microcontroller. `main.c` brings up USB (two
CDC ports + DFU), exports the FPGA clock, loads the bitstream, shows the real
`CDONE` state on the LED, and bridges the TPU CDC port to the UART with a
ring buffer drained from the main loop (not the ISR — see
[`pico2-ice.md`](pico2-ice.md) §7). The second CDC port takes one-byte LED
commands. With `TPU_LINK_SPI=ON`, `tpu_tile.c` replaces the UART bridge with
an SPI bridge (write-then-poll) and handles `FW_PROBE`/`FW_MATMUL` itself
without forwarding them. Firmware must be flashed before gateware, because
without it the FPGA has no clock.

### 10.3 Workloads

- **`software/mnist/`** — a 144→64→10 int8 MLP designed around the hardware's
  numerics. `infer.py` runs it layer by layer through `matmul_tiled`,
  requantizing on the host between layers; `draw_demo.py` is the interactive
  demo. See [`mnist.md`](mnist.md).
- **`software/llm/`** — TinyStories-1M (GPT-Neo) with every linear layer on the
  array: q/k/v/out, both MLP projections, and the lm_head. Embedding,
  LayerNorm, softmax, GELU and residuals stay on the host. Needs
  `PSUM_WIDTH=32` and `act_bypass`, so today it runs against the Verilator
  model (`--link sim`) only. See `software/llm/README.md`.

## 11. Build flow

**iCE40** (`boards/pico2-ice/fpga/Makefile`): yosys reads `rtl/core/`,
`rtl/peripherals/` and `boards/pico2-ice/top/`, `chparam`s the
knobs from §5 onto `tpu_top`, and runs `synth_ice40` with `-dsp` (unless
pairing) and `-abc9 -dff`. Then nextpnr-ice40 (`--up5k --package sg48`,
`tpu_top.pcf`), icepack, and `dfu-util` via the RP2350. The UB maps to
`SB_RAM40_4K`; PE multiplies map to `SB_MAC16`, either inferred or
hand-instantiated.

**Cyclone V** (`boards/de1soc/fpga/`): `tpu_top_hps` becomes a Platform Designer
component on the GHRD's `h2f_lw` bridge, built with `USE_MAC16_PAIR=0` so
Quartus infers its own DSPs from `pe.sv`. Scaffolded, not yet built — see
[`de1soc.md`](de1soc.md).

## 12. Where to go next

- Command frames and status codes → [`protocol.md`](protocol.md)
- What to run before trusting a change → [`verification.md`](verification.md)
- Per-target build details → [`pico2-ice.md`](pico2-ice.md), [`de1soc.md`](de1soc.md)
- Where time and LUTs go → [`performance.md`](performance.md), [`utilization.md`](utilization.md)
- Every file → [`repo-map.md`](repo-map.md)
