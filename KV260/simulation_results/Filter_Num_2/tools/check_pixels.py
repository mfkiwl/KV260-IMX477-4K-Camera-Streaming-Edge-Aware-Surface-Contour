"""Independent raster-order check of the RTL BMP against its decoded JPEG stimulus.
Usage: python tools/check_pixels.py decoded.bmp filtered.bmp [--jpeg original.jpg]
The checker never writes filtered images. Requires NumPy and Pillow.
"""
import argparse
from pathlib import Path
import re

import numpy as np
from PIL import Image


def luma(rgb):
    return (5 * rgb[..., 0] + 9 * rgb[..., 1] + 2 * rgb[..., 2] + 8) // 16


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


def coefficients():
    """Use the design constants. Compute every spatial and arithmetic operation independently."""
    path = Path(__file__).resolve().parents[1] / 'rtl/pic2_grade_coeffs.vhd'
    defs = path.read_text()
    arrays = []
    for name, shape in [('INPUT_WEIGHTS', (27, 12)), ('INPUT_BIAS', (27,)), ('OUTPUT_WEIGHTS', (3, 24))]:
        expr = re.search(r'constant\s+' + name + r'\s*:[^;]+?:=\s*(.*?);', defs, re.S | re.I)
        values = [int(x) for x in re.findall(r'-?\d+', expr.group(1))]
        arrays.append(np.array(values, dtype=np.int32).reshape(shape))
    return arrays


def full_coefficients():
    text = (Path(__file__).resolve().parents[1] / 'rtl/full_grade_coeffs.vhd').read_text()

    def definition(name):
        match = re.search(r'constant\s+' + name + r'\s*:[^;]+?:=\s*(.*?);', text, re.S | re.I)
        return [int(value) for value in re.findall(r'-?\d+', match.group(1))]

    first, second = definition('FIRST_COUNT')[0], definition('SECOND_COUNT')[0]
    arrays = {}
    for name, rows, cols in (('FIRST', first, 12), ('SECOND', second, first),
                             ('RGB', 3, second), ('DIRECT', 3, 12)):
        arrays[name] = (np.array(definition('W_' + name), dtype=np.int32).reshape(rows, cols),
                        np.array(definition('B_' + name), dtype=np.int32))
    return arrays, definition('FRAC_BITS')[0], definition('HIDDEN_LIMIT')[0]


