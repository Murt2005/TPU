"""Qwen2.5-0.5B for the core: calibrate SmoothQuant, quantize, and write

  out/qwen-ddr.bin   every weight the core reads, as N x N int8 tiles in program
                     order (per layer: q/k/v fused, o, gate/up fused, down; then
                     the output head), ready for DDR3. ~494 MB at N = 8
  out/qwen-host.npz  what the host needs around each MATMUL: smoothing vectors,
                     per-output-channel weight scales, biases, norms, and where
                     each matrix's tiles start (a tile index, for SET_WBASE)
  out/smoothing.npz  the calibration, so qwen.Qwen(core=True) can be rebuilt
                     without recalibrating
  out/qwen-host.bin  qwen-host.npz for the C runtime: named float32 / int32 arrays
  out/qwen-vocab.bin each token's bytes, so the runtime can print text

A matrix of K inputs and N outputs is k_tiles = K/N_array by n_blocks = N/N_array
tiles, block-major then K (isa_layout.weight_rows): exactly what one MATMUL with
WBASE at its first tile walks. The embedding lookup reads the output head's tiles:
token t is column t % N of blocks t // N.

    software/qwen/.venv/bin/python software/qwen/export.py [--alpha 0.5] [--windows 16]
    software/qwen/.venv/bin/python software/qwen/export.py --tables-only   # just the .bin tables
"""
import argparse
import json
import os
import struct
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "host"))
from qwen import Qwen  # noqa: E402
from tokenizer import Tokenizer  # noqa: E402
from tpu.isa_layout import weight_rows  # noqa: E402

PARTS = ("qkv", "o", "gate_up", "down")


