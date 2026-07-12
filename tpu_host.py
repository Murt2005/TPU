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
               or       LEN=1  [flags] -- K-tiling variant, see TPU.run()
    0x05 RESET         LEN=0
    0x06 RUN_TILE      LEN=9  [flags, w00,w01,w10,w11, a00,a01,a10,a11] --
                              LOAD_WEIGHTS+LOAD_ACT+RUN folded into one
                              round trip; weights in NATURAL row-major order
                              (no bottom-first reorder on the wire), response
                              identical to RUN's. See TPU.run_tile().
    0x07 STREAM_RUN    LEN=2+8*K  [flags, K_TILES, tile_0 w+a bytes, ...] --
                              a whole K-run (up to 31 tiles) in ONE round
                              trip, accumulated tile-by-tile in the datapath.
                              flags[0]=TILE_FIRST applies to the frame's
                              first tile, flags[1]=TILE_LAST to its last, so
                              longer K-runs span multiple frames. Response:
                              result bytes on a TILE_LAST frame, else a bare
                              ACK. See TPU.stream_run().
"""
import argparse
import struct
import sys
import time

import numpy as np
import serial

CMD_LOAD_WEIGHTS = 0x01
CMD_LOAD_BIAS = 0x02
CMD_LOAD_ACT = 0x03
CMD_RUN = 0x04
CMD_RESET = 0x05
CMD_RUN_TILE = 0x06
CMD_STREAM_RUN = 0x07

# One STREAM_RUN tile = 2x2 weights + 2x2 acts = 8 payload bytes; the 1-byte
# LEN caps a frame at 255 payload bytes, minus 2 header bytes (flags, K_TILES).
STREAM_TILE_BYTES = 8
MAX_STREAM_TILES = (255 - 2) // STREAM_TILE_BYTES  # 31

# The pico2-ice firmware's stock USB->UART bridge (pico-ice-sdk
# ice_usb_cdc_to_uart0) silently DROPS bytes once the RP2350's 32-deep UART
# TX FIFO is full, and USB delivers a burst far faster than the UART drains
# it -- so any frame longer than the FIFO loses its tail. Pace writes bigger
# than one FIFO's worth down to wire speed (chunks + drain-time sleeps);
# this costs nothing measurable since the UART is the throughput floor
# anyway, and stays correct (just redundant) once the firmware-side fix in
# firmware/main.c (blocking bridge write) is flashed.
BRIDGE_FIFO_BYTES = 32
BRIDGE_CHUNK_BYTES = 28  # a little margin under the FIFO depth

STATUS_OK = 0xAA
STATUS_ERR = 0xFF

# Must match fpga/Makefile's BAUD_RATE (the divider is baked into the
# bitstream at synthesis time). The RP2350 bridge needs no matching change:
# pico-ice-sdk's tud_cdc_line_coding_cb sets uart0's baud to whatever rate
# the host opens the CDC port with. 1M divides the 12 MHz FPGA clock exactly
# (TICKS_PER_BIT = 12, zero baud error).
DEFAULT_BAUD = 1_000_000

# Must match fpga/Makefile's CLK_FREQ (default 12 MHz) and firmware/main.c's
# ice_fpga_init() request -- the clock the RP2350 actually exports to the
# FPGA on real pico2-ice hardware, not iverilog sim's 50 MHz DE1-SoC default.
FPGA_CLK_FREQ = 12_000_000


class TPUError(RuntimeError):
    pass


class TPU:
    """One 2x2 systolic-array TPU core, reachable over a UART link."""

    def __init__(self, port, baud=DEFAULT_BAUD, timeout=2.0):
        self.ser = serial.Serial(port, baud, timeout=timeout)
        # cmd byte -> [call count, wire bytes tx (incl. CMD/LEN header), wire bytes rx]
        # Lets a caller measure exactly how many bytes crossed the wire per command
        # type, to separate UART transmission time from actual RTL execution time
        # (see mnist/infer.py's --timing-breakdown and docs/PERFORMANCE_ANALYSIS.md).
        self.stats = {}

    def close(self):
        self.ser.close()

    def __enter__(self):
        return self

    def __exit__(self, *_exc_info):
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
        wire_tx = bytes([cmd, len(payload)]) + payload
        if len(wire_tx) <= BRIDGE_FIFO_BYTES:
            self.ser.write(wire_tx)
        else:
            # Paced write: never let more than one UART FIFO's worth be in
            # flight ahead of the wire (see BRIDGE_* comment above).
            byte_s = 10 / self.ser.baudrate  # 8N1 = 10 bits/byte
            for i in range(0, len(wire_tx), BRIDGE_CHUNK_BYTES):
                chunk = wire_tx[i:i + BRIDGE_CHUNK_BYTES]
                self.ser.write(chunk)
                if i + BRIDGE_CHUNK_BYTES < len(wire_tx):
                    time.sleep(len(chunk) * byte_s * 1.1)
        status, length = self._read_exact(2)
        resp = self._read_exact(length) if length else b""
        wire_rx = 2 + length
        n, bytes_tx, bytes_rx = self.stats.get(cmd, (0, 0, 0))
        self.stats[cmd] = (n + 1, bytes_tx + len(wire_tx), bytes_rx + wire_rx)
        if status != STATUS_OK:
            raise TPUError(
                f"TPU returned STATUS=0x{status:02X} for CMD=0x{cmd:02X} "
                f"(0xFF = unknown command or framing error)"
            )
        return resp

    def reset_stats(self):
        self.stats = {}

    def uart_wire_seconds(self):
        """Real seconds spent shifting bits across the UART link itself
        (8N1 = 10 bits/byte), computed from every byte actually seen on the
        wire since the last reset_stats(). Independent of CLK_FREQ -- baud
        rate sets real bit time directly, see docs/sequencer_uart_design.md §1/§2."""
        total_bytes = sum(bytes_tx + bytes_rx for _, bytes_tx, bytes_rx in self.stats.values())
        return total_bytes * 10 / self.ser.baudrate

    def estimated_rtl_seconds(self, clk_freq=FPGA_CLK_FREQ):
        """Estimated wall-clock time actually spent inside tpu_core's
        datapath (no UART, no USB) -- RUN costs 21 cycles dispatch-to-result
        (docs/sequencer_uart_design.md §3.3, cycle-accurate from the RTL);
        LOAD_*/RESET just latch a register file and ACK, budgeted at a
        conservative 2 cycles since that path isn't cycle-counted in the docs
        the way RUN is. clk_freq defaults to the 12 MHz this repo's firmware
        exports to the FPGA (firmware/main.c's ice_fpga_init call, must match
        fpga/Makefile's CLK_FREQ)."""
        run_like = (CMD_RUN, CMD_RUN_TILE)  # RUN_TILE unpacks in the same
        # dispatch cycle RUN's flags do, then runs the identical pipeline
        run_calls = sum(self.stats.get(cmd, (0, 0, 0))[0] for cmd in run_like)
        # A STREAM_RUN frame runs one ~21-cycle pass per tile; recover the
        # tile count from the wire bytes (4 header bytes per frame, 8/tile).
        n_sr, tx_sr, _ = self.stats.get(CMD_STREAM_RUN, (0, 0, 0))
        stream_tiles = max(0, tx_sr - 4 * n_sr) // STREAM_TILE_BYTES
        other_calls = sum(n for cmd, (n, _, _) in self.stats.items()
                          if cmd not in run_like + (CMD_STREAM_RUN,))
        cycles = (run_calls + stream_tiles) * 21 + other_calls * 2
        return cycles / clk_freq

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

    def run(self, first=True, last=True):
        """Executes one RUN pass; returns a 2x2 int16 matrix, or None.

        first/last drive the accumulator's K-dim tiling (rtl/accumulator.sv):
        first=True overwrites its persistent running sum with this pass's
        result (start of a new K-reduction); first=False adds to it
        (continuing one). last=True forwards the now-final sum through
        bias/ReLU and returns the usual 8-byte result; last=False leaves it
        in the accumulator for a later pass to add to -- bias/activation
        never fire for that pass, so this returns None rather than a
        result (there isn't one yet). first=last=True (the defaults) is
        the original single-shot 2x2 matmul, sent as LEN=0 for wire
        compatibility with hosts that never send the flags byte.
        """
        if first and last:
            payload = b""
        else:
            flags = (0x01 if first else 0) | (0x02 if last else 0)
            payload = bytes([flags])
        resp = self._send_cmd(CMD_RUN, payload)
        if not last:
            return None
        if len(resp) != 8:
            raise TPUError(f"RUN response had {len(resp)} data bytes, expected 8")
        r0c0, r0c1, r1c0, r1c1 = struct.unpack("<hhhh", resp)
        return np.array([[r0c0, r0c1], [r1c0, r1c1]], dtype=np.int16)

    def run_tile(self, w, a, first=True, last=True):
        """One K-tile pass -- LOAD_WEIGHTS + LOAD_ACT + RUN folded into a
        single CMD_RUN_TILE round trip (3x fewer transactions per tile; see
        docs/SEQUENCER_REDESIGN.md §3.1). w and a are 2x2 int8 row-major;
        unlike load_weights(), the weights go over the wire in natural
        row-major order -- the sequencer does the bottom-first reorder
        internally. first/last have exactly run()'s K-tiling semantics;
        returns the 2x2 int16 result when last=True, else None. Bias is not
        part of the frame -- call load_bias() once per output block."""
        w = np.asarray(w, dtype=np.int8)
        a = np.asarray(a, dtype=np.int8)
        if w.shape != (2, 2):
            raise ValueError("weights must be a 2x2 matrix")
        if a.shape != (2, 2):
            raise ValueError("activations must be a 2x2 matrix")
        flags = (0x01 if first else 0) | (0x02 if last else 0)
        resp = self._send_cmd(CMD_RUN_TILE, bytes([flags]) + w.tobytes() + a.tobytes())
        if not last:
            return None
        if len(resp) != 8:
            raise TPUError(f"RUN_TILE response had {len(resp)} data bytes, expected 8")
        r0c0, r0c1, r1c0, r1c1 = struct.unpack("<hhhh", resp)
        return np.array([[r0c0, r0c1], [r1c0, r1c1]], dtype=np.int16)

    def stream_run(self, w_tiles, a_tiles, first=True, last=True):
        """A whole K-run (or a chunk of one) in a single CMD_STREAM_RUN
        round trip: up to MAX_STREAM_TILES (w, a) tile pairs, accumulated
        tile-by-tile in the datapath (docs/SEQUENCER_REDESIGN.md §3.2).
        Weights go in natural row-major order, like run_tile(). first/last
        apply to the frame's first/last tile respectively, so a K-run longer
        than one frame chains: first=True,last=False / False,False / ... /
        False,last=True. Returns the 2x2 int16 result when last=True, else
        None. Bias is not part of the frame -- load_bias() once per block."""
        if len(w_tiles) != len(a_tiles):
            raise ValueError("need one activation tile per weight tile")
        k_tiles = len(w_tiles)
        if not 1 <= k_tiles <= MAX_STREAM_TILES:
            raise ValueError(f"K_TILES must be 1..{MAX_STREAM_TILES}, got {k_tiles}")
        flags = (0x01 if first else 0) | (0x02 if last else 0)
        payload = bytearray([flags, k_tiles])
        for w, a in zip(w_tiles, a_tiles):
            w = np.asarray(w, dtype=np.int8)
            a = np.asarray(a, dtype=np.int8)
            if w.shape != (2, 2) or a.shape != (2, 2):
                raise ValueError("each tile must be a 2x2 matrix")
            payload += w.tobytes() + a.tobytes()
        resp = self._send_cmd(CMD_STREAM_RUN, bytes(payload))
        if not last:
            return None
        if len(resp) != 8:
            raise TPUError(f"STREAM_RUN response had {len(resp)} data bytes, expected 8")
        r0c0, r0c1, r1c0, r1c1 = struct.unpack("<hhhh", resp)
        return np.array([[r0c0, r0c1], [r1c0, r1c1]], dtype=np.int16)

    def reset(self):
        self._send_cmd(CMD_RESET)

    def matmul(self, a, w, bias=(0, 0)):
        """Convenience wrapper: load activations/weights/bias, then RUN."""
        self.load_activations(a)
        self.load_weights(w)
        self.load_bias(bias)
        return self.run()

    def matmul_tiled(self, a, w, bias=None):
        """Y = ReLU(A @ W + bias) for shapes beyond the raw 2x2 hardware
        tile. a: (M,K) int8 array-like, w: (K,N) int8 array-like, bias:
        (N,) int16 array-like (defaults to zero); M, K, N must all be even.

        Tiles the K dimension into 2-wide weight-reload passes accumulated
        in hardware (rtl/accumulator.sv's persistent PSUM), and the M/N
        dimensions into 2x2 blocks run one at a time. Each (M,N) block's
        whole K-run goes over the wire as CMD_STREAM_RUN frames
        (stream_run()) of up to MAX_STREAM_TILES tiles each -- one round
        trip per frame instead of one (RUN_TILE) or three (legacy) per
        K-tile. Bias/ReLU are applied once per (M,N) block, on that block's
        final K-tile pass, exactly matching a single un-tiled matmul.
        """
        a = np.asarray(a, dtype=np.int8)
        w = np.asarray(w, dtype=np.int8)
        if a.ndim != 2 or w.ndim != 2:
            raise ValueError("a and w must be 2D")
        m, k = a.shape
        k2, n = w.shape
        if k != k2:
            raise ValueError(f"inner dimensions must match: a is {a.shape}, w is {w.shape}")
        if m % 2 or k % 2 or n % 2:
            raise ValueError(f"matmul_tiled requires even M, K, N; got M={m}, K={k}, N={n}")
        bias = np.zeros(n, dtype=np.int16) if bias is None else np.asarray(bias, dtype=np.int16)
        if bias.shape != (n,):
            raise ValueError(f"bias must have shape ({n},), got {bias.shape}")

        out = np.zeros((m, n), dtype=np.int16)
        num_k_tiles = k // 2
        for m0 in range(0, m, 2):
            for n0 in range(0, n, 2):
                self.load_bias(bias[n0:n0 + 2])
                w_tiles = [w[k0:k0 + 2, n0:n0 + 2] for k0 in range(0, k, 2)]
                a_tiles = [a[m0:m0 + 2, k0:k0 + 2] for k0 in range(0, k, 2)]
                result = None
                for c0 in range(0, num_k_tiles, MAX_STREAM_TILES):
                    c1 = min(c0 + MAX_STREAM_TILES, num_k_tiles)
                    result = self.stream_run(w_tiles[c0:c1], a_tiles[c0:c1],
                                             first=(c0 == 0),
                                             last=(c1 == num_k_tiles))
                out[m0:m0 + 2, n0:n0 + 2] = result
        return out


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
