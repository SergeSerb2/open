#!/usr/bin/env python3
"""Turn recorder output into the bundled basics clips.

For each clip directory written by demo.py (capture.mov, timestamps.json,
timeline.json, drag images): resample to constant 60 fps by host-clock time
(ScreenCaptureKit sends a frame only when the window changes), draw the
pointer and the drag image from the logged timeline, and encode HEVC Main
(hvc1, BT.709) for AVFoundation hardware decode. It also writes the last-frame
poster, a blurred poster for the end state, and a manifest.

Only the pointer and the drag image are drawn here. The app's own motion is
never retimed or edited.

  post.py REC_DIR OUT_DIR [--clips pin,spaces,split,newtab] [--crf 26]
"""
import argparse, hashlib, json, subprocess, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

FPS = 60
DRAG_ALPHA = 0.8  # Approximation: system drag images draw slightly translucent.


def ease(u):
    u = min(1.0, max(0.0, u))
    return u * u * u * (10 - 15 * u + 6 * u * u)


def pointer_at(moves, host):
    current = moves[0]['from']
    for m in moves:
        if m['start'] > host: break
        if m['duration'] <= 0 or host >= m['start'] + m['duration']: current = m['to']; continue
        k = ease((host - m['start']) / m['duration'])
        current = [m['from'][0] + (m['to'][0] - m['from'][0]) * k, m['from'][1] + (m['to'][1] - m['from'][1]) * k]
    return current


def make_pointer(scale):
    """Our own arrow pointer: black fill, white rim, soft shadow. Hotspot at the tip."""
    ss = 8  # supersampling
    shape = [(0, 0), (0, 16.6), (3.9, 12.9), (6.6, 19.4), (9.2, 18.3), (6.5, 12.0), (11.7, 12.0)]
    size = (int(18 * scale), int(26 * scale)); pad = 3
    big = Image.new('RGBA', (size[0] * ss, size[1] * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    pts = [((x + pad) * scale * ss, (y + pad) * scale * ss) for x, y in shape]
    d.polygon(pts, fill=(255, 255, 255, 255))
    rim = 1.3 * scale * ss
    # Inset black body: shrink toward the polygon's inner area by drawing a thick white outline over black.
    d.polygon(pts, fill=(0, 0, 0, 255), outline=(255, 255, 255, 255), width=int(rim))
    img = big.resize(size, Image.LANCZOS)
    shadow = Image.new('RGBA', size, (0, 0, 0, 0))
    alpha = img.split()[3].point(lambda a: int(a * 0.35))
    shadow.putalpha(alpha)
    shadow = shadow.filter(ImageFilter.GaussianBlur(1.6 * scale))
    out = Image.new('RGBA', size, (0, 0, 0, 0))
    out.alpha_composite(shadow, (0, int(1 * scale)))
    out.alpha_composite(img)
    return out, (pad * scale, pad * scale)


def decode(movie, width, height):
    raw = subprocess.run(['ffmpeg', '-loglevel', 'error', '-i', str(movie), '-fps_mode', 'passthrough', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
                         capture_output=True, check=True).stdout
    n = len(raw) // (width * height * 3)
    return [raw[i * width * height * 3:(i + 1) * width * height * 3] for i in range(n)]


def process(rec, out, name, crf):
    folder = rec / name
    stamps = json.loads((folder / 'timestamps.json').read_text())
    timeline = json.loads((folder / 'timeline.json').read_text())
    width, height = stamps['pixels']
    scale = stamps['scale']
    times = [f['hostSeconds'] for f in stamps['frames'] if not f.get('dropped')]
    frames = decode(folder / 'capture.mov', width, height)
    if len(frames) != len(times):
        raise SystemExit('%s: %d decoded frames for %d timestamps' % (name, len(frames), len(times)))
    pointer, hotspot = make_pointer(scale)
    drags = []
    for d in timeline['drags']:
        image = Image.open(folder / d['image']).convert('RGBA')
        points = d['imageSize']
        if image.size != (round(points[0] * scale), round(points[1] * scale)):
            image = image.resize((round(points[0] * scale), round(points[1] * scale)), Image.LANCZOS)
        a = image.split()[3].point(lambda v: int(v * DRAG_ALPHA)); image.putalpha(a)
        row = d['row']; grab = d['grab']
        drags.append((d['start'], d['end'], image, (grab[0] - row[0], grab[1] - row[1])))
    t0 = timeline['t0']
    count = int(round(timeline['seconds'] * FPS))
    target = out / ('basics-%s.mp4' % name)
    encoder = subprocess.Popen(['ffmpeg', '-loglevel', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgb24',
        '-s', '%dx%d' % (width, height), '-r', str(FPS), '-i', '-',
        '-vf', 'scale=out_color_matrix=bt709:out_range=tv,format=yuv420p',
        '-c:v', 'libx265', '-preset', 'slow', '-crf', str(crf), '-tag:v', 'hvc1',
        '-x265-params', 'log-level=error:keyint=120:min-keyint=60',
        '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-color_range', 'tv',
        '-movflags', '+faststart', '-an', str(target)], stdin=subprocess.PIPE)
    index = 0
    last = None
    for k in range(count):
        host = t0 + k / FPS
        while index + 1 < len(times) and times[index + 1] <= host + 0.002: index += 1
        frame = Image.frombytes('RGB', (width, height), frames[index]).convert('RGBA')
        x, y = pointer_at(timeline['moves'], host)
        for start, end, image, offset in drags:
            if start <= host < end:
                frame.alpha_composite(image, (int(round((x - offset[0]) * scale)), int(round((y - offset[1]) * scale))))
        frame.alpha_composite(pointer, (int(round(x * scale - hotspot[0])), int(round(y * scale - hotspot[1]))))
        last = frame.convert('RGB')
        encoder.stdin.write(last.tobytes())
    encoder.stdin.close()
    if encoder.wait() != 0: raise SystemExit('encode failed for %s' % name)
    poster = out / ('basics-%s-poster.jpg' % name)
    last.save(poster, quality=90)
    blur = out / ('basics-%s-blur.jpg' % name)
    last.resize((width // 2, height // 2), Image.LANCZOS).filter(ImageFilter.GaussianBlur(14)).save(blur, quality=82)
    return {'clip': name, 'frames': count, 'fps': FPS, 'pixels': [width, height], 'sourceFrames': len(times),
            'recordedOn': timeline.get('window', {}), 'source': timeline.get('source'), 'crf': crf,
            'files': {p.name: {'bytes': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
                      for p in (target, poster, blur)}}


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('rec'); p.add_argument('out')
    p.add_argument('--clips', default='pin,spaces,split,newtab')
    p.add_argument('--crf', type=int, default=26)
    o = p.parse_args()
    rec, out = Path(o.rec), Path(o.out); out.mkdir(parents=True, exist_ok=True)
    manifest_path = out / 'basics-manifest.json'
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {'clips': {}}
    for name in o.clips.split(','):
        entry = process(rec, out, name, o.crf)
        manifest['clips'][name] = entry
        print(json.dumps({k: entry[k] for k in ('clip', 'frames', 'sourceFrames', 'source')}),
              {k: v['bytes'] for k, v in entry['files'].items()}, flush=True)
    manifest['tool'] = 'tools/basics (demo.py, recorder.swift, post.py)'
    manifest_path.write_text(json.dumps(manifest, indent=1, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
