#!/usr/bin/env python3
"""cases for the tpu_top UVM test: every instruction, data and expected output
word from the reference model (tpu.isa_model), which the RTL must match word for
word. usage: gen_cases.py <out.txt> [--n 8]

format, one case after another (hex numbers):
    case <name>
    program <count>   then <count> lines of 64-bit instruction words
    data <count>      then <count> lines of 32-bit data words
    out <count>       then <count> lines of expected OUT words
    status <done> <tag> <error code> <error sequence> <reads empty OUT> <host at full speed>
"""
import argparse
import random
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT / "tests" / "isa"), str(ROOT / "software" / "mnist")]

from tpu import isa                                    # noqa: E402
from tpu.isa_model import (ERR_COMBO, ERR_OPCODE, ERR_RANGE, ERR_RESERVED,  # noqa: E402
                           ERR_UNIMPL, IsaModel)
from tpu.isa_waits import insert_waits                 # noqa: E402
import isa_progs                                       # noqa: E402
from test_isa_rtl import layer_program                 # noqa: E402

WMEM_ROWS, UB_DEPTH, ACC_DEPTH, PARAMETER_DEPTH = 8192, 16384, 1024, 256   # tpu_top's defaults


class Cases:
    def __init__(self, n):
        self.n = n
        self.model = IsaModel(n=n)      # memories carry over between cases, as on the core
        self.text = []
        self.count = 0

    def add(self, name, program, data=(), underflow=False, full_speed=False):
        """CTRL.RESET before every case, as the UVM sequence does"""
        self.model.reset()
        out = self.model.run(program, data)
        err = self.model.err
        if err is None:
            assert self.model.data_left == 0, f"{name}: {self.model.data_left} data words unused"
        self.text.append(f"case {name.replace(' ', '_')}")
        self.text.append(f"program {len(program):x}")
        self.text += [f"{w:016x}" for w in program]
        self.text.append(f"data {len(data):x}")
        self.text += [f"{d & 0xFFFFFFFF:08x}" for d in data]
        self.text.append(f"out {len(out):x}")
        self.text += [f"{w:08x}" for w in out]
        self.text.append(f"status {int(self.model.done):x} {self.model.tag:x} "
                         f"{err.code if err else 0:x} {err.seq if err else 0:x} {int(underflow):x} {int(full_speed):x}")
        self.count += 1


