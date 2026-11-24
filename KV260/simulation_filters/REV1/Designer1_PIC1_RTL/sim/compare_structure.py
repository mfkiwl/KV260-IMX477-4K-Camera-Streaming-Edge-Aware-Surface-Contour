"""Compare same-coordinate RGB crops and structural measurements at native resolution.

Dependencies: NumPy, SciPy and Pillow. The reference is used strictly for scoring.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.ndimage import distance_transform_edt, maximum_filter, minimum_filter, sobel, gaussian_filter, label

from surface_metrics import surface_features, surface_mask, surface_scores, flat_components

CROP_W, CROP_H = 320, 176
REGIONS = {
    'Eye and brow': (1072, 365),
    'Upper hair': (988, 12),
    'Forehead': (1040, 172),
    'Ear': (665, 412),
    'Nose and nostrils': (1280, 565),
    'Lips and lower face': (1232, 780),
    'Hair highlights': (825, 68),
    'Cheek': (930, 545),
    'Jacket collar': (705, 880),
    'Jaw and chin': (1200, 930),
    'Chair logo': (230, 564),
    'Background': (60, 70),
}
EDGE_MIN = 8.0
RADIUS = 2
FLAT_RANGE = 4


def analyze(rgb):
    # Luminance over display-coded RGB8; /8 normalizes the Sobel derivative.
    y = (.2126*rgb[...,0] + .7152*rgb[...,1] + .0722*rgb[...,2]).astype(np.float32)
    gx = sobel(y, axis=1, mode='nearest') / 8
    gy = sobel(y, axis=0, mode='nearest') / 8
    mag = np.hypot(gx, gy)
    angle = (np.arctan2(gy,gx) * (4/np.pi) + .5)
    sector = (np.floor(angle).astype(np.int8) % 4)
    strong = np.zeros_like(y, dtype=bool)
    # Nonmaximum suppression, four directions and deterministic tie-breaking.
    pads = np.pad(mag,1,mode='edge')
    h,w = mag.shape
    for i,(dy,dx) in enumerate(((0,1),(1,1),(1,0),(1,-1))):
        n1 = pads[1+dy:1+dy+h,1+dx:1+dx+w]
        n2 = pads[1-dy:1-dy+h,1-dx:1-dx+w]
        strong |= (sector==i) & (mag >= EDGE_MIN) & (mag >= n1) & (mag > n2)
    # Reject a spurious derivative at the outer border. Geometric crops are interior.
    strong[[0,-1],:]=False
    strong[:,[0,-1]]=False
    components, count = label(strong, structure=np.ones((3, 3), dtype=bool))
    sizes = np.bincount(components.ravel(), minlength=count+1)
    keep = sizes >= 24
    keep[0] = False
    long_edges = keep[components]
    short = (sizes>=1) & (sizes<=8)
    fragments = short[components]
    near_long = (distance_transform_edt(~long_edges) <= RADIUS if np.any(long_edges)
                 else np.zeros_like(long_edges))
    window = (5,5,1)
    span = maximum_filter(rgb, size=window, mode='nearest') - minimum_filter(rgb, size=window, mode='nearest')
    flat = span.max(axis=-1) <= FLAT_RANGE
    dist = distance_transform_edt(~strong) if np.any(strong) else np.full(strong.shape,np.inf,np.float32)
    band = gaussian_filter(y, 1.8, mode='nearest') - gaussian_filter(y, 6, mode='nearest')
    src = rgb.astype(np.int16)
    center = (src[...,0]+2*src[...,1]+src[...,2]+2)//4
    padded = np.pad(center, 1, mode='edge')
    neighbors = np.stack((padded[1:-1,:-2],padded[1:-1,2:],padded[:-2,1:-1],padded[2:,1:-1]))
    extremum = (center >= neighbors.max(0)+3) | (center <= neighbors.min(0)-3)
    return {'rgb':rgb, 'mag':mag, 'edges':strong, 'near':dist <= RADIUS, 'flat':flat,
            'fragments':fragments, 'dark_point':center<=neighbors.min(0)-3, 'medium_band':band, 'extremum':extremum, 'long':long_edges, 'near_long':near_long}


def measure(candidate, reference, candidate_surface, reference_surface, reference_area):
    records={}
    for region, xy in {'Whole frame':None, **REGIONS}.items():
        cut = (slice(None),slice(None))
        if xy:
            x,y=xy
            cut=(slice(y,y+CROP_H),slice(x,x+CROP_W))
        a = candidate['edges'][cut]
        b = reference['edges'][cut]
        # Match centers independently. A center outside the ROI can provide the
        # nearest match for one on its boundary. This is not a one-to-one assignment.
        n_a, n_b = int(a.sum()),int(b.sum())
        precision = float(np.count_nonzero(a & reference['near'][cut]) / n_a) if n_a else 0.
        recall = float(np.count_nonzero(b & candidate['near'][cut]) / n_b) if n_b else 0.
        f1=2*precision*recall/(precision+recall) if precision+recall else 0.
        long_a, long_b = candidate['long'][cut], reference['long'][cut]
        n_long_a, n_long_b = int(long_a.sum()), int(long_b.sum())
        long_p = float((long_a & reference['near_long'][cut]).sum()) / max(1, n_long_a)
        long_r = float((long_b & candidate['near_long'][cut]).sum()) / max(1, n_long_b)
        long_f = 2*long_p*long_r/(long_p+long_r) if long_p+long_r else 0.
        d=candidate['rgb'][cut].astype(np.int16)-reference['rgb'][cut]
        mse=float(np.mean(np.square(d,dtype=np.float64)))
        records[region]={
            'pixel_count':int(a.size), 'exact_rgb_pixels':int(np.all(d==0,axis=-1).sum()),
            'rgb_mae':round(float(np.abs(d).mean()),6),
            'rgb_psnr_db':round(10*math.log10(255**2/mse),6) if mse else None,
            'candidate_short_edge_pixels':int(candidate['fragments'][cut].sum()),
            'reference_short_edge_pixels':int(reference['fragments'][cut].sum()),
            'candidate_isolated_dark_pixels':int(candidate['dark_point'][cut].sum()),
            'reference_isolated_dark_pixels':int(reference['dark_point'][cut].sum()),
            'candidate_edges':n_a,'reference_edges':n_b,
            'candidate_connected_edge_pixels':n_long_a,'reference_connected_edge_pixels':n_long_b,
            'connected_precision':round(long_p,6),'connected_recall':round(long_r,6),'connected_f1':round(long_f,6),
            'candidate_edge_density_pct':round(100*n_a/a.size,5),
            'reference_edge_density_pct':round(100*n_b/a.size,5),
            'edge_precision':round(precision,6),'edge_recall':round(recall,6),'edge_f1':round(f1,6),
            'gradient_magnitude_mae':round(float(np.abs(candidate['mag'][cut]-reference['mag'][cut]).mean()),6),
            'candidate_isolated_extrema':int(candidate['extremum'][cut].sum()),
            'reference_isolated_extrema':int(reference['extremum'][cut].sum()),
            'candidate_medium_rms':round(float(np.sqrt(np.mean(candidate['medium_band'][cut]**2))),5),
            'reference_medium_rms':round(float(np.sqrt(np.mean(reference['medium_band'][cut]**2))),5),
            'candidate_flat_pct':round(100*float(candidate['flat'][cut].mean()),5),
            'reference_flat_pct':round(100*float(reference['flat'][cut].mean()),5),
        }
        for bank, prefix in ((candidate, 'candidate_'), (reference, 'reference_')):
            records[region].update({prefix+k: v for k,v in flat_components(bank['flat'][cut]).items()})
        region_a = {key: value[cut] for key, value in candidate_surface.items()}
        region_b = {key: value[cut] for key, value in reference_surface.items()}
        records[region].update(surface_scores(region_a, region_b, reference_area[cut]))
    return records


def font(size, bold=False):
    for path in (Path('/usr/share/fonts/truetype/dejavu/DejaVuSans'+('-Bold' if bold else '')+'.ttf'), 'DejaVuSans.ttf'):
        try:return ImageFont.truetype(str(path),size)
        except OSError:pass
    return ImageFont.load_default()


def make_sheet(images, out, before, after):
    left=25; gap=8; top=114; label_h=38; overview_h=180
    page_w=2*left+len(images)*CROP_W+(len(images)-1)*gap
    page_h=top+overview_h+len(REGIONS)*(label_h+CROP_H)+32
    page=Image.new('RGB',(page_w,page_h),'#F4F3EF')
    draw=ImageDraw.Draw(page)
    ink='#162A31'; dim='#42565D'
    draw.text((left,16),'PIC1  |  Medium-scale surfaces and contours',font=font(31,True),fill=ink)
    draw.text((left,57),'Full frame above each column. Detail crops below use the same coordinates and show one source pixel per image pixel.',font=font(16),fill=dim)
    for i,(name,image) in enumerate(images.items()):
        x=left+i*(CROP_W+gap);draw.text((x,87),name,font=font(19,True),fill=ink)
        page.paste(image.resize((CROP_W,overview_h),Image.Resampling.LANCZOS),(x,top))
    y0=top+overview_h
    for name,(cx,cy) in REGIONS.items():
        draw.text((left,y0+8),name,font=font(19,True),fill=ink)
        draw.text((left+232,y0+10),f'x {cx}    y {cy}    |    {CROP_W} × {CROP_H} pixels',font=font(15),fill=dim)
        a, b = before[name], after[name]
        draw.text((left+565, y0+10),
                  f"12 px surface transitions    Previous {a['candidate_transition_pct']:.1f}%    "
                  f"Revised {b['candidate_transition_pct']:.1f}%    Designer1 {b['reference_transition_pct']:.1f}%",
                  font=font(15), fill=dim)
        for i,image in enumerate(images.values()):
            x0=left+i*(CROP_W+gap)
            page.paste(image.crop((cx,cy,cx+CROP_W,cy+CROP_H)),(x0,y0+label_h))
        y0+=label_h+CROP_H
    page.save(out,optimize=True)


def main():
    q=argparse.ArgumentParser(description=__doc__)
    for name in ('source','prior','reference','out'):q.add_argument('--'+name,type=Path,required=True)
    q.add_argument('--earlier',type=Path)
    q.add_argument('--new',type=Path);q.add_argument('--new-label',default='Medium-scale surfaces')
    args=q.parse_args()
    args.out.mkdir(exist_ok=True,parents=True)
    paths={'Source photograph':args.source}
    if args.earlier:paths['Earlier surface regions']=args.earlier
    paths['Previous directional RTL']=args.prior
    if args.new:paths[args.new_label]=args.new
    paths['Designer1 reference']=args.reference
    images={label:Image.open(path).convert('RGB') for label,path in paths.items()}
    if any(im.size!=(2048,1152) for im in images.values()):raise ValueError('Expected 2048×1152 images')
    reference=analyze(np.asarray(images['Designer1 reference']))
    ref_surface=surface_features(reference['rgb'])
    ref_area=surface_mask(reference['edges'])
    data={'size':[2048,1152],
          'method':{'coordinates':'zero-based x,y relative to upper left of decoded, unregistered images',
                    'luma':'display-coded Y = 0.2126 R + 0.7152 G + 0.0722 B',
                    'strong_edge':'Sobel magnitude divided by 8 >= 8 RGB8 codes/pixel, followed by 4-direction nonmaximum suppression. The frame perimeter is excluded from the binary edge map.',
                    'edge_match':'For each strong candidate center, a reference center within Euclidean distance <= 2 pixels is a hit for precision. Reverse roles for recall. F1 is the harmonic mean. With tolerance, several centers may match one. Edges and distances are computed over the whole image before selecting ROI centers.',
                    'short_edge_pixels':'Number of thinned strong edge centers in eight-connected components of one to eight centers. Whole-frame component labeling before cropping.',
                    'isolated_dark_pixels':'Center luminance is at least three codes below every immediate axial neighbor.',
                    'connected_f1':'Select 8-connected components containing at least 24 thinned strong edge centers independently in candidate and reference. Compute precision/recall/F1 on those retained centers with the same two-pixel tolerance. Connectivity is computed before cropping.',
                    'flat_components':'Label eight-connected components of the 5x5 flat-interior map independently inside each reported ROI. Report largest component area divided by ROI area and count of component areas 32 through 1024 pixels inclusive. Crop edges can truncate a component. Use as a same-crop proxy for overmerging; connected smooth interiors can contain gradients.',
                    'surface_area':'All candidates use positions where the centered 17x17 window contains no thinned strong reference edge center. The mask is computed on the whole frame before cropping.',
                    'transition_pct':'Smooth each RGB8 channel with a Gaussian of sigma 2.5 pixels. At each center compare opposite flanks separated by 12 pixels horizontally and vertically. Take the maximum absolute difference over the six direction/channel combinations. Count positions where the difference is 6 through 24 codes inclusive and divide by surface_area. This measures medium-contrast changes on smoothed surfaces, including soft gradients; it is not a count of distinct patches.',
                    'surface_transition_f1':'Exact-location overlap between candidate and reference 12-pixel surface transitions inside the same reference-defined mask. F1 = 2 times intersection / sum of counts. A null indicates both sets were empty.',
                    'surface_band_mae':'Signed differences of Gaussian responses (sigma 2.5 minus sigma 9, in pixels) are computed per RGB8 channel. Luma band MAE compares the signed luma response against the reference over surface_area. Chroma band MAE averages the absolute errors of red minus green and green minus blue signed band responses. Lower is closer. Local features from the JPEG include effects of compression.',
                    'medium_rms':'RMS of the signed difference of two Gaussian-filtered luminance images at sigma 1.8 and 6.0 pixels, in RGB8 codes. This measures the amount of medium-scale structure.',
                    'isolated_extrema':'Center Y=(R+2G+B+2)//4 is at least three codes higher or lower than all four immediate axial neighbors. Counts also include legitimate point features.',
                    'flat_pct':'Percentage of centers where the maximum minus minimum value is at most 4 codes in each of R, G and B over a 5x5 window. Frame-border samples replicate.',
                    'rgb':'MAE is mean absolute 8-bit RGB channel error. PSNR uses all RGB samples with peak 255. Exact requires all three channels equal. Gradient magnitude MAE uses the normalized Sobel magnitudes before thinning.'},
          'regions_xywh':{k:[x,y,CROP_W,CROP_H] for k,(x,y) in REGIONS.items()},
          'rgb_sha256':{k:hashlib.sha256(im.tobytes()).hexdigest() for k,im in images.items()},
          'measurements':{}}
    for name,im in images.items():
        if name!='Designer1 reference':
            rgb=np.asarray(im)
            data['measurements'][name]=measure(analyze(rgb),reference,surface_features(rgb),ref_surface,ref_area)
    (args.out/'structure_metrics.json').write_text(json.dumps(data,indent=2)+'\n',encoding='utf-8')
    if args.new:
        before=data['measurements']['Previous directional RTL'];after=data['measurements'][args.new_label]
        make_sheet(images,args.out/'PIC1_Structure_Details.png',before,after)
        lines=['Comparison of PIC1 simulator captures with the decoded Designer1 reference',
               'Same coordinates for all frames. Edge F1 uses a two-pixel positional tolerance.',
               'Connected F1 retains only 8-connected components with at least 24 edge centers. Both F1 scores measure correspondence, independently of RGB equality.',
               'Flat area is a coverage statistic. Compare each flat-area percentage with the reference percentage in the same row.',
               '',f"{'Region':20}  {'Edge P prev/new':16} {'Edge R prev/new':16} {'F1 prev/new':16} {'Connected F1':16} {'Flat % prev/new/ref':24} {'RGB MAE prev/new':16}"]
        for name,s in before.items():
            t=after[name]
            def pair(key):return f"{s[key]:.3f} / {t[key]:.3f}"
            lines.append(f"{name:20}  {pair('edge_precision'):16} {pair('edge_recall'):16} {pair('edge_f1'):16} {pair('connected_f1'):16} {s['candidate_flat_pct']:6.2f}/{t['candidate_flat_pct']:6.2f}/{t['reference_flat_pct']:6.2f}     {pair('rgb_mae'):16}")
        lines+=['','Medium-scale surface structure',
                'The same reference-defined mask excludes centers within a 17 x 17 neighborhood of a strong edge.',
                'Surface coverage measures 6–24 code differences between smoothed RGB flanks 12 pixels apart.',
                'Transition F1 compares placement at identical pixels. Signed band errors measure smoothed local luminance and chroma differences.',
                '',f"{'Region':20}  {'Surface % prev/new/art':24} {'Transition F1':16} {'Band luma MAE':16} {'Band chroma MAE':16}"]
        for name,s in before.items():
            t=after[name]
            coverage=f"{s['candidate_transition_pct']:.2f}/{t['candidate_transition_pct']:.2f}/{t['reference_transition_pct']:.2f}"
            def metric(key):
                return ' / '.join('n/a' if v is None else f'{v:.3f}' for v in [s[key],t[key]])
            lines.append(f"{name:20}  {coverage:24} {metric('surface_transition_f1'):16} {metric('surface_luma_band_mae'):16} {metric('surface_chroma_band_mae'):16}")
        lines+=['','Flat-interior sizes in matching crops',
                'Largest is the percentage of crop pixels occupied by the largest connected 5x5-flat interior.',
                'Medium counts 8-connected flat interiors containing 32–1,024 pixels. Each crop is labeled independently.',
                '',f"{'Region':20}  {'Largest % prev/new/art':27} {'Medium count prev/new/art'}"]
        for name,s in before.items():
            t=after[name]
            large=f"{s['candidate_largest_flat_component_pct']:.2f}/{t['candidate_largest_flat_component_pct']:.2f}/{t['reference_largest_flat_component_pct']:.2f}"
            mid=f"{s['candidate_medium_flat_component_count']}/{t['candidate_medium_flat_component_count']}/{t['reference_medium_flat_component_count']}"
            lines.append(f"{name:20}  {large:27} {mid}")
        lines+=['','Full-frame RGB comparison', f"The previous output had {before['Whole frame']['exact_rgb_pixels']:,} exact RGB pixels and PSNR {before['Whole frame']['rgb_psnr_db']:.4f} dB.",
                f"The revised output had {after['Whole frame']['exact_rgb_pixels']:,} exact RGB pixels and PSNR {after['Whole frame']['rgb_psnr_db']:.4f} dB.",
                'Both comparisons include 2,359,296 pixels. Per-region detail, thresholds and decoded image hashes are in structure_metrics.json.']
        (args.out/'structure_summary.txt').write_text('\n'.join(lines)+'\n',encoding='utf-8')

if __name__=='__main__':main()
