"""Measurements of medium-scale color transitions for same-coordinate RGB8 frames."""

import numpy as np
from scipy.ndimage import gaussian_filter, maximum_filter


def surface_features(rgb):
    """Measure smooth flank-to-flank contrast and signed opponent-color detail."""
    # Process channels separately to limit the peak memory cost of a full frame.
    channels = []
    contrast = np.zeros(rgb.shape[:2], dtype=np.float32)
    for i in range(3):
        fine = gaussian_filter(rgb[..., i].astype(np.float32), 2.5, mode='nearest')
        outer = gaussian_filter(rgb[..., i].astype(np.float32), 9.0, mode='nearest')
        channels.append(fine - outer)
        for axis in (0, 1):
            n = rgb.shape[axis]
            idx = np.arange(n)
            left = np.take(fine, np.maximum(0, idx-6), axis=axis)
            right = np.take(fine, np.minimum(n-1, idx+6), axis=axis)
            np.maximum(contrast, np.abs(left-right), out=contrast)
    r, g, b = channels
    band_y = 0.2126*r + 0.7152*g + 0.0722*b
    y = (0.2126*rgb[...,0] + 0.7152*rgb[...,1] + 0.0722*rgb[...,2]).astype(np.float32)
    fine_y = y - gaussian_filter(y, 1.2, mode='nearest')
    active = np.where(band_y >= 2, 1, np.where(band_y <= -2, -1, 0)).astype(np.int8)
    # Test eight same-polarity neighbors four pixels from the active center.
    h, w = active.shape
    pad = np.pad(active, 4, mode='edge')
    votes = np.zeros_like(active)
    for dy in (0, 4, 8):
        for dx in (0, 4, 8):
            if dy != 4 or dx != 4:
                votes += (pad[dy:dy+h, dx:dx+w] == active)
    coherent = np.where(votes >= 4, active, 0).astype(np.int8)
    return {
        'transition': (contrast >= 6.0) & (contrast <= 24.0),
        'band_y': band_y,
        'fine_y': fine_y,
        'coherent': coherent,
        'band_rg': r-g,
        'band_gb': g-b,
    }


def surface_mask(reference_edges):
    """Use one reference-defined evaluation area for every candidate."""
    return maximum_filter(reference_edges, size=17, mode='nearest') == 0


def surface_scores(candidate, reference, selected):
    """Score transition coverage/location and signed band error in a fixed mask."""
    a = candidate['transition'][selected]
    b = reference['transition'][selected]
    n = int(a.size)
    counts = int(a.sum()), int(b.sum())
    hit = int(np.count_nonzero(a & b))
    def average(key):
        delta = candidate[key][selected] - reference[key][selected]
        return float(np.abs(delta).mean()) if n else None
    chroma = None if not n else (average('band_rg') + average('band_gb')) / 2
    signs_a = candidate['coherent'][selected]
    signs_b = reference['coherent'][selected]
    support_n = int(np.count_nonzero(signs_a)) + int(np.count_nonzero(signs_b))
    sign_hits = int(np.count_nonzero((signs_a != 0) & (signs_a == signs_b)))
    def rms(source, key):
        return round(float(np.sqrt(np.mean(np.square(source[key][selected])))), 5) if n else None
    return {
        'surface_pixel_count': n,
        'candidate_surface_fine_rms': rms(candidate, 'fine_y'),
        'reference_surface_fine_rms': rms(reference, 'fine_y'),
        'candidate_surface_medium_rms': rms(candidate, 'band_y'),
        'reference_surface_medium_rms': rms(reference, 'band_y'),
        'candidate_coherent_pct': round(100*np.count_nonzero(signs_a)/n, 5) if n else None,
        'reference_coherent_pct': round(100*np.count_nonzero(signs_b)/n, 5) if n else None,
        'coherent_polarity_f1': round(2*sign_hits/support_n, 6) if support_n else None,
        'candidate_transition_pct': round(100*counts[0]/n, 5) if n else None,
        'reference_transition_pct': round(100*counts[1]/n, 5) if n else None,
        'surface_transition_f1': round(2*hit/sum(counts), 6) if sum(counts) else None,
        'surface_luma_band_mae': round(average('band_y'), 5) if n else None,
        'surface_chroma_band_mae': round(chroma, 5) if n else None,
    }


def flat_components(flat):
    """Area of the largest flat interior and count of medium interiors in this ROI."""
    from scipy.ndimage import label
    components, n = label(flat, structure=np.ones((3, 3), dtype=bool))
    sizes = np.bincount(components.ravel(), minlength=n+1)[1:]
    mid = (sizes >= 32) & (sizes <= 1024)
    return {
        'largest_flat_component_pct': round(100*float(sizes.max())/flat.size, 5) if n else 0.,
        'medium_flat_component_count': int(mid.sum()),
    }

