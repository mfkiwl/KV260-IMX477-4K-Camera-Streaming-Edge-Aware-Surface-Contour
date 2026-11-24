"""Pre-quantization voting on signed local luminance and opponent-color residuals."""
import numpy as np
from stroke_model import luma, shift


def vote_surface(surface, surround, dark_q2, light_q2):
    sector = surface.astype(np.int16)
    broad = surround.astype(np.int16)
    r, g, b = np.moveaxis(sector, -1, 0)
    wr, wg, wb = np.moveaxis(broad, -1, 0)
    level = luma(sector) - luma(broad)
    red_green = (r-g) - (wr-wg)
    green_blue = (g-b) - (wg-wb)
    magnitude = np.maximum.reduce((np.abs(level), np.abs(red_green), np.abs(green_blue)))
    # Equal magnitudes prefer Y, then R-G, then G-B. Zero produces a neutral tag.
    tag = np.where(magnitude == np.abs(level), np.sign(level),
                   np.where(magnitude == np.abs(red_green),
                            2*np.sign(red_green), 3*np.sign(green_blue)))
    accumulated = np.zeros_like(sector)
    votes = []
    for radius, directions in ((3, ((0,-1), (-1,0), (1,0), (0,1))),
                               (7, ((-1,-1), (1,-1), (-1,1), (1,1)))):
        count = np.zeros_like(level)
        for dy, dx in directions:
            neighbor = shift(sector, radius*dy, radius*dx)
            neighbor_tag = shift(tag, radius*dy, radius*dx)
            count += (tag != 0) & (tag == neighbor_tag)
            accumulated += np.clip(neighbor-sector, -10, 10)
        votes.append(count)
    near_votes, far_votes = votes
    response = np.maximum(magnitude, np.maximum(dark_q2, light_q2)//8)
    supported = (near_votes>=2) & (far_votes>=2) & (near_votes+far_votes>=5)
    amount = np.where(response>=18, 0,
                      np.where((response>=3) & supported, 4,
                               np.where(response>=2, 12, 16)))
    # A dead band avoids flipping an established band for sub-three-code means.
    amount = np.where(np.abs(accumulated).max(axis=2)>=23, amount, 0)
    offset = (accumulated+4)//8
    return np.clip(sector + (amount[...,None]*offset+8)//16, 0, 255)


def region_context(surface, surround, dark_q2, light_q2):
    """Bound the broad-context pull using the signed difference of nested spatial means."""
    sector = surface.astype(np.int16)
    level = sector[...,0] + 2*sector[...,1] + sector[...,2]
    near_sum = np.zeros_like(level, dtype=np.int32)
    full_sum = np.zeros_like(near_sum)
    for dy in (-7, -3, 0, 3, 7):
        for dx in (-7, -3, 0, 3, 7):
            tap = shift(level, dy, dx)
            full_sum += tap
            if abs(dx) <= 3 and abs(dy) <= 3:
                near_sum += tap
    inner = (near_sum + 4)//9
    outer = (full_sum + 12)//25
    r, g, b = np.moveaxis(surround.astype(np.int16), -1, 0)
    broad = r + 2*g + b
    delta = inner - outer
    selected = (np.abs(delta) >= 2) & (np.abs(delta) <= 40)
    selected &= ((delta > 0) & (inner > broad)) | ((delta < 0) & (inner < broad))
    y = (broad+2)//4
    exposure = y + r - b
    weight = np.minimum(np.clip(2*(98-exposure),0,16), np.clip(2*(y-32),0,16))
    directional = np.maximum(dark_q2, light_q2).astype(np.int16)
    weight = np.minimum(weight, np.clip((36-directional)//2,0,16))
    change = (np.clip((delta+1)//2,-3,3)*weight + 8)//16
    return np.clip(surround.astype(np.int16) + np.where(selected,change,0)[...,None], 0, 255).astype(np.int16)
