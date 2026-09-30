"""Command-line interface for the TPU host driver (`python3 -m tpu`,
`tpu-host`, or `python3 tpu_host.py`).

Host-side driver for the UART command protocol implemented by
rtl/core/tpu_sequencer.sv. Talks to one ARRAY_ROWS x NUM_COLS systolic array
(rows/cols/m_tile below, matching what the bitstream was built with --
boards/pico2-ice/fpga/Makefile's ARRAY_ROWS/NUM_COLS/M_TILE): load an int8 weight matrix and
an int8 activation matrix, optionally a per-column int16 bias, then RUN to
get back Y = ReLU(A @ W + bias) as an (m_tile x cols) int16 matrix.

Protocol (8-N-1, host-initiates everything -- see rtl/core/tpu_sequencer.sv).
All payload sizes derive from the array shape: W_BYTES = rows*cols,
A_BYTES = m_tile*rows, B_BYTES = psum_bytes*cols,
RESULT_BYTES = psum_bytes*m_tile*cols  (psum_bytes = PSUM_WIDTH/8, default 2)
(the LEN values shown are for the default 2x2/M_TILE=2 shape):

    Host -> FPGA:  [CMD][LEN][payload[LEN]]
    FPGA -> Host:  [STATUS][LEN][payload[LEN]]   (STATUS: 0xAA=OK, 0xFF=ERR)

    0x01 LOAD_WEIGHTS  LEN=W_BYTES(4)  int8, rows bottom-first, row-major within
    0x02 LOAD_BIAS     LEN=B_BYTES(4)  per-column signed LE, psum_bytes each
    0x03 LOAD_ACT      LEN=A_BYTES(4)  int8, row-major
    0x04 RUN           LEN=0  -> RESULT_BYTES(8) signed LE, row-major
               or       LEN=1  [flags] -- K-tiling variant, see TPU.run()
    0x05 RESET         LEN=0
    0x06 RUN_TILE      LEN=1+W_BYTES+A_BYTES(9)  [flags, w bytes, a bytes] --
                              LOAD_WEIGHTS+LOAD_ACT+RUN folded into one
                              round trip; weights in NATURAL row-major order
                              (no bottom-first reorder on the wire), response
                              identical to RUN's. See TPU.run_tile().
    0x07 STREAM_RUN    LEN=2+(W_BYTES+A_BYTES)*K  [flags, K_TILES, tiles...]
                              -- a whole K-run (up to max_stream_tiles) in
                              ONE round trip, accumulated tile-by-tile in
                              the datapath. flags[0]=TILE_FIRST applies to
                              the frame's first tile, flags[1]=TILE_LAST to
                              its last, so longer K-runs span multiple
                              frames. Response: result bytes on a TILE_LAST
                              frame, else a bare ACK. See TPU.stream_run().

Firmware commands (TPU_LINK_SPI firmware only -- boards/pico2-ice/firmware/tpu_tile.c
captures these off the CDC stream; the FPGA never sees them, and firmware
without support forwards them to the FPGA, which rejects the unknown CMD):

    0xF0 FW_MATMUL     LEN=9  [M:u16][K:u16][N:u16][rows][cols][m_tile],
                              then RAW bulk (un-LEN-framed): W (K*N int8
                              row-major), bias (N int16 LE), A (M*K int8
                              row-major), 1 checksum byte (sum mod 256).
                              The RP2350 runs matmul_tiled()'s whole tiling
                              loop against the FPGA locally and answers
                              [0xAA][0x00] + 2*M*N RAW result bytes (int16
                              LE row-major) -- one USB round trip per layer
                              instead of one per tile frame.
    0xF1 FW_PROBE      LEN=0  -> [0xAA][0x02]['T'][version] if the firmware
                              supports FW_MATMUL. See TPU._probe_offload().
"""
import argparse
import sys

import numpy as np

from . import golden
from .driver import TPU
from .protocol import DEFAULT_BAUD


# -- golden self-test -----------------------------------------------------
# Exact vectors from tests/sv/tpu_sequencer_tb.sv "Test 1": W=[[4,5],[2,3]],
# A=[[1,2],[3,4]], bias=[100,200] -> ReLU(A@W + bias) = [[108,211],[120,227]].
# Already verified bit-for-bit in simulation; running it against real
# hardware is a datapath smoke test, not a numerics test.
SELFTEST_W = np.array([[4, 5], [2, 3]], dtype=np.int8)
SELFTEST_A = np.array([[1, 2], [3, 4]], dtype=np.int8)
SELFTEST_BIAS = np.array([100, 200], dtype=np.int16)
SELFTEST_EXPECTED = np.array([[108, 211], [120, 227]], dtype=np.int16)


def selftest(tpu):
    if (tpu.rows, tpu.cols, tpu.m_tile) == (2, 2, 2):
        w, a, b, expected = SELFTEST_W, SELFTEST_A, SELFTEST_BIAS, SELFTEST_EXPECTED
    else:
        # Non-default shape: no hand-verified simulation goldens, so use
        # seeded-random vectors checked against the same numpy math the
        # RTL testbenches compute their expectations with.
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
    """Parse '1,2,3,4' into a flat int list; reshaped against the array
    shape (--rows/--cols/--m-tile) in main()."""
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
