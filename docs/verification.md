# Verification

Four independent tiers. Each catches a class of bug the others structurally
cannot. A change is trusted when the tiers it can reach are green.

There are two cores. Tiers 1–4 below are the legacy byte-protocol core
(pico2-ice). The instruction-stream core (DE1-SoC, [`isa.md`](isa.md)) has
its own reference model and its own sim and hardware tiers, described in
[the instruction-stream section](#the-instruction-stream-core).

## Tier 1 — SystemVerilog testbenches (`make test`)

23 testbenches under `tests/`, run through Icarus Verilog, printing a
pass/fail summary. Fast; the inner development loop.

```bash
make test                 # all of them
make test-mmu             # one
make build-mmu            # compile only
make wave-mmu             # run + open the VCD in gtkwave
make list                 # every available target
```

Three kinds:

- **Unit** — `fifo`, `pe`, `pe_pair`, `mmu`, `bias`, `activation`,
  `accumulator`, `unified_buffer`, `systolic_data_setup`, `weight_fifo`,
  `uart_rx`, `uart_tx`, `spi_slave`, `hps_bridge`.
- **Pairwise integration** — `mmu_accum`, `accum_bias`, `bias_activation`,
  `weight_fifo_mmu`. Prove two adjacent stages compose.
- **Full-path** — `tpu_core` (datapath minus sequencer/PHY),
  `tpu_sequencer` (protocol → pipeline, via direct `rx_data`/`rx_valid`
  injection), plus `tpu_sequencer_4x2` / `_2x4` / `_4x4` at other shapes.

The shape-variant benches exist because **a shape bug is silent**: 4×2 was
chosen with all three axes distinct (`ARRAY_ROWS=4, NUM_COLS=2, M_TILE=3`)
precisely so a row/column index confusion cannot pass by coincidence. This is
how the `unified_buffer` ROWS/COLS indexing bug — harmless while `ROWS==COLS`
— was caught.

Registering a new bench is one line: a `DEPS_<name>` entry in `mk/sim.mk`
listing the RTL it needs. The test list is built from the `tests/*_tb.sv`
files themselves (`make print-tests`), and `run_tests.sh` reads it from there,
so a bench can't be silently left out — one with no `DEPS_` line stops the
build with an error naming it.

## Tier 2 — Static checks (`make lint`)

`-Wall` across five configurations, because a config-specific latch or
width bug hides in the config you didn't build:

- default (UART PHY)
- `USE_SPI=1`
- `USE_SPI=1 USE_MAC16_PAIR=1 ARRAY_ROWS=4 NUM_COLS=4 M_TILE=4`
- `tpu_top_hps` (the DE1-SoC top)
- `tpu_isa_top` (the instruction-stream core)

Each top is linted with its own board's file set, so the DE1-SoC build is
checked without `pe_pair.sv` or the `SB_MAC16` model, exactly as Quartus
sees it. Waivers live in `verilator.vlt`, including a whole-file waiver for
`sim/sb_mac16_sim.v` — that's yosys's own primitive library, extracted at
build time, not ours to lint.

`make lint` first runs `make check-protocol` (`tests/check_protocol.py`):
the opcodes, flag bits and status bytes exist in four languages —
`rtl/core/tpu_pkg.sv`, `host/tpu/protocol.py`,
`tests/verilator/tb_tpu_top.cpp` and the firmware's `tpu_tile.c` — and
nothing generates one from another. The check fails on any disagreement,
and if the Python copy is missing anything the RTL package defines.

## Tier 3 — Verilator full-chip simulation (`make verilate-test`)

`tests/verilator/tb_tpu_top.cpp` drives `tpu_top` through its **real host
pins** — a bit-level UART at the hardware's 12 MHz / 1 Mbaud ratio, or real
SPI transactions — across twelve shape/PHY/width combinations:

```
2_2_2_uart  2_4_2_uart  4_2_3_uart  2_4_2_spi
4_4_2_spipair  4_4_4_spipair  8_8_8_uart
2_2_2_uart32  4_4_2_spi32  8_8_4_uart32
2_2_2_direct  8_8_4_direct32
```

A trailing `32` selects `PSUM_WIDTH=32`; no hardware has ever been built with
it, so these shapes (plus the sim link below) are its only coverage.
`8_8_4_uart32` uses `M_TILE=4` because 8×8 at 4 bytes per element would need
a 256-byte result frame, one past the `LEN` cap.

The `direct` shapes verilate `tpu_core` instead of `tpu_top` and inject bytes
straight into the sequencer's `rx_data`/`rx_valid`, skipping the bit-level
PHY. Same protocol, same golden checks, ~50× fewer simulated cycles per
byte — which is what makes transformer-sized workloads tractable, and what
`make sim-bridge` builds.

This is the tier that catches PHY-level framing and protocol bugs without a
board. `8_8_8_uart` (64 PEs, generic-fabric multiply) is a sim-only proof
that the datapath parameterizes past the iCE40's DSP ceiling — it's the
DE1-SoC scale-up shape.

`FIFO_DEPTH` is computed per shape as the next power of 2 ≥
`max(ARRAY_ROWS, M_TILE)`.

### Running the suite without a board

`make sim-bridge` builds the `direct` bench as a transport binary
(`sim/verilator/bridge/tb_tpu_top`; shape set by `SIM_ROWS`/`SIM_COLS`/
`SIM_MTILE`/`SIM_PSUM`, default 8×8/M_TILE=4/PSUM=32), and
`tests/hw/hw_regression.py --link sim --port <that binary>` runs the hardware
suite against it instead of silicon. That is not a substitute for Tier 4 — it
validates the RTL, protocol and host driver, not the netlist — but it is the
only way to run the host-side programs (`hw_regression.py`, `software/llm/infer.py`)
at shapes and widths no bitstream has been built for.

## Tier 4 — Real hardware (`make hw-test`)

`tests/hw/hw_regression.py` against a flashed board. **The only tier that
validates synthesis** — netlist transforms like `-dsp`, `-abc9 -dff`, and
the hand-instantiated `SB_MAC16` primitives are all trusted on the basis of
this suite passing bit-exactly, not on inspection.

```bash
make hw-test PORT=/dev/cu.usbmodemXXXX CONFIG=4x4_spi
```

14 cases: every simulation vector replayed, int8/int16 boundary cases, a
randomized multi-tile stress run, and the `FW_MATMUL` offload A/B (30
randomized shapes, required bit-identical between the offloaded path, the
host-tiled path, and the golden model). The offload A/B needs the SPI
firmware; on a UART build it prints `[SKIP]`, and the closing banner still
reads "ALL 14 … PASSED", so count the `[PASS]` lines if it matters.

**The arguments must match the flashed bitstream**, not the Makefile
defaults. A mismatch shows up as a frame-length failure.

The target calls bare `python3`, which needs `pyserial` and `numpy`. If they
live in a venv, activate it (or put its `bin/` first on `PATH`) before
running `make hw-test`.

Two bugs were found only here and were invisible to every other tier: the
missing power-on reset ([`pico2-ice.md`](pico2-ice.md) §5.5 — simulation
can't catch it, because every testbench pulses reset) and the TinyUSB ISR
race that only fires at 1 Mbaud.

## Tier 4b — End-to-end accuracy

```bash
python3 software/mnist/infer.py --port /dev/cu.usbmodemXXXX --test-n 20
```

Not a regression gate, but the check that the whole stack — training,
quantization, tiling, wire protocol, silicon — produces the right answer.
Expected: 19/20 on the sampled set, matching the local numpy model exactly.

## The instruction-stream core

Its reference is `host/tpu/isa_model.py`, which executes a program in order
with the core's exact arithmetic. Every check below requires the RTL or the
board to match it **word for word**. Each tier sees a different thing:

| Tier | Command | What it proves |
|---|---|---|
| model | `make isa-model-test` | The model matches independent references: `tpu.golden` on random layers, `hw_layer` at 32 bits on MNIST layer 1, the requantizer against host rounding (one tie, at v=10,450), and `isa_waits` on the compiled MNIST program (hazard-free, every `WAIT` needed) |
| RTL, sim | `make isa-test` (model + RTL at N = 8 and N = 4) | The RTL through its real bridge registers (`tests/verilator/tb_isa.cpp`): every decode error; 40 random single layers including split K; MNIST layer 1 and the two-layer program chained through the UB; the requantizer over every int16, the edges and random int32 for three quant tables; 40 random concurrent programs; and the cycle-exact tile rate |
| netlist, no host | `make isa-selftest-sim`, then the board | `boards/de1soc/fpga/selftest`: the same tests as a ROM register transcript replayed into the bridge **on the FPGA**, plus on-chip tile-rate checks. The replay is cycle-exact, so its perf counters must equal Verilator's |
| netlist, from the ARM | `tests/isa/test_isa_rtl.py serial:<console port>` | The whole RTL suite against the board, through `isa_mmio` over the HPS console. Over this link the cycle-rate check is limited to beats and WSTALL; the rate itself is covered by the self-test |
| application | `mnist_tpu bench` on the board | 10,000 MNIST images end to end, compared with the reference model's prediction, the host numpy path's prediction, and the host's quantized input (preprocessing) |

Notes:
- **Concurrency.** The engines run concurrently, so ordering is the program's
  job. `host/tpu/isa_waits.py` models what each engine reads and writes;
  `check_waits` finds hazards no `WAIT` orders, and `insert_waits` adds the
  minimal `WAIT`s. The random-program test inserts `WAIT`s into legal random
  programs and requires the in-order result. Run without their `WAIT`s, 39 of
  40 programs diverge, which shows the overlap is real and the `WAIT`s carry
  the weight. `ISA_RANDOM_PROGS` raises the count (400 per N has been run).
- **PE invariants.** Simulation-only `$fatal` checks in `isa_pe.sv` assert
  that a weight is never overwritten before its flip and never flipped
  without one.
- **Tile rate.** `T` extra tiles must cost exactly `T · max(m, N)` cycles
  with no extra `PERF_MM_WSTALL`, at m = 1, m = N and m > N. This is checked
  in Verilator, where the clock only advances on register accesses, and on
  chip by the self-test ROM.
- **Self-test sanity.** An injected wrong expected word fails with the right
  mark and count, and an empty ROM fails instead of hanging.
- **MNIST without the board.** `make -C software/mnist/de1soc sim-bench` runs
  the ARM program against Verilator (`-DSIM`). The same C is verified before
  it goes on the card.

**Board results (2026-10-01)**: self-test PASS with every perf capture equal
to Verilator; every functional test in `test_isa_rtl.py` passes; MNIST
10,000/10,000 equal to the reference model, with preprocessing
byte-identical on all 10,000. See [`de1soc.md`](de1soc.md).

## Before trusting a change

| Changed | Run |
|---|---|
| One RTL module | `make test-<name>`, then `make test` |
| Anything in the datapath or sequencer | `make test` + `make lint` + `make verilate-test` |
| Synthesis flags, primitives, or memory inference | all of the above **+ `make hw-test`** |
| Wire protocol | all of the above + `software/mnist/infer.py` |
| The instruction-stream core (`rtl/isa/`, `host/tpu/isa*.py`) | `make isa-test` + `make lint` + `make isa-selftest-sim` |
| Its synthesis, memory inference, or anything timing-related | all of the above + a board build: the self-test **PASS**, then `test_isa_rtl.py serial:<port>` |
| Software on the DE1-SoC's ARM (`software/mnist/de1soc`, `boards/de1soc/sw`) | `make -C software/mnist/de1soc sim-bench`, then `mnist_tpu bench` on the board |
| Firmware | `make hw-test` (there is no firmware sim tier) |

This project deliberately uses **no hosted CI** — the gates are local `make`
targets. See [`CONTRIBUTING.md`](../CONTRIBUTING.md).
