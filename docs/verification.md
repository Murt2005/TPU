# Verification

Four independent tiers. Each catches a class of bug the others structurally
cannot. A change is trusted when the tiers it can reach are green.

## Tier 1 — SystemVerilog testbenches (`make test`)

23 testbenches under `tests/`, run through Icarus Verilog, printing a
pass/fail summary. Fast; the inner development loop.

> `make test` currently runs **22** of them: `run_tests.sh`'s `ALL_TESTS`
> list is missing `hps_bridge`, which passes when run directly with
> `make test-hps_bridge`.

```bash
make test                 # the run_tests.sh list (see note above)
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

Registering a new bench takes **four** edits: in the `Makefile`, a
`DEPS_<name>` line, an entry in `TESTS`, and a `build-<name>` +
`$(SIM_DIR)/<name>.vvp` rule pair; then the same name in `run_tests.sh`'s
`ALL_TESTS`. The script gets dependencies from the Makefile but keeps its own
list of names, so skipping the last step silently drops the bench from
`make test` — which is how `hps_bridge` fell out.

## Tier 2 — Verilator lint (`make lint`)

`-Wall` across four configurations, because a config-specific latch or
width bug hides in the config you didn't build:

- default (UART PHY)
- `USE_SPI=1`
- `USE_SPI=1 USE_MAC16_PAIR=1 ARRAY_ROWS=4 NUM_COLS=4 M_TILE=4`
- `tpu_top_hps` (the DE1-SoC top)

Waivers live in `verilator.vlt`, including a whole-file waiver for
`sim/sb_mac16_sim.v` — that's yosys's own primitive library, extracted at
build time, not ours to lint.

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
`tests/hw_regression.py --link sim --port <that binary>` runs the hardware
suite against it instead of silicon. That is not a substitute for Tier 4 — it
validates the RTL, protocol and host driver, not the netlist — but it is the
only way to run the host-side programs (`hw_regression.py`, `llm/infer.py`)
at shapes and widths no bitstream has been built for.

## Tier 4 — Real hardware (`make hw-test`)

`tests/hw_regression.py` against a flashed board. **The only tier that
validates synthesis** — netlist transforms like `-dsp`, `-abc9 -dff`, and
the hand-instantiated `SB_MAC16` primitives are all trusted on the basis of
this suite passing bit-exactly, not on inspection.

```bash
make hw-test PORT=/dev/cu.usbmodemXXXX \
     ARRAY_ROWS=4 NUM_COLS=4 M_TILE=4 LINK=spi
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
python3 mnist/infer.py --port /dev/cu.usbmodemXXXX --test-n 20
```

Not a regression gate, but the check that the whole stack — training,
quantization, tiling, wire protocol, silicon — produces the right answer.
Expected: 19/20 on the sampled set, matching the local numpy model exactly.

## Before trusting a change

| Changed | Run |
|---|---|
| One RTL module | `make test-<name>`, then `make test` |
| Anything in the datapath or sequencer | `make test` + `make lint` + `make verilate-test` |
| Synthesis flags, primitives, or memory inference | all of the above **+ `make hw-test`** |
| Wire protocol | all of the above + `mnist/infer.py` |
| Firmware | `make hw-test` (there is no firmware sim tier) |

This project deliberately uses **no hosted CI** — the gates are local `make`
targets. See [`CONTRIBUTING.md`](../CONTRIBUTING.md).
