#!/usr/bin/env python3
"""Render the real PiP windows over the plan's only fake: the video host."""
from pathlib import Path
import subprocess

out = Path(__file__).resolve().parent
repo = out.parents[3]
cli = repo / 'Packages/OpenKit/.build/release/features-render'
scenes = [
    ('regular-playing', '384x216', ['--state', 'playing', '--menu']),
    ('regular-paused', '384x216', ['--state', 'paused']),
    ('regular-ended', '384x216', ['--state', 'ended']),
    ('controls-hidden', '384x216', ['--controls', 'hidden']),
    ('compact-playing', '284x160', []),
    ('compact-paused', '284x160', ['--state', 'paused']),
    ('twitch', '384x216', ['--site', 'twitch', '--menu']),
    ('meet', '384x216', ['--site', 'meet', '--meeting', '--menu']),
    ('compact-meeting', '284x160', ['--site', 'meet', '--meeting']),
    ('youtube', '384x216', ['--site', 'youtube', '--menu']),
    ('precision-1', '384x216', ['--drag-precision', '1']),
    ('precision-3', '384x216', ['--drag-precision', '3']),
    ('precision-8', '384x216', ['--drag-precision', '8']),
    ('portrait', '252x448', []),
    ('portrait-minimum', '160x284', []),
    ('compact-precision-1', '284x160', ['--drag-precision', '1']),
    ('compact-precision-3', '284x160', ['--drag-precision', '3']),
    ('portrait-precision', '160x284', ['--drag-precision', '3']),
    ('portrait-precision-1', '160x284', ['--drag-precision', '1']),
    ('portrait-meeting', '160x284', ['--meeting', '--site', 'meet']),
    ('document-hover', '384x300', ['--document', '--document-hover-options']),
    ('square', '450x450', []),
    ('document', '384x300', ['--document', '--top-bar-title', 'example.test', '--menu']),
]
for name, size, extra in scenes:
    for scale in (1, 2):
        subprocess.run([str(cli), 'pip', '--out', str(out / f'{name}@{scale}x.png'),
                        '--size', size, '--scale', str(scale), *extra], check=True, stdout=subprocess.DEVNULL)
for name, args in [('invalid-size', ['--size', '0x216']), ('invalid-state', ['--state', 'unknown'])]:
    result = subprocess.run([str(cli), 'pip', '--out', str(out / 'invalid.png'), *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out / f'{name}.txt').write_text(f'exit={result.returncode}\n{result.stdout}')
    if result.returncode != 1 or (out / 'invalid.png').exists():
        raise RuntimeError(f'{name} did not reject invalid input')
print(f'{len(scenes) * 2} PNGs; native menu sidecars; two invalid CLI cases passed')
