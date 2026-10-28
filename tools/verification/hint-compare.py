#!/usr/bin/env python3
"""Compare Open's first-hide hint render with Arc capture A0440 (completion §5.5).

Usage: hint-compare.py --ours OURS.png [--capture-root .re] [--out TABLE.md]
OURS.png: `features-render hint --size 2216x1394 --scale 1` (A0440's window size, 1x).
The capture stays in .re/ (never committed); the table holds measurements only.
Targets: position <= 1 pt, color dE00 <= 2.
"""
import argparse, glob, io, math, os, sys
import numpy as np
from PIL import Image, ImageCms

def load(path):
    im = Image.open(path)
    if 'icc_profile' in im.info:  # display profile -> sRGB, as docs/design.md §7
        src = ImageCms.ImageCmsProfile(io.BytesIO(im.info['icc_profile']))
        im = ImageCms.profileToProfile(im.convert('RGB'), src, ImageCms.createProfile('sRGB'), outputMode='RGB')
    return np.asarray(im.convert('RGB')).astype(float)

def lab(rgb):
    def lin(c): c = c / 255; return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(c) for c in rgb)
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    f = lambda t: t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116
    return 116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))

def de00(c1, c2):
    L1, a1, b1 = lab(c1); L2, a2, b2 = lab(c2)
    C1, C2 = math.hypot(a1, b1), math.hypot(a2, b2); Cb = (C1 + C2) / 2
    G = 0.5 * (1 - math.sqrt(Cb ** 7 / (Cb ** 7 + 25 ** 7)))
    a1p, a2p = a1 * (1 + G), a2 * (1 + G)
    C1p, C2p = math.hypot(a1p, b1), math.hypot(a2p, b2)
    h1p, h2p = math.degrees(math.atan2(b1, a1p)) % 360, math.degrees(math.atan2(b2, a2p)) % 360
    dLp, dCp = L2 - L1, C2p - C1p
    dh = h2p - h1p
    if C1p * C2p == 0: dh = 0
    elif dh > 180: dh -= 360
    elif dh < -180: dh += 360
    dHp = 2 * math.sqrt(C1p * C2p) * math.sin(math.radians(dh / 2))
    Lbp, Cbp = (L1 + L2) / 2, (C1p + C2p) / 2
    hbp = h1p + h2p if C1p * C2p == 0 else ((h1p + h2p) / 2 if abs(h1p - h2p) <= 180 else (h1p + h2p + 360) / 2 if h1p + h2p < 360 else (h1p + h2p - 360) / 2)
    T = 1 - 0.17 * math.cos(math.radians(hbp - 30)) + 0.24 * math.cos(math.radians(2 * hbp)) + 0.32 * math.cos(math.radians(3 * hbp + 6)) - 0.20 * math.cos(math.radians(4 * hbp - 63))
    SL = 1 + 0.015 * (Lbp - 50) ** 2 / math.sqrt(20 + (Lbp - 50) ** 2); SC = 1 + 0.045 * Cbp; SH = 1 + 0.015 * Cbp * T
    RT = -2 * math.sqrt(Cbp ** 7 / (Cbp ** 7 + 25 ** 7)) * math.sin(math.radians(60 * math.exp(-((hbp - 275) / 25) ** 2)))
    return math.sqrt((dLp / SL) ** 2 + (dCp / SC) ** 2 + (dHp / SH) ** 2 + RT * (dCp / SC) * (dHp / SH))

def toast_box(a):
    """Toast box including its 1 px rim: the fill run along row 30 and down column x 2200."""
    fill = a[30, 2200]
    row = np.abs(a[30, 1700:2216] - fill).max(axis=1) < 10
    col = np.abs(a[0:70, 2200] - fill).max(axis=1) < 14
    xs = np.nonzero(row)[0] + 1700; ys = np.nonzero(col)[0]
    return xs.min() - 1, ys.min() - 1, xs.max() + 1, ys.max() + 1

def ink_groups(a, box):
    """Text ink runs (lum > 140) in the toast's inner rows, away from the rounded corners."""
    x0, y0, x1, y1 = box
    reg = a[y0 + 8:y1 - 7, x0 + 2:x1 - 1]; ink = reg.mean(axis=2) > 140
    cols = ink.any(axis=0); segs, s = [], None
    for i, c in enumerate(list(cols) + [False]):
        if c and s is None: s = i
        if not c and s is not None: segs.append([s + x0 + 2, i - 1 + x0 + 2]); s = None
    groups = []
    for seg in segs:
        if groups and seg[0] - groups[-1][1] <= 6: groups[-1][1] = seg[1]
        else: groups.append(seg)
    rows = np.nonzero(ink.any(axis=1))[0]
    core = reg[reg.mean(axis=2) > 200]
    return groups, (rows.min() + y0 + 8, rows.max() + y0 + 8), core.mean(axis=0)

