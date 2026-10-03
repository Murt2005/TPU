#!/usr/bin/env python3
"""run a workload on the instruction-stream core, and with --visualize-internals
write a cycle-by-cycle page of the core running it (Verilator; see tpu/viz.py).

  visualize.py mlp --visualize-internals                  # 120 -> 36 -> 4, m = N
  visualize.py matmul --m 4 --k 16 --cols 8 --visualize-internals
  visualize.py mnist --images 8 --visualize-internals
  visualize.py mnist --link serial:/dev/tty.usbserial-X --visualize-internals   # board + sim picture

--link is a tb_isa binary or serial:<port> (default: the traced model for --n,
built by `make viz-sim N=<n>`). the load program (weights into WMEM) runs untraced
unless --trace-load; the page still shows WMEM's contents
"""
import argparse
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
from tpu.isa_compile import compile_mlp                                      # noqa: E402
from tpu.viz import Phase, Workload, run_workload, viz_sim_path              # noqa: E402


def mlp_workload(name, title, layers, xs, n, lede="", trace_load=False, facts=None):
    """a compiled MLP: one load phase, then one infer phase per batch in xs"""
    m = xs[0].shape[0]
    cm = compile_mlp(layers, m, n)
    prog, data = cm.load_program()
    phases = [Phase("load: weights → WMEM, bias and quant tables", prog, data, traced=trace_load)]
    for b, x in enumerate(xs):
        p, d = cm.infer_program(x)
        phases.append(Phase(f"infer: batch {b}" if len(xs) > 1 else "infer", p, d))
    tiles, first = [], 0
    for li, p in enumerate(cm.plan):
        tiles.append(dict(first=first, kt=p["kt"], nb=p["nb"], name=f"L{li + 1}"))
        first += p["kt"] * p["nb"]
    k_in = layers[0]["w"].shape[0]
    ub = [dict(start=cm.plan[0]["ub_in"], m=m, chunks=cm.plan[0]["kt"], name="x", kind="in", n_out=k_in,
               note=f"input, {m} × {k_in}")]
    for li, p in enumerate(cm.plan[:-1]):
        ub.append(dict(start=p["ub_out"], m=m, chunks=p["nb"], name=f"h{li + 1}", kind="out",
                       n_out=p["n_out"], note=f"layer {li + 1}'s output, {m} × {p['n_out']}"))
    acc = [dict(start=p["acc"], m=m, nb=p["nb"], name=f"L{li + 1}", last=p["last"])
           for li, p in enumerate(cm.plan)]
    last = cm.plan[-1]
    labels = dict(tiles=tiles, ub=ub, acc=acc,
                  outputs=dict(name="y", m=m, nb=last["nb"], n_out=last["n_out"], batches=len(xs)),
                  wmem=cm.wmem.astype(int).tolist())
    shape = " → ".join(str(s) for s in [k_in] + [l["w"].shape[1] for l in layers])
    f = {"network": f"{shape}, {'ReLU' if layers[0].get('relu', True) else 'identity'} between layers, "
                    f"int8 weights, int32 out", "batch": f"m = {m} rows × {len(xs)} batch(es)"}
    f.update(facts or {})
    return Workload(name=name, title=title, phases=phases, lede=lede, labels=labels, facts=f)


def random_layers(rng, sizes):
    layers = []
    for i, (k, c) in enumerate(zip(sizes, sizes[1:])):
        last = i == len(sizes) - 2
        layers.append(dict(w=rng.integers(-40, 41, (k, c)), b=rng.integers(-2000, 2001, c),
                           relu=True, scale=None if last else 1 / 600))
    return layers


def build_mlp(a):
    def build(n):
        rng = np.random.default_rng(a.seed)
        layers = random_layers(rng, [120, 36, 4])
        m = a.m or n
        xs = [rng.integers(-100, 101, (m, 120)) for _ in range(a.batches)]
        return mlp_workload("mlp", "MLP 120 → 36 → 4", layers, xs, n, trace_load=a.trace_load,
                            lede=f"The walkthrough's two-layer MLP with seeded random int8 weights: layer 1 "
                                 f"requantizes into the UB, layer 2 reads it there and returns int32 rows. "
                                 f"{a.batches} batch(es) of {m} inputs.")
    return build


