"""Check the VHDL view and grade against the native filtered BMP. Requires NumPy and Pillow."""
import argparse
from pathlib import Path

import numpy as np
from PIL import Image


def check(native_path, actual_path):
    with Image.open(native_path) as native_image, Image.open(actual_path) as actual_image:
        width, height = actual_image.size
        if native_image.size != (2048, 1152) or (width, height) not in ((2048,1365), (1536,1024)):
            raise ValueError("Expected a 2048 x 1152 native frame and one of the two Designer portrait sizes")
        native = np.asarray(native_image.convert("RGB"))
        actual = np.asarray(actual_image.convert("RGB"))

    # Direct coordinate formula, independent of the RTL phase accumulators and row RAM.
    if width == 2048:
        knee = 1195
        anchors = np.array([0,9,18,27,39,78,107,140,174,196,218,234,250,252,253,254,255])
        matrix = np.array([[150,12,13,-199,13], [52,20,-63,-63,5], [45,109,-99,-27,61]])
    else:
        knee = 896
        anchors = np.array([0,13,26,39,40,79,105,137,169,190,212,231,250,252,253,254,255])
        matrix = np.array([[134,1,27,-185,-3], [44,7,-55,-53,-13], [38,96,-93,-17,42]])
    x = np.arange(width)
    y = np.arange(height)
    tail = height - 1 - knee
    sx = 105 + (1841 * x + (width - 1)//2) // (width - 1)
    sy = np.where(y <= knee, 1 + (1065 * y + knee//2) // knee,
                  1066 + (85 * (y - knee) + tail//2) // tail)
    mismatches = 0
    for start in range(0, len(y), 64):
        rows = slice(start, start + 64)
        r, g, b = native[sy[rows, None], sx].astype(np.int32).transpose(2, 0, 1)
        luminance = (5*r + 9*g + 2*b + 8) // 16
        k, frac = np.divmod(luminance, 16)
        base = anchors[k] + (frac * (anchors[k+1] - anchors[k]) + 8) // 16
        base = (3*base + 8*((base + 4)//8) + 2) // 4
        u, v = r - g, b - g
        warm = np.maximum(0, u)
        excess = np.maximum(0, u - 16)
        yellow = np.maximum(0, -v - 28)
        features = np.stack((u, v, warm, excess, yellow), axis=-1)
        rgb = features @ matrix.T
        expected = np.clip((64*base[..., None] + rgb + 32)//64, 0, 255)
        mismatches += int(np.any(actual[rows] != expected, axis=-1).sum())
    print(f"RTL versus independent view/grade model: {mismatches:,} mismatched RGB pixels / {actual.shape[0]*actual.shape[1]:,}")
    return mismatches == 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("native", type=Path)
    parser.add_argument("actual", type=Path)
    args = parser.parse_args()
    raise SystemExit(0 if check(args.native, args.actual) else 1)
