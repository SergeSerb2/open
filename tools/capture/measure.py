#!/usr/bin/env python3
"""Measure captured pixels and AX geometry; uncertain estimates stay explicit.

Requires Pillow. Optional spec: {samples:{name:[x,y]}, radii:{name:[x,y,w,h]},
text:{name:[x,y,w,h]}} in window points. Never infer a control's function from
pixels. Burst progress is whole-region image change, not proven layer opacity.
"""
import argparse
import json
import io
import math
from pathlib import Path
import statistics
from PIL import Image, ImageChops, ImageStat, ImageCms
from session import walk


def measure(frame, spec=None):
    spec = spec or {}
    original = Image.open(frame)
    icc = original.info.get('icc_profile')
    image = original.convert('RGB')
    color_status = 'UNQUALIFIED: PNG has no ICC profile; no color reference fallback'
    if icc:
        image = ImageCms.profileToProfile(image, ImageCms.ImageCmsProfile(io.BytesIO(icc)), ImageCms.createProfile('sRGB'), outputMode='RGB')
        color_status = 'converted from embedded PNG ICC profile to sRGB with LittleCMS'
    axfile = frame.with_suffix('.ax.json')
    tree = json.loads(axfile.read_text()) if axfile.exists() else {}
    meta = json.loads(frame.with_suffix('.meta.json').read_text()) if frame.with_suffix('.meta.json').exists() else {}
    window = meta.get('window', {}).get('bounds', {})
    origin = [window.get('X', 0), window.get('Y', 0)]
    if window.get('Width') and window.get('Height'):
        scale = image.width / window['Width']
        if abs(image.height / window['Height'] - scale) > .01:
            raise ValueError('PNG dimensions do not match the recorded window scale')
    elif 'scale' in spec and float(spec['scale']) > 0:
        scale = float(spec['scale'])
    else:
        raise ValueError('recorded window geometry or an explicit measured scale is required; no fallback')
    rows = []
    for i, node in enumerate(walk(tree)):
        if node.get('frame') and isinstance(node['frame'], list) and len(node['frame']) == 4:
            x, y, w, h = node['frame']
            rows.append({'index': i, 'role': node.get('role'), 'title': node.get('title', ''), 'id': node.get('id', ''), 'relative_points': [x - origin[0], y - origin[1], w, h], 'font': node.get('font', 'AX font unavailable')})
    gaps = []
    # Only compare elements with the same role and x/width to avoid presenting
    # arbitrary nested-frame overlaps as row spacing.
    groups = {}
    for row in rows:
        x, y, w, h = row['relative_points']
        if row['role'] in ('AXRow', 'AXButton', 'AXCell', 'AXStaticText'):
            groups.setdefault((row['role'], round(x, 1), round(w, 1)), []).append(row)
    for group in groups.values():
        group.sort(key=lambda r: r['relative_points'][1])
        for a, b in zip(group, group[1:]):
            gap = b['relative_points'][1] - a['relative_points'][1] - a['relative_points'][3]
            if 0 <= gap < 100:
                gaps.append({'from_index': a['index'], 'to_index': b['index'], 'points': gap})
    samples = {}
    for name, point in spec.get('samples', {}).items():
        rgb = image.getpixel(tuple(round(p * scale) for p in point))
        samples[name] = {'point': point, 'srgb_hex': '#%02X%02X%02X' % rgb if icc else None, 'method': color_status}
    radii = {}
    for name, rect in spec.get('radii', {}).items():
        x, y, w, h = [round(v * scale) for v in rect]
        crop = image.crop((x, y, x + w, y + h))
        background = crop.getpixel((0, 0))
        offsets = []
        for yy in range(min(h // 2, 32)):
            xx = next((xx for xx in range(min(w // 2, 40)) if sum(abs(a-b) for a,b in zip(crop.getpixel((xx, yy)), background)) > 24), None)
            if xx is not None:
                offsets.append((xx, yy))
        fits = []
        for radius in [v / 4 for v in range(4, 161)]:
            relevant = [(xx, yy) for xx, yy in offsets if yy < radius]
            if len(relevant) >= 3:
                residual = math.sqrt(statistics.mean((xx - (radius - math.sqrt(max(0, radius**2 - (radius - yy)**2))))**2 for xx, yy in relevant))
                fits.append((residual, radius))
        radii[name] = {'status': 'not measured: no stable edge'} if not fits else {'guess_radius_points': min(fits)[1] / scale, 'rms_pixels': min(fits)[0], 'method': 'top-left circular edge fit; continuous corners and gradients can invalidate it'}
    text = {}
    for name, rect in spec.get('text', {}).items():
        x,y,w,h = [round(v * scale) for v in rect]
        crop = image.crop((x,y,x+w,y+h)).convert('L')
        bg = crop.getpixel((0,0))
        occupied = [yy for yy in range(h) if sum(abs(crop.getpixel((xx,yy))-bg) > 40 for xx in range(w)) >= 2]
        text[name] = {'guess_ink_height_points': (max(occupied)-min(occupied)+1)/scale if occupied else None, 'method': 'thresholded glyph ink; not a font size or proven cap height'}
    result = {'frame': str(frame), 'pixels': list(image.size), 'scale': scale, 'elements': rows, 'gaps': gaps, 'samples': samples, 'radii': radii, 'text': text}
    frame.with_suffix('.measure.json').write_text(json.dumps(result, indent=2))
    lines = ['# Measurement: ' + frame.stem, '', f'PNG {image.width}×{image.height}; scale {scale:g}. Geometry is in window points.', '', '| AX index | Role | x | y | width | height |', '|---|---|---:|---:|---:|---:|']
    for row in rows:
        lines.append('| %s | %s | %s |' % (row['index'], row['role'], ' | '.join('%g' % v for v in row['relative_points'])))
    lines += ['', 'Labels and identifiers are in the private JSON sheet. Font, corner, color and motion estimates need their stated qualifications.', '', '```json', json.dumps({'samples':samples,'radii':radii,'text':text}, indent=2), '```']
    frame.with_suffix('.measure.md').write_text('\n'.join(lines) + '\n')
    return result


def edge_motion(originals, values, spec):
    """Track a visually selected vertical/horizontal edge, not an app layer."""
    roi = spec['roi_pixels']
    axis = spec.get('axis', 'x')
    if axis not in ('x', 'y'):
        raise ValueError('motion edge axis must be x or y')
    scale = float(spec['pixels_per_point'])
    if scale <= 0 or len(roi) != 4:
        raise ValueError('motion edge needs a positive scale and four ROI values')
    x, y, w, h = map(int, roi)
    samples = []
    for filename, value in zip(originals, values):
        source = Image.open(filename)
        if x < 0 or y < 0 or w < 3 or h < 3 or x+w > source.width or y+h > source.height:
            raise ValueError('motion edge ROI is outside a captured frame')
        crop = source.convert('RGB').crop((x,y,x+w,y+h))
        source.close()
        if axis == 'y':
            crop = crop.transpose(Image.Transpose.TRANSPOSE)
        columns = list(crop.resize((crop.width,1),Image.Resampling.BOX).getdata())
        gradients = [sum(abs(a-b) for a,b in zip(columns[i],columns[i-1])) for i in range(1,len(columns))]
        peak = max(range(len(gradients)),key=gradients.__getitem__)
        neighborhood = range(max(0,peak-1),min(len(gradients),peak+2))
        weight = sum(gradients[i] for i in neighborhood)
        coordinate = (sum((i+1)*gradients[i] for i in neighborhood)/weight if weight else peak+1)
        coordinate += x if axis == 'x' else y
        samples.append({'seconds':value['seconds'],'position_points_guess':coordinate/scale,
                        'edge_strength':gradients[peak]})
    first,last = samples[0]['position_points_guess'],samples[-1]['position_points_guess']
    travel = last-first
    intermediate = sum(.05 < (v['position_points_guess']-first)/travel < .95 for v in samples) if abs(travel)>1 else 0
    fits=[]
    if intermediate >= 3:
        first_change = next(v['seconds'] for v in samples if abs(v['position_points_guess']-first)>abs(travel)*.05)
        for delay in [max(0,first_change-.15+i/100) for i in range(31)]:
            for duration in [i/50 for i in range(2,76)]:
                for curve in ('linear','ease-out-cubic','smoothstep'):
                    errors=[]
                    for v in samples:
                        p=max(0,min(1,(v['seconds']-delay)/duration))
                        p=p if curve=='linear' else 1-(1-p)**3 if curve=='ease-out-cubic' else p*p*(3-2*p)
                        errors.append((v['position_points_guess']-(first+travel*p))**2)
                    fits.append((math.sqrt(statistics.mean(errors)),curve,delay,duration))
    best=min(fits) if fits else None
    return {'qualification':'GUESS: strongest averaged pixel edge in an observed ROI; no app layer identity or opacity measurement',
            'roi_pixels':roi,'axis':axis,'pixels_per_point':scale,'samples':samples,
            'travel_points_guess':travel,'intermediate_samples':intermediate,
            'fit_status':'unresolved: sparse or stationary edge' if not best else 'GUESS: poor edge fit' if best[0]>max(1,abs(travel)*.15) else 'guess: pixel edge fit',
            'fit_guess':None if not best else {'rms_points':best[0],'curve':best[1],'delay_seconds':best[2],'duration_seconds':best[3]}}


def burst(directory, spec=None):
    receipt = json.loads((directory / 'timestamps.json').read_text())
    frames = receipt['frames']
    if not frames:
        result = {'status': 'not captured', 'reason': 'stream has no complete image frames', 'receipt': receipt}
        (directory/'motion.measure.json').write_text(json.dumps(result,indent=2))
        return result
    if len(frames) > 1000:
        raise ValueError('burst exceeds1000 frames')
    originals = [directory / f['frame'] for f in frames]
    sizes, pictures = set(), []
    for filename in originals:
        with Image.open(filename) as im:
            if im.width * im.height > 20000000:
                raise ValueError('captured frame exceeds20million pixels')
            sizes.add(im.size)
            pictures.append(im.convert('RGB').resize((256,144)))
    first, last = pictures[0], pictures[-1]
    full = sum(ImageStat.Stat(ImageChops.difference(first,last)).mean)
    values = []
    presentation = all(isinstance(f.get('presentation_seconds'), (int,float)) for f in frames)
    clock = 'capture presentation timestamps' if presentation else 'snapshot midpoint timestamps'
    origin = frames[0]['presentation_seconds'] if presentation else 0
    for f, picture in zip(frames,pictures):
        delta = sum(ImageStat.Stat(ImageChops.difference(first,picture)).mean)
        seconds = f['presentation_seconds'] - origin if presentation else f['elapsed']
        values.append({'seconds':seconds, 'image_change_progress_guess':delta/full if full > .1 else None})
    fitted = []
    intermediate = sum(v['image_change_progress_guess'] is not None and .05 < v['image_change_progress_guess'] < .95 for v in values)
    fit_status = 'unresolved: fewer than three intermediate change samples'
    if len(sizes) > 1:
        fit_status = 'unresolved: window/image size changed; this is not a single-layer animation'
    elif full <= .1:
        fit_status = 'not observed: captured images are static'
    elif intermediate >= 3 and len(frames) >= 5:
        fit_status = 'guess: image-change fit, not layer position or opacity'
        t0 = values[0]['seconds']
        first_change = next(v['seconds']-t0 for v in values if v['image_change_progress_guess'] > .05)
        delays = [max(0, first_change - .15 + i/100) for i in range(31)]
        for delay in delays:
            for duration in [i/50 for i in range(2,76)]:
                for curve in ('linear','ease-out-cubic','smoothstep'):
                    residuals=[]
                    for v in values:
                        p=max(0,min(1,(v['seconds']-t0-delay)/duration))
                        predicted=p if curve=='linear' else (1-(1-p)**3 if curve=='ease-out-cubic' else p*p*(3-2*p))
                        residuals.append((v['image_change_progress_guess']-predicted)**2)
                    fitted.append((math.sqrt(statistics.mean(residuals)),curve,delay,duration))
    best = min(fitted) if fitted else None
    if best and best[0] > .15:
        fit_status = 'GUESS: poor image-change fit; do not accept its duration or curve'
    result={'requested_fps':receipt['requested_fps'],'effective_fps':receipt['effective_fps'],'samples':values,
            'fit_status':fit_status, 'intermediate_samples':intermediate,
            'clock':clock,
            'fit_guess':None if not best else {'rms':best[0],'curve':best[1],'delay_seconds':best[2],'duration_seconds':best[3]},
            'qualification':'GUESS: image change mixes content, position and opacity. No layer opacity or physical scanout measurement. Sparse capture cannot prove spring parameters.'}
    if spec and spec.get('motion_edge'):
        if len(sizes)>1:
            result['position_measurement']={'fit_status':'unresolved: frame size changed'}
        else:
            position=edge_motion(originals,values,spec['motion_edge'])
            (directory/'position.measure.json').write_text(json.dumps(position,indent=2))
            result['position_measurement']={k:v for k,v in position.items() if k!='samples'}
    (directory/'motion.measure.json').write_text(json.dumps(result,indent=2))
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('input', type=Path)
    p.add_argument('--spec',type=Path)
    args=p.parse_args()
    spec=json.loads(args.spec.read_text()) if args.spec else None
    result=burst(args.input,spec) if args.input.is_dir() else measure(args.input,spec)
    print(json.dumps({k:v for k,v in result.items() if k not in ('elements','gaps','samples')}))


if __name__=='__main__': main()
