"""wrap a U-Boot script as a legacy script image (what `mkimage -A arm -T script
-C none` makes), for `source` / callscript. no u-boot-tools needed

    python boards/de1soc/sw/mk-uboot-scr.py <script.txt> <u-boot.scr>
"""
import struct
import sys
import time
import zlib

IH_MAGIC = 0x27051956
IH_OS_LINUX, IH_ARCH_ARM, IH_TYPE_SCRIPT, IH_COMP_NONE = 5, 2, 6, 0


def script_image(text, name="script"):
    body = text.encode()
    data = struct.pack(">II", len(body), 0) + body          # one-file size table, then the file
    header = struct.pack(">IIIIIIIBBBB32s", IH_MAGIC, 0, int(time.time()), len(data), 0, 0,
                         zlib.crc32(data), IH_OS_LINUX, IH_ARCH_ARM, IH_TYPE_SCRIPT, IH_COMP_NONE,
                         name.encode()[:31])
    header = header[:4] + struct.pack(">I", zlib.crc32(header)) + header[8:]
    return header + data


if __name__ == "__main__":
    src, dst = sys.argv[1:3]
    open(dst, "wb").write(script_image(open(src).read(), "TPU with f2h_sdram0"))
