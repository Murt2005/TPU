#!/usr/bin/env python3
"""ISA encoder and reference model, checked against independent references"""
import random
import sys
from pathlib import Path

import numpy as np

from tpu import golden, isa
from tpu.isa_layout import bias_entries, out_rows, ub_entries, weight_rows
from tpu.isa_model import (ERR_COMBO, ERR_NONE, ERR_OPCODE, ERR_RANGE, ERR_RESERVED, ERR_UNIMPL,
                           Ddr, IsaModel)

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
    m = IsaModel(n=8, wmem_rows=64, ub_depth=64, acc_depth=32, param_depth=8, phase=1, ddr=False)
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


def run_layer(model, x, w, b, relu=True, k_split=None, ddr_base=None, words=False):
    """compile one layer: load weights/bias, write x, MATMUL (optionally split
    across two instructions on K), ACTIVATE to host. returns M x N, or the raw
    out words. ddr_base: the host puts the weights in DDR3 there, and the
    MATMULs stream them with wsrc=1 instead of reading WMEM"""
    model.reset()
    n = model.n
    rows, kt, nb = weight_rows(w, n)
    ub = ub_entries(x, n)
    bias = bias_entries(b, n)
    m = x.shape[0]
    wsrc, tile0 = 0, 0
    if ddr_base is None:
        prog = [isa.wr_wmem(0, len(rows)), isa.wr_bias(0, nb), isa.wr_ub(0, len(ub)),
                isa.wait(isa.WT, isa.LD)]
        data = isa.pack_int8(rows)
    else:
        model.ddr.write(ddr_base, rows)
        wsrc, tile0 = 1, ddr_base // (n * n)
        prog = [isa.wr_bias(0, nb), isa.wr_ub(0, len(ub))]
        data = []
    prog += [isa.wait(isa.MM, isa.LD), isa.wait(isa.ACT, isa.LD), isa.set_wbase(tile0)]
    data += isa.pack_int32(bias.ravel()) + isa.pack_int8(ub)
    if k_split is None:
        prog.append(isa.matmul(m, kt, nb, 0, 0, wsrc=wsrc))
    else:
        # weights are block-major, so split per block: K-tiles [0, s) then [s, kt)
        for blk in range(nb):
            prog += [isa.set_wbase(tile0 + blk * kt),
                     isa.matmul(m, k_split, 1, blk * m, 0, wsrc=wsrc),
                     isa.set_wbase(tile0 + blk * kt + k_split),
                     isa.matmul(m, kt - k_split, 1, blk * m, k_split * m, accumulate=True, wsrc=wsrc)]
    prog += [isa.wait(isa.ACT, isa.MM),
             isa.activate(nb, m, 0, func=isa.FUNC_RELU if relu else isa.FUNC_IDENTITY),
             isa.signal(7)]
    out = model.run(prog, data)
    assert model.err is None, model.err
    return out if words else out_rows(out, m, nb, n)[:, :w.shape[1]]


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


def test_ddr_store():
    ddr = Ddr(1 << 20)
    payload = bytes(range(256)) * 40                     # 10 KB across three pages
    ddr.write(4096 - 100, payload)
    ok = ddr.read(4096 - 100, len(payload)) == payload
    ok &= ddr.read(0, 16) == bytes(16) and ddr.read((1 << 20) - 16, 16) == bytes(16)
    ddr.write(64, np.array([[-1, 2], [-128, 127]], np.int8))
    ok &= ddr.read(64, 4) == bytes([255, 2, 128, 127])
    try:
        ddr.write((1 << 20) - 2, b"abc")
        ok = False
    except ValueError:
        pass
    check("DDR3 store: page-crossing writes, zero until written, int8 rows, bounds", ok)


