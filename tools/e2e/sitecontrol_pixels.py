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
        captures[name] = dict(snapshot=path, rgb=[list(pixel(x*scale, y*scale)) for x,y in points])
    probes = [dict(point=list(point), whiteRGB=white, blackRGB=black,
                   deltaE00=env['chrome_delta_e'](white, black),
                   maxChannelChange=max(abs(a-b) for a,b in zip(white, black)))
              for point,white,black in zip(points,captures['white']['rgb'],captures['black']['rgb'])]
    return dict(probes=probes, captures=captures, load=list(os.getloadavg()),
                diagnosticOnly=True, interpretation='A small change is evidence for R7; this does not alter S11/S12 acceptance.')


def compare_live(path, state, scale, private, env, negative_path=None):
    captures = Path(env['ROOT'], '.re/runtime/sessions')
    frames = list(captures.glob('*09-site-controls-first/0010-*/win-73938.png'))
    if not frames:
        return {'status':'SKIP','reason':'no captures'}
    reference=str(frames[0])
    _,_,arc=env['read_image'](reference,srgb=True)
    _,_,ours=env['read_image'](path,srgb=True)
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
        probes.append(dict(element=name,arcRGB=ac,openRGB=oc,deltaE00=de,ok=de<=2))
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
                           ok=error is not None and error<=1 and (text or de is not None and de<=2)))
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
                limits={'positionPoints':1,'deltaE00':2},
                excluded='Different site-setting title/glyph and HTTP Insecure pill; disabled New Boost until provider; Developer Mode per Q14',
                load=list(os.getloadavg()))
    if negative_path:
        negative=compare_live(negative_path,state,scale,private,env)
        report['negativeRejected']=not negative['ok']
        report['negativeFailedElements']=[p['element'] for p in negative['elements'] if not p['ok']]
        report['ok']=report['ok'] and report['negativeRejected']
        (Path(private)/'S12-elements.json').write_text(__import__('json').dumps(report,indent=2))
    return report
