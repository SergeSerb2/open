#!/usr/bin/env python3
"""Pair named evidence, make contact sheets, and retain missing-action gaps."""
import argparse
import json
from pathlib import Path
from PIL import Image, ImageDraw
from session import walk


def observed_surface(path):
    """Classify saved state from observed AX/socket fields, never frame names."""
    meta = json.loads(path.with_suffix('.meta.json').read_text())
    state = meta.get('observedSurface', 'not classified')
    axfile = path.with_suffix('.ax.json')
    tree = json.loads(axfile.read_text()) if axfile.exists() else {}
    if state == 'browser or other':
        if tree.get('source') == 'Open automation socket':
            number = meta.get('window',{}).get('number')
            if any(s.get('window') == number for s in tree.get('little-open-state',{}).get('sessions',[])):
                return 'little-browser'
            if tree.get('commandbar-state',{}).get('presented'):
                return 'commandbar'
            if tree.get('peek-state',{}).get('shown'):
                return 'peek'
            if any(p.get('visible') for p in tree.get('find-state',{}).get('panes',[])):
                return 'find'
        else:
            bounds = meta.get('window',{}).get('bounds',{})
            expected = [bounds.get(k) for k in ('X','Y','Width','Height')]
            windows = [n for n in walk(tree) if n.get('role') == 'AXWindow' and n.get('frame') == expected]
            if len(windows) == 1:
                selected = windows[0]
                if selected.get('id','').startswith('littleBrowserWindow-'):
                    return 'little-browser'
                ids = {n.get('id') for n in walk(selected)}
                if {'confirmCloseModal', 'openInSplit'} <= ids:
                    return 'peek'
                if 'findInPageTextField' in ids:
                    return 'find'
                if 'commandBarTextField' in ids and 'commandBarSuggestions' in ids:
                    return 'commandbar'
    if state == 'library':
        sections = {'Search Media…': 'media', 'Search Downloads…': 'downloads',
                    'Search Easels…': 'easels', 'Search Boosts…': 'boosts',
                    'Search Archive…': 'archive'}
        found = {sections[n['placeholder']] for n in walk(tree)
                 if n.get('role') == 'AXTextField' and n.get('placeholder') in sections}
        if len(found) == 1:
            return 'library/' + found.pop()
        roles = {n.get('role') for n in walk(tree)}
        buttons = {n.get('desc') for n in walk(tree) if n.get('role') == 'AXButton'}
        if not found and {'AXOutline', 'AXRow'} <= roles and {'Media', 'Spaces', 'Downloads'} <= buttons:
            return 'library/spaces'
    return state


def capture_actions(root):
    result={}
    for log in root.rglob('session.jsonl'):
        last={}
        for line in log.read_text().splitlines():
            row=json.loads(line);kind=row.get('step')
            if kind=='start': last={}
            elif kind=='begin' and row['operation']['op'] not in ('launch','shot','axdump','burst','sleep','wait_ax'):
                last={'operation':row['operation'],'status':'attempted'}
            elif kind in ('no-action','not-captured'):
                last={'operation':row['operation'],'status':'not captured'}
            elif kind=='end' and last.get('status')=='attempted' and row.get('operation')==last.get('operation',{}).get('op'):
                last['status']='performed'
            elif kind=='shot':
                result[(log.parent/Path(row['frame_file']).name).relative_to(root)]=dict(last)
    # A derived selection can combine multiple original blocks. Preserve each
    # frame's actual source action instead of losing gaps when logs stay raw.
    qualifications = root / 'capture-qualifications.json'
    if qualifications.exists():
        result.update({Path(name): value for name, value in json.loads(qualifications.read_text()).items()})
    return result


