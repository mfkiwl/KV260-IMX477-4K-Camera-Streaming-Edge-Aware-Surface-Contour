"""Independent raster-order check of the RTL BMP against its decoded JPEG stimulus.
Usage: python tools/check_pixels.py decoded.bmp filtered.bmp [--jpeg original.jpg] [--designer1]
The checker never writes filtered images. Requires NumPy and Pillow.
"""
import argparse

import numpy as np
from PIL import Image


def luma(rgb):
    return (5 * rgb[..., 0] + 9 * rgb[..., 1] + 2 * rgb[..., 2] + 8) // 16


def frame_profile(decoded, requested):
    if requested != "auto":
        return requested
    band = decoded[:8].astype(np.int32)
    green_minus_blue = band[..., 1] - band[..., 2]
    if luma(band).mean() <= 80 and green_minus_blue.mean() >= 4 and np.ptp(band, axis=2).mean() <= 32:
        return "designer1"
    return "source"


def surface(frame, step, tolerance):
    h, w, _ = frame.shape
    padded = np.pad(frame, ((2 * step, 2 * step), (2 * step, 2 * step), (0, 0)), mode="edge")
    luminance = luma(padded)
    output = np.empty_like(frame)
    # Process stripes so memory consumption does not scale with 25 full images.
    for top in range(0, h, 96):
        bottom = min(h, top + 96)
        center = frame[top:bottom]
        colors, scores = [], []
        for row, col in ((0, 0), (0, 2), (2, 0), (2, 2)):
            total = np.zeros_like(center)
            lo = np.full(center.shape[:2], 255, dtype=frame.dtype)
            hi = np.zeros_like(lo)
            for y in range(row, row + 3):
                for x in range(col, col + 3):
                    ys = slice(top + y * step, bottom + y * step)
                    xs = slice(x * step, w + x * step)
                    total += padded[ys, xs]
                    np.minimum(lo, luminance[ys, xs], out=lo)
                    np.maximum(hi, luminance[ys, xs], out=hi)
            color = (total + 4) // 9
            colors.append(color)
            scores.append(2 * (hi - lo) + 3 * np.abs(color - center).max(axis=-1))
        colors = np.stack(colors, axis=2)
        scores = np.stack(scores, axis=2)
        best = scores.argmin(axis=2)
        best_color = np.take_along_axis(colors, best[..., None, None], axis=2)[:, :, 0, :]
        keep = scores <= scores.min(axis=2, keepdims=True) + tolerance
        mean = (np.where(keep[..., None], colors, best_color[:, :, None, :]).sum(axis=2) + 2) // 4
        outlier = np.abs(mean - center).max(axis=-1) > 24
        output[top:bottom] = np.where(outlier[..., None], (mean + center + 1) // 2,
                                      (7 * mean + center + 4) // 8)
    return output


def render(frame, step, chroma_q8):
    colors = frame.astype(np.int32)
    y = luma(colors)
    h, w = y.shape
    pad = np.pad(y, 2 * step, mode="edge")

    def at(dy, dx):
        start_y = (2 + dy) * step
        start_x = (2 + dx) * step
        return pad[start_y:start_y + h, start_x:start_x + w]

    gx = at(-1, 1) + 2 * at(0, 1) + at(1, 1) - at(-1, -1) - 2 * at(0, -1) - at(1, -1)
    gy = at(1, -1) + 2 * at(1, 0) + at(1, 1) - at(-1, -1) - 2 * at(-1, 0) - at(-1, 1)
    surround = sum(at(dy, dx) for dy, dx in ((-1, 0), (0, -1), (0, 1), (1, 0),
                                               (-2, 0), (0, -2), (0, 2), (2, 0)))
    dark = (surround + 4) // 8 - y
    grad = (np.abs(gx) + np.abs(gy)) // 4
    ink = np.where(dark > 1, np.minimum(12, np.maximum(0, grad - 5) // 4 + dark // 4), 0)
    pairs = [(at(0, -2), at(0, 2)), (at(-2, 0), at(2, 0)),
             (at(-2, -2), at(2, 2)), (at(-2, 2), at(2, -2))]
    dark_ridge = np.maximum.reduce([np.minimum(a, b) for a, b in pairs]) - y
    light_ridge = y - np.minimum.reduce([np.maximum(a, b) for a, b in pairs])
    ink = np.maximum(ink, np.minimum(42, 3 * np.maximum(0, dark_ridge - 2) // 2))
    highlight = np.minimum(14, 3 * np.maximum(0, light_ridge - 3) // 4)
    anchors = np.array([0, 56, 81, 104, 122, 137, 149, 158, 168, 180, 191, 201,
                        212, 223, 234, 245, 256], dtype=np.int32)
    lo = y // 16
    continuous = np.minimum(255, anchors[lo] + ((y % 16) * (anchors[lo + 1] - anchors[lo]) + 8) // 16)
    snapped = np.minimum(255, 8 * ((continuous + 4) // 8))
    target = np.clip((3 * continuous + snapped + 2) // 4 - ink + highlight, 0, 255)
    minimum = colors.min(axis=-1)
    span = colors.max(axis=-1) - minimum
    gain = 256 + np.minimum(chroma_q8 - 256, 255 - span)
    relative = ((colors - minimum[..., None]) * gain[..., None] + 128) // 256
    offset = np.clip(target - luma(relative), 0, 255 - relative.max(axis=-1))
    return (relative + offset[..., None]).astype(np.uint8)


def finish(frame):
    h, w, _ = frame.shape
    padded = np.pad(frame.astype(np.int16), ((2, 2), (2, 2), (0, 0)), mode="edge")
    weights = (1, 4, 6, 4, 1)
    output = np.empty_like(frame)
    for top in range(0, h, 96):
        bottom = min(top + 96, h)
        center = padded[top + 2:bottom + 2, 2:w + 2]
        total = np.zeros(center.shape, dtype=np.int32)
        for y, wy in enumerate(weights):
            for x, wx in enumerate(weights):
                sample = padded[top + y:bottom + y, x:x + w]
                strong = np.abs(sample - center).max(axis=-1) > 28
                accepted = np.where(strong[..., None], (sample + center + 1) // 2, sample)
                total += wy * wx * accepted
        output[top:bottom] = (total + 128) // 256
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("decoded", help="BMP written by the VHDL JPEG reader")
    parser.add_argument("actual", help="BMP written by the VHDL AXI sink")
    parser.add_argument("--jpeg", help="cross-check the testbench JPEG decoder against Pillow")
    parser.add_argument("--designer1", action="store_true",
                        help="include the Designer1 grade and contour finish at native pixel coordinates")
    parser.add_argument("--color-profile", choices=("auto", "source", "designer1"), default="auto")
    parser.add_argument("--medium", type=int, default=3)
    parser.add_argument("--coarse", type=int, default=6)
    parser.add_argument("--contour", type=int, default=6)
    parser.add_argument("--chroma-q8", type=int, default=384)
    args = parser.parse_args()
    pixels = np.asarray(Image.open(args.decoded).convert("RGB"), dtype=np.int16)
    profile = frame_profile(pixels, args.color_profile) if args.designer1 else None
    source_rgb = pixels if profile == "source" else None
    with Image.open(args.actual) as im:
        if im.size != (pixels.shape[1], pixels.shape[0]):
            raise SystemExit(f"Geometry FAIL: decoded {pixels.shape[1]} x {pixels.shape[0]}, "
                             f"captured {im.width} x {im.height}")
        actual = np.asarray(im.convert("RGB"))
    if args.jpeg:
        decoded = np.asarray(Image.open(args.jpeg).convert("RGB"), dtype=np.int16)
        if decoded.shape != pixels.shape:
            raise SystemExit(f"Input JPEG shape {decoded.shape} differs from decoder dump {pixels.shape}")
        err = np.abs(pixels - decoded)
        print(f"JPEG decoder vs Pillow/libjpeg: mean |channel error|={err.mean():.5f}, max={err.max()} / 255")
        # Our floating-point IDCT and centered interpolation differ slightly from libjpeg's integer rounding.
        if err.max() > 4 or err.mean() > 0.3:
            raise SystemExit("JPEG decode cross-check outside tolerance")
    for step, tol in ((1, 20), (args.medium, 14), (args.coarse, 10)):
        pixels = surface(pixels, step, tol)
    expected = finish(render(pixels, args.contour, args.chroma_q8))
    if args.designer1:
        from check_designer1_datapath import grade, finish as contour_finish
        print(f"Frame color profile from decoded pixels: {profile}")
        if profile == "designer1":
            for start in range(0, expected.shape[0], 96):
                rows = slice(start, start + 96)
                expected[rows] = grade(expected[rows])
        expected = contour_finish(expected)
        if source_rgb is not None:
            # A common RGB offset preserves both signed channel differences.
            # This form checks the RTL's green-channel reconstruction independently.
            dy = luma(expected.astype(np.int16)) - luma(source_rgb)
            dy = np.clip(dy, -source_rgb.min(axis=2), 255-source_rgb.max(axis=2))
            expected = (source_rgb + dy[..., None]).astype(np.uint8)
            offsets = actual.astype(np.int16) - source_rgb
            errors = int(np.any(offsets != offsets[..., :1], axis=2).sum())
            print(f"Source chroma: {errors:,} pixels with altered channel differences")
            if errors:
                raise SystemExit("Source chroma check failed")
    print(f"Native raster geometry: {actual.shape[1]} x {actual.shape[0]}, x scale 1, y scale 1")
    diff = (actual != expected).any(axis=-1)
    count = int(diff.sum())
    print(f"Independent raster model: {count:,} mismatched pixels / {diff.size:,}")
    if count:
        y, x = np.argwhere(diff)[0]
        raise SystemExit(f"First mismatch at ({x},{y}): RTL={actual[y,x]}, expected={expected[y,x]}")
    print("PASS: every RGB byte matched.")


if __name__ == "__main__":
    main()
