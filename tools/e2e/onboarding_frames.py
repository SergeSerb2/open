#!/usr/bin/env python3
"""Interleave actual intro frame measurements, screen/normal blend, three each.

Run under quiet + on-screen locks, using an already-built automation App.
Every launch uses a disposable root, synthetic import source and sound off.
"""
import argparse
import json
import os
from pathlib import Path
import runpy
import statistics
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    h = runpy.run_path(str(root/'tools/e2e/engine_e2e.py'))
    rows = []
    try:
        with tempfile.TemporaryDirectory(prefix='open-intro-blend-', dir='/tmp') as scratch:
            source = Path(scratch)/'arc-synthetic'
            runpy.run_path(str(root/'tools/e2e/firstrun.py'))['fixture'](source)
            for pair in range(3):
                for mode in ('screen', 'normal'):
                    load = os.getloadavg()
                    if load[0] > 12:
                        raise RuntimeError('blend comparison requires load1 <= 12')
                    data = str(Path(scratch)/f'root-{pair}-{mode}')
                    app = h['Open']('Debug', 'chrome', data,
                        ['--use-mock-keychain', '--arc-dir='+str(source), '--intro-sound=off', '--measure-intro-frames'],
                        str(Path(scratch)/'app.log'), urls=(), first_run=True,
                        extra_env={'OPEN_INTRO_NORMAL_BLEND': '1' if mode=='normal' else '0'})
                    tracker = h['FocusTracker'](); tracker.apps.append(app); app.focus_tracker = tracker
                    try:
                        app.begin_timing('intro blend frame measurement')
                        assert h['wait_until'](lambda: app.call('onboarding').get('elapsed', 0) >= 8.2, timeout=15, step=.05)
                        state = app.call('onboarding')
                        assert not tracker.loss(), 'foreground interrupted'
                        expected = ['screenBlendMode', 'screenBlendMode'] if mode=='screen' else []
                        assert state['blendFilters'] == expected, state['blendFilters']
                        stats = state['frameStats']
                        assert stats['count'] >= 30 and not stats['running']
                        assert state['sound']['decision']=='muted' and not state['sound']['playerWasCreated']
                        row = dict(pair=pair+1, mode=mode, loadStart=load, loadEnd=os.getloadavg(), stats=stats)
                        rows.append(row); print(json.dumps(row), flush=True)
                    finally:
                        app.quit()
                        assert app.quit_report['ok'], app.quit_report
        keys = ('p50MS', 'p95MS', 'maxMS', 'drops')
        medians = {mode: {key: statistics.median(row['stats'][key] for row in rows if row['mode']==mode)
                          for key in keys} for mode in ('screen', 'normal')}
        delta = medians['screen']['p95MS']-medians['normal']['p95MS']
        drops = {mode: sum(row['stats']['drops'] for row in rows if row['mode']==mode) for mode in ('screen', 'normal')}
        report = dict(ok=abs(delta)<.5 and drops['screen']<=drops['normal'], rows=rows,
                      medians=medians, p95DeltaMS=delta, totalDrops=drops,
                      source=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip())
        Path(options.out).write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report, indent=2))
        if not report['ok']: raise SystemExit(1)
    except BaseException:
        if len(rows)<6: Path(options.out).write_text(json.dumps(dict(ok=False, incomplete=True, rows=rows), indent=2)+'\n')
        raise


if __name__ == '__main__': main()
