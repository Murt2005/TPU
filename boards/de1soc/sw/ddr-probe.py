"""DDR3 bandwidth from the FPGA, measured on the DE1-SoC: drives ddr_probe (the
burst-read master on the 128-bit FPGA-to-SDRAM port, boards/de1soc/top/ddr-probe.sv)
through its ARM tool, over the HPS console.

    python boards/de1soc/sw/ddr-probe.py /dev/cu.usbserial-<id>0

1. checks the probe is there and the port is out of reset (fpgaportrst has 0x133).
   the port must be configured and released in U-Boot, before Linux runs: staticcfg's
   applycfg, then fpgaportrst. releasing it from Linux without applycfg hangs the
   whole HPS on the probe's first read (2026-10-02)
2. checks the data: the probe's checksum of a range against the ARM's, read through
   /dev/mem from the same physical addresses
3. sweeps burst length × bursts in flight, with Linux idle and then with the ARM
   streaming through 64 MB of its own memory
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "..", "host"))
from tpu.isa_device import BoardConsole  # noqa: E402

TOOL = "/mnt/boot/ddr_probe"
CLOCK_HZ = 50e6
FPGAPORTRST, STATICCFG = 0xFFC25080, 0xFFC2505C
PORT_RESETS = 0x133           # command port 0, read ports 0-1, write ports 0-1
IDENTITY = 0xDD3B0001
FIELDS = ("identity", "control", "address", "beats", "burst", "outstanding", "cycles", "received",
          "checksum", "latency_first", "latency_max", "latency_sum", "wait_cycles", "issue_cycles")
HEX_WORD = r"[0-9a-f]{8}"


def peek(console, address):
    m = re.search(rf"{address:08x} ({HEX_WORD})", console.run(f"{TOOL} peek {address:x}", 1))
    if not m:
        sys.exit(f"peek {address:#x} failed")
    return int(m.group(1), 16)


def probe(console, address, beats, burst, outstanding):
    out = console.run(f"{TOOL} run {address:x} {beats:x} {burst:x} {outstanding:x}", 3)
    m = re.search(rf"({HEX_WORD}(?: {HEX_WORD}){{13}})", out)
    if not m:
        sys.exit(f"probe run failed: {out!r}")
    r = dict(zip(FIELDS, (int(w, 16) for w in m.group(1).split())))
    if r["control"] == 0xDEAD:
        sys.exit("probe timed out: the port never answered (still in reset, or applycfg needed)")
    if r["received"] != beats:
        sys.exit(f"probe received {r['received']} of {beats} beats")
    bursts = beats // burst
    r["mb_per_s"] = beats * 16 / (r["cycles"] / CLOCK_HZ) / 1e6
    r["rows_per_cycle"] = beats * 2 / r["cycles"]        # 8-byte weight rows, N = 8
    r["latency_mean"] = r["latency_sum"] / bursts
    return r


def sweep(console, address, beats, label):
    print(f"\n{label}: {beats * 16 // 1024} KB per run at {address:#x}, {CLOCK_HZ / 1e6:.0f} MHz, "
          f"peak {16 * CLOCK_HZ / 1e6:.0f} MB/s")
    print(f"{'burst':>5} {'in flight':>9} {'MB/s':>7} {'rows/cyc':>8} {'lat first':>9} {'lat mean':>8} "
          f"{'lat max':>7} {'waitreq %':>9}")
    best = None
    for burst in (1, 2, 4, 8, 16, 32, 64, 128):
        for outstanding in (1, 2, 4, 8, 14):
            r = probe(console, address, beats, burst, outstanding)
            print(f"{burst:>5} {outstanding:>9} {r['mb_per_s']:>7.1f} {r['rows_per_cycle']:>8.3f} "
                  f"{r['latency_first']:>9} {r['latency_mean']:>8.1f} {r['latency_max']:>7} "
                  f"{100 * r['wait_cycles'] / r['cycles']:>9.1f}")
            if best is None or r["mb_per_s"] > best[0]:
                best = (r["mb_per_s"], burst, outstanding)
    print(f"best: {best[0]:.1f} MB/s at burst {best[1]}, {best[2]} in flight")
    return best


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port", help="the HPS console, /dev/cu.usbserial-<id>0")
    ap.add_argument("--address", type=lambda s: int(s, 0), default=0x30000000,
                    help="physical address to read (reads only; default 0x30000000)")
    ap.add_argument("--beats", type=lambda s: int(s, 0), default=1 << 18, help="16-byte beats per run (4 MB)")
    ap.add_argument("--no-load", action="store_true", help="skip the sweep under ARM memory load")
    args = ap.parse_args()

    console = BoardConsole(args.port)
    console.run("mount /dev/mmcblk0p1 /mnt/boot 2>/dev/null", 1)

    identity = peek(console, 0xFF240000)
    if identity != IDENTITY:
        sys.exit(f"no ddr_probe at 0xFF240000 (read {identity:#010x}): wrong bitstream?")
    reset_mask, staticcfg = peek(console, FPGAPORTRST), peek(console, STATICCFG)
    print(f"fpgaportrst {reset_mask:#x}, staticcfg {staticcfg:#x}")
    if reset_mask & PORT_RESETS != PORT_RESETS:
        sys.exit("the FPGA-to-SDRAM port is in reset: apply its configuration and release it in U-Boot "
                 "(releasing it from Linux hangs the HPS)")

    # data check: kernel text, which nothing writes while it runs
    check_address, check_beats = 0x00100000, 1 << 16
    r = probe(console, check_address, check_beats, 16, 8)
    m = re.search(rf"\n({HEX_WORD})\s", console.run(f"{TOOL} sum {check_address:x} {check_beats * 16:x}", 2))
    arm_sum = int(m.group(1), 16)
    print(f"checksum over {check_beats * 16 // 1024} KB at {check_address:#x}: probe {r['checksum']:#010x}, "
          f"ARM {arm_sum:#010x} {'MATCH' if r['checksum'] == arm_sum else 'MISMATCH'}")
    if r["checksum"] != arm_sum:
        sys.exit(1)

    sweep(console, args.address, args.beats, "Linux idle")
    if not args.no_load:
        console.run(f"{TOOL} load 40 &", 1)
        try:
            sweep(console, args.address, args.beats, "ARM streaming 64 MB")
        finally:
            console.run("kill %1", 1)


if __name__ == "__main__":
    main()
