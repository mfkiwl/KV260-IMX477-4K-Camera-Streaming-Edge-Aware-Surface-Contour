"""Compare a simulator BMP with the reference JPEG decoded to RGB8 by Pillow."""
import argparse
import hashlib
import math
from pathlib import Path

import numpy as np
from PIL import Image


def compare(actual_path, reference_path):
    with Image.open(actual_path) as image:
        actual = np.array(image.convert("RGB"))
    with Image.open(reference_path) as image:
        expected = np.array(image.convert("RGB"))
    if actual.shape != expected.shape:
        raise ValueError(f"Image dimensions differ: {actual.shape} and {expected.shape}")
    equal = np.all(actual == expected, axis=2)
    count = int(np.count_nonzero(equal))
    total = equal.size
    error = actual.astype(np.int16) - expected.astype(np.int16)
    mse = np.mean(np.square(error, dtype=np.float64))
    psnr = math.inf if mse == 0 else 10 * math.log10(255**2 / mse)
    lines = [
        f"Actual: {Path(actual_path).name} ({actual.shape[1]} x {actual.shape[0]})",
        f"Reference: {Path(reference_path).name} (decoded RGB8)",
        f"Exact RGB match: {'PASS' if count == total else 'FAIL'}",
        f"Identical RGB pixels: {count:,} / {total:,} ({100*count/total:.6f}%)",
        f"Mismatched RGB pixels: {total-count:,}",
        f"Mean absolute channel error: {np.abs(error).mean():.6f} / 255",
        f"Maximum absolute channel error: {np.abs(error).max()} / 255",
        f"RGB PSNR: {psnr:.4f} dB",
    ]
    if count != total:
        y, x = np.unravel_index(int(np.argmax(~equal)), equal.shape)
        lines.append(f"First mismatch (x={x}, y={y}): RTL={actual[y,x].tolist()} reference={expected[y,x].tolist()}")
    for name, data in (("RTL", actual), ("reference", expected)):
        lines.append(f"{name} decoded RGB SHA-256: {hashlib.sha256(data.tobytes()).hexdigest()}")
    print("\n".join(lines))
    return count == total


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("actual", type=Path)
    parser.add_argument("reference", type=Path)
    args = parser.parse_args()
    raise SystemExit(0 if compare(args.actual, args.reference) else 1)
