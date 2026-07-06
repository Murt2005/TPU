#!/usr/bin/env python3
"""Host-side driver for the UART command protocol implemented by
rtl/tpu_sequencer.sv. Talks to a single 2x2 systolic array: load an int8
weight matrix and an int8 activation matrix, optionally a per-column int16
bias, then RUN to get back Y = ReLU(A @ W + bias) as a 2x2 int16 matrix.

Protocol (8-N-1, host-initiates everything -- see rtl/tpu_sequencer.sv):

    Host -> FPGA:  [CMD][LEN][payload[LEN]]
    FPGA -> Host:  [STATUS][LEN][payload[LEN]]   (STATUS: 0xAA=OK, 0xFF=ERR)

    0x01 LOAD_WEIGHTS  LEN=4  [w10,w11,w00,w01]  int8, bottom row first
    0x02 LOAD_BIAS     LEN=4  [b0_lo,b0_hi,b1_lo,b1_hi]  int16 LE
    0x03 LOAD_ACT      LEN=4  [a00,a01,a10,a11]  int8, row-major
    0x04 RUN           LEN=0  -> [r0c0,r0c1,r1c0,r1c1] int16 LE (8 bytes)
    0x05 RESET         LEN=0
"""
import argparse
import struct
import sys

import numpy as np
import serial

CMD_LOAD_WEIGHTS = 0x01
CMD_LOAD_BIAS = 0x02
CMD_LOAD_ACT = 0x03
CMD_RUN = 0x04
CMD_RESET = 0x05

STATUS_OK = 0xAA
STATUS_ERR = 0xFF

DEFAULT_BAUD = 115200


class TPUError(RuntimeError):
    pass


class TPU:
    """One 2x2 systolic-array TPU core, reachable over a UART link."""

    def __init__(self, port, baud=DEFAULT_BAUD, timeout=2.0):
        self.ser = serial.Serial(port, baud, timeout=timeout)

    def close(self):
        self.ser.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        self.close()

    # -- wire-level helpers --------------------------------------------

    def _read_exact(self, n):
        buf = self.ser.read(n)
        if len(buf) != n:
            raise TPUError(
                f"UART timeout: expected {n} byte(s), got {len(buf)} "
                f"(check baud rate matches CLK_FREQ the bitstream was built "
                f"with, and that the board is running the tpu_top image)"
            )
        return buf

    def _send_cmd(self, cmd, payload=b""):
        self.ser.write(bytes([cmd, len(payload)]) + payload)
        status, length = self._read_exact(2)
        resp = self._read_exact(length) if length else b""
        if status != STATUS_OK:
            raise TPUError(
                f"TPU returned STATUS=0x{status:02X} for CMD=0x{cmd:02X} "
                f"(0xFF = unknown command or framing error)"
            )
        return resp

    # -- protocol commands ------------------------------------------------

    def load_weights(self, w):
        """w: 2x2 array-like, standard row-major [[w00,w01],[w10,w11]],
        int8 signed. Reordered on the wire to bottom-row-first as
        tpu_sequencer.sv expects."""
        w = np.asarray(w, dtype=np.int8)
        if w.shape != (2, 2):
            raise ValueError("weights must be a 2x2 matrix")
        wire = np.array([w[1, 0], w[1, 1], w[0, 0], w[0, 1]], dtype=np.int8)
        self._send_cmd(CMD_LOAD_WEIGHTS, wire.tobytes())

    def load_bias(self, b):
        """b: length-2 array-like, per-output-column int16 bias."""
        b = np.asarray(b, dtype=np.int16)
        if b.shape != (2,):
            raise ValueError("bias must have shape (2,)")
        payload = struct.pack("<hh", int(b[0]), int(b[1]))
        self._send_cmd(CMD_LOAD_BIAS, payload)

    def load_activations(self, a):
        """a: 2x2 array-like, standard row-major [[a00,a01],[a10,a11]],
        int8 signed."""
        a = np.asarray(a, dtype=np.int8)
        if a.shape != (2, 2):
            raise ValueError("activations must be a 2x2 matrix")
        self._send_cmd(CMD_LOAD_ACT, a.tobytes())

    def run(self):
        """Executes ReLU(A @ W + bias) on-chip; returns a 2x2 int16 matrix."""
        payload = self._send_cmd(CMD_RUN)
        if len(payload) != 8:
            raise TPUError(f"RUN response had {len(payload)} data bytes, expected 8")
        r0c0, r0c1, r1c0, r1c1 = struct.unpack("<hhhh", payload)
        return np.array([[r0c0, r0c1], [r1c0, r1c1]], dtype=np.int16)

    def reset(self):
        self._send_cmd(CMD_RESET)

    def matmul(self, a, w, bias=(0, 0)):
        """Convenience wrapper: load activations/weights/bias, then RUN."""
        self.load_activations(a)
        self.load_weights(w)
        self.load_bias(bias)
        return self.run()