def full_grade(features, center, coefficients):
    matrices, bits, limit = coefficients
    scale = 1 << bits

    def linear(values, name):
        weights, bias = matrices[name]
        return values @ weights.T + bias

    def rectified(values, name):
        return np.clip((linear(values, name) + scale // 2) // scale, 0, limit)

    first = rectified(features, 'FIRST')
    second = rectified(first, 'SECOND')
    total = center.astype(np.int32) * scale + linear(features, 'DIRECT') + linear(second, 'RGB')
    return np.clip((total + scale // 2) // scale, 0, 255)


def render(frame, wide_step, fine_step, chroma_q8, legacy_pic2=False):
    height, width, _ = frame.shape
    radius = 2 * max(wide_step, fine_step)
    padded = np.pad(frame, ((radius, radius), (radius, radius), (0, 0)), mode='edge')
    luminance = luma(padded)
    if legacy_pic2:
        weights, bias, output_weights = coefficients()
    else:
        full = full_coefficients()
    spatial_weights = (1, 2, 2, 2, 1)
    sat = (chroma_q8 * 256 + 192) // 384
    out = np.empty_like(frame, dtype=np.uint8)
    for first in range(0, height, 48):
        last = min(first + 48, height)
        center = frame[first:last]
        y = luma(center)
        u = center[..., 0] - center[..., 1]
        v = center[..., 1] - center[..., 2]

        def tap(dy, dx, spacing):
            top, left = radius + dy * spacing, radius + dx * spacing
            return slice(first + top, last + top), slice(left, left + width)

        color_sum = np.zeros_like(center)
        spread_sum = np.zeros_like(y)
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                index = tap(dy, dx, wide_step)
                weight = spatial_weights[dy + 2] * spatial_weights[dx + 2]
                color_sum += weight * padded[index]
                spread_sum += weight * np.abs(luminance[index] - y)
        broad = (color_sum + 32) // 64
        spread = (spread_sum + 32) // 64
        taps = [luminance[tap(dy, dx, fine_step)] for dy in range(-2, 3) for dx in range(-2, 3)]
        inner = (sum(taps[n] for n in (6, 7, 8, 11, 13, 16, 17, 18)) + 4) // 8
        outer = (sum(taps[n] for n in (0, 2, 4, 10, 14, 20, 22, 24)) + 4) // 8
        pairs = [(taps[a], taps[b]) for a, b in ((0, 24), (2, 22), (4, 20), (10, 14))]
        dark_ridge = np.maximum.reduce([np.minimum(a, b) for a, b in pairs]) - y
        light_ridge = y - np.minimum.reduce([np.maximum(a, b) for a, b in pairs])
        fine_span = np.maximum.reduce(taps) - np.minimum.reduce(taps)
        features = np.stack((y, u, v, y - luma(broad), spread,
                             u - (broad[..., 0] - broad[..., 1]), v - (broad[..., 1] - broad[..., 2]),
                             y - inner, dark_ridge, light_ridge, fine_span, outer - y), axis=-1).astype(np.int32)
        if legacy_pic2:
            affine = features @ weights.T + bias
            hidden = np.clip((affine[..., :24] + 128) // 256, 0, 2047)
            correction = (hidden @ output_weights.T + affine[..., 24:] + 128) // 256
            graded = np.clip(center + correction, 0, 255)
            strength = np.clip(np.minimum(224 - y, 96 - np.maximum(np.abs(u), np.abs(v))), 0, 32)[..., None]
            blended = ((32 - strength) * center + strength * graded + 16) // 32
        else:
            blended = full_grade(features, center, full)
        out[first:last] = (sat * blended + (256 - sat) * luma(blended)[..., None] + 128) // 256
    return out


def finish(frame, step=2, threshold=28):
    height, width, _ = frame.shape
    border = 2 * step
    padded = np.pad(frame.astype(np.int16), ((border, border), (border, border), (0, 0)), mode='edge')
    out = np.empty_like(frame)
    for first in range(0, height, 64):
        last = min(first + 64, height)
        center = padded[first + border:last + border, border:width + border]
        means, costs = [], []
        for dy, dx in ((0, 1), (1, 0), (1, 1), (-1, 1)):
            samples, dist = [], []
            for offset in (-2, -1, 1, 2):
                top, left = border + offset * step * dy, border + offset * step * dx
                sample = padded[first + top:last + top, left:left + width]
                distance = np.max(np.abs(sample - center), axis=-1)
                samples.append(np.where((distance > threshold)[..., None], (sample + center + 1) // 2, sample))
                dist.append(distance)
            means.append((samples[0] + samples[3] + 4 * (samples[1] + samples[2]) + 6 * center + 8) // 16)
            costs.append(dist[1] + dist[2] + (dist[0] + dist[3]) // 2)
        costs = np.stack(costs, axis=2)
        means = np.stack(means, axis=2)
        best = np.argmin(costs, axis=2)
        best_mean = np.take_along_axis(means, best[..., None, None], axis=2)
        keep = costs <= costs.min(axis=2, keepdims=True) + 4
        out[first:last] = (np.where(keep[..., None], means, best_mean).sum(axis=2) + 2) // 4
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('decoded', help='BMP written by the VHDL JPEG decoder')
    parser.add_argument('actual', help='BMP captured at the DUT output')
    parser.add_argument('--jpeg', help='also compare the JPEG decoder to Pillow/libjpeg')
    parser.add_argument('--medium', type=int, default=3)
    parser.add_argument('--coarse', type=int, default=16)
    parser.add_argument('--contour', type=int, default=4)
    parser.add_argument('--chroma-q8', type=int, default=384)
    parser.add_argument('--legacy-pic2', action='store_true', help='check the original PIC2 portrait profile')
    args = parser.parse_args()
    pixels = np.asarray(Image.open(args.decoded).convert('RGB'), dtype=np.int16)
    if args.jpeg:
        libjpeg = np.asarray(Image.open(args.jpeg).convert('RGB'), dtype=np.int16)
        err = np.abs(pixels - libjpeg)
        print(f'JPEG decoder vs Pillow/libjpeg: mean absolute channel difference {err.mean():.5f}, max {err.max()}.')
        if err.max() > 4 or err.mean() > 0.3:
            raise SystemExit('JPEG decode cross-check outside tolerance')
    surface_pixels = surface(surface(pixels, 1, 20), args.medium, 14)
    expected = finish(render(surface_pixels, args.coarse, args.contour, args.chroma_q8, args.legacy_pic2))
    actual = np.asarray(Image.open(args.actual).convert('RGB'))
    if expected.shape != actual.shape:
        raise SystemExit(f'Size mismatch: {expected.shape} versus {actual.shape}')
    diff = np.any(expected != actual, axis=-1)
    print(f'Independent raster model: {diff.sum():,} mismatched pixels / {diff.size:,}.')
    if diff.any():
        y, x = np.argwhere(diff)[0]
        raise SystemExit(f'First mismatch at ({x},{y}): RTL={actual[y,x]}, expected={expected[y,x]}')
    print('PASS: every RGB byte matched.')


if __name__ == '__main__':
    main()
