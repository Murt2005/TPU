# Performance

Where the time and the LUTs actually go. Every number here was measured on
this repo's hardware and toolchain — nothing is estimated unless it says so.

## 0. The DE1-SoC

The TPU core ([`architecture.md`](architecture.md)) on the DE1-SoC, 8×8
array at 50 MHz, driven by the board's own ARM. All numbers were measured on
the board on 2026-10-01, on the core before it moved from `rtl/isa/` into
`rtl/core/`. The moved core is cycle-identical. Its rerun measured 113.3 and
80.4 µs, with the ARM-only preprocessing slower by the same ~4%, so the
difference is ARM-side run-to-run variance.

| | m = 1 (one image per run) | m = 8 (batches of 8) |
|---|---|---|
| MNIST accuracy, 10,000 test images | 97.50% | 97.50% |
| equal to the reference model | 10,000 / 10,000 | 10,000 / 10,000 |
| TPU path per image (pack, push over the bridge, compute, read back, argmax) | 60.6 µs | 28.7 µs |
| ARM preprocessing per image (28×28 → 12×12 → int8) | 48.9 µs | 48.9 µs |
| **end to end per image, from raw pixels** | **109.5 µs** (9,132/s) | **77.6 µs** (12,880/s) |

**Against the pico2-ice's best (63.8 ms/image), that's about 580× (one image)
and 820× (batched).** Both numbers start from raw pixels, but the
pico2-ice's host was a Mac across USB and SPI, and here the host is on the
board. Much of the gain is removing that link, not the TPU alone.

Where the 109.5 µs goes:
- **Preprocessing:** about half, plain float math on the ARM.
- **The lightweight bridge:** at m = 1 the TPU path takes twice what the
  same register traffic costs in Verilator, where a register access is one
  cycle (29.4 µs). The difference is the bridge's per-access latency.
- **Compute:** a fraction of that. Each tile takes `max(m, N)` cycles.

