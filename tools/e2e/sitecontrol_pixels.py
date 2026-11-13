"""Real-window SCC element probes. Private captures never leave .re/."""
from pathlib import Path
import os
import statistics


def background_response(app, tab, private, env, scale):
    """R7 diagnostic only: sample identical panel points over flat web colors."""
    import time
    points = [(300, 140), (260, 250)]
    captures = {}
    for name, color in [('white', '#ffffff'), ('black', '#000000')]:
        app.eval(tab, "document.documentElement.style.background=" + repr(color)
                 + ";document.body.style.background=" + repr(color)
                 + ";Array.from(document.body.children).forEach(e=>e.style.visibility='hidden');true")
        app.eval(tab, 'new Promise(done=>requestAnimationFrame(()=>requestAnimationFrame(()=>done(true))))')
        time.sleep(.4)
        path = str(Path(private) / ('R7-' + name + '.png'))
        app.call('snapshot', path=path)
        _, _, pixel = env['read_image'](path, srgb=True)
        captures[name] = dict(snapshot=path, rgb=[list(pixel(x*scale, y*scale)) for x,y in points],
                              pageRGB=list(pixel(700*scale, 500*scale)))
    probes = [dict(point=list(point), whiteRGB=white, blackRGB=black,
                   deltaE00=env['chrome_delta_e'](white, black),
                   maxChannelChange=max(abs(a-b) for a,b in zip(white, black)))
              for point,white,black in zip(points,captures['white']['rgb'],captures['black']['rgb'])]
    for probe in probes:
        probe['barelyChanges'] = probe['deltaE00'] < 3
    page_changed = max(abs(a-b) for a,b in zip(captures['white']['pageRGB'],captures['black']['pageRGB'])) > 200
    return dict(status='INFO', risk='R-7', probes=probes, captures=captures, load=list(os.getloadavg()),
                pageChanged=page_changed, barelyChangesDeltaE00=3,
                remoteLayerSamplingRisk=all(p['barelyChanges'] for p in probes) if page_changed else None,
                diagnosticOnly=True,
                interpretation='With the page changed from white to black, ΔE00 < 3 at both probes indicates '
                               'that the within-window material does not sample the engine remote layer. '
                               'A larger response does not establish parity. S11/S12 acceptance is unchanged.',
                fallback='Separate follow-up PR: borderless child window with .behindWindow blending (plan §11.1).')


# LEAD 12:20 (2026-11-11) approves ΔE00 ≤ 4 for exactly these rows, all others keep ΔE00 ≤ 2. Reason: "Arc's backdrop
# kernel is wider than any public material; values at the panel's edges cannot be reproduced exactly".
EDGE_LIMIT = 4
# The More glyph sits inside the More circle and shares its edge limit (LEAD 17:55, at 1x and 2x).
EDGE_ELEMENTS = frozenset(['Arrow row %d' % i for i in range(1, 10)] + ['Share ring', 'New Boost ring', 'More circle', 'More glyph'])
# LEAD 12:40 closing rule: rows that still miss ΔE00 ≤ 4 after the last tuning session are INFO rows. They print the Arc
# target, Open's value and ΔE00, and still fail above ΔE00 10 or a position change over 1 pt.
INFO_ELEMENTS = frozenset(['Arrow row 0', 'Capture ring', 'Top rim', 'Bottom rim'])
INFO_LIMIT = 10
INFO_REASON = "edge value of Arc's backdrop blur; not reproducible with a public material (lead ruling 2026-11-11)"
def color_limit(name): return INFO_LIMIT if name in INFO_ELEMENTS else EDGE_LIMIT if name in EDGE_ELEMENTS else 2


