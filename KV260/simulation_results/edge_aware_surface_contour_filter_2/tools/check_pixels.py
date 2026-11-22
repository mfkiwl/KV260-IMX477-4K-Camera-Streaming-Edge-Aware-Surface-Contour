"""Compare every captured RTL pixel to an independent spatial integer model.
Usage: python tools/check_pixels.py decoded.bmp filtered.bmp [--jpeg original.jpg]
Requires NumPy and Pillow. All coordinates including image borders are checked.
"""
import argparse
import numpy as np
from PIL import Image

# Direction order: horizontal, rising diagonal (/), vertical, falling diagonal (\).
TANGENT = ((0, 1), (1, -1), (1, 0), (1, 1))
NORMAL = ((1, 0), (1, 1), (0, 1), (1, -1))
K3 = (1, 2, 1)


def luma(rgb):
    return (77 * rgb[..., 0] + 150 * rgb[..., 1] + 29 * rgb[..., 2] + 128) // 256


def stripes(frame, step):
    height, width = frame.shape[:2]
    radius = 2 * step
    padding = [(radius, radius), (radius, radius)] + [(0, 0)] * (frame.ndim - 2)
    padded = np.pad(frame, padding, mode='edge')
    for start in range(0, height, 64):
        end = min(start + 64, height)

        def at(dy, dx):
            y, x = radius + dy * step, radius + dx * step
            return padded[y + start:y + end, x:x + width]

        yield slice(start, end), at


