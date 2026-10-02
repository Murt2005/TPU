"""Phase 2 checks: the numpy reference against the PyTorch model, and the
exported DDR3 image against the reference. Runs in software/qwen/.venv (PyTorch
is only the yardstick; qwen.py, tokenizer.py and export.py need numpy alone).

    software/qwen/.venv/bin/python software/qwen/check.py

1. tokenizer.py gives the reference tokenizer's ids on all of WikiText-2
2. qwen.py's float model matches PyTorch's logits
3. decoding one token at a time through the KV cache matches one full pass
4. qwen.py's core path matches accuracy.py's emulation of it: bit for bit on the
   same input (the int8 activations, then the outputs), and in perplexity end to
   end. end-to-end logits can't match exactly: int8 rounding is a step, so float
   differences of 1e-6 flip some values across a step, and the flips compound
   over 24 layers (the residual stream reaches ~1,400). so the core and the ARM
   runtime are compared MATMUL by MATMUL, on identical int8 inputs
5. out/qwen-ddr.bin holds every int8 weight, tile for tile, and the embedding
   lookup from the head's tiles gives the head's rows
6. greedy text, float and core path
"""
import os
import sys

import numpy as np
import pyarrow.parquet as pq
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "host"))
from qwen import Qwen  # noqa: E402
from tokenizer import Tokenizer  # noqa: E402

failures = []


def check(name, ok, detail=""):
    print(f"[{'PASS' if ok else 'FAIL'}] {name}{(': ' + detail) if detail else ''}")
    if not ok:
        failures.append(name)