def test_ddr_errors():
    """with wsrc=1 implemented: legal, range-checked against DDR3 rather than WMEM;
    the rest of phase 5 stays unimplemented"""
    m = IsaModel(n=8, wmem_rows=64, ub_depth=64, acc_depth=32, param_depth=8,
                 ddr=True, ddr_bytes=64 * 64)    # 64 tiles of DDR3, 8 of WMEM
    cases = [
        ("MATMUL from DDR3", [isa.set_wbase(60), isa.matmul(1, 2, 2, 0, 0, wsrc=1)], ERR_NONE),
        ("MATMUL from DDR3 past its end", [isa.set_wbase(61), isa.matmul(1, 2, 2, 0, 0, wsrc=1)], ERR_RANGE),
        ("MATMUL from WMEM still checks WMEM", [isa.set_wbase(6), isa.matmul(1, 2, 2, 0, 0)], ERR_RANGE),
        ("RD_DDR_UB, entry-aligned", [isa.rd_ddr_ub(0, 4, 64 * 64 - 32)], ERR_NONE),
        ("RD_DDR_UB, misaligned", [isa.rd_ddr_ub(0, 1, 4)], ERR_RESERVED),
        ("RD_DDR_UB past DDR3's end", [isa.rd_ddr_ub(0, 5, 64 * 64 - 32)], ERR_RANGE),
        ("RD_DDR_UB past the UB's end", [isa.rd_ddr_ub(62, 3, 0)], ERR_RANGE),
        ("SET_OBASE, misaligned", [isa.set_obase(6)], ERR_RESERVED),
        ("ACTIVATE to DDR3 at its end", [isa.set_obase(64 * 64 - 32), isa.activate(1, 1, 0, dst=isa.DST_DDR)],
         ERR_NONE),
        ("ACTIVATE to DDR3 past its end", [isa.set_obase(64 * 64 - 28), isa.activate(1, 1, 0, dst=isa.DST_DDR)],
         ERR_RANGE),
        ("ACTIVATE to DDR3, OBASE advanced past its end",
         [isa.set_obase(64 * 64 - 32), isa.activate(1, 1, 0, dst=isa.DST_DDR),
          isa.activate(1, 1, 0, rq=True, dst=isa.DST_DDR)], ERR_RANGE),
    ]
    for name, words, code in cases:
        m.reset()
        m.run(words + [isa.signal(1)])
        got = m.err.code if m.err else ERR_NONE
        check(f"decode, DDR3 enabled: {name}", got == code and m.done == (code == ERR_NONE), str(m.err))
    for name, word in [("MATMUL wsrc=1", isa.matmul(1, 1, 1, 0, 0, wsrc=1)), ("RD_DDR_UB", isa.rd_ddr_ub(0, 1, 0)),
                       ("SET_OBASE", isa.set_obase(0)), ("ACTIVATE dst=DDR", isa.activate(1, 1, 0, dst=isa.DST_DDR))]:
        m = IsaModel(n=8, ddr=False)
        m.run([word, isa.signal(1)])
        check(f"decode: {name} is ERR_UNIMPL until enabled", m.err is not None and m.err.code == ERR_UNIMPL)


