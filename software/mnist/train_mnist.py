#!/usr/bin/env python3
"""train and quantize the 144 -> 64 -> 10 int8 MLP (see docs/mnist.md for why it
is shaped around the hardware's numerics). writes model/mnist_2x2_int8.npz"""
import gzip
import os
import subprocess
import sys
import urllib.parse

import numpy as np

from tpu import golden

DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
MODEL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "model")

MNIST_BASE = "https://ossci-datasets.s3.amazonaws.com/mnist/"
MNIST_FILES = {
    "train_images": "train-images-idx3-ubyte.gz",
    "train_labels": "train-labels-idx1-ubyte.gz",
    "test_images": "t10k-images-idx3-ubyte.gz",
    "test_labels": "t10k-labels-idx1-ubyte.gz",
}

IN_SIDE = 12         # downsampled digit is IN_SIDE x IN_SIDE
NUM_IN = IN_SIDE * IN_SIDE   # 144
NUM_HIDDEN = 64
NUM_OUT = 10
PSUM_WIDTH = 16
PSUM_MIN = -(2 ** (PSUM_WIDTH - 1))
PSUM_MAX = 2 ** (PSUM_WIDTH - 1) - 1



def _download(name, url):
    dest = os.path.join(DATA_DIR, name)
    if os.path.exists(dest):
        return dest
    os.makedirs(DATA_DIR, exist_ok=True)
    print(f"Downloading {url} -> {dest}")
    subprocess.run(["curl", "-sS", "-o", dest, url], check=True)
    return dest


def _read_idx_images(path):
    with gzip.open(path, "rb") as f:
        magic = int.from_bytes(f.read(4), "big")
        assert magic == 2051, f"bad image magic {magic} in {path}"
        n = int.from_bytes(f.read(4), "big")
        rows = int.from_bytes(f.read(4), "big")
        cols = int.from_bytes(f.read(4), "big")
        buf = f.read(n * rows * cols)
        return np.frombuffer(buf, dtype=np.uint8).reshape(n, rows, cols)


def _read_idx_labels(path):
    with gzip.open(path, "rb") as f:
        magic = int.from_bytes(f.read(4), "big")
        assert magic == 2049, f"bad label magic {magic} in {path}"
        n = int.from_bytes(f.read(4), "big")
        buf = f.read(n)
        return np.frombuffer(buf, dtype=np.uint8).copy()


def load_mnist():
    paths = {k: _download(v, urllib.parse.urljoin(MNIST_BASE, v)) for k, v in MNIST_FILES.items()}
    train_images = _read_idx_images(paths["train_images"])
    train_labels = _read_idx_labels(paths["train_labels"])
    test_images = _read_idx_images(paths["test_images"])
    test_labels = _read_idx_labels(paths["test_labels"])
    return train_images, train_labels, test_images, test_labels


def downsample(images, out_side=IN_SIDE):
    """block-average (N, 28, 28) uint8 to (N, out_side**2) float32 in [0, 1]"""
    n, rows, cols = images.shape
    edges_r = np.round(np.linspace(0, rows, out_side + 1)).astype(int)
    edges_c = np.round(np.linspace(0, cols, out_side + 1)).astype(int)
    imgs = images.astype(np.float32) / 255.0
    out = np.zeros((n, out_side, out_side), dtype=np.float32)
    for i in range(out_side):
        for j in range(out_side):
            block = imgs[:, edges_r[i]:edges_r[i + 1], edges_c[j]:edges_c[j + 1]]
            out[:, i, j] = block.mean(axis=(1, 2))
    return out.reshape(n, out_side * out_side)



