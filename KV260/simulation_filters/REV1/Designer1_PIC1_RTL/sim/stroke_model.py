"""Integer raster model for the live contour classifier and compositor."""
import numpy as np


def shift(plane, dy, dx):
    ys = np.clip(np.arange(plane.shape[0]) + dy, 0, plane.shape[0]-1)
    xs = np.clip(np.arange(plane.shape[1]) + dx, 0, plane.shape[1]-1)
    return plane[ys[:, None], xs]


def luma(rgb):
    return (rgb[..., 0] + 2*rgb[..., 1] + rgb[..., 2] + 2)//4


def neighborhood(array, spacing):
    return [shift(array, dy*spacing, dx*spacing)
            for dy in (-1, 0, 1) for dx in (-1, 0, 1)]


def strips(y, spacing):
    nw, n, ne, w, c, e, sw, s, se = neighborhood(y, spacing)

    def avg(a, b, c):
        return (a+2*b+c+2)//4

    strips_at_scale = (
        (w, e, avg(nw, n, ne), avg(sw, s, se)),
        (n, s, avg(nw, w, sw), avg(ne, e, se)),
        (nw, se, avg(n, ne, e), avg(w, sw, s)),
        (ne, sw, avg(w, nw, n), avg(s, se, e)),
    )
    for start, end, left, right in strips_at_scale:
        center = avg(start, c, end)
        yield (right-left, np.abs(end-start), (left+right+1)//2-center,
               np.minimum(left, right)-center)


def linked_strength(y):
    directions = ((0, 1), (1, 0), (1, 1), (1, -1))
    ink = np.zeros_like(y)
    sustained = np.zeros_like(y)
    for (dy, dx), near, far in zip(directions, strips(y, 3), strips(y, 12)):
        gf, tf, phase, vf = near
        gm, tm, _, vm = far
        fine = np.maximum(0, np.abs(gf)-tf//2)
        coarse = np.maximum(0, np.abs(gm)-tm//2)
        agree = ((gf >= 0) & (gm >= 0)) | ((gf <= 0) & (gm <= 0))
        gradient = np.minimum(255, np.minimum(2*fine, coarse)) * agree
        step = np.minimum((gradient+1)//2, np.maximum(0, 12+phase))
        valley = 3*np.maximum(0, np.minimum(vf, vm))
        seed = np.minimum(63, np.maximum(step, valley))

        cross_a = shift(seed, 3*dx, -3*dy)
        cross_b = shift(seed, -3*dx, 3*dy)
        cross_peak = np.maximum(cross_a, cross_b)
        center = np.minimum(seed, np.maximum(0, 10+2*(seed-cross_peak)))
        a, b = shift(center, 3*dy, 3*dx), shift(center, -3*dy, -3*dx)
        contact = np.maximum(np.minimum(center, np.maximum(a, b)),
                             np.minimum(np.minimum(a, b), center+8))
        track = np.minimum((a+2*center+b+2)//4+2, contact+2)
        ink = np.maximum(ink, track)
        far_a = shift(center, 6*dy, 6*dx)
        far_b = shift(center, -6*dy, -6*dx)
        continuation = np.minimum(far_a,far_b)+8+np.maximum(far_a,far_b)//2
        sustained = np.maximum(sustained,np.minimum(track,continuation))
    return ink,sustained


def rank_anchor(rgb):
    patches = neighborhood(rgb, 3)
    levels = np.stack([luma(p) for p in patches])
    middle = np.partition(levels, 4, axis=0)[4]
    result = rgb.copy()
    # Later matches have priority. Preserve the center color at a luminance tie.
    for index in (0, 2, 6, 8, 1, 7, 3, 5, 4):
        result = np.where((levels[index] == middle)[..., None], patches[index], result)
    return result


def coverage_mask(ink):
    # Consolidate across the local area; a lone sample cannot ink its neighbors.
    core = neighborhood(ink, 1)
    votes = sum((p>0).astype(np.int16) for p in core)
    tight = (sum(core)+4)//9
    broad = (sum(neighborhood(ink, 3))+4)//9
    pair = np.maximum.reduce([np.minimum(core[i],core[8-i]) for i in (0,1,2,3)])
    center = (np.minimum(ink,2*tight)+tight+1)//2
    shoulder = np.minimum(48,(2*tight+broad+1)//3+np.minimum(broad,pair)//2)
    return np.where(votes>=3,np.maximum(center,shoulder),np.where(broad>=5,broad//2,0))


def reconstruct(rgb, surface, surround):
    rgb = np.asarray(rgb, dtype=np.int32)
    surface = np.asarray(surface, dtype=np.int32)
    surround = np.asarray(surround, dtype=np.int32)
    r, g, b = np.moveaxis(surface, -1, 0)
    sy, y = luma(surface), luma(rgb)
    delta = luma(surround)-sy
    olive = np.clip(3*(g-b-3), 0, 16)*np.clip(16-3*(r-g-1), 0, 16)//16
    lift = np.clip(-delta-2, 0, 12)*np.clip(58-sy, 0, 16)//16
    lift = (lift*(16-olive)+8)//16
    strength,sustained = linked_strength((2*y).astype(np.int16))
    anchor = rank_anchor(rgb)
    gap = np.max(np.abs(anchor-rgb), axis=-1)
    # Weak fluctuations merge. Across medium/strong boundaries blend only very similar colors.
    w = np.where(strength<9, np.clip(84-gap,0,16), np.clip(14-gap,0,12))
    w = w*(12+olive//4)//16
    near_count=sum((luma(p)<=y+5).astype(np.int16) for p in neighborhood(rgb,3))-1
    far_count=sum((luma(p)<=y+7).astype(np.int16) for p in neighborhood(rgb,6))-1
    depression=luma(anchor)-y
    isolated=(near_count<=2)&(far_count<=3)&(depression>=3)&(sustained<30)
    w=np.where(isolated,np.maximum(w,np.clip(24+depression//2,0,48)),3*w)
    base=rgb+((anchor-rgb)*w[...,None]+24)//48

    e = np.where(sustained>=18,strength-8,0)
    amount = np.minimum(48, (e+1)//2+np.maximum(0, e-6)+np.maximum(0, e-18))
    penalty = (np.clip(7-delta, 0, 8)*np.clip((y-72)//4, 0, 16)+8)//16
    side = np.clip(13+delta-penalty, 3, 20)
    room = np.minimum(np.clip(80-sy, 0, 24), np.clip((156-y)//2, 0, 24))
    amount = (amount*side+8)//16
    amount = (amount*room+12)//24
    amount = (amount*(32-olive//2)+16)//32
    coverage = coverage_mask(amount)
    taps = neighborhood(rgb,3)
    levels = np.stack([luma(p) for p in taps]).reshape(3,3,*y.shape)
    dark_level = np.min(np.median(levels,axis=1),axis=0)
    flank = rgb.copy()
    for i in (0,2,6,8,1,7,3,5,4):
        flank = np.where((levels[i//3,i%3]==dark_level)[...,None],taps[i],flank)
    shadow = (np.minimum(base,flank)*np.array([2,5,9])+8)//16
    highlight = (np.minimum(112,32+base)*lift[...,None]+32)//64
    return np.clip(base+((shadow-base)*coverage[...,None]+32)//64+highlight,0,255).astype(np.int16)
