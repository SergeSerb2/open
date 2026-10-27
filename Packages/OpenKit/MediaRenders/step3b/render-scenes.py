#!/usr/bin/env python3
"""Offscreen synthetic mini-player matrix. No Arc assets or private text."""
from pathlib import Path
import subprocess, tempfile
repo=Path(__file__).resolve().parents[4]
cli=repo/'Packages/OpenKit/.build/release/sidebar-render'
out=Path(__file__).resolve().parent
scenes=[
 ('rest','today:0=playing:video',[]),
 ('paused','today:0=paused',[]),
 ('muted','today:0=playing:muted',[]),
 ('disabled-tracks','today:0=playing',[]),
 ('audio-expanded','today:0=playing:long',['--media-hover','expanded']),
 ('video-expanded','today:0=playing:video:long',['--media-hover','expanded','--media-button-hover','volume']),
 ('button-pressed','today:0=playing:tracks',['--media-button-hover','play','--media-button-pressed']),
 ('tooltip','today:0=playing:tracks',['--media-button-hover','play','--media-tooltip']),
 ('stack-collapsed','today:0=playing:video,today:1=paused,today:2=playing:video',[]),
 ('stack-expanded','today:0=playing:video,today:1=paused,today:2=playing:video',['--media-hover','expanded','--media-button-hover','play:0']),
 ('drawer','today:0=playing',['--media-hover','expanded','--media-drawer','0']),
 ('recording','today:0=recording',[]),
 ('increase-contrast','today:0=playing:tracks',['--media-increase-contrast'])]
with tempfile.TemporaryDirectory(prefix='open-mini-step3b-') as fixture:
 subprocess.run([str(cli),'synth','--out',fixture],check=True,stdout=subprocess.DEVNULL)
 def render(name,spec,extra,width,appearance,scale=2,crop=True,size='1280x900'):
  subprocess.run([str(cli),'render','--snapshot',fixture,'--out',str(out/f'{name}-{appearance}-{width}.png'),'--size',size,'--width',str(width),'--appearance',appearance,'--scale',str(scale),'--media',spec,'--media-theme','red' if name=='red' else 'default',*(['--crop-media-controls'] if crop else []),*extra],check=True,stdout=subprocess.DEVNULL)
 for width in [228,500]:
  for appearance in ['light','dark']:
   for name,spec,extra in scenes:render(name,spec,extra,width,appearance)
 for appearance in ['light','dark']:
  render('red','today:0=playing:video',['--media-hover','expanded'],228,appearance)
  for name,extra in [('rest',[]),('expanded',['--media-hover','expanded'])]:
   render(name,'today:0=playing:video:long',extra,164,appearance)
 # Compare geometry at 1x, with synthetic text only in these committed images.
 for name,spec,extra in [scenes[0],scenes[5],('stack','today:0=playing:video,today:1=playing:video,today:2=playing:video',[]),('stack-expanded','today:0=playing:video,today:1=playing:video,today:2=playing:video',['--media-hover','expanded','--media-button-hover','play:0'])]:
  render('R-'+name,spec,extra,228,'dark',scale=1,crop=False,size='1728x1084')
print('renders',len(list(out.glob('*.png'))))