def medium_patch_match(candidate_sign, reference_sign, mask):
    """Mean best same-sign IoU for connected reference patches in a fixed crop."""
    from scipy.ndimage import label

    iou_sum = 0.0
    count = 0
    for sign in (-1, 1):
        cand, nc = label((candidate_sign == sign) & mask, structure=np.ones((3, 3)))
        ref, nr = label((reference_sign == sign) & mask, structure=np.ones((3, 3)))
        area_c = np.bincount(cand.ravel(), minlength=nc+1)
        area_r = np.bincount(ref.ravel(), minlength=nr+1)
        medium = (area_r >= 32) & (area_r <= 1024)
        medium[0] = False
        both = medium[ref] & (cand != 0)
        # Encode only overlapping positive component labels. A candidate of any
        # size can match, so a broad merged region is charged its entire area.
        pairs, common = np.unique(ref[both].astype(np.int64)*(nc+1)+cand[both], return_counts=True)
        rr, cc = np.divmod(pairs, nc+1)
        best = np.zeros(nr+1)
        np.maximum.at(best, rr, common / (area_r[rr]+area_c[cc]-common))
        iou_sum += best[medium].sum()
        count += int(medium.sum())
    return {'reference_medium_signed_patches': count,
            'mean_best_medium_patch_iou': round(float(iou_sum / count), 6) if count else None}

# These regions have fixed photograph coordinates. They are used only for evaluation.
HAIR_BOX = (700, 150, 910, 310)
EYE_BOX = (1170, 375, 1300, 529)


def anatomical_features(rgb):
    """A hair-interior highlight mask and a vertical luminance profile of the brow and eye."""
    from scipy.ndimage import label

    def smooth_roi(box, sigma):
        x0, y0, x1, y1 = box
        pad = 16  # exceeds SciPy's kernel radius for the selected sigma values
        patch = rgb[y0-pad:y1+pad, x0-pad:x1+pad].astype(np.float32)
        return gaussian_filter(patch, (sigma, sigma, 0), mode='nearest')[pad:-pad,pad:-pad]

    hair = smooth_roi(HAIR_BOX, 2.5)
    r, g, b = np.moveaxis(hair, -1, 0)
    y = .2126*r+.7152*g+.0722*b
    highlight = (y >= 30) & (g-r >= 16) & (b-r >= 22)
    components, n = label(highlight, structure=np.ones((3, 3), dtype=bool))
    sizes = np.bincount(components.ravel(), minlength=n+1)[1:]
    keep = np.r_[False, sizes >= 64]
    eye = smooth_roi(EYE_BOX, 2)
    eye_y = .2126*eye[...,0] + .7152*eye[...,1] + .0722*eye[...,2]
    eye_profile = eye_y.mean(axis=1)
    def column_band(top, bottom):
        return eye_y[top-EYE_BOX[1]:bottom-EYE_BOX[1]].mean(axis=0)
    skin_gap = column_band(443, 452) - np.maximum(column_band(420, 430), column_band(460, 468))
    return {'highlight': keep[components], 'highlight_count': int((sizes >= 64).sum()),
            'largest_highlight_pct': round(100*float(sizes.max())/y.size, 5) if np.any(keep) else 0.,
            'eye_profile': eye_profile, 'skin_gap': skin_gap}


def anatomical_scores(candidate, reference):
    hair = candidate['highlight']
    ref_hair = reference['highlight']
    n = int(hair.sum()) + int(ref_hair.sum())
    eye = candidate['eye_profile']
    ref_eye = reference['eye_profile']
    # All rows below are absolute image coordinates inside EYE_BOX.
    def strip(y0, y1):
        return float(eye[y0-EYE_BOX[1]:y1-EYE_BOX[1]].mean())
    skin = strip(443, 452)
    return {
        'eye_median_column_gap': round(float(np.median(candidate['skin_gap'])), 5),
        'eye_column_gap_mae': round(float(np.mean(np.abs(candidate['skin_gap']-reference['skin_gap']))), 5),
        'eye_brow_mean_luma': round(strip(420, 430), 5),
        'eye_skin_mean_luma': round(skin, 5),
        'eye_upper_lid_mean_luma': round(strip(460, 468), 5),
        'eye_skin_minus_brow_luma': round(skin - strip(420, 430), 5),
        'eye_skin_minus_lid_luma': round(skin - strip(460, 468), 5),
        'hair_highlight_coverage_pct': round(100*float(hair.mean()), 5),
        'largest_hair_highlight_pct': candidate['largest_highlight_pct'],
        'hair_highlight_count': candidate['highlight_count'],
        'hair_highlight_shape_f1': round(2*int((hair & ref_hair).sum())/n, 6) if n else None,
        'eye_vertical_profile_mae': round(float(np.abs(eye-ref_eye).mean()), 5),
        'eye_four_row_contrast_mae': round(float(np.abs((eye[4:]-eye[:-4])-(ref_eye[4:]-ref_eye[:-4])).mean()), 5),
    }
