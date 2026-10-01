"""reference numerics: exact int8 matmul, wrap to PSUM_WIDTH (the accumulator
doesn't saturate), then ReLU unless bypassed. the one Python copy; the C++
bench keeps its own"""
import numpy as np

PSUM_INT = {8: np.int8, 16: np.int16, 32: np.int32, 64: np.int64}


def accumulate(a, w, bias=None):
    r = np.asarray(a, dtype=np.int64) @ np.asarray(w, dtype=np.int64)
    if bias is not None:
        r = r + np.asarray(bias, dtype=np.int64)
    return r


def wrap(x, psum_width=16):
    return np.asarray(x).astype(PSUM_INT[psum_width])


def matmul(a, w, bias=None, psum_width=16, relu=True):
    """relu=False models the ACT_BYPASS flag"""
    r = wrap(accumulate(a, w, bias), psum_width)
    return (np.maximum(r, 0) if relu else r).astype(PSUM_INT[psum_width])


def requant(v, m0, shift):
    """the requantizer: saturate to 27 bits, multiply by M0, round half up by
    adding 2^(shift-1) before the arithmetic shift, clamp to int8"""
    v = np.clip(np.asarray(v, np.int64), -(1 << 26), (1 << 26) - 1)
    m0 = np.asarray(m0, np.int64)
    shift = np.asarray(shift, np.int64)
    # 27 x 24 bits fits int64; the rounding constant is 0 when shift is 0
    rnd = np.where(shift > 0, np.left_shift(np.int64(1), np.maximum(shift - 1, 0)), 0)
    return np.clip((v * m0 + rnd) >> shift, -128, 127).astype(np.int64)
