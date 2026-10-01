"""reference model of the instruction-stream core: executes a program in order
with the spec's exact arithmetic. a correctly WAITed program gives the same
results on the concurrent hardware, so RTL tests compare against this word for word
"""
import numpy as np

from . import golden, isa

# error codes, mirrored in rtl/isa/isa_pkg.sv. checked in this order
ERR_NONE, ERR_OPCODE, ERR_RESERVED, ERR_RANGE, ERR_COMBO, ERR_UNIMPL = 0, 1, 2, 3, 4, 5

class IsaError(Exception):
    def __init__(self, code, seq, word):
        super().__init__(f"error {code} at instruction {seq}: {isa.disasm(word)}")
        self.code, self.seq, self.word = code, seq, word


class IsaModel:
    def __init__(self, n=8, wmem_rows=8192, ub_depth=16384, acc_depth=1024,
                 param_depth=256, phase=3):
        assert n % 4 == 0, "R = C must be a multiple of 4 (rows pack into whole words)"
        self.n, self.phase = n, phase
        self.wmem_rows, self.ub_depth = wmem_rows, ub_depth
        self.acc_depth, self.param_depth = acc_depth, param_depth
        self.wmem = np.zeros((wmem_rows, n), np.int8)
        self.ub = np.zeros((ub_depth, n), np.int8)
        self.acc = np.zeros((acc_depth, n), np.int64)
        self.bias = np.zeros((param_depth, n), np.int64)
        self.quant = np.zeros((param_depth, n), np.int64)
        self.reset()

    def reset(self):
        """CTRL.RESET: memories keep their contents"""
        self.wbase = 0
        self.seq = 0
        self.out = []
        self.done, self.tag = False, 0
        self.err = None

    # -- decode ---------------------------------------------------------------

    def check(self, word, wbase):
        """the error code the dispatcher raises for `word`, or 0"""
        name, f = isa.decode(word)
        if name is None:
            return ERR_OPCODE
        if word & ~isa.field_mask(name) & ((1 << 64) - 1):
            return ERR_RESERVED
        if name == "ACTIVATE" and (f["func"] > 1 or f["dst"] == 3):
            return ERR_RESERVED
        if self.phase < 5 and (
                name in ("RD_DDR_UB", "SET_OBASE")
                or (name == "MATMUL" and f["wsrc"])
                or (name == "ACTIVATE" and f["dst"] == isa.DST_DDR)):
            return ERR_UNIMPL
        if self.phase < 2 and name == "ACTIVATE" and f["rq"]:
            return ERR_UNIMPL
        if name == "ACTIVATE" and f["dst"] == isa.DST_UB and not f["rq"]:
            return ERR_COMBO
        n = self.n
        fits = {
            "WR_WMEM": lambda: f["wmem_row"] + f["n_rows"] <= self.wmem_rows,
            "WR_UB": lambda: f["ub_addr"] + f["n"] <= self.ub_depth,
            "RD_UB": lambda: f["ub_addr"] + f["n"] <= self.ub_depth,
            "WR_BIAS": lambda: f["param_idx"] + f["n"] <= self.param_depth,
            "WR_QUANT": lambda: f["param_idx"] + f["n"] <= self.param_depth,
            "MATMUL": lambda: (f["acc_addr"] + f["n_blocks"] * f["m"] <= self.acc_depth
                               and f["ub_addr"] + f["k_tiles"] * f["m"] <= self.ub_depth
                               and (wbase + f["n_blocks"] * f["k_tiles"]) * n <= self.wmem_rows),
            "ACTIVATE": lambda: (f["acc_addr"] + f["n_blocks"] * f["m"] <= self.acc_depth
                                 and (not (f["bias"] or f["rq"])
                                      or f["param_idx"] + f["n_blocks"] <= self.param_depth)
                                 and (f["dst"] != isa.DST_UB
                                      or f["ub_addr"] + f["n_blocks"] * f["m"] <= self.ub_depth)),
        }
        if name in fits and not fits[name]():
            return ERR_RANGE
        return ERR_NONE

    # -- execute --------------------------------------------------------------

    def run(self, program, data=()):
        """execute instruction words, consuming 32-bit data words in order. stops
        at the first decode error (recorded in self.err). returns the out words
        this run produced, as a host draining the out FIFO would see them"""
        data = list(data)
        pos = 0
        first_out = len(self.out)

        def take(k):
            nonlocal pos
            if pos + k > len(data):
                raise RuntimeError("program needs more data words than were supplied")
            words = data[pos:pos + k]
            pos += k
            return words

        for word in program:
            code = self.check(word, self.wbase)
            if code:
                self.err = IsaError(code, self.seq, word)
                break
            self.seq += 1
            name, f = isa.decode(word)
            getattr(self, "_" + name.lower())(f, take)
        self.data_left = len(data) - pos
        return self.out[first_out:]

    def _int8_rows(self, take, count, width):
        per_row = -(-width // 4)
        rows = []
        for _ in range(count):
            rows.append(isa.unpack_int8(take(per_row), width))
        return np.array(rows, np.int8).reshape(count, width)

    def _nop(self, f, take):
        pass

    def _wr_wmem(self, f, take):
        r = f["wmem_row"]
        self.wmem[r:r + f["n_rows"]] = self._int8_rows(take, f["n_rows"], self.n)

    def _wr_ub(self, f, take):
        a = f["ub_addr"]
        self.ub[a:a + f["n"]] = self._int8_rows(take, f["n"], self.n)

    def _wr_bias(self, f, take):
        p = f["param_idx"]
        vals = [isa.to_int32(w) for w in take(f["n"] * self.n)]
        self.bias[p:p + f["n"]] = np.array(vals, np.int64).reshape(f["n"], self.n)

    def _wr_quant(self, f, take):
        p = f["param_idx"]
        self.quant[p:p + f["n"]] = np.array(take(f["n"] * self.n), np.int64).reshape(f["n"], self.n)

    def _set_wbase(self, f, take):
        self.wbase = f["wbase"]

    @staticmethod
    def _wrap32(x):
        return ((x + (1 << 31)) % (1 << 32)) - (1 << 31)

    def _matmul(self, f, take):
        n, m, kt, nb = self.n, f["m"], f["k_tiles"], f["n_blocks"]
        for b in range(nb):
            for k in range(kt):
                tile = self.wbase + b * kt + k
                w = self.wmem[tile * n:(tile + 1) * n].astype(np.int64)  # row r = K index r
                x = self.ub[f["ub_addr"] + k * m:f["ub_addr"] + (k + 1) * m].astype(np.int64)
                rows = slice(f["acc_addr"] + b * m, f["acc_addr"] + (b + 1) * m)
                psum = x @ w
                if k == 0 and not f["acc"]:
                    self.acc[rows] = self._wrap32(psum)
                else:
                    self.acc[rows] = self._wrap32(self.acc[rows] + psum)
        self.wbase += nb * kt

    def _activate(self, f, take):
        m, nb = f["m"], f["n_blocks"]
        for b in range(nb):
            v = self.acc[f["acc_addr"] + b * m:f["acc_addr"] + (b + 1) * m].copy()
            if f["bias"]:
                v = self._wrap32(v + self.bias[f["param_idx"] + b])
            if f["func"] == isa.FUNC_RELU:
                v = np.maximum(v, 0)
            if f["rq"]:
                q = self.quant[f["param_idx"] + b]
                v = golden.requant(v, q & 0xFFFFFF, (q >> 24) & 0x3F)
            if f["dst"] == isa.DST_UB:
                a = f["ub_addr"] + b * m
                self.ub[a:a + m] = v.astype(np.int8)
            elif f["rq"]:
                self.out += isa.pack_int8(v)
            else:
                for row in v:
                    self.out += isa.pack_int32(row)

    def _rd_ub(self, f, take):
        rows = self.ub[f["ub_addr"]:f["ub_addr"] + f["n"]]
        self.out += isa.pack_int8(rows)

    def _wait(self, f, take):
        pass  # in-order execution already satisfies every WAIT

    def _signal(self, f, take):
        self.done, self.tag = True, f["tag"]
