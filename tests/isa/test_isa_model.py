#!/usr/bin/env python3
"""ISA encoder and reference model, checked against independent references"""
import random
import sys
from pathlib import Path

import numpy as np

from tpu import golden, isa
from tpu.isa_layout import bias_entries, out_rows, ub_entries, weight_rows
from tpu.isa_model import (ERR_COMBO, ERR_OPCODE, ERR_RANGE, ERR_RESERVED, ERR_UNIMPL,
                           IsaModel)

failures = []


def check(name, ok, detail=""):
    print(f"[{'PASS' if ok else 'FAIL'}] {name}{(': ' + detail) if detail and not ok else ''}")
    if not ok:
        failures.append(name)


def test_roundtrip(rng):
    bad = 0
    for name, fields in isa.FIELDS.items():
        for _ in range(200):
            kw = {}
            for field, hi, lo, minus_one in fields:
                kw[field] = rng.randrange(1 << (hi - lo + 1)) + minus_one
            got_name, got = isa.decode(isa.encode(name, **kw))
            bad += got_name != name or got != kw
    check("encoder round-trip, every opcode", bad == 0, f"{bad} mismatches")


def test_errors():
    m = IsaModel(n=8, wmem_rows=64, ub_depth=64, acc_depth=32, param_depth=8, phase=1)
    cases = [
        ("unknown opcode", 0x3F << 58, ERR_OPCODE),
        ("reserved bit", isa.nop() | 1, ERR_RESERVED),
        ("reserved FUNC", isa.encode("ACTIVATE", func=2, dst=1), ERR_RESERVED),
        ("reserved DST", isa.encode("ACTIVATE", dst=3), ERR_RESERVED),
        ("RD_DDR_UB unimplemented", isa.encode("RD_DDR_UB"), ERR_UNIMPL),
        ("SET_OBASE unimplemented", isa.encode("SET_OBASE"), ERR_UNIMPL),
        ("MATMUL from DDR3", isa.matmul(1, 1, 1, 0, 0, wsrc=1), ERR_UNIMPL),
        ("ACTIVATE requantize (phase 1)", isa.activate(1, 1, 0, rq=True, dst=isa.DST_UB), ERR_UNIMPL),
        ("ACTIVATE to DDR3", isa.activate(1, 1, 0, dst=isa.DST_DDR), ERR_UNIMPL),
        ("ACTIVATE int32 into UB", isa.activate(1, 1, 0, dst=isa.DST_UB), ERR_COMBO),
        ("WR_UB past the end", isa.wr_ub(60, 5), ERR_RANGE),
        ("MATMUL ACC past the end", isa.matmul(8, 1, 5, 0, 0), ERR_RANGE),
        ("MATMUL weights past the end", isa.matmul(1, 4, 3, 0, 0), ERR_RANGE),
        ("ACTIVATE params past the end", isa.activate(4, 1, 0, param_idx=6), ERR_RANGE),
    ]
    for name, word, code in cases:
        m.reset()
        m.run([isa.nop(), word, isa.signal(1)])
        ok = m.err is not None and m.err.code == code and m.err.seq == 1 and not m.done
        check(f"decode error: {name}", ok, str(m.err))


def run_layer(model, x, w, b, relu=True, k_split=None):
    """compile one layer: load weights/bias, write x, MATMUL (optionally split
    across two instructions on K), ACTIVATE to host. returns M x N"""
    model.reset()
    n = model.n
    rows, kt, nb = weight_rows(w, n)
    ub = ub_entries(x, n)
    bias = bias_entries(b, n)
    m = x.shape[0]
    prog = [isa.wr_wmem(0, len(rows)), isa.wr_bias(0, nb),
            isa.wr_ub(0, len(ub)), isa.wait(isa.WT, isa.LD), isa.wait(isa.MM, isa.LD),
            isa.wait(isa.ACT, isa.LD), isa.set_wbase(0)]
    data = isa.pack_int8(rows) + isa.pack_int32(bias.ravel()) + isa.pack_int8(ub)
    if k_split is None:
        prog.append(isa.matmul(m, kt, nb, 0, 0))
    else:
        # weights are block-major, so split per block: K-tiles [0, s) then [s, kt)
        for blk in range(nb):
            prog += [isa.set_wbase(blk * kt),
                     isa.matmul(m, k_split, 1, blk * m, 0),
                     isa.set_wbase(blk * kt + k_split),
                     isa.matmul(m, kt - k_split, 1, blk * m, k_split * m, accumulate=True)]
    prog += [isa.wait(isa.ACT, isa.MM),
             isa.activate(nb, m, 0, func=isa.FUNC_RELU if relu else isa.FUNC_IDENTITY),
             isa.signal(7)]
    out = model.run(prog, data)
    assert model.err is None, model.err
    return out_rows(out, m, nb, n)[:, :w.shape[1]]


