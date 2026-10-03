"""Phase 4 checks: runtime/qwen-run (the host side in C) against the numpy
reference and the simulated core.

    make -C software/qwen/runtime
    PATH=$PWD/.venv/bin:$PATH make rtl-sim N=8
    software/qwen/.venv/bin/python software/qwen/test_runtime.py

1. programs: every program qwen-run builds == core_runtime.py's, word for word,
   for every matrix at m = 1..16 (where one program holds it)
2. the C host math with the ref core (an exact int8 matmul in C): greedy text ==
   the numpy core path's on several prompts; perplexity on WikiText-2 within 1%
   of the numpy core path's (end to end, float32 in C vs numpy rounds a few int8
   values differently, so exact equality isn't expected; see check.py)
3. qwen-run against the Verilator core, every matmul logged: each int32 output
   == exact_matmul of its logged int8 input, and the whole log == the ref
   core's, byte for byte (same host code, same int32 -> the same everything)
"""
import os
import subprocess
import sys
import tempfile

import numpy as np
import pyarrow.parquet as pq

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, "..", "..")
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, "host"))
from core_runtime import CoreRuntime  # noqa: E402
from qwen import Qwen, exact_matmul  # noqa: E402
from tokenizer import Tokenizer  # noqa: E402

RUN = os.path.join(HERE, "runtime", "qwen-run")
OUT = os.path.join(HERE, "out")
IMAGE = os.path.join(OUT, "qwen-ddr.bin")
TB_ISA = os.path.join(REPO, "sim", "verilator", "core_n8", "tb_isa")
failures = []


def check(name, ok, detail=""):
    print(f"[{'PASS' if ok else 'FAIL'}] {name}{(': ' + detail) if detail else ''}", flush=True)
    if not ok:
        failures.append(name)


def run(*args):
    return subprocess.run([RUN, "--tables", OUT, *args], capture_output=True, text=True, check=True)


def generated_ids(stdout):
    return [int(t.split("]")[0]) for t in stdout.split("[")[1:]]


def read_log(path):
    """[(matrix index, xq, acc)] from qwen-run --log"""
    raw = open(path, "rb").read()
    calls, at = [], 0
    while at < len(raw):
        index, m, k, n = np.frombuffer(raw, "<u4", 4, at)
        at += 16
        xq = np.frombuffer(raw, np.int8, m * k, at).reshape(m, k)
        at += m * k
        acc = np.frombuffer(raw, "<i4", m * n, at).reshape(m, n)
        at += 4 * m * n
        calls.append((int(index), xq, acc))
    return calls


def main():
    host = np.load(os.path.join(OUT, "qwen-host.npz"))
    sm = np.load(os.path.join(OUT, "smoothing.npz"))
    smoothing = {(int(k.split(".")[0]), k.split(".")[1]): sm[k] for k in sm.files if k != "alpha"}
    tok = Tokenizer.from_dir(os.path.join(HERE, "model"))
    tmp = tempfile.mkdtemp()

    # 1. programs, at the simulator's DDR3 base (0)
    path = os.path.join(tmp, "programs.txt")
    run("--core", "null", "--programs", path)

    class NoDevice:
        link = None
    rt = CoreRuntime(NoDevice(), host, 0, os.path.getsize(IMAGE))
    bad = count = 0
    for line in open(path):
        name, m, *words = line.split()
        want, _, _ = rt.program(name, int(m))
        count += 1
        bad += [int(w, 16) for w in words] != want
    check(f"programs: {count} (every matrix, m = 1..16): qwen-run's == core_runtime.py's, word for word",
          bad == 0 and count > 1500, f"{bad} differ")

    # 2. host math, ref core: text and perplexity against the numpy core path
    model = Qwen(core=True, smoothing=smoothing)
    ref_core = "ref:" + IMAGE
    same = 0
    prompts = ["The capital of France is", "def fibonacci(n):", "In 1905, Albert Einstein",
               "The quick brown fox", "Water boils at"]
    for prompt in prompts:
        ids = tok.encode(prompt)
        got = generated_ids(run("--core", ref_core, "--ids", ",".join(map(str, ids)), "--generate", "8").stdout)
        want, cache = [], model.new_cache()
        logits = model.forward(ids, cache)
        for _ in range(8):
            want.append(int(np.argmax(logits[-1])))
            logits = model.forward([want[-1]], cache)
        same += got == want
        print(f"    {prompt!r} -> C {tok.decode(got)!r}{'' if got == want else f' | numpy {tok.decode(want)!r}'}")
    check(f"greedy text, C + ref core == numpy core path, {len(prompts)} prompts x 8 tokens",
          same >= len(prompts) - 1, f"{same} of {len(prompts)} identical")

    text = "\n\n".join(pq.read_table(os.path.join(HERE, "data", "wikitext-2-raw-v1-test.parquet"))
                       .column("text").to_pylist())[:200000]
    windows = np.array(tok.encode(text))[:8 * 256].astype("<i4")
    ids_path = os.path.join(tmp, "wikitext.i32")
    windows.tofile(ids_path)
    c_ppl = float(run("--core", ref_core, "--score", ids_path, "--window", "256").stdout.split()[1])
    nll, count = 0.0, 0
    for w in windows.reshape(8, 256):
        lp = model.forward(w, model.new_cache())[:-1]
        lp = lp - lp.max(-1, keepdims=True)
        lp = lp - np.log(np.exp(lp).sum(-1, keepdims=True))
        nll -= lp[np.arange(255), w[1:]].sum()
        count += 255
    np_ppl = float(np.exp(nll / count))
    check(f"perplexity, {count:,} WikiText-2 tokens: C + ref core {c_ppl:.3f}, numpy core path {np_ppl:.3f}",
          abs(c_ppl / np_ppl - 1) < 0.01)

    # 3. the simulated core, every matmul logged and checked
    ids = ",".join(map(str, tok.encode("The capital of France is")))
    sim_log, ref_log = os.path.join(tmp, "sim.log"), os.path.join(tmp, "ref.log")
    sim_out = run("--core", f"sim:{TB_ISA}:{IMAGE}", "--ids", ids, "--generate", "2", "--log", sim_log)
    run("--core", ref_core, "--ids", ids, "--generate", "2", "--log", ref_log)
    calls = read_log(sim_log)
    weights = [model.layers[i][p].wq for i in range(model.layers_n) for p in ("qkv", "o", "gate_up", "down")]
    weights.append(model.head.wq)
    exact = sum(np.array_equal(acc, exact_matmul(xq, weights[index])) for index, xq, acc in calls)
    check(f"qwen-run on the simulated core: {len(calls)} matmuls, every int32 == exact_matmul of its logged int8 input",
          exact == len(calls) and len(calls) == 3 * 97, f"{exact} exact")
    check("qwen-run's log, simulated core == ref core, byte for byte (so tokens and logits are identical)",
          open(sim_log, "rb").read() == open(ref_log, "rb").read())
    print(f"    on the simulated core: {tok.decode(generated_ids(sim_out.stdout))!r}; {sim_out.stderr.strip().splitlines()[-1]}")

    print("ALL RUNTIME CHECKS PASSED" if not failures else f"{len(failures)} FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
