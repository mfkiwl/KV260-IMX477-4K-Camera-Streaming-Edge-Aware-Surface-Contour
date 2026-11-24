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
    rendered = np.clip(np.clip(base+offsets,0,255)+correction,0,255)
    far_median = np.partition(np.stack(yf), 4, axis=0)[4]
    warm_votes = sum((v[..., 0] > v[..., 1] + 12).astype(np.int16) for v in far)
    far_span = np.maximum.reduce(yf) - np.minimum.reduce(yf)
    return render_supported_color(rendered, a, target, flank, median, far_median, warm_votes, far_span)


def render_supported_color(rendered, center, tangent_rgb, flank, near_rank, far_rank, warm_votes, far_span):
    """Render a medium color plane from two rank estimates and a compatible tangent."""
    clip = np.clip
    r, g, b = np.moveaxis(center, -1, 0)
    y = luma(center)
    plane = (near_rank + far_rank + 2*luma(tangent_rgb) + 2)//4
    support = clip(18 - np.abs(near_rank-far_rank)//3, 0, 16)
    shadow = clip((90-plane)//2, 0, 16)
    warm = clip((r-g-8)//2, 0, 16)
    cool = clip((b-r+2)//2, 0, 16)
    olive = clip(2*(g-b-3), 0, 16)*clip(16-r+g, 0, 16)//16
    dark_cool = (cool*shadow+8)//16
    gain = np.maximum(np.maximum(warm,cool)*shadow//16,olive)*support//16
    adjust = (clip(plane-y,-20,20)*gain+16)//32

    # Cool rank-supported mids extend a highlight; a narrow positive excursion
    # that is brighter than the tangent plane and the flank is attenuated.
    mids = clip(np.minimum(near_rank,far_rank)-12,0,12)*clip(52-np.maximum(near_rank,far_rank),0,16)//16
    lift = (3*mids*dark_cool+128)//256
    peak = clip(y-np.maximum(plane,flank)-2,0,20)*dark_cool//16

    # Preserve distinct warm and cool opponent levels sharing the same local luminance.
    red_gate = (warm*shadow+8)//16
    jacket = clip(135-plane,0,16)*olive//16
    tr, tg = tangent_rgb[...,0], tangent_rgb[...,1]
    light = clip((plane-41)//2,0,16)*clip((b-r-4)//2,0,16)//16
    pale = light*clip(tr-tg-r+g,0,16)//16
    votes = clip(4*warm_votes,0,16)
    reflected = (24*light*votes+128)//256
    brown = (votes*clip((plane-26)//2,0,16)//16)*clip(3*(g-b)-(r-g)+4,0,16)
    brown = (brown+8)//16
    shade = -((clip(90-plane,0,20)*brown+8)//16)
    red_low = warm*clip(2*(8-g+b),0,16)//16
    glow = (clip(60-plane,0,30)*red_low+8)//16
    # Recover a brighter intermediate plane in a mixed shadow. A spatially
    # uniform cool neighborhood lacks both a broad span and nearby warm votes.
    shoulder = clip(plane-46,0,16)*clip(128-plane,0,16)//16
    support_gain = clip(clip((far_span-12)//2,0,12) + 4*warm_votes,0,16)
    neutral_cool = clip(3*(b-r+12),0,16)
    # Full lift requires a warm neighbor. Uniform cool/olive planes retain shade.
    neutral_cool = (neutral_cool*clip(12*warm_votes+6,0,16)+8)//16
    light_plane = (40*shoulder*support_gain*neutral_cool + 2048)//4096
    red = ((lift+2)//4 - peak//2 - (clip(r-g-6,0,36)*red_gate+8)//16
           + pale + reflected + glow + shade + light_plane + light_plane//2)
    green = (lift - peak + (clip((57-plane)//2,0,12)*red_gate+8)//16
             + (pale+1)//2 + reflected//2 + (glow+1)//2 + shade + light_plane)
    blue = (lift//2 - peak + (clip((57-plane)//2,0,10)*red_gate+8)//16
            - (6*jacket+8)//16 - pale//2 - reflected//4 + glow//4 + shade//2 + light_plane//4)
    return clip(rendered + adjust[...,None] + np.stack((red,green,blue),axis=-1),0,255).astype(np.int16)
