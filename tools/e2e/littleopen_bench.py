#!/usr/bin/env python3
"""Paired real-app Little Open receipts; run under quiet then on-screen lock.

Example: littleopen_bench.py --main-bundle /path/to/main/Open.app --output /tmp/receipt.json
Both apps must use the same configuration, engine and display. No desktop input.
"""
import argparse
import json
import math
import os
from pathlib import Path
import plistlib
import shutil
import socket
import statistics
import subprocess
import tempfile
import time
import engine_e2e as e


def raw_call(app, cmd, **args):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(30)
        sock.connect(app.sock)
        sock.sendall((json.dumps({'id': 1, 'cmd': cmd, 'args': args}) + '\n').encode())
        data = b''
        while not data.endswith(b'\n'):
            chunk = sock.recv(1 << 20)
            if not chunk:
                raise RuntimeError('automation socket closed before response')
            data += chunk
            if len(data) > 8 * 1024 * 1024:
                raise RuntimeError('automation response exceeds 8 MiB')
    response = json.loads(data)
    if not response['ok']:
        raise RuntimeError(response)
    return response


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--main-bundle', required=True)
    parser.add_argument('--branch-bundle', default=str(Path(e.ROOT) / 'build/Debug/Open.app'))
    parser.add_argument('--config', default='Debug')
    parser.add_argument('--samples', type=int, default=10)
    parser.add_argument('--output', required=True)
    parser.add_argument('--scenario', choices=('immediate', 'typed', 'external'), default='immediate')
    parser.add_argument('--report-only', action='store_true', help='record measurements without a performance verdict')
    parser.add_argument('--pair-index', type=int, help='emit one partial pair for the lock-releasing series runner; not an acceptance receipt')
    args = parser.parse_args()
    # New user-realistic paths are measurements for the lead, never new gates.
    args.report_only = args.report_only or args.scenario != 'immediate'
    if not 10 <= args.samples <= 100:
        parser.error('10 to 100 samples per build are required')
    if args.pair_index is not None and not 0 <= args.pair_index < 100:
        parser.error('pair index must be 0 to 99')
    scratch = Path(tempfile.mkdtemp(prefix='open-lo-bench-'))
    probe = scratch / 'frame.dylib'
    subprocess.run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-Wno-deprecated-declarations',
                    str(Path(e.ROOT) / 'tools/verification/littleopen-frame-probe.m'),
                    '-framework', 'AppKit', '-framework', 'QuartzCore', '-o', str(probe)], check=True)
    domain = 'io.github.sergeserb2.open'
    keys = ('open.links.littleOpenNUXSeen', 'open.links.externalInLittleOpen')
    exported = subprocess.run(['defaults', 'export', domain, '-'], capture_output=True)
    saved = plistlib.loads(exported.stdout) if exported.returncode == 0 else {}
    server, port = e._sleep_server()
    rows = []
    receipt = {'configuration': args.config, 'scenario': args.scenario, 'reportOnly': args.report_only, 'samples': rows,
               'method': 'automation request start to first native display-link tick; page submit to loading=false plus document complete and first contentful paint',
               'externalMethod': 'time before LaunchServices open(1) delivery to performance.timeOrigin + FCP; wall/monotonic clock stability checked',
               'typedDelayMs': 400 if args.scenario == 'typed' else 0,
               'memory': 'App metrics totalRSS: App and owned helpers; one loaded window minus baseline',
               'partialPair': args.pair_index,
               'mainBundle': str(Path(args.main_bundle).resolve()), 'branchBundle': str(Path(args.branch_bundle).resolve())}
    try:
        for key in keys:
            subprocess.run(['defaults', 'write', domain, key, '-bool', 'true'], check=True)
        for index in (range(args.samples) if args.pair_index is None else (args.pair_index,)):
            # Alternate the first build of each pair to bound order/cache bias.
            for label in (('main', 'branch') if index % 2 == 0 else ('branch', 'main')):
                if os.getloadavg()[0] > 12:
                    raise RuntimeError('load1 exceeded 12; release screen lock and retry the receipt')
                root = Path.home() / 'Library/Application Support' / ('Open-LOBench-%d-%d-%s' % (os.getpid(), index, label))
                frame_log = scratch / ('frames-%d-%s.jsonl' % (index, label))
                frame_log.touch()
                bundle = args.main_bundle if label == 'main' else args.branch_bundle
                app = None
                try:
                    app = e.Open(args.config, 'chrome', str(root), ['--use-mock-keychain'], str(scratch / (label + '.log')),
                                 urls=(), extra_env={'OPEN_E2E_APP_BUNDLE': str(Path(bundle).resolve()),
                                                    'DYLD_INSERT_LIBRARIES': str(probe), 'OPEN_LITTLEOPEN_FRAME_LOG': str(frame_log)})
                    tracker = e.FocusTracker(); tracker.apps.append(app); app.focus_tracker = tracker
                    window = app.call('shell-windows')[0]
                    app.call('window-focus', id=window['id'], activate=True)
                    tracker.checkpoint()
                    before = app.call('metrics', interval=0.1)
                    load = os.getloadavg()
                    target = 'http://127.0.0.1:%d/plain.html?sample=%d' % (port, index)
                    app.begin_timing('Little Open first frame')
                    if args.scenario == 'external':
                        # Same LaunchServices delivery as littleopen_checks.deliver.
                        # FCP uses the page's epoch timestamp, so this start includes
                        # open(1), routing intake, window, Browser and navigation.
                        request_wall_ms = time.time_ns() / 1e6
                        request_mono = time.monotonic()
                        subprocess.run(['/usr/bin/open', '-a', app.bundle, target],
                                       capture_output=True, timeout=15, check=True)
                        session = e.wait_until(lambda: next((s for s in app.call('little-open-state')['sessions']
                                                            if s['url'] == target), None), timeout=10, step=.002)
                        if not session:
                            raise RuntimeError('external delivery did not open Little Open')
                        opened = None
                    else:
                        opened = raw_call(app, 'little-open-action', action='blank')
                        opened_response_at = time.monotonic()
                        session = opened['result']['sessions'][0]
                    frame = e.wait_until(lambda: next((row for row in [json.loads(line) for line in frame_log.read_text().splitlines()]
                                                     if row['window'] == session['window']), None), timeout=5, step=.002)
                    if not frame:
                        raise RuntimeError('no first-display-link receipt')
                    if opened:
                        first_ms = (frame['uptime'] - opened['observationStart']) * 1000
                        if args.scenario == 'typed':
                            # Count the 400 ms from the blank-open response. Frame
                            # observation time is inside this delay, not added to it.
                            time.sleep(max(0, opened_response_at + .4 - time.monotonic()))
                        app.begin_timing('Little Open page load')
                        submit_request_at = time.monotonic()
                        submitted = raw_call(app, 'key', window=session['window'], text=target + '\r')
                    def page_loaded():
                        current = app.call('little-open-state')['sessions'][0]
                        if current['state'] != 'page' or current['loading']:
                            return None
                        ready = raw_call(app, 'little-open-eval', id=session['id'], js='({ready:document.readyState,url:location.href,fcp:performance.getEntriesByName("first-contentful-paint")[0]?.startTime ?? null,timeOrigin:performance.timeOrigin})')
                        result = ready['result']
                        ready['browserCreationStartedAt'] = current.get('browserCreationStartedAt')
                        return ready if result['ready'] == 'complete' and result['url'] == target and result['fcp'] is not None else None
                    completed = e.wait_until(page_loaded, timeout=15, step=.002)
                    if not completed:
                        raise RuntimeError('page did not finish loading')
                    if opened:
                        page_ms = (completed['observationStart'] - submitted['observationStart']) * 1000
                    else:
                        # Check clock stability; never substitute the later ready
                        # observation for the requested external FCP endpoint.
                        clock_drift_ms = (time.time_ns() / 1e6 - request_wall_ms) - (time.monotonic() - request_mono) * 1000
                        if abs(clock_drift_ms) > 5:
                            raise RuntimeError('wall/monotonic clocks changed during external sample')
                        open_fcp_ms = completed['result']['timeOrigin'] + completed['result']['fcp'] - request_wall_ms
                        if open_fcp_ms <= 0:
                            raise RuntimeError('external FCP predates open request')
                    ready_observed_at = time.monotonic()
                    time.sleep(.5)
                    after = app.call('metrics', interval=0.1)
                    end_load = os.getloadavg()
                    if end_load[0] > 12:
                        raise RuntimeError('load1 exceeded 12 during sample')
                    focus_loss = tracker.loss()
                    if focus_loss:
                        raise RuntimeError('foreground interrupted: ' + json.dumps(focus_loss))
                    row = {'build': label, 'pair': index, 'scenario': args.scenario, 'load': load, 'endLoad': end_load,
                           'uptime': subprocess.check_output(['uptime'], text=True).strip(),
                           'firstContentfulPaintMs': completed['result']['fcp'], 'baselineRSS': before['totalRSS'], 'loadedRSS': after['totalRSS'],
                           'windowRSS': after['totalRSS'] - before['totalRSS'],
                           'processCount': len(after['processes']), 'foregroundInterruptions': focus_loss}
                    if opened:
                        row.update(firstFrameMs=first_ms, pageLoadMs=page_ms,
                                   openResponseToSubmitMs=(submit_request_at - opened_response_at) * 1000,
                                   openRequestToSubmitMs=(submitted['observationStart'] - opened['observationStart']) * 1000)
                    else:
                        row.update(openToFCPMs=open_fcp_ms, clockDriftMs=clock_drift_ms,
                                   openToReadyMs=(ready_observed_at - request_mono) * 1000,
                                   requestWallMs=request_wall_ms,
                                   fcpWallMs=completed['result']['timeOrigin'] + completed['result']['fcp'],
                                   routing=app.call('routing-log')['lastLittleOpenRequest'])
                    if completed.get('browserCreationStartedAt') is not None:
                        row['browserCreationToReadyMs'] = (completed['observationStart'] - completed['browserCreationStartedAt']) * 1000
                        row['firstFrameToBrowserCreationMs'] = (completed['browserCreationStartedAt'] - frame['uptime']) * 1000
                    rows.append(row)
                    print(json.dumps(row), flush=True)
                finally:
                    if app:
                        app.quit()
                        if rows and rows[-1]['pair'] == index and rows[-1]['build'] == label:
                            rows[-1]['cleanupOK'] = app.quit_report.get('ok', False)
                        if not app.quit_report.get('ok'):
                            raise RuntimeError('owned process cleanup failed')
                    shutil.rmtree(root, ignore_errors=True)
                    shutil.rmtree(Path.home() / 'Library/Caches' / root.name, ignore_errors=True)
        def summary(label):
            selected = [r for r in rows if r['build'] == label]
            result = {}
            for metric in ('firstFrameMs', 'pageLoadMs', 'openToFCPMs', 'windowRSS', 'loadedRSS'):
                values = sorted(r[metric] for r in selected if metric in r)
                if not values:
                    continue
                result[metric] = {'median': statistics.median(values), 'p95': values[math.ceil(len(values) * .95)-1]}
            creation = [r['browserCreationToReadyMs'] for r in selected if 'browserCreationToReadyMs' in r]
            if creation:
                values = sorted(creation)
                result['browserCreationToReadyMs'] = {'median': statistics.median(values), 'p95': values[math.ceil(len(values) * .95)-1]}
            return result
        receipt['summary'] = {label: summary(label) for label in ('main', 'branch')}
        if not args.report_only:
            receipt['noSlower'] = all(receipt['summary']['branch'][metric][pct] <= receipt['summary']['main'][metric][pct]
                                 for metric in ('firstFrameMs', 'pageLoadMs') for pct in ('median', 'p95'))
        receipt['extraHiddenBrowserRSS'] = receipt['summary']['branch']['windowRSS']['median'] - receipt['summary']['main']['windowRSS']['median']
        print(json.dumps({k: v for k, v in receipt.items() if k not in ('samples', 'mainBundle', 'branchBundle')}, indent=2))
    finally:
        Path(args.output).write_text(json.dumps(receipt, indent=2) + '\n')
        server.shutdown()
        server.server_close()
        for key in keys:
            if key in saved:
                subprocess.run(['defaults', 'write', domain, key, '-bool', str(saved[key]).lower()], check=True)
            else:
                subprocess.run(['defaults', 'delete', domain, key], capture_output=True)
        shutil.rmtree(scratch, ignore_errors=True)
    if not args.report_only and args.pair_index is None and not receipt.get('noSlower', False):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