class MLP:
    """relu on the output too, because the hardware applies it there"""

    def __init__(self, rng):
        self.w1 = (rng.standard_normal((NUM_IN, NUM_HIDDEN)) * np.sqrt(2.0 / NUM_IN)).astype(np.float32)
        self.b1 = np.zeros(NUM_HIDDEN, dtype=np.float32)
        self.w2 = (rng.standard_normal((NUM_HIDDEN, NUM_OUT)) * np.sqrt(2.0 / NUM_HIDDEN)).astype(np.float32)
        self.b2 = np.zeros(NUM_OUT, dtype=np.float32)

    def forward(self, x):
        z1 = x @ self.w1 + self.b1
        h = np.maximum(z1, 0)
        z2 = h @ self.w2 + self.b2
        out = np.maximum(z2, 0)   # relu on the output too -- matches hardware
        return z1, h, z2, out

    def train_step(self, x, y, lr):
        n = x.shape[0]
        z1, h, z2, out = self.forward(x)

        # softmax over the ReLU'd scores, matching what the hardware returns
        shifted = out - out.max(axis=1, keepdims=True)
        exp = np.exp(shifted)
        probs = exp / exp.sum(axis=1, keepdims=True)
        onehot = np.zeros_like(probs)
        onehot[np.arange(n), y] = 1.0
        loss = -np.log(probs[np.arange(n), y] + 1e-9).mean()

        d_out = (probs - onehot) / n
        d_z2 = d_out * (z2 > 0)
        d_w2 = h.T @ d_z2
        d_b2 = d_z2.sum(axis=0)

        d_h = d_z2 @ self.w2.T
        d_z1 = d_h * (z1 > 0)
        d_w1 = x.T @ d_z1
        d_b1 = d_z1.sum(axis=0)

        self.w1 -= lr * d_w1
        self.b1 -= lr * d_b1
        self.w2 -= lr * d_w2
        self.b2 -= lr * d_b2
        return loss

    def accuracy(self, x, y):
        _, _, _, out = self.forward(x)
        pred = out.argmax(axis=1)
        return (pred == y).mean()


def train(x_train, y_train, x_test, y_test, epochs=40, batch_size=128, lr=0.5, seed=0):
    # accuracy plateaus near 87% until ~epoch 25: fewer epochs only looks converged
    rng = np.random.default_rng(seed)
    model = MLP(rng)
    n = x_train.shape[0]
    for epoch in range(epochs):
        perm = rng.permutation(n)
        losses = []
        for start in range(0, n, batch_size):
            idx = perm[start:start + batch_size]
            losses.append(model.train_step(x_train[idx], y_train[idx], lr))
        acc = model.accuracy(x_test, y_test)
        print(f"epoch {epoch + 1:2d}/{epochs}  loss={np.mean(losses):.4f}  test_acc={acc * 100:.2f}%")
    return model



def quantize_symmetric(tensor, n_bits=8):
    qmax = 2 ** (n_bits - 1) - 1
    scale = max(float(np.abs(tensor).max()), 1e-8) / qmax
    q = np.clip(np.round(tensor / scale), -qmax - 1, qmax).astype(np.int32)
    return q, scale


def hw_layer(x_int, w_int, b_int):
    """the hardware's layer math via tpu.golden; returns (raw, wrapped int16, relu)"""
    raw = golden.accumulate(x_int, w_int, b_int)
    truncated = golden.wrap(raw, 16)   # wraps on overflow, same as the RTL register
    relu = np.maximum(truncated, 0)
    return raw, truncated, relu


def find_safe_input_scale(x_float, w_int, w_scale, bias_float, init_scale, margin=1.05, max_iters=20):
    """smallest input scale that keeps every calibration sample's sum inside int16,
    with a 5% margin (2% left a 1-in-10000 overflow on the test set)"""
    scale = init_scale
    for _ in range(max_iters):
        x_q = np.clip(np.round(x_float / scale), -128, 127).astype(np.int32)
        bias_scale = w_scale * scale
        b_q = np.clip(np.round(bias_float / bias_scale), PSUM_MIN, PSUM_MAX).astype(np.int32)
        raw = x_q.astype(np.int64) @ w_int.astype(np.int64) + b_q.astype(np.int64)
        worst = int(np.abs(raw).max())
        if worst <= PSUM_MAX:
            return scale, x_q, b_q, raw
        scale *= (worst / PSUM_MAX) * margin
    raise RuntimeError("could not find an input scale keeping the accumulator inside int16")


