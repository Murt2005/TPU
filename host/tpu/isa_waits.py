"""WAIT coverage for instruction-stream programs: which memory ranges each engine
touches, a checker that finds cross-engine hazards no WAIT orders, and a pass
that inserts the minimal WAITs. only WT -> MM through the tile buffer is
interlocked in hardware; everything else needs a WAIT (spec section 7)"""
from . import isa

ENGINES = (isa.LD, isa.WT, isa.MM, isa.ACT)


def accesses(word, wbase, n):
    """[(engine, reads, writes)] for one instruction, and WT's WBASE after it.
    reads/writes are lists of (memory, lo, hi) half-open ranges"""
    name, f = isa.decode(word)
    if name in ("NOP", "WAIT", "SIGNAL"):
        return [], wbase
    if name == "WR_WMEM":
        return [(isa.LD, [], [("WMEM", f["wmem_row"], f["wmem_row"] + f["n_rows"])])], wbase
    if name == "WR_UB":
        return [(isa.LD, [], [("UB", f["ub_addr"], f["ub_addr"] + f["n"])])], wbase
    if name == "WR_BIAS":
        return [(isa.LD, [], [("BIAS", f["param_idx"], f["param_idx"] + f["n"])])], wbase
    if name == "WR_QUANT":
        return [(isa.LD, [], [("QUANT", f["param_idx"], f["param_idx"] + f["n"])])], wbase
    if name == "SET_WBASE":
        return [(isa.WT, [], [])], f["wbase"]
    if name == "MATMUL":
        tiles = f["n_blocks"] * f["k_tiles"]
        acc = ("ACC", f["acc_addr"], f["acc_addr"] + f["n_blocks"] * f["m"])
        if f["wsrc"]:   # DDR3 bytes; the host's own writes to DDR3 happen before the program
            wt = (isa.WT, [("DDR", wbase * n * n, (wbase + tiles) * n * n)], [])
        else:
            wt = (isa.WT, [("WMEM", wbase * n, (wbase + tiles) * n)], [])
        mm = (isa.MM, [("UB", f["ub_addr"], f["ub_addr"] + f["k_tiles"] * f["m"]), acc], [acc])
        return [wt, mm], wbase + tiles
    if name == "ACTIVATE":
        rows = f["n_blocks"] * f["m"]
        reads = [("ACC", f["acc_addr"], f["acc_addr"] + rows)]
        if f["bias"]:
            reads.append(("BIAS", f["param_idx"], f["param_idx"] + f["n_blocks"]))
        if f["rq"]:
            reads.append(("QUANT", f["param_idx"], f["param_idx"] + f["n_blocks"]))
        writes = [("UB", f["ub_addr"], f["ub_addr"] + rows)] if f["dst"] == isa.DST_UB else []
        return [(isa.ACT, reads, writes)], wbase
    if name == "RD_UB":
        return [(isa.ACT, [("UB", f["ub_addr"], f["ub_addr"] + f["n"])], [])], wbase
    raise ValueError(f"no access model for {name}")


def _conflict(a, b):
    """True when two (reads, writes) access sets need ordering"""
    (ra, wa), (rb, wb) = a, b

    def hit(x, y):
        return any(m1 == m2 and lo1 < hi2 and lo2 < hi1
                   for m1, lo1, hi1 in x for m2, lo2, hi2 in y)
    return hit(wa, rb) or hit(wa, wb) or hit(ra, wb)


class _Tracker:
    def __init__(self, n):
        self.n = n
        self.wbase = 0
        self.parts = {e: [] for e in ENGINES}         # (instr index, reads, writes)
        self.cover = {e: {e2: -1 for e2 in ENGINES} for e in ENGINES}

    def needs(self, engine, reads, writes):
        """engines whose earlier, unordered parts conflict with this one"""
        out = []
        for e2 in ENGINES:
            if e2 == engine:
                continue
            for idx, r2, w2 in self.parts[e2]:
                if idx > self.cover[engine][e2] and _conflict((reads, writes), (r2, w2)):
                    out.append((e2, idx))
                    break
        return out

    def wait(self, target, mask, upto):
        for e2 in ENGINES:
            if mask >> e2 & 1:
                self.cover[target][e2] = upto

    def fence(self, upto):
        for e in ENGINES:
            for e2 in ENGINES:
                self.cover[e][e2] = upto


def check_waits(program, n):
    """[(instruction index, engine, earlier instruction index)] for every
    cross-engine hazard that no WAIT or SIGNAL orders"""
    t = _Tracker(n)
    hazards = []
    for i, word in enumerate(program):
        name, f = isa.decode(word)
        if name == "WAIT":
            t.wait(f["target"], f["mask"], i)
            continue
        if name == "SIGNAL":
            t.fence(i)
            continue
        parts, t.wbase = accesses(word, t.wbase, n)
        for engine, reads, writes in parts:
            for e2, idx in t.needs(engine, reads, writes):
                hazards.append((i, engine, idx))
        for engine, reads, writes in parts:
            t.parts[engine].append((i, reads, writes))
    return hazards


def insert_waits(program, n):
    """the program with the minimal WAITs inserted before each instruction"""
    t = _Tracker(n)
    out = []
    for word in program:
        name, f = isa.decode(word)
        if name == "SIGNAL":
            out.append(word)
            t.fence(len(out) - 1)
            continue
        parts, new_wbase = accesses(word, t.wbase, n)
        for engine, reads, writes in parts:
            needed = 0
            for e2, _ in t.needs(engine, reads, writes):
                needed |= 1 << e2
            if needed:
                out.append(isa.encode("WAIT", target=engine, mask=needed))
                t.wait(engine, needed, len(out) - 1)
        out.append(word)
        t.wbase = new_wbase
        for engine, reads, writes in parts:
            t.parts[engine].append((len(out) - 1, reads, writes))
    return out
