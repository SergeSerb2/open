#!/usr/bin/env python3
"""Compare Open's compact toolbar (real-window snapshot) with Arc S2 06/0029 (completion §5.5).

Usage: compact-toolbar-compare.py --ours SNAPSHOT.png [--width 164] [--capture-root .re] [--out TABLE.md]
SNAPSHOT.png: the sidebar-completion e2e `a1-compact-164.png` (window 1728 x 1084 at any scale).
Per button (Back, Forward, More options): the glyph ink box (pixels at least half of the peak
contrast above the plate area's background, in points) and the peak tone (mean of the 12
brightest pixels). Targets: position <= 1 pt, dE00 <= 2. A tone row compares only buttons whose
enabled state matches (Back is enabled in Arc's frame after navigation; the e2e page has no history).
"""
import argparse, glob, importlib.util, os, sys
import numpy as np
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('hint_compare', os.path.join(here, 'hint-compare.py'))
hc = importlib.util.module_from_spec(spec); spec.loader.exec_module(hc)

def measure(img, scale, frame):
    x, y, w, h = frame
    reg = img[int(y * scale):int((y + h) * scale), int(x * scale):int((x + w) * scale)]
    lum = reg.mean(axis=2)
    bg = np.median(np.concatenate([lum[0], lum[-1], lum[:, 0], lum[:, -1]]))
    contrast = np.abs(lum - bg)
    ink = contrast > contrast.max() / 2
    ys, xs = np.nonzero(ink)
    box = [x + xs.min() / scale, y + ys.min() / scale, x + (xs.max() + 1) / scale, y + (ys.max() + 1) / scale]
    flat = reg.reshape(-1, 3); peak = flat[np.argsort(flat.mean(axis=1))[-12 * int(scale * scale):]].mean(axis=0)
    return box, peak

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--ours', required=True); ap.add_argument('--width', type=float, default=164)
    ap.add_argument('--capture-root', default=os.path.join(here, '../../.re')); ap.add_argument('--out'); o = ap.parse_args()
    frame = {164: '0029', 207: '0025'}[int(o.width)]
    paths = glob.glob(os.path.join(o.capture_root, 'runtime/sessions/20261026-101147-06-sidebar-width', frame + '-*/win-70352.png'))
    if not paths: print('SKIP: capture S2 06/%s absent' % frame); return 0
    arc, ours = hc.load(paths[0]), hc.load(o.ours)
    scale = ours.shape[1] / arc.shape[1]
    W = o.width
    buttons = [('Back', [W - 90, 9, 28, 28], False), ('Forward', [W - 62, 9, 28, 28], True), ('More options', [W - 34, 9, 28, 28], True)]
    lines = ['| Button (S2 06/%s, width %g) | Arc ink box (pt) | Open ink box (pt) | Position error (pt) | Arc peak | Open peak | ΔE00 |' % (frame, W),
             '|---|---|---|---:|---|---|---:|']
    worst_pos, worst_de = 0, 0
    for name, f, tone in buttons:
        abox, apeak = measure(arc, 1, f); obox, opeak = measure(ours, scale, f)
        err = max(abs(a - b) for a, b in zip(abox, obox)); worst_pos = max(worst_pos, err)
        de = hc.de00(apeak, opeak) if tone else None
        if de is not None: worst_de = max(worst_de, de)
        hexs = lambda c: '#%02X%02X%02X' % tuple(int(round(v)) for v in c)
        lines.append('| %s | %s | %s | %.2f | %s | %s | %s |' % (name, [round(float(v), 1) for v in abox], [round(float(v), 1) for v in obox], err,
                     hexs(apeak), hexs(opeak), '%.2f' % de if de is not None else 'n/a (enabled state differs)'))
    ok = worst_pos <= 1 and worst_de <= 2
    lines += ['', 'Button frames: Arc AX `[W − 90 / W − 62 / W − 34, 9, 28, 28]`; Open uses the same tokens (CT1).',
              'Worst ink position %.2f pt (target <= 1), worst dE00 %.2f (target <= 2): %s' % (worst_pos, worst_de, 'PASS' if ok else 'FAIL')]
    text = '\n'.join(lines); print(text)
    if o.out: open(o.out, 'w').write(text + '\n')
    return 0 if ok else 1

if __name__ == '__main__': sys.exit(main())
