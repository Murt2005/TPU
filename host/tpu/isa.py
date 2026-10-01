"""64-bit instruction encoding for the instruction-stream core (DE1-SoC spec).

one field table drives the encoder, the decoder and the reserved-bit check, so
they can't disagree. counts are given naturally and stored minus one
"""

OP = {
    "NOP": 0x00, "WR_WMEM": 0x01, "WR_UB": 0x02, "WR_BIAS": 0x03, "WR_QUANT": 0x04,
    "RD_DDR_UB": 0x05, "SET_WBASE": 0x06, "SET_OBASE": 0x07,
    "MATMUL": 0x10, "ACTIVATE": 0x18, "RD_UB": 0x19, "WAIT": 0x20, "SIGNAL": 0x21,
}
NAME = {v: k for k, v in OP.items()}

# name -> [(field, hi, lo, minus_one)]
FIELDS = {
    "NOP": [],
    "WR_WMEM": [("wmem_row", 47, 32, False), ("n_rows", 15, 0, True)],
    "WR_UB": [("ub_addr", 45, 32, False), ("n", 11, 0, True)],
    "WR_BIAS": [("param_idx", 39, 32, False), ("n", 7, 0, True)],
    "WR_QUANT": [("param_idx", 39, 32, False), ("n", 7, 0, True)],
    "RD_DDR_UB": [("ub_addr", 57, 44, False), ("n", 43, 32, True), ("ddr_addr", 31, 0, False)],
    "SET_WBASE": [("wbase", 31, 0, False)],
    "SET_OBASE": [("obase", 31, 0, False)],
    "MATMUL": [("acc", 57, 57, False), ("wsrc", 56, 56, False), ("m", 55, 48, True),
               ("k_tiles", 47, 36, True), ("n_blocks", 35, 26, True),
               ("acc_addr", 25, 16, False), ("ub_addr", 15, 2, False)],
    "ACTIVATE": [("func", 57, 56, False), ("rq", 55, 55, False), ("dst", 54, 53, False),
                 ("bias", 52, 52, False), ("n_blocks", 51, 42, True), ("m", 41, 34, True),
                 ("acc_addr", 33, 24, False), ("ub_addr", 23, 10, False),
                 ("param_idx", 9, 2, False)],
    "RD_UB": [("ub_addr", 45, 32, False), ("n", 11, 0, True)],
    "WAIT": [("target", 57, 56, False), ("mask", 51, 48, False)],
    "SIGNAL": [("tag", 15, 0, False)],
}

# engines, as numbered by WAIT's target field and on-mask bits
LD, WT, MM, ACT = 0, 1, 2, 3
FUNC_IDENTITY, FUNC_RELU = 0, 1
DST_UB, DST_HOST, DST_DDR = 0, 1, 2


def _mask(hi, lo):
    return ((1 << (hi - lo + 1)) - 1) << lo


def field_mask(name):
    """bits an instruction may legally set, opcode included"""
    m = _mask(63, 58)
    for _, hi, lo, _ in FIELDS[name]:
        m |= _mask(hi, lo)
    return m


def encode(name, **kw):
    word = OP[name] << 58
    for field, hi, lo, minus_one in FIELDS[name]:
        v = kw.pop(field, 1 if minus_one else 0)
        if minus_one:
            v -= 1
        width = hi - lo + 1
        if not 0 <= v < (1 << width):
            raise ValueError(f"{name}.{field}={v + minus_one} doesn't fit {width} bits")
        word |= v << lo
    if kw:
        raise ValueError(f"{name}: unknown fields {sorted(kw)}")
    return word


def decode(word):
    """(name, fields) or (None, {}) for an unknown opcode"""
    name = NAME.get(word >> 58)
    if name is None:
        return None, {}
    out = {}
    for field, hi, lo, minus_one in FIELDS[name]:
        out[field] = ((word >> lo) & ((1 << (hi - lo + 1)) - 1)) + minus_one
    return name, out


def disasm(word):
    name, f = decode(word)
    if name is None:
        return f"?? 0x{word:016X}"
    return name + "".join(f" {k}={v}" for k, v in f.items())


# convenience constructors, the spec's mnemonics
def nop():
    return encode("NOP")


def wr_wmem(wmem_row, n_rows):
    return encode("WR_WMEM", wmem_row=wmem_row, n_rows=n_rows)


def wr_ub(ub_addr, n):
    return encode("WR_UB", ub_addr=ub_addr, n=n)


def wr_bias(param_idx, n):
    return encode("WR_BIAS", param_idx=param_idx, n=n)


def wr_quant(param_idx, n):
    return encode("WR_QUANT", param_idx=param_idx, n=n)


def set_wbase(wbase):
    return encode("SET_WBASE", wbase=wbase)


def matmul(m, k_tiles, n_blocks, acc_addr, ub_addr, accumulate=False, wsrc=0):
    return encode("MATMUL", acc=int(accumulate), wsrc=wsrc, m=m, k_tiles=k_tiles,
                  n_blocks=n_blocks, acc_addr=acc_addr, ub_addr=ub_addr)


def activate(n_blocks, m, acc_addr, func=FUNC_RELU, rq=False, dst=DST_HOST, bias=True,
             ub_addr=0, param_idx=0):
    return encode("ACTIVATE", func=func, rq=int(rq), dst=dst, bias=int(bias),
                  n_blocks=n_blocks, m=m, acc_addr=acc_addr, ub_addr=ub_addr,
                  param_idx=param_idx)


def rd_ub(ub_addr, n):
    return encode("RD_UB", ub_addr=ub_addr, n=n)


def wait(target, *on):
    mask = 0
    for e in on:
        mask |= 1 << e
    return encode("WAIT", target=target, mask=mask)


def signal(tag):
    return encode("SIGNAL", tag=tag)


# -- data words: int8 groups little-endian, 4 per word; int32 one per word --

def pack_int8(rows):
    """rows of int8 -> 32-bit words, each row padded to a whole word"""
    words = []
    for row in rows:
        b = [int(v) & 0xFF for v in row]
        b += [0] * (-len(b) % 4)
        for i in range(0, len(b), 4):
            words.append(b[i] | b[i + 1] << 8 | b[i + 2] << 16 | b[i + 3] << 24)
    return words


def pack_int32(values):
    return [int(v) & 0xFFFFFFFF for v in values]


def to_int32(word):
    return word - (1 << 32) if word & 0x80000000 else word


def unpack_int8(words, n):
    out = []
    for w in words:
        for s in range(4):
            v = (w >> (8 * s)) & 0xFF
            out.append(v - 256 if v & 0x80 else v)
    return out[:n]


def quant_params(m):
    """real scale M -> (M0, shift) with M ~ M0 / 2^shift and M0 in [2^23, 2^24)"""
    import math
    if not m >= 2 ** -19:
        raise ValueError(f"requant scale {m} below 2^-19: pre-saturation would no longer be exact")
    shift = 23 - math.floor(math.log2(m))
    m0 = round(m * 2 ** shift)
    if m0 == 1 << 24:
        m0 //= 2
        shift -= 1
    if not 0 <= shift <= 63:
        raise ValueError(f"requant scale {m} needs shift {shift}, outside 0..63")
    return m0, shift


def quant_word(m0, shift):
    return (shift & 0x3F) << 24 | (m0 & 0xFFFFFF)
