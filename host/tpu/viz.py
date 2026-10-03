"""run a workload on the instruction-stream core; with visualize_internals, record
every clock cycle of it in the Verilator model and write a cycle-by-cycle page.

cycle-level state only exists in simulation: the board exposes STATUS and four
perf counters. so a board run (serial:<port>) runs there for its outputs and
counters, then replays the same programs on a `make viz-sim` model for the
picture, and the page says which numbers came from where
"""
import json
import os
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

from . import isa
from .isa_device import CTRL, CTRL_CLEAR_PERF, IsaDevice, IsaSerialLink, IsaSimLink, open_link
from .isa_model import IsaModel
from .trace import delta_rows, read_vcd

ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = Path(__file__).with_name("viz_template.html")


def viz_sim_path(n):
    return ROOT / "sim" / "verilator" / f"trace_n{n}" / "tb_isa"


@dataclass
class Phase:
    """one program and its data words, run to its SIGNAL. traced: part of the picture"""
    name: str
    program: list
    data: list = field(default_factory=list)
    traced: bool = True


@dataclass
class Workload:
    """what to run and how to label it. labels (all optional, for the page):
    tiles   [{first, kt, nb, name}]: WMEM tile ranges, block-major then K-tile
    ub      [{start, m, chunks, name, kind ('in' or 'out'), n_out, note}]: UB regions, K-chunk-major
    acc     [{start, m, nb, name, last}]: ACC regions
    outputs {name, m, nb, n_out, batches}: how the host's OUT words decode
    wmem    WMEM rows already loaded (lists of N int8), shown before the trace writes any"""
    name: str
    title: str
    phases: list
    lede: str = ""
    labels: dict = field(default_factory=dict)
    ddr: list = field(default_factory=list)       # (address, bytes) the host writes first
    facts: dict = field(default_factory=dict)


def _model_outputs(link, wl):
    model = IsaModel(n=link.n, wmem_rows=link.wmem_rows, ub_depth=link.ub_depth,
                     acc_depth=link.acc_depth, param_depth=link.param_depth)
    for address, data in wl.ddr:
        model.ddr.write(address, data)
    return [model.run(ph.program, ph.data) for ph in wl.phases]


def _run_phase(dev, ph, recorder=None):
    """one phase, with the perf counters cleared at its start: (out words, perf)"""
    dev.link.write32(CTRL, CTRL_CLEAR_PERF)
    if recorder:
        out = recorder.run(ph.program, ph.data, label=ph.name, timeout=600.0)
    else:
        out = dev.run(ph.program, ph.data, timeout=600.0)
    return out, dev.perf()


def _perf_line(p):
    return f"{p['cycles']} cycles, MM beats {p['mm_beats']}, WSTALL {p['mm_wstall']}, SYNC {p['mm_sync']}"