def compare_live(path, state, scale, private, env, negative_path=None):
    captures = Path(env['ROOT'], '.re/runtime/sessions')
    frames = list(captures.glob('*09-site-controls-first/0010-*/win-73938.png'))
    if not frames:
        return {'status':'SKIP','reason':'no captures'}
    reference=str(frames[0])
    _,_,arc=env['read_image'](reference,srgb=True)
    _,_,ours=env['read_image'](path,srgb=True)
    snapshot_scale = scale
    if scale != 1:
        # The reference is a 1x Arc capture: compare a 1x box-filtered copy of a 2x snapshot (like-for-like rasterization).
        s, base = int(round(scale)), ours
        def ours(x, y, s=s, base=base):
            px = [base(int(x) * s + i + .5, int(y) * s + j + .5) for i in range(s) for j in range(s)]
            return tuple(sum(p[c] for p in px) / len(px) for c in range(3))
        scale = 1
    delta=env['chrome_delta_e']
    bx,by,bw,bh=state['body']
    # Same elements, with footer translated to each panel's measured bottom.
    # Content-setting strings differ because E1 does not yet expose Arc's PiP
    # setting. Do not pretend those different strings are an ink-box match.
    probes=[]
    def fill(name, a, o):
        def mean(px, rect, factor):
            x,y,w,h=rect
            points=[px((u+.5)*factor,(v+.5)*factor)
                    for v in range(round(y),round(y+h)) for u in range(round(x),round(x+w))]
            return [statistics.mean(p[i] for p in points) for i in range(3)]
        ac,oc=mean(arc,a,1),mean(ours,o,scale)
        de=delta(ac,oc)
        probes.append(dict(element=name,arcRGB=ac,openRGB=oc,deltaE00=de,limit=color_limit(name),ok=de<=color_limit(name),
                           **({'status':'INFO','reason':INFO_REASON} if name in INFO_ELEMENTS else {})))
    def add(name, a, o, text=False, arrow=False):
        def plane(px, rect, factor):
            x,y,w,h=rect
            if arrow:
                # Match sitecontrol-render's existing Bitmap.arrowInk. The
                # top/bottom ring contains adjacent arrow ink, not background.
                x0,y0,x1,y1=int(x),int(y),int(x+w),int(y+h)
                pixel=lambda u,v:px((u+.5)*factor,(v+.5)*factor)
                left,right=pixel(x0-1,y0),pixel(x1,y0)
                samples=[]
                for u in range(x0,x1):
                    t=(u-x0+1)/(x1-x0+1); p=pixel(u,y0)
                    samples.append((u,max(abs(p[i]-(left[i]*(1-t)+right[i]*t)) for i in range(3))))
                peak=max((c for u,c in samples),default=0)
                if peak<=6:return None,None
                ink=[u for u,c in samples if c>=peak*.5]
                core=[pixel(u,y0) for u,c in samples if c>=peak*.85]
                return [min(ink),y0,max(ink)+1,y1],[statistics.mean(p[i] for p in core) for i in range(3)]
            points=[]
            for u in range(int(x)-1,int(x+w)+1):
                for v in (int(y)-1,int(y+h)): points.append((u,v))
            for v in range(int(y),int(y+h)):
                for u in (int(x)-1,int(x+w)): points.append((u,v))
            def lum(u,v):
                c=px((u+.5)*factor,(v+.5)*factor);return .2126*c[0]+.7152*c[1]+.0722*c[2]
            # Least-squares plane from the one-pixel ring (§8.3).
            m=[[0.0]*4 for _ in range(3)]
            for u,v in points:
                row=[1,u,v]; z=lum(u,v)
                for i in range(3):
                    for j in range(3):m[i][j]+=row[i]*row[j]
                    m[i][3]+=row[i]*z
            for i in range(3):
                pivot=max(range(i,3),key=lambda j:abs(m[j][i]));m[i],m[pivot]=m[pivot],m[i]
                if abs(m[i][i])<1e-9:return None,None
                f=m[i][i];m[i]=[t/f for t in m[i]]
                for j in range(3):
                    if i!=j:
                        f=m[j][i];m[j]=[q-f*t for q,t in zip(m[j],m[i])]
            coeff=[m[i][3] for i in range(3)]
            ink=[]
            for v in range(round(y),round(y+h)):
                for u in range(round(x),round(x+w)):
                    contrast=abs(lum(u,v)-coeff[0]-coeff[1]*u-coeff[2]*v)
                    ink.append((contrast,u,v))
            maximum=max((v[0] for v in ink),default=0)
            selected=[(u,v) for c,u,v in ink if maximum>6 and c>=maximum*.5]
            if not selected:return None,None
            box=[min(p[0] for p in selected),min(p[1] for p in selected),max(p[0] for p in selected)+1,max(p[1] for p in selected)+1]
            core=[px((u+.5)*factor,(v+.5)*factor) for c,u,v in ink if c>=maximum*.85]
            return box,[statistics.mean(p[i] for p in core) for i in range(3)]
        ab,ac=plane(arc,a,1);ob,oc=plane(ours,o,scale)
        # Position compares local ink edges, so the shorter interim panel can
        # still use the captured footer. Thresholds stay ≤1 pt and DE00 ≤2.
        if ab and ob:
            aa=[ab[0]-a[0],ab[1]-a[1],ab[2]-a[0],ab[3]-a[1]]
            oo=[ob[0]-o[0],ob[1]-o[1],ob[2]-o[0],ob[3]-o[1]]
            error=max(abs(u-v) for u,v in zip(aa,oo))
        else:error=None
        de=delta(ac,oc) if ac and oc else None
        probes.append(dict(element=name,arcBox=ab,openBox=ob,positionError=error,deltaE00=de,
                           limit=color_limit(name),ok=error is not None and error<=1 and (text or de is not None and de<=color_limit(name)),
                           **({'status':'INFO','reason':INFO_REASON} if name in INFO_ELEMENTS else {})))
    for row in range(10):
        add('Arrow row '+str(row),[183,81+row,36,1],[state['tip'][0]-18,state['tip'][1]+row,36,1],arrow=True)
    for i,name in enumerate(['Share','New Boost','Capture','Capture Full Page']):
        # New Boost is intentionally disabled until the runtime is wired.
        if name=='New Boost' and not next(c for c in state['controls'] if c['id']=='action.newBoost')['enabled']:continue
        add(name+' glyph',[83+10+i*56+10,91+14,28,24],[bx+10+i*56+10,by+14,28,24])
        for label,dx,dy,w,h in [('fill',3,14,2,4),('top',3,2,1,1),('bottom',3,30,1,1),('highlight',12,0,24,1),('ring',8,-1,32,1)]:
            fill(name+' '+label,[93+i*56+dx,101+dy,w,h],[bx+10+i*56+dx,by+10+dy,w,h])
    add('Extensions label',[91,143,90,20],[bx+8,by+52,90,20],text=True)
    add('Settings label',[91,218,75,20],[bx+8,by+127,75,20],text=True)
    add('Extension + glyph',[108,176,18,20],[bx+25,by+85,18,20])
    fill('Extension + tile',[99,195,3,3],[bx+16,by+104,3,3])
    # The second captured settings row and our Camera row are both allowed.
    # Their different glyphs/titles are excluded; compare the disc and subtitle.
    add('Allowed circle',[92,287,34,34],[bx+9,by+196,34,34])
    fill('Allowed circle fill',[98,293,2,2],[bx+15,by+202,2,2])
    add('Allowed subtitle',[132,305,90,17],[bx+49,by+214,90,17],text=True)
    add('More glyph',[285,355,16,14],[bx+202,by+bh-33,16,14])
    fill('More circle',[289,370,8,2],[bx+206,by+bh-18,8,2])
    fill('Separator',[263,335,30,1],[bx+180,by+bh-53,30,1])
    fill('Top rim',[120,91,1,1],[bx+37,by,1,1])
    fill('Bottom rim',[120,387,1,1],[bx+37,by+bh-1,1,1])
    report=dict(ok=all(p['ok'] for p in probes),elements=probes,capture=reference,snapshot=path,
                limits={'positionPoints':1,'deltaE00':2,'edgeDeltaE00':EDGE_LIMIT,'edgeElements':sorted(EDGE_ELEMENTS),
                        'infoDeltaE00':INFO_LIMIT,'infoElements':sorted(INFO_ELEMENTS),'infoReason':INFO_REASON},
                excluded='Different site-setting title/glyph and HTTP Insecure pill; Developer Mode per Q14',
                load=list(os.getloadavg()))
    if negative_path:
        negative=compare_live(negative_path,state,snapshot_scale,private,env)
        report['negativeRejected']=not negative['ok']
        report['negativeFailedElements']=[p['element'] for p in negative['elements'] if not p['ok']]
        report['ok']=report['ok'] and report['negativeRejected']
        (Path(private)/'S12-elements.json').write_text(__import__('json').dumps(report,indent=2))
    return report


