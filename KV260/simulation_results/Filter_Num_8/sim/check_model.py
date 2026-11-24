"""Independent raster arithmetic check using the decoded stimulus and accepted RGB10 output words."""
import argparse
import ast
import re
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def color_axes(rgb):
    red, green, blue = [rgb[..., i] for i in range(3)]
    return np.stack(((red + 2*green + blue + 2)//4, red-green, green-blue), axis=-1)


def tile_means(image, side):
    height, width = image.shape[:2]
    ys = np.arange(0, height, side)
    xs = np.arange(0, width, side)
    rows = np.add.reduceat(image, ys, axis=0, dtype=np.int32)
    sums = np.add.reduceat(rows, xs, axis=1, dtype=np.int32)
    counts = np.minimum(height-ys, side)[:, None] * np.minimum(width-xs, side)[None, :]
    return ((sums + counts[:, :, None]//2) // counts[:, :, None]).astype(np.int32)


def interpolate(tiles, side, x, y):
    def bounds(position, size):
        offset = position - side//2
        lower = offset//side
        return lower.clip(0, size-1), (lower+1).clip(0, size-1), (offset%side)[:, None]

    def mix(first, second, phase):
        return (first*(side-phase) + second*phase + side//2)//side

    x0, x1, px = bounds(x, tiles.shape[1])
    y0, y1, py = bounds(y, tiles.shape[0])
    a, b, c, d = tiles[y0,x0], tiles[y0,x1], tiles[y1,x0], tiles[y1,x1]
    rgbt = mix(mix(a,b,px), mix(c,d,px), py)
    a, b, c, d = [color_axes(v)[:, :2] for v in (a,b,c,d)]
    horizontal = mix(b-a, d-c, py)
    vertical = mix(c-a, d-b, px)
    slopes = np.column_stack((horizontal[:,0], vertical[:,0], horizontal[:,1], vertical[:,1]))
    return rgbt, slopes


def coefficients():
    source = (ROOT / 'rtl/portrait_coefficients.vhd').read_text()

    def value(name):
        match = re.search(r'constant '+name+r'\b[^;]*?:=\s*(.*?);', source, re.S)
        if match is None:
            raise ValueError(f'Missing coefficient {name}')
        return ast.literal_eval(match.group(1))

    # Integer-valued doubles are exact for all bounded 32-bit dot products and
    # let NumPy use its optimized matrix multiplication for a full video frame.
    return [(np.ascontiguousarray(np.array(value(f'W{i}'),dtype=np.float64).T),
             np.array(value(f'B{i}')), value(f'FRACTION{i}')) for i in (1,2,3)]


def finish_stages():
    text = (ROOT / 'rtl/portrait_types.vhd').read_text()
    def sequence(name):
        return ast.literal_eval(re.search(r'constant '+name+r'\b[^;]*?:=\s*(.*?);',text,re.S).group(1))
    return zip(sequence('FINISH_SPACING'),sequence('FINISH_THRESHOLD'))


def smooth_range(rgb, spacing, threshold):
    height, width = rgb.shape[:2]
    padded = np.pad(rgb, ((spacing,spacing),(spacing,spacing),(0,0)), mode='edge')
    output = np.empty_like(rgb)
    for y in range(0,height,32):
        end = min(height,y+32)
        center = rgb[y:end]
        center_y = color_axes(center)[...,0]
        adjustment = np.zeros_like(center)
        for dy in (-spacing,0,spacing):
            for dx in (-spacing,0,spacing):
                if dx == 0 and dy == 0:
                    continue
                other = padded[y+spacing+dy:end+spacing+dy,spacing+dx:spacing+dx+width]
                delta = other-center
                spread = np.max(np.abs(delta),axis=2)
                distance = np.maximum(np.abs(color_axes(other)[...,0]-center_y),(spread+1)//2)
                weight = ((threshold-distance+3)//4).clip(0,16)
                adjustment += delta*weight[...,None]
        output[y:end] = center + (adjustment+64)//128
    return output


def check(decoded, trace, frames=1, low_bits=False):
    with Image.open(decoded) as image:
        source = np.array(image.convert('RGB'), dtype=np.int32)
    height, width = source.shape[:2]
    words = np.fromfile(trace, dtype='<u4')
    if words.size != width*height*frames:
        raise ValueError(f'Expected {width*height*frames} transfer words, received {words.size}')
    words = words.reshape(frames,-1)
    layers = coefficients()
    mismatches = 0
    for frame in range(frames):
        raw = (source if frame == 0 else 255-np.roll(source,-1,axis=-1))*4
        if low_bits:
            ids = np.arange(width*height,dtype=np.int32).reshape(height,width,1)
            raw += (ids + np.arange(3,dtype=np.int32) + frame + 1)%4
        luma = color_axes(raw)[...,0]
        previous = np.concatenate((luma[:,:1],luma[:,:-1]),axis=1)
        texture = np.minimum(1023,8*np.abs(luma-previous))
        planes = np.concatenate((raw,texture[...,None]),axis=2)
        sizes = (4,16,64)
        tiles = [tile_means(planes,side) for side in sizes]
        graded = np.empty_like(raw)
        for row in range(0,height,24):
            ids = np.arange(row*width,min(height,row+24)*width)
            y, x = np.divmod(ids,width)
            samples = [interpolate(t,side,x,y) for t,side in zip(tiles,sizes)]
            (p4,g4),(p16,g16),(p64,g64) = samples
            a,b,c = [color_axes(p) for p in (p4,p16,p64)]
            feature = np.column_stack((color_axes(raw[y,x])-a, a, b-a, c-b,
                                       p4[:,3],p16[:,3],p64[:,3],g4,g16,g64)).astype(np.float64)
            for idx,(weight,bias,shift) in enumerate(layers):
                feature = np.floor((feature@weight + bias + 2**(shift-1)) / 2**shift)
                feature = feature.clip(0,16383) if idx<2 else feature.clip(-2048,2047)
            output = (feature.astype(np.int32)+p4[:,:3]).clip(0,1023)
            graded.reshape(-1,3)[ids] = output
        for spacing,threshold in finish_stages():
            graded = smooth_range(graded,spacing,threshold)
        flat = graded.reshape(-1,3)
        packed = (flat[:,0]<<20) | (flat[:,1]<<10) | flat[:,2]
        different = int(np.count_nonzero(packed != words[frame]))
        print(f'Frame {frame+1} independent RGB10 model: {different:,} mismatched words / {width*height:,}')
        mismatches += different
    return mismatches == 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('decoded', type=Path)
    parser.add_argument('trace', type=Path)
    parser.add_argument('--frames', type=int, choices=(1,2), default=1)
    parser.add_argument('--low-bits', action='store_true')
    options = parser.parse_args()
    raise SystemExit(0 if check(options.decoded,options.trace,options.frames,options.low_bits) else 1)
