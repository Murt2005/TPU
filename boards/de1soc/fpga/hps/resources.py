#!/usr/bin/env python3
"""where the FPGA's DSP blocks, RAM blocks and logic go, from a Quartus fit report.

  resources.py [build/ghrd/output_files/soc_system.fit.rpt] [--all]

prints the device totals, the TPU's hierarchy (ALMs, registers, M10K blocks, DSP
blocks per module), every RAM with its shape, block count and how full its blocks
are, and every DSP block by module and mode. --all includes the GHRD's own RAMs
and modules, not just the TPU's.

an M10K block is 10,240 bits, configurable from 8K x 1 to 256 x 40 (512 x 20 in
simple dual port). a DSP block holds one 27x27 multiplier, two 18x19, or three
9x9 that share their register clocks, enables and clears
"""
import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

DEFAULT = Path(__file__).with_name("build") / "ghrd" / "output_files" / "soc_system.fit.rpt"


def tables(path):
    """name -> (header, rows) for every ';'-delimited table in the report"""
    lines = Path(path).read_text(encoding="latin-1").splitlines()
    out, i = {}, 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("; ") and i + 1 < len(lines) and lines[i + 1].startswith("+--") and line.rstrip().endswith(";"):
            title = line.strip("; ").strip()
            j = i + 2
            header, rows = None, []
            while j < len(lines) and (lines[j].startswith(";") or lines[j].startswith("+")):
                if lines[j].startswith(";"):
                    cells = [c.strip() for c in lines[j].strip().strip(";").split(";")]
                    if header is None:
                        header = cells
                    else:
                        rows.append(cells)
                j += 1
            out.setdefault(title, (header, rows))
            i = j
        else:
            i += 1
    return out


def short(name):
    """drop the GHRD prefix and Quartus's generated suffixes"""
    name = name.replace("soc_system:u0|", "").replace("tpu_top:tpu_0|tpu_core:u_core|", "core|")
    name = re.sub(r"\|altsyncram(_\w+)?:[^|]*", "", name)
    name = re.sub(r"\|ALTSYNCRAM$", "", name)
    name = re.sub(r"\w+:(\w+)", r"\1", name)
    return name


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("report", nargs="?", default=str(DEFAULT))
    ap.add_argument("--all", action="store_true", help="the GHRD's RAMs and modules too")
    a = ap.parse_args()
    t = tables(a.report)

    # -- totals
    head, rows = t.get("Fitter Resource Usage Summary", (None, []))
    for r in rows:
        if r[0] in ("Logic utilization (ALMs needed / total ALMs on device)", "Total DSP Blocks",
                    "M10K blocks", "Total block memory bits", "Total registers"):
            print(f"{r[0]:<58} {r[1]}")
    print()

    # -- the TPU's hierarchy
    head, rows = t.get("Fitter Resource Utilization by Entity", (None, []))
    if head:
        col = {h: k for k, h in enumerate(head)}
        alm = col.get("ALMs needed [=A-B+C]")
        regs = next(k for h, k in col.items() if h.startswith("Dedicated Logic Registers"))
        m10k = col.get("M10Ks")
        dsp = col.get("DSP Blocks")
        full = col.get("Full Hierarchy Name")
        print(f"{'module':<62}{'ALMs':>10}{'regs':>8}{'M10K':>6}{'DSP':>5}")
        # one line per module type under each parent: 64 pe become "pe x64"
        groups = {}
        order = []
        for r in rows:
            name = r[full]
            if not a.all and "tpu_top:tpu_0" not in name:
                continue
            parts = name.strip("|").split("|")
            depth = len(parts) - (3 if "tpu_top:tpu_0" in name else 1)
            if depth > (3 if a.all else 2) or depth < 0:
                continue
            parent = "|".join(parts[:-1])
            kind = parts[-1].split(":")[0]
            key = (parent, kind, depth)
            if key not in groups:
                groups[key] = [0, 0.0, 0, 0, 0]
                order.append(key)
            g = groups[key]
            g[0] += 1
            g[1] += float(r[alm].split()[0])
            g[2] += int(r[regs].split()[0])
            g[3] += int(r[m10k] or 0)
            g[4] += int(r[dsp] or 0)
        for key in order:
            (parent, kind, depth), g = key, groups[key]
            label = "  " * depth + kind + (f" x{g[0]}" if g[0] > 1 else "")
            print(f"{label:<62}{g[1]:>10.0f}{g[2]:>8}{g[3]:>6}{g[4]:>5}")
        print()

    # -- RAMs
    head, rows = t.get("Fitter RAM Summary", (None, []))
    if head:
        col = {h: k for k, h in enumerate(head)}
        print(f"{'RAM':<62}{'mode':>18}{'shape':>14}{'M10K':>6}{'bits':>10}{'full':>7}")
        total = 0
        for r in rows:
            name = r[col["Name"]]
            if not a.all and "tpu_top:tpu_0" not in name:
                continue
            blocks = int(r[col["M10K blocks"]]) if r[col["M10K blocks"]].isdigit() else 0
            bits = int(r[col["Size"]]) if r[col["Size"]].isdigit() else 0
            total += blocks
            fill = bits / (blocks * 10240) if blocks else 0
            shape = f"{r[col['Port A Depth']]}x{r[col['Port A Width']]}"
            print(f"{short(name)[:61]:<62}{r[col['Mode']]:>18}{shape:>14}{blocks:>6}{bits:>10}{fill:>7.0%}")
        print(f"{'':<62}{'':>18}{'total':>14}{total:>6}")
        print()

    # -- DSP blocks
    head, rows = t.get("DSP Block Details", (None, []))
    if head:
        col = {h: k for k, h in enumerate(head)}
        by = defaultdict(lambda: defaultdict(int))
        for r in rows:
            name = short(r[col["Name"]])
            if not a.all and not name.startswith("core|") and "tpu" not in name:
                continue
            module = re.sub(r"\[\d+\]", "[*]", name.rsplit("|", 1)[0])
            by[module][r[col["Mode"]]] += 1
        print(f"{'DSP blocks, by module':<62}{'mode':>28}{'blocks':>8}")
        for module, modes in sorted(by.items(), key=lambda kv: -sum(kv[1].values())):
            for mode, count in modes.items():
                print(f"{module[:61]:<62}{mode:>28}{count:>8}")
    head, rows = t.get("Fitter DSP Block Usage Summary", (None, []))
    if rows:
        print()
        for r in rows:
            if r[0]:
                print(f"  {r[0]:<36}{r[1]:>6}")


if __name__ == "__main__":
    sys.exit(main())
