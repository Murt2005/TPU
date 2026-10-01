"""driver for the instruction-stream core's 12-register bridge"""
import os
import struct
import subprocess
import time

INSN_LO, INSN_HI, DATA, OUT, STATUS, LEVELS, CTRL, ERR_SEQ = range(8)
PERF_CYCLES, PERF_MM_BEATS, PERF_MM_WSTALL, PERF_MM_SYNC = range(8, 12)

CTRL_RESET, CTRL_CLEAR_DONE, CTRL_CLEAR_PERF = 1, 2, 4


class IsaSimLink:
    """Verilator model of tpu_isa_top as a subprocess (make isa-sim). writes are
    buffered and only flushed when a read needs the reply"""

    # the model's clock only advances on register accesses, so PERF_CYCLES
    # differences between runs are exact; on hardware the link's latency is in them
    cycle_exact = True

    def __init__(self, binary):
        if not os.path.exists(binary):
            raise FileNotFoundError(f"{binary} not found: build it with `make isa-sim`")
        self._p = subprocess.Popen([os.path.abspath(binary)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, bufsize=0)
        self._buf = bytearray()
        raw = self._read(20)
        self.n, self.wmem_rows, self.ub_depth, self.acc_depth, self.param_depth = \
            struct.unpack("<5I", raw)

    def _read(self, k):
        out = b""
        while len(out) < k:
            chunk = self._p.stdout.read(k - len(out))
            if not chunk:
                raise RuntimeError("isa sim exited")
            out += chunk
        return out

    def write32(self, reg, value):
        self._buf += b"W" + bytes([reg]) + struct.pack("<I", value & 0xFFFFFFFF)
        if len(self._buf) > 1 << 16:
            self.flush()

    def flush(self):
        if self._buf:
            self._p.stdin.write(bytes(self._buf))
            self._buf.clear()

    def read32(self, reg):
        self._buf += b"R" + bytes([reg])
        self.flush()
        return struct.unpack("<I", self._read(4))[0]

    def close(self):
        try:
            self.flush()
            self._p.stdin.write(b"Q")
            self._p.stdin.close()
            self._p.wait(timeout=10)
        except Exception:
            self._p.kill()


class BoardConsole:
    """the DE1-SoC's HPS serial console as a launcher for raw-binary programs:
    gets to a root shell, silences kernel messages, mounts the SD card's boot
    partition (where the programs live), then starts one and syncs on its echo"""

    BAUD = 115200
    FAST_BAUD = 1562500     # 6.25 MHz / 4: the fastest the HPS UART and the CP2105 agree on
    SETBAUD = "/mnt/boot/setbaud"

    def __init__(self, port, baud=BAUD):
        import serial
        self._s = serial.Serial(port, baud, timeout=0.2)
        self._recover()
        self._s.write(b"\x03")                   # abandon any half-typed line
        self._quiet()
        self._shell(b"")
        self._shell(b"root", tolerate_login=True)
        self._shell(b"dmesg -n 1")              # kernel messages would corrupt the stream
        self._shell(b"mkdir -p /mnt/boot; grep -q /mnt/boot /proc/mounts || mount /dev/mmcblk0p1 /mnt/boot")
        self._quiet()

    def _alive(self):
        self._s.reset_input_buffer()
        self._s.write(b"\x03\recho ALIVE_$((40+2))\r")
        time.sleep(0.6)
        return b"ALIVE_42" in self._s.read(4096)

    def _recover(self):
        """a session that died at the fast rate leaves the console there"""
        if self._alive():
            return
        self._s.baudrate = self.FAST_BAUD
        if self._alive():
            self._s.write(b"stty sane 115200\r")
            self._s.flush()
            time.sleep(0.5)
        self._s.baudrate = self.BAUD
        self._quiet()

    def run(self, cmdline, wait=1.0):
        """a shell command's output, as text"""
        self._s.reset_input_buffer()
        self._s.write(cmdline.encode() + b"\r")
        time.sleep(wait)
        out = b""
        while True:
            chunk = self._s.read(65536)
            out += chunk
            if not chunk:
                break
        return out.decode(errors="replace")

    def set_baud(self, rate):
        """both ends to `rate`; needs setbaud on the board for rates above 921600"""
        self._s.write(f"{self.SETBAUD} {rate}\r".encode())
        self._s.flush()
        time.sleep(0.4)
        self._s.baudrate = rate
        time.sleep(0.1)
        self._quiet(0.3)

    def upload(self, local, remote, fast=True):
        """copy a file to the board (the HPS has no Ethernet here): the shell's tty
        goes raw and `dd` takes the bytes unescaped and unechoed, at the fast
        rate when setbaud is there. written as .part, renamed once the md5 matches"""
        import hashlib
        data = open(local, "rb").read()
        if fast:
            self.set_baud(self.FAST_BAUD)
        try:
            self.run(f"rm -f {remote}.part", 0.3)
            self._quiet(0.5)
            # wait until the shell has the line (its echo), then for stty to make the tty raw
            # this busybox's head has no -c; dd bs=1 counts bytes exactly on a raw tty
            self.launch(f"stty raw -echo; dd of={remote}.part bs=1 count={len(data)} 2>/dev/null; "
                        f"stty sane")
            self._s.timeout = 0.2               # launch() left it long; the prompt wait polls
            time.sleep(0.3)
            self._s.reset_input_buffer()
            self._s.write(data)
            self._s.flush()
            self._wait_prompt(timeout=30.0 + len(data) / 10000)
            md5 = hashlib.md5(data).hexdigest()
            out = self.run(f"md5sum {remote}.part", 1.0)
            if md5 not in out:
                raise RuntimeError(f"upload of {local}: md5 mismatch ({out!r})")
            self.run(f"mv {remote}.part {remote}; chmod +x {remote}; sync", 1.0)
        except Exception:
            self._s.write(b"\x03\x04\rstty sane\r")
            raise
        finally:
            self._s.timeout = 0.2
            if fast:
                self.set_baud(self.BAUD)

    def _wait_prompt(self, timeout=10.0):
        buf = b""
        end = time.time() + timeout
        while not buf.rstrip().endswith(b"#") and time.time() < end:
            buf += self._s.read(4096)
        if not buf.rstrip().endswith(b"#"):
            raise RuntimeError(f"no shell prompt: {buf[-100:]!r}")

    def launch(self, cmdline, timeout=10.0):
        """start a program; afterwards the line is raw binary to and from it"""
        cmd = cmdline.encode() if isinstance(cmdline, str) else cmdline
        # "\r" alone: a trailing "\n" would stay queued and be the program's first input byte
        self._s.write(cmd + b"\r")
        # sync on the shell's echo of this line; past 80 columns the console wraps
        # it with "\r" and spaces, so compare with those removed
        def squash(b):
            return b.replace(b"\r", b"").replace(b" ", b"")
        want = squash(cmd)
        seen = b""
        deadline = time.time() + timeout
        while not (seen.endswith(b"\n") and squash(seen[:-1]).rstrip(b"\n").endswith(want)):
            seen += self._s.read(1)
            if time.time() > deadline:
                raise RuntimeError(f"no echo of {cmd!r} from the board console: {seen[-200:]!r}")
        self._s.timeout = timeout

    def read(self, k):
        out = self._s.read(k)
        if len(out) < k:
            raise RuntimeError(f"board link: wanted {k} bytes, got {len(out)} ({out!r})")
        return out

    def write(self, data):
        self._s.write(data)

    def close(self, quit_byte=b"Q"):
        try:
            if quit_byte:
                self._s.write(quit_byte)
                self._s.flush()
                time.sleep(0.3)
            self._s.reset_input_buffer()
        finally:
            self._s.close()

    def _quiet(self, idle=1.0, limit=10.0):
        """read until the console has been silent for `idle` seconds"""
        end = time.time() + limit
        last = time.time()
        while time.time() < end and time.time() - last < idle:
            if self._s.read(4096):
                last = time.time()

    def _shell(self, line, tolerate_login=False):
        self._s.write(line + b"\r")
        time.sleep(0.5)
        out = self._s.read(4096)
        if tolerate_login and b"assword" in out:
            self._s.write(b"\r")
            time.sleep(0.5)
            self._s.read(4096)
        return out


class IsaSerialLink(IsaSimLink):
    """the real core on the DE1-SoC, through boards/de1soc/sw/isa_mmio run on the
    HPS over its serial console, speaking the same protocol as the Verilator model"""

    cycle_exact = False

    def __init__(self, port, server="/mnt/boot/isa_mmio", baud=115200, timeout=10.0):
        self._con = BoardConsole(port, baud)
        self._buf = bytearray()
        self._con.launch(server, timeout)
        self.n, self.wmem_rows, self.ub_depth, self.acc_depth, self.param_depth = \
            struct.unpack("<5I", self._read(20))

    def _read(self, k):
        return self._con.read(k)

    def flush(self):
        if self._buf:
            self._con.write(bytes(self._buf))
            self._buf.clear()

    def close(self):
        self.flush()
        self._con.close(b"Q")


def open_link(spec):
    """'serial:<port>[:<server path>]' for the board, else a Verilator tb_isa binary"""
    if spec.startswith("serial:"):
        port, _, server = spec[len("serial:"):].partition(":")
        return IsaSerialLink(port, server or "/mnt/boot/isa_mmio")
    return IsaSimLink(spec)


class IsaError(RuntimeError):
    pass


class IsaDevice:
    def __init__(self, link):
        self.link = link

    def reset(self):
        self.link.write32(CTRL, CTRL_RESET | CTRL_CLEAR_PERF)

    def status(self):
        s = self.link.read32(STATUS)
        return {"done": bool(s & 1), "err": bool(s & 2), "idle": bool(s & 4),
                "underflow": bool(s & 8), "err_code": (s >> 8) & 0xFF, "tag": s >> 16}

    def levels(self):
        v = self.link.read32(LEVELS)
        return {"insn_free": v & 0x3FF, "data_free": (v >> 10) & 0x7FF, "out_count": v >> 21}

    def perf(self):
        return {name: self.link.read32(reg) for name, reg in
                (("cycles", PERF_CYCLES), ("mm_beats", PERF_MM_BEATS),
                 ("mm_wstall", PERF_MM_WSTALL), ("mm_sync", PERF_MM_SYNC))}

    def push_program(self, words):
        for w in words:
            self.link.write32(INSN_LO, w & 0xFFFFFFFF)
            self.link.write32(INSN_HI, w >> 32)

    def push_data(self, words):
        for w in words:
            self.link.write32(DATA, w)

    def drain(self):
        n = self.levels()["out_count"]
        return [self.link.read32(OUT) for _ in range(n)]

    def run(self, program, data=(), timeout=60.0):
        """push a program ending in SIGNAL plus its data, then collect output
        until DONE. the instruction FIFO must hold the whole program (512)"""
        if len(program) > 512:
            raise ValueError("phase 1 driver: program must fit the 512-entry instruction FIFO")
        self.link.write32(CTRL, CTRL_CLEAR_DONE)
        self.push_program(program)
        self.push_data(data)
        out = []
        t0 = time.time()
        while True:
            out += self.drain()
            st = self.status()
            if st["err"]:
                raise IsaError(f"error code {st['err_code']} at instruction "
                               f"{self.link.read32(ERR_SEQ)}")
            if st["done"]:
                return out + self.drain()
            if time.time() - t0 > timeout:
                raise TimeoutError(f"no DONE after {timeout}s: {st} {self.levels()}")
