# Host protocol

How the host drives the array. `rtl/tpu_sequencer.sv`'s header comment is the
normative definition — this page explains it and covers the layers around it
(PHY choice, firmware-local commands, host driver).

## 1. Framing

Host-initiated, request/response, one outstanding transaction:

```
Host → FPGA:  [CMD][LEN][payload[LEN]]
FPGA → Host:  [STATUS][LEN][payload[LEN]]

STATUS: 0xAA = OK, 0xFF = unknown CMD / framing error / bad LEN
```

`LEN` is one byte, so **255 payload bytes is a hard frame cap** — the reason
`STREAM_RUN` carries per-frame tiling flags (§3).

Byte counts below are for a generic `ARRAY_ROWS × NUM_COLS` array with
`M_TILE` activation rows; parenthesised values are the 2×2 case.

## 2. Commands

| CMD | Name | LEN | Payload |
|---|---|---|---|
| `0x01` | `LOAD_WEIGHTS` | `ARRAY_ROWS*NUM_COLS` (4) | weight rows **bottom-first**, `NUM_COLS` int8 each |
| `0x02` | `LOAD_BIAS` | `PSUM_BYTES*NUM_COLS` (4) | `NUM_COLS` signed LE, `PSUM_BYTES` each |
| `0x03` | `LOAD_ACT` | `M_TILE*ARRAY_ROWS` (4) | activation rows, natural row-major, int8 |
| `0x04` | `RUN` | 0 or 1 | empty, or `[flags]` |
| `0x05` | `RESET` | 0 | — |
| `0x06` | `RUN_TILE` | `1+ARRAY_ROWS*NUM_COLS+M_TILE*ARRAY_ROWS` (9) | `[flags, weights, acts]` |
| `0x07` | `STREAM_RUN` | `2+K_TILES*(tile bytes)` | `[flags, K_TILES, tile₀, tile₁, …]` |
| `0xFF` | `NOP` | *(no LEN byte)* | ignored in `S_IDLE`, no response — the SPI read-poll filler |

`LOAD_*` latch into a persistent register file and ACK immediately; no
datapath activity happens until a `RUN`-family command.

**`RUN` response** on a `TILE_LAST` pass: `STATUS=0xAA`,
`LEN=PSUM_BYTES*M_TILE*NUM_COLS` (8), row-major signed LE. On a non-last
pass: bare `STATUS=0xAA, LEN=0`.

`PSUM_BYTES` is `PSUM_WIDTH/8`, **2 in every bitstream built so far**. It is
a synthesis-time constant like the shape, so a host that disagrees gets a
frame-length error rather than a wrong answer — and because `LEN` caps a
frame at 255 bytes, a wider build also caps `M_TILE*NUM_COLS` (at 63 when
`PSUM_WIDTH=32`). The sequencer refuses to elaborate past that.

### The flags byte

`flags[0]=TILE_FIRST`, `flags[1]=TILE_LAST` — threaded straight into
`accumulator.sv`. `flags[2]=ACT_BYPASS` skips the ReLU clamp for this pass,
returning the biased sum unchanged; it is only observable on a `TILE_LAST`
pass, since that is the only one activation fires on. `RUN` with `LEN=0` is
equivalent to `flags=TILE_FIRST|TILE_LAST`, i.e. the original single-shot
behaviour, so a host that never sends the byte still works. Bit positions
are named in `rtl/tpu_pkg.sv` and mirrored in `tpu_host.py`. See
[`architecture.md`](architecture.md) §4 for the accumulation semantics.

## 3. The batched commands

Three generations, each reducing round trips. All three still work; the
older ones are kept as bisect fallbacks.

**`RUN_TILE` (0x06)** folds `LOAD_WEIGHTS` + `LOAD_ACT` + `RUN` into one
frame: one round trip per K-tile instead of three. Weights are in **natural
row-major** order here (the sequencer does the bottom-first reorder
internally). Does not touch `reg_bias` — `LOAD_BIAS` stays a separate,
once-per-output-block command.

**`STREAM_RUN` (0x07)** carries a whole K-run in one frame. The sequencer
deserializes each tile straight into the register file as bytes arrive —
there is **no whole-frame buffering** (a 255-byte register buffer is
prohibitive on the UP5K) — and runs a full pipeline pass between tiles.

