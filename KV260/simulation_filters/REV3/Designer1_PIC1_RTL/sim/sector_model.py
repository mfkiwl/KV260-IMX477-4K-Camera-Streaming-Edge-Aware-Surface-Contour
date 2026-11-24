"""Select low-variance overlapping square neighborhoods using live RGB samples."""
import numpy as np


def sector_surface(fine_rgb, dark_q2, light_q2, radius=4):
    src = np.asarray(fine_rgb, dtype=np.int32)
    height, width = src.shape[:2]
    if height <= radius or width <= radius:
        return src.astype(np.uint8)
    luma = (src[..., 0] + 2*src[..., 1] + src[..., 2] + 2) // 4
    guide = luma + np.clip((light_q2-dark_q2+2)//4, -12, 12)
    strength = np.maximum(dark_q2, light_q2)
    slope = np.where(strength >= 24, 16, np.where(strength >= 8, 8, 0))
    values = np.dstack((src, luma, luma*luma))
    integral = np.pad(values, ((1,0),(1,0),(0,0))).cumsum(0,dtype=np.int64).cumsum(1,dtype=np.int64)
    count = (radius + 1)**2
    tolerance = (2*count)**2
    result = np.empty(src.shape, dtype=np.uint8)
    x = np.arange(width)
    for begin in range(0, height, 48):
        y = np.arange(begin, min(height, begin+48))
        means, scores, valid = [], [], []
        for dy, dx in ((-radius,-radius),(-radius,0),(0,-radius),(0,0)):
            x0, x1 = x+dx, x+dx+radius+1
            y0, y1 = y+dy, y+dy+radius+1
            mask = ((y0 >= 0) & (y1 <= height))[:,None] & ((x0 >= 0) & (x1 <= width))
            x0, x1 = x0.clip(0,width), x1.clip(0,width)
            y0, y1 = y0.clip(0,height)[:,None], y1.clip(0,height)[:,None]
            sums = integral[y1,x1] - integral[y0,x1] - integral[y1,x0] + integral[y0,x0]
            variance = count*sums[...,4] - sums[...,3]**2
            mean_rgb = (sums[..., :3]+count//2)//count
            mean_y = (mean_rgb[...,0]+2*mean_rgb[...,1]+mean_rgb[...,2]+2)//4
            deviation = np.maximum(0, np.abs(guide[y]-mean_y)-1)
            cost = variance + count*count*slope[y]*deviation
            scores.append(np.where(mask,cost,2**50))
            means.append(mean_rgb)
            valid.append(mask)
        scores = np.stack(scores,axis=2)
        keep = np.stack(valid,axis=2) & (scores <= scores.min(axis=2)[...,None]+tolerance)
        num = keep.sum(axis=2)[..., None]
        numerator = (np.stack(means,axis=2)*keep[...,None]).sum(axis=2)
        selection = (numerator+num//2)//np.maximum(num,1)
        result[y] = np.where(num!=0,selection,src[y])
    return result