def test_ddr_weights(rng):
    """the same layers with their weights in DDR3 give the same out words as from
    WMEM, word for word, and match tpu.golden"""
    nrng = np.random.default_rng(2)
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
        base = rng.randrange(0, (1 << 30) // (n * n) - 1000) * n * n
        model = IsaModel(n=n, wmem_rows=4096, ub_depth=512, acc_depth=512, param_depth=64,
                         ddr=True)
        from_wmem = run_layer(model, x, w, b, relu, split, words=True)
        from_ddr = run_layer(model, x, w, b, relu, split, ddr_base=base, words=True)
        got = out_rows(from_ddr, mm, -(-nn // n), n)[:, :nn]
        bad += from_ddr != from_wmem or not np.array_equal(got, golden.matmul(x, w, b, psum_width=32, relu=relu))
    check("random layers, weights in DDR3 (wsrc=1) == in WMEM, word for word, and vs tpu.golden",
          bad == 0, f"{bad}/60 differ")


def test_ddr_mixed_sources():
    """one K-sum split across the two sources: the first K-tiles from WMEM, the
    rest from DDR3, through one WBASE that every MATMUL advances"""
    n, m, kt = 8, 3, 4
    nrng = np.random.default_rng(3)
    x = nrng.integers(-128, 128, (m, kt * n), dtype=np.int64)
    w = nrng.integers(-128, 128, (kt * n, n), dtype=np.int64)
    rows, _, _ = weight_rows(w, n)
    model = IsaModel(n=n, ddr=True)
    base_tile = 1000
    model.ddr.write(base_tile * n * n, rows[2 * n:])        # K-tiles 2, 3
    ub = ub_entries(x, n)
    prog = [isa.wr_wmem(0, 2 * n), isa.wr_ub(0, len(ub)), isa.wait(isa.WT, isa.LD),
            isa.wait(isa.MM, isa.LD), isa.set_wbase(0),
            isa.matmul(m, 2, 1, 0, 0),
            isa.set_wbase(base_tile),
            isa.matmul(m, 2, 1, 0, 2 * m, accumulate=True, wsrc=1),
            isa.wait(isa.ACT, isa.MM), isa.activate(1, m, 0, func=isa.FUNC_IDENTITY, bias=False),
            isa.signal(3)]
    out = model.run(prog, isa.pack_int8(rows[:2 * n]) + isa.pack_int8(ub))
    ok = model.err is None and model.wbase == base_tile + 2
    ok &= np.array_equal(out_rows(out, m, 1, n), golden.wrap(x @ w, 32))
    check("one K-sum across WMEM and DDR3, WBASE advancing through both", ok)


def test_rd_ddr_ub():
    """RD_DDR_UB puts DDR3 bytes into the UB exactly as WR_UB puts the same rows,
    from any entry-aligned address (mid-beat at N = 4 and 8 included)"""
    nrng = np.random.default_rng(4)
    ok = True
    for n in (4, 8, 16):
        for start in range(0, 32, n):
            rows = nrng.integers(-128, 128, (7, n))
            m = IsaModel(n=n)
            address = 0x30000000 + start
            m.ddr.write(address, rows)
            out = m.run([isa.rd_ddr_ub(5, 7, address), isa.wait(isa.ACT, isa.LD), isa.rd_ub(5, 7), isa.signal(1)])
            ok &= m.err is None and out == isa.pack_int8(rows)
    check("RD_DDR_UB == WR_UB of the same rows, every entry alignment, N = 4, 8, 16", ok)


def test_activate_ddr():
    """ACTIVATE dst=DDR writes the words dst=HOST would send, little-endian, back
    to back from OBASE; OBASE advances past each one, int32 and requantized alike"""
    n, m_rows, nb = 8, 3, 2
    nrng = np.random.default_rng(6)
    ok = True
    for rq in (False, True):
        model = IsaModel(n=n)
        acc = nrng.integers(-5000, 5000, (nb * m_rows, n))
        model.acc[:nb * m_rows] = acc
        model.quant[:nb] = isa.quant_word(1 << 23, 4)
        act = dict(func=isa.FUNC_RELU, rq=rq, bias=False)
        host = model.run([isa.activate(nb, m_rows, 0, dst=isa.DST_HOST, **act), isa.signal(1)])
        model.reset()
        base = 0x30000010 + 4
        model.run([isa.set_obase(base), isa.activate(nb, m_rows, 0, dst=isa.DST_DDR, **act),
                   isa.activate(1, 1, 0, dst=isa.DST_DDR, **act), isa.signal(2)])
        size = 4 * len(host)
        got = [int.from_bytes(model.ddr.read(base + 4 * i, 4), "little") for i in range(len(host))]
        ok &= model.err is None and got == host
        ok &= model.obase == base + size + (n if rq else 4 * n)
        ok &= model.ddr.read(base + size, 4) == host[0].to_bytes(4, "little")   # the next one, right after
    check("ACTIVATE dst=DDR: the host's words at OBASE, OBASE advancing (int32 and requantized)", ok)


def test_chain_through_ddr():
    """MNIST's hidden layer requantized into DDR3 and read back with RD_DDR_UB:
    the same scores as chaining through the UB"""
    from tpu.isa_compile import compile_mlp
    x, layers, _ = mnist_layers()
    m = 8
    cm = compile_mlp(layers, m)
    p0, p1 = cm.plan
    model = IsaModel(n=8)
    model.run(*cm.load_program())
    ok = True
    for i in range(0, 16, m):
        xb = x[i:i + m]
        model.reset()
        want = model.run(*cm.infer_program(xb))
        ub = ub_entries(xb, 8)
        hidden = 0x30000000
        prog = [isa.wr_ub(p0["ub_in"], len(ub)), isa.set_wbase(0), isa.set_obase(hidden),
                isa.wait(isa.MM, isa.LD),
                isa.matmul(m, p0["kt"], p0["nb"], p0["acc"], p0["ub_in"]), isa.wait(isa.ACT, isa.MM),
                isa.activate(p0["nb"], m, p0["acc"], func=isa.FUNC_RELU, rq=True, dst=isa.DST_DDR,
                             param_idx=p0["par"]),
                isa.wait(isa.LD, isa.ACT),
                isa.rd_ddr_ub(p1["ub_in"], p0["nb"] * m, hidden), isa.wait(isa.MM, isa.LD),
                isa.matmul(m, p1["kt"], p1["nb"], p1["acc"], p1["ub_in"]), isa.wait(isa.ACT, isa.MM),
                isa.activate(p1["nb"], m, p1["acc"], func=isa.FUNC_RELU, dst=isa.DST_HOST, param_idx=p1["par"]),
                isa.signal(3)]
        model.reset()
        got = model.run(prog, isa.pack_int8(ub))
        ok &= model.err is None and got == want
        from tpu.isa_waits import check_waits
        ok &= check_waits(prog, 8) == []
        bare = [w for w in prog if isa.decode(w)[0] != "WAIT"]
        ok &= any(i == bare.index(isa.rd_ddr_ub(p1["ub_in"], p0["nb"] * m, hidden)) and e == isa.LD
                  for i, e, _ in check_waits(bare, 8))
    check("MNIST's hidden layer through DDR3 (ACTIVATE dst=DDR, RD_DDR_UB) == through the UB; "
          "isa_waits sees the DDR3 hazard", ok)


def test_mnist_layer1():
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "software" / "mnist"))
    import train_mnist as T
    from mnist_model import quantize, load_model
    mdl = load_model()
    _, _, xi, _ = T.load_mnist()
    for m in (1, 8):
        x = quantize(T.downsample(xi[:20]), float(mdl["in_scale"])).astype(np.int64)
        model = IsaModel(n=8, wmem_rows=8192, ub_depth=16384, acc_depth=1024, param_depth=256)
        got = np.concatenate([run_layer(model, x[i:i + m], mdl["w1"], mdl["b1"])
                              for i in range(0, len(x), m)])
        raw = golden.accumulate(x, mdl["w1"], mdl["b1"])
        want = np.maximum(golden.wrap(raw, 32), 0)
        check(f"MNIST layer 1, 20 images, m={m}, vs hw_layer at 32 bits", np.array_equal(got, want))


def mnist_layers():
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "software" / "mnist"))
    import train_mnist as T
    from mnist_model import quantize, load_model, predict_batch_offline
    mdl = load_model()
    _, _, xi, _ = T.load_mnist()
    xf = T.downsample(xi[:20])
    x = quantize(xf, float(mdl["in_scale"])).astype(np.int64)
    hs = float(mdl["hidden_scale"])
    layers = [dict(w=mdl["w1"], b=mdl["b1"], relu=True, scale=1 / hs, hidden_scale=hs),
              dict(w=mdl["w2"], b=mdl["b2"], relu=True, scale=None)]
    return x, layers, predict_batch_offline(mdl, xf)


