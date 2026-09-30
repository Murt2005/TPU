"""Transports for the host<->TPU byte stream.

Every link is a duck-typed stand-in for serial.Serial (write / read /
reset_input_buffer / close / baudrate), so the driver above it does not know
which one it is talking to. uart and spi are plain pyserial on the RP2350's
USB-CDC port -- the firmware does the SPI -- so they need no class here.
"""
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
    """Duck-typed drop-in for serial.Serial that reaches the DE1-SoC's
    hps_bridge (rtl/peripherals/hps_bridge.sv) over the Cyclone V lightweight HPS->FPGA
    bridge via /dev/mem. It exposes the small slice of the pyserial API the
    TPU class uses (write/read/reset_input_buffer/close/baudrate) so nothing
    else in this driver changes -- only the transport does.

    This runs ON the board's ARM Linux (not on the host PC): tpu_host.py is
    copied to the DE1-SoC and invoked there with `--link hps --port /dev/mem`.
    The byte-level wire protocol is identical to the UART/SPI links.

    hps_bridge register map (word offsets within the Avalon component):
        0x0  TXDATA (w)  host->FPGA byte  (writing pushes one rx byte)
        0x4  RXDATA (r)  FPGA->host byte  (reading pops it)
        0x8  STATUS (r)  bit0 TX_SPACE=1 always, bit1 RX_AVAIL=byte waiting

    NOTE: unvalidated on hardware from this repo yet -- the register contract
    matches hps_bridge.sv / hps_bridge_tb.sv, but confirm the base address and
    the component's Qsys offset for your generated system. LWH2F_BASE is the
    standard Cyclone V lightweight bridge base; `offset` is the hps_bridge
    component's base assigned in Platform Designer (page-aligned).
    """

    LWH2F_BASE  = 0xFF20_0000      # Cyclone V lightweight HPS->FPGA bridge base
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
        # drain any FPGA->host bytes still pending in the bridge
        while self._rd32(self.STATUS) & self.ST_RX_AVAIL:
            _ = self._rd32(self.RXDATA)

    def close(self):
        try:
            self._map.close()
        finally:
            os.close(self._fd)


class SimLink:
    """Duck-typed drop-in for serial.Serial that drives a Verilator model of
    tpu_core, run as a subprocess in bridge mode
    (tests/verilator/tb_tpu_top.cpp --bridge, built by `make sim-bridge`).

    The byte-level wire protocol is identical to the UART/SPI/HPS links, so
    everything above this -- matmul_tiled's zero-padding, K-tiling and
    STREAM_RUN chaining -- is the same code that drives real silicon. Only
    --link changes. That is the point: a model debugged here runs on the
    board without touching the driver.

    The bridge answers one frame at a time and never volunteers bytes, so
    reads are framed exactly like the hardware links'. Simulation is slow
    (a STREAM_RUN frame is tens of thousands of simulated cycles), hence the
    much larger default timeout.
    """

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
        # The resync filler in _resync_and_probe_shape provokes a STATUS_ERR
        # per bogus frame; drain them so the next real response is not read
        # from the middle of that chatter.
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
    """Open the transport for `link` (one of LINKS)."""
    if link not in LINKS:
        raise ValueError(f"link must be one of {LINKS}, got {link!r}")
    if link == "hps":
        # memory-mapped bridge on the DE1-SoC (runs on the board's ARM)
        return MmioLink(port, timeout=timeout)
    if link == "sim":
        # Simulated cycles are far slower than wall-clock serial; give the
        # model room rather than inheriting the 2 s hardware default.
        return SimLink(port, timeout=max(timeout, 120.0))
    return serial.Serial(port, baud, timeout=timeout)
