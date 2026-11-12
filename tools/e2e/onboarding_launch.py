#!/usr/bin/env python3
"""Interleaved real-returning launch comparison, main/branch, never audible.

Run only under quiet + on-screen locks, after both Debug apps are built.
Every measured launch has browser.json and omits --skip-first-run.
"""
import argparse
import json
import os
import plistlib
import subprocess
from pathlib import Path
import runpy
import shutil
import statistics
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--main-app', required=True)
    parser.add_argument('--out', required=True)
    options = parser.parse_args()
    os.environ.pop('OPEN_SKIP_FIRST_RUN', None)
    root = Path(__file__).resolve().parents[2]
    h = runpy.run_path(str(root/'tools/e2e/engine_e2e.py'))
    Open, wait = h['Open'], h['wait_until']
    samples = []
    exported = subprocess.run(['defaults', 'export', __import__('prefs_domain').domain(), '-'], capture_output=True)
    domain = plistlib.loads(exported.stdout) if exported.returncode==0 else {}
    keys = ('open.firstRun.completed', 'open.links.openPeekShiftClick', 'open.links.openPeekOtherSites')
    saved = {key: domain.get(key) for key in keys}
    h['_restore_defaults'](None, {key: None for key in keys})
    try:
        with tempfile.TemporaryDirectory(prefix='open-intro-launch-', dir='/tmp') as scratch:
            source = Path(scratch)/'arc-synthetic'
            runpy.run_path(str(root/'tools/e2e/firstrun.py'))['fixture'](source)
            data = str(Path(scratch)/'root')
            log = str(Path(scratch)/'app.log')
            app = Open('Debug', 'chrome', data, ['--use-mock-keychain', '--arc-dir='+str(source), '--intro-sound=off'], log, urls=(),
                       extra_env={'OPEN_E2E_APP_BUNDLE': options.main_app}, first_run=True)
            try:
                assert app.call('first-run')['active']
                app.call('first-run', action='fresh')
                assert wait(lambda: not app.call('first-run')['active'], timeout=10, step=.05)
                app.call('save')
            finally: app.quit()
            assert Path(data, 'State/browser.json').is_file()
            for attempt in range(5):
                for kind in ('main', 'branch'):
                    env = {'OPEN_E2E_APP_BUNDLE': options.main_app} if kind=='main' else {}
                    load = os.getloadavg()
                    if load[0] > 12:
                        raise RuntimeError('returning launches require load1 <= 12')
                    app = Open('Debug', 'chrome', data, ['--use-mock-keychain', '--arc-dir='+str(source), '--intro-sound=off'], log,
                               urls=(), extra_env=env, first_run=True)
                    tracker = h['FocusTracker'](); tracker.apps.append(app); app.focus_tracker = tracker
                    try:
                        native = app.call('native-focus-state')
                        assert native['active'] and native['frontmostPID']==app.pid, 'foreground interrupted'
                        assert not app.call('first-run')['active']
                        if kind=='branch': assert not app.call('onboarding')['moduleActive']
                        marks = app.call('timing')
                        assert marks.get('firstFrameConfirmed') is True, 'launch first frame unconfirmed'
                        assert not tracker.loss(), 'foreground interrupted'
                        samples.append(dict(kind=kind, attempt=attempt+1, load=load, marks=marks))
                        print(json.dumps(samples[-1]), flush=True)
                    finally: app.quit()
            names = set.intersection(*(set(row['marks']) for row in samples))
            medians = {kind: {key: statistics.median(row['marks'][key] for row in samples if row['kind']==kind)
                              for key in sorted(names) if all(type(row['marks'][key]) in (int,float) for row in samples)}
                       for kind in ('main', 'branch')}
            # Keep every numeric launch mark shared by both Apps; do not hide
            # a slower stage by selecting only the earliest shell marks.
            comparison = {key: medians['branch'][key]-medians['main'][key]
                          for key in medians['main']}
            report = dict(samples=samples, medians=medians, deltaMS=comparison,
                          ok=bool(comparison) and all(delta <= 5 for delta in comparison.values()))
            Path(options.out).write_text(json.dumps(report, indent=2)+'\n')
            print(json.dumps(report, indent=2))
            if not report['ok']: raise SystemExit(1)
    finally:
        h['_restore_defaults'](None, saved)


if __name__ == '__main__': main()