def compare(arc, opened, out):
    out.mkdir(parents=True,exist_ok=True)
    for old in out.glob('sheet-*.png'):
        old.unlink()
    a={p.relative_to(arc):p for p in arc.rglob('*.png') if 'window-' not in p.name and p.with_suffix('.meta.json').exists()}
    b={p.relative_to(opened):p for p in opened.rglob('*.png') if 'window-' not in p.name and p.with_suffix('.meta.json').exists()}
    lines=['# Capture gap report','','Pixel differences include different data and page content. They do not by themselves prove a design gap. Missing automation is distinct from a missing product surface.','','| Frame | Arc pixels | Open pixels | Evidence / gap |','|---|---|---|---|']
    sheets=[]
    differences=[]
    open_actions=capture_actions(opened);arc_actions=capture_actions(arc)
    for name in sorted(set(a)|set(b)):
        left=Image.open(a[name]).convert('RGB') if name in a else None
        right=Image.open(b[name]).convert('RGB') if name in b else None
        sizes=[str(im.size) if im else 'not captured' for im in (left,right)]
        states=[]
        for files in (a,b):
            states.append(observed_surface(files[name]) if name in files else 'not captured')
        state_mismatch = left is not None and right is not None and states[0] != states[1]
        if state_mismatch:
            differences.append({'frame':str(name),'kind':'different captured states','arc':states[0],'open':states[1],
                                'status':'not a same-state comparison; inspect action gaps and persisted section'})
        if not left or not right:
            differences.append({'frame':str(name),'kind':'missing capture','detail':'Arc' if not left else 'Open','status':'product surface unverified'})
        elif left.size != right.size:
            differences.append({'frame':str(name),'kind':'size','arc':list(left.size),'open':list(right.size),'status':'observed; window sizes may differ'})
        measured=[]
        for root in (arc,opened):
            path=(root/name).with_suffix('.measure.json')
            measured.append(json.loads(path.read_text()) if path.exists() else {})
        am,bm=measured
        def unique_elements(m):
            groups={}
            for e in m.get('elements',[]):
                if e.get('id'): groups.setdefault((e.get('role'),e['id']),[]).append(e)
            return {k:v[0] for k,v in groups.items() if len(v)==1}
        ae,be=unique_elements(am),unique_elements(bm)
        for key in sorted(set(ae)&set(be)):
            af,bf=ae[key]['relative_points'],be[key]['relative_points']
            if af[2:] != bf[2:]: differences.append({'frame':str(name),'kind':'element size','element':key,'arc':af[2:],'open':bf[2:],'status':'observed'})
            if af[:2] != bf[:2]: differences.append({'frame':str(name),'kind':'position / spacing','element':key,'arc':af[:2],'open':bf[:2],'status':'observed'})
        for sample in sorted(set(am.get('samples',{}))&set(bm.get('samples',{}))):
            ac,bc=am['samples'][sample].get('srgb_hex'),bm['samples'][sample].get('srgb_hex')
            if ac and bc and ac!=bc: differences.append({'frame':str(name),'kind':'colour','sample':sample,'arc':ac,'open':bc,'status':'observed; data and appearance must match'})
        action=open_actions.get(name,{})
        action_gap=action.get('status')=='not captured'
        arc_action_gap=arc_actions.get(name,{}).get('status')=='not captured'
        evidence='Requested Open action not captured; image shows the previous state' if action_gap else ('Pair captured; inspect surface and geometry' if left and right else 'Missing capture; product state unverified')
        if state_mismatch: evidence+='; DIFFERENT CAPTURED STATES'
        if arc_action_gap: evidence+='; requested Arc action not captured'
        evidence+='; observed Arc: '+states[0]+'; Open: '+states[1]
        lines.append('| %s | %s | %s | %s |' % (name,*sizes,evidence))
        tile=Image.new('RGB',(1200,440),'#242424'); draw=ImageDraw.Draw(tile)
        present=[im for im in (left,right) if im]
        factor=min(1,588/max(im.width for im in present),400/max(im.height for im in present))
        for index,(x,im,label) in enumerate(((0,left,'Arc'),(600,right,'Open'))):
            if label=='Open' and action_gap: label+=' [NO ACTION]'
            if label=='Arc' and arc_action_gap: label+=' [NO ACTION]'
            size=('%dx%d'%im.size) if im else 'not captured'
            draw.text((x+12,8),label+' '+size+' | '+str(name),fill='white')
            draw.text((x+12,20),states[index],fill='#BBBBBB')
            if im:
                im=im.resize((max(1,round(im.width*factor)),max(1,round(im.height*factor))),Image.Resampling.LANCZOS)
                tile.paste(im,(x+6,32))
            else: draw.text((x+16,64),'NOT CAPTURED',fill='white')
        sheets.append(tile)
    for i in range(0,len(sheets),3):
        sheet=Image.new('RGB',(1200,440*min(3,len(sheets)-i)),'#242424')
        for j,tile in enumerate(sheets[i:i+3]): sheet.paste(tile,(0,j*440))
        sheet.save(out/('sheet-%02d.png'%(i//3+1)))
    gaps=[]
    for path in opened.rglob('no-actions.json'):
        gaps.extend(json.loads(path.read_text()))
    (out/'differences.json').write_text(json.dumps(differences,indent=2))
    lines+=['','## Measured differences','','| Frame | Kind | Evidence |','|---|---|---|']
    for d in differences: lines.append('| %s | %s | %s |'%(d['frame'],d['kind'],json.dumps({k:v for k,v in d.items() if k not in ('frame','kind')})))
    lines+=['','Missing AX elements are not classified as missing product elements when a backend lacks a complete AX snapshot. Motion fits remain qualified in each burst measurement.','','## Socket action gaps','']
    for gap in gaps: lines.append('- '+gap['finding']+': `'+json.dumps(gap['step'],ensure_ascii=False)+'`')
    (out/'gap-report.md').write_text('\n'.join(lines)+'\n')
    return {'pairs':len(set(a)&set(b)),'arc_frames':len(a),'open_frames':len(b),'socket_action_gaps':len(gaps)}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('arc',type=Path);p.add_argument('open',type=Path);p.add_argument('--out',type=Path)
    args=p.parse_args();print(json.dumps(compare(args.arc,args.open,args.out or args.open.parent/'comparison')))


if __name__=='__main__': main()
