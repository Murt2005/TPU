#!/usr/bin/env python3
"""Hardware regression suite for a real pico2-ice board running tpu_top.

Extends tpu_host.py's single --selftest vector into the full set of cases
tests/tpu_sequencer_tb.sv exercises in simulation (T1-T6), plus int8/int16
boundary cases and a randomized stress run. A pass here means the design
matches simulation across a much wider input space than the happy-path
vector alone, on real silicon rather than just in iverilog.

Usage:
    python3 tests/hw_regression.py --port /dev/cu.usbmodemXXXX
    python3 tests/hw_regression.py --port /dev/cu.usbmodemXXXX --stress-n 500
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
CASES = [
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


def run_case(tpu, name, a, w, bias):
    expected = golden(a, w, bias)
    got = tpu.matmul(a, w, bias)
    passed = np.array_equal(got, expected)
    status = "PASS" if passed else "FAIL"
    print(f"[{status}] {name}")
    if not passed:
        print(f"       got={got.tolist()} expected={expected.tolist()}")
    return passed


def run_reset_roundtrip(tpu):
    tpu.reset()
    return run_case(tpu, "T3b post-reset compute",
                     [[1, 2], [3, 4]], [[4, 5], [2, 3]], [100, 200])


def run_unknown_cmd(tpu):
    try:
        tpu._send_cmd(0xFF)
    except Exception:
        print("[PASS] T4 unknown CMD 0xFF -> STATUS_ERR")
        return True
    print("[FAIL] T4 unknown CMD 0xFF -- expected an error response, got none")
    return False


def run_tiled_stress(tpu, n, seed):
    """Exercises matmul_tiled()'s K/M/N-dim tiling (rtl/accumulator.sv's
    persistent PSUM, driven via RUN's first/last flags) against randomized
    shapes beyond the raw 2x2 hardware tile -- proving the accumulator's
    hardware-side K-reduction matches an un-tiled golden model on real
    silicon, not just in sim (tests/tpu_sequencer_tb.sv Test 7,
    tests/tpu_core_tb.sv Test 8)."""
    rng = np.random.default_rng(seed)
    fails = 0
    for i in range(n):
        m = int(rng.choice([2, 4]))
        k = int(rng.choice([2, 4, 6, 8]))
        ncols = int(rng.choice([2, 4, 6]))
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
        a = rng.integers(-128, 128, size=(2, 2))
        w = rng.integers(-128, 128, size=(2, 2))
        bias = rng.integers(-1000, 1000, size=2)
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
    (degenerate single-frame), 31 (exactly one full frame), 32 and 40
    (multi-frame chains, where the flags byte carries TILE_FIRST/TILE_LAST
    across frames -- the case MNIST's K=144 layer depends on). Goes through
    matmul_tiled(), which is the code path inference actually uses."""
    rng = np.random.default_rng(seed + 2)
    fails = 0
    cases = (1, 3, 31, 32, 40)
    for kt in cases:
        a = rng.integers(-20, 20, size=(2, 2 * kt)).astype(np.int8)
        w = rng.integers(-20, 20, size=(2 * kt, 2)).astype(np.int8)
        bias = rng.integers(-50, 50, size=2).astype(np.int16)
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
        a = rng.integers(-128, 128, size=(2, 2))
        w = rng.integers(-128, 128, size=(2, 2))
        bias = rng.integers(-1000, 1000, size=2)
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
    p.add_argument("--stress-n", type=int, default=200,
                    help="number of randomized matmuls to run (default 200)")
    p.add_argument("--seed", type=int, default=0, help="RNG seed for the stress test")
    args = p.parse_args()

    results = []
    with TPU(args.port, args.baud) as tpu:
        for name, a, w, bias in CASES:
            results.append(run_case(tpu, name, a, w, bias))
        results.append(run_reset_roundtrip(tpu))
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
