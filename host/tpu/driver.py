"""the TPU driver: one systolic-array core behind any link in links.py"""
import struct
import time

import numpy as np

from .links import TPUError, open_link
from .protocol import (
    BRIDGE_CHUNK_BYTES, BRIDGE_FIFO_BYTES, CMD_LOAD_ACT, CMD_LOAD_BIAS,
    CMD_LOAD_WEIGHTS, CMD_RESET, CMD_RUN, CMD_RUN_TILE, CMD_STREAM_RUN,
    DEFAULT_BAUD, FPGA_CLK_FREQ, FW_MATMUL, FW_PROBE, FW_PROBE_MAGIC,
    PSUM_DTYPE, SPI_WIRE_HZ, STATUS_OK, pack_flags,
)


class TPU:
    """one TPU core; rows/cols/m_tile/psum_width must match the flashed bitstream"""

    def __init__(self, port, baud=DEFAULT_BAUD, timeout=2.0,
                 rows=2, cols=2, m_tile=None, probe=True, link="uart",
                 offload=True, psum_width=16):
        self.rows = rows            # ARRAY_ROWS: K-tile depth
        self.cols = cols            # NUM_COLS:   N-tile width
        self.m_tile = rows if m_tile is None else m_tile  # M rows per RUN
        if psum_width not in PSUM_DTYPE:
            raise ValueError(f"psum_width must be one of "
                             f"{sorted(PSUM_DTYPE)}, got {psum_width}")
        self.psum_width = psum_width
        self.psum_bytes = psum_width // 8
        self.psum_dtype = PSUM_DTYPE[psum_width]
        self.link = link            # see protocol.py's SPI_WIRE_HZ comment
        self.result_bytes = self.psum_bytes * self.m_tile * self.cols
        self.stream_tile_bytes = self.rows * self.cols + self.m_tile * self.rows
        self.max_stream_tiles = (255 - 2) // self.stream_tile_bytes
        self.ser = open_link(link, port, baud, timeout)
        # cmd -> (calls, wire bytes tx, wire bytes rx), for latency attribution
        self.stats = {}
        # FPGA work the firmware drives during FW_MATMUL, invisible to stats
        self.offload_tiles = 0      # STREAM_RUN tiles the firmware drove
        self.offload_cmds = 0       # LOAD_BIAS frames the firmware drove
        self.offload = False
        if probe:
            self._resync_and_probe_shape()
            # older firmware forwards FW_PROBE and the FPGA rejects it
            if offload and link == "spi":
                self.offload = self._probe_offload()

    def _resync_and_probe_shape(self):
        """flush a half-received frame, reset, then check the result length matches
        our shape. 258 zero bytes complete any pending frame; the junk responses are
        discarded"""
        # a fresh sim process can't be mid-frame, and skipping the filler saves ~129 simulated frames
        if self.link != "sim":
            filler = bytes(258)  # max LEN(255) + CMD/LEN header margin
            byte_s = 10 / self.ser.baudrate
            for i in range(0, len(filler), BRIDGE_CHUNK_BYTES):
                self.ser.write(filler[i:i + BRIDGE_CHUNK_BYTES])
                time.sleep(BRIDGE_CHUNK_BYTES * byte_s * 1.1)
            time.sleep(0.1)               # let the error-response chatter land
            self.ser.reset_input_buffer() # ...and throw it away
        self.reset()
        resp = self._send_cmd(CMD_RUN)    # zeroed regs post-reset: result is junk,
        if len(resp) != self.result_bytes:  # only its LENGTH matters here
            raise TPUError(
                f"array-shape mismatch: the flashed bitstream returns "
                f"{len(resp)}-byte results "
                f"(PSUM_BYTES*M_TILE*NUM_COLS), but rows={self.rows}/"
                f"cols={self.cols}/m_tile={self.m_tile}/"
                f"psum_width={self.psum_width} expects {self.result_bytes}. "
                f"Pass --rows/--cols/--m-tile/--psum-width matching the "
                f"boards/pico2-ice/fpga/Makefile ARRAY_ROWS/NUM_COLS/M_TILE/PSUM_WIDTH the "
                f"bitstream was built with."
            )

    def _probe_offload(self):
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

    # wire-level helpers

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
        if self.link in ("spi", "hps", "sim") or len(wire_tx) <= BRIDGE_FIFO_BYTES:
            self.ser.write(wire_tx)
        else:
            # never more than one UART FIFO's worth in flight
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
        """seconds spent on the host link itself; a lower bound for SPI and the offload path"""
        total_bytes = sum(bytes_tx + bytes_rx for _, bytes_tx, bytes_rx in self.stats.values())
        if self.link == "spi":
            return total_bytes * 8 / SPI_WIRE_HZ
        return total_bytes * 10 / self.ser.baudrate

    def estimated_rtl_seconds(self, clk_freq=FPGA_CLK_FREQ):
        """rough time inside tpu_core at a fixed 21 cycles per pass (the 2x2 figure)"""
        run_like = (CMD_RUN, CMD_RUN_TILE)
        run_calls = sum(self.stats.get(cmd, (0, 0, 0))[0] for cmd in run_like)
        # tile count from wire bytes: 4 header bytes per frame
        n_sr, tx_sr, _ = self.stats.get(CMD_STREAM_RUN, (0, 0, 0))
        stream_tiles = max(0, tx_sr - 4 * n_sr) // self.stream_tile_bytes
        other_calls = sum(n for cmd, (n, _, _) in self.stats.items()
                          if cmd not in run_like + (CMD_STREAM_RUN, FW_MATMUL, FW_PROBE))
        cycles = ((run_calls + stream_tiles + self.offload_tiles) * 21
                  + (other_calls + self.offload_cmds) * 2)
        return cycles / clk_freq

    # protocol commands

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
        return np.frombuffer(resp, dtype=self.psum_dtype).reshape(self.m_tile, self.cols)

    def load_weights(self, w):
        """w: (rows, cols) int8; sent bottom row first, as LOAD_WEIGHTS expects"""
        w = self._check_w(w)
        self._send_cmd(CMD_LOAD_WEIGHTS, np.ascontiguousarray(w[::-1]).tobytes())

    def load_bias(self, b):
        b = np.asarray(b, dtype=self.psum_dtype)
        if b.shape != (self.cols,):
            raise ValueError(f"bias must have shape ({self.cols},), got {b.shape}")
        self._send_cmd(CMD_LOAD_BIAS, b.astype(self.psum_dtype).tobytes())

    def load_activations(self, a):
        a = self._check_a(a)
        self._send_cmd(CMD_LOAD_ACT, a.tobytes())

    def run(self, first=True, last=True, act_bypass=False):
        """one pass; returns (m_tile, cols) when last, else None (the sum stays in the accumulator)"""
        if first and last and not act_bypass:
            payload = b""
        else:
            payload = bytes([pack_flags(first, last, act_bypass)])
        resp = self._send_cmd(CMD_RUN, payload)
        if not last:
            return None
        return self._parse_result(resp, "RUN")

    def run_tile(self, w, a, first=True, last=True, act_bypass=False):
        """one K-tile in one RUN_TILE frame; bias comes from load_bias()"""
        w = self._check_w(w)
        a = self._check_a(a)
        flags = pack_flags(first, last, act_bypass)
        resp = self._send_cmd(CMD_RUN_TILE, bytes([flags]) + w.tobytes() + a.tobytes())
        if not last:
            return None
        return self._parse_result(resp, "RUN_TILE")

    def stream_run(self, w_tiles, a_tiles, first=True, last=True, act_bypass=False):
        """up to max_stream_tiles K-tiles in one STREAM_RUN frame; first/last apply to the frame's ends"""
        if len(w_tiles) != len(a_tiles):
            raise ValueError("need one activation tile per weight tile")
        k_tiles = len(w_tiles)
        if not 1 <= k_tiles <= self.max_stream_tiles:
            raise ValueError(f"K_TILES must be 1..{self.max_stream_tiles}, got {k_tiles}")
        payload = bytearray([pack_flags(first, last, act_bypass), k_tiles])
        for w, a in zip(w_tiles, a_tiles):
            payload += self._check_w(w).tobytes() + self._check_a(a).tobytes()
        resp = self._send_cmd(CMD_STREAM_RUN, bytes(payload))
        if not last:
            return None
        return self._parse_result(resp, "STREAM_RUN")

    def reset(self):
        self._send_cmd(CMD_RESET)

    def matmul(self, a, w, bias=None):
        self.load_activations(a)
        self.load_weights(w)
        self.load_bias(np.zeros(self.cols, dtype=np.int16) if bias is None else bias)
        return self.run()

    def matmul_tiled(self, a, w, bias=None, offload=None, act_bypass=False):
        """act(A @ W + bias) for any M, K, N: zero-pads to the tile grid, chains STREAM_RUN
        frames per output block, and slices the padding off. offload: None uses FW_MATMUL
        when the firmware has it, False forces the host path, True requires it"""
        a = np.asarray(a, dtype=np.int8)
        w = np.asarray(w, dtype=np.int8)
        if a.ndim != 2 or w.ndim != 2:
            raise ValueError("a and w must be 2D")
        m, k = a.shape
        k2, n = w.shape
        if k != k2:
            raise ValueError(f"inner dimensions must match: a is {a.shape}, w is {w.shape}")
        bias = (np.zeros(n, dtype=self.psum_dtype) if bias is None
                else np.asarray(bias, dtype=self.psum_dtype))
        if bias.shape != (n,):
            raise ValueError(f"bias must have shape ({n},), got {bias.shape}")

        # the firmware is int16-only with no flags byte
        offload_blocked = None
        if self.psum_bytes != 2:
            offload_blocked = f"psum_width={self.psum_width} (firmware is int16-only)"
        elif act_bypass:
            offload_blocked = "act_bypass=True (firmware always applies ReLU)"
        if offload is True:
            if not self.offload:
                raise TPUError("firmware matmul offload requested but not "
                               "available (needs --link spi + TPU_LINK_SPI "
                               "firmware with FW_MATMUL support)")
            if offload_blocked:
                raise TPUError(f"firmware matmul offload requested but "
                               f"incompatible with {offload_blocked}")
        use_offload = (self.offload if offload is None else offload) and not offload_blocked
        # u16 dims on the wire
        if use_offload and 0 < min(m, k, n) and max(m, k, n) <= 0xFFFF:
            return self._matmul_offload(a, w, bias, m, k, n)

        def _round_up(x, q):
            return -(-x // q) * q

        mp, kp, np_ = _round_up(m, self.m_tile), _round_up(k, self.rows), _round_up(n, self.cols)
        if (mp, kp, np_) != (m, k, n):
            a = np.pad(a, ((0, mp - m), (0, kp - k)))
            w = np.pad(w, ((0, kp - k), (0, np_ - n)))
            bias = np.pad(bias, (0, np_ - n))

        out = np.zeros((mp, np_), dtype=self.psum_dtype)
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
                                             last=(c1 == num_k_tiles),
                                             act_bypass=act_bypass)
                out[m0:m0 + self.m_tile, n0:n0 + self.cols] = result
        return out[:m, :n]

    def _matmul_offload(self, a, w, bias, m, k, n):
        """one bulk CDC write; the RP2350 runs matmul_tiled()'s loop and returns the whole result"""
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
        blocks = -(-m // self.m_tile) * -(-n // self.cols)
        self.offload_tiles += blocks * -(-k // self.rows)
        self.offload_cmds += blocks   # one LOAD_BIAS per block
        return np.frombuffer(resp, dtype="<i2").reshape(m, n).copy()
