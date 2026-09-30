"""Reference model of the TPU datapath's numerics -- the one copy.

The hardware computes int8 x int8 products, sums them exactly, adds a bias,
then keeps the low PSUM_WIDTH bits: the accumulator does not saturate, it
wraps. ReLU (unless bypassed) is applied after that truncation. Every value
the pipeline produces along the way fits in int64, so truncating once at the
end gives the identical bit pattern to truncating after every add.

Used by tests/hw/hw_regression.py (expected results), the selftest in
cli.py, software/mnist (training-time emulation and the offline backend),
and software/llm (the exact-int8 comparison backend). The C++ bench in
tests/verilator/tb_tpu_top.cpp keeps its own copy of the same arithmetic.
"""
import numpy as np

# PSUM_WIDTH -> the signed integer type it wraps into.
PSUM_INT = {8: np.int8, 16: np.int16, 32: np.int32, 64: np.int64}


def accumulate(a, w, bias=None):
    """Exact A @ W (+ bias) in int64 -- the value before any truncation."""
    r = np.asarray(a, dtype=np.int64) @ np.asarray(w, dtype=np.int64)
    if bias is not None:
        r = r + np.asarray(bias, dtype=np.int64)
    return r


def wrap(x, psum_width=16):
    """Keep the low psum_width bits, signed -- what the accumulator holds."""
    return np.asarray(x).astype(PSUM_INT[psum_width])


def matmul(a, w, bias=None, psum_width=16, relu=True):
    """What the device returns for one matmul: act(wrap(A @ W + bias)).
    relu=False models the flags[2] ACT_BYPASS path."""
    r = wrap(accumulate(a, w, bias), psum_width)
    return (np.maximum(r, 0) if relu else r).astype(PSUM_INT[psum_width])
