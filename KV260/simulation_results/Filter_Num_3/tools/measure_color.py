"""Measure native BMP color transfer using the supplied PIC1 reference and both PIC2 captures."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def read_rgb(path):
    with Image.open(path) as image:
        return np.asarray(image.convert('RGB'), dtype=np.int32)


def y1000(rgb):
    return 299 * rgb[..., 0] + 587 * rgb[..., 1] + 114 * rgb[..., 2]


def summarize(rgb):
    y = y1000(rgb)
    bright = rgb[y >= np.percentile(y, 90)]
    bins = np.bincount((y // 16000).ravel(), minlength=16)
    frac = bins / y.size
    hist = frac[frac > 0]
    return {
        'width': rgb.shape[1], 'height': rgb.shape[0], 'pixels': y.size,
        'mean_y': float(y.mean()/1000), 'median_y': float(np.median(y)/1000),
        'p10_p90_y': (np.percentile(y,[10,90])/1000).tolist(),
        'pure_white_percent': float(100*np.all(rgb == 255, axis=2).mean()),
        'near_white_percent_y_ge_250': float(100*(y >= 250000).mean()),
        'any_channel_255_percent': float(100*np.any(rgb == 255, axis=2).mean()),
        'highlight_mean_rgb': bright.mean(axis=0).tolist(),
        'highlight_mean_r_minus_b': float((bright[:,0]-bright[:,2]).mean()),
        'midtone_percent_64_to_191': float(100*((y >= 64000) & (y < 192000)).mean()),
        'effective_luma_bands_of_16': float(2**(-np.sum(hist*np.log2(hist)))),
        'luma_band_percent': (100*frac).tolist(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', type=Path, help='also save the measurements as JSON')
    args = parser.parse_args()
    paths = {'pic1_reference': ROOT/'reference/PIC1_filtered.bmp',
             'pic2_before': ROOT/'reference/PIC2_filtered_before.bmp',
             'pic2_corrected': ROOT/'results/PIC2_filtered.bmp'}
    frames = {name: read_rgb(path) for name,path in paths.items()}
    data = {name: summarize(frame) for name,frame in frames.items()}
    for name, path in paths.items():
        data[name]['sha256_bmp'] = hashlib.sha256(path.read_bytes()).hexdigest()
    data['pic1_simulation_byte_identical'] = (ROOT/'results/PIC1_filtered.bmp').read_bytes() == paths['pic1_reference'].read_bytes()
    data['gap_before'] = data['pic2_before']['mean_y'] - data['pic1_reference']['mean_y']
    data['gap_after'] = data['pic2_corrected']['mean_y'] - data['pic1_reference']['mean_y']
    white = np.all(frames['pic2_before'] == 255, axis=2)
    data['old_pure_white_pixels'] = int(white.sum())
    if white.any():
        data['new_luma_p10_p50_p90_over_old_white_pixels'] = (np.percentile(y1000(frames['pic2_corrected'])[white],[10,50,90])/1000).tolist()
    result = json.dumps(data, indent=2)+'\n'
    print(result, end='')
    if args.json:
        args.json.write_text(result, encoding='utf-8')


if __name__ == '__main__':
    main()
