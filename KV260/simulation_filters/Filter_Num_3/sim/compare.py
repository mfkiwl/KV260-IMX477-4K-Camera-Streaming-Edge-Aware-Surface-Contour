"""Measure complete decoded images at native resolution. Python 3, NumPy and Pillow."""
import argparse
import hashlib
from pathlib import Path

import numpy as np
from PIL import Image


def gaussian_valid(image):
    """11x11 separable Gaussian, sigma 1.5. Return only complete windows."""
    axis = np.arange(-5, 6, dtype=np.float64)
    weights = np.exp(-0.5 * (axis / 1.5) ** 2)
    weights /= weights.sum()
    height, width = image.shape
    horizontal = np.zeros((height, width - 10), dtype=np.float64)
    for offset, weight in enumerate(weights):
        horizontal += weight * image[:, offset:offset + width - 10]
    result = np.zeros((height - 10, width - 10), dtype=np.float64)
    for offset, weight in enumerate(weights):
        result += weight * horizontal[offset:offset + height - 10]
    return result


def ssim_luma(actual, reference):
    # Full-range BT.601 luma; population variance, K1=.01, K2=.03, L=255.
    coefficients = np.array([0.299, 0.587, 0.114])
    a, b = actual @ coefficients, reference @ coefficients
    ma, mb = gaussian_valid(a), gaussian_valid(b)
    va = gaussian_valid(a*a) - ma*ma
    vb = gaussian_valid(b*b) - mb*mb
    cov = gaussian_valid(a*b) - ma*mb
    c1, c2 = (0.01*255)**2, (0.03*255)**2
    local = ((2*ma*mb + c1) / (ma*ma + mb*mb + c1)
             * (2*cov + c2) / (va + vb + c2))
    return float(local.mean())


def measure(output, reference):
    with Image.open(output) as image, Image.open(reference) as target:
        if image.size != target.size:
            raise ValueError(f"Raster dimensions differ: {image.size} versus {target.size}")
        a = np.asarray(image.convert("RGB"))
        b = np.asarray(target.convert("RGB"))
    error = a.astype(np.int16) - b
    mse = float(np.square(error, dtype=np.float64).mean())
    return dict(width=a.shape[1], height=a.shape[0], pixels=a.shape[0]*a.shape[1],
                mae=float(np.abs(error).mean()), mse=mse,
                psnr=float(10*np.log10(255**2/mse)) if mse else float("inf"),
                ssim=ssim_luma(a, b), exact=int(np.all(a == b, axis=2).sum()),
                max_error=int(np.abs(error).max()),
                rgb_sha256=hashlib.sha256(a.tobytes()).hexdigest())


def report(output, reference):
    m = measure(output, reference)
    print(f"{output.name} vs {reference.name}\n"
          f"Raster {m['width']} x {m['height']}  |  pixels {m['pixels']:,}\n"
          f"RGB MAE {m['mae']:.5f} / 255  |  RGB PSNR {m['psnr']:.4f} dB\n"
          f"Luma SSIM {m['ssim']:.6f}  |  exact RGB pixels {m['exact']:,}\n"
          f"Maximum channel error {m['max_error']} / 255\n"
          f"Output decoded RGB SHA-256 {m['rgb_sha256']}")
    return m


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("reference", type=Path)
    args = parser.parse_args()
    report(args.output, args.reference)
