"""the core's instruction profiler (rtl/common/profiler.sv): its events, the
instruction spans they stand for, and the profile file qwen-run --profile writes.

an event is 128 bits: [39:0] cycle, [40] dispatch, [44:41] pops, [48:45] completions
(LD, WT, MM, ACT), and from bit 49, 19 bits per engine: the cycles it was blocked
since its previous completion (saturating at BLOCKED_MAX). a WAIT's own wait
comes from the timestamps instead (Span.waited), which can't saturate. the dispatcher issues in program order and routes by opcode, and every
engine pops and completes in its queue's order, so the k-th pop on MM is the k-th
instruction routed to MM: no instruction ids travel in the events.

a profile file (little-endian):
  b"TPUP", u32 version, u32 N, and from version 2 u32 weight lanes (version 1: 1)
  then records, each a tag byte:
    b"P" u32 label length, label, u32 count, count x u64   a program, as pushed
    b"E" u32 count, count x 4 x u32                         events, oldest first
    b"D" u32 dropped                                        events the FIFO lost
    b"M" u32 label length, label, f64 host seconds          a mark: what the next programs are for
"""
import struct
from dataclasses import dataclass, field

from . import isa

ENGINES = ("LD", "WT", "MM", "ACT")
ROUTE = {"WR_WMEM": 0b0001, "WR_UB": 0b0001, "WR_BIAS": 0b0001, "WR_QUANT": 0b0001, "RD_DDR_UB": 0b0001,
         "SET_WBASE": 0b0010, "MATMUL": 0b0110, "ACTIVATE": 0b1000, "RD_UB": 0b1000, "SET_OBASE": 0b1000}


BLOCKED_MAX = (1 << 19) - 1


def decode_event(e):
    return dict(cycle=e & ((1 << 40) - 1), dispatch=e >> 40 & 1, pop=e >> 41 & 0xF, done=e >> 45 & 0xF,
                blocked=[e >> (49 + 19 * k) & BLOCKED_MAX for k in range(4)])


def route(word):
    name, f = isa.decode(word)
    if name == "WAIT":
        return 1 << f["target"]
    return ROUTE.get(name, 0)


@dataclass
class Span:
    """one instruction: when it was dispatched, and on each engine it went to,
    when that engine popped and completed it and how long it was blocked first"""
    program: int
    index: int
    word: int
    dispatch: int = None
    start: dict = field(default_factory=dict)
    end: dict = field(default_factory=dict)
    blocked: dict = field(default_factory=dict)
    waited: dict = field(default_factory=dict)     # a WAIT: cycles from reaching its queue's head to its pop

    @property
    def name(self):
        return isa.decode(self.word)[0] or "?"


def reconstruct(programs, events):
    """programs: [(label, words)] in the order they were pushed; events: decoded,
    oldest first. -> list of Span, program order"""
    spans = [Span(p, i, w) for p, (_, words) in enumerate(programs) for i, w in enumerate(words)]
    queues = [[s for s in spans if route(s.word) >> e & 1] for e in range(4)]
    k, popped, done = 0, [0] * 4, [0] * 4
    for ev in events:
        if ev["dispatch"]:
            if k >= len(spans):
                raise ValueError("more dispatches than instructions: the events don't match the programs")
            spans[k].dispatch = ev["cycle"]
            k += 1
        for e in range(4):
            if ev["pop"] >> e & 1:
                queues[e][popped[e]].start[e] = ev["cycle"]
                popped[e] += 1
            if ev["done"] >> e & 1:
                s = queues[e][done[e]]
                s.end[e] = ev["cycle"]
                s.blocked[e] = ev["blocked"][e]
                done[e] += 1
    # a WAIT reaches the head of its queue once it's dispatched and the engine is
    # done with what came before: for WT, whose fetch stage runs ahead of its
    # fill, once the previous instruction is popped
    for e in range(4):
        prev = None
        for s in queues[e]:
            if s.name == "WAIT" and e in s.start and s.dispatch is not None:
                ready = s.dispatch + 1
                if prev is not None:
                    ready = max(ready, (prev.start if e == 1 else prev.end).get(e, ready))
                s.waited[e] = max(0, s.start[e] - ready)
            prev = s
    return spans


def write_header(f, n, lanes=1):
    f.write(b"TPUP" + struct.pack("<III", 2, n, lanes))


def write_program(f, label, words):
    raw = label.encode()
    f.write(b"P" + struct.pack("<I", len(raw)) + raw + struct.pack(f"<I{len(words)}Q", len(words), *words))


def write_events(f, events, dropped=0):
    if events:
        f.write(b"E" + struct.pack("<I", len(events)))
        for e in events:
            f.write(struct.pack("<4I", *[(e >> (32 * k)) & 0xFFFFFFFF for k in range(4)]))
    if dropped:
        f.write(b"D" + struct.pack("<I", dropped))


