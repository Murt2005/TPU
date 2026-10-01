#!/usr/bin/env python3
"""tinystories (GPT-Neo) with its linear layers on the TPU; LayerNorm, softmax,
GELU and residuals stay on the host. needs PSUM_WIDTH=32 (see README.md)"""
import argparse
import os
import sys
import time

import numpy as np

from tpu import golden

from tokenizer import Tokenizer

MODEL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "model")


def layernorm(x, g, b, eps):
    mu = x.mean(-1, keepdims=True)
    var = x.var(-1, keepdims=True)
    return (x - mu) / np.sqrt(var + eps) * g + b


def gelu_new(x):
    """tanh approximation, which is what GPT-Neo's gelu_new is"""
    return 0.5 * x * (1.0 + np.tanh(
        np.sqrt(2.0 / np.pi) * (x + 0.044715 * np.power(x, 3.0))))


def softmax(x, axis=-1):
    x = x - x.max(axis=axis, keepdims=True)
    e = np.exp(x)
    return e / e.sum(axis=axis, keepdims=True)


class NumpyBackend:
    """host reference. exact=True reproduces the array bit for bit, so comparing
    against it separates hardware bugs from quantization error"""

    def __init__(self, exact=False):
        self.exact = exact
        self.name = "numpy-int8" if exact else "numpy"

    def matmul(self, a, w_q, w_s):
        if not self.exact:
            return a.astype(np.float32) @ (w_q.astype(np.float32) * w_s)
        a_q, a_s = _quantize_rows(np.atleast_2d(a))
        acc = golden.matmul(a_q, w_q, psum_width=32, relu=False)
        return acc.astype(np.float32) * (a_s * w_s)

    def matmul_dyn(self, a, b):
        if not self.exact:
            return a.astype(np.float32) @ b.astype(np.float32)
        a_q, a_s = _quantize_rows(np.atleast_2d(a))
        b_q, b_s = _quantize_rows(np.atleast_2d(b))
        acc = golden.matmul(a_q, b_q, psum_width=32, relu=False)
        return acc.astype(np.float32) * (a_s * b_s)

    def close(self):
        pass


def _quantize_rows(a):
    """dynamic per-tensor int8 quantization"""
    amax = float(np.abs(a).max())
    scale = amax / 127.0 if amax > 0 else 1.0
    q = np.rint(a / scale).clip(-127, 127).astype(np.int8)
    return q, np.float32(scale)


class TpuBackend:

    def __init__(self, tpu):
        self.tpu = tpu
        self.name = f"tpu[{tpu.link}]"
        self.calls = 0
        self.macs = 0
        if tpu.psum_width < 32:
            raise SystemExit(
                f"this model needs PSUM_WIDTH>=32 (got {tpu.psum_width}): the "
                f"MLP's K=256 reduction overflows a 16-bit accumulator, which "
                f"does not saturate -- it wraps. Rebuild with PSUM_WIDTH=32.")

    def _run(self, a_q, w_q):
        self.calls += 1
        self.macs += a_q.shape[0] * a_q.shape[1] * w_q.shape[1]
        # bias is float and added by the caller; a transformer has no ReLU
        return self.tpu.matmul_tiled(a_q, w_q, bias=None, act_bypass=True)

    def matmul(self, a, w_q, w_s):
        a_q, a_s = _quantize_rows(np.atleast_2d(a))
        acc = self._run(a_q, w_q).astype(np.float32)
        return acc * (a_s * w_s)

    def matmul_dyn(self, a, b):
        a_q, a_s = _quantize_rows(np.atleast_2d(a))
        b_q, b_s = _quantize_rows(np.atleast_2d(b))
        acc = self._run(a_q, b_q).astype(np.float32)
        return acc * (a_s * b_s)

    def close(self):
        self.tpu.close()


