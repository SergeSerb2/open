#!/usr/bin/env python3
"""Interleave unchanged-main and branch live App switches under quiet + on-screen locks.

Both apps need the identical automation-only `split op=bench` observer. Production
main stays unchanged. The first rAF in EVERY pane and native CA completion determine
readiness. All query-return diagnostics and all samples are retained.
"""
import argparse
import atexit
import importlib.util
import json
import math
import os
from pathlib import Path
import statistics
import signal
import subprocess
import sys
import tempfile


def summary(values):
    return dict(median=statistics.median(values), p95=sorted(values)[math.ceil(len(values)*.95)-1])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--main-root', type=Path, required=True)
    parser.add_argument('--branch-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda *_: sys.exit(143))
    branch = args.branch_root.resolve()
    spec = importlib.util.spec_from_file_location('split_engine_e2e', branch/'tools/e2e/engine_e2e.py')
    h = importlib.util.module_from_spec(spec); sys.modules[spec.name] = h; spec.loader.exec_module(h)
    atexit.register(lambda: [app.quit() for app in h._OWNED_APPS])
    server, origin = h._fixture_server('Split speed')
    receipts = []
    try:
        with tempfile.TemporaryDirectory(prefix='open-sp-', dir='/tmp') as scratch:
            for pair in range(3):
                for label in ('main', 'branch'):
                    root = getattr(args, label+'_root').resolve()
                    h.ROOT = str(root)
                    run = Path(scratch)/('%s-%d' % (label, pair+1)); run.mkdir()
                    app = h.Open('Release', 'chrome', str(run/'data'), ['--use-mock-keychain'], str(run/'app.log'), urls=())
                    saved = {}
                    receipt = dict(revision=label, pair=pair+1, load_before=list(os.getloadavg()),
                                   uptime_before=subprocess.check_output(['uptime'], text=True).strip())
                    try:
                        key = 'open.advanced.showFullURLWithToolbar'
                        saved[key] = app.call('defaults', key=key)
                        app.call('defaults', key=key, value=False)
                        app.call('suggest-remote', enabled=False)
                        app.call('window-frame', frame=[60,60,1360,860])
                        ids = []
                        for name in ('first','second','third'):
                            tid = app.call('open', url=origin+'/'+name)['id']; app.call('wait', tab=tid); ids.append(tid)
                        panes = app.call('split')
                        for i,pane in enumerate(panes):
                            app.call('navigate', tab=pane['id'], url=origin+'/pane-'+str(i)); app.call('wait', tab=pane['id'])
                        tree = app.call('sidebar-tree')
                        split = next(node['id'] for node in tree['today'] if node['kind']=='split')
                        app.call('focus', tab=panes[-1]['id'])
                        tracker = h.FocusTracker(); tracker.apps.append(app); app.focus_tracker = tracker
                        app.begin_timing('paired split selection')
                        measured = app.call('split', op='bench', nodes=[ids[0],ids[1],split])
                        lost = tracker.loss()
                        if lost: raise h.FocusInterruption('foreground lost in paired benchmark', lost)
                        motion = app.call('split', op='bench', nodes=[ids[0],ids[1],split], motionOnly=True)
                        receipt.update(motion=motion, samples=measured, milliseconds={k:summary(v) for k,v in measured.items()},
                                       load_after=list(os.getloadavg()), uptime_after=subprocess.check_output(['uptime'],text=True).strip())
                    finally:
                        h._restore_defaults(app, saved)
                        app.quit(); receipt['cleanup'] = app.quit_report
                        receipts.append(receipt)
                        args.output.parent.mkdir(parents=True, exist_ok=True)
                        args.output.write_text(json.dumps(dict(runs=receipts),indent=2)+'\n')
                    print(label, pair+1, receipt['milliseconds'], receipt['uptime_after'], flush=True)
        totals = {}
        for label in ('main','branch'):
            runs = [r for r in receipts if r['revision']==label]
            totals[label] = {key:summary([v for run in runs for v in run['samples'][key]]) for key in runs[0]['samples']}
        ok = all(totals['branch'][key]['p95'] <= 25 and totals['branch'][key]['p95'] <= totals['main'][key]['p95'] + 1
                 for key in ('single','split')) and all(r['cleanup']['ok'] for r in receipts)
        motion_ok = not any(animation['layer'].endswith('.focusRing') and animation['keyPath'] in ('bounds','position')
                            for run in receipts if run['revision']=='branch' for case in run['motion']['motion']
                            for animation in case['animations'])
        ok = ok and motion_ok
        result = dict(ok=ok, motion_ok=motion_ok, target_ms=16, target_met=all(totals['branch'][key]['p95']<=16 for key in ('single','split')), runs=receipts, milliseconds=totals,
                      gate='branch p95 <= main p95 +1ms and <=25ms, both paths; 16ms remains target; 3 interleaved pairs, 40 samples/path/run, all retained')
        args.output.write_text(json.dumps(result,indent=2)+'\n')
        print('Split App paired gate', 'PASS' if ok else 'FAIL', totals, flush=True)
        return 0 if ok else 1
    finally:
        server.shutdown(); server.server_close()


if __name__ == '__main__':
    raise SystemExit(main())