# Arc 1.172 session 2, 14c-sidebar-url/s2-sidebar-site-control (golden Space, Light, page #F3F5EE, 1280×800, sidebar 366,
# panel body [221,91,236,254]). Numbers only: body-relative point → sRGB (embedded ICC → sRGB, 3×3 mean at 2×).
# Footer samples are measured from the panel's bottom edge (negative y): the fixture may show more setting rows.
ARC_LIGHT = [('body left third', (40, 150), (237, 211, 138), 3), ('body right third', (200, 150), (246, 248, 234), 3),
             ('tile', (14, 26), (250, 250, 250), 3), ('footer chip', (30, -18), (225, 200, 131), 3),
             ('footer hairline', (120, -53), (213, 190, 125), None)]
# Arc 14c's visible golden sidebar is #B9A35F. This synthetic key recreates that
# backdrop with #344's light-theme law. The old fitted #BD9C26 key predates that
# law and now draws a brighter sidebar; it was never a captured Arc editor key.
GOLD = {'mathVersion': 1, 'keyColor': {'red': 0x9F / 255, 'green': 0x7C / 255, 'blue': 0x12 / 255, 'alpha': 1}, 'colorCount': 1,
        'wheel': 'analogous', 'appearance': 'automatic', 'noiseFactor': 0, 'texture': 'grain', 'intensityFactor': .8}


