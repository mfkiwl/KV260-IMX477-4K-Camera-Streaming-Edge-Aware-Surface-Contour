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
from scipy.ndimage import binary_erosion, distance_transform_edt, maximum_filter, minimum_filter, sobel, gaussian_filter, label

from surface_metrics import surface_features, surface_mask, surface_scores, flat_components, medium_patch_match, anatomical_features, anatomical_scores, CROWN_BOX

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
        if region in ('Cheek', 'Forehead', 'Jacket collar'):
            records[region].update(medium_patch_match(region_a['coherent'], region_b['coherent'], reference_area[cut]))
    return records


def font(size, bold=False):
    for path in (Path('/usr/share/fonts/truetype/dejavu/DejaVuSans'+('-Bold' if bold else '')+'.ttf'), 'DejaVuSans.ttf'):
        try:return ImageFont.truetype(str(path),size)
        except OSError:pass
    return ImageFont.load_default()


def largest_cheek_overlay(im):
    # Include the external two-pixel margin in the 5x5 test, as in the full-frame score.
    x, y = REGIONS['Cheek']
    rgb = np.asarray(im.crop((x-2, y-2, x+CROP_W+2, y+CROP_H+2)))
    window = (5, 5, 1)
    span = maximum_filter(rgb, size=window) - minimum_filter(rgb, size=window)
    flat = span[2:-2, 2:-2].max(axis=2) <= FLAT_RANGE
    ids, n = label(flat, structure=np.ones((3,3), dtype=bool))
    display = rgb[2:-2,2:-2].copy()
    if n:
        selected = ids == 1 + np.bincount(ids.ravel())[1:].argmax()
        display[~selected] = (display[~selected].astype(np.uint16)*3//5).astype(np.uint8)
        display[selected & ~binary_erosion(selected)] = (188, 241, 245)
    return Image.fromarray(display)


def make_sheet(images, out, before, after):
    left=25; gap=8; top=114; label_h=38; overview_h=180
    page_w=2*left+len(images)*CROP_W+(len(images)-1)*gap
    crown_w, crown_h = CROWN_BOX[2]-CROWN_BOX[0], CROWN_BOX[3]-CROWN_BOX[1]
    shown_h = round(crown_h*CROP_W/crown_w)
    page_h=top+overview_h+(len(REGIONS)+1)*(label_h+CROP_H)+label_h+shown_h+32
    page=Image.new('RGB',(page_w,page_h),'#F4F3EF')
    draw=ImageDraw.Draw(page)
    ink='#162A31'; dim='#42565D'
    draw.text((left,16),'PIC1  |  Directional surface regions',font=font(31,True),fill=ink)
    draw.text((left,57),'Each column uses the same coordinates. The full frame and crown are scaled to fit. Other crops show one source pixel per image pixel.',font=font(16),fill=dim)
    for i,(name,image) in enumerate(images.items()):
        x=left+i*(CROP_W+gap);draw.text((x,87),name,font=font(19,True),fill=ink)
        page.paste(image.resize((CROP_W,overview_h),Image.Resampling.LANCZOS),(x,top))
    y0=top+overview_h
    for name,(cx,cy) in REGIONS.items():
        draw.text((left,y0+8),name,font=font(19,True),fill=ink)
        draw.text((left+232,y0+10),f'x {cx}    y {cy}    |    {CROP_W} × {CROP_H} pixels',font=font(15),fill=dim)
        a, b = before[name], after[name]
        draw.text((left+565, y0+10),
                  f"Fine surface variation (RMS luma)    Previous {a['candidate_surface_fine_rms']:.2f}    "
                  f"Revised {b['candidate_surface_fine_rms']:.2f}    Designer1 {b['reference_surface_fine_rms']:.2f}",
                  font=font(15), fill=dim)
        for i,image in enumerate(images.values()):
            x0=left+i*(CROP_W+gap)
            page.paste(image.crop((cx,cy,cx+CROP_W,cy+CROP_H)),(x0,y0+label_h))
        y0+=label_h+CROP_H
        if name == 'Upper hair':
            draw.text((left,y0+8),'Crown highlights',font=font(19,True),fill=ink)
            draw.text((left+232,y0+10),'x 1170    y 16    |    380 × 112 pixels. Pale outlines mark connected blue regions of at least 64 pixels.',font=font(15),fill=dim)
            for i,image in enumerate(images.values()):
                mask=anatomical_features(np.asarray(image))['crown']
                color=np.array(image.crop(CROWN_BOX))
                color[mask & ~binary_erosion(mask)]=(175,211,210)
                crop=Image.fromarray(color).resize((CROP_W,shown_h),Image.Resampling.LANCZOS)
                page.paste(crop,(left+i*(CROP_W+gap),y0+label_h))
            y0+=label_h+shown_h
        if name == 'Cheek':
            draw.text((left,y0+8),'Largest flat cheek patch',font=font(19,True),fill=ink)
            draw.text((left+302,y0+10),'The outline follows the largest connected 5 × 5 flat interior in this crop.',font=font(15),fill=dim)
            for i,image in enumerate(images.values()):
                page.paste(largest_cheek_overlay(image),(left+i*(CROP_W+gap),y0+label_h))
            y0+=label_h+CROP_H
    page.save(out,optimize=True)


def main():
    q=argparse.ArgumentParser(description=__doc__)
    for name in ('source','prior','reference','out'):q.add_argument('--'+name,type=Path,required=True)
    q.add_argument('--earlier',type=Path)
    q.add_argument('--new',type=Path);q.add_argument('--new-label',default='Directional surface regions')
    args=q.parse_args()
    args.out.mkdir(exist_ok=True,parents=True)
    paths={'Source photograph':args.source}
    if args.earlier:paths['Earlier coherent RTL']=args.earlier
    paths['Previous medium-region RTL']=args.prior
    if args.new:paths[args.new_label]=args.new
    paths['Designer1 reference']=args.reference
    images={label:Image.open(path).convert('RGB') for label,path in paths.items()}
    if any(im.size!=(2048,1152) for im in images.values()):raise ValueError('Expected 2048×1152 images')
    reference=analyze(np.asarray(images['Designer1 reference']))
    ref_surface=surface_features(reference['rgb'])
    ref_area=surface_mask(reference['edges'])
    ref_anatomy=anatomical_features(reference['rgb'])
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
                    'surface_scale':'Over the fixed reference surface mask, measure RMS of fine Y minus Gaussian Y at sigma 1.2, and of Gaussian Y at sigma 2.5 minus sigma 9. Units are display-coded luma levels.',
                    'coherent_polarity_f1':'Sign of the sigma 2.5 minus 9 luma band is positive at +2 codes and above and negative at -2 codes and below. Retain a nonzero center if at least four of the eight neighbors at axial/diagonal offsets of four pixels have its sign. Compare exact-position AND sign overlap inside the common reference surface mask. Activity counts report both polarities. This is a filter-output statistic independent of the RTL vote.',
                    'medium_patch_match':'Within cheek, forehead and collar, label 8-connected coherent positive and negative band signals separately inside the common reference surface mask. For each reference component of 32 through 1,024 pixels, compute the best intersection-over-union with any same-sign candidate component, counting the complete area of both components inside the crop. Average with equal weight per reference component. Non-overlapping reference components score zero.',
                    'tiny_signed_regions':'In the same crop, mask and sign labeling used for medium patch matching, count components of 1 through 15 pixels, inclusive, and sum their area as a percentage of all selected surface pixels. The crop and mask can split larger components. These counts include real fine structure and do not independently identify noise.',
                    'eye_column_gap':'In every column of the eye strip subtract the brighter mean of the brow and lid bands from the mean of the intervening skin band. Report the median across 130 columns and the per-column mean absolute error versus the reference.',
                    'right_eye_column_gap':'A separate diagnostic covers the smaller eye on the right of the frame, x [1550,1575). Use the same sigma 2 smoothing and column-gap definition, with brow rows [434,438), skin [448,452), and lid [459,463). Report median luma gap and per-column MAE against the artwork.',
                    'lip_opponent_mae':'Take the mean decoded RGB independently inside two lip bands, x [1370,1400) with y [836,847) on the upper lip and [865,877) on the lower lip. Derive R-G and G-B from each mean. Report those four signed values and the equally weighted mean of their absolute differences from the corresponding artwork values.',
                    'crown_highlights':'Use the same smoothing, color limits and 64-pixel component minimum as for the side-hair measurement, independently inside a second hair-only rectangle x [1170,1550), y [16,128). Report retained area fraction, largest component fraction of crop, component count and exact-location F1 against the artwork.',
                    'anatomical':'Hair rectangle x 700:910, y 150:310 contains only side hair in the artwork. Smooth RGB channels at sigma 2.5, take Y>=30 and G-R>=16 and B-R>=22, and retain 8-connected clusters of at least 64 pixels. F1 compares their exact occupied area. Eye rectangle x 1170:1300, y 375:529 includes upper brow, gap, lid, eye and lower shadow. Smooth RGB at sigma 2 and average Y across its 130 columns. Compare the resulting row profile and signed changes over four rows, using MAE against the artwork. Subtract mean brow (y 420:430) and upper lid (460:468) from intervening skin (443:452) in the same strip. Half-open coordinates; these are diagnostic proxies, not semantic labels.',
                    'medium_rms':'RMS of the signed difference of two Gaussian-filtered luminance images at sigma 1.8 and 6.0 pixels, in RGB8 codes. This measures the amount of medium-scale structure.',
                    'isolated_extrema':'Center Y=(R+2G+B+2)//4 is at least three codes higher or lower than all four immediate axial neighbors. Counts also include legitimate point features.',
                    'flat_pct':'Percentage of centers where the maximum minus minimum value is at most 4 codes in each of R, G and B over a 5x5 window. Frame-border samples replicate.',
                    'rgb':'MAE is mean absolute 8-bit RGB channel error. PSNR uses all RGB samples with peak 255. Exact requires all three channels equal. Gradient magnitude MAE uses the normalized Sobel magnitudes before thinning.'},
          'regions_xywh':{k:[x,y,CROP_W,CROP_H] for k,(x,y) in REGIONS.items()},
          'rgb_sha256':{k:hashlib.sha256(im.tobytes()).hexdigest() for k,im in images.items()},
          'measurements':{}, 'anatomical':{'Designer1 reference':anatomical_scores(ref_anatomy,ref_anatomy)}}
    for name,im in images.items():
        if name!='Designer1 reference':
            rgb=np.asarray(im)
            data['anatomical'][name]=anatomical_scores(anatomical_features(rgb),ref_anatomy)
            data['measurements'][name]=measure(analyze(rgb),reference,surface_features(rgb),ref_surface,ref_area)
    (args.out/'structure_metrics.json').write_text(json.dumps(data,indent=2)+'\n',encoding='utf-8')
    if args.new:
        before=data['measurements']['Previous medium-region RTL'];after=data['measurements'][args.new_label]
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
        lines+=['','Surface detail within the common reference mask, in luma codes',
                'Fine RMS measures deviations within roughly one pixel. Medium RMS measures the signed sigma 2.5-to-9 difference.',
                'Polarity F1 measures same-sign coherent response overlap on positions outside the reference contour margin.',
                '', f"{'Region':20}  {'Fine RMS prev/new/art':24} {'Medium RMS prev/new/art':25} {'Coherent F1 prev/new'}"]
        for name,s in before.items():
            t=after[name]
            def triple(base):
                values = [s['candidate_'+base],t['candidate_'+base],t['reference_'+base]]
                return '/'.join('n/a' if v is None else f'{v:.3f}' for v in values)
            def pair_or_null(key):
                return '/'.join('n/a' if v is None else f'{v:.3f}' for v in (s[key],t[key]))
            lines.append(f"{name:20}  {triple('surface_fine_rms'):24} {triple('surface_medium_rms'):25} {pair_or_null('coherent_polarity_f1')}")
        lines+=['','Targeted eye and hair measurements. Definitions and coordinates in structure_metrics.json.',
                '', f"{'Image':24} {'Eye row MAE':>12} {'Eye contrast MAE':>17} {'Skin-brow':>11} {'Skin-lid':>10} {'Hair cov. %':>13} {'Largest %':>11} {'Clusters':>9} {'Shape F1':>10}"]
        for name in ['Previous medium-region RTL',args.new_label,'Designer1 reference']:
            v=data['anatomical'][name]
            lines.append(f"{name:24} {v['eye_vertical_profile_mae']:12.3f} {v['eye_four_row_contrast_mae']:17.3f} "
                         f"{v['eye_skin_minus_brow_luma']:11.2f} {v['eye_skin_minus_lid_luma']:10.2f} "
                         f"{v['hair_highlight_coverage_pct']:13.2f} {v['largest_hair_highlight_pct']:11.2f} {v['hair_highlight_count']:9} {v['hair_highlight_shape_f1']:10.3f}")
        lines+=['', 'Interior crown highlights, measured separately from side hair in the preceding table.',
                'Image                       Coverage %    Largest %    Clusters    Shape F1']
        for name in ['Previous medium-region RTL',args.new_label,'Designer1 reference']:
            v=data['anatomical'][name]
            lines.append(f"{name:26} {v['crown_highlight_coverage_pct']:11.2f} {v['largest_crown_highlight_pct']:12.2f} "
                         f"{v['crown_highlight_count']:11} {v['crown_highlight_shape_f1']:11.3f}")
        lines+=['', 'Across-column separation of the skin band between brow and upper lid, in luma codes.',
                'Image                     Median column gap    Gap profile MAE     Mean brow / skin / lid']
        for name in ['Previous medium-region RTL',args.new_label,'Designer1 reference']:
            v=data['anatomical'][name]
            lines.append(f"{name:24}  {v['eye_median_column_gap']:16.2f}  {v['eye_column_gap_mae']:17.2f}     " 
                         f"{v['eye_brow_mean_luma']:.1f} / {v['eye_skin_mean_luma']:.1f} / {v['eye_upper_lid_mean_luma']:.1f}")
        lines+=['','Smaller eye on the right of the image, measured independently in 25 columns.',
                'Image                       Median column gap      Gap profile MAE']
        for name in ['Previous medium-region RTL',args.new_label,'Designer1 reference']:
            v=data['anatomical'][name]
            lines.append(f"{name:26} {v['right_eye_median_column_gap']:17.2f} {v['right_eye_column_gap_mae']:20.2f}")
        lines+=['','Mean opponent color in small upper- and lower-lip interior bands, in RGB8 codes.',
                'Image                         Upper R-G / G-B      Lower R-G / G-B   Four-value MAE']
        for name in ['Previous medium-region RTL',args.new_label,'Designer1 reference']:
            v=data['anatomical'][name]
            lines.append(f"{name:26} {v['upper_lip_mean_rg']:8.2f} / {v['upper_lip_mean_gb']:6.2f}   "
                         f"{v['lower_lip_mean_rg']:8.2f} / {v['lower_lip_mean_gb']:6.2f} {v['lip_opponent_mae']:16.2f}")
        lines+=['', 'Medium signed-luminance regions on the common surface mask. Mean best overlap per artwork patch.',
                'Region                Artwork patch count    Mean best IoU previous / new']
        for name in ('Cheek','Forehead','Jacket collar'):
            a,b=before[name],after[name]
            overlap=' / '.join('n/a' if x is None else f'{x:.3f}' for x in
                                 (a['mean_best_medium_patch_iou'],b['mean_best_medium_patch_iou']))
            lines.append(f"{name:20}  {a['reference_medium_signed_patches']:19}    {overlap}")
        lines+=['','Tiny signed surface regions of 1–15 pixels, measured in the same crops and surface mask.',
                'Region                Count prev/new/art       % of selected surface prev/new/art']
        for name in ('Cheek','Forehead','Jacket collar'):
            a,b=before[name],after[name]
            cnt=(a['candidate_tiny_signed_count'], b['candidate_tiny_signed_count'], b['reference_tiny_signed_count'])
            pct=(a['candidate_tiny_signed_surface_pct'], b['candidate_tiny_signed_surface_pct'], b['reference_tiny_signed_surface_pct'])
            lines.append(f"{name:20}  {' / '.join(map(str,cnt)):24} {' / '.join(f'{i:.3f}' for i in pct)}")
        def psnr_text(record):
            value = record['Whole frame']['rgb_psnr_db']
            return 'infinite' if value is None else f'{value:.4f}'
        lines+=['','Full-frame RGB comparison', f"The previous output had {before['Whole frame']['exact_rgb_pixels']:,} exact RGB pixels and PSNR {psnr_text(before)} dB.",
                f"The revised output had {after['Whole frame']['exact_rgb_pixels']:,} exact RGB pixels and PSNR {psnr_text(after)} dB.",
                'Both comparisons include 2,359,296 pixels. Per-region detail, thresholds and decoded image hashes are in structure_metrics.json.']
        (args.out/'structure_summary.txt').write_text('\n'.join(lines)+'\n',encoding='utf-8')

if __name__=='__main__':main()
