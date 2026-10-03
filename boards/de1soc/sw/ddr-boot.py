"""Boot the DE1-SoC with the core's FPGA-to-SDRAM port live, without touching the
SD card: reboot into U-Boot, load a bitstream over JTAG, apply the port's
configuration, release the port, and boot Linux with mem=256M (DDR3 from
0x10000000 up is left to the FPGA: room for Qwen2.5-0.5B's 494 MB of weights).

    python boards/de1soc/sw/ddr-boot.py /dev/cu.usbserial-<id>0 boards/de1soc/fpga/hps/build/soc_system.rbf

U-Boot 2013.01 never applies a new bitstream's port configuration (staticcfg's
applycfg) and leaves the ports in reset (fpgaportrst). applycfg has to land
while the SDRAM controller is idle; U-Boot itself runs from SDRAM, and a bare
`mw` to it hung the HPS once in three tries. So it runs from ten instructions in
on-chip RAM, which set the bit and wait for the controller to clear it, as later
U-Boots do. Nothing is saved: a power cycle boots as before. Every step's output
is checked, and the first surprise stops it.
"""
import argparse
import os
import subprocess
import sys
import time

import serial

BLASTER_FIRMWARE = os.path.expanduser("~/.local/share/intel-blaster/blaster_6810.hex")
PROMPT = b"SOCFPGA_CYCLONE5 #"
ROUTINE = 0xFFFFD000          # on-chip RAM, clear of the SPL's vectors at 0xFFFF0000
APPLYCFG = [0xE59F101C,       # ldr r1, [pc, #0x1c]     staticcfg's address, below
            0xE5910000,       # ldr r0, [r1]
            0xE3800008,       # orr r0, r0, #8          applycfg
            0xE5810000,       # str r0, [r1]
            0xF57FF04F,       # dsb sy
            0xE5910000,       # ldr r0, [r1]            until the controller has taken it
            0xE3100008,       # tst r0, #8
            0x1AFFFFFC,       # bne (the ldr)
            0xE12FFF1E,       # bx lr                   rc = staticcfg
            0xFFC2505C]       # staticcfg
PORT_RESETS = 0x133           # f2h_sdram0: command port 0, read ports 0-1, write ports 0-1
BOOTARGS = "console=ttyS0,115200 root=/dev/mmcblk0p2 rw rootwait mem=256M"


class UBoot:
    def __init__(self, port):
        self.s = serial.Serial(port, 115200, timeout=0.3)

    def until(self, marker, timeout, send=None):
        buf = b""
        end = time.time() + timeout
        while time.time() < end:
            buf += self.s.read(4096)
            if marker in buf:
                if send is not None:
                    self.s.write(send)
                return buf.decode(errors="replace")
        sys.exit(f"no {marker!r} within {timeout} s; last output: {buf[-300:]!r}")

    def run(self, command, expect=None, timeout=10):
        self.s.write(command.encode() + b"\r")
        out = self.until(PROMPT, timeout)
        if expect is not None and expect not in out:
            sys.exit(f"`{command}`: expected {expect!r}, got {out!r}")
        return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port", help="the HPS console, /dev/cu.usbserial-<id>0")
    ap.add_argument("rbf", help="the GHRD bitstream to load over JTAG")
    args = ap.parse_args()

    u = UBoot(args.port)
    # from Linux (or anywhere else) to U-Boot's prompt
    u.s.write(b"\x03\r")
    time.sleep(1)
    u.s.read(65536)
    u.s.write(b"\r")
    time.sleep(1)
    if PROMPT not in u.s.read(65536):
        u.s.write(b"reboot\r")
        u.until(b"Hit any key", 120, send=b" ")
        u.until(PROMPT, 10)
    print("U-Boot: stopped")

    subprocess.run(["openFPGALoader", "-b", "de1Soc", "--probe-firmware", BLASTER_FIRMWARE, args.rbf],
                   check=True, capture_output=True)
    print(f"JTAG: loaded {args.rbf}")

    u.run("run mmcload", expect="socfpga.dtb", timeout=30)
    for i, word in enumerate(APPLYCFG):
        u.run(f"mw {ROUTINE + 4 * i:x} {word:08x}")
    u.run(f"go {ROUTINE:x}", expect="rc = 0x", timeout=5)
    print("SDRAM controller: port configuration applied")
    u.run("run bridge_enable_handoff", expect="axibridge")
    u.run(f"mw ffc25080 {PORT_RESETS:x}; md ffc25080 1", expect=f"ffc25080: {PORT_RESETS:08x}")
    print("f2h_sdram0: out of reset")

    u.run(f"setenv bootargs {BOOTARGS}")
    u.s.write(b"bootz ${loadaddr} - ${fdtaddr}\r")     # not mmcboot: it would reset bootargs
    u.until(b"login:", 120, send=b"root\r")
    time.sleep(2)
    u.s.read(65536)
    print(f"Linux: up, {BOOTARGS.split()[-1]}")


if __name__ == "__main__":
    main()