def light_and_ghost(app, origin, private, env, record):
    """S11_light: the Light material against Arc 14c. S14_no_ghost: shapes behind the panel are not recognisable in it."""
    import time
    wait = env['wait_until']
    app.call('appearance', name='light')
    app.call('window-frame', frame=[80, 60, 1280, 800])
    state = app.call('window-state')
    if state['sidebarWidth'] != 366:
        app.call('mouse', **{'from': [state['sidebarWidth'], 400], 'to': [366, 400]})
    app.call('theme-set', style=GOLD); time.sleep(.6)
    tabs = [env['new_tab'](app, origin + '/light.html?%d' % i) for i in range(6)]
    for t in tabs: app.call('wait', tab=t)
    def opened():
        if app.call('site-controls', action='state')['presented']: app.call('site-controls', action='close')
        s = app.call('site-controls', action='open', via='urlField')
        app.call('mouse', action='hover', x=800, y=500); time.sleep(.5)
        return s
    def snap(name):
        path = str(Path(private) / name)
        app.call('snapshot', path=path, window=app.call('window-state')['number']); return path
    # The panel's empty material beside the Add tile: body + (70…130, 82…108) over the sidebar, + (160…225, 82…108) over the page.
    app.call('select', tab=tabs[0]); s = opened(); bx, by = s['body'][0], s['body'][1]
    rows = {t: app.call('sidebar-row', node=t)['frame'] for t in tabs}
    band = (by + 82, by + 108)
    behind = max(tabs, key=lambda t: min(rows[t][1] + rows[t][3], band[1]) - max(rows[t][1], band[0]))
    away = min(tabs, key=lambda t: abs(rows[t][1] - (by + 300)))
    # A: the selected row and a black page block behind the empty material. B: neither.
    app.call('select', tab=behind)
    app.eval(behind, "document.getElementById('ghost').style.visibility='visible';true")
    s = opened(); a_path = snap('S14-with-shapes.png')
    width, _, px = env['read_image'](a_path, srgb=True); scale = width / app.call('window-state')['frame'][2]
    delta = env['chrome_delta_e']
    probes = []
    bh = s['body'][3]
    at = lambda y: y if y >= 0 else bh + y
    for name, (x, y), target, limit in ARC_LIGHT:
        y = at(y)
        pts = [px((bx + x + dx / 2) * scale, (by + y + dy / 2) * scale) for dx in (-1, 0, 1) for dy in (-1, 0, 1)]
        rgb = [sum(p[i] for p in pts) / 9 for i in range(3)]
        de = delta(rgb, list(target))
        probes.append(dict(element=name, point=[x, y], arc=list(target), open=rgb, deltaE00=round(de, 2), limit=limit,
                           ok=limit is None or de <= limit))
    app.call('site-controls', action='close'); time.sleep(.3)
    # The same state without the panel: the S11_light negative and the S14 "shapes are visible" proof.
    _, _, neg = env['read_image'](snap('S11-light-closed.png'), srgb=True)
    closed_px = neg
    # Verify the captured scene's input too, so a later theme-law change cannot
    # silently compare a different backdrop with the same material targets.
    backdrop = list(neg(4 * scale, 150 * scale))[:3]
    backdrop_delta = delta(backdrop, [185, 163, 95])
    record('S11_light_backdrop', backdrop_delta <= 1, rgb=backdrop, arc=[185, 163, 95],
           deltaE00=round(backdrop_delta, 2), limit=1, point=[4, 150])
    negative = [delta(list(neg((bx + x) * scale, (by + at(y)) * scale)), list(t)) for _, (x, y), t, limit in ARC_LIGHT if limit]
    negative_rejected = any(d > 3 for d in negative)
    record('S11_light', all(p['ok'] for p in probes) and negative_rejected, probes=probes, negativeDeltaE00=negative,
           negativeRejected=negative_rejected, reference='Arc 1.172 14c s2-sidebar-site-control (numbers only)', scale=scale)
    # B: another tab selected (its row far below), the page block hidden.
    app.call('select', tab=away)
    for t in tabs: app.eval(t, "document.getElementById('ghost').style.visibility='hidden';true")
    opened(); b_path = snap('S14-without-shapes.png')
    _, _, pb = env['read_image'](b_path, srgb=True)
    app.call('site-controls', action='close'); time.sleep(.3)
    _, _, closed_b = env['read_image'](snap('S14-without-shapes-closed.png'), srgb=True)
    def luminance(c):
        f = lambda v: (v / 255) / 12.92 if v / 255 <= 0.04045 else (((v / 255) + 0.055) / 1.055) ** 2.4
        return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2])
    def region(p, x0, x1):
        vals = [luminance(p(x * scale, y * scale)) for x in range(bx + x0, bx + x1, 2) for y in range(band[0], band[1], 2)]
        return sum(vals) / len(vals)
    areas = {'selected row': (70, 130), 'page heading': (160, 225)}
    contrast = {k: (max(region(px, *v), region(pb, *v)) + .05) / (min(region(px, *v), region(pb, *v)) + .05) for k, v in areas.items()}
    # Negative proof: the same shapes without the panel are plainly recognisable.
    neg_contrast = {k: (max(region(closed_px, *v), region(closed_b, *v)) + .05) / (min(region(closed_px, *v), region(closed_b, *v)) + .05) for k, v in areas.items()}
    record('S14_no_ghost', all(c < 1.05 for c in contrast.values()) and all(c >= 1.05 for c in neg_contrast.values()), contrast={k: round(v, 4) for k, v in contrast.items()},
           limit=1.05, rows={'behind': rows[behind], 'band': list(band)}, snapshots=[a_path, b_path],
           sameStateWithoutPanelContrast={k: round(v, 3) for k, v in neg_contrast.items()})
    app.call('site-controls', action='close')
    # S11_light_neutral: Night (Open's default theme), Light, same page. The panel adds no yellow cast of its own: the
    # right-third body equals the same point with the tint layer off (ΔE00 ≤ 2), and its b* is within ±2 of the page's.
    app.call('theme-set', style=None); time.sleep(.6)
    app.call('select', tab=tabs[0])
    s = opened(); bx, by = s['body'][0], s['body'][1]
    point = ((bx + 200) * scale, (by + 150) * scale)
    _, _, with_tint = env['read_image'](snap('S11-neutral-tint.png'), srgb=True)
    app.call('site-controls', action='material', appearance='light', material=10, overlay=[246 / 255, 246 / 255, 232 / 255, 0.4], tintAlpha=0)
    time.sleep(.4)
    _, _, without = env['read_image'](snap('S11-neutral-notint.png'), srgb=True)
    app.call('site-controls', action='material', appearance='light', material=-1)
    app.call('site-controls', action='close'); time.sleep(.3)
    _, _, page = env['read_image'](snap('S11-neutral-closed.png'), srgb=True)
    a_rgb, b_rgb, p_rgb = list(with_tint(*point)), list(without(*point)), list(page(*point))
    de = delta(a_rgb, b_rgb); b_star = lab(a_rgb)[2]; page_b = lab(p_rgb)[2]
    record('S11_light_neutral', de <= 2 and abs(b_star - page_b) <= 2, withTint=a_rgb, tintOff=b_rgb, deltaE00=round(de, 2),
           bStar=round(b_star, 2), pageBStar=round(page_b, 2), page=p_rgb)


def lab(rgb):
    def lin(c):
        c = c / 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(v) for v in rgb[:3])
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    f = lambda t: t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116
    return 116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))
