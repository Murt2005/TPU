#!/usr/bin/env python3
"""Interactive MNIST drawing demo: draw a digit, run it through the real
TPU (mnist/infer.py's multi-layer driver), watch the board's LED flip from
green to blue when the on-chip inference completes.

Draws directly into a numpy array in parallel with the visible Tkinter
canvas strokes (no PIL/screen-capture dependency -- matches this repo's
pyserial+numpy-only footprint), then normalizes the drawing the same way
the MNIST dataset itself was prepared (crop to the digit's bounding box,
scale the longest side to 20 px, paste into a 28x28 frame centered by
center of mass) before the usual 28x28 -> IN_SIDExIN_SIDE downsample and
mnist.infer.MNISTInference. Without that normalization the MLP -- which
has no translation invariance -- sees off-center/full-frame drawings as
pixel patterns it never trained on (a 3 px shift alone drops MNIST test
accuracy from 97% to 23%).

LED control rides the board's *second* USB-CDC port ("RP2040 logs",
otherwise idle -- see firmware/main.c) as a one-byte 'g'/'b' command,
entirely separate from the TPU protocol on the first port.

Usage:
    python3 mnist/draw_demo.py --port /dev/cu.usbmodemXXXX --led-port /dev/cu.usbmodemYYYY
    python3 mnist/draw_demo.py --offline   # no board -- pure numpy backend, no LED
"""
import argparse
import os
import sys
import tkinter as tk

import numpy as np
import serial

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from infer import HardwareBackend, MNISTInference, OfflineBackend, load_model  # noqa: E402
from tpu_host import TPU  # noqa: E402

CANVAS_SIZE = 280   # 10x scale of a 28x28 MNIST image
BRUSH_RADIUS = 14


def _stamp_circle(img, cx, cy, r, value=255):
    h, w = img.shape
    x0, x1 = max(0, cx - r), min(w, cx + r + 1)
    y0, y1 = max(0, cy - r), min(h, cy + r + 1)
    if x0 >= x1 or y0 >= y1:
        return
    yy, xx = np.ogrid[y0:y1, x0:x1]
    mask = (xx - cx) ** 2 + (yy - cy) ** 2 <= r * r
    img[y0:y1, x0:x1][mask] = value


def _resize_block_mean(img, out_h, out_w):
    """Block-average a uint8 image to (out_h, out_w) float32 in [0,1] --
    train_mnist.downsample()'s pooling, generalized to rectangular shapes.
    Strokes come out antialiased like real MNIST rather than hard-edged."""
    h, w = img.shape
    edges_r = np.round(np.linspace(0, h, out_h + 1)).astype(int)
    edges_c = np.round(np.linspace(0, w, out_w + 1)).astype(int)
    imgf = img.astype(np.float32) / 255.0
    out = np.zeros((out_h, out_w), dtype=np.float32)
    for i in range(out_h):
        r0, r1 = edges_r[i], max(edges_r[i + 1], edges_r[i] + 1)
        for j in range(out_w):
            c0, c1 = edges_c[j], max(edges_c[j + 1], edges_c[j] + 1)
            out[i, j] = imgf[r0:r1, c0:c1].mean()
    return out


