#!/usr/bin/env python3
"""draw a digit and classify it on the TPU.
pico2-ice: the board's LED flips green -> blue over the otherwise-idle second CDC port.
DE1-SoC (--de1soc): the board's ARM runs the whole inference on the TPU and shows
the digit on the HEX displays (software/mnist/de1soc/mnist_tpu serve)"""
import argparse
import struct
import time
import tkinter as tk

import numpy as np
import serial

from infer import HardwareBackend, MNISTInference, OfflineBackend, load_model
from tpu import TPU

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
    """train_mnist.downsample()'s pooling for any shape; keeps strokes antialiased"""
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
    """crop, scale to `box` px and center by mass, as MNIST was prepared: the MLP has
    no translation invariance (a 3 px shift drops accuracy from 97% to 23%).
    img must have at least one nonzero pixel"""
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


class De1SocBoard:
    """the DE1-SoC's ARM over its serial console running `mnist_tpu serve`: the
    28x28 drawing goes to the board, which downsamples, quantizes, runs both layers
    on the TPU and lights the digit on HEX0. clear() puts dashes back"""

    def __init__(self, port, baud=115200, program="/mnt/boot/mnist_tpu", model="/mnt/boot/model.bin"):
        from tpu.isa_device import BoardConsole
        self.con = BoardConsole(port)
        if baud == BoardConsole.BAUD:
            self.con.launch(f"{program} serve {model}", timeout=20.0)
        else:
            # the board switches its side for the session, then says 'S' at the new rate
            self.con.launch(f"{program} serve {model} {baud}", timeout=20.0)
            self.con._s.baudrate = baud
        self.baud = baud
        if self.con.read(1) != b"S":
            raise RuntimeError("mnist_tpu didn't start on the board")
        self.last_us = None

    def predict_image(self, img28_uint8):
        t0 = time.time()
        self.con.write(b"I" + np.ascontiguousarray(img28_uint8, dtype=np.uint8).tobytes())
        if self.con.read(1) != b"R":
            raise RuntimeError("board: bad reply")
        digit = self.con.read(1)[0]
        scores = np.array(struct.unpack("<10i", self.con.read(40)))
        (self.last_us,) = struct.unpack("<I", self.con.read(4))
        self.last_round_trip_ms = (time.time() - t0) * 1e3
        return digit, scores

    def clear(self):
        self.con.write(b"C")
        self.con.read(1)

    def close(self):
        self.con.write(b"Q")
        self.con._s.flush()
        time.sleep(0.3)                 # the board restores 115200 as it exits
        self.con._s.baudrate = 115200
        self.con.close(None)


class DrawApp:
    def __init__(self, root, inference, led_serial=None, title="MNIST on a 2x2 TPU", board=None):
        self.inference = inference
        self.led_serial = led_serial
        self.board = board
        self.img = np.zeros((CANVAS_SIZE, CANVAS_SIZE), dtype=np.uint8)
        self.last_xy = None

        root.title(title)

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
        if self.board is not None:
            self.board.clear()

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
        timing = ""
        if self.board is not None:
            timing = (f"\non the board: {self.board.last_us} us; "
                      f"with the serial link: {self.board.last_round_trip_ms:.0f} ms")
        self.result_var.set(f"Predicted: {digit}\n(top scores -- {breakdown}){timing}")
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
    p.add_argument("--de1soc", metavar="PORT",
                   help="the DE1-SoC's HPS console (the CP2105 'Enhanced' port); the board runs "
                        "the inference on its TPU and shows the digit on the HEX displays")
    p.add_argument("--baud", type=int, default=115200,
                   help="console rate for the --de1soc session: 115200 (default) or 1562500, "
                        "the fastest the HPS UART and the CP2105 agree on (13.6x)")
    p.add_argument("--rows", type=int, default=2,
                    help="ARRAY_ROWS the flashed bitstream was built with (default 2)")
    p.add_argument("--cols", type=int, default=2,
                    help="NUM_COLS the flashed bitstream was built with (default 2)")
    p.add_argument("--m-tile", type=int, default=None,
                    help="M_TILE the flashed bitstream was built with (default: --rows)")
    p.add_argument("--link", choices=("uart", "spi"), default="uart",
                    help="host-link PHY the board is running (see python3 -m tpu --help)")
    args = p.parse_args()

    if args.de1soc:
        board = De1SocBoard(args.de1soc, baud=args.baud)
        root = tk.Tk()
        try:
            DrawApp(root, board, title="MNIST on the DE1-SoC TPU (8x8)", board=board)
            root.mainloop()
        finally:
            board.close()
        return

    if not args.offline and not args.port:
        p.error("--port is required unless --offline or --de1soc is given")

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