Because 255 bytes caps `K_TILES` per frame (31 at 2×2, while MNIST layer 1's
K=144 needs 72 K-tiles), a K-run chains across frames using the flags byte:
`first=1,last=0` / `0,0` / … / `0,last=1`.

> **Timing assumption.** Between tiles the sequencer spends one pipeline pass
> (~25–35 cycles) *not* consuming RX bytes. This is safe only while byte time
> exceeds pass latency. On UART that is `10*CLK_FREQ/BAUD_RATE` cycles
> (~1042 at 12 MHz/115200). On SPI it is why the write clock is capped at
> `CLK/6`. **Any new `CLK_FREQ`/baud or SPI-clock pairing must preserve
> this.**

`K_TILES=0`, or a `LEN` that doesn't equal `2+K_TILES*(tile bytes)`, answers
`STATUS_ERR` immediately.

## 4. PHY: the same byte stream over three transports

The sequencer sees an identical byte-stream interface in all three cases; the
protocol above is unchanged.

**UART** (`USE_SPI=0`) — 8-N-1. The FPGA-side baud divider is computed at
synthesis time from `CLK_FREQ`/`BAUD_RATE`, so **those two must match the
firmware's clock request**. See [`pico2-ice.md`](pico2-ice.md) §3.

**SPI** (`USE_SPI=1`) — `rtl/spi_slave.sv`, mode 0, on the shared
RP2350↔iCE40 config bus. SPI is master-driven, so responses are **polled**:
the bridge clocks `0xFF` filler (`NOP`, ignored in `S_IDLE`) and the first
non-`0x00` MISO byte is the STATUS. Both clocks are CLK-capped — write
≤ `CLK/6` (the inter-tile window above), read ≤ `CLK/8` (the 2FF SCK
synchronizer). At the 24 MHz core clock that is 4 MHz / 3 MHz. No baud
coupling, which is what allows the higher core clock.

**HPS Avalon-MM** (`tpu_top_hps`) — `rtl/hps_bridge.sv`, memory-mapped, fixed
read latency 1, no waitrequest. Driven from the board's own Linux over
`/dev/mem`. See [`de1soc.md`](de1soc.md).

## 5. Firmware-local commands (SPI builds)

`firmware/tpu_tile.c` captures two command bytes off the CDC stream that
**never reach the FPGA**. Every sequencer command still passes through
byte-identically, so raw-protocol tests double as pass-through coverage.

| CMD | Name | Behaviour |
|---|---|---|
| `0xF1` | `FW_PROBE` | → `[0xAA][0x02]['T'][ver]`. Pre-offload firmware forwards it and the FPGA's `STATUS_ERR` reads as "not supported" |
| `0xF0` | `FW_MATMUL` | dims header + raw W/bias/A bulk + checksum in **one** CDC write; the RP2350 runs the entire `LOAD_BIAS` + chained-`STREAM_RUN` loop over SPI and answers with the raw de-tiled `2*M*N`-byte result |

`FW_MATMUL` collapses MNIST from ~45 USB round trips per image to 2 (one per
layer). Zero-padding happens in the tile gather — no padded copies are
materialized. Results are bit-identical to the host-tiled path, A/B-verified
in `tests/hw_regression.py`.

## 6. Host side

`tpu_host.py` (repo root) implements all of the above:

- `TPU(rows, cols, m_tile, psum_width=16)` — frame sizes are derived from
  the shape and the PSUM width.
- `load_weights` / `load_bias` / `load_activations` / `run` / `reset` —
  the legacy one-command-at-a-time API.
- `run_tile()` — `RUN_TILE`.
- `matmul_tiled()` — the real entry point: zero-pads any M/K/N, drives
  chained `STREAM_RUN`, slices the result. Offloads to `FW_MATMUL` by
  default when the firmware probes as supporting it; `offload=False` /
  `--no-offload` forces the host-tiled path.
- `act_bypass=` on `run`/`run_tile`/`stream_run`/`matmul_tiled` sets
  `flags[2]`. `FW_MATMUL` cannot carry it (nor a widened PSUM), so
  `matmul_tiled` falls back to the host-tiled path in either case.
- CLI: `--port`, `--link {uart,spi,hps}`, `--rows/--cols/--m-tile`,
  `--psum-width`, `--selftest`, `--weights/--activations/--bias`, `--reset`.

`tests/hw_regression.py` drives the same protocol for the full regression.

Driving the board directly from a terminal or another language is entirely
reasonable — the sequencer's header comment is all you need.
