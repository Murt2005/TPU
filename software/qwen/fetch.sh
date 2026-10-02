#!/bin/sh
# download Qwen2.5-0.5B (bf16 safetensors, config, tokenizer) and the WikiText-2
# eval text into model/ and data/ (gitignored, reproducible)
# usage: ./fetch.sh [model-id]
set -e
MODEL="${1:-Qwen/Qwen2.5-0.5B}"
DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DIR/model" "$DIR/data"
echo "fetching $MODEL ..."
for f in config.json generation_config.json model.safetensors tokenizer.json tokenizer_config.json vocab.json merges.txt; do
    [ -s "$DIR/model/$f" ] || curl -sSL --fail -o "$DIR/model/$f" "https://huggingface.co/$MODEL/resolve/main/$f"
    echo "  $f"
done
WT="https://huggingface.co/datasets/Salesforce/wikitext/resolve/main/wikitext-2-raw-v1"
for split in test train; do
    f="wikitext-2-raw-v1-$split.parquet"
    [ -s "$DIR/data/$f" ] || curl -sSL --fail -o "$DIR/data/$f" "$WT/$split-00000-of-00001.parquet"
    echo "  $f"
done
