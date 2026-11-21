"""Exercise a known curved boundary and a noisy gray ramp through the RGB10 wrapper.
Run from any directory with GHDL, NumPy and Pillow. Outputs are saved under
results/curve_test by default. Coordinates are in image pixels.
"""
import argparse
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def curve_target(folder):
    height, width = 176, 512
    y, x = np.ogrid[:height, :width]
    # A continuous antialiased step with a crest, a trough and a sloped segment.
    edge_y = 91 + 18 * np.sin(2*np.pi*x[0]/226)
    ramp = 76 + x/18
    transition = np.clip((y-edge_y+1.25)/2.5, 0, 1)
    rng = np.random.default_rng(477)
    noise = rng.normal(0, 3, size=(height, width))
    # The lower curve is a separate two-pixel-wide antialiased dark stroke.
    thin_y = 143 + 11*np.sin(2*np.pi*x[0]/99)
    coverage = np.clip(1.5 - np.abs(y-thin_y), 0, 1)
    gray = np.rint(ramp + 88*transition - 60*coverage + noise).clip(0, 255).astype(np.uint8)
    Image.fromarray(gray).save(folder/'curve.jpg', quality=100)
    return edge_y, thin_y


def measure(path, edge_y, thin_y):
    gray = np.asarray(Image.open(path).convert('L'), dtype=np.float64)
    x = np.arange(12, gray.shape[1]-12)
    # Fit and subtract the intended sloping surface so its gradient does not
    # contribute to the measured shading noise. Exclude all sides and the curve.
    patch = gray[12:52, x]
    slope, intercept = np.polyfit(x, patch.mean(axis=0), 1)
    rms = np.sqrt(np.mean((patch - (slope*x+intercept))**2))
    y = np.rint(edge_y[x]).astype(int)
    # Local dark-side plateau and local minimum within +/-3 px of the known edge.
    plateau = np.median(gray[y[None, :] + np.arange(-13, -6)[:, None], x], axis=0)
    offsets = np.arange(-3, 4)
    strip = gray[y[None, :] + offsets[:, None], x]
    dip = plateau - strip.min(axis=0)
    # Detect ink only if it is >=10 gray levels darker than the local dark side.
    ink = dip >= 10
    missing = np.flatnonzero(np.diff(np.r_[False, ~ink, False]))
    longest_gap = int(np.diff(missing.reshape(-1, 2), axis=1).max()) if missing.size else 0
    yy = np.rint(thin_y[x]).astype(int)
    line_bg = np.median(gray[yy[None, :] + np.arange(8, 14)[:, None], x], axis=0)
    line = gray[yy[None, :] + np.arange(-2, 3)[:, None], x].min(axis=0)
    thin_present = int(np.count_nonzero(line_bg-line >= 15))
    return rms, int(ink.sum()), ink.size, longest_gap, float(np.median(dip)), thin_present


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--outdir', type=Path, default=ROOT/'results/curve_test')
    args = parser.parse_args()
    folder = args.outdir.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    edge_y, thin_y = curve_target(folder)
    subprocess.run([sys.executable, str(ROOT/'sim/run_ghdl.py'), str(folder/'curve.jpg'),
                    '--output', str(folder/'filtered.bmp'), '--decoded-bmp', str(folder/'decoded.bmp'),
                    '--rgb10', '--stalls', '--build', str(ROOT/'build/ghdl_curve')], check=True)
    subprocess.run([sys.executable, str(ROOT/'tools/check_pixels.py'), str(folder/'decoded.bmp'),
                    str(folder/'filtered.bmp')], check=True)
    before = measure(folder/'decoded.bmp', edge_y, thin_y)
    after = measure(folder/'filtered.bmp', edge_y, thin_y)
    for name, (rms, linked, cols, gap, dip, thin) in [('Input', before), ('Output', after)]:
        print(f'{name}: detrended flat-ramp RMS {rms:.3f} gray levels; ink detected in '
              f'{linked}/{cols} columns; longest missing run {gap} columns; median ink depth {dip:.1f} levels; '
              f'two-pixel curved stroke retained in {thin}/{cols} columns')
    if after[0] >= before[0] or after[1] < 0.98*after[2] or after[3] > 2 or after[5] != after[2]:
        raise SystemExit('Shading or curve continuity check failed')
    print('PASS: smooth ramp and continuous curved contour.')


if __name__ == '__main__':
    main()