def main():
    from transformers import AutoModelForCausalLM, AutoTokenizer
    model_dir = os.path.join(HERE, "model")
    ref_tok = AutoTokenizer.from_pretrained(model_dir)
    tok = Tokenizer.from_dir(model_dir)

    # 1. tokenizer, line by line over both splits
    bad = total = 0
    for split in ("test", "train"):
        for line in pq.read_table(os.path.join(HERE, "data", f"wikitext-2-raw-v1-{split}.parquet")).column("text").to_pylist():
            total += 1
            if tok.encode(line) != ref_tok(line).input_ids:
                bad += 1
    sample = "Hello, world! 1234 — naïve café 日本語 <|endoftext|>\n\n  code:\tx = [1, 2]"
    check(f"tokenizer: {total:,} WikiText-2 lines, ids equal to the reference", bad == 0, f"{bad} differ")
    check("tokenizer: round trip", tok.decode(tok.encode(sample)) == sample)

    ids = tok.encode("The quick brown fox jumps over the lazy dog. In 1905, Albert Einstein published "
                     "four papers that changed physics: on the photoelectric effect, Brownian motion,")
    ref = AutoModelForCausalLM.from_pretrained(model_dir, dtype=torch.float32).eval()
    with torch.no_grad():
        want = ref(torch.tensor([ids])).logits[0].numpy()

    # 2. float model against PyTorch
    fm = Qwen()
    got = fm.forward(ids, fm.new_cache())
    err = np.abs(got - want).max()
    check(f"float model vs PyTorch, {len(ids)} tokens: max |logit difference| {err:.2e}, "
          f"argmax equal at every position", err < 2e-3 and (got.argmax(-1) == want.argmax(-1)).all())

    # 3. KV cache: one token at a time == all at once
    cache = fm.new_cache()
    steps = np.concatenate([fm.forward(ids[:5], cache)] + [fm.forward([t], cache) for t in ids[5:]])
    check(f"KV cache: decoding one token at a time == one pass (max diff {np.abs(steps - got).max():.2e})",
          np.abs(steps - got).max() < 1e-3)
    del fm

    # 4. core path against accuracy.py's CoreLinear: same input -> same int8, same output
    import accuracy
    cm = Qwen(core=True)
    h = np.random.default_rng(0).standard_normal((len(ids), 896)).astype(np.float32)
    h[:, 7] *= 300                                     # an outlier channel, like the real ones
    worst, same_q = 0.0, True
    tests = [("layer 0 q/k/v", cm.layers[0]["qkv"], [ref.model.layers[0].self_attn.q_proj, ref.model.layers[0].self_attn.k_proj,
                                                 ref.model.layers[0].self_attn.v_proj], h),
             ("layer 5 down", cm.layers[5]["down"], [ref.model.layers[5].mlp.down_proj],
              np.random.default_rng(1).standard_normal((len(ids), 4864)).astype(np.float32) * 3),
             ("output head", cm.head, [ref.lm_head], h)]
    for name, lin, torch_linears, x in tests:
        emu = [accuracy.CoreLinear(t, "token") for t in torch_linears]
        with torch.no_grad():
            want = np.concatenate([e(torch.tensor(x)).numpy() for e in emu], axis=-1)
            xs = torch.tensor(x).abs().amax(dim=-1, keepdim=True).clamp(min=1e-12) / 127
            want_q = torch.round(torch.tensor(x) / xs).clamp(-127, 127).numpy()
        from qwen import quantize_rows
        got_q, _ = quantize_rows(x)
        same_q &= np.array_equal(got_q, want_q) and all(np.array_equal(e.wq.numpy(), w) for e, w in
                                                        zip(emu, np.split(lin.wq, np.cumsum([e.wq.shape[0] for e in emu])[:-1])))
        got = lin(x)
        worst = max(worst, float(np.abs(got - want).max() / np.abs(want).max()))
    check(f"core linears vs accuracy.py's on the same input: int8 activations and weights identical, outputs within "
          f"{worst:.1e} (relative; the emulation sums in float32)", same_q and worst < 1e-5)

    # ... and end to end, in perplexity, on WikiText-2 test windows
    windows = np.array(tok.encode("\n\n".join(pq.read_table(os.path.join(HERE, "data", "wikitext-2-raw-v1-test.parquet"))
                                               .column("text").to_pylist())[:200000]))
    windows = windows[:8 * 256].reshape(8, 256)
    accuracy.swap(ref, "token")
    nll_np = nll_torch = 0.0
    for w in windows:
        lp = cm.forward(w, cm.new_cache())[:-1]
        lp = lp - lp.max(-1, keepdims=True)
        lp = lp - np.log(np.exp(lp).sum(-1, keepdims=True))
        nll_np -= lp[np.arange(len(w) - 1), w[1:]].sum()
        with torch.no_grad():
            lt = torch.log_softmax(ref(torch.tensor([w])).logits[0, :-1], dim=-1).numpy()
        nll_torch -= lt[np.arange(len(w) - 1), w[1:]].sum()
    count = windows.shape[0] * (windows.shape[1] - 1)
    ppl_np, ppl_torch = np.exp(nll_np / count), np.exp(nll_torch / count)
    check(f"core path vs the emulation end to end, {count:,} WikiText-2 tokens: perplexity {ppl_np:.3f} vs "
          f"{ppl_torch:.3f}", abs(ppl_np / ppl_torch - 1) < 0.01)

    def perplexity(model):
        nll = 0.0
        for w in windows:
            lp = model.forward(w, model.new_cache())[:-1]
            lp = lp - lp.max(-1, keepdims=True)
            lp = lp - np.log(np.exp(lp).sum(-1, keepdims=True))
            nll -= lp[np.arange(len(w) - 1), w[1:]].sum()
        return np.exp(nll / count)
    del ref, cm

    # 5. the exported DDR3 image
    out = os.path.join(HERE, "out")
    if not os.path.exists(os.path.join(out, "qwen-ddr.bin")):
        print("[SKIP] no out/qwen-ddr.bin: run export.py")
    else:
        host = np.load(os.path.join(out, "qwen-host.npz"))
        sm = np.load(os.path.join(out, "smoothing.npz"))
        smoothing = {(int(k.split(".")[0]), k.split(".")[1]): sm[k] for k in sm.files if k != "alpha"}
        cm = Qwen(core=True, smoothing=smoothing)
        n = int(host["n"])
        ddr = np.memmap(os.path.join(out, "qwen-ddr.bin"), dtype=np.int8, mode="r")
        bad = 0
        names = [(f"layer{i}.{p}", cm.layers[i][p]) for i in range(cm.layers_n) for p in ("qkv", "o", "gate_up", "down")]
        for name, lin in names + [("head", cm.head)]:
            tile = int(host[f"{name}.tile"])
            k_tiles, n_blocks = host[f"{name}.shape"]
            tiles = ddr[tile * n * n:(tile + k_tiles * n_blocks) * n * n].reshape(n_blocks, k_tiles, n, n)
            w = tiles.transpose(1, 2, 0, 3).reshape(k_tiles * n, n_blocks * n)     # K x N
            bad += not np.array_equal(w, lin.wq.T) or not np.array_equal(host[f"{name}.wscale"], lin.wscale)
        check(f"DDR3 image: {ddr.size:,} bytes; every matrix's tiles == its int8 weights", bad == 0, f"{bad} bad")
        # embedding of token t: column t % n of blocks t // n, every K-tile, every row
        head_tile = int(host["head.tile"])
        k_tiles, _ = host["head.shape"]
        ok = True
        for t in (0, 1, 7, 8, 12345, 151935):
            b, c = divmod(t, n)
            offsets = (head_tile + b * k_tiles + np.arange(k_tiles)[:, None]) * n * n + np.arange(n)[None, :] * n + c
            ok &= np.array_equal(ddr[offsets.ravel()], cm.head.wq[t])
        check("embedding lookup from the head's tiles == the head's row", ok)

        # the image's own calibration delivers phase 1's accuracy
        ppl_image = perplexity(cm)
        fm = Qwen()
        ppl_float = perplexity(fm)
        del fm
        check(f"the exported model (alpha {float(sm['alpha'])}), {count:,} tokens: perplexity {ppl_image:.3f} vs float "
              f"{ppl_float:.3f} ({100 * (ppl_image / ppl_float - 1):+.2f}%; phase 1: +1.74% on 102,400)",
              ppl_image / ppl_float - 1 < 0.04)

        # 6. text, float and core
        prompt = "The capital of France is"
        print(f"  core path (from the image's quantization), greedy: {prompt!r} ->"
              f" {cm.generate(tok, prompt, 12)!r}")
        del cm
        fm = Qwen()
        print(f"  float model, greedy:                               {prompt!r} ->"
              f" {fm.generate(tok, prompt, 12)!r}")

    print("ALL QWEN CHECKS PASSED" if not failures else f"{len(failures)} FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
