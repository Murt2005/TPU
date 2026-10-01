#!/usr/bin/env python3
"""instruction-stream RTL vs the reference model, word for word. usage: test_isa_rtl.py <tb_isa binary>"""
import random
import sys
from pathlib import Path

import numpy as np

from tpu import golden, isa
from tpu.isa_device import ERR_SEQ, OUT, IsaDevice, IsaError, IsaSimLink
from tpu.isa_layout import bias_entries, out_rows, ub_entries, weight_rows
from tpu.isa_model import (ERR_COMBO, ERR_OPCODE, ERR_RANGE, ERR_RESERVED, ERR_UNIMPL,
                           IsaModel)

failures = []


def check(name, ok, detail=""):
    print(f"[{'PASS' if ok else 'FAIL'}] {name}{(': ' + detail) if detail and not ok else ''}")
    if not ok:
        failures.append(name)


def layer_program(n, x, w, b, relu=True, k_split=None, tag=7):
    rows, kt, nb = weight_rows(w, n)
    ub = ub_entries(x, n)
    bias = bias_entries(b, n)
    m = x.shape[0]
    prog = [isa.wr_wmem(0, len(rows)), isa.wr_bias(0, nb), isa.wr_ub(0, len(ub)),
            isa.wait(isa.WT, isa.LD), isa.wait(isa.MM, isa.LD), isa.wait(isa.ACT, isa.LD),
            isa.set_wbase(0)]
    data = isa.pack_int8(rows) + isa.pack_int32(bias.ravel()) + isa.pack_int8(ub)
    if k_split is None:
        prog.append(isa.matmul(m, kt, nb, 0, 0))
    else:
        for blk in range(nb):
            prog += [isa.set_wbase(blk * kt), isa.matmul(m, k_split, 1, blk * m, 0),
                     isa.set_wbase(blk * kt + k_split),
                     isa.matmul(m, kt - k_split, 1, blk * m, k_split * m, accumulate=True)]
    prog += [isa.wait(isa.ACT, isa.MM),
             isa.activate(nb, m, 0, func=isa.FUNC_RELU if relu else isa.FUNC_IDENTITY),
             isa.signal(tag)]
    return prog, data, nb


