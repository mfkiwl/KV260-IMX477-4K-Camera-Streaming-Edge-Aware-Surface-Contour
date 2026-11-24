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
