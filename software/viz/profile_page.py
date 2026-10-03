#!/usr/bin/env python3
"""a profile file (qwen-run --profile, or tpu.profile.Recorder.save) -> a page of
the core's engines over the whole run: a zoomable timeline of every instruction
on LD, WT, MM and ACT, the host's gaps between programs, and where the cycles went
per matrix, per mark and per engine.

  profile_page.py qwen.prof -o qwen-profile.html [--title ...] [--source ...]
"""
import argparse
from pathlib import Path

from tpu.profile import analyze, read_file, render_page


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("profile")
    ap.add_argument("-o", "--out")
    ap.add_argument("--title", help="default: the file's name")
    ap.add_argument("--source", default="", help="where it ran, e.g. 'hardware (DE1-SoC)' or 'Verilator sim'")
    a = ap.parse_args()
    n, programs, events, dropped, marks = read_file(a.profile)
    data = analyze(n, programs, events, marks, dropped)
    data["source_short"] = a.source
    src = (f"Recorded by the core's instruction profiler (rtl/common/profiler.sv) on {a.source or 'the core'}: "
           f"{len(events):,} events for {len(programs):,} programs. Cycles count from the first event; "
           f"the core runs at 50 MHz on the board.")
    title = a.title or f"Profile: {Path(a.profile).stem}"
    out = Path(a.out or Path(a.profile).with_suffix(".html").name)
    out.write_text(render_page(data, title, src))
    print(f"{out}: {len(programs)} programs, {len(data['rows'])} engine instructions, {data['end']:,} cycles"
          + (f", {dropped} events DROPPED" if dropped else "") + (f", {data['missing']} incomplete" if data["missing"] else ""))


if __name__ == "__main__":
    main()
