"""Compare two decoded RGB8 rasters in native coordinates. Requires Pillow."""
import argparse
import hashlib
import math
import sys
from pathlib import Path

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[1]


def compare(actual_path, reference_path):
    with Image.open(actual_path) as image:
        actual = image.convert("RGB")
    with Image.open(reference_path) as image:
        reference = image.convert("RGB")

    print(f"Actual: {actual_path.name} ({actual.width} x {actual.height})")
    print(f"Reference: {reference_path.name} ({reference.width} x {reference.height})")
    if actual.size != reference.size:
        print("Exact RGB comparison: FAIL (different dimensions)")
        return False

    for label, raster in (("Actual", actual), ("Reference", reference)):
        print(f"{label} decoded RGB SHA-256: {hashlib.sha256(raster.tobytes()).hexdigest()}")

    diff = ImageChops.difference(actual, reference)
    dr, dg, db = diff.split()
    largest_difference = ImageChops.lighter(ImageChops.lighter(dr, dg), db)
    pixels = actual.width * actual.height
    equal = largest_difference.histogram()[0]
    hist = diff.histogram()
    absolute_sum = sum((i % 256) * n for i, n in enumerate(hist))
    square_sum = sum((i % 256) ** 2 * n for i, n in enumerate(hist))
    print(f"Identical RGB pixels: {equal:,} / {pixels:,} ({100 * equal / pixels:.6f}%)")
    print(f"Mismatched RGB pixels: {pixels - equal:,} / {pixels:,}")
    print(f"Mean absolute channel error: {absolute_sum / (3 * pixels):.6f} / 255")
    print(f"Maximum absolute channel error: {largest_difference.getextrema()[1]} / 255")
    if square_sum:
        print(f"RGB PSNR: {10 * math.log10(255**2 * 3 * pixels / square_sum):.4f} dB")
        y = largest_difference.getbbox()[1]
        x = largest_difference.crop((0, y, actual.width, y + 1)).getbbox()[0]
        print(f"First mismatch (x={x}, y={y}): RTL={actual.getpixel((x,y))}, "
              f"reference={reference.getpixel((x,y))}")
    print("Exact RGB comparison:", "PASS" if equal == pixels else "FAIL")
    return equal == pixels


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("actual", nargs="?", type=Path, default=ROOT / "results/PIC1_filtered.bmp")
    parser.add_argument("reference", nargs="?", type=Path, default=ROOT / "images/Designer1.jpg")
    args = parser.parse_args()
    try:
        sys.exit(0 if compare(args.actual, args.reference) else 1)
    except OSError as error:
        print(f"Cannot compare the images: {error}", file=sys.stderr)
        sys.exit(2)
