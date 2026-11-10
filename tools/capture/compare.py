#!/usr/bin/env python3
"""Pair named evidence, make contact sheets, and retain missing-action gaps."""
import argparse
import json
from pathlib import Path
from PIL import Image, ImageDraw


def compare(arc, opened, out):
    out.mkdir(parents=True,exist_ok=True)
    a={p.relative_to(arc):p for p in arc.rglob('*.png') if 'window-' not in p.name and not p.parent.joinpath('timestamps.json').exists()}
    b={p.relative_to(opened):p for p in opened.rglob('*.png') if 'window-' not in p.name and not p.parent.joinpath('timestamps.json').exists()}
    lines=['# Capture gap report','','Pixel differences include different data and page content. They do not by themselves prove a design gap. Missing automation is distinct from a missing product surface.','','| Frame | Arc pixels | Open pixels | Evidence / gap |','|---|---|---|---|']
    sheets=[]
    for name in sorted(set(a)|set(b)):
        left=Image.open(a[name]).convert('RGB') if name in a else None
        right=Image.open(b[name]).convert('RGB') if name in b else None
        sizes=[str(im.size) if im else 'not captured' for im in (left,right)]
        lines.append('| %s | %s | %s | %s |' % (name,*sizes,'Pair captured; inspect surface and geometry' if left and right else 'Missing capture; product state unverified'))
        tile=Image.new('RGB',(1200,440),'#242424'); draw=ImageDraw.Draw(tile)
        for x,im,label in ((0,left,'Arc'),(600,right,'Open')):
            draw.text((x+12,8),label+' — '+str(name),fill='white')
            if im:
                im.thumbnail((588,400));tile.paste(im,(x+6,32))
            else: draw.text((x+16,64),'NOT CAPTURED',fill='white')
        sheets.append(tile)
    for i in range(0,len(sheets),3):
        sheet=Image.new('RGB',(1200,440*min(3,len(sheets)-i)),'#242424')
        for j,tile in enumerate(sheets[i:i+3]): sheet.paste(tile,(0,j*440))
        sheet.save(out/('sheet-%02d.png'%(i//3+1)))
    gaps=[]
    for path in opened.rglob('no-actions.json'):
        gaps.extend(json.loads(path.read_text()))
    lines+=['','## Socket action gaps','']
    for gap in gaps: lines.append('- '+gap['finding']+': `'+json.dumps(gap['step'],ensure_ascii=False)+'`')
    (out/'gap-report.md').write_text('\n'.join(lines)+'\n')
    return {'pairs':len(set(a)&set(b)),'arc_frames':len(a),'open_frames':len(b),'socket_action_gaps':len(gaps)}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('arc',type=Path);p.add_argument('open',type=Path);p.add_argument('--out',type=Path)
    args=p.parse_args();print(json.dumps(compare(args.arc,args.open,args.out or args.open.parent/'comparison')))


if __name__=='__main__': main()
