"""Phase 3: Qwen2.5-0.5B's linear layers on the core, in Verilator, with the
weights in the simulated DDR3. Every MATMUL's int32 output is compared word for
word with qwen.exact_matmul on the same int8 input.

    PATH=$PWD/.venv/bin:$PATH make rtl-sim N=8
    software/qwen/.venv/bin/python software/qwen/phase3.py [sim/verilator/core_n8/tb_isa]

1. each of layer 0's matrices and the output head on random int8 rows, m = 1
   and m = 5, with the DDR3 model's random timing (waitrequest, latency, gaps)
2. the prompt through the whole model, then a few tokens decoded one at a time,
   every linear layer on the core (fixed DDR3 timing, for speed): logits and text
   must equal the numpy core path's, since only the matmuls moved
"""
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "host"))
from core_runtime import CoreRuntime  # noqa: E402
from qwen import Qwen, exact_matmul  # noqa: E402
from tokenizer import Tokenizer  # noqa: E402
from tpu.isa_device import IsaDevice, open_link  # noqa: E402

failures = []


def check(name, ok, detail=""):
    print(f"[{'PASS' if ok else 'FAIL'}] {name}{(': ' + detail) if detail else ''}", flush=True)
    if not ok:
        failures.append(name)


def main():
    binary = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", "sim", "verilator", "core_n8", "tb_isa")
    out = os.path.join(HERE, "out")
    host = np.load(os.path.join(out, "qwen-host.npz"))
    image = os.path.join(out, "qwen-ddr.bin")
    sm = np.load(os.path.join(out, "smoothing.npz"))
    smoothing = {(int(k.split(".")[0]), k.split(".")[1]): sm[k] for k in sm.files if k != "alpha"}

    link = open_link(binary)
    dev = IsaDevice(link)
    rt = CoreRuntime(dev, host, base=link.ddr_window[0], image_bytes=os.path.getsize(image), verify=False)
    t0 = time.time()
    rt.load_image(image)
    print(f"weight image in simulated DDR3: {os.path.getsize(image):,} bytes ({time.time() - t0:.0f} s)", flush=True)

    model = Qwen(core=True, smoothing=smoothing)
    tok = Tokenizer.from_dir(os.path.join(HERE, "model"))

    # 1. each matrix of layer 0 and the head, random rows, random bus timing
    rng = np.random.default_rng(0)
    link.ddr_timing(True)
    for name, lin in [("layer0.qkv", model.layers[0]["qkv"]), ("layer0.o", model.layers[0]["o"]),
                      ("layer0.gate_up", model.layers[0]["gate_up"]), ("layer0.down", model.layers[0]["down"]),
                      ("head", model.head)]:
        for m in (1, 5):
            xq = rng.integers(-127, 128, (m, lin.wq.shape[1])).astype(np.int8)
            t0 = time.time()
            got = rt.matmul(name, xq)
            k_tiles, n_blocks = host[f"{name}.shape"]
            check(f"{name} ({k_tiles} x {n_blocks} tiles), m={m}, random DDR3 timing: int32 == exact_matmul",
                  np.array_equal(got, exact_matmul(xq, lin.wq)), f"{time.time() - t0:.1f} s")

    # 2. the whole model: prompt, then decode, every matmul on the core and checked
    link.ddr_timing(False)
    prompt, steps = "The capital of France is", 3
    ids = tok.encode(prompt)
    reference = Qwen(core=True, smoothing=smoothing)
    ref_cache, cache = reference.new_cache(), model.new_cache()
    rt.verify = True
    rt.attach(model)
    t0 = time.time()
    rt.calls = rt.beats = rt.stalls = rt.tiles = 0
    logits = model.forward(ids, cache)
    want = reference.forward(ids, ref_cache)
    check(f"prompt ({len(ids)} tokens, m={len(ids)}): {rt.calls} programs on the core, every int32 == "
          f"exact_matmul, logits == the numpy core path", np.array_equal(logits, want),
          f"{time.time() - t0:.0f} s")
    text_ids = []
    for step in range(steps):
        nxt = int(np.argmax(logits[-1]))
        text_ids.append(nxt)
        rt.calls = rt.beats = rt.stalls = rt.tiles = 0
        t0 = time.time()
        logits = model.forward([nxt], cache)
        want = reference.forward([nxt], ref_cache)
        check(f"decode step {step + 1} (m=1): {rt.calls} programs, {rt.tiles:,} tiles, "
              f"{rt.stalls} weight-stall cycles, logits == the numpy core path", np.array_equal(logits, want),
              f"{time.time() - t0:.0f} s")
    text_ids.append(int(np.argmax(logits[-1])))
    print(f"  {prompt!r} -> {tok.decode(text_ids)!r}  (on the simulated core)")
    print(f"  one decoded token: {rt.tiles:,} tiles x 8 cycles + {rt.stalls} stall cycles = "
          f"{(rt.tiles * 8 + rt.stalls) / 50e6:.3f} s of array time at 50 MHz")
    link.close()
    print("ALL PHASE 3 CHECKS PASSED" if not failures else f"{len(failures)} FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
