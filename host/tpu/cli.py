"""command-line interface for the TPU host driver (python3 -m tpu, tpu-host, or
tpu_host.py). the wire protocol is specified in docs/protocol.md"""
import argparse
import sys

import numpy as np

from . import golden
from .driver import TPU
from .protocol import DEFAULT_BAUD


# test 1 of tests/sv/tpu_sequencer_tb.sv: a datapath smoke test, not a numerics test
SELFTEST_W = np.array([[4, 5], [2, 3]], dtype=np.int8)
SELFTEST_A = np.array([[1, 2], [3, 4]], dtype=np.int8)
SELFTEST_BIAS = np.array([100, 200], dtype=np.int16)
SELFTEST_EXPECTED = np.array([[108, 211], [120, 227]], dtype=np.int16)


def selftest(tpu):
    if (tpu.rows, tpu.cols, tpu.m_tile) == (2, 2, 2):
        w, a, b, expected = SELFTEST_W, SELFTEST_A, SELFTEST_BIAS, SELFTEST_EXPECTED
    else:
        # no hand-checked vectors at other shapes: seeded random against the reference
        rng = np.random.default_rng(0)
        w = rng.integers(-9, 10, size=(tpu.rows, tpu.cols), dtype=np.int8)
        a = rng.integers(-9, 10, size=(tpu.m_tile, tpu.rows), dtype=np.int8)
        b = rng.integers(-50, 51, size=tpu.cols).astype(np.int16)
        expected = golden.matmul(a, w, b, psum_width=tpu.psum_width)
    print(f"Sending W={w.tolist()} A={a.tolist()} bias={b.tolist()}")
    got = tpu.matmul(a, w, b)
    print(f"Got:      {got.tolist()}")
    print(f"Expected: {expected.tolist()}")
    if np.array_equal(got, expected):
        print("PASS -- hardware datapath matches expected values")
        return True
    print("FAIL -- hardware result does not match expected values")
    return False


def parse_ints(s):
    try:
        return [int(x) for x in s.split(",")]
    except ValueError:
        raise argparse.ArgumentTypeError("expected comma-separated ints, e.g. 1,2,3,4")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", required=True,
                    help="serial device for the board's 'iCE40 UART' USB-CDC port "
                         "(not 'RP2040 logs' -- the board exposes two ports with "
                         "identical descriptions on macOS/pyserial; if unsure, try "
                         "the higher-numbered /dev/cu.usbmodemN one first). "
                         "For --link hps this is the mmap device, normally /dev/mem")
    p.add_argument("--baud", type=int, default=DEFAULT_BAUD,
                    help=f"must match CLK_FREQ/BAUD_RATE the bitstream was built with "
                         f"(default {DEFAULT_BAUD})")
    p.add_argument("--rows", type=int, default=2,
                    help="ARRAY_ROWS the bitstream was built with (default 2)")
    p.add_argument("--cols", type=int, default=2,
                    help="NUM_COLS the bitstream was built with (default 2)")
    p.add_argument("--m-tile", type=int, default=None,
                    help="M_TILE the bitstream was built with (default: same as --rows)")
    p.add_argument("--psum-width", type=int, default=16, choices=(8, 16, 32, 64),
                    help="PSUM_WIDTH the bitstream was built with (default 16). "
                         "Sets the wire bytes per bias/result element; a "
                         "mismatch is a frame-length error, not a wrong answer")
    p.add_argument("--link", choices=("uart", "spi", "hps", "sim"), default="uart",
                    help="host-link PHY the board is running: uart (default), "
                         "spi (USE_SPI=1 gateware + TPU_LINK_SPI firmware; "
                         "disables UART-era write pacing), or hps (DE1-SoC "
                         "tpu_top_hps gateware, driven over /dev/mem from the "
                         "board's ARM Linux -- run `python3 -m tpu` on the board), "
                         "or sim (Verilator model of tpu_core as a subprocess; "
                         "--port is the binary from `make sim-bridge`)")
    p.add_argument("--selftest", action="store_true",
                    help="run a known-good W/A/bias combo and check against the "
                         "expected result")
    p.add_argument("--weights", type=parse_ints, metavar="w00,w01,...",
                    help="int8 (rows x cols) weight matrix, flat row-major")
    p.add_argument("--activations", type=parse_ints, metavar="a00,a01,...",
                    help="int8 (m_tile x rows) activation matrix, flat row-major")
    p.add_argument("--bias", type=parse_ints, metavar="b0,b1,...", default=None,
                    help="int16 per-column bias, cols values (default all zero)")
    p.add_argument("--reset", action="store_true",
                    help="pulse the on-chip reset before doing anything else")
    args = p.parse_args()

    with TPU(args.port, args.baud, rows=args.rows, cols=args.cols,
             m_tile=args.m_tile, link=args.link,
             psum_width=args.psum_width) as tpu:
        if args.reset:
            tpu.reset()
            print("Reset OK")

        if args.selftest:
            sys.exit(0 if selftest(tpu) else 1)

        if args.weights is None or args.activations is None:
            p.error("--weights and --activations are required unless --selftest is given")

        if len(args.weights) != tpu.rows * tpu.cols:
            p.error(f"--weights needs {tpu.rows * tpu.cols} values for a "
                    f"{tpu.rows}x{tpu.cols} array")
        if len(args.activations) != tpu.m_tile * tpu.rows:
            p.error(f"--activations needs {tpu.m_tile * tpu.rows} values for "
                    f"m_tile={tpu.m_tile}, rows={tpu.rows}")
        w = np.array(args.weights, dtype=np.int8).reshape(tpu.rows, tpu.cols)
        a = np.array(args.activations, dtype=np.int8).reshape(tpu.m_tile, tpu.rows)
        b = None
        if args.bias is not None:
            if len(args.bias) != tpu.cols:
                p.error(f"--bias needs {tpu.cols} values")
            b = np.array(args.bias, dtype=np.int16)

        result = tpu.matmul(a, w, b)
        print(f"W={w.tolist()} A={a.tolist()} "
              f"bias={(b.tolist() if b is not None else [0] * tpu.cols)}")
        print(f"Y = ReLU(A @ W + bias) =\n{result}")


if __name__ == "__main__":
    main()
