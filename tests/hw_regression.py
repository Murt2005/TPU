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
from tpu_host import TPU  # noqa: E402

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
    p.add_argument("--baud", type=int, default=115200)
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

    print("=" * 60)
    if all(results):
        print(f"ALL {len(results)} HARDWARE REGRESSION TESTS PASSED")
        sys.exit(0)
    else:
        print(f"{results.count(False)}/{len(results)} HARDWARE REGRESSION TESTS FAILED")
        sys.exit(1)


if __name__ == "__main__":
    main()
