"""Check the complete framing, continuous grade and contour finish from the native RTL stream."""
import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def frame_coordinates(n, knee, first, middle, last):
    pos = np.arange(n, dtype=np.int32)
    tail = n - 1 - knee
    return np.where(pos <= knee,
                    first + (pos * (middle - first) + knee // 2) // knee,
                    middle + ((pos - knee) * (last - middle) + tail // 2) // tail)


def luminance(rgb):
    r, g, b = rgb.transpose(2, 0, 1).astype(np.int32)
    return (5 * r + 9 * g + 2 * b + 8) // 16


def grade(rgb):
    levels = np.array([0,32,48,64,80,96,112,128,144,160,176,192,224,256])
    anchors_q2 = np.array([0,153,195,283,348,429,464,577,671,696,703,735,858,986])
    matrix_q6 = np.array([
        [88,-95,-246,-104,76,231,133,-141,105,50,-116,196,14,-41,-146],
        [153,-104,-173,-81,97,141,-124,-191,41,62,-63,149,86,-74,-84],
        [120,-89,-24,-32,66,-94,22,-222,-50,153,10,19,-45,-139,160]
    ], dtype=np.int32)
    p = rgb.astype(np.int32)
    y = luminance(p)
    r, g, b = p.transpose(2, 0, 1)
    u = np.clip(r - g, -48, 48)
    v = np.clip(g - b, -64, 64)
    uc = np.clip(u, -14, 24)
    vc = np.clip(v, 0, 40)
    shadows = np.clip(128 - y, 0, 64)
    highlights = np.clip(y - 112, 0, 64)
    mid = np.clip(y - 48, 0, 48) - np.clip(y - 96, 0, 48)

    def q5(a, b):
        return (a * b + 16) // 32

    terms = np.stack((np.full_like(y,32), shadows, highlights, mid, u, v, uc, vc,
                      q5(shadows,uc), q5(shadows,vc), q5(highlights,uc),
                      q5(highlights,vc), q5(uc,v), q5(uc,u), q5(vc,v)), axis=-1)
    tone_q6 = np.floor(np.interp(np.arange(256), levels, 16 * anchors_q2) + 0.5).astype(np.int32)
    correction = terms @ matrix_q6.T + 64 * (p - y[...,None])
    rendered = np.clip((tone_q6[y,None] + correction + 32) // 64, 0, 255)
    span = np.max(p, axis=2) - np.min(p, axis=2)
    mix = np.clip(np.minimum.reduce([y - 16, 240 - y, 128 - span]), 0, 32)[...,None]
    return ((mix * rendered + (32 - mix) * p + 16) // 32).astype(np.uint8)


def finish(graded):
    center = graded.astype(np.int16)
    y = luminance(center).astype(np.int16)
    h, w = y.shape
    pitch = 3
    pad = 2 * pitch
    pixels = np.pad(center, ((pad,pad),(pad,pad),(0,0)), mode="edge")
    lumas = np.pad(y, pad, mode="edge")

    def tap(a, dy, dx):
        row, col = pad + pitch * dy, pad + pitch * dx
        return a[row:row+h, col:col+w]

    accumulated = np.zeros_like(center)
    best = np.full_like(y, -1)
    curvature = np.zeros_like(y)
    down_limit = np.zeros_like(y)
    up_limit = np.zeros_like(y)
    ridge = np.zeros_like(y)
    for dy, dx in [(0,1),(1,0),(1,1),(1,-1)]:
        for sign in (-1, 1):
            delta = tap(pixels, sign * dy, sign * dx) - center
            distance = np.max(np.abs(delta), axis=2)
            weight = np.where(distance <= 18, 2, distance <= 36).astype(np.int16)
            accumulated += weight[...,None] * delta
        a, b = tap(lumas, 2 * dy, 2 * dx), tap(lumas, -2 * dy, -2 * dx)
        lo, hi = np.minimum(a,b), np.maximum(a,b)
        stronger = hi - lo > best
        curvature = np.where(stronger, y - (lo + hi) // 2, curvature)
        down_limit = np.where(stronger, np.maximum(y - lo, 0), down_limit)
        up_limit = np.where(stronger, np.maximum(hi - y, 0), up_limit)
        best = np.maximum(best, hi - lo)
        ridge = np.maximum(ridge, lo - y)

    surface = center + (accumulated + 8) // 16
    darker = np.minimum(2 * np.maximum(-curvature - 3, 0), np.minimum(down_limit, 24))
    lighter = np.minimum(3 * np.maximum(curvature - 3, 0) // 2, np.minimum(up_limit, 16))
    shift = lighter - np.maximum(darker, np.clip(ridge - 8, 0, 16))
    return np.clip(surface + shift[...,None], 0, 255).astype(np.uint8)


def check(native, captured):
    with Image.open(native) as src, Image.open(captured) as dst:
        if src.size != (2048,1152) or dst.size != (2048,1365):
            raise ValueError(f"Unexpected sizes {src.size} -> {dst.size}")
        source = np.asarray(src.convert("RGB"))
        actual = np.asarray(dst.convert("RGB"))
    x = frame_coordinates(2048,700,70,736,1946)
    y = frame_coordinates(1365,1245,0,1110,1151)
    # Chunk only the pointwise grade. The contour window crosses chunk boundaries.
    expected = np.concatenate([grade(source[rows[:,None],x]) for rows in np.array_split(y,16)])
    expected = finish(expected)
    mismatch = np.any(expected != actual, axis=-1)
    n = int(mismatch.sum())
    print(f"Designer1 arithmetic model versus AXI capture: {n:,} differing RGB pixels / {mismatch.size:,}")
    if n:
        row, col = np.argwhere(mismatch)[0]
        print(f"First mismatch at ({col}, {row}): model {expected[row,col]}, RTL {actual[row,col]}")
    return n == 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("native", type=Path, nargs="?", default=ROOT / "results/PIC1_native.bmp")
    parser.add_argument("actual", type=Path, nargs="?", default=ROOT / "results/PIC1_filtered.bmp")
    args = parser.parse_args()
    sys.exit(0 if check(args.native, args.actual) else 1)
