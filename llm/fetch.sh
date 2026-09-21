#!/bin/sh
# Download TinyStories-1M and quantize it into llm/model/.
#
# Everything this produces is gitignored and reproducible: the checkpoint and
# tokenizer come from Hugging Face, the .npz is built by llm/export.py.
#
# Usage:  ./llm/fetch.sh [model-id]        (default roneneldan/TinyStories-1M)
set -e
MODEL="${1:-roneneldan/TinyStories-1M}"
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/model"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$OUT"
echo "fetching $MODEL ..."
for f in config.json pytorch_model.bin vocab.json merges.txt; do
    curl -sSL --fail -o "$TMP/$f" "https://huggingface.co/$MODEL/resolve/main/$f"
    echo "  $f"
done
cp "$TMP/vocab.json" "$TMP/merges.txt" "$OUT/"

NAME="$(basename "$MODEL" | tr '[:upper:]' '[:lower:]')"
python3 "$DIR/export.py" --bin "$TMP/pytorch_model.bin" \
    --config "$TMP/config.json" -o "$OUT/$NAME.npz"
echo
echo "done. Run it with:"
echo "  make sim-bridge"
echo "  python3 llm/infer.py --link sim --port sim/verilator/bridge/tb_tpu_top \\"
echo "      --model $OUT/$NAME.npz --prompt 'Once upon a time' -n 20"
