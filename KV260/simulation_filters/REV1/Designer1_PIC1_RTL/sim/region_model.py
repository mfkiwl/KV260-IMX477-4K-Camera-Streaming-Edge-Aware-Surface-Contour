"""Directional color consolidation using two sparse neighborhoods of live RGB."""
import numpy as np
from stroke_model import luma, neighborhood


def consolidate(rgb):
    a = np.asarray(rgb, dtype=np.int32)
    y = luma(a)
    near, far = neighborhood(a,2), neighborhood(a,5)
    yn, yf = [luma(v) for v in near], [luma(v) for v in far]
    cost = np.full_like(y, 2047)
    target, flank = a.copy(), y.copy()
    for i, j, n, m in ((3,5,1,7),(1,7,3,5),(0,8,2,6),(2,6,0,8)):
        score = 2*(np.abs(yn[i]-y)+np.abs(yn[j]-y))+np.abs(yf[i]-y)+np.abs(yf[j]-y)
        chosen = score<cost
        avg = (near[i]+near[j]+far[i]+far[j]+2)//4
        target = np.where(chosen[...,None],avg,target)
        flank = np.where(chosen,(yf[n]+yf[m]+1)//2,flank)
        cost = np.minimum(cost,score)

    median = np.partition(np.stack(yn),4,axis=0)[4]
    anchor = a.copy()
    for i in (0,2,6,8,1,7,3,5,4):
        anchor = np.where((yn[i]==median)[...,None],near[i],anchor)
    sn = np.maximum.reduce([y+6-np.maximum(yn[i],yn[8-i]) for i in range(4)])
    sf = np.maximum.reduce([y+9-np.maximum(yf[i],yf[8-i]) for i in range(4)])
    repair = np.where((median>y+3)&(sn<0)&(sf<0),np.clip(2*np.minimum(-sn,-sf),0,14),0)
    amount = np.clip((68-cost)//2,0,18)
    base = a+((target-a)*amount[...,None]+16)//32
    base += ((anchor-base)*repair[...,None]+8)//16

    along = (2*y+luma(target)+1)//3
    dev = along-flank
    r,g,b = np.moveaxis(a,-1,0)
    lip = np.clip(r-g-20,0,24)*np.clip(24-np.maximum(0,3*(g-b-8)),0,24)//24
    warm = np.clip((146-y)//2,0,24)*np.clip((r-g-14)//2,0,24)//24
    structure = (np.clip(24-cost//3,0,20)*np.clip(np.abs(dev)-2,0,16)+8)//16
    shift = (structure*warm+8)//16
    shift = (shift*(8+lip)+8)//16
    shift = np.where(dev>0,shift,(-shift)//3)
    shift = (shift*np.clip(12+lip,0,24)+12)//24
    cool = np.clip((b-r-8)//2,0,18)*np.clip((52-y)//2,0,16)//16
    tier = 2*np.clip((along-20)//3,-3,5)
    tier = (tier*cool+8)//16
    tier = (tier*np.clip(2*np.abs(dev),0,16)+8)//16
    tint = (lip*np.clip(8+dev,0,20)+16)//32
    offsets = np.stack((shift+tint+tier//3,shift+tier,shift//2+tint//2+tier),axis=-1)

    # Preserve medium-scale color in an interior supported by both stencils.
    # Centered differences are clipped before summation so a single distant
    # dark contour cannot dictate the color of the surrounding surface.
    def bounded_mean(levels):
        return (sum(np.clip(level-y,-14,14) for level in levels)+4)//8

    near_change, far_change = bounded_mean(yn), bounded_mean(yf)
    medium = np.clip(near_change-far_change,-8,8)
    medium = (medium+1)//2
    warm_weight = np.clip((r-g-4)//2,0,16)*np.clip((g-b+4)//2,0,16)//16
    cool_weight = np.clip((b-r-1)//2,0,16)*np.clip(56-y,0,16)//16
    warm_step = (medium*warm_weight+8)//16
    cool_step = (medium*cool_weight+8)//16
    low_blue = (np.clip((50-y-near_change)//2,0,16)*cool_weight+8)//16
    low_blue = (low_blue*np.clip(3*np.abs(far_change),0,16)+8)//16
    correction = np.stack((warm_step//2-low_blue, warm_step+cool_step,
                           (warm_step+1)//2+(3*cool_step)//2),axis=-1)
    return np.clip(np.clip(base+offsets,0,255)+correction,0,255).astype(np.int16)
