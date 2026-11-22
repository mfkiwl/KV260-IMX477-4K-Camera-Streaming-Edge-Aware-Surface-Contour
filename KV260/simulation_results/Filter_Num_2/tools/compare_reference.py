"""Compare unregistered RGB images on the reference raster. Requires Pillow and NumPy."""
import argparse
from pathlib import Path
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
LUMA = np.array([0.299, 0.587, 0.114])


def local_mean(a):
    # Valid 11x11 Gaussian, sigma 1.5; exclude the five-pixel boundary.
    weights = np.exp(-0.5 * (np.arange(-5, 6) / 1.5) ** 2)
    weights /= weights.sum()
    cols = a.shape[1] - 10
    horiz = sum(k * a[:, n:n + cols] for n, k in enumerate(weights))
    rows = a.shape[0] - 10
    return sum(k * horiz[n:n + rows] for n, k in enumerate(weights))


def measure(actual, ref):
    rgb = np.asarray(actual, dtype=np.float64)
    reference = np.asarray(ref, dtype=np.float64)
    error = rgb - reference
    mse = np.square(error).mean()
    y, target = rgb @ LUMA, reference @ LUMA
    a, b = local_mean(y), local_mean(target)
    va = local_mean(y*y) - a*a
    vb = local_mean(target*target) - b*b
    cov = local_mean(y*target) - a*b
    c1, c2 = (0.01*255)**2, (0.03*255)**2
    ssim = ((2*a*b + c1)*(2*cov + c2))/((a*a + b*b + c1)*(va + vb + c2))
    return {'rgb_mae': np.abs(error).mean(), 'luma_mae': np.abs(y-target).mean(),
            'psnr': np.inf if mse == 0 else 10*np.log10(255**2/mse), 'ssim_y': ssim.mean(),
            'channel_mae': np.abs(error).mean((0,1)), 'exact_pixels': int((error==0).all(2).sum()),
            'total_pixels': error.shape[0]*error.shape[1]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('images', type=Path, nargs='*', default=[ROOT/'results/PIC99.bmp'])
    parser.add_argument('--reference', type=Path, default=ROOT/'images/PIC99_reference.PNG')
    args = parser.parse_args()
    ref = Image.open(args.reference).convert('RGB')
    print(f'Reference {args.reference.name}, {ref.width} x {ref.height}, 8-bit RGB; full frame, Pillow Lanczos, no alignment.')
    for filename in args.images:
        rgb = Image.open(filename).convert('RGB').resize(ref.size, Image.Resampling.LANCZOS)
        m = measure(rgb, ref)
        print(f'{filename.name}: RGB MAE {m["rgb_mae"]:.4f}, RGB PSNR {m["psnr"]:.3f} dB, '
              f'luma MAE {m["luma_mae"]:.4f}, luma SSIM {m["ssim_y"]:.5f}.')
        print('  R/G/B MAE ' + ', '.join(f'{v:.4f}' for v in m['channel_mae']) +
              f'; exact RGB pixels {m["exact_pixels"]:,} / {m["total_pixels"]:,}.')


if __name__ == '__main__':
    main()