# -- golden self-test -----------------------------------------------------
# Exact vectors from tests/tpu_sequencer_tb.sv "Test 1": W=[[4,5],[2,3]],
# A=[[1,2],[3,4]], bias=[100,200] -> ReLU(A@W + bias) = [[108,211],[120,227]].
# Already verified bit-for-bit in simulation; running it against real
# hardware is a datapath smoke test, not a numerics test.
SELFTEST_W = np.array([[4, 5], [2, 3]], dtype=np.int8)
SELFTEST_A = np.array([[1, 2], [3, 4]], dtype=np.int8)
SELFTEST_BIAS = np.array([100, 200], dtype=np.int16)
SELFTEST_EXPECTED = np.array([[108, 211], [120, 227]], dtype=np.int16)


def selftest(tpu):
    print(f"Sending W={SELFTEST_W.tolist()} A={SELFTEST_A.tolist()} "
          f"bias={SELFTEST_BIAS.tolist()}")
    got = tpu.matmul(SELFTEST_A, SELFTEST_W, SELFTEST_BIAS)
    print(f"Got:      {got.tolist()}")
    print(f"Expected: {SELFTEST_EXPECTED.tolist()}")
    if np.array_equal(got, SELFTEST_EXPECTED):
        print("PASS -- hardware datapath matches simulation golden values")
        return True
    print("FAIL -- hardware result does not match simulation golden values")
    return False


def parse_matrix(s):
    """Parse '1,2,3,4' -> [[1,2],[3,4]] for --activations / --weights."""
    vals = [int(x) for x in s.split(",")]
    if len(vals) != 4:
        raise argparse.ArgumentTypeError("expected 4 comma-separated ints, e.g. 1,2,3,4")
    return [[vals[0], vals[1]], [vals[2], vals[3]]]


def parse_bias(s):
    vals = [int(x) for x in s.split(",")]
    if len(vals) != 2:
        raise argparse.ArgumentTypeError("expected 2 comma-separated ints, e.g. 100,200")
    return vals


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", required=True,
                    help="serial device for the board's 'iCE40 UART' USB-CDC port "
                         "(not 'RP2040 logs' -- the board exposes two ports with "
                         "identical descriptions on macOS/pyserial; if unsure, try "
                         "the higher-numbered /dev/cu.usbmodemN one first)")
    p.add_argument("--baud", type=int, default=DEFAULT_BAUD,
                    help=f"must match CLK_FREQ/BAUD_RATE the bitstream was built with "
                         f"(default {DEFAULT_BAUD})")
    p.add_argument("--selftest", action="store_true",
                    help="run the known-good W/A/bias combo and check against the "
                         "simulated golden result")
    p.add_argument("--weights", type=parse_matrix, metavar="w00,w01,w10,w11",
                    help="int8 2x2 weight matrix, row-major")
    p.add_argument("--activations", type=parse_matrix, metavar="a00,a01,a10,a11",
                    help="int8 2x2 activation matrix, row-major")
    p.add_argument("--bias", type=parse_bias, metavar="b0,b1", default=[0, 0],
                    help="int16 per-column bias (default 0,0)")
    p.add_argument("--reset", action="store_true",
                    help="pulse the on-chip reset before doing anything else")
    args = p.parse_args()

    with TPU(args.port, args.baud) as tpu:
        if args.reset:
            tpu.reset()
            print("Reset OK")

        if args.selftest:
            sys.exit(0 if selftest(tpu) else 1)

        if args.weights is None or args.activations is None:
            p.error("--weights and --activations are required unless --selftest is given")

        result = tpu.matmul(args.activations, args.weights, args.bias)
        print(f"W={args.weights} A={args.activations} bias={args.bias}")
        print(f"Y = ReLU(A @ W + bias) =\n{result}")


if __name__ == "__main__":
    main()
