# Qwen2.5-0.5B on the core

Getting [Qwen2.5-0.5B](https://huggingface.co/Qwen/Qwen2.5-0.5B) (24 layers,
hidden 896, 14 query / 2 KV heads, SwiGLU 4,864, vocabulary 151,936, tied
embedding) to run with every linear layer on the array and its weights streamed
from DDR3, as the instruction-stream spec plans (its "Scaling to
Qwen2.5-Coder-0.5B"). Status: phases 1 and 2 done. Nothing runs on the core yet.

| Phase | What | Status |
|---|---|---|
| 1 | What the core's int8 arithmetic costs the model (`accuracy.py`) | **done**: +1.74% perplexity with SmoothQuant, no hardware change |
| 2 | A numpy reference, the tokenizer, and the DDR3 weight image (`qwen.py`, `tokenizer.py`, `export.py`, `check.py`) | **done** |
| 3 | Each layer as core programs, checked word for word in Verilator | next |
| 4 | The host runtime in C on the ARM | |
| 5 | On the board (needs a larger DDR3 window than `mem=768M` leaves) | |

## Setup

```sh
software/qwen/fetch.sh                        # weights, tokenizer, WikiText-2 (gitignored)
python3 -m venv software/qwen/.venv
software/qwen/.venv/bin/pip install torch transformers safetensors pyarrow numpy
```

PyTorch is only the yardstick, for `accuracy.py` and `check.py`.
`qwen.py`, `tokenizer.py` and `export.py` need numpy alone (and pyarrow to read
the calibration text).

## Phase 1: the int8 cost

`accuracy.py` swaps every linear layer (q, k, v, o, gate, up, down, and the
output head) for exactly what the core and its host compute:
- int8 weights with one scale per output channel
- int8 activations, quantized at each matmul from their own maximum
- exact integer accumulation, then dequantization on the host

Norms, RoPE, attention, softmax and biases stay float, as they will on the
ARM. The embedding lookup reads the output head's int8 rows (they're tied).

WikiText-2 test, 102,400 tokens in windows of 512, against the float model
(bf16 weights, float32 math):

| Variant | Perplexity | vs float | Top-1 agreement | KL, nats/token |
|---|---|---|---|---|
| float | 16.867 | — | 100% | 0 |
| int8 weights, float activations | 16.902 | +0.21% | 96.49% | 0.0039 |
| int8 activations, one scale per matmul input | 90.392 | +436% | 39.97% | 1.7103 |
| int8 activations, one scale per token | 17.477 | +3.62% | 89.52% | 0.0402 |
| per token + SmoothQuant α = 0.5 | 17.192 | +1.93% | 91.17% | 0.0224 |
| **per token + SmoothQuant α = 0.65** | **17.160** | **+1.74%** | **91.70%** | **0.0186** |
| per token + SmoothQuant α = 0.8 | 17.207 | +2.02% | 91.30% | 0.0215 |

- **Weights aren't the problem.** int8 with per-channel scales costs 0.2%.
- **Activations are, as the spec expected.** A few channels are far larger
  than the rest, so one scale per input is unusable.
- **One scale per token is free on this core.** The host quantizes each input
  row and dequantizes each output row, and the array never mixes rows.
- **SmoothQuant is free too.** It divides each input channel by
  `s = max|x|^α / max|W|^(1−α)` and multiplies the weights' columns by `s`
  before quantizing. The host divides as it quantizes, so nothing changes on
  the core. Linears that share an input (q/k/v, gate/up) run as one fused
  `MATMUL`, so they share one `s`; the numbers above use the shared vectors.
- **α = 0.65** is the export's default. It's calibrated on 64 × 512 tokens of
  WikiText-2 train.

## Phase 2: the reference and the image

- **`tokenizer.py`:** Qwen2's byte-level BPE in pure Python. Python's `re`
  has no `\p{L}`, so those classes are built from `unicodedata`. It gives the
  reference tokenizer's ids on all 41,076 WikiText-2 lines (2.8 M tokens).
- **`qwen.py`:** the model in numpy, with a KV cache. `FloatLinear` follows the
  checkpoint; `CoreLinear` is the core's arithmetic, with its exact int32
  matmul isolated in `matmul`, so phase 3 can put the core there and compare
  word for word.
- **`export.py`:** calibrates, quantizes and writes two files to `out/`:
  - `qwen-ddr.bin`: every weight as 8×8 int8 tiles in program order. Per
    layer: q/k/v fused (112 × 144 tiles), o (112 × 112), gate/up fused
    (112 × 1,216), down (608 × 112). Then the output head (112 × 18,992).
    Each matrix is exactly what one `MATMUL` walks from its first tile.
  - `qwen-host.npz`: per matrix, its first tile (for `SET_WBASE`), its
    shape, per-channel weight scales, the smoothing vector and biases; and
    the norms.
- **The embedding** is read out of the output head's tiles. Token *t* is
  column *t* mod 8 of block ⌊*t*/8⌋: 896 scattered bytes, so there's no
  second 136 MB copy.
- **`check.py`** holds all of it to PyTorch:

| Check | Result |
|---|---|
| tokenizer, all of WikiText-2 | identical ids on 41,076 lines (2.8 M tokens) |
| float model vs PyTorch | max logit difference 4.6e-4, same argmax everywhere |
| KV cache, one token at a time vs one pass | max difference 1.7e-4 |
| core linears vs `accuracy.py`'s, same input | int8 activations and weights identical, outputs equal |
| core path vs `accuracy.py` end to end | perplexity 23.55 vs 23.66 (2,040 tokens) |
| DDR3 image | all 493,961,216 bytes equal to the model's int8 weights; embedding lookup from the head's tiles |
| the exported model (α = 0.65) vs float | +2.25% perplexity on those 2,040 tokens |
| greedy text, "The capital of France is" | float and core path both: " Paris. It is the largest city in Europe and the second" |

**Exact comparisons happen per `MATMUL`.** Two correct implementations of the
int8 path don't produce identical logits end to end. Float differences of
1e-6 move some activations across an int8 rounding boundary, and the flips
compound over 24 layers, where the residual stream reaches ~1,400. So
phase 3 compares the core's int32 output word for word on identical int8
inputs, and end-to-end runs are judged by perplexity.

## What phase 3 has to respect

- **The accumulator holds 1,024 rows.** So gate/up (1,216 blocks) takes 2
  `MATMUL`s and the head (18,992 blocks) 19.
- **The bias and quant tables have 256 entries.** Every `ACTIVATE` sends raw
  int32 (`rq=0`, `bias=0`, `func` identity) to DDR3, and the host dequantizes.
- **32-bit accumulation is safe.** The largest K is 4,864, and
  4,864 × 127 × 127 ≈ 78.5 M, far below 2³¹.
