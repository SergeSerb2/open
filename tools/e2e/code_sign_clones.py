#!/usr/bin/env python3
"""Real-App regression for the installation-wide code-sign clone cache.

Run under heavy.sh + the on-screen lock with an automation Release bundle.
--baseline records the old leak; --compare checks a matched five-launch set.
Only synthetic hash directories created here are removed by harness cleanup.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
import time
import uuid

import engine_e2e as e

FIXTURE = 'data:text/html,<title>Clone cleanup</title><h1>Clone cleanup launch</h1>'
CACHE = Path.home() / 'Library/Application Support/Open/CodeSignClones'


def key(path):
    return hashlib.sha256(str(path).encode()).hexdigest().upper()


def identity(directory):
    exe = directory / 'Application.bundle/Contents/MacOS/Open'
    st = exe.stat()
    return dict(device=st.st_dev, inode=st.st_ino, size=st.st_size,
                mtime=st.st_mtime_ns, identity=(directory / 'identity').read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--baseline', action='store_true')
    parser.add_argument('--compare', type=Path)
    args = parser.parse_args()
    args.bundle = args.bundle.resolve()
    args.out.mkdir(parents=True, exist_ok=False)
    current = CACHE / key(args.bundle)
    report = dict(baseline=args.baseline, source=subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], text=True).strip(), checks={}, launches=[], cleanup=[])
    created = []
    apps = []
    held = None
    root = Path(tempfile.mkdtemp(prefix='open-clones-e2e-'))

    def save():
        (args.out / 'report.json').write_text(json.dumps(report, indent=2))

    def check(name, condition, **detail):
        report['checks'][name] = dict(ok=bool(condition), **detail)
        print(name, 'PASS' if condition else 'FAIL', flush=True)
        save()
        if not condition:
            raise AssertionError(name)

    def launch(label, blank=False):
        app = e.Open('Release', 'chrome', str(root / label), ['--use-mock-keychain'],
                     str(args.out / (label + '.log')), urls=('about:blank' if blank else FIXTURE,),
                     extra_env={'OPEN_E2E_APP_BUNDLE': str(args.bundle)})
        apps.append(app)
        if not blank:
            tab = app.call('tabs')[0]['id']
            app.call('wait', tab=tab)
            assert e.wait_until(lambda: app.call('timing').get('firstContentfulPaint'), timeout=15, step=.05)
        return app

    def stop(app):
        app.quit()
        report['cleanup'].append(app.quit_report)
        save()
        assert app.quit_report['ok'], app.quit_report

    def seed(label, full=True):
        directory = CACHE / key(root / label)
        assert not directory.exists()
        if full:
            subprocess.run(['cp', '-cR', str(current), str(directory)], check=True)
        else:
            directory.mkdir(mode=0o700)
        created.append(directory)
        return directory

    try:
        # Exclude first-after-install from timing; wait for the engine's real clone.
        app = launch('prime')
        assert e.wait_until(lambda: (current / 'identity').exists(), timeout=20)
        check('current_key_matches_engine', (current / 'Application.bundle/Contents/MacOS/Open').exists())
        before = identity(current)
        stop(app)
        stale = [seed('stale-%d' % i) for i in range(3)]
        live = seed('live')
        held = open(live / 'lease', 'r+b')
        fcntl.flock(held, fcntl.LOCK_SH | fcntl.LOCK_NB)
        interrupted = CACHE / ('.prune-' + key(root / 'interrupted') + '-' + str(uuid.uuid4()).upper())
        subprocess.run(['cp', '-cR', str(current), str(interrupted)], check=True)
        created.append(interrupted)
        incomplete = seed('incomplete', full=False)
        outside = root / 'outside'
        outside.mkdir()
        sentinel = outside / 'sentinel'
        sentinel.write_text('outside cache: keep')
        link = CACHE / key(root / 'symlink')
        link.symlink_to(outside, target_is_directory=True)
        created.append(link)
        # A symlink inside a valid retired clone must be unlinked, not traversed.
        (stale[0] / 'outside-link').symlink_to(outside, target_is_directory=True)
        for index in range(5):
            load = list(os.getloadavg())
            app = launch('sample-%d' % index)
            try:
                if index == 0:
                    if args.baseline:
                        time.sleep(3)
                        # The regression assertion is intentionally false on main.
                        observed = all(not directory.exists() for directory in stale)
                        report['old_code_regression'] = dict(ok=observed, remaining=sum(d.exists() for d in stale))
                        check('baseline_reproduces_three_stale_clones', not observed and all(d.exists() for d in stale))
                    else:
                        completed = e.wait_until(lambda: app.call('timing').get('cloneCleanup'), timeout=60, step=.1)
                        check('background_cleanup_finished', completed is not None, counts=completed)
                        check('three_stale_clones_removed', all(not d.exists() for d in stale))
                        check('interrupted_and_incomplete_removed', not interrupted.exists() and not incomplete.exists())
                        check('current_clone_unchanged', identity(current) == before)
                        check('live_shared_lease_preserved', live.exists())
                        check('symlinks_do_not_escape_cache', sentinel.read_text() == 'outside cache: keep' and link.is_symlink())
                timing = app.call('timing')
                if not args.baseline:
                    assert e.wait_until(lambda: app.call('timing').get('cloneCleanupFinished'), timeout=60)
                    timing = app.call('timing')
                report['launches'].append(dict(timing=timing, loadBefore=load, loadAfter=list(os.getloadavg())))
                if not args.baseline:
                    check('after_first_paint_%d' % index,
                          timing.get('cloneCleanupScheduled', -1) >= timing['firstContentfulPaint'] - timing['firstPaintClockUncertaintyMs'])
                save()
            finally:
                stop(app)
        report['medianPaintMs'] = statistics.median(r['timing']['firstContentfulPaint'] for r in report['launches'])
        report['medianSidebarMs'] = statistics.median(r['timing']['sidebarDrawn'] for r in report['launches'])
        if not args.baseline:
            held.close()
            held = None
            app = launch('released-lease')
            try:
                check('released_lease_removed_next_launch', e.wait_until(lambda: not live.exists(), timeout=30) is not None)
                check('current_reused_after_relaunch', identity(current) == before)
            finally:
                stop(app)
            # No web FCP: the native first frame must still start maintenance.
            blank_stale = seed('blank-stale')
            app = launch('blank', blank=True)
            try:
                check('blank_launch_cleanup', e.wait_until(lambda: not blank_stale.exists(), timeout=30) is not None)
                check('blank_keeps_current', identity(current) == before)
            finally:
                stop(app)
        if args.compare:
            baseline = json.loads(args.compare.read_text())
            check('matched_launch_paint', report['medianPaintMs'] <= baseline['medianPaintMs'] * 1.10,
                  beforeMs=baseline['medianPaintMs'], afterMs=report['medianPaintMs'], maximumFactor=1.10,
                  qualification='rental Release, matched bundle path/fixture, five launches per side')
        check('all_owned_processes_and_windows_closed', all(r['ok'] for r in report['cleanup']))
        save()
        print(json.dumps({k: report[k] for k in ('medianPaintMs', 'medianSidebarMs')}), flush=True)
    finally:
        if held:
            held.close()
        for app in apps:
            if not app.closed:
                app.quit()
        # These synthetic entries alone are ours; all other cache deletion is
        # performed by the launched App's production maintenance path.
        for directory in created:
            if directory.is_symlink():
                directory.unlink()
            elif directory.exists():
                shutil.rmtree(directory)
        shutil.rmtree(root)
        save()


if __name__ == '__main__':
    main()