**Per-tile rate** (self-test on the board, and Verilator; cycle-exact):
8 extra tiles cost 64, 64 and 152 cycles at m = 1, 8 and 19. That's exactly
`max(m, 8)` per tile, with no steady-state weight stalls (WSTALL stays at
the 9 cycles of the first tile's fetch).

**Per tile, against the legacy core:** a legacy 8×8/M_TILE=8 pass takes 49
cycles (traced, [`utilization.md`](utilization.md) §1), against 8 here, so
**6.1× fewer cycles per tile**. In throughput, that's 512 MACs per 8 cycles
at 50 MHz = **3.2 GMAC/s** steady state, against about 53 MMAC/s for the
pico2-ice's best build (64 MACs per 29-cycle pass at 24 MHz). That ratio
combines about 6× from overlap, 4× from the larger array and 2× from the
clock.

**Drawing demo**, with the round trip from the Mac over the HPS console:
73.5 ms at 115,200 baud, 7.5 ms at 1,562,500. Both take 117 µs on the
board; the rest is the 785-byte image crossing the serial link.

### Weights from DDR3

Measured on the board on 2026-10-02 with `boards/de1soc/sw/ddr-bench.py`,
from the on-chip counters only: a `MATMUL` takes `max(m, N)` cycles a tile,
plus every cycle the array waits for weights (`PERF_MM_WSTALL`). WT and MM
are held until the whole program is queued, so the console link never enters.

| Layer | Tiles | WSTALL from WMEM | WSTALL from DDR3 (idle / ARM streaming 64 MB) | Weights from DDR3 |
|---|---|---|---|---|
| MNIST layer 1 (144 × 64) | 144 | 11 | 22 / 22–24 | 392 MB/s, 98.1% of the array's rate |
| WMEM's capacity (1024 tiles) | 1,024 | 11 | 22 / 24–32 | 399 MB/s, 99.7% |
| Qwen q/k/v fused (896 × 1152) | 16,128 | — (doesn't fit) | 22 / 31 | 399.9 MB/s, 99.98% |
| Qwen down (4864 × 896) | 68,096 | — | 22 / 22–29 | 400.0 MB/s, 99.99–100% |

- **DDR3 costs a fixed ~11 cycles a `MATMUL`, never per tile.** The stall is
  the first tile's DDR3 latency; after that the stream keeps the array fed.
  A second `MATMUL` behind the first is prefetched and adds 0–6 cycles.
- **400 MB/s is the array's appetite, not DDR3's limit.** At 8×8 and 50 MHz
  the array takes one 8-byte weight row a cycle at m = 1. The port carries
  800 MB/s (§ the probe in [`de1soc.md`](de1soc.md) §7), so it has 2×
  headroom, also with the ARM loading memory.
- **For MNIST** the weights fit WMEM, and DDR3 would cost 2 × 11 cycles a
  run: 0.44 µs on a 109.5 µs image.
- **For an LLM** this is the spec's decode bound, now measured: at m = 1
  every weight byte is used once per token, so Qwen2.5-0.5B's 494 MB take
  494 / 400 = **1.24 s of array time per token** (0.8 tokens/s), before
  any host work or handoffs. 16×16 or 100 MHz doubles the appetite to
  800 MB/s, exactly the port's measured peak.

### Qwen2.5-0.5B: the TPU against a Mac

Generating one token at a time, one stream, greedy, after a 5-token prompt;
measured 2026-10-02. On the board, `qwen-run --core mmio`
([`../software/qwen/`](../software/qwen/README.md)). On the Mac (an M2 Pro,
16 GB), the same C runtime with its int8 reference matmul, and PyTorch 2.14
with `transformers` 5.18.

| Where | Arithmetic | Time per token | Tokens/s | vs the TPU |
|---|---|---|---|---|
| **TPU on the DE1-SoC** (8×8, 50 MHz) | int8, weights streamed from DDR3 | 1.37 s | **0.73** | 1× |
| Mac, `qwen-run --core ref` (1 CPU core, plain C loops) | the same int8 arithmetic | 0.052 s | 19.3 | 26× |
| Mac, PyTorch on the CPU (6 threads) | float32 | 0.047 s | 21.5 | 29× |
| Mac, PyTorch on the GPU (MPS) | float32 | 0.019 s | 52.7 | 72× |

Generating one token at a time reads every weight once a token (494 MB at
int8), so speed is set by how fast weights reach the multipliers:
- **The TPU:** the 8×8 array takes one 8-byte weight row a cycle at
  50 MHz, which is 400 MB/s. Its peak is 64 multiply-adds a cycle,
  3.2 G/s. The DDR3 port could deliver 800 MB/s; the array is the limit.
- **The Mac:** its memory system delivers hundreds of GB/s. The
  single-threaded C loop moves about 9.5 GB/s of int8 weights (about 9.5 G
  multiply-adds/s), and the GPU about 100 GB/s of float32 weights (2 GB a
  token).

The design does what it set out to do: the array never waits for weights,
and every result is exact. But a 2013-era Cyclone V with the smallest array
its DSP blocks allow, at a conservative clock, is far from a current laptop:
- **Bigger or faster:** 16×16 or 100 MHz each double throughput, to about
  1.5 tokens/s. Both together reach about 3, the most the DDR3 port allows.
- **Prompts go faster:** 16 prompt tokens share one pass over the weights,
  so about 6 tokens/s.
- **Power** is where an FPGA could compare better, per watt. It hasn't been
  measured on either side.

Resources and timing are in [`de1soc.md`](de1soc.md) §1.

## History: the pico2-ice and the first core

> Sections 1–4 below are the first core's measurements, on the retired
> pico2-ice (iCE40UP5K + RP2350). Its RTL, firmware, docs and tests are at
> the git tag `pico2-ice-final`; file paths and docs named here refer to that
> tag (`git show pico2-ice-final:<path>`). They're kept because they're
> measured, and because they're what the current core was designed against.

## 1. The pico2-ice: where it ended

MNIST end-to-end, 144→64→10 int8 model, one image, SPI link with firmware
offload:

| Shape | LCs | DSP | fMax | Core clk | ms/image |
|---|---|---|---|---|---|
| 2×2 / M_TILE=2 | 2,138 (40%) | 4/8 | 30.66 MHz | 12 MHz | 315.6 *(UART, 1 Mbaud)* |
| 2×4 / M_TILE=2 | 3,538 (67%) | 8/8 | 31.61 MHz | 12 MHz | 239.65 *(UART, 1 Mbaud)* |
| 2×4 / M_TILE=2 | 3,538 (67%) | 8/8 | 31.61 MHz | 24 MHz | **64.1** *(SPI + offload)* |
| 4×4 / M_TILE=2 | 4,397 (83%) | 8/8 | 28.63 MHz | 24 MHz | **63.8** |
| 4×4 / M_TILE=4 | 4,935 (93%) | 8/8 | 27.62 MHz | 24 MHz | 80.3 *(single image)* |

All shapes: `make hw-test` 14/14, MNIST 19/20 on the sampled set, results
bit-identical to the golden model.

**4×4/M_TILE=4 is slower on a single image and that is expected** — three of
four streamed activation rows are zero padding. Its batched cost is better
(30.6 ms per 2 rows vs. 44.6 at M_TILE=2, from the halved weight
re-streaming), projecting to ~17 ms/image once `software/mnist/infer.py` batches
images. It is the right shape *after* batching lands, not before.

### Budget breakdown

The remaining time is **wire-bound, not compute-bound**. At 4×4 the array
itself is ~3% of the budget:

- ~30 ms/image of SPI tile traffic at the `CLK/6`-capped 4 MHz write clock
  (~14 KB of padded tiles for layer 1 — W crosses once, A once per N-block)
- ~10 KB/image of CDC bulk transfer
- ~2 ms of actual RTL execution

The per-USB-transaction tax that dominated earlier is gone (see §3's M3).

## 2. Resource budget on the UP5K

The chip: 5,280 LCs, 8 `SB_MAC16` DSP blocks, 30 EBR blocks, 8 global buffers.

Two structural facts shape every decision here:

**All 8 global buffers are claimed** even by the 2×2 design. Adding
high-fanout control signals doesn't fail the build — nextpnr silently falls
back to slower, more congested regular routing.

**A PE costs 251 LUT4 as fabric logic, 36 with `-dsp`** (measured by
synthesizing `pe.sv` standalone both ways). That ~7× is the single biggest
lever in the whole design, from one synthesis flag with no RTL change:

```bash
yosys -p "read_verilog -sv rtl/datapath/pe.sv; synth_ice40 -top pe -json /dev/null" \
    2>&1 | grep -E "SB_LUT4|SB_DFF|SB_MAC16"
yosys -p "read_verilog -sv rtl/datapath/pe.sv; synth_ice40 -top pe -dsp -json /dev/null" \
    2>&1 | grep -E "SB_LUT4|SB_DFF|SB_MAC16"
```

Reproduce a full-design utilisation report:

```bash
cd boards/pico2-ice/fpga/ && make clean && make util
```

### Breaking the DSP ceiling

The array size was capped twice, and the cap was wrong both times:

1. *"~20 PEs by mixing DSP and LUT PEs"* — **not reachable.** yosys `-dsp`
   maps *every* `pe` multiply to `SB_MAC16` with no per-instance opt-out.
2. *"8 PEs, all DSP-backed"* — **retired by `boards/pico2-ice/top/pe_pair.sv`**, which
   hand-instantiates `SB_MAC16` in dual-8×8 signed mode (`MODE_8x8=1`,
   `A_SIGNED=B_SIGNED=1`, `{TOP,BOT}ADDSUB_LOWERINPUT=1`, `UPPERINPUT=1`,
   `OUTPUT_SELECT=1`). Two independent 8×8 multiplier + 16-bit ADDSUB +
   output-register halves per block means **one DSP carries two complete PE
   MACs** — 16 PEs on 8 blocks.

`pe_pair`'s port list is two `pe.sv` interfaces, so `mmu.sv` drops one pair
onto the same net arrays as two row-adjacent PEs. The top half's registered
psum leaves on `psum_out[r]` and re-enters as `psum_in[r+1]` → the D input,
which *is* the inter-PE pipeline register. Bit-exactness comes from input
gating (act→0 when invalid so the adder passes C/D through; C/D→0 in the
act-valid/psum-invalid case; both→0 during `loading_phase` for the
synchronous clear), verified cycle-accurate in `tests/sv/pe_pair_tb.sv` against
yosys's own `SB_MAC16` model.

Of the 8-PE shapes, **2×4 beats 4×2** for this workload: total activation
bytes scale as `K·N·M_TILE/NUM_COLS`, so wider wins. Weight bytes are `K·N`,
shape-invariant.

### Fitting the last 10%

`4×4/M_TILE=4` first came out at 5,484 LCs (103%) — and the overflow was
never the array. Standalone synthesis attributed ~1,531 LUT4 / ~1,314 DFF to
the *sequencer*, ~1,050 FFs of it matrix bytes staged **twice** (RX payload
buffer + decoded `reg_weights`/`reg_act` copies; `result_rows` +
`tx_payload`). Two fixes:

- **`ABC_FLAGS := -abc9 -dff`** — ABC's register-aware pass sweeps the
  duplication at netlist level: **5,484 → 5,072 LCs**. (`-abc2`/`-relut`
  variants: ±5 LCs. `-abc9` alone: 0.) 5,072 packs at 96% but does *not*
  place — seeds 2/3/7 and `--placer sa` all fail legalization.
- **BRAM-backed `unified_buffer`** — rewritten as two per-bank 1W1R memories
  with flat row words and `(* ram_style = "block" *)`. The roles guarantee
  one writer and one reader per bank, and port latencies are unchanged (the
  bank's sync read *is* the old stage-2 register). Uses 2 of the 29 idle
  `SB_RAM40_4K`: **5,072 → 4,935 LCs (93%)**, places and routes at 27.62 MHz.

Both benefit every build, not just 4×4.

## 3. How it got 125× faster

About a week of measurement (first bring-up 07-06, last step 07-13), in the
order the levers were pulled. Each step's
numbers are what was measured at the time.

| Step | Change | ms/image | Cumulative |
|---|---|---|---|
| baseline | 2×2, UART 115200, one command per operation | 8,001 | 1× |
| — | *(retrospective: 7,727 after early fixes)* | 7,727 | |
| **Tier 2** | `CMD_RUN_TILE` — fold `LOAD_WEIGHTS`+`LOAD_ACT`+`RUN` into one frame | 3,986 | 2.0× |
| **Tier 3** | `CMD_STREAM_RUN` — a whole K-run per round trip | 2,454 | 3.3× |
| **Tier 1** | UART at 1,000,000 baud (exact ÷12 of 12 MHz) + `-dsp` synthesis | 315.6 | 25× |
| **M1** | Array 2×2 → 2×4 (8 PEs, all DSP-backed) | 239.65 | 33× |
| **M2** | `spi_slave.sv` replaces the UART; core clock 12 → 24 MHz | 88 | 91× |
| **M3** | `FW_MATMUL` — whole tiling loop moved onto the RP2350 | 64.1 | 125× |
| **M4** | 4×4 via `pe_pair.sv` (16 PEs on 8 DSPs) | 63.8 | 125× |

Notes on the shape of that curve:

**Tier 1 was decisively the biggest single step** (7.8×). Post-Tier-3
analysis showed wire time at 74% of the budget and irreducible at 115200 —
the batching work had made the transport the whole problem, which is what
made the baud bump obvious.

**M4 is flat, by design.** Weight wire bytes are shape-invariant and
activation bytes scale as `1/NUM_COLS` (unchanged from 2×4), so the halved
K-tile count only trims per-frame overhead that the ~41 ms USB/Python
remainder dwarfs. The payoff is 2× compute density and the headroom for
`M_TILE` image batching — not latency.

**The M2+M3 projection was optimistic** (15–35 ms predicted, 64 delivered).
The SPI write clock capped at `CLK/6` = 4 MHz was the miss. The USB
per-transaction tax M3 targeted *is* genuinely gone — the `--no-offload`
A/B on identical firmware measures 96.6 ms host-tiled vs. 64.1 offloaded.

**Two firmware bugs surfaced only under speed**, both described in
`docs/pico2-ice.md` §7 (at the tag): silent byte drops past the 32-deep UART TX
FIFO (triggered by any frame > 32 bytes, i.e. by the batching work itself),
and a TinyUSB ISR race that was rare at 115200 and fatal at 1 Mbaud. Faster
transports don't just move numbers; they change which bugs are reachable.

### Retracted conclusions

Kept deliberately, because the reasoning trail matters:

- *"The practical ceiling is ~20 PEs by mixing DSP and LUT PEs."* Wrong —
  no per-instance opt-out in yosys `-dsp`.
- *"The practical ceiling is 8 PEs."* Wrong — `pe_pair.sv` doubled it.
- *"31 tiles per frame is plenty for MNIST."* Wrong — layer 1's K=144 needs
  72 K-tiles per output block, which is what forced `STREAM_RUN`'s
  cross-frame flags byte.
- *"4×4/M_TILE=4 does not fit."* True at the time; fixed by `ABC_FLAGS` +
  BRAM UB.

## 4. Hardware vs. a laptop

Same model, same sampled images, three execution paths
(`python3 software/mnist/infer.py --port ... --compare --test-n 20`):

| Path | Accuracy | Latency |
|---|---|---|
| pico2-ice hardware | 19/20 (95.00%) | ~64 ms/image |
| Mac (M2 Pro), one image at a time | 19/20 (95.00%) | 0.09 ms/image |
| Mac (M2 Pro), batched/vectorized | 19/20 (95.00%) | 0.01 ms/image |

**Accuracy is identical across all three.** Same int8/int16 fixed-point math,
same images — this was never a numerics question. The gap is purely about
where the arithmetic physically happens, and it is not the array being slow.

| | pico2-ice (iCE40UP5K + RP2350B) | Apple M2 Pro (MBP 14", 2023) |
|---|---|---|
| Role here | Runs the TPU datapath (`rtl/` + `boards/pico2-ice/top/` → `boards/pico2-ice/fpga/tpu_top.bin`) + bridge firmware | Runs the host driver, and here a numpy re-implementation of the same math |
| Process | 40nm (both chips) | TSMC N5P (5nm-class) |
| Compute used | 16 PEs carved from 5,280 LUT4s; the RP2350's cores only bridge | 1 CPU core of 12; GPU and Neural Engine idle |
| Scale | ~5,280 LUTs | ~40 billion transistors |
| Power | UP5K ~75 µW static; RP2350 ~450–475 mW bridging — sub-watt board | 20–30 W SoC under sustained CPU load; 67–96 W adapter for the laptop |
| Size | ~51 × 21 mm | 31.3 × 22.1 × 1.55 cm, ~1.6 kg |
| Price | ~$30–40 | $1,999+ |

**Caveat:** this compares a bare FPGA+MCU dev board against an entire laptop
— display, battery, SSD, 11 unused cores, GPU, Neural Engine. Different
categories of thing, not an SoC-vs-SoC teardown. The point isn't that either
"wins": it's that a few thousand LUTs at sub-watt power reproduce a real (if
tiny) TPU datapath's *exact numerical behaviour*, at a latency cost a
general-purpose CPU makes irrelevant by being enormously overprovisioned for
a 144→64→10 MLP.

Sources: [iCE40 UltraPlus datasheet](https://www.latticesemi.com/-/media/LatticeSemi/Documents/DataSheets/iCE/iCE40-UltraPlus-Family-Data-Sheet.ashx) ·
[ice40_power](https://github.com/tinyvision-ai-inc/ice40_power) ·
[RP2350 datasheet](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf) ·
[M2 Pro specs](https://lowendmac.com/1234/apple-silicon-m2-pro-chip-specs/) ·
[MacBook Pro 14" specs](https://support.apple.com/en-us/111340)

## 5. What's left

See [`backlog.md`](backlog.md).

- **On the DE1-SoC:** the next levers are ARM preprocessing (about half of
  the 109.5 µs) and bridge register traffic. The array is already fed every
  cycle at m ≥ N.
- **On the pico2-ice (retired):** the structural levers this section used to
  list were resident weights and shadow-bank overlap.
  [`utilization.md`](utilization.md) has the traced numbers behind them,
  showing the array fed new rows only 9–16% of each pass. Both were built
  into the instruction-stream core instead.
