#!/usr/bin/env python3
"""files for mnist_tpu on the DE1-SoC's ARM:
  model.bin   - compiled MLP: load program + data, infer programs for m=1 and m=8
  testset.bin - per test image: 28x28 pixels, label, the host's quantized input,
                the reference model's prediction and the host numpy path's prediction
usage: make_data.py [outdir] [--count N]"""
import argparse
import struct
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import train_mnist as T                                         # noqa: E402
from infer import _quantize, load_model, predict_batch_offline  # noqa: E402
from tpu.isa_compile import compile_mlp                         # noqa: E402
from tpu.isa_model import IsaModel                              # noqa: E402

MS = (1, 8)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir", nargs="?", default=str(HERE / "build"))
    ap.add_argument("--count", type=int, default=10000)
    a = ap.parse_args()
    out = Path(a.outdir)
    out.mkdir(parents=True, exist_ok=True)

    mdl = load_model()
    hs = float(mdl["hidden_scale"])
    layers = [dict(w=mdl["w1"], b=mdl["b1"], relu=True, scale=1 / hs),
              dict(w=mdl["w2"], b=mdl["b2"], relu=True, scale=None)]
    cms = {m: compile_mlp(layers, m) for m in MS}
    load = cms[1].load_program()
    assert all(cm.load_program() == load for cm in cms.values())
    first, last = cms[1].plan[0], cms[1].plan[-1]
    in_scale = np.float32(mdl["in_scale"])
    edges = np.round(np.linspace(0, 28, T.IN_SIDE + 1)).astype(int)

    with open(out / "model.bin", "wb") as f:
        f.write(b"TPUM" + struct.pack("<9I", 1, cms[1].n, cms[1].k_in, first["kt"], last["nb"],
                                      last["n_out"], T.IN_SIDE, len(MS), 0))
        f.write(struct.pack("<f", float(in_scale)))
        f.write(struct.pack(f"<{T.IN_SIDE + 1}I", *edges))
        prog, data = load
        f.write(struct.pack("<2I", len(prog), len(data)))
        f.write(struct.pack(f"<{len(prog)}Q", *prog))
        f.write(struct.pack(f"<{len(data)}I", *data))
        for m in MS:
            iprog, _ = cms[m].infer_program(np.zeros((m, cms[m].k_in), np.int64))
            f.write(struct.pack("<2I", m, len(iprog)))
            f.write(struct.pack(f"<{len(iprog)}Q", *iprog))

    _, _, xi, yi = T.load_mnist()
    xi, yi = xi[:a.count], yi[:a.count]
    xf = T.downsample(xi)
    xq = _quantize(xf, float(mdl["in_scale"])).astype(np.int8)
    host = np.asarray(predict_batch_offline(mdl, xf))

    # the reference model's predictions: what the TPU must produce exactly
    cm = cms[8]
    model = IsaModel(n=cm.n)
    model.run(*load)
    ref = []
    for i in range(0, len(xq), 8):
        xb = np.zeros((8, cm.k_in), np.int64)
        xb[:len(xq[i:i + 8])] = xq[i:i + 8]
        model.reset()
        o = model.run(*cm.infer_program(xb))
        assert model.err is None, model.err
        ref += list(cm.decode(o).argmax(1)[:len(xq[i:i + 8])])
    ref = np.array(ref)

    with open(out / "testset.bin", "wb") as f:
        f.write(b"TPUT" + struct.pack("<3I", 1, len(xi), xq.shape[1]))
        for k in range(len(xi)):
            f.write(xi[k].astype(np.uint8).tobytes())
            f.write(struct.pack("<3B", int(yi[k]), int(ref[k]), int(host[k])))
            f.write(xq[k].tobytes())
    print(f"{out}: {len(xi)} images; reference model accuracy {np.mean(ref == yi):.4f}, "
          f"host path {np.mean(host == yi):.4f}, model vs host differ on {int(np.sum(ref != host))}")


if __name__ == "__main__":
    main()
