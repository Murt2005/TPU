#!/usr/bin/env python3
"""Host-side driver for the UART command protocol implemented by
rtl/tpu_sequencer.sv. Talks to one ARRAY_ROWS x NUM_COLS systolic array
(rows/cols/m_tile below, matching what the bitstream was built with --
fpga/Makefile's ARRAY_ROWS/NUM_COLS/M_TILE): load an int8 weight matrix and
an int8 activation matrix, optionally a per-column int16 bias, then RUN to
get back Y = ReLU(A @ W + bias) as an (m_tile x cols) int16 matrix.

Protocol (8-N-1, host-initiates everything -- see rtl/tpu_sequencer.sv).
All payload sizes derive from the array shape: W_BYTES = rows*cols,
A_BYTES = m_tile*rows, B_BYTES = 2*cols, RESULT_BYTES = 2*m_tile*cols
(the LEN values shown are for the default 2x2/M_TILE=2 shape):

    Host -> FPGA:  [CMD][LEN][payload[LEN]]
    FPGA -> Host:  [STATUS][LEN][payload[LEN]]   (STATUS: 0xAA=OK, 0xFF=ERR)

    0x01 LOAD_WEIGHTS  LEN=W_BYTES(4)  int8, rows bottom-first, row-major within
    0x02 LOAD_BIAS     LEN=B_BYTES(4)  per-column int16 LE
    0x03 LOAD_ACT      LEN=A_BYTES(4)  int8, row-major
    0x04 RUN           LEN=0  -> RESULT_BYTES(8) int16 LE, row-major
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

Firmware commands (TPU_LINK_SPI firmware only -- firmware/tpu_tile.c
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
import struct
import sys
import time

import numpy as np
import serial

# Wire-protocol opcodes / status bytes. These mirror rtl/tpu_pkg.sv, which is
# the canonical (RTL) side of the host<->FPGA contract -- keep the two in sync.
CMD_LOAD_WEIGHTS = 0x01
CMD_LOAD_BIAS = 0x02
CMD_LOAD_ACT = 0x03
CMD_RUN = 0x04
CMD_RESET = 0x05
CMD_RUN_TILE = 0x06
CMD_STREAM_RUN = 0x07

FW_MATMUL = 0xF0
FW_PROBE = 0xF1
FW_PROBE_MAGIC = b"T\x01"  # firmware/tpu_tile.c's FW_MAGIC + FW_VERSION

# One STREAM_RUN tile = rows*cols weight + m_tile*rows act payload bytes; the
# 1-byte LEN caps a frame at 255 payload bytes, minus 2 header bytes (flags,
# K_TILES). Both are shape-dependent, computed per TPU instance in __init__
# (self.stream_tile_bytes / self.max_stream_tiles: 8 and 31 at 2x2/M_TILE=2,
# 12 and 21 at the 2x4/M_TILE=2 hardware shape).

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

# link="spi" (TPU_LINK_SPI firmware + USE_SPI=1 gateware): the CDC port is
# bridged to the RP2350<->iCE40 SPI bus instead of uart0. Two host-side
# differences, both handled by TPU(link=...):
#  - no write pacing: the SPI bridge reads the CDC FIFO under TinyUSB flow
#    control (no 32-byte UART FIFO to overrun), so the BRIDGE_* sleeps
#    below would just emulate UART-era latency for nothing;
#  - wire-time accounting: SPI moves 8 bits/byte at the bridge's write
#    clock (firmware/main.c TPU_SPI_WRITE_HZ; reads are slower and add
#    poll filler, so uart_wire_seconds() is a lower bound there).
SPI_WIRE_HZ = 4_000_000

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
    """One systolic-array TPU core, reachable over a UART link.

    rows/cols/m_tile must match the ARRAY_ROWS/NUM_COLS/M_TILE the bitstream
    was built with (fpga/Makefile) -- the wire protocol's payload sizes are
    synthesis-time constants on the FPGA side, so a shape mismatch shows up
    as STATUS_ERR or a UART timeout, not a wrong answer.
    """

    def __init__(self, port, baud=DEFAULT_BAUD, timeout=2.0,
                 rows=2, cols=2, m_tile=None, probe=True, link="uart",
                 offload=True):
        self.rows = rows            # ARRAY_ROWS: K-tile depth
        self.cols = cols            # NUM_COLS:   N-tile width
        self.m_tile = rows if m_tile is None else m_tile  # M rows per RUN
        if link not in ("uart", "spi"):
            raise ValueError(f"link must be 'uart' or 'spi', got {link!r}")
        self.link = link            # see the SPI_WIRE_HZ comment above
        self.result_bytes = 2 * self.m_tile * self.cols
        self.stream_tile_bytes = self.rows * self.cols + self.m_tile * self.rows
        self.max_stream_tiles = (255 - 2) // self.stream_tile_bytes
        self.ser = serial.Serial(port, baud, timeout=timeout)
        # cmd byte -> [call count, wire bytes tx (incl. CMD/LEN header), wire bytes rx]
        # Lets a caller measure exactly how many bytes crossed the wire per command
        # type, to separate UART transmission time from actual RTL execution time
        # (see mnist/infer.py's --timing-breakdown and docs/PERFORMANCE_ANALYSIS.md).
        self.stats = {}
        # FPGA-side work done on the offload path, invisible to self.stats'
        # wire counts (the tile frames run RP2350->FPGA, not host->board);
        # tracked separately so estimated_rtl_seconds() stays honest.
        self.offload_tiles = 0      # STREAM_RUN tiles the firmware drove
        self.offload_cmds = 0       # LOAD_BIAS frames the firmware drove
        self.offload = False
        if probe:
            self._resync_and_probe_shape()
            # Firmware matmul offload (FW_MATMUL, firmware/tpu_tile.c) only
            # exists behind the SPI bridge; older firmware answers the probe
            # with the FPGA's STATUS_ERR for the unknown CMD.
            if offload and link == "spi":
                self.offload = self._probe_offload()

    def _resync_and_probe_shape(self):
        """Recover a possibly-desynced sequencer, then verify this driver's
        shape matches the flashed bitstream's -- turning the two ways a shape
        mismatch otherwise surfaces (an opaque STATUS_ERR, or a desynced
        sequencer that silently eats the *next* session's bytes as leftover
        payload and times out) into one immediate, explicit error.

        Resync: a crashed/mismatched previous session can leave the
        sequencer mid-frame in S_RECV_PAYLOAD, waiting on up to 255 payload
        bytes. Feeding it 258 zero bytes completes any such frame (the
        remainder parse as CMD=0x00/LEN=0 pairs, each answered with a
        harmless STATUS_ERR), after which it is guaranteed back in S_IDLE;
        the error chatter is then discarded and a RESET restores a clean
        datapath.

        Shape probe: a LEN=0 RUN's response LEN is the device's
        2*M_TILE*NUM_COLS -- a synthesis-time constant -- so comparing it
        against this driver's expectation catches a mismatched bitstream
        before any real traffic is sent."""
        filler = bytes(258)  # max LEN(255) + CMD/LEN header margin
        byte_s = 10 / self.ser.baudrate
        for i in range(0, len(filler), BRIDGE_CHUNK_BYTES):
            self.ser.write(filler[i:i + BRIDGE_CHUNK_BYTES])
            time.sleep(BRIDGE_CHUNK_BYTES * byte_s * 1.1)
        time.sleep(0.1)                   # let the error-response chatter land
        self.ser.reset_input_buffer()     # ...and throw it away
        self.reset()
        resp = self._send_cmd(CMD_RUN)    # zeroed regs post-reset: result is junk,
        if len(resp) != self.result_bytes:  # only its LENGTH matters here
            raise TPUError(
                f"array-shape mismatch: the flashed bitstream returns "
                f"{len(resp)}-byte results (2*M_TILE*NUM_COLS), but "
                f"rows={self.rows}/cols={self.cols}/m_tile={self.m_tile} "
                f"expects {self.result_bytes}. Pass --rows/--cols/--m-tile "
                f"matching the fpga/Makefile ARRAY_ROWS/NUM_COLS/M_TILE the "
                f"bitstream was built with."
            )

    def _probe_offload(self):
        """True iff the firmware advertises the FW_MATMUL offload. The
        TPU_LINK_SPI firmware answers FW_PROBE locally with [magic, version];
        anything else -- older firmware forwards the frame to the FPGA,
        whose sequencer rejects the unknown CMD with STATUS_ERR -- means no
        offload support."""
        try:
            return self._send_cmd(FW_PROBE) == FW_PROBE_MAGIC
        except TPUError:
            return False

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
        if self.link == "spi" or len(wire_tx) <= BRIDGE_FIFO_BYTES:
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
        self.offload_tiles = 0
        self.offload_cmds = 0

    def uart_wire_seconds(self):
        """Real seconds spent shifting bits across the host link itself,
        computed from every byte actually seen on the wire since the last
        reset_stats(). UART: 8N1 = 10 bits/byte at the CDC baud rate. SPI:
        8 bits/byte at the bridge's write clock (SPI_WIRE_HZ) -- a lower
        bound, since response bytes drain at the slower read clock plus
        poll-filler overhead. On the FW_MATMUL offload path this counts the
        host<->firmware CDC bytes only; the firmware separately re-drives
        the (padded) tiles over SPI, so it is an even looser lower bound
        there."""
        total_bytes = sum(bytes_tx + bytes_rx for _, bytes_tx, bytes_rx in self.stats.values())
        if self.link == "spi":
            return total_bytes * 8 / SPI_WIRE_HZ
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
        # tile count from the wire bytes (4 header bytes per frame).
        n_sr, tx_sr, _ = self.stats.get(CMD_STREAM_RUN, (0, 0, 0))
        stream_tiles = max(0, tx_sr - 4 * n_sr) // self.stream_tile_bytes
        # FW_MATMUL/FW_PROBE never reach the FPGA; the offload_* counters
        # carry the tile/bias work the firmware drove on FW_MATMUL's behalf.
        other_calls = sum(n for cmd, (n, _, _) in self.stats.items()
                          if cmd not in run_like + (CMD_STREAM_RUN, FW_MATMUL, FW_PROBE))
        cycles = ((run_calls + stream_tiles + self.offload_tiles) * 21
                  + (other_calls + self.offload_cmds) * 2)
        return cycles / clk_freq

    # -- protocol commands ------------------------------------------------

    def _check_w(self, w):
        w = np.asarray(w, dtype=np.int8)
        if w.shape != (self.rows, self.cols):
            raise ValueError(f"weights must be {self.rows}x{self.cols}, got {w.shape}")
        return w

    def _check_a(self, a):
        a = np.asarray(a, dtype=np.int8)
        if a.shape != (self.m_tile, self.rows):
            raise ValueError(f"activations must be {self.m_tile}x{self.rows}, got {a.shape}")
        return a

    def _parse_result(self, resp, what):
        if len(resp) != self.result_bytes:
            raise TPUError(f"{what} response had {len(resp)} data bytes, "
                           f"expected {self.result_bytes}")
        return np.frombuffer(resp, dtype="<i2").reshape(self.m_tile, self.cols)

    def load_weights(self, w):
        """w: (rows x cols) array-like, standard row-major, int8 signed.
        Reordered on the wire to bottom-row-first as tpu_sequencer.sv
        expects."""
        w = self._check_w(w)
        self._send_cmd(CMD_LOAD_WEIGHTS, np.ascontiguousarray(w[::-1]).tobytes())

    def load_bias(self, b):
        """b: length-cols array-like, per-output-column int16 bias."""
        b = np.asarray(b, dtype=np.int16)
        if b.shape != (self.cols,):
            raise ValueError(f"bias must have shape ({self.cols},), got {b.shape}")
        self._send_cmd(CMD_LOAD_BIAS, b.astype("<i2").tobytes())

    def load_activations(self, a):
        """a: (m_tile x rows) array-like, standard row-major, int8 signed."""
        a = self._check_a(a)
        self._send_cmd(CMD_LOAD_ACT, a.tobytes())

    def run(self, first=True, last=True):
        """Executes one RUN pass; returns an (m_tile x cols) int16 matrix,
        or None.

        first/last drive the accumulator's K-dim tiling (rtl/accumulator.sv):
        first=True overwrites its persistent running sum with this pass's
        result (start of a new K-reduction); first=False adds to it
        (continuing one). last=True forwards the now-final sum through
        bias/ReLU and returns the usual 8-byte result; last=False leaves it
        in the accumulator for a later pass to add to -- bias/activation
        never fire for that pass, so this returns None rather than a
        result (there isn't one yet). first=last=True (the defaults) is
        the original single-shot matmul, sent as LEN=0 for wire
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
        return self._parse_result(resp, "RUN")

    def run_tile(self, w, a, first=True, last=True):
        """One K-tile pass -- LOAD_WEIGHTS + LOAD_ACT + RUN folded into a
        single CMD_RUN_TILE round trip (3x fewer transactions per tile; see
        docs/SEQUENCER_REDESIGN.md §3.1). w is (rows x cols), a is
        (m_tile x rows), both int8 row-major; unlike load_weights(), the
        weights go over the wire in natural row-major order -- the sequencer
        does the bottom-first reorder internally. first/last have exactly
        run()'s K-tiling semantics; returns the (m_tile x cols) int16 result
        when last=True, else None. Bias is not part of the frame -- call
        load_bias() once per output block."""
        w = self._check_w(w)
        a = self._check_a(a)
        flags = (0x01 if first else 0) | (0x02 if last else 0)
        resp = self._send_cmd(CMD_RUN_TILE, bytes([flags]) + w.tobytes() + a.tobytes())
        if not last:
            return None
        return self._parse_result(resp, "RUN_TILE")

    def stream_run(self, w_tiles, a_tiles, first=True, last=True):
        """A whole K-run (or a chunk of one) in a single CMD_STREAM_RUN
        round trip: up to self.max_stream_tiles (w, a) tile pairs,
        accumulated tile-by-tile in the datapath
        (docs/SEQUENCER_REDESIGN.md §3.2). Weights go in natural row-major
        order, like run_tile(). first/last apply to the frame's first/last
        tile respectively, so a K-run longer than one frame chains:
        first=True,last=False / False,False / ... / False,last=True.
        Returns the (m_tile x cols) int16 result when last=True, else None.
        Bias is not part of the frame -- load_bias() once per block."""
        if len(w_tiles) != len(a_tiles):
            raise ValueError("need one activation tile per weight tile")
        k_tiles = len(w_tiles)
        if not 1 <= k_tiles <= self.max_stream_tiles:
            raise ValueError(f"K_TILES must be 1..{self.max_stream_tiles}, got {k_tiles}")
        flags = (0x01 if first else 0) | (0x02 if last else 0)
        payload = bytearray([flags, k_tiles])
        for w, a in zip(w_tiles, a_tiles):
            payload += self._check_w(w).tobytes() + self._check_a(a).tobytes()
        resp = self._send_cmd(CMD_STREAM_RUN, bytes(payload))
        if not last:
            return None
        return self._parse_result(resp, "STREAM_RUN")

    def reset(self):
        self._send_cmd(CMD_RESET)

    def matmul(self, a, w, bias=None):
        """Convenience wrapper: load activations/weights/bias, then RUN."""
        self.load_activations(a)
        self.load_weights(w)
        self.load_bias(np.zeros(self.cols, dtype=np.int16) if bias is None else bias)
        return self.run()

    def matmul_tiled(self, a, w, bias=None, offload=None):
        """Y = ReLU(A @ W + bias) for shapes beyond the raw hardware tile.
        a: (M,K) int8 array-like, w: (K,N) int8 array-like, bias: (N,)
        int16 array-like (defaults to zero). Any M, K, N -- dimensions that
        don't divide the tile shape are zero-padded on the wire and the
        padding is sliced back off the result (zero K-columns add nothing
        to the products; padded N-columns get bias 0 and are discarded, so
        the answer is exactly the un-padded matmul's).

        Tiles the K dimension into rows-deep weight-reload passes
        accumulated in hardware (rtl/accumulator.sv's persistent PSUM), and
        the M/N dimensions into (m_tile x cols) blocks run one at a time.
        Each (M,N) block's whole K-run goes over the wire as CMD_STREAM_RUN
        frames (stream_run()) of up to self.max_stream_tiles tiles each --
        one round trip per frame instead of one (RUN_TILE) or three
        (legacy) per K-tile. Bias/ReLU are applied once per (M,N) block, on
        that block's final K-tile pass, exactly matching a single un-tiled
        matmul.

        offload: None (default) uses the firmware FW_MATMUL fast path when
        the connected firmware advertises it (self.offload) -- the whole
        loop above runs on the RP2350 with ONE USB round trip, bit-identical
        results. False forces the host-tiled path (A/B testing, regression
        bisecting); True demands the offload and raises if unavailable.
        """
        a = np.asarray(a, dtype=np.int8)
        w = np.asarray(w, dtype=np.int8)
        if a.ndim != 2 or w.ndim != 2:
            raise ValueError("a and w must be 2D")
        m, k = a.shape
        k2, n = w.shape
        if k != k2:
            raise ValueError(f"inner dimensions must match: a is {a.shape}, w is {w.shape}")
        bias = np.zeros(n, dtype=np.int16) if bias is None else np.asarray(bias, dtype=np.int16)
        if bias.shape != (n,):
            raise ValueError(f"bias must have shape ({n},), got {bias.shape}")

        if offload is True and not self.offload:
            raise TPUError("firmware matmul offload requested but not "
                           "available (needs --link spi + TPU_LINK_SPI "
                           "firmware with FW_MATMUL support)")
        use_offload = self.offload if offload is None else offload
        # Degenerate/oversize shapes stay on the host path (the u16 wire
        # dims cap at 65535; M*K etc. of 0 make an empty result anyway).
        if use_offload and 0 < min(m, k, n) and max(m, k, n) <= 0xFFFF:
            return self._matmul_offload(a, w, bias, m, k, n)

        def _round_up(x, q):
            return -(-x // q) * q

        mp, kp, np_ = _round_up(m, self.m_tile), _round_up(k, self.rows), _round_up(n, self.cols)
        if (mp, kp, np_) != (m, k, n):
            a = np.pad(a, ((0, mp - m), (0, kp - k)))
            w = np.pad(w, ((0, kp - k), (0, np_ - n)))
            bias = np.pad(bias, (0, np_ - n))

        out = np.zeros((mp, np_), dtype=np.int16)
        num_k_tiles = kp // self.rows
        for m0 in range(0, mp, self.m_tile):
            for n0 in range(0, np_, self.cols):
                self.load_bias(bias[n0:n0 + self.cols])
                w_tiles = [w[k0:k0 + self.rows, n0:n0 + self.cols]
                           for k0 in range(0, kp, self.rows)]
                a_tiles = [a[m0:m0 + self.m_tile, k0:k0 + self.rows]
                           for k0 in range(0, kp, self.rows)]
                result = None
                for c0 in range(0, num_k_tiles, self.max_stream_tiles):
                    c1 = min(c0 + self.max_stream_tiles, num_k_tiles)
                    result = self.stream_run(w_tiles[c0:c1], a_tiles[c0:c1],
                                             first=(c0 == 0),
                                             last=(c1 == num_k_tiles))
                out[m0:m0 + self.m_tile, n0:n0 + self.cols] = result
        return out[:m, :n]

    def _matmul_offload(self, a, w, bias, m, k, n):
        """FW_MATMUL fast path (firmware/tpu_tile.c): ship the whole
        unpadded W/bias/A in one bulk CDC write; the RP2350 runs exactly
        matmul_tiled()'s LOAD_BIAS + chained-STREAM_RUN loop against the
        FPGA over SPI (zero-padding included) and returns the full de-tiled
        (M,N) int16 result. Inputs are pre-validated by matmul_tiled()."""
        header = struct.pack("<BBHHHBBB", FW_MATMUL, 9, m, k, n,
                             self.rows, self.cols, self.m_tile)
        bulk = (np.ascontiguousarray(w).tobytes()
                + bias.astype("<i2").tobytes()
                + np.ascontiguousarray(a).tobytes())
        checksum = int(np.frombuffer(bulk, np.uint8).sum(dtype=np.uint64)) & 0xFF
        wire_tx = header + bulk + bytes([checksum])
        self.ser.write(wire_tx)
        status, _ = self._read_exact(2)   # response: [STATUS][0x00] + raw result
        resp = self._read_exact(2 * m * n) if status == STATUS_OK else b""
        calls, bytes_tx, bytes_rx = self.stats.get(FW_MATMUL, (0, 0, 0))
        self.stats[FW_MATMUL] = (calls + 1, bytes_tx + len(wire_tx),
                                 bytes_rx + 2 + len(resp))
        if status != STATUS_OK:
            raise TPUError(
                f"FW_MATMUL failed: STATUS=0x{status:02X} (dims/checksum "
                f"rejected by the firmware, or an SPI-side frame failed)")
        # Mirror the FPGA work the firmware just drove (see reset_stats).
        blocks = -(-m // self.m_tile) * -(-n // self.cols)
        self.offload_tiles += blocks * -(-k // self.rows)
        self.offload_cmds += blocks   # one LOAD_BIAS per block
        return np.frombuffer(resp, dtype="<i2").reshape(m, n).copy()


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
        expected = np.maximum(
            a.astype(np.int32) @ w.astype(np.int32) + b, 0).astype(np.int16)
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
                         "the higher-numbered /dev/cu.usbmodemN one first)")
    p.add_argument("--baud", type=int, default=DEFAULT_BAUD,
                    help=f"must match CLK_FREQ/BAUD_RATE the bitstream was built with "
                         f"(default {DEFAULT_BAUD})")
    p.add_argument("--rows", type=int, default=2,
                    help="ARRAY_ROWS the bitstream was built with (default 2)")
    p.add_argument("--cols", type=int, default=2,
                    help="NUM_COLS the bitstream was built with (default 2)")
    p.add_argument("--m-tile", type=int, default=None,
                    help="M_TILE the bitstream was built with (default: same as --rows)")
    p.add_argument("--link", choices=("uart", "spi"), default="uart",
                    help="host-link PHY the board is running: uart (default) or "
                         "spi (USE_SPI=1 gateware + TPU_LINK_SPI firmware; "
                         "disables UART-era write pacing)")
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
             m_tile=args.m_tile, link=args.link) as tpu:
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
