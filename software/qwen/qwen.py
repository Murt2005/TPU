"""Qwen2.5-0.5B in numpy: the reference the core's programs and the ARM runtime
are checked against. Two kinds of linear layer:

- FloatLinear: x @ W^T + b in float32, from the bf16 checkpoint. check.py holds
  it to the PyTorch model's logits.
- CoreLinear: what the core and its host compute. The host divides the input by
  a per-channel smoothing vector (SmoothQuant, folded into the weights), then
  quantizes each row to int8 with its own scale (round half to even, +-127).
  The core multiplies by int8 weights, quantized with one scale per output
  channel, and accumulates exactly in 32 bits. The host dequantizes:
  acc * row scale * column scale, then adds the bias.
  `matmul` is the core's part, exact (float64 sums of these integers are exact),
  so it can be swapped for the core itself and compared word for word.

Linears that share an input run fused, as one MATMUL each: q, k and v; gate and
up. Everything else (embedding lookup, RMSNorm, RoPE, attention over the KV
cache, SiLU, residuals) is host float32, as on the ARM.
"""
import json
import os
import struct

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))


def load_safetensors(path):
    """name -> float32 array, from a safetensors file (bf16, f16 or f32), numpy only"""
    with open(path, "rb") as fh:
        header_len = struct.unpack("<Q", fh.read(8))[0]
        header = json.loads(fh.read(header_len))
        base = 8 + header_len
    raw = np.memmap(path, dtype=np.uint8, mode="r")
    out = {}
    for name, meta in header.items():
        if name == "__metadata__":
            continue
        a, b = meta["data_offsets"]
        buf = raw[base + a:base + b]
        if meta["dtype"] == "BF16":
            x = (buf.view(np.uint16).astype(np.uint32) << 16).view(np.float32)
        elif meta["dtype"] == "F16":
            x = buf.view(np.float16).astype(np.float32)
        elif meta["dtype"] == "F32":
            x = np.array(buf.view(np.float32))
        else:
            raise ValueError(f"{name}: dtype {meta['dtype']}")
        out[name] = x.reshape(meta["shape"])
    return out


def quantize_rows(x):
    """int8 rows and one float32 scale per row: x ~ q * scale, |q| <= 127"""
    scale = (np.abs(x).max(axis=-1, keepdims=True) / 127).astype(np.float32)
    scale = np.maximum(scale, np.float32(1e-12))
    return np.clip(np.rint(x / scale), -127, 127).astype(np.int8), scale


class FloatLinear:
    def __init__(self, w, b=None):
        self.w, self.b = w, b

    def __call__(self, x):
        y = x @ self.w.T
        return y if self.b is None else y + self.b


class CoreLinear:
    """the core's int8 matmul with the host's quantize and dequantize around it"""

    def __init__(self, w, b=None, smooth=None):
        self.smooth = None if smooth is None else smooth.astype(np.float32)
        self.wq, self.wscale = quantize_rows(w if smooth is None else w * smooth[None, :])
        self.wscale = self.wscale[:, 0]                # one per output channel
        self.b = b
        self.matmul = exact_matmul

    def __call__(self, x):
        x2 = np.atleast_2d(x)
        if self.smooth is not None:
            x2 = x2 / self.smooth
        xq, xscale = quantize_rows(x2)
        acc = self.matmul(xq, self.wq)                 # int32, rows x out
        y = acc.astype(np.float32) * xscale * self.wscale
        if self.b is not None:
            y = y + self.b
        return y.reshape(*x.shape[:-1], -1)


def exact_matmul(xq, wq):
    """int8 rows x int8 weights (out x in) -> int32, as the core accumulates them"""
    acc = xq.astype(np.float64) @ wq.astype(np.float64).T   # exact: every sum < 2^53
    assert np.abs(acc).max(initial=0) < 2 ** 31
    return acc.astype(np.int32)


def _tap(taps, key, x):
    peak = np.abs(x).max(axis=0)
    taps[key] = peak if key not in taps else np.maximum(taps[key], peak)


def rms_norm(x, g, eps):
    return (x / np.sqrt(np.mean(x * x, axis=-1, keepdims=True) + eps)).astype(np.float32) * g


def silu(x):
    return x / (1 + np.exp(-x))


