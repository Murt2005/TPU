# Backlog

Open work, in rough value order. The DE1-SoC and its instruction-stream core
([`isa.md`](isa.md)) are the active target. A change there is trusted once
`make isa-test`, `make lint` and the board tiers in
[`verification.md`](verification.md) are green.

## High value

**One core.** The instruction-stream core lives in `rtl/isa/`, beside the
legacy `rtl/core/`, which only the pico2-ice uses. With the pico2-ice no
longer developed, the plan is to move the new core into `rtl/core/` in
place:
- **Rewritten:** `pe.sv`, `mmu.sv`, `accumulator.sv`, `bias.sv`,
  `activation.sv`, `unified_buffer.sv`, `tpu_core.sv`, `tpu_pkg.sv`.
- **Replaced:** the sequencer, by the dispatcher and the LD/WT/MM/ACT engine
  files.
- **Kept unchanged:** `fifo.sv`, `systolic_data_setup.sv`.
- **Deleted:** `weight_fifo.sv`, `pe_pair.sv`.

Then the pico2-ice board directory, its peripherals and testbenches, and the
old protocol driver can go in a second commit. `make isa-test`, the
self-test's cycle-exact perf captures and a board run catch any behavioural
drift.

**ARM preprocessing.** 48.9 µs of the 109.5 µs MNIST image is
`mnist_tpu.c`'s float downsample and quantize. It's bit-exact with numpy,
which constrains how it can change. An integer or table-driven version has
to stay byte-identical on all 10,000 test images (the bench checks this).

**Fewer bridge accesses per inference.** At m = 1 the TPU path is 60.6 µs on
the board, against 29.4 µs of equivalent register traffic at one access per
cycle in Verilator. The infer program is the same 11 instructions every
time, so a resident-program register (replay the last program, push only
data) would remove most of them. Wider or burst transfers over the full
HPS→FPGA bridge would cut the rest.

**A larger array.** 78 of 87 DSP blocks are used at 8×8: 64 PEs, 8
requantizer lanes and the tile-count products. 16×16 needs the PE multiplies
packed three per DSP block (Cyclone V's 9×9 mode) or partly in soft logic.
The RTL is fully parameterized in `N` and verified at 8 and 4.

## Medium

**Ethernet on the rev H board.** The 2014 SD image's Ethernet links but
receives nothing. A boot loader generated from the rev H GHRD's handoff files
is the likely fix, and that needs SoC EDS on top of Quartus. Today
everything (including file uploads) goes over the console, which works, so
this is convenience.

**DDR3 (spec phase 5).** `RD_DDR_UB`, `SET_OBASE`, `MATMUL wsrc=1` and
`ACTIVATE dst=DDR` decode and are rejected as `ERR_UNIMPL`. Needed once a
model's weights outgrow WMEM (8192 rows).

**The transformer on the new core.** `software/llm/` targets the legacy
byte protocol (`PSUM_WIDTH=32`, `--link sim`/`hps`). The instruction-stream
core has a 32-bit ACC and can return int32 rows to the host, so a compiler
from the GPT-Neo layers to `MATMUL`/`ACTIVATE` would put it on the board.

**A bigger MNIST model.** The current one is sized to stay provably inside
the legacy core's non-saturating int16 PSUM ([`mnist.md`](mnist.md) §2). The
new core accumulates in 32 bits and requantizes in hardware, so that
constraint is gone.

## Low / speculative

**The FPGA-side UART.** The CP2105's second ("Standard") port goes straight
to FPGA pins, up to 921,600 baud. It's a host path that bypasses Linux, but
it's slower than the HPS console's 1.5625 Mbaud, so it's only interesting
for an HPS-less setup.

**int4 payload packing.** Halves weight and activation bytes. Gated on a
software accuracy experiment first.

## Legacy core (pico2-ice): parked

Valid but not being pursued, since the pico2-ice isn't developed any more:
- `M_TILE` image batching in `software/mnist/infer.py` (projected ~17
  ms/image at 4×4/M_TILE=4)
- addressable resident weights and shadow-bank overlap for `tpu_sequencer`
  (both exist in the instruction-stream core now)
- a `PSUM_WIDTH=32` iCE40 bitstream
- `--link hps` in `hw_regression.py` / `infer.py`
- packed headers, the fixed-cycle `WAIT_TIMEOUT` replacement, and the
  accumulator's lockstep column gate

## Done — kept so the trail is legible

The instruction-stream core, on the DE1-SoC:
- Phase 1: the ISA, reference model, dispatcher and engines, matching the
  model word for word
- Phase 2: the requantizer and layer chaining through the UB
- Phase 3: overlapped tiles (`w_cur`/`w_next` PEs, 2-slot WT), measured at
  `max(m, N)` cycles per tile
- Quartus bring-up in an OrbStack VM; the DSP-width and requantizer-timing
  fixes
- FPGA-only self-test, PASS on the board, including the tile rate
- The GHRD integration on the rev H board; the full test suite passing from
  the ARM
- MNIST end to end on the ARM (109.5 µs/image) and the HEX-display drawing
  demo, with a 1.5625 Mbaud console link

The legacy core, on the pico2-ice (details in
[`performance.md`](performance.md) §3):
- Full sequencer parameterization (`ARRAY_ROWS`/`NUM_COLS`/`M_TILE`)
- `unified_buffer`'s ROWS/COLS indexing bug
- `CMD_RUN_TILE`, then `CMD_STREAM_RUN` with cross-frame tiling flags
- `rx_error` wired into the sequencer with an explicit `STATUS_ERR`
- Natural row-major weight order on the newer commands
- 1 Mbaud UART, then the SPI link, then the RP2350 matmul offload
- `-dsp`, then `pe_pair.sv`'s dual-8×8 `SB_MAC16` (16 PEs on 8 blocks)
- The LC diet that made 4×4/M_TILE=4 fit (`-abc9 -dff` + BRAM UB)
- `PSUM_WIDTH` as a build knob, and a per-pass ReLU bypass (`flags[2]`)
- The `--link sim` transport, and TinyStories-1M running on it (`software/llm/`)
