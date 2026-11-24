"""Compare all 32 bits of the accepted AXI stream with a source-only raster model."""
import argparse
from pathlib import Path

import numpy as np
from PIL import Image

from live_tone_model import tone_with_context


def smooth(rgb, threshold_base=16, threshold_step=2):
    """Apply centered separable filters at four scales. One RGB outlier vetoes a tap."""
    a = np.asarray(rgb, dtype=np.int16)
    for scale in range(4):
        threshold = min(255, threshold_base + scale*threshold_step)
        for axis in (1, 0):  # Horizontal, then vertical.
            reach = min(2**scale, a.shape[axis]-1)
            if reach == 0:
                continue
            lo = a.copy()
            hi = a.copy()
            nearer_origin = [slice(None)] * a.ndim
            farther_from_origin = [slice(None)] * a.ndim
            nearer_origin[axis] = slice(None, -reach)
            farther_from_origin[axis] = slice(reach, None)
            lo[tuple(farther_from_origin)] = a[tuple(nearer_origin)]
            hi[tuple(nearer_origin)] = a[tuple(farther_from_origin)]
            lo = np.where((np.abs(lo-a).max(axis=2) <= threshold)[..., None], lo, a)
            hi = np.where((np.abs(hi-a).max(axis=2) <= threshold)[..., None], hi, a)
            a = (lo + 2*a + hi + 2)//4
    return a.astype(np.uint8)


def broad_context(rgb, spacing=16):
    """Separable, unthresholded [1,2,1] around a fixed-distance center."""
    a = np.asarray(rgb, dtype=np.int32)
    for axis in (1, 0):
        pos = np.arange(a.shape[axis])
        lo = np.take(a, np.where(pos >= spacing, pos-spacing, pos), axis=axis)
        hi = np.take(a, np.where(pos+spacing < a.shape[axis], pos+spacing, pos), axis=axis)
        a = (lo + 2*a + hi + 2)//4
    return a


def expected(rgb):
    """Return packed RGB10 words; each 8-bit result expands by MSB replication."""
    detail = smooth(rgb)
    rgb8 = np.asarray(tone_with_context(detail.astype(np.int32), broad_context(detail)),
                      dtype=np.uint32)
    rgb10 = (rgb8 << 2) | (rgb8 >> 6)
    return (rgb10[..., 0] << 20) | (rgb10[..., 1] << 10) | rgb10[..., 2]


def check(decoded, trace, frames=1, low_bits=False):
    with Image.open(decoded) as image:
        source = np.asarray(image.convert("RGB"))
    words = np.fromfile(trace, dtype="<u4")
    count = source.shape[0] * source.shape[1]
    if words.size != frames*count:
        raise ValueError(f"Expected {frames*count} transfers, captured {words.size}")
    words = words.reshape(frames, *source.shape[:2])
    # Shifting/replicating/randomizing the two input low bits produces the
    # same RGB888 core input. The four output bytes are checked in full.
    mismatches = 0
    for f in range(frames):
        image = source if f == 0 else 255-np.roll(source, -1, axis=2)
        result = expected(image)
        mask = words[f] != result
        misses = np.count_nonzero(mask)
        print(f"Frame {f+1} full-word model: {misses:,} mismatches / {count:,}")
        if misses:
            y, x = np.unravel_index(mask.argmax(), mask.shape)
            print(f"First at ({x}, {y}): expected 0x{result[y,x]:08x}, got 0x{words[f,y,x]:08x}")
        mismatches += misses
    return mismatches == 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("decoded", type=Path)
    parser.add_argument("trace", type=Path)
    parser.add_argument("--frames", default=1, type=int, choices=(1, 2))
    parser.add_argument("--low-bits", action="store_true",
                        help="accept traces with varying low input bits, as in the stress test")
    args = parser.parse_args()
    raise SystemExit(0 if check(args.decoded, args.trace, args.frames, args.low_bits) else 1)
