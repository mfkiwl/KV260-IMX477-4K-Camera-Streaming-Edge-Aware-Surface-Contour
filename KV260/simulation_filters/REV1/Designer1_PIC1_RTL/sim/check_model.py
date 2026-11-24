"""Raster arithmetic for the live surface, structure and tone paths."""
import argparse
from pathlib import Path

import numpy as np
from PIL import Image


def taps(a, axis, spacing):
    positions = np.arange(a.shape[axis])
    lo = np.where(positions >= spacing, positions-spacing, positions)
    hi = np.where(positions+spacing < a.shape[axis], positions+spacing, positions)
    return np.take(a, lo, axis=axis), np.take(a, hi, axis=axis)


def blur_axis(rgb, axis, spacing, threshold):
    lo, hi = taps(rgb, axis, spacing)
    if threshold is not None:
        lo = np.where((np.abs(lo-rgb).max(axis=2) <= threshold)[...,None], lo, rgb)
        hi = np.where((np.abs(hi-rgb).max(axis=2) <= threshold)[...,None], hi, rgb)
    return (lo + 2*rgb + hi + 2)//4


def planes(rgb, threshold_base=16, sector_radius=4, structure_step=4, context_step=16):
    fine = np.asarray(rgb, dtype=np.int16)
    for axis in (1, 0):
        fine = blur_axis(fine, axis, 1, threshold_base)
    y = (fine[...,0] + 2*fine[...,1] + fine[...,2]+2)//4
    dark = np.zeros_like(y)
    light = np.zeros_like(y)
    for axis in (1, 0):
        lo, hi = taps(y, axis, structure_step)
        delta = y - (lo+hi+1)//2
        dark = np.maximum(dark, -delta)
        light = np.maximum(light, delta)
    from sector_model import sector_surface
    from directional_model import directional_masks
    dark_q2, light_q2 = directional_masks(fine, fine_step=2, medium_step=6, pre_step=2)
    surface = np.asarray(sector_surface(fine, dark_q2, light_q2, sector_radius), dtype=np.int16)
    surround = surface
    for axis in (1, 0):
        surround = blur_axis(surround, axis, context_step, None)
    return surface, surround, np.minimum(63,dark), np.minimum(63,light), dark_q2, light_q2


def luma(rgb):
    return (rgb[..., 0]+2*rgb[..., 1]+rgb[..., 2]+2)//4


def finish_axis(rgb, axis, spacing, maximum_cutoff, evidence, olive):
    left, right = taps(rgb, axis, spacing)
    yl, yc, yr = luma(left), luma(rgb), luma(right)
    cutoff = np.maximum(0, maximum_cutoff-8+np.clip((yc-50)//8, 0, 8))
    if spacing>1:
        barrier = evidence >= 12
        cutoff_y = np.where(olive>=8,14,7)
        left = np.where((barrier & (np.abs(yl-yc)>cutoff_y))[...,None],rgb,left)
        right = np.where((barrier & (np.abs(yr-yc)>cutoff_y))[...,None],rgb,right)
        yl, yr = luma(left), luma(right)
    a = np.where((np.abs(left-rgb).max(2)<=cutoff)[...,None],left,rgb)
    b = np.where((np.abs(right-rgb).max(2)<=cutoff)[...,None],right,rgb)
    smooth = (a+2*rgb+b+2)//4
    if spacing == 1:
        return smooth
    dl, dr = np.abs(yl-yc), np.abs(yr-yc)
    contrast = np.abs(yl-yr)
    between = ((yl < yc) & (yc < yr)) | ((yr < yc) & (yc < yl))
    restore = (between & (contrast >= 10) & (contrast <= 52) & (np.abs(dl-dr) >= 3)
               & (np.minimum(dl, dr) >= 2) & ((yc <= 140) | (rgb[...,0]-rgb[...,1] >= 20)))
    restore &= (olive<8) | (contrast>=32)
    nearer = np.where((dl < dr)[...,None], left, right)
    return np.where(restore[..., None], (rgb + 3*nearer + 2)//4, smooth)


def clear_impulses(rgb):
    left, right = taps(rgb, 1, 1)
    above, below = taps(rgb, 0, 1)
    ys = np.stack([luma(v) for v in (left, right, above, below)])
    low, high = ys.min(axis=0), ys.max(axis=0)
    center = luma(rgb)
    gap = np.maximum(low-center, center-high)
    replace = (gap >= 3) & (gap <= 28) & (high-low <= 18)
    horizontal = (left+right+1)//2
    vertical = (above+below+1)//2
    mean = (horizontal+vertical+1)//2
    red, green, blue = np.moveaxis(rgb,-1,0)
    # Suppress short fragments in a supported, moderately bright warm surface.
    # A 32-code range guard protects larger transitions at the same hue.
    warm = (red-green > 40) & (green-blue > 8) & (center > 80)
    bounded = (high-low <= 32) & (high-center <= 32) & (center-low <= 32)
    mixed = (10*rgb+6*mean+8)//16
    result = np.where((warm & bounded)[...,None], mixed, rgb)
    return np.where(replace[..., None], mean, result)


def expected(rgb):
    from live_tone_model import tone_with_structure
    from stroke_model import reconstruct
    surface, surround, *structure = planes(rgb)
    out = tone_with_structure(surface, surround, *structure)
    r,g,b = np.moveaxis(surface,-1,0)
    olive = np.clip(3*(g-b-3),0,16)*np.clip(16-3*(r-g-1),0,16)//16
    for spacing in (1, 2, 4):
        for axis in (1, 0):
            out = finish_axis(out, axis, spacing, maximum_cutoff=24,evidence=np.maximum(structure[2],structure[3]),olive=olive)
    out = reconstruct(out, surface, surround)
    from region_model import consolidate
    out8 = clear_impulses(consolidate(out)).astype(np.uint32)
    out10 = (out8 << 2) | (out8 >> 6)
    return (out10[..., 0] << 20) | (out10[..., 1] << 10) | out10[..., 2]


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
