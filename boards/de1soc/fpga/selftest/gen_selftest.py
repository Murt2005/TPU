#!/usr/bin/env python3
"""replay's ROM: the core's tests as a register transcript, every
expected word from the reference model. usage: gen_selftest.py [out.hex] [--n 8] [--lanes 2]"""
import argparse
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[4]
sys.path[:0] = [str(ROOT / "tests" / "isa"), str(ROOT / "software" / "mnist")]

from tpu import isa                                    # noqa: E402
from tpu.isa_model import IsaModel                     # noqa: E402
from tpu.isa_waits import insert_waits                 # noqa: E402
import isa_progs                                       # noqa: E402
from test_isa_rtl import layer_program                 # noqa: E402

OP_WR, OP_RD, OP_WAIT_DONE, OP_MARK, OP_CAP, OP_CHECK, OP_END = 0x1, 0x2, 0x3, 0x4, 0x5, 0x6, 0xF
INSN_LO, INSN_HI, DATA, OUT, STATUS, LEVELS, CTRL = 0, 1, 2, 3, 4, 5, 6
CYCLES, BEATS, WSTALL = 8, 9, 10
CTRL_RESET, CTRL_CLEAR_DONE, CTRL_CLEAR_PERF = 1, 2, 4
INSN_DEPTH, DATA_DEPTH, OUT_DEPTH = 512, 1024, 1024


class Transcript:
    def __init__(self, n):
        self.entries = []
        self.model = IsaModel(n=n)
        self.marks = {}
        self.caps = []          # slot -> what it holds

    def cap(self, reg, what):
        """read a register into the next capture slot (shown on HEX with SW9 + SW4..0)"""
        slot = len(self.caps)
        assert slot < 32
        self.caps.append(what)
        self._e(OP_CAP, reg, slot)
        return slot

    def check(self, a, b, expected, tol=0):
        """on chip: |cap[a] - cap[b] - expected| <= tol; b == a checks cap[a] alone"""
        assert 0 <= expected < 1 << 18 and 0 <= tol < 16
        self._e(OP_CHECK, 0, a << 27 | b << 22 | tol << 18 | expected)

    def perf(self, what):
        return [self.cap(r, f"{what}: {name}") for r, name in
                ((CYCLES, "cycles"), (BEATS, "MM beats"), (WSTALL, "MM wstall"))]

    def _e(self, op, addr=0, data=0):
        self.entries.append(op << 36 | addr << 32 | (data & 0xFFFFFFFF))

    def mark(self, m, name):
        self.marks[m] = name
        self._e(OP_MARK, 0, m)

    def reset(self):
        self._e(OP_WR, CTRL, CTRL_RESET | CTRL_CLEAR_PERF)
        self.model.reset()

    def run(self, prog, data):
        """push, wait for DONE, check every OUT word, then the drained FIFO levels"""
        assert len(prog) <= INSN_DEPTH and isa.decode(prog[-1])[0] == "SIGNAL"
        out = self.model.run(prog, data)
        assert self.model.err is None, self.model.err
        assert len(out) <= OUT_DEPTH, "ACT would stall on a full out FIFO before DONE"
        self._e(OP_WR, CTRL, CTRL_CLEAR_DONE)
        for w in prog:
            self._e(OP_WR, INSN_LO, w & 0xFFFFFFFF)
            self._e(OP_WR, INSN_HI, w >> 32)
        for d in data:
            self._e(OP_WR, DATA, d)
        self._e(OP_WAIT_DONE)
        for w in out:
            self._e(OP_RD, OUT, w)
        self._e(OP_RD, LEVELS, DATA_DEPTH << 10 | INSN_DEPTH)