def main(binary):
    link = IsaSimLink(binary)
    dev = IsaDevice(link)
    n = link.n
    print(f"tb_isa: N={n} WMEM={link.wmem_rows} UB={link.ub_depth} ACC={link.acc_depth} "
          f"PARAM={link.param_depth}")

    def model():
        return IsaModel(n=n, wmem_rows=link.wmem_rows, ub_depth=link.ub_depth,
                        acc_depth=link.acc_depth, param_depth=link.param_depth)

    # -- smoke: UB round trip -------------------------------------------------
    dev.reset()
    nrng = np.random.default_rng(3)
    ents = nrng.integers(-128, 128, (5, n))
    prog = [isa.wr_ub(10, 5), isa.wait(isa.ACT, isa.LD), isa.rd_ub(10, 5), isa.signal(1)]
    out = dev.run(prog, isa.pack_int8(ents))
    check("WR_UB -> RD_UB round trip", out == isa.pack_int8(ents),
          f"{[hex(v) for v in out]} vs {[hex(v) for v in isa.pack_int8(ents)]}")
    st = dev.status()
    check("SIGNAL sets DONE and its tag", st["done"] and st["tag"] == 1, str(st))

    # -- decode errors --------------------------------------------------------
    cases = [
        ("unknown opcode", 0x3F << 58, ERR_OPCODE),
        ("reserved bit", isa.nop() | 1, ERR_RESERVED),
        ("reserved FUNC", isa.encode("ACTIVATE", func=2, dst=1), ERR_RESERVED),
        ("reserved DST", isa.encode("ACTIVATE", dst=3), ERR_RESERVED),
        ("RD_DDR_UB unimplemented", isa.encode("RD_DDR_UB"), ERR_UNIMPL),
        ("SET_OBASE unimplemented", isa.encode("SET_OBASE"), ERR_UNIMPL),
        ("MATMUL from DDR3", isa.matmul(1, 1, 1, 0, 0, wsrc=1), ERR_UNIMPL),
        ("ACTIVATE requantize", isa.activate(1, 1, 0, rq=True, dst=isa.DST_UB), ERR_UNIMPL),
        ("ACTIVATE to DDR3", isa.activate(1, 1, 0, dst=isa.DST_DDR), ERR_UNIMPL),
        ("ACTIVATE int32 into UB", isa.activate(1, 1, 0, dst=isa.DST_UB), ERR_COMBO),
        ("WR_UB past the end", isa.wr_ub(link.ub_depth - 2, 5), ERR_RANGE),
        ("MATMUL ACC past the end", isa.matmul(8, 1, link.acc_depth // 8 + 1, 0, 0), ERR_RANGE),
        ("MATMUL weights past the end",
         isa.matmul(1, link.wmem_rows // n + 1, 1, 0, 0), ERR_RANGE),
        ("ACTIVATE params past the end", isa.activate(4, 1, 0, param_idx=link.param_depth - 2),
         ERR_RANGE),
    ]
    for name, word, code in cases:
        dev.reset()
        m = model()
        m.run([isa.nop(), word, isa.signal(1)])
        try:
            dev.run([isa.nop(), word, isa.signal(1)], timeout=5)
            got = None
        except IsaError:
            got = (dev.status()["err_code"], link.read32(ERR_SEQ))
        ok = got == (code, 1) and m.err is not None and (m.err.code, m.err.seq) == got
        check(f"decode error: {name}", ok, f"rtl {got}, model {m.err}")
    dev.reset()
    out = dev.run([isa.wr_ub(0, 1), isa.wait(isa.ACT, isa.LD), isa.rd_ub(0, 1), isa.signal(2)],
                  isa.pack_int8([list(range(n))]))
    check("CTRL.RESET clears ERR and the core runs again", out == isa.pack_int8([list(range(n))]))

    # -- random single layers vs the model ----------------------------------------
    rng = random.Random(5)
    bad = 0
    count = 40
    for i in range(count):
        mm, k, nn = rng.randrange(1, 9), rng.randrange(1, 4 * n + 5), rng.randrange(1, 3 * n + 3)
        x = nrng.integers(-128, 128, (mm, k))
        w = nrng.integers(-128, 128, (k, nn))
        b = nrng.integers(-(1 << 31), 1 << 31, nn)
        kt = -(-k // n)
        split = rng.randrange(1, kt) if kt > 1 and i % 3 == 0 else None
        prog, data, nb = layer_program(n, x, w, b, relu=bool(i % 2), k_split=split)
        dev.reset()
        mod = model()
        want = mod.run(prog, data)
        got = dev.run(prog, data)
        if got != want:
            bad += 1
            if bad == 1:
                print(f"    first mismatch: m={mm} k={k} n={nn} split={split}")
                print(f"    rtl  {got[:8]}\n    model{want[:8]}")
        gold = golden.matmul(x, w, b, psum_width=32, relu=bool(i % 2))
        if not np.array_equal(out_rows(want, mm, nb, n)[:, :nn], gold):
            bad += 1
    check(f"{count} random single layers, RTL == model == tpu.golden", bad == 0, f"{bad} bad")

    # -- MNIST layer 1 --------------------------------------------------------
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "software" / "mnist"))
    import train_mnist as T
    from infer import _quantize, load_model
    mdl = load_model()
    _, _, xi, _ = T.load_mnist()
    x = _quantize(T.downsample(xi[:8]), float(mdl["in_scale"])).astype(np.int64)
    prog, data, nb = layer_program(n, x, mdl["w1"], mdl["b1"])
    dev.reset()
    got = out_rows(dev.run(prog, data), 8, nb, n)[:, :64]
    want = np.maximum(golden.wrap(golden.accumulate(x, mdl["w1"], mdl["b1"]), 32), 0)
    check("MNIST layer 1, 8 images (m=8), vs hw_layer at 32 bits", np.array_equal(got, want))
    perf = dev.perf()
    tiles = -(-144 // n) * -(-64 // n)
    check("PERF_MM_BEATS counts one beat per activation row per tile",
          perf["mm_beats"] == tiles * 8, f"{perf}")

    # -- status ---------------------------------------------------------------
    link.read32(OUT)
    st = dev.status()
    check("reading an empty OUT sets UNDERFLOW", st["underflow"], str(st))
    dev.reset()
    check("idle after reset", dev.status()["idle"])

    link.close()
    print("ALL ISA RTL TESTS PASSED" if not failures else f"{len(failures)} FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
