"""Check the final RTL capture at every (x,y) with an independent array model.
Start at the decoded JPEG (--decoded) or at the native camera-filter output (--native).
"""
import argparse
import filecmp
from pathlib import Path

import numpy as np
from PIL import Image

from check_pixels import camera_filter, luma, surface


ROOT = Path(__file__).resolve().parents[1]
ANCHOR = np.array([-39, -27, -16, -3, 12, 33, 52, 86, 120, 152, 167, 177, 189, 202, 215, 229, 242], dtype=np.int32)
WEIGHT = np.array([
    [-19, -42, -35, 130, 149, 68, 58, 43, -52, -34, 36, 73, 40, -71, 70, 75, 38, -9, -38, 42, -40],
    [-166, -101, -48, 153, 39, 67, 63, 58, -65, -32, 75, 72, 46, -78, 57, 80, 16, -10, -41, 35, -33],
    [787, -110, -146, 122, -7, 99, 19, -9, -43, -18, 69, 56, 38, -68, 62, 64, 4, -11, -18, 18, -18]
], dtype=np.int32)
ARTWORK_X = ((0,208,645,1637,1885,2047), (0,119,623,1679,1906,2047))
ARTWORK_Y = ((0,437,943,1052,1142), (4,464,1004,1102,1151))


def coordinates(output_knots, input_knots):
    indices = np.arange(output_knots[-1]+1)
    segment = np.searchsorted(output_knots[1:], indices, side="left")
    out, src = np.asarray(output_knots), np.asarray(input_knots)
    width = out[segment+1] - out[segment]
    return src[segment] + ((indices-out[segment])*(src[segment+1]-src[segment]) + width//2)//width


def condition_input(pixels):
    """Meter a spatial grid across the whole source and apply the frame's RGB gains."""
    grid = pixels[::8, ::8].reshape(-1, 3)
    means = (grid.sum(axis=0, dtype=np.int64) + len(grid)//2)//len(grid)
    level = int(luma(means))
    denominator = 33 + max(0, level-70)
    base = max(64, (256*33 + denominator//2)//denominator)
    warm = min(max(0, 12-int(means[0])+int(means[2])), 24, (256-base+4)//8)
    gains = np.array([min(256, base+(2*warm+1)//3), base, base-warm], dtype=np.int32)
    lift = (256-base+5)//10
    source = pixels.astype(np.int32)
    toe = np.maximum(0, lift - (luma(source)+4)//8)
    print(f"Meter RGB {means.tolist()}, Q8 gains {gains.tolist()}, shadow lift {lift}")
    return np.minimum(255, (source*gains+128)//256 + toe[..., None]).astype(np.int16)


def ring(frame, spacing):
    r, g, b = np.moveaxis(frame.astype(np.int16), -1, 0)
    y = (5*r + 9*g + 2*b + 8)//16
    h, w = y.shape
    pad = np.pad(y, 2*spacing, mode="edge")
    offsets = [(-2,0),(2,0),(0,-2),(0,2),(-1,-1),(1,1),(-1,1),(1,-1)]
    taps = []
    for dy, dx in offsets:
        top, left = (dy+2)*spacing, (dx+2)*spacing
        taps.append(pad[top:top+h,left:left+w])
    return y, taps


def grade(frame):
    y, taps = ring(frame, 8)
    detail = y - (sum(taps)+4)//8
    span = np.maximum.reduce(taps) - np.minimum.reduce(taps)
    pairs = list(zip(taps[::2], taps[1::2]))
    black = np.maximum(0, np.maximum.reduce([np.minimum(a,b) for a,b in pairs])-y)
    white = np.maximum(0, y-np.minimum.reduce([np.maximum(a,b) for a,b in pairs]))
    out = np.empty_like(frame)
    def ramp(x, low, high):
        return np.clip(x-low, 0, high-low)
    for top in range(0, len(frame), 64):
        rows = slice(top,top+64)
        r, g, b = np.moveaxis(frame[rows].astype(np.int32), -1, 0)
        level = y[rows].astype(np.int32)
        u, v = r-g, g-b
        dc, spread = detail[rows], span[rows]
        terms = np.stack((
            np.ones_like(u), u, v, ramp(u,-8,4), ramp(u,4,16), ramp(v,28,48),
            ramp(level-2*v,68,84), ramp(level-2*v,84,104), ramp(level+2*u,72,92),
            ramp(level+2*u,120,152), ramp(v-u,4,16), ramp(level+2*v,68,96),
            ramp(level+2*v,96,128), ramp(level-2*u,72,96), ramp(2*v+u,10,22),
            ramp(u+v,28,48), ramp(level+4*u-2*v,80,100), ramp(dc,-32,0),
            ramp(dc,0,32), ramp(spread,0,24), ramp(spread+u,16,40)), axis=-1)
        k, frac = np.divmod(level, 16)
        base = ((16-frac)*ANCHOR[k]+frac*ANCHOR[k+1]+8)//16
        rgb = np.clip(base[...,None] + (terms @ WEIGHT.T + 32)//64, 0, 255)
        target_y = (5*rgb[...,0]+9*rgb[...,1]+2*rgb[...,2]+8)//16
        neutral = np.minimum.reduce([16-2*abs(u)-abs(v-6), 28-abs(target_y-61), 20-spread])
        shift = ((61-target_y)*np.clip(neutral,0,16)+8)//16
        shift -= np.clip((3*np.maximum(black[rows]-4,0)+1)//2,0,36)
        shift += np.minimum(np.maximum(white[rows]-3,0),np.clip(85-target_y,0,12))
        toned = target_y+shift
        residual = ((toned+8)//16)*16-toned
        shift += (residual*np.clip(14+3*u,8,52)+32)//64
        out[rows] = np.clip(rgb+shift[...,None],0,255)
    return out


def outline(frame):
    y, taps = ring(frame, 1)
    hi, lo = np.maximum.reduce(taps), np.minimum.reduce(taps)
    ink = np.minimum(np.clip((hi-y-7)//2,0,24),np.clip((hi+lo-2*y-2)//2,0,24))
    f = frame.astype(np.int16)
    pad = np.pad(f,((1,1),(1,1),(0,0)),mode="edge")
    mean = (4*f+pad[:-2,1:-1]+pad[2:,1:-1]+pad[1:-1,:-2]+pad[1:-1,2:]+4)//8
    return np.clip(mean-ink[...,None],0,255).astype(np.uint8)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--native", type=Path, help="native camera-filter capture")
    source.add_argument("--decoded", type=Path, help="VHDL decoder capture, before the first filter")
    parser.add_argument("--profile", type=int, choices=(2,3), default=3)
    parser.add_argument("--actual", type=Path)
    parser.add_argument("--golden", type=Path, help="also compare the entire captured BMP with this reference")
    args = parser.parse_args()
    name = "PIC1_filtered.bmp" if args.profile==3 else "PIC1_filtered_Designer2.bmp"
    with Image.open(args.decoded or args.native or ROOT/"results/PIC1_native_baseline.bmp") as image:
        if args.profile == 2 and image.size != (2048,1152):
            parser.error("Profile 2 artwork framing requires a 2048 x 1152 source")
        camera = np.asarray(image.convert("RGB"), dtype=np.int16)
    if args.decoded:
        camera = camera_filter(condition_input(camera)).astype(np.int16)
    softened = surface(camera,3,18).astype(np.uint8)
    graded = grade(softened)
    if args.profile == 2:
        graded = graded[coordinates(*ARTWORK_Y)[:,None], coordinates(*ARTWORK_X)]
    expected = outline(graded)
    actual_path = args.actual or ROOT/"results"/name
    with Image.open(actual_path) as image:
        actual = np.asarray(image.convert("RGB"))
    if expected.shape != actual.shape:
        raise SystemExit(f"Frame shape mismatch: {expected.shape} vs {actual.shape}")
    mismatch = np.any(expected != actual,axis=-1)
    print(f"Profile {args.profile}: {int(mismatch.sum()):,} mismatched pixels / {mismatch.size:,}")
    if mismatch.any():
        y,x = np.argwhere(mismatch)[0]
        raise SystemExit(f"At ({x}, {y}) expected {expected[y,x]} and captured {actual[y,x]}")
    print("PASS: all RGB channels agree with the independently evaluated datapath.")
    if args.golden:
        if not filecmp.cmp(actual_path, args.golden, shallow=False):
            raise SystemExit(f"Golden BMP byte comparison failed: {args.golden}")
        print(f"PASS: capture is byte-identical to {args.golden.name}.")


if __name__ == "__main__":
    main()