def build(n):
    c = Cases(n)
    nrng = np.random.default_rng(3)
    rng = random.Random(5)

    ents = nrng.integers(-128, 128, (5, n))
    c.add("UB round trip", [isa.wr_ub(10, 5), isa.wait(isa.ACT, isa.LD), isa.rd_ub(10, 5), isa.signal(1)],
          isa.pack_int8(ents))

    errors = [
        ("unknown opcode", 0x3F << 58, ERR_OPCODE),
        ("reserved bit", isa.nop() | 1, ERR_RESERVED),
        ("reserved FUNC", isa.encode("ACTIVATE", func=2, dst=1), ERR_RESERVED),
        ("reserved DST", isa.encode("ACTIVATE", dst=3), ERR_RESERVED),
        ("RD_DDR_UB unimplemented", isa.encode("RD_DDR_UB"), ERR_UNIMPL),
        ("SET_OBASE unimplemented", isa.encode("SET_OBASE"), ERR_UNIMPL),
        ("MATMUL from DDR3", isa.matmul(1, 1, 1, 0, 0, wsrc=1), ERR_UNIMPL),
        ("ACTIVATE to DDR3", isa.activate(1, 1, 0, dst=isa.DST_DDR), ERR_UNIMPL),
        ("ACTIVATE int32 into UB", isa.activate(1, 1, 0, dst=isa.DST_UB), ERR_COMBO),
        ("WR_UB past the end", isa.wr_ub(UB_DEPTH - 2, 5), ERR_RANGE),
        ("MATMUL ACC past the end", isa.matmul(8, 1, ACC_DEPTH // 8 + 1, 0, 0), ERR_RANGE),
        ("MATMUL weights past the end", isa.matmul(1, WMEM_ROWS // n + 1, 1, 0, 0), ERR_RANGE),
        ("ACTIVATE params past the end", isa.activate(4, 1, 0, param_idx=PARAMETER_DEPTH - 2), ERR_RANGE),
    ]
    for name, word, code in errors:
        c.add(f"decode error {name}", [isa.nop(), word, isa.signal(1)])
        assert c.model.err is not None and c.model.err.code == code
    c.add("runs again after CTRL.RESET", [isa.wr_ub(0, 1), isa.wait(isa.ACT, isa.LD), isa.rd_ub(0, 1), isa.signal(2)],
          isa.pack_int8([list(range(n))]))

    for i in range(40):
        m, k, nn = rng.randrange(1, 9), rng.randrange(1, 4 * n + 5), rng.randrange(1, 3 * n + 3)
        x = nrng.integers(-128, 128, (m, k))
        w = nrng.integers(-128, 128, (k, nn))
        b = nrng.integers(-(1 << 31), 1 << 31, nn)
        kt = -(-k // n)
        split = rng.randrange(1, kt) if kt > 1 and i % 3 == 0 else None
        prog, data, _ = layer_program(n, x, w, b, relu=bool(i % 2), k_split=split)
        c.add(f"layer {i} m={m} K={k} N={nn}" + (f" split={split}" if split else ""), prog, data)

    nb = 32
    c.add("zero ACC for the requantizer",
          [isa.wr_wmem(0, nb * n), isa.wr_ub(0, 1), isa.wait(isa.WT, isa.LD), isa.wait(isa.MM, isa.LD),
           isa.set_wbase(0), isa.matmul(1, 1, nb, 0, 0), isa.signal(3)],
          [0] * (nb * n * n // 4 + n // 4))
    qrng = np.random.default_rng(11)
    tables = [np.full(n, isa.quant_word(13049303, 31)), np.full(n, isa.quant_word(1 << 23, 23)),
              np.array([isa.quant_word(int(qrng.integers(1 << 23, 1 << 24)), int(qrng.integers(0, 64)))
                        for _ in range(n)])]
    edge = [(1 << 26) - 1, 1 << 26, -(1 << 26), -(1 << 26) - 1, (1 << 31) - 1, -(1 << 31), 10449, 10450, 10451, -10450]
    for j, qrow in enumerate(tables):
        vals = np.concatenate([edge, qrng.integers(-40000, 40000, nb * n // 2),
                               qrng.integers(-(1 << 31), 1 << 31, nb * n)])[:nb * n]
        c.add(f"requantizer table {j}",
              [isa.wr_bias(0, nb), isa.wr_quant(0, nb), isa.wait(isa.ACT, isa.LD),
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
        layers = [dict(w=mdl["w1"], b=mdl["b1"], relu=True, scale=1 / hs),
                  dict(w=mdl["w2"], b=mdl["b2"], relu=True, scale=None)]
        x = quantize(T.downsample(xi[:9]), float(mdl["in_scale"])).astype(np.int64)
        for m in (8, 1):
            cm = compile_mlp(layers, m, n)
            c.add(f"MNIST load m={m}", *cm.load_program())
            c.add(f"MNIST infer m={m}, layers chained through the UB", *cm.infer_program(x[8 - m:8]))

    prng = np.random.default_rng(5)
    c.add("random-program initial state", *isa_progs.init_program(n, prng))
    for i in range(40):
        raw, data = isa_progs.random_program(n, prng)
        c.add(f"random concurrent program {i}", insert_waits(raw, n) + [isa.signal(9)], data)

    # LD held behind a WAIT on a 3,200-cycle MATMUL (operands loaded beforehand)
    # while 1,100 data words arrive at full speed: the DATA FIFO fills and the
    # host's writes stall on waitrequest until MM finishes
    c.add("operands for the backpressure MATMUL",
          [isa.wr_wmem(0, 16 * n), isa.wr_ub(0, 200 * 4), isa.signal(6)],
          isa.pack_int8(nrng.integers(-128, 128, (16 * n, n))) + isa.pack_int8(nrng.integers(-128, 128, (200 * 4, n))))
    entries = 1100 * 4 // n
    c.add("data backpressure behind a WAIT",
          [isa.set_wbase(0), isa.matmul(200, 4, 4, 0, 0), isa.wait(isa.LD, isa.MM),
           isa.wr_ub(1000, entries), isa.wait(isa.ACT, isa.LD), isa.rd_ub(1000 + entries - 4, 4), isa.signal(6)],
          isa.pack_int8(nrng.integers(-128, 128, (entries, n))), full_speed=True)

    c.add("reading an empty OUT sets UNDERFLOW", [isa.signal(5)], underflow=True)
    return c


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--n", type=int, default=8)
    a = ap.parse_args()
    c = build(a.n)
    Path(a.out).write_text("\n".join(c.text) + "\n")
    print(f"{a.out}: {c.count} cases for N={a.n}")


if __name__ == "__main__":
    main()
