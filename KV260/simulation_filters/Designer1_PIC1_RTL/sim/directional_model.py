"""Directional contour evidence from two stencils of the incoming luminance."""
import numpy as np


def directional_masks(rgb, fine_step, medium_step, pre_step):
    source = np.asarray(rgb, dtype=np.int16)
    y = source[..., 0] + 2*source[..., 1] + source[..., 2]
    for axis in (1, 0):
        positions = np.arange(y.shape[axis])
        low = np.where(positions >= pre_step, positions - pre_step, positions)
        high = np.where(positions + pre_step < len(positions), positions + pre_step, positions)
        y = (np.take(y, low, axis=axis) + 2*y + np.take(y, high, axis=axis) + 2)//4
    fine = directional_strips(y, fine_step)
    medium = directional_strips(y, medium_step)
    masks = []
    for polarity in (-1, 1):
        strongest = np.zeros_like(y)
        for (f, _, ft), (m, mn, mt) in zip(fine, medium):
            coherent = np.maximum(0, polarity*m - np.maximum(0, mt-mn)//8)
            support = 3*np.maximum(0, polarity*f) + np.maximum(0, mn-ft)//4 + 2
            strongest = np.maximum(strongest, np.minimum(coherent, support))
        masks.append(np.minimum(strongest, 255))
    return tuple(masks)


def directional_strips(y, radius):
    height, width = y.shape
    padded = np.pad(y, radius, mode='edge')

    def sample(dy, dx):
        return padded[radius+dy:radius+dy+height, radius+dx:radius+dx+width]

    def avg(a, b, c):
        return (a + 2*b + c + 2)//4

    nw, n, ne, w, center, e, sw, s, se = (
        sample(dy, dx) for dy in (-radius, 0, radius) for dx in (-radius, 0, radius)
    )
    strips = (
        (w, e, avg(nw, n, ne), avg(sw, s, se)),
        (n, s, avg(nw, w, sw), avg(ne, e, se)),
        (nw, se, avg(n, ne, e), avg(w, sw, s)),
        (ne, sw, avg(w, nw, n), avg(s, se, e)),
    )
    return [(avg(t0, center, t1)-(lo+hi+1)//2, np.abs(hi-lo), np.abs(t1-t0))
            for t0, t1, lo, hi in strips]
