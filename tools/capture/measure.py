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
    scale = image.width / window['Width'] if window.get('Width') else float(spec.get('scale', 1))
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


def burst(directory):
    receipt = json.loads((directory / 'timestamps.json').read_text())
    frames = receipt['frames']
    if not frames:
        result = {'status': 'not captured', 'reason': 'stream has no complete image frames', 'receipt': receipt}
        (directory/'motion.measure.json').write_text(json.dumps(result,indent=2))
        return result
    pictures = [Image.open(directory / f['frame']).convert('RGB').resize((256,144)) for f in frames]
    first, last = pictures[0], pictures[-1]
    full = sum(ImageStat.Stat(ImageChops.difference(first,last)).mean)
    values = []
    for f, picture in zip(frames,pictures):
        delta = sum(ImageStat.Stat(ImageChops.difference(first,picture)).mean)
        values.append({'seconds':f['elapsed'], 'image_change_progress_guess':delta/full if full > .1 else None})
    fitted = []
    if full > .1 and len(frames) >= 5:
        t0 = frames[0]['elapsed']
        for delay in [i/50 for i in range(16)]:
            for duration in [i/50 for i in range(2,76)]:
                for curve in ('linear','ease-out-cubic','smoothstep'):
                    residuals=[]
                    for v in values:
                        p=max(0,min(1,(v['seconds']-t0-delay)/duration))
                        predicted=p if curve=='linear' else (1-(1-p)**3 if curve=='ease-out-cubic' else p*p*(3-2*p))
                        residuals.append((v['image_change_progress_guess']-predicted)**2)
                    fitted.append((math.sqrt(statistics.mean(residuals)),curve,delay,duration))
    best = min(fitted) if fitted else None
    result={'requested_fps':receipt['requested_fps'],'effective_fps':receipt['effective_fps'],'samples':values,
            'fit_guess':None if not best else {'rms':best[0],'curve':best[1],'delay_seconds':best[2],'duration_seconds':best[3]},
            'qualification':'GUESS: image change mixes content, position and opacity. No layer opacity or physical scanout measurement. Sparse capture cannot prove spring parameters.'}
    (directory/'motion.measure.json').write_text(json.dumps(result,indent=2))
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('input', type=Path)
    p.add_argument('--spec',type=Path)
    args=p.parse_args()
    result=burst(args.input) if args.input.is_dir() else measure(args.input,json.loads(args.spec.read_text()) if args.spec else None)
    print(json.dumps({k:v for k,v in result.items() if k not in ('elements','gaps','samples')}))


if __name__=='__main__': main()
