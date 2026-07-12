#!/usr/bin/env python3
"""Hardware regression suite for a real pico2-ice board running tpu_top.

Extends tpu_host.py's single --selftest vector into the full set of cases
tests/tpu_sequencer_tb.sv exercises in simulation (T1-T6), plus int8/int16
boundary cases and a randomized stress run. A pass here means the design
matches simulation across a much wider input space than the happy-path
vector alone, on real silicon rather than just in iverilog.

--rows/--cols/--m-tile must match the ARRAY_ROWS/NUM_COLS/M_TILE the flashed
bitstream was built with (fpga/Makefile). At the default 2x2/M_TILE=2 shape
the fixed cases are the exact vectors from tests/tpu_sequencer_tb.sv; at any
other shape the same case *patterns* (zeros, one-hot columns, int8 extremes,
PSUM wraparound) are generated at that shape and checked against the golden
model, mirroring tests/tpu_sequencer_4x2_tb.sv / tpu_sequencer_2x4_tb.sv.

Usage:
    python3 tests/hw_regression.py --port /dev/cu.usbmodemXXXX
    python3 tests/hw_regression.py --port /dev/cu.usbmodemXXXX --stress-n 500
    python3 tests/hw_regression.py --port ... --rows 2 --cols 4 --m-tile 2
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tpu_host import TPU, DEFAULT_BAUD  # noqa: E402

PSUM_WIDTH = 16  # rtl/tpu_top.sv: accumulator + bias adder width (no saturation)


def golden(a, w, bias):
    """Reference model matching the hardware's fixed-width datapath exactly.

    The accumulator/bias sum is a PSUM_WIDTH-bit signed value with silent
    (non-saturating) overflow -- ReLU is applied *after* that truncation, not
    on the mathematically-exact product. This only matters once |A@W + bias|
    exceeds int16 range; every value the pipeline actually produces along the
    way is representable in wider precision, so truncating once at the end
    (rather than after every add) yields the identical bit pattern.
    """
    a = np.asarray(a, dtype=np.int64)
    w = np.asarray(w, dtype=np.int64)
    bias = np.asarray(bias, dtype=np.int64)
    r = a @ w + bias
    r16 = r.astype(np.int16)
    return np.maximum(r16, 0).astype(np.int16)


# Test vectors mirrored from tests/tpu_sequencer_tb.sv Test 1/2/5/6 so a pass
# here means the same cases verified in simulation also hold on real hardware.
# Only valid at the default 2x2/M_TILE=2 shape; see build_cases() for the
# shape-generalized equivalents.
CASES_2X2 = [
    ("T1 happy path",
     [[1, 2], [3, 4]], [[4, 5], [2, 3]], [100, 200]),
    ("T2 zero weights + negative bias -> all zero",
     [[0, 0], [0, 0]], [[0, 0], [0, 0]], [-10, -20]),
    ("T5 negative arithmetic + ReLU clamp",
     [[-1, 1], [2, -2]], [[-1, -2], [-3, -4]], [0, 0]),
    ("T6 identity matrix",
     [[10, 20], [30, 40]], [[1, 0], [0, 1]], [0, 0]),
    ("int8 max positive squared",
     [[127, 127], [127, 127]], [[127, 0], [0, 127]], [0, 0]),
    ("int8 min negative squared",
     [[-128, -128], [-128, -128]], [[-128, 0], [0, -128]], [0, 0]),
    ("mixed extremes -- exercises PSUM_WIDTH overflow wraparound",
     [[127, -128], [-128, 127]], [[-128, 127], [127, -128]], [1000, -1000]),
]


def build_cases(rows, cols, m_tile):
    """The same seven case *patterns* as CASES_2X2, at an arbitrary shape.
    A is (m_tile x rows), W is (rows x cols), bias is (cols,)."""
    if (rows, cols, m_tile) == (2, 2, 2):
        return CASES_2X2
    rng = np.random.default_rng(1234)
    a_rand = rng.integers(1, 9, size=(m_tile, rows)).astype(np.int8)
    w_rand = rng.integers(1, 9, size=(rows, cols)).astype(np.int8)
    b_alt = np.array([100 * (1 if c % 2 == 0 else 2) for c in range(cols)], np.int16)
    # one-hot "selection" weight columns: column c picks A column (c % rows)
    w_sel = np.zeros((rows, cols), dtype=np.int8)
    for c in range(cols):
        w_sel[c % rows, c] = 1
    signs = np.fromfunction(lambda i, j: (-1) ** (i + j), (m_tile, rows)).astype(np.int8)
    wsigns = np.fromfunction(lambda i, j: (-1) ** (i + j), (rows, cols)).astype(np.int8)
    return [
        ("T1 happy path",
         a_rand, w_rand, b_alt),
        ("T2 zero weights + negative bias -> all zero",
         np.zeros((m_tile, rows), np.int8), np.zeros((rows, cols), np.int8),
         np.arange(-10, -10 * (cols + 1), -10, dtype=np.int16)[:cols]),
        ("T5 negative arithmetic + ReLU clamp",
         signs * a_rand, -np.abs(w_rand), np.zeros(cols, np.int16)),
        ("T6 selection matrix (one-hot weight columns)",
         a_rand * 10, w_sel, np.zeros(cols, np.int16)),
        ("int8 max positive squared",
         np.full((m_tile, rows), 127, np.int8), w_sel * 127, np.zeros(cols, np.int16)),
        ("int8 min negative squared",
         np.full((m_tile, rows), -128, np.int8), w_sel * np.int8(-128),
         np.zeros(cols, np.int16)),
        ("mixed extremes -- exercises PSUM_WIDTH overflow wraparound",
         signs * np.int8(127) - (signs < 0), wsigns * np.int8(127) - (wsigns < 0),
         np.array([1000 * (-1) ** c for c in range(cols)], np.int16)),
    ]


def run_case(tpu, name, a, w, bias):
    expected = golden(a, w, bias)
    got = tpu.matmul(a, w, bias)
    passed = np.array_equal(got, expected)
    status = "PASS" if passed else "FAIL"
    print(f"[{status}] {name}")
    if not passed:
        print(f"       got={got.tolist()} expected={expected.tolist()}")
    return passed


def run_reset_roundtrip(tpu, cases):
    tpu.reset()
    name, a, w, bias = cases[0]
    return run_case(tpu, "T3b post-reset compute", a, w, bias)


def run_unknown_cmd(tpu):
    # 0xEE, not 0xFF: 0xFF is CMD_NOP (the SPI read-poll filler), which the
    # sequencer silently ignores in S_IDLE rather than answering STATUS_ERR.
    try:
        tpu._send_cmd(0xEE)
    except Exception:
        print("[PASS] T4 unknown CMD 0xEE -> STATUS_ERR")
        return True
    print("[FAIL] T4 unknown CMD 0xEE -- expected an error response, got none")
    return False


def run_tiled_stress(tpu, n, seed):
    """Exercises matmul_tiled()'s K/M/N-dim tiling (rtl/accumulator.sv's
    persistent PSUM, driven via the STREAM_RUN first/last flags) against
    randomized shapes beyond the raw hardware tile -- proving the
    accumulator's hardware-side K-reduction matches an un-tiled golden model
    on real silicon, not just in sim. Shapes deliberately include
    non-multiples of the tile size to exercise matmul_tiled()'s internal
    zero-padding."""
    rng = np.random.default_rng(seed)
    r, c, mt = tpu.rows, tpu.cols, tpu.m_tile
    m_choices = [1, mt, 2 * mt, 2 * mt + 1]
    k_choices = [r, 2 * r, 3 * r, 3 * r + 1]
    n_choices = [c, 2 * c, 2 * c + 1, 3 * c - 1]
    fails = 0
    for i in range(n):
        m = int(rng.choice(m_choices))
        k = int(rng.choice(k_choices))
        ncols = int(rng.choice(n_choices))
        a = rng.integers(-20, 20, size=(m, k)).astype(np.int8)
        w = rng.integers(-20, 20, size=(k, ncols)).astype(np.int8)
        bias = rng.integers(-50, 50, size=ncols).astype(np.int16)
        expected = golden(a, w, bias)
        got = tpu.matmul_tiled(a, w, bias)
        if not np.array_equal(got, expected):
            fails += 1
            print(f"       [tiled {i}] M={m} K={k} N={ncols} a={a.tolist()} w={w.tolist()} "
                  f"bias={bias.tolist()} got={got.tolist()} expected={expected.tolist()}")
    passed = fails == 0
    status = "PASS" if passed else "FAIL"
    print(f"[{status}] tiled stress: {n - fails}/{n} randomized multi-tile matmuls matched the golden model")
    return passed


def run_tile_equivalence(tpu, n, seed):
    """CMD_RUN_TILE (one frame) must produce bit-identical results to the
    legacy LOAD_WEIGHTS/LOAD_ACT/RUN triple for the same inputs -- both
    against each other and against the golden model. Note run_tile() sends
    weights in natural row-major order (the sequencer reorders internally),
    so this also catches a wire-order regression in either path."""
    rng = np.random.default_rng(seed + 1)
    fails = 0
    for i in range(n):
        a = rng.integers(-128, 128, size=(tpu.m_tile, tpu.rows))
        w = rng.integers(-128, 128, size=(tpu.rows, tpu.cols))
        bias = rng.integers(-1000, 1000, size=tpu.cols)
        legacy = tpu.matmul(a, w, bias)          # loads bias as a side effect...
        via_tile = tpu.run_tile(w, a)            # ...which persists for RUN_TILE
        expected = golden(a, w, bias)
        if not (np.array_equal(legacy, via_tile) and np.array_equal(via_tile, expected)):
            fails += 1
            print(f"       [run_tile {i}] a={a.tolist()} w={w.tolist()} bias={bias.tolist()} "
                  f"legacy={legacy.tolist()} run_tile={via_tile.tolist()} expected={expected.tolist()}")
    passed = fails == 0
    status = "PASS" if passed else "FAIL"
    print(f"[{status}] run_tile equivalence: {n - fails}/{n} RUN_TILE results matched the legacy path + golden model")
    return passed


def run_stream_boundaries(tpu, seed):
    """CMD_STREAM_RUN K-runs at the frame-chunking boundaries: 1 tile
    (degenerate single-frame), max_stream_tiles (exactly one full frame),
    max+1 and max+9 (multi-frame chains, where the flags byte carries
    TILE_FIRST/TILE_LAST across frames -- the case MNIST's K=144 layer
    depends on). Goes through matmul_tiled(), which is the code path
    inference actually uses."""
    rng = np.random.default_rng(seed + 2)
    mst = tpu.max_stream_tiles
    fails = 0
    cases = (1, 3, mst, mst + 1, mst + 9)
    for kt in cases:
        a = rng.integers(-20, 20, size=(tpu.m_tile, tpu.rows * kt)).astype(np.int8)
        w = rng.integers(-20, 20, size=(tpu.rows * kt, tpu.cols)).astype(np.int8)
        bias = rng.integers(-50, 50, size=tpu.cols).astype(np.int16)
        expected = golden(a, w, bias)
        got = tpu.matmul_tiled(a, w, bias)
        if not np.array_equal(got, expected):
            fails += 1
            print(f"       [stream K_TILES={kt}] got={got.tolist()} expected={expected.tolist()}")
    passed = fails == 0
    status = "PASS" if passed else "FAIL"
    print(f"[{status}] stream boundaries: {len(cases) - fails}/{len(cases)} K-runs "
          f"(K_TILES in {cases}) matched the golden model")
    return passed


def run_stress(tpu, n, seed):
    rng = np.random.default_rng(seed)
    fails = 0
    for i in range(n):
        a = rng.integers(-128, 128, size=(tpu.m_tile, tpu.rows))
        w = rng.integers(-128, 128, size=(tpu.rows, tpu.cols))
        bias = rng.integers(-1000, 1000, size=tpu.cols)
        expected = golden(a, w, bias)
        got = tpu.matmul(a, w, bias)
        if not np.array_equal(got, expected):
            fails += 1
            print(f"       [stress {i}] a={a.tolist()} w={w.tolist()} "
                  f"bias={bias.tolist()} got={got.tolist()} expected={expected.tolist()}")
    passed = fails == 0
    status = "PASS" if passed else "FAIL"
    print(f"[{status}] stress: {n - fails}/{n} randomized matmuls matched the golden model")
    return passed


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", required=True, help="serial device for the iCE40 UART CDC port")
    p.add_argument("--baud", type=int, default=DEFAULT_BAUD)
    p.add_argument("--rows", type=int, default=2,
                    help="ARRAY_ROWS the flashed bitstream was built with (default 2)")
    p.add_argument("--cols", type=int, default=2,
                    help="NUM_COLS the flashed bitstream was built with (default 2)")
    p.add_argument("--m-tile", type=int, default=None,
                    help="M_TILE the flashed bitstream was built with (default: --rows)")
    p.add_argument("--stress-n", type=int, default=200,
                    help="number of randomized matmuls to run (default 200)")
    p.add_argument("--seed", type=int, default=0, help="RNG seed for the stress test")
    args = p.parse_args()

    results = []
    with TPU(args.port, args.baud, rows=args.rows, cols=args.cols,
             m_tile=args.m_tile) as tpu:
        cases = build_cases(tpu.rows, tpu.cols, tpu.m_tile)
        for name, a, w, bias in cases:
            results.append(run_case(tpu, name, a, w, bias))
        results.append(run_reset_roundtrip(tpu, cases))
        results.append(run_unknown_cmd(tpu))
        results.append(run_stress(tpu, args.stress_n, args.seed))
        results.append(run_tiled_stress(tpu, min(args.stress_n, 50), args.seed))
        results.append(run_tile_equivalence(tpu, min(args.stress_n, 50), args.seed))
        results.append(run_stream_boundaries(tpu, args.seed))

    print("=" * 60)
    if all(results):
        print(f"ALL {len(results)} HARDWARE REGRESSION TESTS PASSED")
        sys.exit(0)
    else:
        print(f"{results.count(False)}/{len(results)} HARDWARE REGRESSION TESTS FAILED")
        sys.exit(1)


if __name__ == "__main__":
    main()