def run_mnist(layers, x, m, ddr_base=None):
    """(argmax per image, every out word) for the compiled MNIST program"""
    from tpu.isa_compile import compile_mlp
    cm = compile_mlp(layers, m, ddr_base=ddr_base)
    model = IsaModel(n=8, ddr=ddr_base is not None)
    if ddr_base is not None:
        model.ddr.write(*cm.ddr_image())
    model.run(*cm.load_program())
    preds, words = [], []
    for i in range(0, len(x), m):
        xb = np.zeros((m, x.shape[1]), np.int64)
        xb[:len(x[i:i + m])] = x[i:i + m]
        model.reset()
        out = model.run(*cm.infer_program(xb))
        assert model.err is None, model.err
        preds += list(cm.decode(out).argmax(1)[:len(x[i:i + m])])
        words += out
    return preds, words


def test_mnist_full():
    x, layers, host_pred = mnist_layers()
    for m in (1, 8):
        preds, words = run_mnist(layers, x, m)
        check(f"MNIST full program chained on the core, 20 images, m={m}: argmax == host path",
              list(preds) == list(host_pred), f"{preds} vs {list(host_pred)}")
        _, ddr_words = run_mnist(layers, x, m, ddr_base=0x30000000)
        check(f"MNIST with its weights in DDR3 (wsrc=1), m={m}: out words == WMEM build", ddr_words == words)


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


