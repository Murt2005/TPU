"""Qwen2's byte-level BPE in pure Python, from its tokenizer.json, so the runtime
needs nothing beyond numpy. NFC, then the special tokens, then the pre-tokenizer
split, bytes to printable characters, and BPE by merge rank.

The split pattern uses \\p{L} and \\p{N}, which Python's re doesn't have, so
those classes are built from unicodedata as explicit ranges. check.py requires
the same ids as the reference tokenizer on all of WikiText-2.
"""
import json
import os
import re
import sys
import unicodedata
from functools import lru_cache


@lru_cache()
def _byte_encoder():
    """reversible byte <-> printable-character map (GPT-2's), so BPE never sees control chars or spaces"""
    bs = list(range(ord("!"), ord("~") + 1)) + list(range(ord("\xa1"), ord("\xac") + 1)) \
        + list(range(ord("\xae"), ord("\xff") + 1))
    cs = bs[:]
    n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b)
            cs.append(256 + n)
            n += 1
    return dict(zip(bs, (chr(c) for c in cs)))


def _category_class(prefixes):
    """a regex class body matching every code point whose category starts with one of prefixes"""
    ranges, start = [], None
    for cp in range(sys.maxunicode + 2):
        inside = cp <= sys.maxunicode and unicodedata.category(chr(cp))[0] in prefixes
        if inside and start is None:
            start = cp
        elif not inside and start is not None:
            ranges.append((start, cp - 1))
            start = None
    def esc(cp):
        return f"\\U{cp:08x}"
    return "".join(esc(a) if a == b else f"{esc(a)}-{esc(b)}" for a, b in ranges)


@lru_cache()
def _split_pattern():
    """tokenizer.json's split regex, with \\p{L} and \\p{N} spelled out"""
    letter, number = _category_class("L"), _category_class("N")
    return re.compile(
        r"(?i:'s|'t|'re|'ve|'m|'ll|'d)"
        rf"|[^\r\n{letter}{number}]?[{letter}]+"
        rf"|[{number}]"
        rf"| ?[^\s{letter}{number}]+[\r\n]*"
        r"|\s*[\r\n]+"
        r"|\s+(?!\S)"
        r"|\s+")


class Tokenizer:
    def __init__(self, path):
        with open(path, encoding="utf-8") as fh:
            spec = json.load(fh)
        model = spec["model"]
        self.encoder = dict(model["vocab"])
        merges = [tuple(m.split(" ")) if isinstance(m, str) else tuple(m) for m in model["merges"]]
        self.ranks = {m: i for i, m in enumerate(merges)}
        self.special = {t["content"]: t["id"] for t in spec["added_tokens"]}
        self.encoder.update(self.special)
        self.decoder = {v: k for k, v in self.encoder.items()}
        self.special_ids = set(self.special.values())
        self.b2u = _byte_encoder()
        self.u2b = {v: k for k, v in self.b2u.items()}
        self.special_split = re.compile("(" + "|".join(re.escape(t) for t in
                                                      sorted(self.special, key=len, reverse=True)) + ")")
        self._cache = {}

    @classmethod
    def from_dir(cls, d):
        return cls(os.path.join(d, "tokenizer.json"))

    def _bpe(self, token):
        if token in self._cache:
            return self._cache[token]
        word = list(token)
        while len(word) > 1:
            best, rank = None, None
            for pair in zip(word, word[1:]):
                r = self.ranks.get(pair)
                if r is not None and (rank is None or r < rank):
                    best, rank = pair, r
            if best is None:
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
        for piece in self.special_split.split(unicodedata.normalize("NFC", text)):
            if piece in self.special:
                ids.append(self.special[piece])
                continue
            for chunk in _split_pattern().findall(piece):
                token = "".join(self.b2u[b] for b in chunk.encode("utf-8"))
                ids.extend(self.encoder[p] for p in self._bpe(token))
        return ids

    def decode(self, ids):
        out = bytearray()
        for i in ids:
            if i in self.special_ids:
                out += self.decoder[i].encode("utf-8")
            else:
                out += bytes(self.u2b[c] for c in self.decoder[i])
        return out.decode("utf-8", errors="replace")


if __name__ == "__main__":
    tk = Tokenizer.from_dir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "model"))
    text = " ".join(sys.argv[1:]) or "Hello, world! 1234 tokens"
    ids = tk.encode(text)
    print(ids)
    print(repr(tk.decode(ids)))
