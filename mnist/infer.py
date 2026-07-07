#!/usr/bin/env python3
"""Multi-layer MNIST inference driver: feeds the trained+quantized MLP
(mnist/train_mnist.py's mnist_2x2_int8.npz) through the real TPU, layer by
layer, using tpu_host.TPU.matmul_tiled() for each layer's K-tiled matmul.

The host does the inter-layer requantization that unified_buffer's 8-bit
activation store forces on any multi-layer network: rtl/activation.sv's
ReLU output is int16, but the *next* layer's activation input can only be
int8 -- there is no on-chip requantization unit, so this driver rescales
via the model's calibrated hidden_scale between layer 1 and layer 2,
exactly like mnist/train_mnist.py's quantized_accuracy() does in its
pure-numpy simulation.

Also provides an OfflineBackend that mirrors the exact same fixed-point
arithmetic in pure numpy (train_mnist.hw_layer()) so this driver -- and
anything built on it, like the drawing demo -- can be exercised without a
board attached, and so hardware predictions can be sanity-checked against
the training script's own quantized-accuracy run.

Usage:
    python3 mnist/infer.py --port /dev/cu.usbmodemXXXX --test-n 50   # hardware
    python3 mnist/infer.py --offline --test-n 200                    # no board
"""
import argparse
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from train_mnist import IN_SIDE, downsample, hw_layer, load_mnist  # noqa: E402
from tpu_host import TPU  # noqa: E402

DEFAULT_MODEL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "model", "mnist_2x2_int8.npz")


def load_model(path=DEFAULT_MODEL):
    with np.load(path) as npz:
        return {k: npz[k] for k in npz.files}


def _quantize(x, scale):
    return np.clip(np.round(np.asarray(x) / scale), -128, 127).astype(np.int8)


def _pad_to_2_rows(row):
    """The hardware requires an even activation-row count (unified_buffer
    is fixed at ROWS=2); pad a single example with a dummy zero row and
    only ever read back row 0."""
    row = np.asarray(row)
    return np.stack([row, np.zeros_like(row)], axis=0)


class OfflineBackend:
    """Pure-numpy stand-in for the hardware: same non-saturating int16
    accumulator semantics (train_mnist.hw_layer), no board required."""

    def run_layer(self, x_row_int8, w_int8, b_int16):
        x2 = _pad_to_2_rows(x_row_int8).astype(np.int64)
        _, _, relu = hw_layer(x2, w_int8.astype(np.int64), b_int16.astype(np.int64))
        return relu[0]


class HardwareBackend:
    """Drives the real pico2-ice board via TPU.matmul_tiled()."""

    def __init__(self, tpu):
        self.tpu = tpu

    def run_layer(self, x_row_int8, w_int8, b_int16):
        x2 = _pad_to_2_rows(x_row_int8)
        out = self.tpu.matmul_tiled(x2, w_int8, b_int16)
        return out[0]


class MNISTInference:
    """model + backend -> predict driver, shared between the hardware and
    offline backends so the drawing demo can use either interchangeably."""

    def __init__(self, backend, model=None):
        self.backend = backend
        self.model = model if model is not None else load_model()

    def predict_flat(self, x64_float):
        """x64_float: length-64 array, pixel intensities in [0,1]
        (train_mnist.downsample()'s output convention)."""
        m = self.model
        x_q = _quantize(x64_float, float(m["in_scale"]))
        h_raw = self.backend.run_layer(x_q, m["w1"], m["b1"])          # int16, ReLU'd
        h_q = _quantize(h_raw.astype(np.float64), float(m["hidden_scale"]))
        scores = self.backend.run_layer(h_q, m["w2"], m["b2"])         # int16, ReLU'd
        digit = int(np.argmax(scores))
        return digit, scores

    def predict_image(self, img28_uint8):
        """img28_uint8: (28,28) array, standard MNIST convention (0 =
        background, 255 = stroke)."""
        x = downsample(img28_uint8[np.newaxis, :, :], out_side=IN_SIDE)[0]
        return self.predict_flat(x)


def run_test_set(inference, x_test, y_test, n, seed=0):
    rng = np.random.default_rng(seed)
    idx = rng.choice(len(x_test), size=min(n, len(x_test)), replace=False)
    correct = 0
    t0 = time.time()
    for i in idx:
        digit, _ = inference.predict_flat(x_test[i])
        correct += int(digit == y_test[i])
    elapsed = time.time() - t0
    return correct, len(idx), elapsed


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", help="serial device for the board's 'iCE40 UART' CDC port; omit for --offline")
    p.add_argument("--offline", action="store_true", help="use the pure-numpy backend instead of real hardware")
    p.add_argument("--test-n", type=int, default=20, help="number of random MNIST test images to classify")
    args = p.parse_args()

    if not args.offline and not args.port:
        p.error("--port is required unless --offline is given")

    model = load_model()

    print("Loading MNIST test set...")
    _, _, test_images, test_labels = load_mnist()
    x_test = downsample(test_images)
    y_test = test_labels.astype(np.int64)

    if args.offline:
        inference = MNISTInference(OfflineBackend(), model)
        correct, n, elapsed = run_test_set(inference, x_test, y_test, args.test_n)
        print(f"[offline] {correct}/{n} correct ({100 * correct / n:.2f}%), "
              f"{elapsed / n * 1000:.2f} ms/image")
        return

    with TPU(args.port) as tpu:
        inference = MNISTInference(HardwareBackend(tpu), model)
        correct, n, elapsed = run_test_set(inference, x_test, y_test, args.test_n)
        print(f"[hardware] {correct}/{n} correct ({100 * correct / n:.2f}%), "
              f"{elapsed / n * 1000:.2f} ms/image")


if __name__ == "__main__":
    main()