def test_waits():
    """the compiled program's WAITs are exactly the hazards isa_waits finds"""
    from tpu.isa_compile import compile_mlp
    from tpu.isa_waits import accesses, check_waits, insert_waits
    x, layers, _ = mnist_layers()
    cm = compile_mlp(layers, 8)
    prog, data = cm.infer_program(x[:8])
    ok = check_waits(prog, 8) == []
    waits = [i for i, w in enumerate(prog) if isa.decode(w)[0] == "WAIT"]
    for i in waits:
        ok &= bool(check_waits(prog[:i] + prog[i + 1:], 8))
    bare = [w for w in prog if isa.decode(w)[0] != "WAIT"]
    redo = insert_waits(bare, 8)
    ok &= check_waits(redo, 8) == [] and len(redo) == len(prog)
    model = IsaModel(n=8)
    model.run(*cm.load_program())
    model.reset()
    a = model.run(prog, data)
    model.reset()
    ok &= a == model.run(redo, data)
    check("isa_waits: compiled MNIST program hazard-free, every WAIT needed, re-insertion matches",
          ok)
    # weights in DDR3: the WT half reads DDR3, which nothing in the program writes
    cm = compile_mlp(layers, 8, ddr_base=0x30000000)
    load, _ = cm.load_program()
    prog, _ = cm.infer_program(x[:8])
    ok = check_waits(load, 8) == [] and check_waits(prog, 8) == []
    ok &= isa.wait(isa.WT, isa.LD) not in load
    wt = [a for w in prog if isa.decode(w)[0] == "MATMUL" for a in accesses(w, (0x30000000 // 64, 0), 8)[0]
          if a[0] == isa.WT]
    ok &= all(r[0][0] == "DDR" for _, r, _ in wt)
    check("isa_waits: DDR3-weight MNIST program hazard-free; WT reads DDR3, not WMEM", ok)


if __name__ == "__main__":
    rng = random.Random(0)
    test_roundtrip(rng)
    test_errors()
    test_random_layers(rng)
    test_ddr_store()
    test_ddr_errors()
    test_ddr_weights(rng)
    test_ddr_mixed_sources()
    test_rd_ddr_ub()
    test_activate_ddr()
    test_mnist_layer1()
    test_requant_vs_host_round()
    test_mnist_full()
    test_chain_through_ddr()
    test_waits()
    print(f"{'ALL ISA MODEL TESTS PASSED' if not failures else f'{len(failures)} FAILED'}")
    sys.exit(1 if failures else 0)
