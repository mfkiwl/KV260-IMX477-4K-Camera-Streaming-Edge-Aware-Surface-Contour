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
    return {
        'transition': (contrast >= 6.0) & (contrast <= 24.0),
        'band_y': 0.2126*r + 0.7152*g + 0.0722*b,
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
    return {
        'surface_pixel_count': n,
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
