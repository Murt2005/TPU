#!/usr/bin/env python3
"""Turn a trace_tb VCD into a per-cycle JSON timeline of the datapath.

    python3 viz/vcd_to_trace.py trace.vcd -o trace.json

The VCD records everything; this keeps the ~100 signals the visualizer draws
and samples them once per cycle (on the rising edge) rather than on every
value change, which is what makes the result a clean frame sequence instead
of a change log.

The JSON it emits is the reference the viewer's JavaScript model is checked
against (viz/check_model.mjs), so its shape is a contract: one record per
cycle, each fully specified, no deltas.
"""
import argparse
import json
import re
import sys


def parse_vcd(path):
    """-> (signals: {full.name: id}, widths: {id: w}, changes: [(t, id, val)])"""
    signals, widths, changes = {}, {}, []
    scope, t = [], 0
    with open(path) as fh:
        in_defs = True
        for line in fh:
            line = line.strip()
            if not line:
                continue
            if in_defs:
                if line.startswith("$scope"):
                    scope.append(line.split()[2])
                elif line.startswith("$upscope"):
                    scope.pop()
                elif line.startswith("$var"):
                    p = line.split()
                    width, vid, name = int(p[2]), p[3], p[4]
                    signals[".".join(scope + [name])] = vid
                    widths[vid] = width
                elif line.startswith("$enddefinitions"):
                    in_defs = False
                continue
            if line[0] == "#":
                t = int(line[1:])
            elif line[0] in "bB":
                val, vid = line[1:].split(" ", 1)
                changes.append((t, vid.strip(), val))
            elif line[0] in "rR":
                pass                              # no reals in this design
            elif line[0] in "01xXzZ":
                changes.append((t, line[1:].strip(), line[0]))
    return signals, widths, changes


def to_int(bits, width, signed=True):
    """VCD binary string -> Python int. x/z reads as 0, which is what an
    unbuilt or reset signal should render as."""
    if bits is None:
        return 0
    b = bits.lower()
    if "x" in b or "z" in b:
        return 0
    b = b.rjust(width, "0" if b[0] != "1" else b[0])   # VCD left-truncates
    v = int(b, 2)
    if signed and width > 0 and len(b) >= width and b[-width] == "1":
        v -= 1 << width
    return v


def unpack(v, n, w, signed=True):
    """One packed [n-1:0][w-1:0] word -> n elements, index 0 = LSB slice."""
    out = []
    mask = (1 << w) - 1
    for i in range(n):
        x = (v >> (w * i)) & mask
        if signed and x >> (w - 1):
            x -= 1 << w
        out.append(x)
    return out