class Model:
    def __init__(self, path):
        z = np.load(path)
        self.z = {k: z[k] for k in z.files}
        g = self.z.get
        self.L = int(g("n_layer")); self.H = int(g("n_head"))
        self.d = int(g("d_model")); self.dff = int(g("d_ff"))
        self.V = int(g("vocab")); self.n_ctx = int(g("n_ctx"))
        self.window = int(g("window")); self.eps = float(g("ln_eps"))
        self.layer_types = g("layer_types")
        self.dh = self.d // self.H

    def _lin(self, be, x, i, tag):
        z = self.z
        y = be.matmul(x, z[f"l{i}.{tag}_w"], z[f"l{i}.{tag}_s"])
        return y + z[f"l{i}.{tag}_b"]

    def forward(self, be, ids, cache, tpu_attention=False):
        """one decode step: feed the last token, return logits"""
        z = self.z
        pos = len(ids) - 1
        if pos >= self.n_ctx:
            raise SystemExit(f"context limit {self.n_ctx} reached")
        x = (z["wte"][ids[-1]] + z["wpe"][pos]).astype(np.float32)[None, :]

        for i in range(self.L):
            h = layernorm(x, z[f"l{i}.ln1_g"], z[f"l{i}.ln1_b"], self.eps)
            q = self._lin(be, h, i, "q")
            k = self._lin(be, h, i, "k")
            v = self._lin(be, h, i, "v")

            kc, vc = cache[i]
            kc.append(k[0]); vc.append(v[0])
            K = np.stack(kc)                      # (T, d)
            V = np.stack(vc)

            qh = q.reshape(self.H, self.dh)       # (H, dh)
            Kh = K.reshape(-1, self.H, self.dh).transpose(1, 0, 2)   # (H, T, dh)
            Vh = V.reshape(-1, self.H, self.dh).transpose(1, 0, 2)

            ctx = np.empty((self.H, self.dh), np.float32)
            for hd in range(self.H):
                # GPT-Neo does not scale by 1/sqrt(d_head): it's folded into the weights
                if tpu_attention:
                    s = be.matmul_dyn(qh[hd][None, :], Kh[hd].T)[0]
                else:
                    s = qh[hd] @ Kh[hd].T
                # one token at a time, the causal mask is already satisfied; local layers see the last `window`
                if self.layer_types[i] == 1 and len(kc) > self.window:
                    s = s.copy()
                    s[: len(kc) - self.window] = -1e9
                p = softmax(s)
                if tpu_attention:
                    ctx[hd] = be.matmul_dyn(p[None, :], Vh[hd])[0]
                else:
                    ctx[hd] = p @ Vh[hd]

            a = self._lin(be, ctx.reshape(1, self.d), i, "o")
            x = x + a

            h2 = layernorm(x, z[f"l{i}.ln2_g"], z[f"l{i}.ln2_b"], self.eps)
            ff = gelu_new(self._lin(be, h2, i, "fc"))
            x = x + self._lin(be, ff, i, "pr")

        x = layernorm(x, z["ln_f_g"], z["ln_f_b"], self.eps)
        return be.matmul(x, z["head_w"], z["head_s"])[0]

    def new_cache(self):
        return [([], []) for _ in range(self.L)]