def wikitext_ids(tokenizer, split, windows, length):
    import pyarrow.parquet as pq    # only for reading the eval text
    text = "\n\n".join(pq.read_table(os.path.join(HERE, "data", f"wikitext-2-raw-v1-{split}.parquet"))
                       .column("text").to_pylist())
    ids = np.array(tokenizer.encode(text[:windows * length * 8]))
    count = min(windows, len(ids) // length)
    return ids[:count * length].reshape(count, length)


def calibrate(float_model, batches, alpha):
    """SmoothQuant vectors, one per fused linear: s = max|x|^a / max|W|^(1-a) per input channel"""
    taps = {}
    for batch in batches:
        float_model.forward(batch, float_model.new_cache(), taps=taps)
    smoothing = {}
    for i, layer in enumerate(float_model.layers):
        for part in PARTS:
            wmax = np.maximum(np.abs(layer[part].w).max(axis=0), 1e-5)
            xmax = np.maximum(taps[(i, part)], 1e-5)
            smoothing[(i, part)] = (xmax ** alpha / wmax ** (1 - alpha)).astype(np.float32)
    return smoothing


def write_tables(out_dir, tokenizer, cfg):
    """qwen-host.npz and the config as qwen-host.bin, and the vocabulary as
    qwen-vocab.bin, little-endian, for runtime/qwen-run.c:
      host:  "QWH1", u32 count, then per array: u16 name length, name, u8 type
             (0 float32, 1 int32), u32 element count, the elements
      vocab: "QWV1", u32 count, then per token: u16 length, its bytes"""
    host = dict(np.load(os.path.join(out_dir, "qwen-host.npz")))
    host.update({"cfg.layers": cfg["num_hidden_layers"], "cfg.hidden": cfg["hidden_size"],
                 "cfg.heads": cfg["num_attention_heads"], "cfg.kv_heads": cfg["num_key_value_heads"],
                 "cfg.inter": cfg["intermediate_size"], "cfg.vocab": cfg["vocab_size"],
                 "cfg.eps": np.float32(cfg["rms_norm_eps"]), "cfg.theta": np.float32(cfg["rope_theta"])})
    with open(os.path.join(out_dir, "qwen-host.bin"), "wb") as fh:
        fh.write(b"QWH1" + struct.pack("<I", len(host)))
        for name, value in sorted(host.items()):
            a = np.asarray(value).ravel()
            kind = 0 if np.issubdtype(a.dtype, np.floating) else 1
            a = a.astype("<f4" if kind == 0 else "<i4")
            fh.write(struct.pack("<H", len(name)) + name.encode() + struct.pack("<BI", kind, a.size) + a.tobytes())
    with open(os.path.join(out_dir, "qwen-vocab.bin"), "wb") as fh:
        count = cfg["vocab_size"]
        fh.write(b"QWV1" + struct.pack("<I", count))
        for i in range(count):
            raw = tokenizer.decode_bytes([i]) if i in tokenizer.decoder else b""
            fh.write(struct.pack("<H", len(raw)) + raw)


def plan(model, n):
    """[(name, linear, first tile, k_tiles, n_blocks)] in DDR3 (program) order"""
    out, tile = [], 0
    for i, layer in enumerate(model.layers):
        for part in PARTS:
            lin = layer[part]
            k_tiles, n_blocks = lin.wq.shape[1] // n, lin.wq.shape[0] // n
            out.append((f"layer{i}.{part}", lin, tile, k_tiles, n_blocks))
            tile += k_tiles * n_blocks
    head = model.head
    out.append(("head", head, tile, head.wq.shape[1] // n, head.wq.shape[0] // n))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--alpha", type=float, default=0.5, help="SmoothQuant migration strength")
    ap.add_argument("--windows", type=int, default=16, help="WikiText-2 train windows to calibrate on")
    ap.add_argument("--length", type=int, default=512)
    ap.add_argument("-n", type=int, default=8, help="array size N")
    ap.add_argument("--tables-only", action="store_true", help="rewrite just qwen-host.bin and qwen-vocab.bin")
    args = ap.parse_args()
    out_dir = os.path.join(HERE, "out")
    os.makedirs(out_dir, exist_ok=True)

    tokenizer = Tokenizer.from_dir(os.path.join(HERE, "model"))
    cfg = json.load(open(os.path.join(HERE, "model", "config.json")))
    if args.tables_only:
        write_tables(out_dir, tokenizer, cfg)
        return
    print(f"calibrating on {args.windows} x {args.length} WikiText-2 train tokens (float model, numpy) ...")
    float_model = Qwen()
    smoothing = calibrate(float_model, wikitext_ids(tokenizer, "train", args.windows, args.length), args.alpha)
    del float_model
    np.savez(os.path.join(out_dir, "smoothing.npz"), alpha=args.alpha,
             **{f"{i}.{p}": v for (i, p), v in smoothing.items()})

    model = Qwen(core=True, smoothing=smoothing)
    n = args.n
    layout = plan(model, n)
    host = dict(n=n, alpha=args.alpha, final_norm=model.final_norm)
    with open(os.path.join(out_dir, "qwen-ddr.bin"), "wb") as ddr:
        for name, lin, tile, k_tiles, n_blocks in layout:
            assert ddr.tell() == tile * n * n
            rows, kt, nb = weight_rows(lin.wq.T, n)          # K x N, block-major then K
            assert (kt, nb) == (k_tiles, n_blocks)
            ddr.write(rows.astype(np.int8).tobytes())
            host[f"{name}.tile"] = tile
            host[f"{name}.shape"] = np.array([k_tiles, n_blocks])
            host[f"{name}.wscale"] = lin.wscale
            if lin.smooth is not None:
                host[f"{name}.smooth"] = lin.smooth
            if lin.b is not None:
                host[f"{name}.bias"] = lin.b
        size = ddr.tell()
    for i, layer in enumerate(model.layers):
        host[f"layer{i}.input_norm"] = layer["input_norm"]
        host[f"layer{i}.post_norm"] = layer["post_norm"]
    np.savez(os.path.join(out_dir, "qwen-host.npz"), **host)
    write_tables(out_dir, tokenizer, cfg)
    tiles = size // (n * n)
    print(f"out/qwen-ddr.bin: {size:,} bytes, {tiles:,} tiles of {n * n} bytes")
    print(f"  per layer {layout[4][2]:,} tiles; output head {layout[-1][3]} x {layout[-1][4]} = "
          f"{layout[-1][3] * layout[-1][4]:,} tiles from tile {layout[-1][2]:,}")


if __name__ == "__main__":
    main()
