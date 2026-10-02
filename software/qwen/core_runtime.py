"""Phase 3: Qwen's linear layers on the core. The weights sit in DDR3 as
export.py wrote them; each call of a linear layer is one program:

    RD_DDR_UB    the host's int8 input rows (K-chunk-major) into the UB, from DDR3
    SET_WBASE    the matrix's first tile
    per chunk of output blocks (the accumulator holds 1,024 rows, so n_blocks x m <= 1024):
      MATMUL wsrc=1   weights straight from DDR3; WBASE walks on to the next chunk
      SET_OBASE / ACTIVATE dst=DDR, identity, no bias, no requantize: raw int32 out
    SIGNAL

WAITs come from tpu.isa_waits. The host reads the int32 rows back from DDR3 and
dequantizes them (qwen.CoreLinear). DDR3 holds, from `base`: the weight image,
then an input area, then an output area.

With verify=True every call is also computed by qwen.exact_matmul on the same
int8 input and must match word for word. That's the comparison phase 3 rests on:
the host side is the same numpy code, so equal int32 means equal logits.
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "host"))
from qwen import exact_matmul  # noqa: E402
from tpu import isa  # noqa: E402
from tpu.isa_layout import ub_entries  # noqa: E402
from tpu.isa_waits import check_waits, insert_waits  # noqa: E402

ACC_ROWS = 1024              # tpu_core's ACC_DEPTH
UB_ENTRIES = 16384           # UB_DEPTH
RD_DDR_UB_MAX = 4096         # RD_DDR_UB's n field
N_BLOCKS_MAX = 1024          # MATMUL's and ACTIVATE's n_blocks fields


def align(x, a):
    return -(-x // a) * a


class CoreRuntime:
    def __init__(self, dev, host, base, image_bytes, verify=True, advance=1 << 16):
        """dev: tpu.isa_device.IsaDevice. host: export.py's qwen-host.npz.
        base: where the weight image sits in DDR3 (a multiple of 64)"""
        self.dev, self.link, self.host = dev, dev.link, host
        self.n = int(host["n"])
        self.base, self.verify, self.advance = base, verify, advance
        self.inputs = align(base + image_bytes, 1 << 20)
        self.outputs = self.inputs + (1 << 20)
        self.calls = self.mismatches = 0
        self.beats = self.stalls = self.tiles = 0

    def load_image(self, path, chunk=16 << 20):
        with open(path, "rb") as fh:
            offset = 0
            while True:
                data = fh.read(chunk)
                if not data:
                    break
                self.link.ddr_write(self.base + offset, data)
                offset += len(data)
        self.link.flush()

    def program(self, name, m):
        """the program for one call of matrix `name` on m input rows, and its output chunks"""
        n = self.n
        k_tiles, n_blocks = (int(v) for v in self.host[f"{name}.shape"])
        tile = int(self.host[f"{name}.tile"])
        entries = k_tiles * m
        if entries > UB_ENTRIES:
            raise ValueError(f"{name}: {m} rows x {k_tiles} K-tiles don't fit the UB")
        prog = []
        for first in range(0, entries, RD_DDR_UB_MAX):
            count = min(RD_DDR_UB_MAX, entries - first)
            prog.append(isa.rd_ddr_ub(first, count, self.inputs + first * n))
        prog.append(isa.set_wbase(self.base // (n * n) + tile))
        chunks, done, obase = [], 0, self.outputs
        per = min(N_BLOCKS_MAX, ACC_ROWS // m)
        while done < n_blocks:
            nb = min(per, n_blocks - done)
            prog += [isa.matmul(m, k_tiles, nb, 0, 0, wsrc=1), isa.set_obase(obase),
                     isa.activate(nb, m, 0, func=isa.FUNC_IDENTITY, rq=False, bias=False, dst=isa.DST_DDR)]
            chunks.append((done, nb, obase))
            obase += nb * m * n * 4
            done += nb
        prog = insert_waits(prog, n) + [isa.signal(1)]
        assert not check_waits(prog, n)
        return prog, chunks, obase - self.outputs

    def matmul(self, name, xq):
        """int8 rows (m x K) times matrix `name` on the core -> int32 (m x N)"""
        n = self.n
        m, k = xq.shape
        prog, chunks, out_bytes = self.program(name, m)
        self.link.ddr_write(self.inputs, ub_entries(xq, n).astype(np.int8).tobytes())
        self.dev.reset()
        self.dev.run(prog, timeout=600, advance=self.advance)
        perf = self.dev.perf()
        self.beats += perf["mm_beats"]
        self.stalls += perf["mm_wstall"]
        raw = np.frombuffer(self.link.ddr_read(self.outputs, out_bytes), dtype="<i4")
        out = np.empty((m, sum(nb for _, nb, _ in chunks) * n), np.int32)
        for first, nb, obase in chunks:
            o = (obase - self.outputs) // 4
            out[:, first * n:(first + nb) * n] = raw[o:o + nb * m * n].reshape(nb, m, n).transpose(1, 0, 2).reshape(m, nb * n)
        self.tiles += int(np.prod(self.host[f"{name}.shape"]))
        self.calls += 1
        return out

    def attach(self, model):
        """route every CoreLinear of qwen.Qwen(core=True) through the core"""
        names = [(f"layer{i}.{p}", model.layers[i][p]) for i in range(model.layers_n)
                 for p in ("qkv", "o", "gate_up", "down")] + [("head", model.head)]
        for name, lin in names:
            def on_core(xq, wq, name=name):
                got = self.matmul(name, xq)
                if self.verify and not np.array_equal(got, exact_matmul(xq, wq)):
                    self.mismatches += 1
                    raise AssertionError(f"{name}: core int32 != exact_matmul on the same int8 input")
                return got
            lin.matmul = on_core
