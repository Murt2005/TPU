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


class Ddr:
    """the HPS's DDR3 as the core sees it: byte-addressed, zero until written.
    the host writes it directly (the ARM's stores; a preload in simulation), not
    through the instruction stream. sparse, in 4 KB pages"""
    PAGE = 4096

    def __init__(self, size=1 << 30):
        self.size = size
        self.pages = {}

    def write(self, address, data):
        """bytes, or an int8 array (written row-major)"""
        if not isinstance(data, (bytes, bytearray)):
            data = np.asarray(data, np.int8).tobytes()
        if address < 0 or address + len(data) > self.size:
            raise ValueError(f"DDR3 write [{address:#x}, {address + len(data):#x}) outside {self.size:#x} bytes")
        done = 0
        while done < len(data):
            page, offset = divmod(address + done, self.PAGE)
            k = min(self.PAGE - offset, len(data) - done)
            self.pages.setdefault(page, bytearray(self.PAGE))[offset:offset + k] = data[done:done + k]
            done += k

    def read(self, address, count):
        out = bytearray(count)
        done = 0
        while done < count:
            page, offset = divmod(address + done, self.PAGE)
            k = min(self.PAGE - offset, count - done)
            if page in self.pages:
                out[done:done + k] = self.pages[page][offset:offset + k]
            done += k
        return bytes(out)


class IsaModel:
    def __init__(self, n=8, wmem_rows=8192, ub_depth=16384, acc_depth=1024,
                 param_depth=256, phase=3, ddr_weights=True, ddr_bytes=1 << 30):
        """ddr_weights: MATMUL wsrc=1 (weights from DDR3) is implemented, as in the
        RTL; without it, ERR_UNIMPL like the rest of phase 5. tile t of a wsrc=1 MATMUL is the
        n*n bytes at DDR3 byte address t*n*n, rows in WMEM order"""
        assert n % 4 == 0, "R = C must be a multiple of 4 (rows pack into whole words)"
        self.n, self.phase, self.ddr_weights = n, phase, ddr_weights
        self.ddr = Ddr(ddr_bytes)
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
                or (name == "MATMUL" and f["wsrc"] and not self.ddr_weights)
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
                               and self._weights_fit(f, wbase)),
            "ACTIVATE": lambda: (f["acc_addr"] + f["n_blocks"] * f["m"] <= self.acc_depth
                                 and (not (f["bias"] or f["rq"])
                                      or f["param_idx"] + f["n_blocks"] <= self.param_depth)
                                 and (f["dst"] != isa.DST_UB
                                      or f["ub_addr"] + f["n_blocks"] * f["m"] <= self.ub_depth)),
        }
        if name in fits and not fits[name]():
            return ERR_RANGE
        return ERR_NONE

    def _weights_fit(self, f, wbase):
        end_tile = wbase + f["n_blocks"] * f["k_tiles"]
        if f["wsrc"]:
            return end_tile * self.n * self.n <= self.ddr.size
        return end_tile * self.n <= self.wmem_rows

    def weight_tile(self, tile, wsrc):
        """tile `tile` of WMEM or DDR3: n x n, row r = K index r"""
        n = self.n
        if wsrc:
            return np.frombuffer(self.ddr.read(tile * n * n, n * n), np.int8).reshape(n, n)
        return self.wmem[tile * n:(tile + 1) * n]

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
                w = self.weight_tile(tile, f["wsrc"]).astype(np.int64)  # row r = K index r
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
