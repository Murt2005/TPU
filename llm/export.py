#!/usr/bin/env python3
"""Quantize a GPT-Neo checkpoint (TinyStories) into this repo's int8 format.

    python3 llm/export.py --bin /path/to/pytorch_model.bin \
                          --config /path/to/config.json -o llm/model/tinystories-1m.npz

What this does and does NOT do
------------------------------
Post-training quantization only. No gradients, no fine-tuning, no calibration
set -- and deliberately so, because of how the runtime quantizes activations.

Weights: int8, with a **per-output-channel** scale. Per-channel costs nothing
here (the host divides each output column by its own scale after the matmul)
and is markedly more accurate than per-tensor on a model this small.

Activations: NOT quantized here. llm/infer.py quantizes each activation
vector dynamically at runtime from its own max, so there is no calibration
distribution to capture and no train/serve skew. That is the standard W8A8
dynamic recipe, and it is why this script needs no data.

Bias: kept in float and added on the host AFTER dequantization, rather than
folded into the accumulator. The accumulator-domain bias would have to be
scaled by the activation scale, which is only known at runtime -- so folding
it in is not merely inconvenient, it is impossible without fixing the
activation scale ahead of time.

Embeddings and LayerNorm stay float: a lookup is not a matmul, and LayerNorm
runs on the host (rtl/ has no normalization unit).
"""
import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import torch_bin


def quantize_per_channel(w_in_out):
    """int8-quantize an (in, out) weight matrix, one scale per output column.

    Returns (int8 array, float32 scales). A column that is entirely zero gets
    scale 1.0 rather than 0, so dequantization cannot produce NaN.
    """
    w = np.asarray(w_in_out, dtype=np.float32)
    amax = np.abs(w).max(axis=0)                 # per output channel
    scale = np.where(amax > 0, amax / 127.0, 1.0).astype(np.float32)
    q = np.rint(w / scale).clip(-127, 127).astype(np.int8)
    return q, scale


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--bin", required=True, help="pytorch_model.bin")
    p.add_argument("--config", required=True, help="config.json")
    p.add_argument("-o", "--out", required=True, help="output .npz")
    args = p.parse_args()

    cfg = json.load(open(args.config))
    if cfg.get("model_type") != "gpt_neo":
        raise SystemExit(f"expected a gpt_neo config, got {cfg.get('model_type')!r}")

    d = cfg["hidden_size"]
    L = cfg["num_layers"]
    H = cfg["num_heads"]
    V = cfg["vocab_size"]
    dff = cfg.get("intermediate_size") or 4 * d      # GPT-Neo default
    win = cfg.get("window_size", 256)

    print(f"GPT-Neo: d_model={d} layers={L} heads={H} d_ff={dff} vocab={V}")
    sd = torch_bin.load(args.bin)

    out = {
        "n_layer": np.int32(L), "n_head": np.int32(H), "d_model": np.int32(d),
        "d_ff": np.int32(dff), "vocab": np.int32(V),
        "n_ctx": np.int32(cfg["max_position_embeddings"]),
        "window": np.int32(win),
        "ln_eps": np.float32(cfg.get("layer_norm_epsilon", 1e-5)),
        # attention_layers alternates global/local; a local layer only differs
        # once the sequence exceeds `window`, which infer.py asserts against.
        "layer_types": np.array(
            [1 if t == "local" else 0 for t in cfg["attention_layers"]], np.int32),
    }

    out["wte"] = sd["transformer.wte.weight"].astype(np.float32)   # (V, d)
    out["wpe"] = sd["transformer.wpe.weight"].astype(np.float32)   # (n_ctx, d)
    out["ln_f_g"] = sd["transformer.ln_f.weight"].astype(np.float32)
    out["ln_f_b"] = sd["transformer.ln_f.bias"].astype(np.float32)

    # nn.Linear stores (out, in); every matmul here wants (in, out).
    def lin(name):
        return sd[name].astype(np.float32).T

    n_q = 0
    for i in range(L):
        pre = f"transformer.h.{i}"
        att = f"{pre}.attn.attention"
        out[f"l{i}.ln1_g"] = sd[f"{pre}.ln_1.weight"].astype(np.float32)
        out[f"l{i}.ln1_b"] = sd[f"{pre}.ln_1.bias"].astype(np.float32)
        out[f"l{i}.ln2_g"] = sd[f"{pre}.ln_2.weight"].astype(np.float32)
        out[f"l{i}.ln2_b"] = sd[f"{pre}.ln_2.bias"].astype(np.float32)

        for tag, key, bias_key in (
            ("q",  f"{att}.q_proj.weight",   None),
            ("k",  f"{att}.k_proj.weight",   None),
            ("v",  f"{att}.v_proj.weight",   None),
            ("o",  f"{att}.out_proj.weight", f"{att}.out_proj.bias"),
            ("fc", f"{pre}.mlp.c_fc.weight",  f"{pre}.mlp.c_fc.bias"),
            ("pr", f"{pre}.mlp.c_proj.weight", f"{pre}.mlp.c_proj.bias"),
        ):
            q, s = quantize_per_channel(lin(key))
            out[f"l{i}.{tag}_w"] = q
            out[f"l{i}.{tag}_s"] = s
            out[f"l{i}.{tag}_b"] = (sd[bias_key].astype(np.float32) if bias_key
                                    else np.zeros(q.shape[1], np.float32))
            n_q += 1

    # lm_head is tied to wte in GPT-Neo: logits = x @ wte.T, so the matmul's
    # (in, out) matrix is wte.T with one scale per vocabulary entry.
    q, s = quantize_per_channel(out["wte"].T)
    out["head_w"], out["head_s"] = q, s
    n_q += 1

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    np.savez_compressed(args.out, **out)

    # Report the worst per-matrix quantization error, so a bad export is
    # visible here rather than as mysterious garbage at generation time.
    worst, worst_name = 0.0, ""
    for i in range(L):
        for tag, key in (("q", "q_proj"), ("k", "k_proj"), ("v", "v_proj"),
                         ("o", "out_proj")):
            ref = lin(f"transformer.h.{i}.attn.attention.{key}.weight")
            deq = out[f"l{i}.{tag}_w"].astype(np.float32) * out[f"l{i}.{tag}_s"]
            rel = np.abs(deq - ref).max() / max(np.abs(ref).max(), 1e-9)
            if rel > worst:
                worst, worst_name = rel, f"l{i}.{tag}"
    size = os.path.getsize(args.out)
    print(f"quantized {n_q} matrices -> {args.out} ({size/1e6:.1f} MB)")
    print(f"worst per-matrix relative weight error: {worst:.4f} ({worst_name})")


if __name__ == "__main__":
    main()
