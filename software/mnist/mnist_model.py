"""the trained MNIST model and its host-side reference: loading, quantizing, and the
numpy forward pass (np.round between layers) that the DE1-SoC results are compared to"""
import os

import numpy as np

from train_mnist import IN_SIDE, downsample, hw_layer

DEFAULT_MODEL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "model", "mnist_2x2_int8.npz")


def load_model(path=DEFAULT_MODEL):
    with np.load(path) as npz:
        return {k: npz[k] for k in npz.files}


def quantize(x, scale):
    return np.clip(np.round(np.asarray(x) / scale), -128, 127).astype(np.int8)


def predict_batch_offline(model, x_batch_float):
    """the host reference for a batch of downsampled images: argmax per image"""
    m = model
    x_q = quantize(x_batch_float, float(m["in_scale"]))
    _, _, relu1 = hw_layer(x_q.astype(np.int64), m["w1"].astype(np.int64), m["b1"].astype(np.int64))
    h_q = quantize(relu1.astype(np.float64), float(m["hidden_scale"]))
    _, _, relu2 = hw_layer(h_q.astype(np.int64), m["w2"].astype(np.int64), m["b2"].astype(np.int64))
    return relu2.argmax(axis=1)


class OfflineModel:
    """the reference for one drawn image, with the same predict_image as the board"""

    def __init__(self, model=None):
        self.model = model if model is not None else load_model()

    def predict_image(self, img28_uint8):
        """img28_uint8: (28, 28), 0 = background, 255 = stroke. returns (digit, scores)"""
        m = self.model
        x = downsample(img28_uint8[np.newaxis, :, :], out_side=IN_SIDE)
        x_q = quantize(x, float(m["in_scale"]))
        _, _, relu1 = hw_layer(x_q.astype(np.int64), m["w1"].astype(np.int64), m["b1"].astype(np.int64))
        h_q = quantize(relu1.astype(np.float64), float(m["hidden_scale"]))
        _, _, scores = hw_layer(h_q.astype(np.int64), m["w2"].astype(np.int64), m["b2"].astype(np.int64))
        return int(np.argmax(scores[0])), scores[0]
