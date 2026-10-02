"""Phase 1: what the core's int8 arithmetic costs Qwen2.5-0.5B, before any RTL or
runtime work. every linear layer (q, k, v, o, gate, up, down, and the tied output
head) is replaced by what the core computes: int8 weights with one scale per
output channel, times int8 activations quantized at each matmul from their own
maximum, accumulated exactly, then dequantized on the host. norms, RoPE,
attention, softmax and biases stay float, as they will on the ARM. the embedding
lookup reads the same int8 rows the output head uses (they're tied).

measured on WikiText-2 (test) against the float model: perplexity, how often the
top-1 next token agrees, and the KL divergence of the next-token distribution.

    software/qwen/.venv/bin/python software/qwen/accuracy.py [--windows 40] [--length 512]

variants:
  float            the reference (bf16 weights, computed in float32)
  W8               int8 weights only
  W8A8 per-tensor  one activation scale per matmul input (pessimistic for prefill)
  W8A8 per-token   one per input row: what decode at m = 1 does, and what the core
                   allows at any m, since the host dequantizes each output row
  + SmoothQuant    activations divided per channel by s = max|x|^a / max|w|^(1-a)
                   (calibrated on WikiText-2 train) and weights multiplied by it,
                   before quantizing. free on this core: the ARM quantizes every
                   matmul input anyway
"""
import argparse
import copy
import math
import os
import time

import numpy as np
import pyarrow.parquet as pq
import torch
import torch.nn as nn
from transformers import AutoModelForCausalLM, AutoTokenizer

HERE = os.path.dirname(os.path.abspath(__file__))
LINEARS = ("q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj")
# linears that share an input run as one fused MATMUL on the core, so the input is
# quantized once and they share one smoothing vector
SHARED_INPUT = {"q_proj": ("q_proj", "k_proj", "v_proj"), "k_proj": ("q_proj", "k_proj", "v_proj"),
                "v_proj": ("q_proj", "k_proj", "v_proj"), "gate_proj": ("gate_proj", "up_proj"),
                "up_proj": ("gate_proj", "up_proj"), "o_proj": ("o_proj",), "down_proj": ("down_proj",)}


def quantize_rows(w):
    """int8 values (kept as float) and one scale per row, symmetric to +-127"""
    scale = w.abs().amax(dim=1, keepdim=True).clamp(min=1e-12) / 127
    return torch.round(w / scale).clamp(-127, 127), scale


class CoreLinear(nn.Module):
    """y = dequant(int8(x / s) @ int8(W * s)^T) + b, as the core and its host compute it"""

    def __init__(self, linear, activations, smooth=None):
        super().__init__()
        w = linear.weight.detach().float()
        if smooth is not None:
            w = w * smooth[None, :]
        self.wq, self.wscale = quantize_rows(w)
        self.bias = None if linear.bias is None else linear.bias.detach().float()
        self.activations = activations          # None, "token" or "tensor"
        self.smooth = smooth

    def forward(self, x):
        if self.smooth is not None:
            x = x / self.smooth
        if self.activations is None:
            y = x @ (self.wq * self.wscale).T
        else:
            if self.activations == "token":
                xs = x.abs().amax(dim=-1, keepdim=True)
            else:
                xs = x.abs().amax().reshape(1, 1, 1)
            xs = xs.clamp(min=1e-12) / 127
            xq = torch.round(x / xs).clamp(-127, 127)
            y = (xq @ self.wq.T) * xs * self.wscale.T
        return y if self.bias is None else y + self.bias