class Qwen:
    """Qwen2 forward pass with a KV cache; linear layers float or core"""

    def __init__(self, model_dir=os.path.join(HERE, "model"), core=False, smoothing=None):
        """smoothing: {(layer, "qkv" | "o" | "gate_up" | "down"): per-input-channel vector},
        from export.calibrate; only used with core=True"""
        self.cfg = json.load(open(os.path.join(model_dir, "config.json")))
        c = self.cfg
        self.layers_n, self.d = c["num_hidden_layers"], c["hidden_size"]
        self.heads, self.kv_heads = c["num_attention_heads"], c["num_key_value_heads"]
        self.head_dim = self.d // self.heads
        self.eps, self.theta = np.float32(c["rms_norm_eps"]), c["rope_theta"]
        w = load_safetensors(os.path.join(model_dir, "model.safetensors"))
        self.weights = w
        self.core = core
        smoothing = smoothing or {}
        emb = w["model.embed_tokens.weight"]
        make = (lambda wt, b, key: CoreLinear(wt, b, smoothing.get(key))) if core else \
            (lambda wt, b, key: FloatLinear(wt, b))
        self.layers = []
        for i in range(self.layers_n):
            p = f"model.layers.{i}."
            qkv_w = np.concatenate([w[p + f"self_attn.{n}_proj.weight"] for n in "qkv"])
            qkv_b = np.concatenate([w[p + f"self_attn.{n}_proj.bias"] for n in "qkv"])
            gate_up = np.concatenate([w[p + "mlp.gate_proj.weight"], w[p + "mlp.up_proj.weight"]])
            self.layers.append(dict(
                input_norm=w[p + "input_layernorm.weight"], post_norm=w[p + "post_attention_layernorm.weight"],
                qkv=make(qkv_w, qkv_b, (i, "qkv")), o=make(w[p + "self_attn.o_proj.weight"], None, (i, "o")),
                gate_up=make(gate_up, None, (i, "gate_up")),
                down=make(w[p + "mlp.down_proj.weight"], None, (i, "down"))))
        self.final_norm = w["model.norm.weight"]
        self.head = make(emb, None, (None, "head"))    # tied: the output head is the embedding
        # the host looks embeddings up in the head's own rows, int8 on the core path
        self.embedding = (self.head.wq.astype(np.float32) * self.head.wscale[:, None]) if core else emb
        inv = 1.0 / (self.theta ** (np.arange(0, self.head_dim, 2, dtype=np.float64) / self.head_dim))
        self.inv_freq = inv.astype(np.float32)

    def new_cache(self):
        return [dict(k=np.zeros((0, self.kv_heads, self.head_dim), np.float32),
                     v=np.zeros((0, self.kv_heads, self.head_dim), np.float32)) for _ in range(self.layers_n)]

    def rope(self, x, positions):
        """x: tokens x heads x head_dim, rotate-half form"""
        angles = positions[:, None].astype(np.float32) * self.inv_freq[None, :]
        cos = np.concatenate([np.cos(angles)] * 2, axis=-1)[:, None, :]
        sin = np.concatenate([np.sin(angles)] * 2, axis=-1)[:, None, :]
        half = self.head_dim // 2
        rotated = np.concatenate([-x[..., half:], x[..., :half]], axis=-1)
        return (x * cos + rotated * sin).astype(np.float32)

    def forward(self, ids, cache, taps=None):
        """logits for each of ids (tokens after those already in cache), cache extended.
        taps: a dict of each fused linear's per-input-channel max |x| so far, for calibration"""
        ids = np.asarray(ids)
        start = cache[0]["k"].shape[0]
        positions = np.arange(start, start + len(ids))
        x = self.embedding[ids].astype(np.float32)
        q_size, kv_size = self.heads * self.head_dim, self.kv_heads * self.head_dim
        group = self.heads // self.kv_heads
        for i, (layer, c) in enumerate(zip(self.layers, cache)):
            h = rms_norm(x, layer["input_norm"], self.eps)
            if taps is not None:
                _tap(taps, (i, "qkv"), h)
            qkv = layer["qkv"](h)
            q = qkv[:, :q_size].reshape(-1, self.heads, self.head_dim)
            k = qkv[:, q_size:q_size + kv_size].reshape(-1, self.kv_heads, self.head_dim)
            v = qkv[:, q_size + kv_size:].reshape(-1, self.kv_heads, self.head_dim)
            q, k = self.rope(q, positions), self.rope(k, positions)
            c["k"] = np.concatenate([c["k"], k])
            c["v"] = np.concatenate([c["v"], v])
            keys = np.repeat(c["k"], group, axis=1)          # all positions x heads x head_dim
            values = np.repeat(c["v"], group, axis=1)
            scores = np.einsum("thd,shd->hts", q, keys) / np.float32(np.sqrt(self.head_dim))
            causal = positions[:, None] >= np.arange(keys.shape[0])[None, :]
            scores = np.where(causal[None], scores, -np.inf)
            scores = np.exp(scores - scores.max(axis=-1, keepdims=True))
            probs = (scores / scores.sum(axis=-1, keepdims=True)).astype(np.float32)
            attn = np.einsum("hts,shd->thd", probs, values).reshape(-1, q_size)
            if taps is not None:
                _tap(taps, (i, "o"), attn)
            x = x + layer["o"](attn)
            h = rms_norm(x, layer["post_norm"], self.eps)
            if taps is not None:
                _tap(taps, (i, "gate_up"), h)
            gu = layer["gate_up"](h)
            inner = gu.shape[-1] // 2
            act = silu(gu[:, :inner]) * gu[:, inner:]
            if taps is not None:
                _tap(taps, (i, "down"), act)
            x = x + layer["down"](act)
        return self.head(rms_norm(x, self.final_norm, self.eps))

    def generate(self, tokenizer, prompt, n):
        """greedy: prompt ids through once, then one token at a time (decode, m = 1)"""
        cache = self.new_cache()
        ids = tokenizer.encode(prompt)
        logits = self.forward(ids, cache)
        out = []
        for _ in range(n):
            nxt = int(np.argmax(logits[-1]))
            out.append(nxt)
            logits = self.forward([nxt], cache)
        return tokenizer.decode(out)
