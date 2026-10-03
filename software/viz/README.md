# Cycle-by-cycle visualizer

Runs a workload on the instruction-stream core and, with `--visualize-internals`,
writes one self-contained HTML page that steps through every clock cycle of it.
The page shows the host bus, the instruction and data FIFOs, the dispatcher and the
four engine queues (with each `WAIT`'s snapshot), the engines' states, and three
memories: WMEM, the UB and ACC, each with a window that follows the activity. It
also shows the tile buffer's two slots, every PE's activation, partial sum, weight
and shadow weight, the column de-skew FIFOs, the activation unit's stages and the
results. A timeline of the whole run sits above, and the events of the current
cycle sit below.

```sh
make viz                                   # 120 → 36 → 4 MLP at N = 8, m = 8
make viz N=4 WORKLOAD=matmul VIZ_ARGS='--m 4 --k 16 --cols 8'
make viz WORKLOAD=mnist VIZ_ARGS='--images 8 -o mnist.html'
make viz VIZ_ARGS='--batches 2 --trace-load'
```

`make viz` builds `sim/verilator/trace_n<N>/tb_isa` (`make viz-sim`: `tb_isa`
with `--trace -DTB_TRACE`) and runs `visualize.py`. Without `--visualize-internals`,
`visualize.py` only runs the workload and checks it against the reference model.

## Where the numbers come from

Every value on the page is a signal from a **Verilator simulation** of `tpu_top`,
the RTL the DE1-SoC bitstream is built from. `tb_isa` samples a VCD once per
cycle, just before the rising edge. Each step therefore shows the registers as
they stand and the inputs that edge takes, so a PE's Σ is the multiply-accumulate
it performs at that edge. `tpu/trace.py` keeps the ~100 signals the page draws, and
`tpu/viz.py` writes the page from `tpu/viz_template.html`. The page then checks
that every partial sum a PE takes from above equals what the PE above computed the
cycle before. Separately, `tpu/viz.py` compares the output words with the reference
model (`tpu/isa_model.py`).

On the board there's no per-cycle state to read: the core exposes STATUS and four
perf counters. With `--link serial:<port>` the workload runs on the **hardware**
for its outputs and `PERF_CYCLES`, then replays the same programs on the traced
model for the picture. The page says which numbers came from which, and whether
the board's output words equal the simulation's.

```sh
python3 software/viz/visualize.py mnist --link serial:/dev/tty.usbserial-XXXX --visualize-internals
```

## Workloads

| Name | What |
|---|---|
| `mlp` | the walkthrough's 120 → 36 → 4 MLP with seeded random weights; `--m`, `--batches` |
| `matmul` | one `MATMUL` + identity `ACTIVATE` to the host; `--m`, `--k`, `--cols` |
| `mnist` | the committed 144 → 64 → 10 model on test images; `--images`, `--first` |

A new workload is a `build(n)` that returns a `tpu.viz.Workload`: its phases
(program and data each, run to `SIGNAL`, and whether each is traced) and the
labels the page uses for WMEM tiles, UB and ACC regions and the output rows.
`mlp_workload()` derives all of that from a compiled MLP. The weight load is
untraced by default (`--trace-load` includes it). The page still shows WMEM's
contents. Traces stop at `--max-cycles` (20,000), and an 8 × 8 page is
about 1 MB per 1,000 cycles.
