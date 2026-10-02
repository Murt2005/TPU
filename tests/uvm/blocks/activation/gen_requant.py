#!/usr/bin/env python3
"""requantizer vectors for activation_test, from tpu.golden.requant (the host reference,
independent of the RTL). usage: gen_requant.py <out.txt>; lines: v(hex32) q(hex32) out(hex8)"""
import sys

import numpy as np

from tpu import golden, isa

rng = np.random.default_rng(7)
edges = np.array([0, 1, -1, 2, -2, 127, -128, 10449, 10450, 10451, -10450, (1 << 26) - 1, 1 << 26,
                  -(1 << 26), -(1 << 26) - 1, (1 << 31) - 1, -(1 << 31)], np.int64)
quants = [(13049303, 31), (1 << 23, 23), (0xFFFFFF, 0), (0xFFFFFF, 63), (0, 10), (1, 1), (1 << 23, 0)]
quants += [(int(rng.integers(0, 1 << 24)), int(rng.integers(0, 64))) for _ in range(60)]

lines = []
for m0, shift in quants:
    v = np.concatenate([edges, rng.integers(-40000, 40000, 150), rng.integers(-(1 << 31), 1 << 31, 150)])
    out = golden.requant(v, np.full(v.shape, m0), np.full(v.shape, shift))
    q = isa.quant_word(m0, shift)
    lines += [f"{int(x) & 0xFFFFFFFF:08x} {q:08x} {int(o) & 0xFF:02x}" for x, o in zip(v, out)]
while len(lines) % 4:
    lines.append(lines[-1])
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
print(f"{sys.argv[1]}: {len(lines)} vectors over {len(quants)} quant words")
