# Datapath visualizer

An interactive 4×4 systolic array: edit W, A and bias, step the clock, and
watch the diagonal wavefront cross the array.

**Live page:** https://claude.ai/artifact/Sr4fZ6oUw15Ee8fXSCq5dC

## How it is put together

Three pieces, deliberately decoupled so each can be checked on its own.

```
rtl/*.sv ──> trace_tb.cpp ──> .vcd ──> vcd_to_trace.py ──> .json
                                                             │
                                          check_model.mjs ───┤ compares
                                                             │
                              viewer.html ──> model.mjs ─────┘
```

| File | Role |
|---|---|
| `trace_tb.cpp` | Verilator `--trace` on `tpu_core`, drives one `RUN_TILE` over the real byte protocol, dumps every internal signal |
| `vcd_to_trace.py` | VCD → per-cycle JSON timeline (~120 signals, sampled on the rising edge) |
| `model.mjs` | Cycle-accurate JavaScript port of the datapath |
| `check_model.mjs` | Proves `model.mjs` matches the RTL, register by register, cycle by cycle |
| `viewer.html` | The page |

## Why there is a JavaScript model at all

The viewer computes traces for matrices you type in, so the simulator has to
run in the browser. The honest alternative was compiling Verilator's output to
WASM through emscripten — a ~1GB toolchain for this one page.

So `model.mjs` is a port, and a port can drift. Two things keep it honest:

- **The control schedule was measured, not invented.** `tpu_sequencer.sv`'s FSM
  is counter-driven, so the cycle sequence depends only on the array shape,
  never on the data. It was read off an RTL trace and encoded directly.
- **`make viz-check` compares the two.** Random matrices go through both the
  Verilator model and `model.mjs`; every PE's weight, activation and partial
  sum, plus the accumulator, bias and ReLU stages, must agree on every cycle.

```bash
make viz-check                 # 40 random cases at 4x4/M_TILE=4, ~4s
make viz-check-all             # every shape the viewer offers
make viz-check VIZ_ROWS=8 VIZ_COLS=8 VIZ_MTILE=4 VIZ_CHECK_N=100
```

`viz-check-all` sweeps `2x2/2  2x4/2  4x2/3  4x4/2  4x4/4  8x8/4`, rebuilding
the RTL harness for each. **4x2/M_TILE=3 is the one that matters most** — all
three axes differ, so a row/column mixup cannot pass by coincidence
(`rtl/CLAUDE.md`).

**Run this after any datapath change.** The animation is only worth trusting
for as long as it passes.

## Regenerating a reference trace

```bash
make sim-trace
./sim/verilator/trace/trace_tb \
    --w 1,2,3,4,5,6,7,8,1,0,0,1,2,2,2,2 \
    --a 1,1,1,1,2,0,0,2,0,1,1,0,3,3,3,3 \
    --bias 10,20,30,40 -o /tmp/t.vcd
python3 viz/vcd_to_trace.py /tmp/t.vcd -o /tmp/t.json
```

`trace_tb` prints the device's own result as JSON, so a trace can be checked
against a reference before anything renders it.

Opening the VCD in gtkwave works too — the visualizer is a reading of it, not
a replacement for it.

## Shapes

The viewer offers six, picked from a dropdown; the SVG derives its cell size
and viewBox from the shape, shrinking cells as the array grows so an 8×8 still
fits one screen with legible numbers. 4×4/M_TILE=4 is the default: big enough
for a real diagonal wavefront (a 2×2 barely has one), small enough to read
every value.

`model.mjs`'s control schedule is a function of `ARRAY_ROWS` and `M_TILE`,
which is why this generalizes at all — and `make viz-check-all` is what proves
the generalization rather than assuming it. Adding a shape means adding an
`<option>` and an entry in `VIZ_SHAPES`.

## No RTL changes

Nothing here touches `rtl/`. A VCD already records strictly more than any
number of `$display` calls would, so the synthesizable source stays clean and
the visualizer cannot perturb what it is measuring.