def read_file(path):
    """-> (N, programs [(label, words)], raw events, dropped, marks [(program index, label, seconds)], lanes)"""
    data = open(path, "rb").read()
    if data[:4] != b"TPUP":
        raise ValueError(f"{path}: not a profile")
    version, n = struct.unpack_from("<II", data, 4)
    lanes = struct.unpack_from("<I", data, 12)[0] if version >= 2 else 1
    at, programs, events, dropped, marks = 16 if version >= 2 else 12, [], [], 0, []
    while at < len(data):
        tag = data[at:at + 1]
        at += 1
        if tag == b"P":
            (k,) = struct.unpack_from("<I", data, at)
            label = data[at + 4:at + 4 + k].decode()
            at += 4 + k
            (count,) = struct.unpack_from("<I", data, at)
            words = list(struct.unpack_from(f"<{count}Q", data, at + 4))
            at += 4 + 8 * count
            programs.append((label, words))
        elif tag == b"E":
            (count,) = struct.unpack_from("<I", data, at)
            w = struct.unpack_from(f"<{4 * count}I", data, at + 4)
            events += [w[4 * i] | w[4 * i + 1] << 32 | w[4 * i + 2] << 64 | w[4 * i + 3] << 96 for i in range(count)]
            at += 4 + 16 * count
        elif tag == b"M":
            (k,) = struct.unpack_from("<I", data, at)
            label = data[at + 4:at + 4 + k].decode()
            (seconds,) = struct.unpack_from("<d", data, at + 4 + k)
            marks.append((len(programs), label, seconds))
            at += 12 + k
        elif tag == b"D":
            dropped += struct.unpack_from("<I", data, at)[0]
            at += 4
        else:
            raise ValueError(f"{path}: bad record at byte {at - 1}")
    return n, programs, events, dropped, marks, lanes


class Recorder:
    """runs programs on an IsaDevice and keeps the profile: run() is IsaDevice.run
    with a label, drained after every program"""

    def __init__(self, dev):
        from .isa_device import CTRL, CTRL_CLEAR_PROFILE
        self.dev, self.programs, self.events, self.dropped = dev, [], [], 0
        dev.link.write32(CTRL, CTRL_CLEAR_PROFILE)

    def drain(self):
        ev, dropped = self.dev.profile_drain()
        self.events += ev
        self.dropped = max(self.dropped, dropped)     # the register counts since the last clear

    def run(self, program, data=(), label="", **kw):
        self.programs.append((label, list(program)))
        out = self.dev.run(program, data, poll=self.drain, **kw)
        self.drain()
        return out

    def save(self, path):
        with open(path, "wb") as f:
            write_header(f, self.dev.link.n, self.dev.weight_lanes())
            for label, words in self.programs:
                write_program(f, label, words)
            write_events(f, self.events, self.dropped)


# -- the page ---------------------------------------------------------------------
OPS = ["WR_WMEM", "WR_UB", "WR_BIAS", "WR_QUANT", "RD_DDR_UB", "SET_WBASE", "SET_OBASE",
       "MATMUL", "ACTIVATE", "RD_UB", "WAIT", "SIGNAL", "NOP"]


def analyze(n, programs, events, marks=(), dropped=0, lanes=1):
    """the page's data: per engine instruction a row [lane, program, index, op,
    start, end, blocked], dispatch times, programs and marks, cycles from the
    first event"""
    decoded = [decode_event(e) for e in events]
    spans = reconstruct(programs, decoded)
    t0 = decoded[0]["cycle"] if decoded else 0
    rows, missing = [], 0
    for s in spans:
        for e in range(4):
            if route(s.word) >> e & 1:
                if e not in s.start or e not in s.end:
                    missing += 1
                    continue
                rows.append([e, s.program, s.index, OPS.index(s.name) if s.name in OPS else len(OPS) - 1,
                             s.start[e] - t0, s.end[e] - t0,
                             s.waited[e] if s.name == "WAIT" and e in s.waited else s.blocked.get(e, 0)])
    first = 0
    progs = []
    for p, (label, words) in enumerate(programs):
        disp = [s.dispatch - t0 for s in spans[first:first + len(words)] if s.dispatch is not None]
        ends = [max(s.end.values()) - t0 for s in spans[first:first + len(words)] if s.end]
        mm = [isa.decode(w)[1] for w in words if isa.decode(w)[0] == "MATMUL"]
        progs.append(dict(label=label, first=first, count=len(words),
                          start=min(disp) if disp else None, end=max(ends) if ends else None,
                          tiles=sum(f["k_tiles"] * f["n_blocks"] for f in mm),
                          ideal=sum(f["k_tiles"] * f["n_blocks"] * max(f["m"], n // lanes) + n // lanes for f in mm),
                          words=[isa.disasm(w) for w in words]))
        first += len(words)
    end = max((r[5] for r in rows), default=0)
    return dict(N=n, lanes=lanes, rows=rows, programs=progs, end=end, events=len(events), dropped=dropped,
                missing=missing, marks=[dict(program=p, label=l, seconds=s) for p, l, s in marks], ops=OPS)


def render_page(data, title, source):
    import json
    from pathlib import Path
    data = dict(data, title=title, source=source)
    page = Path(__file__).with_name("profile_template.html").read_text()
    payload = json.dumps(data, separators=(",", ":")).replace("</", "<\\/")
    return page.replace("__TITLE__", title.replace("&", "&amp;").replace("<", "&lt;")).replace("__DATA__", payload)