def build(n, lanes=2):
    t = Transcript(n)
    rng = np.random.default_rng(2026)

    t.mark(0x01, "UB round trip")
    t.reset()
    ub = rng.integers(-128, 128, (16, n))
    t.run([isa.wr_ub(0, 16), isa.wait(isa.ACT, isa.LD), isa.rd_ub(0, 16), isa.signal(1)],
          isa.pack_int8(ub))

    shapes = [(1, 3 * n, n), (n, n, n), (n + 3, 2 * n + 1, 2 * n - 1), (2 * n + 1, 4 * n, n + 2),
              (3, 5 * n, 3 * n), (n, 6 * n, 2 * n)]
    for i, (m, k, nn) in enumerate(shapes):
        t.mark(0x10 + i, f"single layer m={m} K={k} N={nn}")
        t.reset()
        x = rng.integers(-128, 128, (m, k))
        w = rng.integers(-128, 128, (k, nn))
        b = rng.integers(-30000, 30000, nn)
        split = (-(-k // n)) // 2 if i % 2 and k > n else None
        prog, data, _ = layer_program(n, x, w, b, relu=bool(i % 2), k_split=split)
        t.run(prog, data)

    # requantizer: ACC zeroed, so ACT's bias carries the inputs
    nb = 32
    t.mark(0x20, "zero ACC for the requantizer")
    t.reset()
    t.run([isa.wr_wmem(0, nb * n), isa.wr_ub(0, 1), isa.wait(isa.WT, isa.LD), isa.wait(isa.MM, isa.LD),
           isa.set_wbase(0), isa.matmul(1, 1, nb, 0, 0), isa.signal(3)],
          [0] * (nb * n * n // 4 + n // 4))
    tables = [np.full(n, isa.quant_word(13049303, 31)), np.full(n, isa.quant_word(1 << 23, 23)),
              np.array([isa.quant_word(int(rng.integers(1 << 23, 1 << 24)), int(rng.integers(0, 64)))
                        for _ in range(n)])]
    edge = [(1 << 26) - 1, 1 << 26, -(1 << 26), -(1 << 26) - 1, (1 << 31) - 1, -(1 << 31),
            10449, 10450, 10451, -10450]
    for j, qrow in enumerate(tables):
        t.mark(0x21 + j, f"requantizer table {j}")
        vals = np.concatenate([edge, rng.integers(-40000, 40000, nb * n // 2),
                               rng.integers(-(1 << 31), 1 << 31, nb * n)])[:nb * n]
        t.run([isa.wr_bias(0, nb), isa.wr_quant(0, nb), isa.wait(isa.ACT, isa.LD),
               isa.activate(nb, 1, 0, func=isa.FUNC_IDENTITY, rq=True, dst=isa.DST_HOST, bias=True),
               isa.signal(4)],
              isa.pack_int32(vals) + isa.pack_int32(np.tile(qrow, nb)))

    if n == 8:
        import train_mnist as T
        from mnist_model import quantize, load_model
        from tpu.isa_compile import compile_mlp
        mdl = load_model()
        _, _, xi, _ = T.load_mnist()
        hs = float(mdl["hidden_scale"])
        cm = compile_mlp([dict(w=mdl["w1"], b=mdl["b1"], relu=True, scale=1 / hs),
                          dict(w=mdl["w2"], b=mdl["b2"], relu=True, scale=None)], 8, n)
        t.mark(0x30, "MNIST load program")
        t.reset()
        t.run(*cm.load_program())
        t.mark(0x31, "MNIST 8 images, layers chained through the UB")
        t.reset()
        t.run(*cm.infer_program(quantize(T.downsample(xi[:8]), float(mdl["in_scale"])).astype(np.int64)))
        t.perf("MNIST 8 images")

    # steady-state rate: kt and 2kt tiles of one MATMUL; the extra tiles must cost
    # exactly tiles * max(m, N / lanes) cycles (+-1: WAIT_DONE polls every 2 cycles), no WSTALL
    tiles = 8
    for j, m in enumerate((1, n, 2 * n + 3)):
        t.mark(0x50 + j, f"tile rate, m={m}: {tiles} vs {2 * tiles} tiles")
        t.reset()
        t.run([isa.wr_wmem(0, 2 * tiles * n), isa.wr_ub(0, 2 * tiles * m),
               isa.wait(isa.WT, isa.LD), isa.wait(isa.MM, isa.LD), isa.signal(1)],
              [0] * (2 * tiles * n * n // 4 + 2 * tiles * m * n // 4))
        runs = []
        for kt in (tiles, 2 * tiles):
            t.reset()
            t.run([isa.set_wbase(0), isa.matmul(m, kt, 1, 0, 0), isa.signal(2)], [])
            runs.append(t.perf(f"m={m}, {kt} tiles"))
        (c1, b1, s1), (c2, b2, s2) = runs
        t.check(c2, c1, tiles * max(m, n // lanes), tol=1)
        t.check(s2, s1, 0)
        t.check(b1, b1, tiles * m)
        t.check(b2, b2, 2 * tiles * m)

    prng = np.random.default_rng(5)
    t.mark(0x40, "random-program initial state")
    t.reset()
    t.run(*isa_progs.init_program(n, prng))
    for i in range(1, 9):                              # memories carry over, as in the model
        t.mark(0x40 + i, f"random concurrent program {i}")
        raw, data = isa_progs.random_program(n, prng, max_data=400)
        t.reset()
        t.run(insert_waits(raw, n) + [isa.signal(9)], data)

    t.mark(0xFF, "end")
    t._e(OP_END)
    return t


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?", default=str(Path(__file__).with_name("isa_selftest.hex")))
    ap.add_argument("--n", type=int, default=8)
    ap.add_argument("--depth", type=int, default=16384)
    ap.add_argument("--lanes", type=int, default=2, help="the build's WEIGHT_LANES")
    a = ap.parse_args()
    t = build(a.n, a.lanes)
    if len(t.entries) > a.depth:
        sys.exit(f"transcript is {len(t.entries)} entries, ROM holds {a.depth}")
    with open(a.out, "w") as f:
        for e in t.entries:
            f.write(f"{e:010x}\n")
    with open(Path(a.out).with_suffix(".marks"), "w") as f:
        for m, name in t.marks.items():
            f.write(f"{m:02X}  {name}\n")
    with open(Path(a.out).with_suffix(".caps"), "w") as f:
        f.write("SW9 up, SW4..0 = slot; HEX5..0 = low 24 bits, hex\n")
        for i, what in enumerate(t.caps):
            f.write(f"{i:2d}  {i:05b}  {what}\n")
    print(f"{a.out}: {len(t.entries)} entries of {a.depth}, {len(t.marks)} marks")


if __name__ == "__main__":
    main()