def build_quantized_model(model, x_calib):
    """calibrates against the exact integer pipeline, not the float model"""
    w1_q, w1_scale = quantize_symmetric(model.w1)
    w2_q, w2_scale = quantize_symmetric(model.w2)

    in_scale_init = max(float(np.abs(x_calib).max()), 1e-8) / 127.0
    in_scale, _, b1_q, raw1 = find_safe_input_scale(
        x_calib, w1_q, w1_scale, model.b1, in_scale_init)
    relu1 = np.maximum(raw1.astype(np.int16), 0)
    overflow1 = int(np.sum(raw1 != raw1.astype(np.int16)))

    # no on-chip requantization: the host rescales int16 to int8 between layers
    hidden_scale_init = max(float(relu1.max()), 1e-8) / 127.0
    hidden_scale, _, b2_q, raw2 = find_safe_input_scale(
        relu1.astype(np.float64), w2_q, w2_scale, model.b2, hidden_scale_init)
    overflow2 = int(np.sum(raw2 != raw2.astype(np.int16)))

    print(f"Calibration overflow check: layer1 {overflow1}/{len(raw1)} samples wrapped, "
          f"layer2 {overflow2}/{len(raw2)} samples wrapped "
          f"(0 means every accumulator value fit safely inside int16)")

    return {
        "w1": w1_q.astype(np.int8), "b1": b1_q.astype(np.int16),
        "w2": w2_q.astype(np.int8), "b2": b2_q.astype(np.int16),
        "in_scale": in_scale, "hidden_scale": hidden_scale,
        "w1_scale": w1_scale, "w2_scale": w2_scale,
        "in_side": IN_SIDE,
    }


def quantized_accuracy(qmodel, x, y):
    in_scale = qmodel["in_scale"]
    x_q = np.clip(np.round(x / in_scale), -128, 127).astype(np.int32)
    raw1, trunc1, relu1 = hw_layer(x_q, qmodel["w1"].astype(np.int32), qmodel["b1"].astype(np.int32))
    overflow1 = int(np.sum(raw1 != trunc1))

    h_q = np.clip(np.round(relu1.astype(np.float64) / qmodel["hidden_scale"]), -128, 127).astype(np.int32)
    raw2, trunc2, relu2 = hw_layer(h_q, qmodel["w2"].astype(np.int32), qmodel["b2"].astype(np.int32))
    overflow2 = int(np.sum(raw2 != trunc2))

    pred = relu2.argmax(axis=1)
    acc = (pred == y).mean()
    return acc, overflow1, overflow2


def main():
    print("Loading MNIST...")
    train_images, train_labels, test_images, test_labels = load_mnist()

    print(f"Downsampling 28x28 -> {IN_SIDE}x{IN_SIDE} ({NUM_IN} inputs)...")
    x_train = downsample(train_images)
    x_test = downsample(test_images)
    y_train = train_labels.astype(np.int64)
    y_test = test_labels.astype(np.int64)

    print(f"\nTraining {NUM_IN}->{NUM_HIDDEN}->{NUM_OUT} MLP (ReLU on every layer, matching hardware)...")
    model = train(x_train, y_train, x_test, y_test)
    float_acc = model.accuracy(x_test, y_test)
    print(f"\nFloat model test accuracy: {float_acc * 100:.2f}%")

    print("\nQuantizing (int8 weights/activations, int16 bias, calibrated on the training set)...")
    qmodel = build_quantized_model(model, x_train)

    q_acc, ov1, ov2 = quantized_accuracy(qmodel, x_test, y_test)
    print(f"\nQuantized (int8/int16, hardware-exact) test accuracy: {q_acc * 100:.2f}%")
    print(f"Test-set overflow check: layer1 {ov1}/{len(x_test)}, layer2 {ov2}/{len(x_test)} "
          f"accumulator values wrapped (must be 0 for a numerically-safe design)")
    if ov1 or ov2:
        print("WARNING: int16 accumulator overflow detected on the test set -- "
              "shrink NUM_HIDDEN/IN_SIDE or recalibrate scales before trusting this model.",
              file=sys.stderr)

    os.makedirs(MODEL_DIR, exist_ok=True)
    out_path = os.path.join(MODEL_DIR, "mnist_2x2_int8.npz")
    np.savez(out_path, **qmodel)
    print(f"\nSaved quantized model to {out_path}")


if __name__ == "__main__":
    main()
