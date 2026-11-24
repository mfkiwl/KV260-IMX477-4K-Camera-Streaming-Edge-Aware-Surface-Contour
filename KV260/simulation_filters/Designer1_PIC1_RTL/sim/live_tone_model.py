"""Independent image-domain model of tone band placement and contour reconstruction."""
import numpy as np


def tone_with_structure(surface, surround, fine_dark, fine_light, dark_q2, light_q2):
    r, g, b = np.moveaxis(surface.astype(np.int32), -1, 0)
    wr, wg, wb = np.moveaxis(surround.astype(np.int32), -1, 0)
    center_y = (r + 2*g + b + 2)//4
    delta = (wr + 2*wg + wb + 2)//4 - center_y
    trust = np.clip(16 - 2*np.maximum(np.abs(delta)-3, 0), 0, 16)
    y = center_y + (delta*trust + 8)//16
    rg = r-g + ((wr-wg-r+g)*trust + 8)//16
    gb = g-b + ((wg-wb-g+b)*trust + 8)//16
    warm = np.clip(4*(rg-1) - np.maximum(y-32, 0)//16, 0, 16)
    dark_zone = np.clip(46-y, 0, 16)
    dark = dark_q2.astype(np.int32)
    light = light_q2.astype(np.int32)

    shadow = np.clip((80-y)//2, 0, 16)
    yellow = np.clip(2*(16-gb), 0, 16)
    cool = (shadow*(16-warm)*yellow + 128)//256
    olive_gate = np.clip(3*(gb-4), 0, 16)
    lit = np.clip((np.maximum(dark, light)+2)//4 + np.clip(-delta, 0, 8) - 1, 0, 16)
    cool = (cool*(16-(olive_gate*lit+8)//16)+8)//16
    toe = np.clip(40-y, 0, 16)
    room = np.clip((128-y)//4, 0, 16)
    olive = np.clip(gb//2, 0, 12)
    lum = (2*(y-8)-toe//2-np.maximum(y-64, 0)-np.maximum(y-96, 0)//2
           + (warm*room+8)//16 + (olive*(16-warm)*room+128)//256)
    red_green = (7*rg)//2 + 2*warm - (9*cool+2)//4
    green_blue = (5*gb)//2 + (gb*warm)//16 - (cool*(32-toe)*3+32)//64

    # Adjust the decision threshold for the existing 16-code bands.
    activity_gate = np.maximum(np.clip(2*rg-gb, 0, 16), np.clip(67-y, 0, 16))
    activity = np.clip(3*np.abs(delta) + fine_dark + fine_light, 0, 16)
    amount = np.maximum(np.clip(warm, 4, 16), np.minimum(np.clip(2*(gb-6), 0, 16), activity))
    phase = (np.clip((light-dark+2)//4, -5, 5)*activity_gate+8)//16
    green_weight = np.clip(2*(gb-4), 0, 16)*(16-warm)
    phase = (phase*(16-green_weight//16)+8)//16
    band = 16*((lum+phase+8)//16)
    lum += ((band-lum)*amount+8)//16

    guard = (warm*np.clip((y-32)//4, 0, 8)+8)//16
    dark_floor = 2 + np.clip(2*guard-2*np.maximum(0, delta-3), 0, 16)
    light_floor = 2 + np.clip(2*guard-2*np.maximum(0, -delta-3), 0, 16)
    axial_ink = np.maximum(np.clip(3*(fine_dark-fine_light//2-dark_floor), 0, 48),
                          np.clip(delta-7, 0, 32)//2)
    axial_highlight = np.clip(2*(fine_light-fine_dark//2-light_floor), 0, 20)
    lum += axial_highlight-axial_ink

    floor = 5 + ((warm*(16-dark_zone)+8)//16)//2
    ink = (np.clip(dark-light//2-floor, 0, 40)*activity_gate+8)//16
    crest = np.maximum(0, light-dark//2-floor)
    highlight = (np.clip((6*crest+2)//4, 0, 48)*(dark_zone+3)+8)//16
    stroke = np.maximum(0, highlight-axial_highlight)-np.maximum(0, ink-axial_ink)
    tint = np.clip((dark-light+2)//4, 0, 16)
    red_green -= (red_green*tint+32)//64
    green_blue -= (green_blue*tint+32)//64
    lum += np.clip((-np.minimum(0, delta)*dark_zone+8)//16, 0, 12)
    # The surround supplies local chroma. Lower its influence across a luma boundary.
    chroma_strength = (green_weight+8)//16
    chroma_strength = (chroma_strength*(8+np.clip(24-np.abs(delta), 0, 8))+8)//16
    red_green += ((3*(wr-wg)-red_green)*chroma_strength+16)//32
    green_blue += ((3*(wg-wb)-green_blue)*chroma_strength+16)//32
    green = lum + (green_blue-red_green+2)//4
    color = np.clip(np.stack((green+red_green, green, green-green_blue), axis=-1), 0, 255)

    color = np.clip(color+(np.minimum(128, color+16)*stroke[..., None]+64)//128, 0, 255)
    dark_crest = (np.clip((34-center_y)*2, 0, 16)*np.clip(light-dark-3, 0, 44)+8)//16
    return np.clip(color+(np.minimum(72, color+24)*dark_crest[..., None]+32)//64, 0, 255).astype(np.int16)
