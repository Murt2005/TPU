# Backlog

Open work, in rough value order. A change is trusted once `make check` and,
for anything touching synthesis or timing, the board tiers in
[`verification.md`](verification.md) are green.

## High value

**ARM preprocessing.** 48.9 µs of the 109.5 µs MNIST image is
`mnist-tpu.c`'s float downsample and quantize. It's bit-exact with numpy,
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
The RTL is fully parameterized in `ARRAY_SIZE` and verified at 8 and 4.

## Medium

**Ethernet on the rev H board.** The 2014 SD image's Ethernet links but
receives nothing. A boot loader generated from the rev H GHRD's handoff files
is the likely fix, and that needs SoC EDS on top of Quartus. Today
everything (including file uploads) goes over the console, which works, so
this is convenience.

**DDR3 (spec phase 5).** `MATMUL wsrc=1` (prefetching across `MATMUL`s),
`RD_DDR_UB`, `SET_OBASE` and `ACTIVATE dst=DDR` are built, and the card
boots with the port live (`u-boot.scr`). Left: porting the LLM path
(`software/llm/` at the tag `pico2-ice-final`) onto them. Sustained FPGA-to-SDRAM bandwidth is
measured: 800 MB/s on a 128-bit port at 50 MHz, the port's peak, also under
ARM memory load ([`de1soc.md`](de1soc.md) §7).

**A transformer on the core.** The first core ran TinyStories-1M (GPT-Neo)
with every linear layer on the array, in simulation (`software/llm/`, at the
tag `pico2-ice-final`). The current core has a 32-bit ACC and returns int32
rows to the host, so a compiler from the GPT-Neo layers to `MATMUL`/`ACTIVATE`
would put it on the board.

**A bigger MNIST model.** The current one is sized to stay provably inside
the first core's wrapping int16 accumulator ([`mnist.md`](mnist.md) §2). This
core accumulates in 32 bits and requantizes in hardware, so that constraint
is gone. Retraining without ReLU on the output layer is also possible now.

## Low / speculative

**The FPGA-side UART.** The CP2105's second ("Standard") port goes straight
to FPGA pins, up to 921,600 baud. It's a host path that bypasses Linux, but
it's slower than the HPS console's 1.5625 Mbaud, so it's only interesting
for an HPS-less setup.

**int4 payload packing.** Halves weight and activation bytes. Gated on a
software accuracy experiment first.

## Done — kept so the trail is legible

The current core, on the DE1-SoC:
- Phase 1: the ISA, reference model, dispatcher and engines, matching the
  model word for word
- Phase 2: the requantizer and layer chaining through the UB
- Phase 3: overlapped tiles (`weight_current`/`weight_next` PEs, 2-slot WT), measured at
  `max(m, N)` cycles per tile
- Quartus bring-up in an OrbStack VM; the DSP-width and requantizer-timing
  fixes
- FPGA-only self-test, PASS on the board, including the tile rate
- The GHRD integration on the rev H board; the full test suite passing from
  the ARM
- MNIST end to end on the ARM (109.5 µs/image) and the HEX-display drawing
  demo, with a 1.5625 Mbaud console link
- One core: the instruction-stream core moved into `rtl/core/` on the TPUv1
  datapath files, cycle-exact; unit benches for every datapath module;
  re-validated on the board
- The pico2-ice and the first core retired (tag `pico2-ice-final`)

The first core, on the pico2-ice (at the tag; details in
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
