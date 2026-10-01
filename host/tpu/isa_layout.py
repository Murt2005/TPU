"""host-side layout for the instruction-stream core's fixed-stride addressing"""
import numpy as np


def pad_to(a, rows, cols):
    out = np.zeros((rows, cols), a.dtype)
    out[:a.shape[0], :a.shape[1]] = a
    return out


def weight_rows(w, n):
    """K x N int8 weights -> WMEM rows in tile order: block-major, then K-tile,
    then row (top row first). returns (rows, k_tiles, n_blocks)"""
    k, nn = w.shape
    kt, nb = -(-k // n), -(-nn // n)
    wp = pad_to(np.asarray(w, np.int8), kt * n, nb * n)
    tiles = [wp[kk * n:(kk + 1) * n, b * n:(b + 1) * n] for b in range(nb) for kk in range(kt)]
    return np.concatenate(tiles), kt, nb


def ub_entries(x, n):
    """M x K int8 activations -> UB entries, K-chunk-major: chunk k of row m at k*M + m"""
    m, k = x.shape
    kt = -(-k // n)
    xp = pad_to(np.asarray(x, np.int8), m, kt * n)
    return np.concatenate([xp[:, kk * n:(kk + 1) * n] for kk in range(kt)])


def bias_entries(b, n):
    """length-N bias -> one C-wide entry per N-block"""
    nb = -(-len(b) // n)
    bp = np.zeros(nb * n, np.int64)
    bp[:len(b)] = b
    return bp.reshape(nb, n)


def out_rows(words, m, n_blocks, n):
    """ACTIVATE's int32 host output (block-major) -> M x (n_blocks*n) int64"""
    v = np.array([w - (1 << 32) if w & 0x80000000 else w for w in words], np.int64)
    blocks = v.reshape(n_blocks, m, n)
    return np.concatenate(list(blocks), axis=1)
