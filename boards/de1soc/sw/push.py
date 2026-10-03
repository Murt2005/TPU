"""Send a big file to the DE1-SoC over its console, in pieces: each piece goes
through recv (BoardConsole.upload's block-wise receiver, ~110 KB/s at 1.5625
Mbaud) and is md5-checked, retried alone if a byte was lost, then appended to
the target and deleted, so the card needs room for one piece beyond the file.
It resumes after the last whole piece if stopped, and checks the whole file's
md5 before renaming it into place.

    python boards/de1soc/sw/push.py /dev/cu.usbserial-<id>0 software/qwen/out/qwen-ddr.bin /mnt/boot/qwen/qwen-ddr.bin

needs /mnt/boot/recv on the board (boards/de1soc/fpga/hps: make recv)
"""
import argparse
import hashlib
import os
import re
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "..", "host"))
from tpu.isa_device import BoardConsole  # noqa: E402


def until_prompt(console, command, timeout):
    """a command's output, read until the shell's prompt comes back"""
    console._s.reset_input_buffer()
    console._s.write(command.encode() + b"\r")
    out, end = b"", time.time() + timeout
    while time.time() < end and not out.rstrip().endswith(b"#"):
        out += console._s.read(4096)
    if not out.rstrip().endswith(b"#"):
        sys.exit(f"`{command}`: no prompt within {timeout} s")
    return out.decode(errors="replace")


def remote_size(console, path):
    out = console.run(f"ls -l {path} 2>/dev/null || echo missing", 2)
    m = re.search(r"\s(\d+)\s+\w{3}\s+\d+\s+[\d:]+\s+" + re.escape(path), out)
    return int(m.group(1)) if m else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port")
    ap.add_argument("local")
    ap.add_argument("remote")
    ap.add_argument("--piece", type=int, default=16 << 20)
    ap.add_argument("--receiver", default="/mnt/boot/recv")
    args = ap.parse_args()

    total = os.path.getsize(args.local)
    partial = args.remote + ".partial"
    console = BoardConsole(args.port)
    console.run("mount /dev/mmcblk0p1 /mnt/boot 2>/dev/null", 1)
    done = remote_size(console, partial)
    if done % args.piece:
        print(f"{partial}: {done} bytes, not a whole number of pieces; starting over")
        console.run(f"rm -f {partial}", 1)
        done = 0
    t0 = time.time()
    with open(args.local, "rb") as fh, tempfile.TemporaryDirectory() as tmp:
        fh.seek(done)
        while done < total:
            data = fh.read(args.piece)
            piece = os.path.join(tmp, "piece")
            open(piece, "wb").write(data)
            for attempt in range(4):
                try:
                    console.upload(piece, args.remote + ".piece", rate=None, fast=True, receiver=args.receiver)
                    break
                except RuntimeError as e:
                    print(f"  piece at {done}: {e}; again")
                    console = BoardConsole(args.port)
            else:
                sys.exit(f"piece at {done} failed 4 times")
            until_prompt(console, f"cat {args.remote}.piece >> {partial} && rm {args.remote}.piece", 120)
            if remote_size(console, partial) != done + len(data):
                sys.exit(f"{partial} didn't grow to {done + len(data)}")
            done += len(data)
            print(f"  {done:,} / {total:,} bytes ({100 * done / total:.0f}%), "
                  f"{(time.time() - t0) / 60:.1f} min", flush=True)
    want = hashlib.md5(open(args.local, "rb").read()).hexdigest()
    out = until_prompt(console, f"md5sum {partial}", 900)
    if want not in out:
        sys.exit(f"md5 of the whole file differs: {out!r}")
    until_prompt(console, f"mv {partial} {args.remote}; sync", 300)
    print(f"{args.remote}: {total:,} bytes, md5 {want}, {(time.time() - t0) / 60:.1f} min")


if __name__ == "__main__":
    main()