STATE_NAMES = [
    "IDLE", "RECV_LEN", "RECV_PAYLOAD", "EXEC", "WR_UB", "LD_WF", "LD_WF_GAP",
    "SWAP", "LOADING", "STREAM", "WAIT", "RESET_PULSE", "TX_STATUS", "TX_DATA",
    "SR_FLAGS", "SR_KT", "SR_RECV_TILE",
]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("vcd")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--rows", type=int, default=4)
    ap.add_argument("--cols", type=int, default=4)
    ap.add_argument("--m-tile", type=int, default=4)
    ap.add_argument("--meta", help="JSON line printed by trace_tb (inputs/result)")
    args = ap.parse_args()

    R, C, M = args.rows, args.cols, args.m_tile
    signals, widths, changes = parse_vcd(args.vcd)

    T = "TOP.tpu_core."
    want = {
        "state":   T + "u_seq.state",
        "loading": T + "seq_loading_phase",
        "sds_row": T + "u_sds.mmu_in_row",
        "sds_val": T + "u_sds.mmu_in_valid",
        "wf_col":  T + "u_wf.out_col",
        "wf_val":  T + "u_wf.out_col_valid",
        "ub_data": T + "ub_read_data",
        "ub_val":  T + "ub_read_valid",
        # The sequencer's control outputs. These are what the JS model in the
        # viewer has to be driven by: the FSM is counter-driven, so this
        # schedule depends only on the shape, never on the data.
        "ub_addr": T + "seq_ub_addr",
        "ub_en":   T + "seq_ub_en",
        "wf_we":   T + "seq_we_col",
        "swap":    T + "seq_swap_banks",
        "ac_row":  T + "u_accum.out_row",
        "ac_val":  T + "u_accum.out_row_valid",
        "bi_row":  T + "u_bias.out_row",
        "bi_val":  T + "u_bias.out_row_valid",
        "at_row":  T + "u_act.out_row",
        "at_val":  T + "u_act.out_row_valid",
    }
    for r in range(R):
        for c in range(C):
            pe = f"{T}u_mmu.gen_pe_rows.gen_row[{r}].gen_col[{c}].pe_inst."
            want[f"w{r}_{c}"]  = pe + "weight_reg"
            want[f"a{r}_{c}"]  = pe + "in_activation"
            want[f"av{r}_{c}"] = pe + "in_activation_valid"
            want[f"p{r}_{c}"]  = pe + "out_partial_sum"
            want[f"pv{r}_{c}"] = pe + "out_partial_sum_valid"

    missing = [k for k, n in want.items() if n not in signals]
    if missing:
        sys.exit(f"signals not in VCD (shape mismatch?): "
                 f"{[want[k] for k in missing[:4]]}")
    ids = {k: signals[n] for k, n in want.items()}
    # Several logical signals can share one VCD id; index changes by id.
    by_id = {}
    for t, vid, val in changes:
        by_id.setdefault(vid, []).append((t, val))

    # Walk time forward, holding last value -- a VCD only records changes.
    cursor = {vid: 0 for vid in by_id}
    cur = {vid: None for vid in by_id}
    max_t = max((t for t, _, _ in changes), default=0)

    def advance(t):
        for vid, lst in by_id.items():
            i = cursor[vid]
            while i < len(lst) and lst[i][0] <= t:
                cur[vid] = lst[i][1]
                i += 1
            cursor[vid] = i

    def val(key, signed=True):
        vid = ids[key]
        return to_int(cur.get(vid), widths[vid], signed)

    frames = []
    # trace_tb dumps twice per cycle; rising edges land on even timestamps.
    for t in range(0, max_t + 1, 2):
        advance(t)
        st = val("state", signed=False)
        f = {
            "c": t // 2,
            "state": STATE_NAMES[st] if st < len(STATE_NAMES) else str(st),
            "loading": val("loading", signed=False),
            "sds": {"row": unpack(val("sds_row", False), R, 8),
                    "valid": unpack(val("sds_val", False), R, 1, signed=False)},
            "wf": {"col": unpack(val("wf_col", False), C, 8),
                   "valid": unpack(val("wf_val", False), C, 1, signed=False)},
            "ub": {"data": unpack(val("ub_data", False), R, 8),
                   "valid": val("ub_val", signed=False),
                   "addr": val("ub_addr", signed=False),
                   "en": val("ub_en", signed=False)},
            "ctl": {"we": unpack(val("wf_we", False), C, 1, signed=False),
                    "swap": val("swap", signed=False)},
            "accum": {"row": unpack(val("ac_row", False), C, 16),
                      "valid": val("ac_val", signed=False)},
            "bias": {"row": unpack(val("bi_row", False), C, 16),
                     "valid": val("bi_val", signed=False)},
            "act": {"row": unpack(val("at_row", False), C, 16),
                    "valid": val("at_val", signed=False)},
            "pe": [[{
                "w":  val(f"w{r}_{c}"),
                "a":  val(f"a{r}_{c}"),
                "av": val(f"av{r}_{c}", signed=False),
                "p":  val(f"p{r}_{c}"),
                "pv": val(f"pv{r}_{c}", signed=False),
            } for c in range(C)] for r in range(R)],
        }
        frames.append(f)

    out = {"shape": {"rows": R, "cols": C, "m_tile": M}, "cycles": frames}
    if args.meta:
        out["meta"] = json.loads(args.meta)
    with open(args.out, "w") as fh:
        json.dump(out, fh, separators=(",", ":"))
    busy = sum(1 for f in frames if f["state"] not in ("IDLE",))
    print(f"{len(frames)} cycles ({busy} non-idle) -> {args.out}")


if __name__ == "__main__":
    main()
