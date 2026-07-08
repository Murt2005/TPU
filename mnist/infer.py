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
    python3 mnist/infer.py --port /dev/cu.usbmodemXXXX --compare --test-n 20
        # runs the SAME sampled images on pico2-ice hardware and locally
        # (one-at-a-time and batched/vectorized), prints all three side by side
"""
import argparse
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from train_mnist import IN_SIDE, downsample, hw_layer, load_mnist  # noqa: E402
from tpu_host import TPU, FPGA_CLK_FREQ  # noqa: E402

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


def sample_indices(n_total, n, seed=0):
    rng = np.random.default_rng(seed)
    return rng.choice(n_total, size=min(n, n_total), replace=False)


def run_test_set(inference, x_test, y_test, idx):
    """One-at-a-time loop, same call pattern as the hardware backend (one
    predict_flat() round-trip per image) -- the fair comparison for
    per-image latency, whichever backend is plugged in."""
    correct = 0
    t0 = time.time()
    for i in idx:
        digit, _ = inference.predict_flat(x_test[i])
        correct += int(digit == y_test[i])
    elapsed = time.time() - t0
    return correct, len(idx), elapsed


def predict_batch_offline(model, x_batch_float):
    """Vectorized equivalent of OfflineBackend, run once over the whole
    batch instead of image-by-image -- same exact fixed-point math
    (train_mnist.hw_layer is already row-independent), just without the
    per-image Python call overhead. Shows the local machine's real batch
    throughput rather than a hardware-shaped one-at-a-time loop."""
    m = model
    x_q = _quantize(x_batch_float, float(m["in_scale"]))
    _, _, relu1 = hw_layer(x_q.astype(np.int64), m["w1"].astype(np.int64), m["b1"].astype(np.int64))
    h_q = _quantize(relu1.astype(np.float64), float(m["hidden_scale"]))
    _, _, relu2 = hw_layer(h_q.astype(np.int64), m["w2"].astype(np.int64), m["b2"].astype(np.int64))
    return relu2.argmax(axis=1)


def run_test_set_batched(model, x_test, y_test, idx):
    x_batch = x_test[idx]
    y_batch = y_test[idx]
    t0 = time.time()
    preds = predict_batch_offline(model, x_batch)
    elapsed = time.time() - t0
    correct = int(np.sum(preds == y_batch))
    return correct, len(idx), elapsed


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", help="serial device for the board's 'iCE40 UART' CDC port; omit for --offline")
    p.add_argument("--offline", action="store_true", help="use the pure-numpy backend instead of real hardware")
    p.add_argument("--compare", action="store_true",
                    help="run both the real hardware (--port) and the local pure-numpy backend "
                         "on the exact same sampled images, and print a side-by-side comparison")
    p.add_argument("--test-n", type=int, default=20, help="number of random MNIST test images to classify")
    args = p.parse_args()

    if args.compare and not args.port:
        p.error("--compare requires --port (it compares hardware against the local backend)")
    if not args.offline and not args.port:
        p.error("--port is required unless --offline is given")

    model = load_model()

    print("Loading MNIST test set...")
    _, _, test_images, test_labels = load_mnist()
    x_test = downsample(test_images)
    y_test = test_labels.astype(np.int64)
    idx = sample_indices(len(x_test), args.test_n)

    def report(label, correct, n, elapsed):
        print(f"[{label}] {correct}/{n} correct ({100 * correct / n:.2f}%), "
              f"{elapsed / n * 1000:.2f} ms/image")

    if args.compare:
        with TPU(args.port) as tpu:
            tpu.reset_stats()
            hw_inference = MNISTInference(HardwareBackend(tpu), model)
            hw_result = run_test_set(hw_inference, x_test, y_test, idx)
            hw_uart_s = tpu.uart_wire_seconds()
            hw_rtl_s = tpu.estimated_rtl_seconds()
        local_inference = MNISTInference(OfflineBackend(), model)
        local_result = run_test_set(local_inference, x_test, y_test, idx)
        batched_result = run_test_set_batched(model, x_test, y_test, idx)

        print(f"\nSame {len(idx)} test images, same model, three ways:")
        report("pico2-ice hardware", *hw_result)
        report("Mac local, one image at a time", *local_result)
        report("Mac local, batched/vectorized", *batched_result)

        hw_total_s = hw_result[2]
        hw_overhead_s = hw_total_s - hw_uart_s - hw_rtl_s
        mac_loop_s, mac_batch_s = local_result[2], batched_result[2]
        mac_dispatch_s = mac_loop_s - mac_batch_s
        n = len(idx)

        print(f"\npico2-ice: where did the {hw_total_s * 1000 / n:.2f} ms/image actually go?")
        print(f"  UART wire time (bytes/baud, §uart_wire_seconds)  {hw_uart_s * 1000 / n:8.3f} ms/image "
              f"({100 * hw_uart_s / hw_total_s:5.1f}%)")
        print(f"  RTL compute (21 cycles/RUN @ {FPGA_CLK_FREQ // 1_000_000} MHz)         "
              f"{hw_rtl_s * 1000 / n:8.3f} ms/image ({100 * hw_rtl_s / hw_total_s:5.1f}%)")
        print(f"  USB/pyserial/Python overhead (remainder)         {hw_overhead_s * 1000 / n:8.3f} ms/image "
              f"({100 * hw_overhead_s / hw_total_s:5.1f}%)")
        print(f"\nMac: local backend's own dispatch overhead (one-at-a-time loop vs. one "
              f"batched numpy call for the identical arithmetic):")
        print(f"  Python/numpy call overhead                       "
              f"{mac_dispatch_s * 1000 / n:8.3f} ms/image "
              f"({100 * mac_dispatch_s / mac_loop_s:5.1f}% of the one-at-a-time number)")
        print(f"\nSee docs/PERFORMANCE_ANALYSIS.md for the full writeup and what it does/doesn't mean.")
        return

    if args.offline:
        inference = MNISTInference(OfflineBackend(), model)
        report("offline (one at a time)", *run_test_set(inference, x_test, y_test, idx))
        report("offline (batched/vectorized)", *run_test_set_batched(model, x_test, y_test, idx))
        return

    with TPU(args.port) as tpu:
        inference = MNISTInference(HardwareBackend(tpu), model)
        report("hardware", *run_test_set(inference, x_test, y_test, idx))


if __name__ == "__main__":
    main()
