#!/usr/bin/env python3
"""Check that every copy of the wire-protocol constants agrees.

The opcodes, flag bits and status bytes are defined once per language:

    rtl/core/tpu_pkg.sv                      canonical (the RTL side)
    host/tpu/protocol.py                     must mirror all of it
    tests/verilator/tb_tpu_top.cpp           the subset the C++ bench uses
    boards/pico2-ice/firmware/tpu_tile.c     the subset the firmware uses,
                                             plus FW_* shared with the host

Nothing generates one from another, so this is what stops them drifting.
Flags are compared as byte masks: the RTL stores FLAG_* as bit positions,
the other three as masks. Run via `make check-protocol` (also part of
`make lint`). Exits non-zero on any mismatch.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NAME = r"(CMD_[A-Z_]+|FLAG_[A-Z_]+|STATUS_[A-Z]+|FW_[A-Z_]+)"


def num(s):
    s = s.strip()
    if s.startswith("8'h"):
        return int(s[3:], 16)
    if len(s) == 3 and s[0] == s[2] == "'":        # C char literal, e.g. 'T'
        return ord(s[1])
    return int(s, 0)


def from_sv(path):
    out = {}
    for name, val in re.findall(rf"localparam\s+[^=]*?\b{NAME}\s*=\s*([^;]+);",
                                path.read_text()):
        out[name] = num(val)
    for name in [n for n in out if n.startswith("FLAG_")]:
        out[name] = 1 << out[name]                  # bit position -> mask
    return out


def from_c(path, pattern):
    return {n: num(v) for n, v in re.findall(pattern, path.read_text())}


def from_py(path):
    ns = {}
    exec(compile(path.read_text(), str(path), "exec"), ns)
    out = {k: v for k, v in ns.items()
           if re.fullmatch(NAME, k) and isinstance(v, int)}
    magic = ns["FW_PROBE_MAGIC"]                   # b"T\x01" = FW_MAGIC + FW_VERSION
    out["FW_MAGIC"], out["FW_VERSION"] = magic[0], magic[1]
    return out


def main():
    sources = {
        "rtl/core/tpu_pkg.sv": from_sv(ROOT / "rtl/core/tpu_pkg.sv"),
        "host/tpu/protocol.py": from_py(ROOT / "host/tpu/protocol.py"),
        "tests/verilator/tb_tpu_top.cpp": from_c(
            ROOT / "tests/verilator/tb_tpu_top.cpp",
            rf"static\s+constexpr\s+\w+\s+{NAME}\s*=\s*([^;]+);"),
        "boards/pico2-ice/firmware/tpu_tile.c": from_c(
            ROOT / "boards/pico2-ice/firmware/tpu_tile.c",
            rf"#define\s+{NAME}\s+(\S+)"),
    }
    canon = sources["rtl/core/tpu_pkg.sv"]
    py = sources["host/tpu/protocol.py"]
    errors = []
    if not canon:
        errors.append("found no constants in rtl/core/tpu_pkg.sv -- parser out of date?")
    for name in sorted(set(canon) - set(py)):
        errors.append(f"{name} is in rtl/core/tpu_pkg.sv but missing from host/tpu/protocol.py")
    # Every name defined in more than one place must have one value.
    names = sorted(set().union(*sources.values()))
    compared = 0
    for name in names:
        vals = {src: d[name] for src, d in sources.items() if name in d}
        if len(vals) < 2:
            continue
        compared += 1
        if len(set(vals.values())) > 1:
            detail = ", ".join(f"{src}=0x{v:02X}" for src, v in vals.items())
            errors.append(f"{name} disagrees: {detail}")
    for e in errors:
        print(f"check-protocol: {e}", file=sys.stderr)
    if errors:
        return 1
    counts = ", ".join(f"{Path(s).name} {len(d)}" for s, d in sources.items())
    print(f"check-protocol: {compared} shared constants agree ({counts})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