def build_matmul(a):
    def build(n):
        rng = np.random.default_rng(a.seed)
        m = a.m or n
        layers = [dict(w=rng.integers(-60, 61, (a.k, a.cols)), b=rng.integers(-500, 501, a.cols),
                       relu=False, scale=None)]
        xs = [rng.integers(-60, 61, (m, a.k)) for _ in range(a.batches)]
        return mlp_workload("matmul", f"Matmul {m} × {a.k} × {a.cols}", layers, xs, n, trace_load=a.trace_load,
                            lede=f"One MATMUL: x ({m} × {a.k}) times W ({a.k} × {a.cols}) plus bias, "
                                 f"returned to the host as int32, with no activation function.")
    return build


def build_mnist(a):
    sys.path.insert(0, str(HERE.parent / "mnist"))
    import train_mnist as T
    from mnist_model import load_model, quantize

    def build(n):
        mdl = load_model()
        hs = float(mdl["hidden_scale"])
        layers = [dict(w=mdl["w1"], b=mdl["b1"], relu=True, scale=1 / hs),
                  dict(w=mdl["w2"], b=mdl["b2"], relu=True, scale=None)]
        _, _, xi, yi = T.load_mnist()
        sel = slice(a.first, a.first + a.images)
        xq = quantize(T.downsample(xi[sel]), float(mdl["in_scale"])).astype(np.int64)
        labels = ", ".join(str(int(v)) for v in yi[sel])
        return mlp_workload("mnist", f"MNIST, {a.images} digit{'s' if a.images > 1 else ''}", layers, [xq], n,
                            trace_load=a.trace_load,
                            lede=f"Test images {a.first}–{a.first + a.images - 1} (labels {labels}), downsampled to "
                                 f"12 × 12 and quantized on the host, through the committed 144 → 64 → 10 model.",
                            facts={"labels": labels})
    return build


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("workload", choices=["mlp", "matmul", "mnist"])
    ap.add_argument("--visualize-internals", action="store_true",
                    help="record every clock cycle in Verilator and write the cycle-by-cycle page")
    ap.add_argument("--n", type=int, default=8, help="array size for the default --link (4 or 8)")
    ap.add_argument("--link", help="tb_isa binary or serial:<port> (default: sim/verilator/trace_n<N>/tb_isa)")
    ap.add_argument("--viz-sim", help="the traced tb_isa for the picture (default: by the link's N)")
    ap.add_argument("-o", "--out", help="page path (default: <workload>-n<N>-viz.html)")
    ap.add_argument("--m", type=int, help="rows per batch (default N; mnist: --images)")
    ap.add_argument("--batches", type=int, default=1)
    ap.add_argument("--k", type=int, default=16, help="matmul: K")
    ap.add_argument("--cols", type=int, default=8, help="matmul: output columns")
    ap.add_argument("--images", type=int, default=8, help="mnist: images in the batch")
    ap.add_argument("--first", type=int, default=0, help="mnist: first test image")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--trace-load", action="store_true", help="trace the weight load too")
    ap.add_argument("--max-cycles", type=int, default=20000)
    ap.add_argument("--profile", metavar="PAGE", help="record the instruction profiler and write its page")
    a = ap.parse_args()
    build = {"mlp": build_mlp, "matmul": build_matmul, "mnist": build_mnist}[a.workload](a)
    link = a.link or str(viz_sim_path(a.n))
    if not a.link and not Path(link).exists():
        sys.exit(f"{link} not found: build it with `make viz-sim N={a.n}`")
    r = run_workload(build, link, visualize_internals=a.visualize_internals, out=a.out,
                     viz_sim=a.viz_sim, max_cycles=a.max_cycles, profile_out=a.profile)
    ok = r["match"] and r.get("sim_match", True)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