def run_workload(build, link_spec, visualize_internals=False, out=None, viz_sim=None,
                 max_cycles=20000, profile_out=None, log=print):
    """build(n) -> Workload for an N x N array. link_spec: a tb_isa binary or
    serial:<port>. profile_out: also record the instruction profiler and write
    its page there (tpu/profile.py). returns a dict: outputs per phase, whether they match the
    reference model, perf counters, and the page's path when one was written"""
    link = open_link(link_spec)
    on_board = isinstance(link, IsaSerialLink)
    n = link.n
    result = {"link": link_spec}
    try:
        wl = build(link.n)
        expected = _model_outputs(link, wl)
        dev = IsaDevice(link)
        for address, data in wl.ddr:
            link.ddr_write(address, data)
        dev.reset()
        recorder = None
        if profile_out:
            from .profile import Recorder
            recorder = Recorder(dev)
        t = time.time()
        runs = [_run_phase(dev, ph, recorder) for ph in wl.phases]
        outs = [o for o, _ in runs]
        result.update(outputs=outs, perf=[p for _, p in runs], seconds=time.time() - t,
                      match=outs == expected, where="hardware" if on_board else "Verilator sim")
        log(f"{wl.title}: {result['where']} N={link.n}, outputs "
            f"{'match' if result['match'] else 'DIFFER from'} the reference model")
        for ph, p in zip(wl.phases, result["perf"]):
            log(f"  {ph.name}: {_perf_line(p)}")
        if recorder:
            from .profile import analyze, render_page
            where = "hardware (DE1-SoC)" if on_board else "Verilator sim"
            data = analyze(link.n, recorder.programs, recorder.events, (), recorder.dropped, dev.weight_lanes())
            data["source_short"] = where
            src = (f"Recorded by the core's instruction profiler on {where}: {len(recorder.events):,} events. "
                   + ("Cycle counts include the console link: the core waits for each word the host sends." if on_board else ""))
            Path(profile_out).write_text(render_page(data, f"Profile: {wl.title}", src))
            log(f"profile: {profile_out} ({len(recorder.events)} events, {recorder.dropped} dropped)")
            result["profile"] = str(profile_out)
    finally:
        link.close()
    if not visualize_internals:
        return result

    # the picture: a traced Verilator model of the same build
    binary = Path(viz_sim or viz_sim_path(n))
    if not binary.exists():
        raise FileNotFoundError(f"{binary}: build it with `make viz-sim N={n}`")
    hw = dict(result) if on_board else None
    sim = IsaSimLink(str(binary))
    try:
        if sim.n != n:
            raise ValueError(f"{binary} is N={sim.n}, the run was N={n}")
        wl = build(sim.n)
        dev = IsaDevice(sim)
        for address, data in wl.ddr:
            sim.ddr_write(address, data)
        fd, vcd = tempfile.mkstemp(suffix=".vcd", prefix="tpu-trace-")
        os.close(fd)
        traced = [k for k, ph in enumerate(wl.phases) if ph.traced] or list(range(len(wl.phases)))
        first, last = traced[0], traced[-1]
        dev.reset()
        souts, sperf = [], []
        for k, ph in enumerate(wl.phases):
            if k == first:
                sim.trace(vcd)
            o, p = _run_phase(dev, ph)
            souts.append(o)
            sperf.append(p)
            if k == last:
                sim.trace(None)
    finally:
        sim.close()
    keys, rows, t0 = read_vcd(vcd, sim.n)
    os.unlink(vcd)
    ix = {k: i for i, k in enumerate(keys)}
    done = [i for i in range(1, len(rows)) if rows[i][ix["done"]] and not rows[i - 1][ix["done"]]]
    if done:
        rows = rows[:done[-1] + 6]
    if len(rows) > max_cycles:
        log(f"trace: keeping the first {max_cycles} of {len(rows)} cycles (--max-cycles)")
        rows = rows[:max_cycles]

    phases = [wl.phases[k] for k in traced]
    prog = []
    for ph in phases:
        prog += [[f"{w:016X}", isa.disasm(w), ph.name] for w in ph.program]
    sim_match = souts == expected
    facts = {
        "workload": wl.title,
        "array": f"{sim.n} × {sim.n}, WMEM {sim.wmem_rows} rows, UB {sim.ub_depth}, ACC {sim.acc_depth}",
        "traced": ", ".join(ph.name for ph in phases) + f" ({len(rows)} cycles)",
        "not traced": ", ".join(ph.name for k, ph in enumerate(wl.phases) if k not in traced) or "nothing",
    }
    for k, ph in enumerate(wl.phases):
        facts[f"perf, {ph.name} (sim)"] = _perf_line(sperf[k])
        if hw:
            facts[f"perf, {ph.name} (hardware)"] = _perf_line(hw["perf"][k])
    facts.update(wl.facts)
    if hw:
        facts["hardware cycle counts"] = ("include the console link: the core waits on each word the "
                                          "host sends. MM beats count rows issued, the same on both")
    source = (f"Recorded in a Verilator simulation of tpu_top, the RTL the DE1-SoC bitstream is built "
              f"from, at N = {sim.n}. Every value on the page is a signal from that simulation.")
    if hw:
        source += (f" The board ran the same programs over {hw['link']}: its output words "
                   f"{'are identical to' if hw['outputs'] == souts else 'DIFFER from'} the simulation's.")
    meta = {
        "N": sim.n, "t0": t0, "title": wl.title, "lede": wl.lede,
        "eyebrow": f"TPU · {wl.name} · Verilator sim · {time.strftime('%Y-%m-%d')}",
        "source": source, "host": "Host (ARM)" if hw else "Host",
        "prog": prog,
        "data_total": sum(len(ph.data) for ph in phases),
        "out_total": sum(len(expected[k]) for k in traced),
        "depths": {"wmem": sim.wmem_rows, "ub": sim.ub_depth, "acc": sim.acc_depth},
        "check": {"ok": sim_match, "what": "reference model, word for word"},
        "facts": facts,
        **wl.labels,
    }
    if hw:
        beats = [p["mm_beats"] for p in hw["perf"]] == [p["mm_beats"] for p in sperf]
        meta["hardware"] = {"ok": hw["outputs"] == souts and hw["match"] and beats,
                            "summary": ("same outputs" if hw["outputs"] == souts else "outputs differ from the sim")
                            + (", same MM beats" if beats else ", MM beats differ")}
    page = render(keys, rows, meta)
    out = Path(out or f"{wl.name}-n{sim.n}-viz.html")
    out.write_text(page)
    log(f"visualize: {out} ({len(rows)} cycles, {len(page) / 1e6:.1f} MB); sim outputs "
        f"{'match' if sim_match else 'DIFFER from'} the reference model")
    result.update(page=str(out), cycles=len(rows), sim_match=sim_match)
    return result


def render(keys, rows, meta):
    data = json.dumps({"keys": keys, "rows": delta_rows(rows), "meta": meta}, separators=(",", ":"))
    data = data.replace("</", "<\\/")
    page = TEMPLATE.read_text()
    title = meta["title"].replace("&", "&amp;").replace("<", "&lt;")
    return page.replace("__TITLE__", title).replace("__DATA__", data)
