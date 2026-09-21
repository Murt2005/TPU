#!/usr/bin/env python3
"""GPT-2 byte-level BPE, in pure Python.

TinyStories uses the GPT-Neo tokenizer, which is GPT-2's. This is the
standard implementation (byte<->unicode mapping, then greedy merges by rank)
with no dependency on `tokenizers` or `transformers`, so the demo runs with
nothing but numpy installed.
"""
import json
import os
import re
from functools import lru_cache


@lru_cache()
def _byte_encoder():
    """Reversible byte <-> printable-unicode map, so BPE never sees control
    characters or a literal space (which would collide with the merge-file
    format)."""
    bs = (list(range(ord("!"), ord("~") + 1))
          + list(range(ord("\xa1"), ord("\xac") + 1))
          + list(range(ord("\xae"), ord("\xff") + 1)))
    cs = bs[:]
    n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b)
            cs.append(256 + n)
            n += 1
    return dict(zip(bs, (chr(c) for c in cs)))


_PAT = re.compile(
    r"""'s|'t|'re|'ve|'m|'ll|'d| ?[A-Za-z]+| ?[0-9]+| ?[^\sA-Za-z0-9]+|\s+(?!\S)|\s+""")


class Tokenizer:
    def __init__(self, vocab_path, merges_path):
        with open(vocab_path, encoding="utf-8") as fh:
            self.encoder = json.load(fh)
        self.decoder = {v: k for k, v in self.encoder.items()}
        with open(merges_path, encoding="utf-8") as fh:
            lines = fh.read().split("\n")[1:]           # drop "#version:"
        merges = [tuple(l.split()) for l in lines if len(l.split()) == 2]
        self.ranks = {m: i for i, m in enumerate(merges)}
        self.b2u = _byte_encoder()
        self.u2b = {v: k for k, v in self.b2u.items()}
        self._cache = {}

    @classmethod
    def from_dir(cls, d):
        return cls(os.path.join(d, "vocab.json"), os.path.join(d, "merges.txt"))

    def _bpe(self, token):
        if token in self._cache:
            return self._cache[token]
        word = list(token)
        while len(word) > 1:
            # Merge the adjacent pair with the lowest rank, repeatedly.
            pairs = {(word[i], word[i + 1]) for i in range(len(word) - 1)}
            best = min(pairs, key=lambda p: self.ranks.get(p, float("inf")))
            if best not in self.ranks:
                break
            a, b = best
            merged, i = [], 0
            while i < len(word):
                if i < len(word) - 1 and word[i] == a and word[i + 1] == b:
                    merged.append(a + b)
                    i += 2
                else:
                    merged.append(word[i])
                    i += 1
            word = merged
        self._cache[token] = word
        return word

    def encode(self, text):
        ids = []
        for chunk in _PAT.findall(text):
            token = "".join(self.b2u[b] for b in chunk.encode("utf-8"))
            ids.extend(self.encoder[p] for p in self._bpe(token))
        return ids

    def decode(self, ids):
        text = "".join(self.decoder[i] for i in ids)
        return bytearray(self.u2b[c] for c in text).decode("utf-8", errors="replace")


if __name__ == "__main__":
    import sys
    tk = Tokenizer.from_dir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "model"))
    s = sys.argv[1] if len(sys.argv) > 1 else "Once upon a time, there was a little girl."
    ids = tk.encode(s)
    print(f"{len(ids)} tokens: {ids}")
    print(f"roundtrip: {tk.decode(ids)!r}")
    assert tk.decode(ids) == s, "BPE roundtrip mismatch"
    print("roundtrip OK")
