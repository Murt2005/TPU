# Running a transformer on the array

TinyStories-1M (GPT-Neo, 8 layers, d=64, 16 heads, vocab 50257) with its
linear layers executed on the TPU. Works against the Verilator model today;
the same driver runs on real hardware by changing `--link`.

## Quick start

```bash
./llm/fetch.sh                 # download + quantize (~48MB download, gitignored)
make sim-bridge                # build the simulated core as a transport
python3 llm/infer.py --link sim --port sim/verilator/bridge/tb_tpu_top \
    --prompt "Once upon a time" -n 20
```

No accelerator at all:

```bash
python3 llm/infer.py --offline --prompt "Once upon a time" -n 20
```

## What runs where

The hardware has exactly one operation, so the split is forced:

| On the array | On the host |
|---|---|
| q / k / v / out_proj, mlp.c_fc, mlp.c_proj (6 per block) | embedding lookup, LayerNorm |
| the tied lm_head | softmax, GELU, residuals |

49 matmuls and ~3.6M MACs per token. **89% of that is the lm_head** — a
50257-wide output projection on a 64-wide model. The transformer itself is
the small part, which is worth knowing before reading too much into the
throughput number.

Attention's own QK^T and AV matmuls stay on the host by default. `--tpu-attention`
moves them onto the array, but at `d_head=4` they are ~0.25% of the arithmetic
and cost 32 extra round trips per layer.

## Quantization

Post-training, no calibration set, no fine-tuning.

- **Weights** — int8, one scale per output channel (`llm/export.py`). Worst
  per-matrix relative error on this checkpoint: **0.39%**.
- **Activations** — quantized dynamically at each matmul from their own max,
  so there is no calibration distribution to capture and no train/serve skew.
- **Bias** — kept float and added after dequantization. It *cannot* be folded
  into the accumulator: that would need scaling by the activation scale, which
  is only known at runtime.

**This model requires `PSUM_WIDTH=32`.** The MLP's K=256 reduction reaches
256·127·127 ≈ 4.1M, and the accumulator does not saturate — a 16-bit build
would wrap it into noise. `TpuBackend` refuses to start on a narrower build.

## Checking it is right

`--compare` runs three backends on the same prompt:

```bash
python3 llm/infer.py --link sim --port sim/verilator/bridge/tb_tpu_top \
    --prompt "Once upon a time" -n 6 --compare
```

- **array vs exact int8 emulation** — must be identical. This is the real
  correctness gate: the emulation quantizes and accumulates exactly as the
  RTL does, so any difference is a hardware or protocol bug, not rounding.
- **int8 vs float reference** — divergence here is ordinary quantization
  error and is expected on longer generations.

Measured at 8×8 / M_TILE=4 / PSUM=32, 6 tokens: all three produced
`", there was a little girl"`, identical.

## Cost

~11-19 s/token against the Verilator model, dominated not by simulated cycles
but by host round trips: `stream_tile_bytes` is 96 at this shape, so the
255-byte frame cap allows only **2 tiles per frame**, and a token needs ~28k
frames. On real hardware the same driver has no such per-frame process
boundary.

## Files

| File | What |
|---|---|
| `fetch.sh` | Download a checkpoint and quantize it |
| `torch_bin.py` | Read a PyTorch `.bin` without PyTorch (zip + pickle + raw storages) |
| `export.py` | Per-output-channel int8 quantization → `.npz` |
| `tokenizer.py` | GPT-2 byte-level BPE, pure Python |
| `infer.py` | Forward pass, backends, generation, CLI |
| `model/` | Downloaded + generated artifacts (gitignored) |