def plate_box(a, box, groups):
    """The keycap plate: columns and rows between the first two text runs lighter than the fill."""
    x0, y0, x1, y1 = box
    fill = a[y0 + 24, groups[0][1] + 3].mean()
    lo, hi = groups[0][1] + 2, groups[2][0] - 2
    light = a[y0 + 3:y1 - 2, lo:hi].mean(axis=2) - fill > 6
    # Plate columns are light over most of its 27 rows; text ink covers at most ~14 rows.
    cols = np.nonzero(light.sum(axis=0) >= 20)[0]; rows = np.nonzero(light.sum(axis=1) >= 30)[0]
    return cols.min() + lo, rows.min() + y0 + 3, cols.max() + lo, rows.max() + y0 + 3

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--ours', required=True)
    ap.add_argument('--capture-root', default=os.path.join(os.path.dirname(__file__), '../../.re'))
    ap.add_argument('--out'); o = ap.parse_args()
    s = os.path.join(o.capture_root, 'runtime/sessions/20261024-213009-session-anim')
    arc_path = glob.glob(os.path.join(s, '0440-*/win-5389.png'))
    if not arc_path: print('SKIP: capture A0440 absent'); return 0
    arc, ours = load(arc_path[0]), load(o.ours)
    if ours.shape != arc.shape: sys.exit('ours %s must match the capture %s (render --size 2216x1394 --scale 1)' % (ours.shape, arc.shape))
    abox, obox = toast_box(arc), toast_box(ours)
    ag, ay, acore = ink_groups(arc, abox); og, oy, ocore = ink_groups(ours, obox)
    ap_, op_ = plate_box(arc, abox, ag), plate_box(ours, obox, og)
    rows = []
    def pos(name, a, b): rows.append((name, a, b, max(abs(x - y) for x, y in zip(a, b)), None))
    def col(name, a, b): rows.append((name, '#%02X%02X%02X' % tuple(int(round(v)) for v in a), '#%02X%02X%02X' % tuple(int(round(v)) for v in b), None, de00(a, b)))
    pos('toast box [x0, y0, x1, y1]', abox, obox)
    names = ['ink "You can use"', 'ink keycap', 'ink "to easily show and hide your Sidebar!"']
    for name, a, b in zip(names, ag, og): pos(name + ' [x0, x1]', a, b)
    pos('ink rows [y0, y1]', ay, oy)
    pos('keycap plate [x0, y0, x1, y1]', ap_, op_)
    for label, dy in (('fill y + 2', 2), ('fill y + 43', 43)):
        for side, dx in (('left', 8), ('right', -8)):
            ax = abox[0] + dx if dx > 0 else abox[2] + dx; ox = obox[0] + dx if dx > 0 else obox[2] + dx
            col('%s %s' % (label, side), arc[abox[1] + dy, ax], ours[obox[1] + dy, ox])
    col('keycap plate fill', arc[ap_[1] + 3, ap_[0] + 3], ours[op_[1] + 3, op_[0] + 3])
    col('text core', acore, ocore)
    worst_pos = max(r[3] for r in rows if r[3] is not None); worst_de = max(r[4] for r in rows if r[4] is not None)
    lines = ['| Element | Arc A0440 | Open | Position error (pt) | ΔE00 |', '|---|---|---|---:|---:|']
    for n, a, b, p, d in rows:
        lines.append('| %s | %s | %s | %s | %s |' % (n, a if isinstance(a, str) else list(map(int, a)), b if isinstance(b, str) else list(map(int, b)),
                                                    '' if p is None else '%g' % p, '' if d is None else '%.2f' % d))
    lines.append(''); lines.append('Worst position %g pt (target <= 1), worst dE00 %.2f (target <= 2): %s'
                                   % (worst_pos, worst_de, 'PASS' if worst_pos <= 1 and worst_de <= 2 else 'FAIL'))
    text = '\n'.join(lines); print(text)
    if o.out: open(o.out, 'w').write(text + '\n')
    return 0 if worst_pos <= 1 and worst_de <= 2 else 1

if __name__ == '__main__': sys.exit(main())