def generate(model, be, tk, prompt, n, temperature, top_k, seed, tpu_attention,
             verbose=True):
    rng = np.random.default_rng(seed)
    ids = tk.encode(prompt)
    if not ids:
        raise SystemExit("empty prompt")
    cache = model.new_cache()
    out_ids = []
    t0 = time.time()
    for step in range(len(ids) - 1 + n):
        fed = ids + out_ids
        logits = model.forward(be, fed[: min(len(fed), step + 1)], cache,
                               tpu_attention)
        if step < len(ids) - 1:
            continue
        if temperature <= 0:
            nxt = int(np.argmax(logits))
        else:
            lg = logits / temperature
            if top_k:
                cut = np.partition(lg, -top_k)[-top_k]
                lg = np.where(lg < cut, -np.inf, lg)
            p = softmax(lg)
            nxt = int(rng.choice(len(p), p=p))
        out_ids.append(nxt)
        if verbose:
            sys.stdout.write(tk.decode([nxt]))
            sys.stdout.flush()
    if verbose:
        sys.stdout.write("\n")
    return prompt + tk.decode(out_ids), time.time() - t0


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--model", default=os.path.join(MODEL_DIR, "tinystories-1m.npz"))
    p.add_argument("--prompt", default="Once upon a time")
    p.add_argument("-n", "--n", type=int, default=20, help="tokens to generate")
    p.add_argument("--temperature", type=float, default=0.0,
                   help="0 = greedy (deterministic, the default)")
    p.add_argument("--top-k", type=int, default=40)
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--offline", action="store_true",
                   help="numpy only; no accelerator, no --port needed")
    p.add_argument("--compare", action="store_true",
                   help="run the array against the exact int8 emulation and "
                        "the float reference, and diff all three")
    p.add_argument("--tpu-attention", action="store_true",
                   help="also put QK^T and AV on the array (see module docstring)")
    p.add_argument("--port")
    p.add_argument("--link", choices=("uart", "spi", "hps", "sim"), default="sim")
    p.add_argument("--rows", type=int, default=8)
    p.add_argument("--cols", type=int, default=8)
    p.add_argument("--m-tile", type=int, default=4)
    p.add_argument("--psum-width", type=int, default=32, choices=(8, 16, 32, 64))
    args = p.parse_args()

    if not os.path.exists(args.model):
        raise SystemExit(
            f"model not found: {args.model}\n"
            f"Build it with:  python3 software/llm/export.py --bin pytorch_model.bin "
            f"--config config.json -o {args.model}")
    model = Model(args.model)
    tk = Tokenizer.from_dir(MODEL_DIR)
    print(f"TinyStories GPT-Neo: d={model.d} layers={model.L} heads={model.H} "
          f"d_ff={model.dff} vocab={model.V}")

    def run(be, label):
        print(f"\n--- {label} ---")
        txt, dt = generate(model, be, tk, args.prompt, args.n, args.temperature,
                           args.top_k, args.seed, args.tpu_attention)
        extra = ""
        if isinstance(be, TpuBackend):
            extra = (f", {be.calls} matmuls, "
                     f"{be.macs/1e6:.2f}M MACs on the array")
        print(f"[{label}] {dt:.2f}s total, {dt/max(args.n,1):.2f}s/token{extra}")
        return txt

    if args.offline and not args.compare:
        run(NumpyBackend(exact=False), "numpy")
        return

    if not args.port:
        raise SystemExit("--port is required unless --offline "
                         "(for --link sim it is the `make sim-bridge` binary)")
    from tpu import TPU
    tpu = TPU(args.port, rows=args.rows, cols=args.cols, m_tile=args.m_tile,
              link=args.link, psum_width=args.psum_width)
    be = TpuBackend(tpu)
    try:
        tpu_txt = run(be, be.name)
    finally:
        be.close()

    if args.compare:
        exact_txt = run(NumpyBackend(exact=True), "numpy-int8")
        float_txt = run(NumpyBackend(exact=False), "numpy")
        print("\n--- comparison ---")
        if tpu_txt == exact_txt:
            print("array == exact int8 emulation: IDENTICAL "
                  "(the datapath is doing what it should)")
        else:
            n = sum(1 for x, y in zip(tpu_txt, exact_txt) if x == y)
            print(f"array vs exact int8 emulation: DIVERGED after {n} chars "
                  f"-- this is a hardware/protocol bug, not quantization")
            print(f"  array: {tpu_txt!r}")
            print(f"  exact: {exact_txt!r}")
        if exact_txt == float_txt:
            print("int8 == float reference: IDENTICAL "
                  "(quantization changed nothing on this prompt)")
        else:
            n = sum(1 for x, y in zip(exact_txt, float_txt) if x == y)
            print(f"int8 vs float reference: diverged after {n} chars "
                  f"-- expected; this is quantization error, not a bug")
            print(f"  int8:  {exact_txt!r}")
            print(f"  float: {float_txt!r}")


if __name__ == "__main__":
    main()