def surface(frame, step, sigma, center_cap):
    # Each of the four quadrants includes the center. Explicit 2-D reductions
    # are independent of the RTL's strip decomposition and clock scheduling.
    x = np.arange(64, dtype=np.int64)
    denom = (sigma ** 2 + x ** 2) ** 2
    decay = np.maximum(1, (255 * sigma ** 4 + denom // 2) // denom).astype(np.int32)
    out = np.empty_like(frame)
    for rows, at in stripes(frame, step):
        center = frame[rows]
        scalar_shape = center.shape[:2]
        weighted = np.zeros_like(center)
        weights = np.zeros(scalar_shape, np.int32)
        best = np.full(scalar_shape, 382, dtype=np.int32)
        for ry, rx in ((-2, -2), (-2, 0), (0, -2), (0, 0)):
            samples = [at(ry+i, rx+j) for i in range(3) for j in range(3)]
            means = (sum(K3[i] * K3[j] * samples[3*i+j] for i in range(3) for j in range(3)) + 8) // 16
            ys = [luma(p) for p in samples]
            chroma_span = (np.maximum.reduce(samples) - np.minimum.reduce(samples)).max(axis=-1)
            score = np.maximum.reduce(ys) - np.minimum.reduce(ys) + chroma_span // 2
            w = decay[np.minimum(63, score // 2)]
            weighted += w[..., None] * means
            weights += w
            best = np.minimum(best, score)
        inv = (262144 + weights // 2) // weights
        smooth = np.minimum(255, (weighted.astype(np.int64) * inv[..., None] + 131072) // 262144)
        retain = np.clip((best - 24) // 2, 0, center_cap)
        if step == 1:
            yc = luma(center)
            ridge_score = np.zeros_like(yc)
            for (ty, tx), (ny, nx) in zip(TANGENT, NORMAL):
                along = np.minimum(np.abs(luma(at(ty, tx))-yc), np.abs(luma(at(-ty, -tx))-yc))
                for offset in (1, 2):
                    a, b = luma(at(offset*ny, offset*nx)), luma(at(-offset*ny, -offset*nx))
                    contrast = np.maximum(np.minimum(a, b)-yc, yc-np.maximum(a, b))
                    ridge_score = np.maximum(ridge_score, contrast-along)
            line_keep = np.clip(8*(ridge_score-8), 0, 248)
        else:
            # At wider spacings a continuous narrow line can fall between the
            # axial/diagonal taps. Preserve its center if every sector crosses an edge.
            line_keep = np.clip(5*(best-28), 0, 248)
        retain = np.maximum(retain, line_keep)[..., None]
        out[rows] = ((256-retain)*smooth + retain*center + 128) // 256
    return out


def scharr(at, dy=0, dx=0):
    gx = 3*(at(dy-1, dx+1)-at(dy-1, dx-1)) + 10*(at(dy, dx+1)-at(dy, dx-1)) + 3*(at(dy+1, dx+1)-at(dy+1, dx-1))
    gy = 3*(at(dy+1, dx-1)-at(dy-1, dx-1)) + 10*(at(dy+1, dx)-at(dy-1, dx)) + 3*(at(dy+1, dx+1)-at(dy-1, dx+1))
    return gx, gy


def geometry(gx, gy):
    ax, ay = np.abs(gx), np.abs(gy)
    mag = (np.maximum(ax, ay) + 3 * np.minimum(ax, ay) // 8) // 8
    direction = np.select([ax*77 < ay*32, ay*77 < ax*32, (gx < 0) == (gy < 0)], [0, 2, 1], default=3)
    return mag, direction


def ramp(value, low, high):
    return np.clip((value-low)*255 // (high-low), 0, 255)


def render(frame, step, chroma_q8):
    all_y = luma(frame)
    out = np.empty_like(frame)
    for rows, at in stripes(all_y, step):
        y = all_y[rows]
        center_mag, direction = geometry(*scharr(at))
        patch = {(dy, dx): geometry(*scharr(at, dy, dx))[0] for dy in (-1, 0, 1) for dx in (-1, 0, 1)}
        linked, flanks, valleys = [], [], []
        for (ty, tx), (ny, nx) in zip(TANGENT, NORMAL):
            linked.append((patch[-ty, -tx] + 2*center_mag + patch[ty, tx] + 2) // 4)
            flanks.append(np.maximum(patch[-ny, -nx], patch[ny, nx]))
            valleys.append(np.maximum(0, (at(-ny, -nx) + at(ny, nx)) // 2 - y))
        flow = np.choose(direction, linked)
        flank = np.choose(direction, flanks)
        soft_nms = np.maximum(0, flow - 2*np.maximum(0, flank-center_mag))
        edge = np.maximum(soft_nms, 2*np.choose(direction, valleys))
        scale = 256 - ramp(edge, 22, 68)*204//256
        yc = y + 14*(255-y)**2//65025
        delta = (frame[rows] - y[..., None])*chroma_q8
        chroma = np.sign(delta) * (np.abs(delta)//256)  # VHDL signed integer division
        tone_rgb = np.clip(yc[..., None] + chroma, 0, 255)
        out[rows] = (tone_rgb*scale[..., None] + 128)//256
    return out


def finish(frame):
    out = np.empty_like(frame)
    for rows, at in stripes(frame, 1):
        center = frame[rows]
        mag, direction = geometry(*scharr(lambda dy, dx: luma(at(dy, dx))))
        def accepted(dy, dx, limit):
            sample = at(dy, dx)
            keep = np.abs(sample-center).max(axis=-1) <= limit
            return np.where(keep[..., None], sample, center)
        tangent = np.zeros_like(center)
        for d, (dy, dx) in enumerate(TANGENT):
            total = sum(k * accepted(i*dy, i*dx, 36) for i, k in zip(range(-2, 3), (1, 4, 6, 4, 1)))
            tangent = np.where((direction == d)[..., None], (total+8)//16, tangent)
        total = sum(wy*wx*accepted(dy, dx, 18) for dy, wy in zip(range(-1, 2), K3)
                                                  for dx, wx in zip(range(-1, 2), K3))
        flat = (total + 8)//16
        blend = ramp(mag, 16, 48)[..., None]
        out[rows] = ((255-blend)*flat + blend*tangent + 128)//255
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('decoded', help='BMP written by the VHDL JPEG reader')
    parser.add_argument('actual', help='BMP written by the AXI sink')
    parser.add_argument('--jpeg', help='also compare the VHDL decoder with libjpeg')
    parser.add_argument('--medium', type=int, default=2)
    parser.add_argument('--coarse', type=int, default=4)
    parser.add_argument('--contour', type=int, default=1)
    parser.add_argument('--chroma-q8', type=int, default=288)
    args = parser.parse_args()
    frame = np.asarray(Image.open(args.decoded).convert('RGB'), dtype=np.int32)
    if args.jpeg:
        decoded = np.asarray(Image.open(args.jpeg).convert('RGB'), dtype=np.int32)
        err = np.abs(frame-decoded)
        print(f'JPEG decoder vs libjpeg: mean absolute RGB channel error {err.mean():.5f}, max {err.max()} / 255')
        if err.max() > 4 or err.mean() > 0.3:
            raise SystemExit('JPEG decode outside tolerance')
    for step, sigma, cap in ((1, 14, 16), (args.medium, 12, 24), (args.coarse, 10, 40)):
        frame = surface(frame, step, sigma, cap)
    expected = finish(render(frame, args.contour, args.chroma_q8))
    actual = np.asarray(Image.open(args.actual).convert('RGB'))
    if actual.shape != expected.shape:
        raise SystemExit(f'Size mismatch: {actual.shape} vs {expected.shape}')
    bad = (actual != expected).any(axis=-1)
    print(f'Independent raster model: {bad.sum():,} mismatched pixels / {bad.size:,}')
    if bad.any():
        y, x = np.argwhere(bad)[0]
        raise SystemExit(f'First mismatch at ({x},{y}): RTL={actual[y,x]}, expected={expected[y,x]}')
    print('PASS: every RGB byte matched.')


if __name__ == '__main__':
    main()
