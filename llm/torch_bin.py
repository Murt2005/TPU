#!/usr/bin/env python3
"""Read a PyTorch .bin checkpoint without PyTorch.

A .bin is a zip: `<name>/data.pkl` holds a pickled state dict whose tensors
are persistent-id references, and `<name>/data/<k>` holds each tensor's raw
storage bytes. Unpickling normally needs torch to resolve `torch.FloatStorage`
and `torch._utils._rebuild_tensor_v2`; this module stubs both and rebuilds
plain numpy arrays instead.

Only what a dense transformer checkpoint uses is supported: contiguous
(or transposable) float/int storages, no sparse tensors, no nested modules.
A stride the loader cannot express as a numpy view raises rather than
silently returning wrong numbers.
"""
import pickle
import zipfile

import numpy as np

# torch storage class name -> numpy dtype
_DTYPES = {
    "FloatStorage": np.float32,
    "HalfStorage": np.float16,
    "DoubleStorage": np.float64,
    "BFloat16Storage": None,      # needs a manual widen, see _read_storage
    "LongStorage": np.int64,
    "IntStorage": np.int32,
    "ShortStorage": np.int16,
    "CharStorage": np.int8,
    "ByteStorage": np.uint8,
    "BoolStorage": np.bool_,
}


class _Storage:
    __slots__ = ("key", "dtype_name")

    def __init__(self, key, dtype_name):
        self.key = key
        self.dtype_name = dtype_name


def _rebuild_tensor_v2(storage, storage_offset, size, stride, *_rest):
    return ("tensor", storage, storage_offset, tuple(size), tuple(stride))


class _Unpickler(pickle.Unpickler):
    def find_class(self, module, name):
        if name in _DTYPES:
            return lambda *a, **k: name          # storage class -> its name
        if name == "_rebuild_tensor_v2":
            return _rebuild_tensor_v2
        if module == "collections" and name == "OrderedDict":
            return dict
        # Anything else in a plain state dict is metadata we do not need.
        return lambda *a, **k: None

    def persistent_load(self, pid):
        # ('storage', <storage_cls>, key, location, numel)
        _tag, storage_cls, key, _loc, _numel = pid
        name = storage_cls if isinstance(storage_cls, str) else storage_cls()
        return _Storage(key, name)


def _read_storage(zf, prefix, st):
    with zf.open(f"{prefix}/data/{st.key}") as fh:
        raw = fh.read()
    if st.dtype_name == "BFloat16Storage":
        # bf16 is the top 16 bits of an fp32; widen by left-shifting into place.
        u16 = np.frombuffer(raw, dtype="<u2").astype(np.uint32) << 16
        return u16.view(np.float32) if u16.dtype == np.uint32 else u16.astype(np.float32)
    dt = _DTYPES.get(st.dtype_name)
    if dt is None:
        raise ValueError(f"unsupported storage type {st.dtype_name}")
    return np.frombuffer(raw, dtype=dt)


def load(path):
    """Return {name: np.ndarray} for a PyTorch .bin state dict."""
    zf = zipfile.ZipFile(path)
    pkl = [n for n in zf.namelist() if n.endswith("/data.pkl")]
    if not pkl:
        raise ValueError(f"{path} has no data.pkl -- not a PyTorch zip checkpoint")
    prefix = pkl[0].rsplit("/", 1)[0]
    with zf.open(pkl[0]) as fh:
        raw_state = _Unpickler(fh).load()

    out = {}
    for name, val in raw_state.items():
        if not (isinstance(val, tuple) and val and val[0] == "tensor"):
            continue
        _, st, off, size, stride = val
        flat = _read_storage(zf, prefix, st)
        n = int(np.prod(size)) if size else 1
        expected = _contiguous_stride(size)
        if stride == expected:
            out[name] = flat[off:off + n].reshape(size).copy()
        else:
            # Non-contiguous: express as strided view over the flat storage.
            itemsize = flat.dtype.itemsize
            out[name] = np.lib.stride_tricks.as_strided(
                flat[off:], shape=size,
                strides=tuple(s * itemsize for s in stride)).copy()
    return out


def _contiguous_stride(size):
    stride, acc = [], 1
    for d in reversed(size):
        stride.append(acc)
        acc *= d
    return tuple(reversed(stride))


if __name__ == "__main__":
    import sys
    sd = load(sys.argv[1])
    total = sum(v.size for v in sd.values())
    print(f"{len(sd)} tensors, {total/1e6:.2f}M params")
    for k, v in list(sd.items())[:40]:
        print(f"  {k:<48} {str(v.shape):<18} {v.dtype}")
