"""transports for the host<->TPU byte stream; each is a duck-typed serial.Serial"""
import mmap
import os
import select
import subprocess
import time

import serial


class TPUError(RuntimeError):
    pass


LINKS = ("uart", "spi", "hps", "sim")


class MmioLink:
    """the DE1-SoC's hps_bridge over /dev/mem; runs on the board's ARM. untested on hardware"""

    LWH2F_BASE  = 0xFF20_0000      # cyclone V lightweight HPS->FPGA bridge base
    SPAN        = 0x1000           # one page is plenty for 3 registers
    TXDATA      = 0x0
    RXDATA      = 0x4
    STATUS      = 0x8
    ST_RX_AVAIL = 1 << 1

    def __init__(self, port="/dev/mem", timeout=2.0,
                 base=LWH2F_BASE, offset=0):
        if offset % mmap.PAGESIZE:
            raise ValueError(
                f"hps_bridge component offset 0x{offset:X} must be page-aligned "
                f"(multiple of 0x{mmap.PAGESIZE:X}); set its Qsys base accordingly"
            )
        self.timeout = timeout
        self.baudrate = 10 ** 9    # sentinel: makes the UART-era pacing math ~0
        self._fd = os.open(port, os.O_RDWR | os.O_SYNC)
        self._map = mmap.mmap(self._fd, self.SPAN,
                              flags=mmap.MAP_SHARED,
                              prot=mmap.PROT_READ | mmap.PROT_WRITE,
                              offset=base + offset)

    def _rd32(self, off):
        return int.from_bytes(self._map[off:off + 4], "little")

    def _wr32(self, off, val):
        self._map[off:off + 4] = int(val & 0xFFFFFFFF).to_bytes(4, "little")

    def write(self, data):
        for b in data:
            self._wr32(self.TXDATA, b)
        return len(data)

    def read(self, n):
        out = bytearray()
        deadline = time.time() + self.timeout
        while len(out) < n:
            if self._rd32(self.STATUS) & self.ST_RX_AVAIL:
                out.append(self._rd32(self.RXDATA) & 0xFF)
            elif time.time() > deadline:
                break
        return bytes(out)

    def reset_input_buffer(self):
        while self._rd32(self.STATUS) & self.ST_RX_AVAIL:
            _ = self._rd32(self.RXDATA)

    def close(self):
        try:
            self._map.close()
        finally:
            os.close(self._fd)


class SimLink:
    """a Verilator model of tpu_core as a subprocess (make sim-bridge); the same bytes as silicon"""

    def __init__(self, port, timeout=120.0):
        self.timeout = timeout
        self.baudrate = 10 ** 9      # sentinel: makes UART-era pacing math ~0
        if not os.path.exists(port):
            raise TPUError(
                f"sim bridge binary not found: {port}\n"
                f"Build it with:  make sim-bridge"
            )
        self._p = subprocess.Popen(
            [os.path.abspath(port), "--bridge"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)

    def _alive(self):
        return self._p.poll() is None

    def write(self, data):
        if not self._alive():
            raise TPUError("sim bridge exited (the DUT stopped answering)")
        self._p.stdin.write(bytes(data))
        self._p.stdin.flush()
        return len(data)

    def read(self, n):
        out = bytearray()
        deadline = time.time() + self.timeout
        while len(out) < n:
            left = deadline - time.time()
            if left <= 0:
                break
            r, _, _ = select.select([self._p.stdout], [], [], left)
            if not r:
                break
            chunk = self._p.stdout.read(n - len(out))   # bufsize=0: may be short
            if not chunk:
                break
            out += chunk
        return bytes(out)

    def reset_input_buffer(self):
        # drain the STATUS_ERR chatter the resync filler provokes
        while True:
            r, _, _ = select.select([self._p.stdout], [], [], 0.5)
            if not r:
                return
            if not self._p.stdout.read(65536):
                return

    def close(self):
        try:
            self._p.stdin.close()
            self._p.wait(timeout=5)
        except Exception:
            self._p.kill()


def open_link(link, port, baud, timeout):
    if link not in LINKS:
        raise ValueError(f"link must be one of {LINKS}, got {link!r}")
    if link == "hps":
        return MmioLink(port, timeout=timeout)
    if link == "sim":
        # simulation is far slower than any serial link
        return SimLink(port, timeout=max(timeout, 120.0))
    return serial.Serial(port, baud, timeout=timeout)
