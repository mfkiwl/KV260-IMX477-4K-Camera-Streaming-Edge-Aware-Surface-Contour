"""Bit-accurate RGB888 analytic split-tone grade; final channel order is RGB."""
import numpy as np

def tone_with_context(rgb, context):
    rgb = np.asarray(rgb, dtype=np.int32)
    r, g, b = np.moveaxis(rgb, -1, 0)
    y = (r + 2*g + b + 2) // 4
    context=np.asarray(context,dtype=np.int32)
    wr,wg,wb=np.moveaxis(context,-1,0)
    wy=(wr+2*wg+wb+2)//4
    # At gentle gradients, use up to three-quarters of the broad surface color.
    # Suppress mixing across strong luminance boundaries. Q4 grade blend.
    trust=np.clip(12-np.abs(y-wy),0,12)
    rg = (r-g)+(((wr-wg)-(r-g))*trust+8)//16
    gb = (g-b)+(((wg-wb)-(g-b))*trust+8)//16
    # Factors in Q4, shared by every pixel. Chroma suppresses the shadow tint.
    warm = np.clip(4*(rg-1)-np.maximum(y-32,0)//16, 0, 16)
    shadow = np.clip((80-y)//2, 0, 16)
    yellow_guard = np.clip(2*(16-gb),0,16)
    cool = (shadow*(16-warm)*yellow_guard+128)//256
    toe = np.clip(40-y,0,16)
    # Two-to-one exposure with a black toe and a highlight shoulder.
    lum = 2*(y-8)-toe//2-np.maximum(y-64,0)-np.maximum(y-96,0)//2
    # Midtone lift for warm colors, with reduced lift approaching highlights.
    room = np.clip((128-y)//4, 0, 16)
    lum += (warm*room+8)//16
    olive = np.clip(gb//2,0,12)
    lum += (olive*(16-warm)*room+128)//256
    # Strengthen measured opponent chroma and tint low-saturation shadows.
    rg_out = (7*rg)//2+2*warm-(9*cool+2)//4
    gb_out = (5*gb)//2+(gb*warm)//16-(cool*(32-toe)*3+32)//64
    lum-=np.clip(wy-y-8,0,24)//2  # dark-side contour
    # Half-strength, eight-level-spacing luma posterization.
    lum = (lum+((lum+4)//8)*8)//2
    green = lum+(gb_out-rg_out+2)//4
    out = np.stack((green+rg_out,green,green-gb_out),axis=-1)
    return np.clip(out,0,255).astype(np.uint8)