def test_random_layers(rng):
    nrng = np.random.default_rng(1)
    bad = 0
    for i in range(60):
        n = rng.choice([4, 8])
        mm, k, nn = rng.randrange(1, 9), rng.randrange(1, 40), rng.randrange(1, 30)
        x = nrng.integers(-128, 128, (mm, k), dtype=np.int64)
        w = nrng.integers(-128, 128, (k, nn), dtype=np.int64)
        b = nrng.integers(-(1 << 31), 1 << 31, nn, dtype=np.int64)
        relu = bool(i % 2)
        kt = -(-k // n)
        split = rng.randrange(1, kt) if kt > 1 and i % 3 == 0 else None
        model = IsaModel(n=n, wmem_rows=4096, ub_depth=512, acc_depth=512, param_depth=64)
        got = run_layer(model, x, w, b, relu, split)
        want = golden.matmul(x, w, b, psum_width=32, relu=relu)
        bad += not np.array_equal(got, want)
    check("random single layers vs tpu.golden (32-bit, K split across MATMULs)", bad == 0,
          f"{bad}/60 differ")


def test_mnist_layer1():
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "software" / "mnist"))
    import train_mnist as T
    from infer import _quantize, load_model
    mdl = load_model()
    _, _, xi, _ = T.load_mnist()
    for m in (1, 8):
        x = _quantize(T.downsample(xi[:20]), float(mdl["in_scale"])).astype(np.int64)
        model = IsaModel(n=8, wmem_rows=8192, ub_depth=16384, acc_depth=1024, param_depth=256)
        got = np.concatenate([run_layer(model, x[i:i + m], mdl["w1"], mdl["b1"])
                              for i in range(0, len(x), m)])
        raw = golden.accumulate(x, mdl["w1"], mdl["b1"])
        want = np.maximum(golden.wrap(raw, 32), 0)
        check(f"MNIST layer 1, 20 images, m={m}, vs hw_layer at 32 bits", np.array_equal(got, want))


def mnist_layers():
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "software" / "mnist"))
    import train_mnist as T
    from infer import _quantize, load_model, predict_batch_offline
    mdl = load_model()
    _, _, xi, _ = T.load_mnist()
    xf = T.downsample(xi[:20])
    x = _quantize(xf, float(mdl["in_scale"])).astype(np.int64)
    hs = float(mdl["hidden_scale"])
    layers = [dict(w=mdl["w1"], b=mdl["b1"], relu=True, scale=1 / hs, hidden_scale=hs),
              dict(w=mdl["w2"], b=mdl["b2"], relu=True, scale=None)]
    return x, layers, predict_batch_offline(mdl, xf)


def test_mnist_full():
    from tpu.isa_compile import compile_mlp
    x, layers, host_pred = mnist_layers()
    for m in (1, 8):
        cm = compile_mlp(layers, m)
        model = IsaModel(n=8)
        model.run(*cm.load_program())
        preds = []
        for i in range(0, 20, m):
            xb = np.zeros((m, x.shape[1]), np.int64)
            xb[:len(x[i:i + m])] = x[i:i + m]
            model.reset()
            out = model.run(*cm.infer_program(xb))
            assert model.err is None, model.err
            preds += list(cm.decode(out).argmax(1)[:len(x[i:i + m])])
        check(f"MNIST full program on chip, 20 images, m={m}: argmax == host path",
              list(preds) == list(host_pred), f"{preds} vs {list(host_pred)}")


def test_requant_vs_host_round():
    """the spec's table: the 24-bit requantizer matches np.round(v / hidden_scale)
    on every v in 0..65535 except the one exact tie"""
    _, layers, _ = mnist_layers()
    m0, shift = isa.quant_params(layers[0]["scale"])
    v = np.arange(65536)
    hw = golden.requant(v, m0, shift)
    host = np.clip(np.round(v / layers[0]["hidden_scale"]), -128, 127)
    diff = np.nonzero(hw != host)[0]
    check("requantizer vs host rounding: one difference, the tie at v=10,450",
          list(diff) == [10450], f"differs at {list(diff[:10])}")


if __name__ == "__main__":
    rng = random.Random(0)
    test_roundtrip(rng)
    test_errors()
    test_random_layers(rng)
    test_mnist_layer1()
    test_requant_vs_host_round()
    test_mnist_full()
    print(f"{'ALL ISA MODEL TESTS PASSED' if not failures else f'{len(failures)} FAILED'}")
    sys.exit(1 if failures else 0)
