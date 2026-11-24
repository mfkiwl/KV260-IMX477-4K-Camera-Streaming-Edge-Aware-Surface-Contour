"""Measure native-raster RGB error and luminance SSIM against an independent reference."""
import argparse
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def rgb(path):
    with Image.open(path) as im:
        return np.asarray(im.convert("RGB"))


def local_ssim(a, b):
    """BT.709 Y', 11-by-11 Gaussian, sigma 1.5, population moments, valid windows."""
    kernel = np.exp(-0.5 * (np.arange(-5, 6) / 1.5) ** 2)
    kernel /= kernel.sum()

    def gaussian_valid(im):
        height, width = im.shape
        rows = np.zeros((height, width - 10), dtype=np.float64)
        for i, weight in enumerate(kernel):
            rows += weight * im[:, i:i + width - 10]
        result = np.zeros((height - 10, width - 10), dtype=np.float64)
        for i, weight in enumerate(kernel):
            result += weight * rows[i:i + height - 10]
        return result

    weights = np.array([0.2126, 0.7152, 0.0722])
    x, y = a @ weights, b @ weights
    mx, my = gaussian_valid(x), gaussian_valid(y)
    vx = np.maximum(gaussian_valid(x * x) - mx * mx, 0)
    vy = np.maximum(gaussian_valid(y * y) - my * my, 0)
    cov = gaussian_valid(x * y) - mx * my
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    return float(np.mean(((2 * mx * my + c1) * (2 * cov + c2))
                         / ((mx * mx + my * my + c1) * (vx + vy + c2))))


def metrics(a, b):
    if a.shape != b.shape:
        raise ValueError(f"Raster shapes differ: {a.shape} versus {b.shape}")
    if min(a.shape[:2]) < 11:
        raise ValueError("Both rasters must be at least 11 pixels along each axis for SSIM")
    difference = a.astype(np.int16) - b.astype(np.int16)
    mse = np.mean(difference.astype(np.float64) ** 2)
    return (float(np.abs(difference).mean()),
            math.inf if mse == 0 else 10 * math.log10(255 ** 2 / mse),
            local_ssim(a, b),
            int(np.count_nonzero(np.all(difference == 0, axis=2))))


def describe(path, reference, target):
    a = rgb(path)
    mae, psnr, ssim, equal = metrics(a, target)
    h, w = a.shape[:2]
    print(f"{path.name} versus {reference.name} | {w} x {h} RGB8")
    print(f"Mean absolute RGB channel error = {mae:.6f} / 255")
    print(f"RGB PSNR = {psnr:.6f} dB")
    print(f"Luminance SSIM = {ssim:.6f}")
    print(f"Identical RGB triplets = {equal:,} / {h*w:,}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("actual", type=Path, nargs="?", default=ROOT / "results/PIC1_filtered.bmp")
    parser.add_argument("reference", type=Path, nargs="?", default=ROOT / "reference/Designer1_PIC1_2048x1152.jpg")
    parser.add_argument("--baseline", type=Path, help="also measure this earlier capture against the same artwork")
    args = parser.parse_args()
    try:
        target = rgb(args.reference)
        if args.baseline is not None:
            describe(args.baseline, args.reference, target)
            print()
        describe(args.actual, args.reference, target)
    except (ValueError, OSError) as exc:
        sys.exit(f"Image comparison failed: {exc}")
