#!/usr/bin/env python3
"""Train + quantize a tiny MNIST MLP sized for this repo's 2x2 TPU.

Host-side only -- no hardware/serial dependency. Produces
mnist/model/mnist_2x2_int8.npz, an int8-weight/int16-bias two-layer MLP
whose exact fixed-point forward pass (mnist/model.py) mirrors the RTL:

  - int8 weights and activations, int16 bias (rtl/tpu_sequencer.sv wire
    format).
  - Accumulation happens in a PSUM_WIDTH=16 register (rtl/accumulator.sv)
    that is NOT saturating -- it silently wraps on overflow, exactly like
    tests/hw_regression.py's golden() model. This is true regardless of
    K-dim tiling (rtl/accumulator.sv's persistent psum_reg is 16 bits
    whether one RUN or many passes feed it), so a layer's K (its input
    width) can't be so large that realistic int8-range weights/activations
    push the true sum past +-32767.
  - ReLU is applied unconditionally by rtl/activation.sv on *every* layer,
    including the output layer -- there is no "skip activation" mode. The
    network is trained with ReLU on the output logits too, so the loss
    landscape matches what the hardware will actually produce (argmax over
    ReLU'd scores), rather than training a standard logits-then-softmax
    network and hoping ReLU doesn't disturb its decision boundve afterward.
  - unified_buffer's activation store is int8 (DATA_WIDTH=8), so a
    multi-layer network run on hardware needs the *host* to re-quantize
    each layer's int16 ReLU output down to int8 before it becomes the next
    layer's input -- there is no on-chip requantization unit. This script
    calibrates that per-layer rescale (hidden_scale below) empirically and
    bakes it into the saved model.

Network: 144 (12x12 downsampled digit) -> 64 (hidden) -> 10 (class scores).
Both K values (144, 64) and both N values (64, 10) are even, so every layer
tiles cleanly into the array's 2x2 blocks with no padding.

Usage:
    python3 mnist/train_mnist.py
"""
import gzip
import os
import subprocess
import sys
import urllib.parse

import numpy as np

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
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


# -- data loading -----------------------------------------------------------

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
    """Block-average images (N,28,28) uint8 -> (N, out_side*out_side) float32 in [0,1].

    Bin edges aren't evenly spaced (28 doesn't divide out_side evenly for
    out_side=8) -- fine for a coarse pooling, not aiming for anti-aliasing
    quality.
    """
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


# -- float model + training --------------------------------------------------

class MLP:
    """64 -> 32 -> 10, ReLU after both layers (matches the hardware: there
    is no non-activated output mode -- rtl/activation.sv always applies
    ReLU), trained with that exact nonlinearity on the output scores."""

    def __init__(self, rng):
        self.w1 = (rng.standard_normal((NUM_IN, NUM_HIDDEN)) * np.sqrt(2.0 / NUM_IN)).astype(np.float32)
        self.b1 = np.zeros(NUM_HIDDEN, dtype=np.float32)
        self.w2 = (rng.standard_normal((NUM_HIDDEN, NUM_OUT)) * np.sqrt(2.0 / NUM_HIDDEN)).astype(np.float32)
        self.b2 = np.zeros(NUM_OUT, dtype=np.float32)

    def forward(self, x):
        z1 = x @ self.w1 + self.b1
        h = np.maximum(z1, 0)
        z2 = h @ self.w2 + self.b2
        out = np.maximum(z2, 0)   # ReLU on the output too -- matches hardware
        return z1, h, z2, out

    def train_step(self, x, y, lr):
        n = x.shape[0]
        z1, h, z2, out = self.forward(x)

        # Softmax cross-entropy on the ReLU'd output scores.
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
    # At this size/lr, test_acc plateaus around ~87% until a sharp breakthrough
    # near epoch 25, then settles around 97% -- fewer epochs looks converged
    # but isn't; don't shrink epochs without re-checking the accuracy curve.
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


# -- quantization -------------------------------------------------------------

def quantize_symmetric(tensor, n_bits=8):
    qmax = 2 ** (n_bits - 1) - 1
    scale = max(float(np.abs(tensor).max()), 1e-8) / qmax
    q = np.clip(np.round(tensor / scale), -qmax - 1, qmax).astype(np.int32)
    return q, scale


def hw_layer(x_int, w_int, b_int):
    """Mirror rtl/accumulator.sv + bias.sv + activation.sv exactly:
    wide-precision MAC, truncate to signed PSUM_WIDTH (non-saturating
    wraparound, not clamping), then ReLU. Matches
    tests/hw_regression.py's golden(). Returns (raw_wide, truncated_i16, relu_out).
    """
    raw = x_int.astype(np.int64) @ w_int.astype(np.int64) + b_int.astype(np.int64)
    truncated = raw.astype(np.int16)   # numpy wraps on overflow, same as the RTL register
    relu = np.maximum(truncated, 0)
    return raw, truncated, relu


def find_safe_input_scale(x_float, w_int, w_scale, bias_float, init_scale, margin=1.05, max_iters=20):
    """Search for the smallest input scale (largest quantized-input range)
    that keeps every calibration sample's raw accumulator strictly inside
    int16 -- not just on average, but for every sample seen. Grows the scale
    (shrinking quantized magnitude) whenever the observed worst case
    overflows, with a 5% safety margin so rounding at the boundary can't tip
    a borderline sample back over on unseen data. (2% wasn't enough headroom
    once NUM_IN/NUM_HIDDEN grew past the original 64->32->10 size: it left a
    1-in-10000 test-set overflow that never showed up during calibration.)
    """
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
    """Quantize weights/biases and calibrate the inter-layer rescale using
    the *exact* integer forward pipeline (not the float model's activations),
    so the saved scales are self-consistent with what hardware will do.
    Both per-layer scales are searched (find_safe_input_scale) to guarantee
    zero int16 accumulator overflow across the whole calibration set, since
    a plain max-abs/127 scale still lets correlated inputs (e.g. a dark
    digit whose many bright pixels line up with same-sign weights) overflow
    on a small fraction of real samples.
    """
    w1_q, w1_scale = quantize_symmetric(model.w1)
    w2_q, w2_scale = quantize_symmetric(model.w2)

    in_scale_init = max(float(np.abs(x_calib).max()), 1e-8) / 127.0
    in_scale, _, b1_q, raw1 = find_safe_input_scale(
        x_calib, w1_q, w1_scale, model.b1, in_scale_init)
    relu1 = np.maximum(raw1.astype(np.int16), 0)
    overflow1 = int(np.sum(raw1 != raw1.astype(np.int16)))

    # Host-side rescale: hidden layer's int16 ReLU output must become int8
    # for the next layer's activation input (unified_buffer is 8-bit).
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
