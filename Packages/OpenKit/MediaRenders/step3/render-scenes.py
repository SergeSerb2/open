#!/usr/bin/env python3
from pathlib import Path
import subprocess, tempfile
repo = Path(__file__).resolve().parents[4]
cli = repo / 'Packages/OpenKit/.build/release/sidebar-render'
out = Path(__file__).resolve().parent
scenes = [
    ('audio-playing', 'today:0=playing:tracks', []),
    ('paused', 'today:0=paused', []),
    ('muted', 'today:0=playing:muted', []),
    ('video', 'today:0=playing:video', []),
    ('recording', 'today:0=recording', []),
    ('drawer', 'today:0=playing', ['--media-drawer', '0']),
    ('stack-collapsed', 'today:0=playing,today:1=paused,today:2=playing:video', []),
    ('stack-expanded', 'today:0=playing,today:1=paused,today:2=playing:video', ['--media-hover', 'stack']),
    ('title-hover', 'today:0=playing:long', ['--media-hover', 'title:0']),
    ('card-hover', 'today:0=playing:video', ['--media-hover', 'card:0'])]
with tempfile.TemporaryDirectory(prefix='open-mini-scene-') as fixture:
    subprocess.run([str(cli), 'synth', '--out', fixture], check=True)
    for width in [228, 500]:
        for appearance in ['light', 'dark']:
            for name, spec, extra in scenes:
                subprocess.run([str(cli), 'render', '--snapshot', fixture, '--out', str(out / f'{name}-{appearance}-{width}.png'),
                                '--size', '1280x900', '--width', str(width), '--appearance', appearance, '--scale', '2',
                                '--media', spec, '--media-theme', 'default', '--crop-media-controls', *extra], check=True, stdout=subprocess.DEVNULL)
    for appearance in ['light', 'dark']:
        extras = [
            ('themed', 228, 'today:0=playing:tracks', ['--media-theme', 'red']),
            ('narrow-hover', 180, 'today:0=playing:video:long:tracks', ['--media-hover', 'card:0']),
            ('narrow-drawer', 180, 'today:0=playing', ['--media-drawer', '0']),
            ('button-hover', 228, 'today:0=playing:tracks', ['--media-button-hover', 'play']),
            ('button-pressed', 228, 'today:0=playing:tracks', ['--media-button-hover', 'play', '--media-button-pressed']),
            ('tooltip', 228, 'today:0=playing:tracks', ['--media-button-hover', 'play', '--media-tooltip']),
            ('increase-contrast', 228, 'today:0=playing:tracks', ['--media-increase-contrast']),
        ]
        for name, width, spec, extra in extras:
            subprocess.run([str(cli), 'render', '--snapshot', fixture, '--out', str(out / f'{name}-{appearance}-{width}.png'),
                            '--size', '1280x900', '--width', str(width), '--appearance', appearance, '--scale', '2',
                            '--media', spec, '--crop-media-controls', *([] if '--media-theme' in extra else ['--media-theme', 'default']), *extra], check=True, stdout=subprocess.DEVNULL)
        subprocess.run([str(cli), 'render', '--snapshot', fixture, '--out', str(out / f'full-sidebar-{appearance}-228.png'),
                        '--size', '1280x900', '--width', '228', '--appearance', appearance, '--scale', '2',
                        '--media', 'today:0=playing:tracks', '--media-theme', 'default'], check=True, stdout=subprocess.DEVNULL)
print('renders', len(list(out.glob('*.png'))), out)
