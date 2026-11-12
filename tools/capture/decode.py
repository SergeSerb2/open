#!/usr/bin/env python3
"""Decode completed own-application movies off screen, preserving movie PTS."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys


def decode(directory):
    movie = directory / 'capture.mov'
    destination = directory / 'timestamps.json'
    original = directory / 'capture-stream-timestamps.json'
    if not destination.exists() and not original.exists():
        raise RuntimeError('recorder did not finalize timestamps; movie is unqualified')
    if movie.stat().st_size > 512*1024*1024:
        raise RuntimeError('movie exceeds512MiB')
    if not original.exists():
        shutil.copy2(destination, original)
    receipt = json.loads(original.read_text())
    ffmpeg, ffprobe = shutil.which('ffmpeg'), shutil.which('ffprobe')
    if not ffmpeg or not ffprobe:
        raise RuntimeError('ffmpeg and ffprobe are required; movie and original receipts remain intact')
    probe = json.loads(subprocess.check_output([ffprobe, '-v', 'error', '-select_streams', 'v:0',
        '-read_intervals','%+#1001','-show_frames', '-show_entries', 'frame=best_effort_timestamp_time', '-of', 'json', str(movie)], text=True,timeout=20))
    times = [float(f['best_effort_timestamp_time']) for f in probe['frames'] if 'best_effort_timestamp_time' in f]
    if len(times)>1000 or (times and times[-1]-times[0]>7):
        raise RuntimeError('movie exceeds1000 frames or7seconds')
    with (directory/'decode.log').open('w') as log:
        subprocess.run([ffmpeg, '-v', 'warning', '-threads', '2', '-i', str(movie),
            '-fps_mode', 'passthrough', '-start_number', '0', '-threads', '2', '-y', str(directory/'%04d.png')],
            check=True, stdout=log, stderr=subprocess.STDOUT)
    images = sorted(directory.glob('[0-9][0-9][0-9][0-9].png'))
    if len(times) != len(images) or not times:
        raise RuntimeError('decoded frame count differs from movie timestamp count')
    receipt['method'] = 'ScreenCaptureKit movie; native frames decoded off screen'
    receipt['clock'] = 'movie presentation timestamps'
    receipt['frames'] = [{'frame':p.name,'presentation_seconds':t,'elapsed':t-times[0]} for p,t in zip(images,times)]
    receipt['effective_fps'] = (len(times)-1)/(times[-1]-times[0]) if len(times)>1 and times[-1]>times[0] else 0
    receipt['qualification'] = 'Movie PTS measures recorded presentation; compressed video is unsuitable for exact color sampling or physical scanout claims.'
    destination.write_text(json.dumps(receipt,indent=2))
    print(json.dumps({'directory':str(directory),'decoded_frames':len(times),'effective_fps':receipt['effective_fps']}))


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root',type=Path)
    args=parser.parse_args()
    failed = False
    for movie in args.root.rglob('capture.mov'):
        try:
            decode(movie.parent)
        except Exception as error:
            failed = True
            receipt = {'status':'UNQUALIFIED','reason':str(error)}
            (movie.parent/'decode-failure.json').write_text(json.dumps(receipt,indent=2))
            print(json.dumps({'directory':str(movie.parent),**receipt}),file=sys.stderr)
    sys.exit(1 if failed else 0)
