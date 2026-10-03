# Qwen2.5-0.5B on the core

Getting [Qwen2.5-0.5B](https://huggingface.co/Qwen/Qwen2.5-0.5B) (24 layers,
hidden 896, 14 query / 2 KV heads, SwiGLU 4,864, vocabulary 151,936, tied
embedding) to run with every linear layer on the array and its weights streamed
from DDR3, as the instruction-stream spec plans (its "Scaling to
Qwen2.5-Coder-0.5B"). Status: **running on the DE1-SoC**. Every linear layer
runs on the 8×8 core at 50 MHz with its weights streamed from DDR3, at 0.73
tokens/s. Every matmul matches the exact reference, and perplexity is 2.5%
above the float model. `chat.py` is a browser chat with it.

| Phase | What | Status |
|---|---|---|
| 1 | What the core's int8 arithmetic costs the model (`accuracy.py`) | **done**: +1.74% perplexity with SmoothQuant, no hardware change |
| 2 | A numpy reference, the tokenizer, and the DDR3 weight image (`qwen.py`, `tokenizer.py`, `export.py`, `check.py`) | **done** |
| 3 | Each layer as core programs, checked word for word in Verilator (`core_runtime.py`, `phase3.py`) | **done**: the whole model, every `MATMUL` exact |
| 4 | The host runtime in C (`runtime/`, `test_runtime.py`), for the Mac and the ARM | **done**: exact against the simulated core |
| 5 | On the board (`qwen-run --core mmio`), and a browser chat (`chat.py`) | **done**: 0.73 tokens/s, every matmul exact |

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

## Phase 3: the layers on the core

`core_runtime.py` turns each call of a linear layer into one program:
- `RD_DDR_UB` loads the host's int8 rows, which the host wrote to DDR3 in the
  UB's layout, in pieces of up to 4,096 entries.
- `SET_WBASE` points at the matrix's first tile.
- Per chunk of output blocks, it runs a `MATMUL wsrc=1`, then `SET_OBASE`
  and an `ACTIVATE dst=DDR` that writes raw int32.
- `SIGNAL` ends it.
- The `WAIT`s come from `isa_waits`.

It plugs into `qwen.CoreLinear.matmul`, the one place the core's arithmetic
happens. The host reads the int32 back and dequantizes it in numpy, as before.
Each layer is a chunk of 1,024 / m output blocks at most (the accumulator's
rows): at m = 1, gate/up is 2 `MATMUL`s and the head 19.

`phase3.py`, in Verilator (`tb_isa`, the 494 MB image in its DDR3 model):

| Check | Result |
|---|---|
| layer 0's q/k/v, o, gate/up, down and the output head; random int8 rows, m = 1 and 5; random DDR3 timing | int32 == the reference matmul, word for word |
| a 5-token prompt (m = 5), then 3 tokens decoded one at a time; every linear layer on the core, each `MATMUL` checked | 97 programs per pass, all exact; logits identical to the numpy core path |
| greedy text on the simulated core | "The capital of France is" → " Paris. It is" |
| one weight byte changed in the simulated DDR3 | caught: 2 output words differ |

**Per decoded token** the core works through 7,718,144 tiles in 97 programs:
**1.235 s of array time at 50 MHz**, the spec's figure. It also waits 0 cycles
for weights. Each program's `RD_DDR_UB` holds MM back while WT is already
prefetching that program's weights, so the first tile is there before the
array needs it. Verilator runs it at about 1.8 M cycles/s, so 36 s of
simulation per token.

## Phase 4: the host runtime in C

`runtime/` is the host side in C (`make -C software/qwen/runtime`; `make arm`
cross-compiles it in the Quartus VM). It follows `qwen.py` and
`core_runtime.py` operation for operation:
- the embedding gathered from the head's tiles
- RMSNorm, RoPE, attention over a float32 KV cache (2,048 positions)
- SiLU and the residuals
- around each linear layer: smoothing, per-row int8 quantization (`rintf`,
  half to even), the core, and dequantization

It builds the programs itself. A matrix too wide for the 512-word instruction
FIFO at some m (the head above m = 5) runs as several programs. One `qwen-run`
binary takes any of four cores:

| Core | What it is | For |
|---|---|---|
| `ref:IMAGE` | an exact int8 matmul in C over the image's tiles | checking the host math fast on the Mac |
| `sim:TB_ISA[:IMAGE]` | the Verilator core over `tb_isa`'s pipe, weights in its DDR3 | checking against the RTL |
| `mmio` | the DE1-SoC's core through `/dev/mem` | phase 5 |
| `null` | no matmul (zeros) | timing the host's own work |

`qwen-run --ids … --generate N` continues a prompt (token ids from
`tokenizer.py`; text printed from the exported vocabulary). `--score` gives a
perplexity, and `--log` records every matmul's int8 input and int32 output.
`export.py` also writes `qwen-host.bin` and `qwen-vocab.bin`, flat files the C
side reads without numpy.

`test_runtime.py`:

| Check | Result |
|---|---|
| every program `qwen-run` builds vs `core_runtime.py`'s, every matrix at m = 1..16 | 1,541 programs, identical word for word |
| greedy text, C + ref core vs the numpy core path, 5 prompts × 8 tokens | 4 identical; the fifth splits at a near-tie after "jumps over the lazy dog\n\n" |
| perplexity, 2,040 WikiText-2 tokens | C 23.091, numpy 22.920 (0.7%) |
| C on the simulated core: prompt + 2 tokens, every matmul logged | 291 matmuls, each int32 == the exact product of its logged int8 input |
| that log vs the ref core's | identical, byte for byte |

**On the ARM** (the board, the null core, measured 2026-10-02), the host's
own work is about **50 ms a token** at a short context. Attention over the
KV cache adds about 0.6 ms per token of context: about 90 ms at 69
tokens, and about 1.3 s extrapolated to 2,048, as much as the array's
1.24 s. That's the spec's prediction for long contexts. The fixes are NEON
(the build is scalar float) or attention on the array. Memory isn't a
concern: 24 MB of the 771 MB Linux has.

## Phase 5: on the board

**Setup.**
- The card boots through `u-boot.scr` with `mem=256M`. Linux keeps 256 MB
  and uses about 25 MB of it. The FPGA gets 0x10000000–0x3F000000 (752 MB).
- `/mnt/boot/qwen/` on the FAT partition holds:
  - `qwen-run`, built with `make arm`
  - `qwen-host.bin` and `qwen-vocab.bin`
  - `qwen-ddr.bin`, copied with a card reader, since the console would take
    over an hour
- `qwen-run --core mmio:qwen-ddr.bin` copies the image into DDR3 at
  0x10000000, in 90 s from the card. Later runs use `--core mmio`, since
  the weights stay until power-off.

**Results, measured 2026-10-02:**

| Check | Result |
|---|---|
| the weight image on the card | md5 equal to the Mac's |
| a prompt and 3 tokens with `--check ref:qwen-ddr.bin` (every matmul also computed by the C reference from the card's file) | 388 matmuls, **0 mismatched** |
| greedy text | "The capital of France is" → " Paris. It is the largest city in Europe and the 13th largest" |
| perplexity, the same 2,040 WikiText-2 tokens | **22.97** (C on the Mac: 23.09; numpy core path: 22.92; float: 22.42) |
| speed, decoding | **1.37 s a token (0.73 tokens/s)**: the core 1.31 s, the ARM 0.06 s |
| speed, a 5-token prompt (one pass, m = 5) | 1.9 s |

Of the core's 1.31 s, 1.235 s is the array streaming 7.7 M tiles at full
rate. Weight stalls are about 1,000 cycles a token, 21 µs. The other ~75 ms
is pushing 97 programs and reading their int32 results back through the
uncached window.

**Where the time could go next:**
- **The array is the bound.** At m = 1 every weight byte is read once a
  token. 16×16 or 100 MHz would halve the time, and the port's 800 MB/s
  allows it.
- **The ARM grows with context.** Attention costs about 0.6 ms a token of
  context, so at 2,048 tokens the host matches the array. NEON or attention
  on the array would fix it.
- **Program overhead.** About 75 ms a token. Pre-queued programs released by
  a doorbell register would cut it.

## A chat in the browser

```sh
.venv/bin/python software/qwen/chat.py --board /dev/cu.usbserial-<id>0          # weights already in DDR3
.venv/bin/python software/qwen/chat.py --board /dev/cu.usbserial-<id>0 --load   # after a power cycle (~90 s)
.venv/bin/python software/qwen/chat.py --ref                                   # no board: the C reference on the Mac
```

It opens http://localhost:8000. That's a small local web app with only the
standard library and pyserial, so it runs in the repo's `.venv`.
- **What it does:** it tokenizes your prompt on the Mac, sends the ids to
  `qwen-run --serve` on the board over the console, and streams the reply
  back token by token, with the prompt time and tokens/s under each reply.
- **Two modes:** **Chat** keeps the conversation as "User: … / Assistant:"
  turns under a one-line preamble. **Complete** continues your text as-is.
- **Ending a reply:** the base model writes the next turns itself, so chat
  mode ends a reply where "User:" or "Assistant:" starts. What's shown is
  kept, and `chat.py` sends `S` to `qwen-run --serve`, which stops before
  the next token instead of running on to the limit.
- **Quitting:** Ctrl-C quits `chat.py`, and `qwen-run` on the board with it.
- **LED9 blinks once per token** on the board, about 0.1 s each. `qwen-run
  --serve` writes bit 8 of the GHRD's `led_pio` (0xFF210040, which drives
  LEDR[9:1]). It goes on as a token is sent and off two layers into the next
  one, so the blink costs no time.
- **The base model completes text rather than following instructions.** It
  answers short questions ("Name three primary colors." → "Three primary
  colors are red, blue, and yellow.") but rambles on longer ones.
  Qwen2.5-0.5B-Instruct has the same shapes and would drop in through
  `fetch.sh` and `export.py`.
- **The console is busy while it runs.** `qwen-run --serve` holds it until
  `chat.py` stops.

## The core's limits the programs respect

- **The accumulator holds 1,024 rows.** So gate/up (1,216 blocks) takes 2
  `MATMUL`s and the head (18,992 blocks) 19.
- **The bias and quant tables have 256 entries.** Every `ACTIVATE` sends raw
  int32 (`rq=0`, `bias=0`, `func` identity) to DDR3, and the host dequantizes.
- **32-bit accumulation is safe.** The largest K is 4,864, and
  4,864 × 127 × 127 ≈ 78.5 M, far below 2³¹.