def normalize_drawing(img, box=20, side=28):
    """MNIST-style normalization of a drawing (any resolution, 0=background):
    crop to the ink's bounding box, scale the longest side to `box` px, paste
    into a side x side frame positioned so the center of mass lands at the
    frame's center -- the same preprocessing the MNIST digits were prepared
    with, which the model therefore expects. Returns (side, side) uint8.

    The caller guarantees img has at least one nonzero pixel.
    """
    ys, xs = np.nonzero(img)
    crop = img[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    h, w = crop.shape
    scale = box / max(h, w)
    nh = max(1, int(round(h * scale)))
    nw = max(1, int(round(w * scale)))
    small = _resize_block_mean(crop, nh, nw)

    total = small.sum()
    cy = (small * np.arange(nh)[:, None]).sum() / total
    cx = (small * np.arange(nw)[None, :]).sum() / total
    y0 = int(np.clip(round(side / 2 - cy), 0, side - nh))
    x0 = int(np.clip(round(side / 2 - cx), 0, side - nw))

    frame = np.zeros((side, side), dtype=np.float32)
    frame[y0:y0 + nh, x0:x0 + nw] = small
    return np.clip(frame * 255.0, 0, 255).astype(np.uint8)


def _stamp_line(img, x0, y0, x1, y1, r, value=255):
    dist = max(abs(x1 - x0), abs(y1 - y0), 1)
    steps = int(dist // max(1, r // 2)) + 1
    for i in range(steps + 1):
        t = i / steps
        cx = int(round(x0 + (x1 - x0) * t))
        cy = int(round(y0 + (y1 - y0) * t))
        _stamp_circle(img, cx, cy, r, value)


class DrawApp:
    def __init__(self, root, inference, led_serial=None):
        self.inference = inference
        self.led_serial = led_serial
        self.img = np.zeros((CANVAS_SIZE, CANVAS_SIZE), dtype=np.uint8)
        self.last_xy = None

        root.title("MNIST on a 2x2 TPU")

        self.canvas = tk.Canvas(root, width=CANVAS_SIZE, height=CANVAS_SIZE,
                                 bg="black", cursor="cross")
        self.canvas.grid(row=0, column=0, columnspan=2, padx=10, pady=10)
        self.canvas.bind("<Button-1>", self.on_press)
        self.canvas.bind("<B1-Motion>", self.on_drag)
        self.canvas.bind("<ButtonRelease-1>", self.on_release)

        self.result_var = tk.StringVar(value="Draw a digit, then click Predict")
        tk.Label(root, textvariable=self.result_var, font=("Helvetica", 18),
                 wraplength=CANVAS_SIZE).grid(row=1, column=0, columnspan=2, pady=(0, 10))

        tk.Button(root, text="Predict", command=self.predict,
                  font=("Helvetica", 14)).grid(row=2, column=0, sticky="ew", padx=10, pady=10)
        tk.Button(root, text="Clear", command=self.clear,
                  font=("Helvetica", 14)).grid(row=2, column=1, sticky="ew", padx=10, pady=10)

        root.grid_columnconfigure(0, weight=1)
        root.grid_columnconfigure(1, weight=1)

        self._set_led("g")

    def on_press(self, event):
        self.last_xy = (event.x, event.y)
        _stamp_circle(self.img, event.x, event.y, BRUSH_RADIUS)
        r = BRUSH_RADIUS
        self.canvas.create_oval(event.x - r, event.y - r, event.x + r, event.y + r,
                                 fill="white", outline="white")

    def on_drag(self, event):
        x0, y0 = self.last_xy
        x1, y1 = event.x, event.y
        self.canvas.create_line(x0, y0, x1, y1, width=BRUSH_RADIUS * 2,
                                 fill="white", capstyle=tk.ROUND, smooth=True)
        _stamp_line(self.img, x0, y0, x1, y1, BRUSH_RADIUS)
        self.last_xy = (x1, y1)

    def on_release(self, _event):
        self.last_xy = None

    def clear(self):
        self.img[:] = 0
        self.canvas.delete("all")
        self.result_var.set("Draw a digit, then click Predict")
        self._set_led("g")

    def predict(self):
        if not self.img.any():
            self.result_var.set("Canvas is empty -- draw a digit first")
            return
        self._set_led("g")
        self.result_var.set("Running on TPU...")
        self.canvas.update_idletasks()

        img28_u8 = normalize_drawing(self.img)
        digit, scores = self.inference.predict_image(img28_u8)

        ranked = np.argsort(scores)[::-1]
        breakdown = ", ".join(f"{d}:{int(scores[d])}" for d in ranked[:3])
        self.result_var.set(f"Predicted: {digit}\n(top scores -- {breakdown})")
        self._set_led("b")

    def _set_led(self, cmd):
        if self.led_serial is not None:
            try:
                self.led_serial.write(cmd.encode())
            except Exception:
                pass


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", help="serial device for the board's 'iCE40 UART' CDC port; omit for --offline")
    p.add_argument("--led-port", help="serial device for the board's 'RP2040 logs' CDC port "
                                       "(optional -- LED feedback is skipped if not given)")
    p.add_argument("--offline", action="store_true", help="use the pure-numpy backend instead of real hardware")
    p.add_argument("--rows", type=int, default=2,
                    help="ARRAY_ROWS the flashed bitstream was built with (default 2)")
    p.add_argument("--cols", type=int, default=2,
                    help="NUM_COLS the flashed bitstream was built with (default 2)")
    p.add_argument("--m-tile", type=int, default=None,
                    help="M_TILE the flashed bitstream was built with (default: --rows)")
    p.add_argument("--link", choices=("uart", "spi"), default="uart",
                    help="host-link PHY the board is running (see tpu_host.py --help)")
    args = p.parse_args()

    if not args.offline and not args.port:
        p.error("--port is required unless --offline is given")

    model = load_model()
    led_serial = serial.Serial(args.led_port, 115200, timeout=1) if args.led_port else None

    root = tk.Tk()

    if args.offline:
        inference = MNISTInference(OfflineBackend(), model)
        DrawApp(root, inference, led_serial)
        root.mainloop()
        return

    with TPU(args.port, rows=args.rows, cols=args.cols, m_tile=args.m_tile,
             link=args.link) as tpu:
        inference = MNISTInference(HardwareBackend(tpu), model)
        DrawApp(root, inference, led_serial)
        root.mainloop()

    if led_serial is not None:
        led_serial.close()


if __name__ == "__main__":
    main()
