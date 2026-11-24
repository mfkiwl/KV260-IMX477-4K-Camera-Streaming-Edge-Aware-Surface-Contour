"""Independent image-domain model of tone band placement and contour reconstruction."""
import numpy as np


def tone_with_structure(surface, surround, fine_dark, fine_light, dark_q2, light_q2):
    r, g, b = np.moveaxis(surface.astype(np.int32), -1, 0)
    wr, wg, wb = np.moveaxis(surround.astype(np.int32), -1, 0)
    center_y = (r + 2*g + b + 2)//4
    delta = (wr + 2*wg + wb + 2)//4 - center_y
    trust = np.clip(16 - 2*np.maximum(np.abs(delta)-3, 0), 0, 16)

    # The sector-selected surface and its broad context are aligned. A color or
    # luma difference controls use of the sector level when choosing its band.
    surf_rg, surf_gb = r-g,g-b
    diff_rg, diff_gb = wr-wg-surf_rg,wg-wb-surf_gb
    response = np.clip(4*np.abs(delta)+2*np.maximum(np.abs(diff_rg),np.abs(diff_gb))-2,0,16)
    gate = np.maximum(np.clip(3*(surf_rg-1),0,16),np.clip(38-center_y,0,16))
    structure = (gate*response+8)//16
    reduced_trust = (trust*(16-(structure*10+8)//16)+8)//16
    y = center_y+(delta*reduced_trust+8)//16
    chroma_trust = (reduced_trust+trust+1)//2
    rg = surf_rg+(diff_rg*chroma_trust+8)//16
    gb = surf_gb+(diff_gb*chroma_trust+8)//16
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
    surface_offset = np.clip(-delta,-12,12)
    lum += (surface_offset*structure+16)//32
    band = 16*((lum+phase+8)//16)
    # Place a half band where a warm, spatially supported transition crosses a broad surface.
    sub = (np.clip(np.abs(delta)-1,0,4)*warm+2)//4
    half_band = 8*((lum+phase+4)//8)
    sub=np.maximum(sub,structure)
    band += ((half_band-band)*sub+8)//16
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
    patch = np.clip((-delta+1)//2,0,7)*6
    patch = (patch*np.clip(52-center_y,0,16)+8)//16
    patch = (patch*(16-warm//2)+8)//16
    lum += patch
    red_green -= patch*3//4
    green_blue -= patch//3
    red_green += (np.clip(2*(rg-gb),0,12)*warm+8)//16
    region_y = center_y+(3*delta+2)//4
    grade = 4*np.clip((region_y-19)//2,0,4)-6
    cool_zone = np.clip(36-center_y,0,12)*np.clip(12-3*np.abs(rg),0,12)
    local_gate = np.clip(4*np.abs(delta)+np.maximum(light,dark)//2,0,16)
    bias = (grade*cool_zone+72)//144
    lum += (bias*local_gate+8)//16
    green_blue -= (np.clip(3*(rg-gb+1),0,12)*np.clip(68-y,0,16)*warm+128)//256

    # Separate dark, nearly neutral planes using their neighborhood exposure
    # and the *signed* surface-to-context difference.
    neutral = np.clip(16-3*np.abs(rg)-np.maximum(0,gb-2)*2,0,16)
    shadow_mix = (np.clip(36-region_y,0,12)*neutral+8)//16
    shadow_mix = (shadow_mix*(4+np.minimum(12,3*np.abs(delta)))+8)//16
    plane_bias = np.clip(-delta,-12,12)-14
    lum += (shadow_mix*plane_bias+8)//16
    # Preserve a bounded amount of local opponent-color contrast.
    red_green += (np.clip(-diff_rg,-3,3)*structure+8)//16
    # Rounding the broad exposure adds one coherent warm middle level. Blend
    # only its rounding residual, up to four luma codes, into the surface.
    broad_y = center_y + delta
    rounded = 8*((broad_y+6)//8)-2
    lit_weight = (warm*np.clip(2*(broad_y-55),0,16)+8)//16
    lum += ((rounded-broad_y)*lit_weight+8)//16
    warm_exposure = broad_y + wr - wb
    plane_offset = np.where(warm_exposure < 93, -5, np.where(warm_exposure >= 99, 4, 0))
    lum += (plane_offset*lit_weight+8)//16
    # Broad warm highlights share a local chroma ceiling across adjacent pixels.
    warmth = np.clip(2*(wr - wb - 34), 0, 14)
    shoulder = (warmth*lit_weight + 8)//16
    red_green -= shoulder
    green_blue -= shoulder
    # Retain olive planes when the broad green-blue contrast and the signed
    # center-to-context luminance support a different local color.
    olive_plane = np.clip(wg-wb-3, 0, 4) * np.clip(4-2*(wr-wg), 0, 4)
    olive_plane = olive_plane*np.clip(72-broad_y, 0, 16)//16
    olive_luma = np.clip(2*(wg-wb-10), -12, 2)
    olive_chroma = np.clip(-2*delta, -9, 9)
    lum += (olive_luma*olive_plane + 8)//16
    red_green += (olive_chroma*olive_plane + 8)//16
    green_blue += (olive_chroma*olive_plane + 8)//16
    # Keep quarter-code exposure when the dark sector differs from its broad
    # surround. Bound each opponent and luma change before reconstructing RGB.
    center_q2 = r + 2*g + b
    broad_q2 = wr + 2*wg + wb
    exposure = (center_q2 + broad_q2 + 1)//2
    relief = center_q2 - broad_q2
    low_chroma = np.clip(16-4*np.maximum(np.abs(wr-wg), np.abs(wg-wb)-1), 0, 16)
    shadow_weight = np.minimum(np.clip(2*(36-broad_y), 0, 16), low_chroma)
    polarity = np.clip(3*relief, 0, 16)
    brightness = np.clip(2*(exposure-87), 0, 16)
    ridge_weight = polarity*brightness*np.clip(16-4*(wr-wb), 0, 16)//256
    cool_relief = np.clip(90-exposure, 0, 9)//3 + (np.clip(relief-2,-6,6)*ridge_weight+8)//16
    cool_chroma = (2*ridge_weight+8)//16
    lum += (cool_relief*shadow_weight+8)//16
    green_blue += (cool_chroma*shadow_weight+8)//16
    green = lum + (green_blue-red_green+2)//4
    color = np.clip(np.stack((green+red_green, green, green-green_blue), axis=-1), 0, 255)

    color = np.clip(color+(np.minimum(128, color+16)*stroke[..., None]+64)//128, 0, 255)
    dark_crest = (np.clip((34-center_y)*2, 0, 16)*np.clip(light-dark-3, 0, 44)+8)//16
    return np.clip(color+(np.minimum(72, color+24)*dark_crest[..., None]+32)//64, 0, 255).astype(np.int16)
