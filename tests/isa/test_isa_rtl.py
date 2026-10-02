#!/usr/bin/env python3
"""instruction-stream RTL vs the reference model, word for word.
usage: test_isa_rtl.py <tb_isa binary | serial:<port>[:<server>]> (the latter is the DE1-SoC)"""
import os
import random
import sys
from pathlib import Path

import numpy as np

from tpu import golden, isa
from tpu.isa_device import ERR_SEQ, OUT, IsaDevice, IsaError, open_link
from tpu.isa_layout import bias_entries, out_rows, ub_entries, weight_rows
from tpu.isa_model import (ERR_COMBO, ERR_OPCODE, ERR_RANGE, ERR_RESERVED, ERR_UNIMPL,
                           IsaModel)

failures = []
# random int32 inputs per requant table; the spec asks for 10^6 (ISA_RQ_RANDOM=1000000)
RQ_RANDOM = int(os.environ.get("ISA_RQ_RANDOM", "20000"))


def check(name, ok, detail=""):
    print(f"[{'PASS' if ok else 'FAIL'}] {name}{(': ' + detail) if detail and not ok else ''}")
    if not ok:
        failures.append(name)


def layer_program(n, x, w, b, relu=True, k_split=None, tag=7, ddr_base=None):
    """one layer's program and data. ddr_base: its weights stream from DDR3 there
    (MATMUL wsrc=1); the caller writes weight_rows(w, n)[0] to DDR3 first"""
    rows, kt, nb = weight_rows(w, n)
    ub = ub_entries(x, n)
    bias = bias_entries(b, n)
    m = x.shape[0]
    wsrc, tile0 = (0, 0) if ddr_base is None else (1, ddr_base // (n * n))
    prog = ([isa.wr_wmem(0, len(rows))] if not wsrc else []) + [
            isa.wr_bias(0, nb), isa.wr_ub(0, len(ub)),
            isa.wait(isa.WT, isa.LD), isa.wait(isa.MM, isa.LD), isa.wait(isa.ACT, isa.LD),
            isa.set_wbase(tile0)]
    data = (isa.pack_int8(rows) if not wsrc else []) + isa.pack_int32(bias.ravel()) + isa.pack_int8(ub)
    if k_split is None:
        prog.append(isa.matmul(m, kt, nb, 0, 0, wsrc=wsrc))
    else:
        for blk in range(nb):
            prog += [isa.set_wbase(tile0 + blk * kt), isa.matmul(m, k_split, 1, blk * m, 0, wsrc=wsrc),
                     isa.set_wbase(tile0 + blk * kt + k_split),
                     isa.matmul(m, kt - k_split, 1, blk * m, k_split * m, accumulate=True, wsrc=wsrc)]
    prog += [isa.wait(isa.ACT, isa.MM),
             isa.activate(nb, m, 0, func=isa.FUNC_RELU if relu else isa.FUNC_IDENTITY),
             isa.signal(tag)]
    return prog, data, nb


def main(binary):
    link = open_link(binary)
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

    # -- phase 5: weights from DDR3 (MATMUL wsrc=1) ----------------------------
    dev.reset()
    m = model()
    words = [isa.set_wbase((1 << 30) // (n * n)), isa.matmul(1, 1, 1, 0, 0, wsrc=1), isa.signal(1)]
    m.run(words)
    try:
        dev.run(words, timeout=5)
        got = None
    except IsaError:
        got = (dev.status()["err_code"], link.read32(ERR_SEQ))
    check("decode error: MATMUL from DDR3 past its end", got == (ERR_RANGE, 1)
          and m.err is not None and (m.err.code, m.err.seq) == got, f"rtl {got}, model {m.err}")

    def ddr_layer(x, w, b, relu, split, base):
        prog, data, nb = layer_program(n, x, w, b, relu=relu, k_split=split, ddr_base=base)
        rows = weight_rows(w, n)[0]
        link.ddr_write(base, rows.astype(np.int8).tobytes())
        mod = model()
        mod.ddr.write(base, rows)
        dev.reset()
        return dev.run(prog, data), mod.run(prog, data), nb

    drng = random.Random(9)
    bad = 0
    count = 30
    for i in range(count):
        mm, k, nn = drng.randrange(1, 9), drng.randrange(1, 6 * n + 5), drng.randrange(1, 4 * n + 3)
        x = nrng.integers(-128, 128, (mm, k))
        w = nrng.integers(-128, 128, (k, nn))
        b = nrng.integers(-(1 << 31), 1 << 31, nn)
        kt = -(-k // n)
        split = drng.randrange(1, kt) if kt > 1 and i % 3 == 0 else None
        lo, hi = link.ddr_window
        base = drng.randrange(lo // (n * n), (hi - 65536) // (n * n)) * n * n
        got, want, nb = ddr_layer(x, w, b, bool(i % 2), split, base)
        gold = golden.matmul(x, w, b, psum_width=32, relu=bool(i % 2))
        if got != want or not np.array_equal(out_rows(want, mm, nb, n)[:, :nn], gold):
            bad += 1
            if bad == 1:
                print(f"    first mismatch: m={mm} k={k} n={nn} split={split} base={base:#x}")
    check(f"{count} random layers with weights in DDR3 (random bus timing), RTL == model == tpu.golden",
          bad == 0, f"{bad} bad")

    # CTRL.RESET while a DDR3 stream is in flight: late beats must not leak into the next MATMUL
    dev.reset()
    dev.push_program([isa.set_wbase(link.ddr_window[0] // (n * n)), isa.matmul(1, 64, 8, 0, 0, wsrc=1)])
    for _ in range(40):
        dev.status()
    dev.reset()
    x = nrng.integers(-128, 128, (3, 5 * n))
    w = nrng.integers(-128, 128, (5 * n, 2 * n))
    b = nrng.integers(-1000, 1000, 2 * n)
    got, want, _ = ddr_layer(x, w, b, True, None, link.ddr_window[0] + 0x200000)
    check("CTRL.RESET mid-stream: the next DDR3 MATMUL is still exact", got == want)

    # -- MNIST layer 1 --------------------------------------------------------
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "software" / "mnist"))
    import train_mnist as T
    from mnist_model import quantize, load_model
    mdl = load_model()
    _, _, xi, _ = T.load_mnist()
    x = quantize(T.downsample(xi[:8]), float(mdl["in_scale"])).astype(np.int64)
    prog, data, nb = layer_program(n, x, mdl["w1"], mdl["b1"])
    dev.reset()
    got = out_rows(dev.run(prog, data), 8, nb, n)[:, :64]
    want = np.maximum(golden.wrap(golden.accumulate(x, mdl["w1"], mdl["b1"]), 32), 0)
    check("MNIST layer 1, 8 images (m=8), vs hw_layer at 32 bits", np.array_equal(got, want))
    perf = dev.perf()
    tiles = -(-144 // n) * -(-64 // n)
    check("PERF_MM_BEATS counts one beat per activation row per tile",
          perf["mm_beats"] == tiles * 8, f"{perf}")

    # -- phase 2: the requantizer alone ------------------------------------------
    nb = min(link.param_depth, link.acc_depth)
    dev.reset()
    zero = [isa.wr_wmem(0, nb * n), isa.wr_ub(0, 1), isa.wait(isa.WT, isa.LD),
            isa.wait(isa.MM, isa.LD), isa.set_wbase(0), isa.matmul(1, 1, nb, 0, 0), isa.signal(3)]
    dev.run(zero, [0] * (nb * n * n // 4 + n // 4))   # ACC rows 0..nb-1 = 0
    qrng = np.random.default_rng(11)
    tables = [("MNIST hidden scale", np.full(n, isa.quant_word(13049303, 31))),
              ("M = 1", np.full(n, isa.quant_word(1 << 23, 23))),
              ("per-channel random", np.array([isa.quant_word(int(qrng.integers(1 << 23, 1 << 24)),
                                                               int(qrng.integers(0, 64)))
                                               for _ in range(n)]))]
    edge = np.array([(1 << 26) - 1, 1 << 26, -(1 << 26), -(1 << 26) - 1, (1 << 31) - 1, -(1 << 31)])
    for name, qrow in tables:
        vals = np.concatenate([np.arange(-32768, 32768), edge,
                               qrng.integers(-(1 << 31), 1 << 31, RQ_RANDOM)])
        per = nb * n
        bad = 0
        for i in range(0, len(vals), per):
            chunk = np.zeros(per, np.int64)
            got_n = len(vals[i:i + per])
            chunk[:got_n] = vals[i:i + per]
            prog = [isa.wr_bias(0, nb), isa.wr_quant(0, nb), isa.wait(isa.ACT, isa.LD),
                    isa.activate(nb, 1, 0, func=isa.FUNC_IDENTITY, rq=True, dst=isa.DST_HOST,
                                 bias=True, param_idx=0), isa.signal(4)]
            data = isa.pack_int32(chunk) + isa.pack_int32(np.tile(qrow, nb))
            got = isa.unpack_int8(dev.run(prog, data), per)
            want = golden.requant(chunk.reshape(nb, n), np.tile(qrow & 0xFFFFFF, (nb, 1)),
                                  np.tile((qrow >> 24) & 0x3F, (nb, 1))).ravel()
            bad += int(np.sum(np.array(got[:got_n]) != want[:got_n]))
        check(f"requantizer, {len(vals):,} inputs (every int16 + edges + random int32): {name}",
              bad == 0, f"{bad} differ")

    # -- phase 2: full MNIST program, layers chained in the UB ----------------
    from tpu.isa_compile import compile_mlp
    from mnist_model import predict_batch_offline
    hs = float(mdl["hidden_scale"])
    layers = [dict(w=mdl["w1"], b=mdl["b1"], relu=True, scale=1 / hs),
              dict(w=mdl["w2"], b=mdl["b2"], relu=True, scale=None)]
    xf = T.downsample(xi[:20])
    x20 = quantize(xf, float(mdl["in_scale"])).astype(np.int64)
    host_pred = list(predict_batch_offline(mdl, xf))
    if n == 8:
        for m in (1, 8):
            cm = compile_mlp(layers, m, n)
            dev.reset()
            mod = model()
            lp = cm.load_program()
            dev.run(*lp)
            mod.run(*lp)
            preds, same = [], True
            for i in range(0, 20, m):
                xb = np.zeros((m, 144), np.int64)
                xb[:len(x20[i:i + m])] = x20[i:i + m]
                prog, data = cm.infer_program(xb)
                dev.reset()
                mod.reset()
                got = dev.run(prog, data)
                same &= got == mod.run(prog, data)
                preds += list(cm.decode(got).argmax(1)[:len(x20[i:i + m])])
            check(f"MNIST full program chained on the core, 20 images, m={m}: RTL == model, argmax == host path",
                  same and preds == host_pred, f"same={same} {preds} vs {host_pred}")
        for m in (1, 8):
            cm = compile_mlp(layers, m, n, ddr_base=0x30000000)
            dev.reset()
            mod = model()
            link.ddr_write(*cm.ddr_image())
            mod.ddr.write(*cm.ddr_image())
            lp = cm.load_program()
            dev.run(*lp)
            mod.run(*lp)
            preds, same = [], True
            for i in range(0, 20, m):
                xb = np.zeros((m, 144), np.int64)
                xb[:len(x20[i:i + m])] = x20[i:i + m]
                prog, data = cm.infer_program(xb)
                dev.reset()
                mod.reset()
                got = dev.run(prog, data)
                same &= got == mod.run(prog, data)
                preds += list(cm.decode(got).argmax(1)[:len(x20[i:i + m])])
            check(f"MNIST with its weights in DDR3, 20 images, m={m}: RTL == model, argmax == host path",
                  same and preds == host_pred, f"same={same} {preds} vs {host_pred}")

    # -- phase 3: random concurrent programs, WAITs from isa_waits -------------
    import isa_progs
    from tpu.isa_waits import check_waits, insert_waits
    prng = np.random.default_rng(5)
    init = isa_progs.init_program(n, prng)
    bad = left = raced = 0
    count = int(os.environ.get("ISA_RANDOM_PROGS", "40"))
    for t in range(count):
        raw, data = isa_progs.random_program(n, prng)
        prog = insert_waits(raw, n) + [isa.signal(9)]
        raced += bool(check_waits(raw, n))
        left += len(check_waits(prog, n))
        dev.reset()
        mod = model()
        dev.run(*init)
        mod.run(*init)
        dev.reset()
        mod.reset()
        got = dev.run(prog, data)
        want = mod.run(prog, data)
        if got != want or mod.err is not None:
            bad += 1
            if bad == 1:
                print(f"    first mismatch: program {t}, model err {mod.err}")
    check(f"{count} random concurrent programs ({raced} with hazards before WAIT insertion): "
          f"RTL == model", bad == 0 and left == 0 and raced > count // 2,
          f"bad={bad} hazards left={left} raced={raced}")

    # -- phase 3: steady-state tile rate ---------------------------------------
    tiles = 8
    for m in (1, n, 2 * n + 3):
        dev.reset()
        dev.run([isa.wr_wmem(0, 2 * tiles * n), isa.wr_ub(0, 2 * tiles * m),
                 isa.wait(isa.WT, isa.LD), isa.wait(isa.MM, isa.LD), isa.signal(1)],
                [0] * (2 * tiles * n * n // 4 + 2 * tiles * m * n // 4))
        runs = []
        for kt in (tiles, 2 * tiles):
            dev.reset()
            dev.run([isa.set_wbase(0), isa.matmul(m, kt, 1, 0, 0), isa.signal(2)])
            runs.append(dev.perf())
        period = max(m, n)
        dc = runs[1]["cycles"] - runs[0]["cycles"]
        counts_ok = (runs[1]["mm_wstall"] == runs[0]["mm_wstall"]
                     and runs[1]["mm_beats"] == 2 * tiles * m)
        if link.cycle_exact:
            check(f"one tile per max(m, N) = {period} cycles in steady state, m={m}: "
                  f"{tiles} more tiles take {dc} cycles, no extra WSTALL",
                  abs(dc - tiles * period) <= 8 and counts_ok, f"{runs}")
        else:   # the rate itself is checked on the board by the self-test ROM
            check(f"m={m}: {tiles} more tiles add exactly {tiles * m} MM beats and no WSTALL "
                  f"(cycle rate not measurable over this link)", counts_ok, f"{runs}")

    # -- phase 5: the tile rate from DDR3, on a bus that answers at once -------
    link.ddr_timing(False)
    link.ddr_write(link.ddr_window[0], bytes(2 * tiles * n * n))
    for m in (1, n):
        runs = []
        for kt in (tiles, 2 * tiles):
            dev.reset()
            dev.run([isa.set_wbase(link.ddr_window[0] // (n * n)), isa.matmul(m, kt, 1, 0, 0, wsrc=1),
                     isa.signal(2)])
            runs.append(dev.perf())
        period = max(m, n)
        dc = runs[1]["cycles"] - runs[0]["cycles"]
        counts_ok = (runs[1]["mm_wstall"] == runs[0]["mm_wstall"]
                     and runs[1]["mm_beats"] == 2 * tiles * m)
        if link.cycle_exact:
            check(f"weights from DDR3: one tile per max(m, N) = {period} cycles, m={m}: "
                  f"{tiles} more tiles take {dc} cycles, no extra WSTALL",
                  abs(dc - tiles * period) <= 8 and counts_ok, f"{runs}")
        else:
            check(f"weights from DDR3, m={m}: {tiles} more tiles add exactly {tiles * m} MM beats "
                  f"and no WSTALL", counts_ok, f"{runs}")
    link.ddr_timing(True)

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