def wikitext(tokenizer, split, windows, length):
    text = "\n\n".join(pq.read_table(os.path.join(HERE, "data", f"wikitext-2-raw-v1-{split}.parquet"))
                       .column("text").to_pylist())
    ids = tokenizer(text, return_tensors="pt").input_ids[0]
    count = min(windows, len(ids) // length)
    return ids[:count * length].reshape(count, length)


@torch.no_grad()
def calibrate(model, batches, device):
    """each linear's per-input-channel max |x| over the calibration text"""
    peaks, hooks = {}, []
    for name, module in model.named_modules():
        if isinstance(module, nn.Linear):
            def hook(mod, inputs, output, name=name):
                m = inputs[0].detach().abs().reshape(-1, inputs[0].shape[-1]).amax(dim=0)
                peaks[name] = torch.maximum(peaks[name], m) if name in peaks else m
            hooks.append(module.register_forward_hook(hook))
    for batch in batches:
        model(batch[None].to(device))
    for h in hooks:
        h.remove()
    return peaks


def swap(model, activations, smooth_alpha=None, peaks=None):
    """model's linears replaced by CoreLinear, in place; the tied embedding reads int8 rows.
    with smoothing, linears that share an input (one fused MATMUL) share one vector,
    from the largest weight per input channel across the group"""
    names = {id(v): k for k, v in model.named_modules()}
    for layer in model.model.layers:
        for part in (layer.self_attn, layer.mlp):
            linears = {name: getattr(part, name) for name in LINEARS if hasattr(part, name)}
            smooth = {}
            if smooth_alpha is not None:
                for name, linear in linears.items():
                    group = SHARED_INPUT[name]
                    wmax = torch.stack([linears[g].weight.detach().float().abs().amax(dim=0) for g in group]
                                       ).amax(dim=0).clamp(min=1e-5)
                    xmax = peaks[names[id(linear)]].clamp(min=1e-5)
                    smooth[name] = xmax ** smooth_alpha / wmax ** (1 - smooth_alpha)
            for name, linear in linears.items():
                setattr(part, name, CoreLinear(linear, activations, smooth.get(name)))
    model.lm_head = CoreLinear(model.lm_head, activations)
    emb = model.model.embed_tokens
    emb.weight = nn.Parameter(model.lm_head.wq * model.lm_head.wscale, requires_grad=False)


@torch.no_grad()
def evaluate(model, batches, device, reference=None):
    """perplexity; with reference (the float model, run on the same windows side
    by side: its log-probs for all of them wouldn't fit in memory), top-1
    agreement and mean KL"""
    nll, count, agree, kl = 0.0, 0, 0, 0.0
    for batch in batches:
        logp = torch.log_softmax(model(batch[None].to(device)).logits[0, :-1].float(), dim=-1)
        target = batch[1:].to(device)
        nll -= logp.gather(1, target[:, None]).sum().item()
        count += len(target)
        if reference is not None:
            ref = torch.log_softmax(reference(batch[None].to(device)).logits[0, :-1].float(), dim=-1)
            agree += (logp.argmax(-1) == ref.argmax(-1)).sum().item()
            kl += (ref.exp() * (ref - logp)).sum().item()
    return dict(ppl=math.exp(nll / count), agree=agree / count, kl=kl / count, tokens=count)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--windows", type=int, default=40, help="WikiText-2 test windows")
    ap.add_argument("--length", type=int, default=512, help="tokens per window")
    ap.add_argument("--calibration", type=int, default=16, help="WikiText-2 train windows for SmoothQuant")
    ap.add_argument("--alphas", default="0.5,0.75", help="SmoothQuant migration strengths to try")
    args = ap.parse_args()

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    path = os.path.join(HERE, "model")
    tokenizer = AutoTokenizer.from_pretrained(path)
    model = AutoModelForCausalLM.from_pretrained(path, dtype=torch.float32).to(device).eval()
    test = wikitext(tokenizer, "test", args.windows, args.length)
    train = wikitext(tokenizer, "train", args.calibration, args.length)
    print(f"Qwen2.5-0.5B on {device}; WikiText-2 test, {test.numel():,} tokens in windows of {args.length}")

    t0 = time.time()
    ref = evaluate(model, test, device)
    rows = [("float (bf16 weights, fp32 math)", ref["ppl"], 1.0, 0.0)]
    print(f"  float: ppl {ref['ppl']:.3f} ({time.time() - t0:.0f} s)")
    peaks = calibrate(model, train, device)

    variants = [("W8, float activations", None, None), ("W8A8 per-tensor", "tensor", None),
                ("W8A8 per-token", "token", None)]
    variants += [(f"W8A8 per-token + SmoothQuant a={a}", "token", float(a)) for a in args.alphas.split(",")]
    for label, activations, alpha in variants:
        t0 = time.time()
        variant = copy.deepcopy(model)
        swap(variant, activations, alpha, peaks)
        r = evaluate(variant, test, device, reference=model)
        del variant
        rows.append((label, r["ppl"], r["agree"], r["kl"]))
        print(f"  {label}: ppl {r['ppl']:.3f}, top-1 agree {100 * r['agree']:.2f}%, KL {r['kl']:.4f} "
              f"({time.time() - t0:.0f} s)")

    print(f"\n| Variant | Perplexity | vs float | Top-1 agreement with float | KL(float ‖ variant), nats/token |")
    print("|---|---|---|---|---|")
    for label, ppl, agree, kl in rows:
        print(f"| {label} | {ppl:.3f} | {100 * (ppl / ref['ppl'] - 1):+.2f}% | {100 * agree:.2f}% | {kl:.4f} |")


if __name__ == "__main__":
    main()
