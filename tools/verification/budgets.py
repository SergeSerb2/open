#!/usr/bin/env python3
"""One pass over existing Release performance harnesses; Python stdlib only."""
import argparse
import contextlib
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / 'Packages/OpenKit/.build/release'
HELPERS = ROOT / '.re/e2e-tools'
DOMAIN = 'io.github.sergeserb2.open'
LIMIT = 16 * 1024 * 1024  # Bounded real-harness output; no page bodies in receipts.
GROUPS = ('launch', 'first-run', 'idle-animated', 'idle-static', 'sitecontrol', 'sidebar',
          'commandbar', 'tab-switch', 'sidebar-bench', 'sidebar-selection',
          'sidebar-bulk', 'sidebar-expand', 'folder-peek', 'suggest', 'adblock',
          'command-open', 'find', 'theme', 'features', 'favicons', 'feature-idle')
SCREEN = {'launch', 'first-run', 'idle-animated', 'idle-static', 'sitecontrol', 'sidebar', 'tab-switch',
          'command-open', 'find', 'theme'}
APP = {'launch', 'first-run', 'idle-animated', 'idle-static', 'tab-switch', 'command-open', 'find'}
KEYS = ('open.advanced.showFullURLWithToolbar', 'open.advanced.tabSleepMode',
        'open.advanced.enablePictureInPictureOnLeave', 'open.pip.autoDisabledHosts',
        'open.pip.keepOnTop', 'open.settings.lastPane', 'open.links.littleOpenHotkeyEnabled',
        'open.links.externalInLittleOpen', 'open.general.searchSuggestNoticeDismissed',
        'open.firstRun.completed', 'open.import.lastArcDir')


def atomic_json(path, value):
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')
    temporary.replace(path)


def stop(job):
    if job.poll() is None:
        job.terminate()
        try:
            job.wait(timeout=10)
        except subprocess.TimeoutExpired:
            job.kill()
            job.wait(timeout=10)
    else:
        job.wait()


def interrupt(number, _frame):
    raise InterruptedError('interrupted by signal ' + str(number))


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def command(group, scratch):
    commands = {
        'sitecontrol': ['sitecontrol-render', 'check'],
        'sidebar': ['sidebar-render', 'check'],
        'commandbar': ['commandbar-render', 'check'],
        'sidebar-bench': ['sidebar-render', 'bench', '--rows', '1000'],
        'sidebar-selection': ['sidebar-render', 'bench', '--rows', '1000', '--selection'],
        'sidebar-bulk': ['sidebar-render', 'bench', '--rows', '1000', '--bulk', '50'],
        'sidebar-expand': ['sidebar-render', 'bench', '--expand-all', '50'],
        'folder-peek': ['sidebar-render', 'bench', '--rows', '1000', '--scale', '2', '--folder-peek', '50'],
        'suggest': ['openkit', 'suggest-check'],
        'adblock': ['openkit', 'adblock', 'perf', '--dir', str(scratch / 'data')],
        'theme': ['space-editor-render', 'check'],
        'features': ['features-render', 'check'],
        'favicons': ['features-render', 'favicon-check'],
        'feature-idle': ['features-render', 'check', '--only', 'idle'],
    }
    args = commands[group]
    return [str(BIN / args[0]), *args[1:]]


def needed_products(groups):
    return sorted({Path(command(group, Path('.'))[0]).name for group in groups if group not in APP})


def run_cli(group, scratch, data_root, receipt):
    (data_root / 'tmp').mkdir()
    (data_root / 'home').mkdir()
    env = dict(os.environ, TMPDIR=str(data_root / 'tmp') + '/',
               CFFIXED_USER_HOME=str(data_root / 'home'), OPEN_VERIFY_SUITE_ROOT=str(scratch))
    # Caller-supplied benchmark overrides would change the existing workload.
    for key in ('BENCH_SCROLL_LOOPS', 'BENCH_MOVES', 'OPEN_VERIFY_BREAK',
                'DYLD_INSERT_LIBRARIES', 'SIDEBAR_FOLDER_PEEK_PERF'):
        env.pop(key, None)
    if group == 'feature-idle':
        env['DYLD_INSERT_LIBRARIES'] = str(HELPERS / 'budgets-idle-probe.dylib')
    argv = command(group, data_root)
    receipt['command'] = argv
    logfile = scratch / 'command.log'
    with logfile.open('w') as log:
        mask = signal.pthread_sigmask(signal.SIG_BLOCK, (signal.SIGTERM, signal.SIGINT, signal.SIGHUP))
        job = None
        try:
            job = subprocess.Popen(argv, cwd=data_root, env=env, stdin=subprocess.DEVNULL,
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
                                   preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, mask))
            receipt['pid'] = job.pid
            signal.pthread_sigmask(signal.SIG_SETMASK, mask)
            deadline = time.monotonic() + 900
            while job.poll() is None:
                if time.monotonic() >= deadline:
                    raise RuntimeError('existing harness exceeded 900 s')
                if logfile.stat().st_size > LIMIT:
                    raise RuntimeError('existing harness output exceeds 16 MiB')
                time.sleep(.2)
        finally:
            # Give the real harness its normal cleanup path before killing its
            # owned process group. Never kill by executable name or bundle ID.
            signal.pthread_sigmask(signal.SIG_BLOCK, (signal.SIGTERM, signal.SIGINT, signal.SIGHUP))
            try:
                if job is not None and job.poll() is None:
                    # Keep the process group leader unreaped through TERM/KILL.
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(job.pid, signal.SIGTERM)
                    time.sleep(2)
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(job.pid, signal.SIGKILL)
                if job is not None:
                    job.wait(timeout=10)
                cleanup = load_module('budgets_check_cleanup', ROOT / 'tools/verification/check.py')
                receipt['native_apps_stopped'] = cleanup.stop_native_suite_apps(scratch)
                receipt['cli_cleanup'] = True
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, mask)
    receipt['returncode'] = job.returncode
    receipt['crashed'] = job.returncode < 0
    if logfile.stat().st_size > LIMIT:
        raise RuntimeError('existing harness output exceeds 16 MiB')
    return logfile.read_text(errors='replace')


def worker(group, app, output, data_root):
    """Runs inside the row's screen lock, when required. No builds or load wait."""
    scratch = output.parent
    (scratch / 'worker.pid').write_text(str(os.getpid()))
    receipt = dict(group=group, load_start=list(os.getloadavg()), cleanup=False, data_root=str(data_root))
    harness = None
    saved = {}
    try:
        if group in APP:
            # Keep diagnostic injection and negative controls out of the
            # primary measurements. This changes only the disposable worker.
            for key in ('OPEN_SPEED_TRACE', 'OPEN_FIND_DISABLE_PREWARM', 'OPEN_VERIFY_BREAK',
                        'OPEN_E2E_NO_LAUNCH_WAIT', 'DYLD_INSERT_LIBRARIES',
                        'DYLD_PRINT_LIBRARIES', 'DYLD_PRINT_INITIALIZERS',
                        'DYLD_PRINT_STATISTICS', 'DYLD_PRINT_STATISTICS_DETAILS'):
                os.environ.pop(key, None)
            # Import before resetting defaults so every reset has a restore path.
            sys.path.insert(0, str(ROOT / 'tools/e2e'))
            harness = load_module('budgets_engine_e2e', ROOT / 'tools/e2e/engine_e2e.py')
            exported = subprocess.run(['defaults', 'export', DOMAIN, '-'], capture_output=True, timeout=10)
            if len(exported.stdout) > LIMIT:
                raise RuntimeError('shared defaults export exceeds 16 MiB')
            persistent = plistlib.loads(exported.stdout) if exported.returncode == 0 else {}
            if exported.returncode and b'does not exist' not in exported.stdout + exported.stderr:
                raise RuntimeError('could not snapshot shared defaults')
            saved = {key: persistent.get(key) for key in KEYS}
            for key in KEYS:
                subprocess.run(['defaults', 'delete', DOMAIN, key], capture_output=True, timeout=10)
            # Match split-app-speed's toolbar setting. Other rows use defaults.
            if group == 'tab-switch':
                subprocess.run(['defaults', 'write', DOMAIN, KEYS[0], '-bool', 'false'], check=True, capture_output=True, timeout=10)
            extracted = load_module('budgets_app', ROOT / 'tools/verification/budgets_app.py')
            tracker = harness.FocusTracker()
            harness._ACTIVE_FOCUS_TRACKER = tracker
            receipt['data'] = extracted.run(group, harness, app, scratch, data_root)
            tracker.apps = harness._OWNED_APPS
            lost = tracker.loss()
            if lost:
                raise RuntimeError('foreground interrupted during timed App workload')
        else:
            receipt['text'] = run_cli(group, scratch, data_root, receipt)
    except BaseException as error:
        receipt['error'] = str(error)
        receipt['interrupted'] = isinstance(error, InterruptedError)
        # Ordinary page/metric failures stay as FAIL and do not skip later rows.
        # A failure to load/respond may be a loader crash: do not relaunch it.
        receipt['stop_onscreen'] = 'automation was not ready' in str(error)
    finally:
        for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(number, signal.SIG_IGN)
        try:
            if harness:
                cleanup_errors = []
                for instance in harness._OWNED_APPS:
                    try:
                        instance.quit()
                    except BaseException as error:
                        cleanup_errors.append('owned App cleanup: ' + str(error))
                restore = load_module('budgets_restore_defaults', ROOT / 'tools/e2e/restore_defaults.py')
                for key, value in saved.items():
                    try:
                        if value is None:
                            subprocess.run(['defaults', 'delete', DOMAIN, key], capture_output=True, timeout=10)
                        else:
                            # The existing null-checked CF writer preserves every
                            # plist type, including integers, rather than stringifying.
                            restore.write_collection(key, value)
                    except BaseException as error:
                        cleanup_errors.append('defaults restore: ' + str(error))
                checked = subprocess.run(['defaults', 'export', DOMAIN, '-'], capture_output=True, timeout=10)
                restored = plistlib.loads(checked.stdout) if checked.returncode == 0 else {}
                receipt['defaults_restored'] = all(
                    (key not in restored if value is None else key in restored and
                     plistlib.dumps(restored[key], fmt=plistlib.FMT_BINARY) == plistlib.dumps(value, fmt=plistlib.FMT_BINARY))
                    for key, value in saved.items())
                if not receipt['defaults_restored']:
                    raise RuntimeError('shared defaults did not restore with original values/types')
                receipt['app_cleanup'] = [a.quit_report for a in harness._OWNED_APPS]
                if any('reply' not in a.quit_report for a in harness._OWNED_APPS):
                    receipt['stop_onscreen'] = True
                if not all(a.quit_report.get('ok') for a in harness._OWNED_APPS):
                    raise RuntimeError('owned process/window cleanup failed')
                if cleanup_errors:
                    raise RuntimeError('; '.join(cleanup_errors))
            elif receipt.get('pid') and not receipt.get('cli_cleanup'):
                raise RuntimeError('CLI/native child cleanup did not complete')
            shutil.rmtree(data_root)
            receipt['data_root_removed'] = not data_root.exists()
            receipt['cleanup'] = True
        except BaseException as error:
            receipt['cleanup_error'] = str(error)
        receipt['load_end'] = list(os.getloadavg())
        atomic_json(output, receipt)


def rows_from(receipt, fail_demo=False):
    """Parse the existing reported metrics; do not replace measurement methods.

    Every numeric budget below cites its defining doc or harness source. Raw
    harness verdicts also remain in the JSON, including unrelated flow failures.
    """
    rows = []
    group = receipt['group']
    text = receipt.get('text', '')
    data = receipt.get('data', {})
    valid = receipt.get('cleanup') and not receipt.get('error') and not receipt.get('crashed')

    def add(name, limit, value=None, *, unit='ms', metric='p95', median=None,
            samples=None, strict=False, source='', evidence=None, ok=True):
        passed = bool(valid and ok and value is not None and math.isfinite(value))
        if passed and limit is not None:
            passed = value < limit if strict else value <= limit
        row = dict(row=name, budget=limit, operator='<' if strict else '<=', unit=unit,
                   measured={metric: value}, samples=samples, status='PASS' if passed else 'FAIL',
                   load1_start=receipt['load_start'][0], load1_end=receipt['load_end'][0],
                   source=source, harness=group)
        if median is not None:
            row['measured']['median'] = median
        if evidence is not None:
            row['evidence'] = evidence
        if receipt.get('error'):
            row['error'] = receipt['error']
        rows.append(row)

    def match(pattern):
        return re.search(pattern, text, re.MULTILINE)

    def native_ok(pattern):
        m = match(r'^\s*(PASS|FAIL)\s+.*?' + pattern)
        return bool(m and m[1] == 'PASS')

    def numeric(name, limit, pattern, *, index=1, **kw):
        m = match(pattern)
        add(name, limit, float(m[index]) if m else None, evidence=m[0] if m else 'metric missing', **kw)

    if group == 'launch':
        # docs/architecture.md performance table; app-shell plan Q9 existing profile.
        for key, limit in (('sidebarDrawn', 250), ('firstContentfulPaint', 700), ('main', 50), ('modelLoaded', 120)):
            samples = [s['timing'].get(key) for s in data.get('samples', [])]
            complete = len(samples) >= 7 and all(isinstance(v, (int, float)) for v in samples)
            med = statistics.median(samples) if complete else None
            p95 = sorted(samples)[math.ceil(len(samples) * .95) - 1] if complete else None
            add('launch ' + key, limit, med, metric='median', samples=len(samples),
                source='docs/plans/app-shell.md §5.1/Q9; docs/architecture.md',
                evidence={'p95_ms': p95, 'existing_profile': True})
            rows[-1]['measured']['p95'] = p95
    elif group == 'first-run':
        # docs/status.md F12; docs/first-run/steps-ef-verification.md Release timing.
        for label, values, limit in (
            ('first-run first content', [s['welcome']['sidebarDrawn'] for s in data.get('samples', [])], 250),
            ('first-run imported paint', [s['imported_paint_ms'] for s in data.get('samples', [])], 700)):
            add(label, limit, statistics.median(values) if len(values) == 5 else None,
                metric='median', samples=len(values), ok=all(v >= 0 for v in values),
                source='docs/status.md F12; docs/first-run/steps-ef-verification.md Release timing')
            rows[-1]['measured']['p95'] = max(values) if values else None
    elif group.startswith('idle-'):
        # Lead ruling 2026-11-08 09:30, docs/architecture.md performance budgets:
        # static ten-page total CPU <=0.5%; animated selected page is informational.
        cpu = data.get('cpu', {})
        limit = 0.5 if group == 'idle-static' else None
        add(group + ' ten pages', limit, cpu.get('total_cpu_percent'), unit='%', metric='mean',
            samples='1 × 60 s; settle 90 s', ok=cpu.get('complete', False),
            source='docs/architecture.md; docs/idle-cpu.md; docs/s8-speed-gates.md',
            evidence=cpu)
        if limit is None:
            rows[-1]['budget_label'] = 'animated page (no numeric budget)'
            rows[-1]['operator'] = None
            if rows[-1]['status'] == 'PASS':
                rows[-1]['status'] = 'NO NUMERIC BUDGET'
    elif group == 'sitecontrol':
        source = 'Packages/OpenKit/Sources/sitecontrol-render/'
        # Bench.swift / docs/plans/site-control.md §8: strict CPU target <8 ms.
        numeric('Site Control cold open CPU', 8, r'^cold open:.*?CPU p95 ([\d.]+) ms', samples=30,
                strict=True, source='docs/followups.md Site Control performance; ' + source + 'Bench.swift')
        # EditorOpenBench.swift: full check procedure owns <12 ms acceptance.
        numeric('simple editor open CPU', 12, r'^Editor open:.*?main-thread CPU p95 ([\d.]+) ms',
                samples=20, strict=True, source=source + 'EditorOpenBench.swift; docs/verification.md Simple Boost editor open')
        for label, pattern, n in (
            ('Site Control cold instructions', r'cold open main-thread median (\d+) instructions', 30),
            ('simple editor instructions', r'simple editor build/layout/first draw median (\d+) instructions', 20)):
            observed = match(pattern)
            m = match(pattern + r' <= (\d+)')
            add(label, int(m[2]) if m else None, int(observed[1]) if observed else None,
                unit='instructions', metric='median', samples=n, ok=m is not None,
                source=source + 'Bench.swift / EditorOpenBench.swift; Resources instruction baselines')
            if m is None:
                rows[-1]['budget_label'] = 'accepted machine instruction ceiling unavailable'
        numeric('editor idle CPU', 10, r'^Editor idle: ([\d.]+) ms', metric='total', samples='1 × 2 s', strict=True,
                source=source + 'EditorBench.swift (<0.5% main thread / 2 s)', ok='no host work=true' in text)
        numeric('editor ten-page refresh', 100, r'ten-page refresh max ([\d.]+) ms', metric='max', samples=10, strict=True, source=source + 'EditorBench.swift')
        numeric('editor pad CPU', 2, r'^Editor: pad event main-thread CPU p95 ([\d.]+) ms', samples=500, strict=True, source=source + 'EditorBench.swift')
        numeric('editor hue off-main', 15, r'hue sample ([\d.]+) ms off-main=true', metric='elapsed', samples=1, strict=True, source=source + 'EditorBench.swift')
        numeric('code keystroke highlight CPU', 2, r'^Code keystroke:.*?CPU p95 ([\d.]+) ms', samples=100, strict=True, source=source + 'CodeFlows.swift')
        numeric('editor preview coalescing', 61, r'previews (\d+) in 1 s / 120 Hz', unit='previews', metric='count',
                samples=120, source=source + 'EditorBench.swift', ok=bool(match(r'previews [1-9]\d* in 1 s')))
    elif group == 'sidebar':
        # SM6CostGate.swift: one discarded fresh process then median of five.
        m = match(r'SM6 cost median (\d+) <= (\d+) instructions')
        observed = match(r'SM6 cost five-process median=(\d+)')
        add('SM6 cost', int(m[2]) if m else None, int(m[1]) if m else int(observed[1]) if observed else None,
            unit='instructions', metric='median', samples=5, ok=m is not None,
            source='Packages/OpenKit/Sources/sidebar-render/SM6CostGate.swift; Resources/sm6-cost-baselines.json')
        if m is None:
            rows[-1]['budget_label'] = 'accepted machine instruction ceiling unavailable'
        # docs/plans/sidebar-completion.md SM6: <=120ms. Reuse the fresh
        # process wall spans from the same cost run; discard its declared warmup.
        sm6 = []
        for line in text.splitlines():
            if line.startswith('SM6_JSON '):
                with contextlib.suppress(json.JSONDecodeError):
                    sm6.append(json.loads(line[9:]))
        walls = [sample['wallMS'] for sample in sm6[1:]] if len(sm6) == 6 else []
        add('SM6 first layout wall', 120, statistics.median(walls) if walls else None,
            metric='median', samples=len(walls), source='docs/plans/sidebar-completion.md SM6; sidebar-render/SM6Measure.swift')
        rows[-1]['measured']['p95'] = sorted(walls)[-1] if walls else None
        structure = [line for line in text.splitlines() if re.search(r'^\s*(?:OK|PASS|FAIL)\s+SM6', line) and 'cost' not in line]
        add('SM6 structure', 0, sum('FAIL' in line for line in structure) if structure else None,
            unit='failures', metric='count', samples=len(structure), evidence=structure,
            source='Packages/OpenKit/Sources/sidebar-render/SM6Fixture.swift (structural fallback)')
        numeric('mini-player paused idle CPU', .5, r'MC8 paused idle CPU ([\d.]+)%', unit='%', metric='mean', samples='1 × 2 s',
                source='Packages/OpenKit/Sources/sidebar-render/MediaChecks.swift MC8')
    elif group == 'commandbar':
        # commandbar-render/main.swift (#132/#135/#136, now rows 150/151), s8-speed-gates.md.
        m = match(r'keystroke → rows drawn, main CPU: p50 ([\d.]+) ms  p95 ([\d.]+) ms')
        count = match(r'(\d+) keystrokes')
        n = int(count[1]) if count else None
        add('command bar keystroke CPU', 8, float(m[2]) if m else None, median=float(m[1]) if m else None,
            samples=n, strict=True, ok=native_ok('keystroke → rows drawn, main-thread CPU p95'),
            source='Packages/OpenKit/Sources/commandbar-render/main.swift; docs/s8-speed-gates.md')
        m = match(r'inline completion adds .*?: p95 ([+\-\d.]+) ms.*?paired median ([+\-\d.]+) ms')
        add('inline completion added CPU', .3, float(m[1]) if m else None, median=float(m[2]) if m else None,
            samples=n, ok=native_ok('inline completion adds ≤ 0.3 ms'),
            source='Packages/OpenKit/Sources/commandbar-render/main.swift; Bench.swift')
        numeric('command bar layout passes', 1, r'layout passes on max (\d+)', unit='passes', metric='max', samples=n,
                ok=native_ok('inline completion adds ≤ 0.3 ms'),
                source='Packages/OpenKit/Sources/commandbar-render/main.swift')
    elif group == 'tab-switch':
        # architecture.md strict product target, NOT the separate approved 25ms relative gate.
        for key in ('single', 'split'):
            values = data.get('samples', {}).get(key, [])
            add('tab switch ' + key, 16, sorted(values)[math.ceil(len(values)*.95)-1] if values else None,
                median=statistics.median(values) if values else None, samples=len(values),
                source='docs/architecture.md; tools/verification/split-app-speed.py')
    elif group == 'sidebar-bench':
        # architecture.md 120Hz; sidebar-render/Bench.swift emits its 8.33ms limit.
        m = match(r'scroll (\d+) steps.*?median ([\d.]+) ms, p95 ([\d.]+) ms')
        add('sidebar scroll 120 Hz', 8.33, float(m[3]) if m else None, median=float(m[2]) if m else None,
            samples=int(m[1]) if m else None, source='docs/architecture.md; Packages/OpenKit/Sources/sidebar-render/Bench.swift')
        m = match(r'moveNode ×200.*?median ([\d.]+) ms, p95 ([\d.]+) ms')
        add('sidebar drag/model move', 8.33, float(m[2]) if m else None, median=float(m[1]) if m else None,
            samples=200, source='docs/architecture.md 120Hz; Packages/OpenKit/Sources/sidebar-render/Bench.swift')
    elif group == 'sidebar-selection':
        numeric('sidebar selection toggle', 1, r'MS14 selection.*?p95 ([\d.]+) ms', samples=200,
                source='Packages/OpenKit/Sources/sidebar-render/Bench.swift MS14')
    elif group == 'sidebar-bulk':
        # Bench.swift MS14: all four p95 values <=16ms, 50 selected rows ×40.
        for label, pattern in (
            ('move', r'MS14 bulk 50 ×40.*?move p95 ([\d.]+) ms'),
            ('archive', r'MS14 bulk 50 ×40.*?archive p95 ([\d.]+) ms'),
            ('folder', r'MS14 bulk 50 Today → folder ×40: p95 ([\d.]+) ms'),
            ('Space', r'Space-icon bulk move ×40: p95 ([\d.]+) ms')):
            numeric('sidebar bulk ' + label, 16, pattern, samples=40, source='Packages/OpenKit/Sources/sidebar-render/Bench.swift MS14')
    elif group == 'sidebar-expand':
        numeric('sidebar Expand All', 16, r'EA4 Expand All.*?p95 ([\d.]+) ms', samples=40,
                source='Packages/OpenKit/Sources/sidebar-render/Bench.swift EA4')
    elif group == 'folder-peek':
        # FolderPeekBench.swift has three declared attempts; retain every one.
        attempts = list(re.finditer(r'FP10 transition p95 peek=([\d.]+) ms.*?limit=([\d.]+) ms', text))
        transitions = list(re.finditer(r'FP10 transition-main-thread n=(\d+) median ([\d.]+) ms', text))
        for index, m in enumerate(attempts):
            add('FP10 transition attempt ' + str(index+1), float(m[2]), float(m[1]), samples=240,
                median=float(transitions[index][2]) if index < len(transitions) else None,
                source='Packages/OpenKit/Sources/sidebar-render/FolderPeekBench.swift', evidence=m[0])
        for index, m in enumerate(re.finditer(r'FP10 transition-main-thread n=(\d+) median ([\d.]+) ms', text)):
            add('FP10 median goal attempt ' + str(index+1), 1, float(m[2]), metric='median', samples=int(m[1]), strict=True,
                source='docs/status.md collapsed-folder row; docs/followups.md sidebar outline-wide rendering')
        scrolls = list(re.finditer(r'FP10 peek-scroll n=(\d+) median ([\d.]+) ms p95 ([\d.]+) ms', text))
        for index, m in enumerate(scrolls):
            add('FP10 scroll attempt ' + str(index+1), 8.33, float(m[3]), median=float(m[2]), samples=int(m[1]),
                source='Packages/OpenKit/Sources/sidebar-render/FolderPeekBench.swift')
        relative = list(re.finditer(r'FP10 paired scroll p95 limit=([\d.]+) ms', text))
        for index, m in enumerate(scrolls):
            add('FP10 relative scroll attempt ' + str(index+1), float(relative[index][1]) if index < len(relative) else None,
                float(m[3]), samples=int(m[1]), ok=index < len(relative),
                source='Packages/OpenKit/Sources/sidebar-render/FolderPeekBench.swift matched baseline *1.10 +0.05ms')
        if not attempts:
            add('FP10 transition', 2, source='Packages/OpenKit/Sources/sidebar-render/FolderPeekBench.swift')
    elif group == 'suggest':
        source = 'Packages/OpenKit/Sources/openkit/SuggestCheck.swift'
        attempts = list(re.finditer(r'^  \.\. remote real-time attempt (\d+) stream ended after ([\d.]+) ms', text, re.MULTILINE))
        # Existing #31 allows at most three attempts. Show all; its own verdict
        # owns acceptance. No additional retry is introduced by this runner.
        values = [float(m[2]) for m in attempts]
        add('suggest #31 slow-server stream', 600, min(values) if values else None, metric='best_attempt',
            samples=len(values), strict=True, source=source + ' #31', evidence=values,
            ok=bool(match(r'PASS.*remote: real-time slow-server')))
        numeric('suggest extension actions CPU', .2, r'local synchronous p95 ([\d.]+) ms', samples=100, strict=True, source=source)
        for name, prefix, limit, strict in (
            ('suggest first snapshot CPU', 'first snapshot, main-thread CPU:', 5, True),
            ('suggest inline snapshot CPU', 'first snapshot with inline completion allowed, main-thread CPU:', 5, True),
            ('suggest completion check CPU', 'completion check over the snapshot rows, CPU:', .05, False)):
            m = match('^' + re.escape(prefix) + r'.*?p50 ([\d.]+) ms  p95 ([\d.]+) ms')
            add(name, limit, float(m[2]) if m else None, median=float(m[1]) if m else None,
                samples=1000, strict=strict, source=source, evidence=m[0] if m else 'metric missing')
    elif group == 'adblock':
        # AdBlockCLI.swift lead decision 2026-10-25, also check.py adblock_perf.
        for label, pattern, limit in (('adblock 1000 lookups', r'lookups_1000 p95_ms=([\d.]+)', 1),
                                      ('adblock profile integrity scan', r'profile_open_with_integrity_scan p95_ms=([\d.]+)', 10)):
            numeric(label, limit, pattern, samples=10, strict=True,
                    source='Packages/OpenKit/Sources/openkit/AdBlockCLI.swift; tools/verification/check.py adblock_perf')
    elif group == 'command-open':
        # architecture.md; engine_e2e.py app_actions first_open_results_budget.
        add('command bar cold first results' + (' [FAIL DEMO]' if fail_demo else ''), 1 if fail_demo else 50,
            data.get('milliseconds'), metric='elapsed', samples=1,
            source='docs/architecture.md; tools/e2e/engine_e2e.py first_open_results_budget')
    elif group == 'find':
        # docs/status.md Find; find_checks.py F04_one_frame 120Hz gate.
        for key in ('first', 'repeat'):
            values = [sample[key] for sample in data.get('samples', [])]
            add('Find ' + key + ' open', 1000/120, sorted(values)[math.ceil(len(values)*.95)-1] if values else None,
                median=statistics.median(values) if values else None, samples=len(values), ok=len(values) == 20,
                source='tools/e2e/find_checks.py F04_one_frame; docs/status.md Find')
    elif group == 'theme':
        # space-editor-render LiveThemeChecks.swift B1, Checks.swift costs().
        numeric('theme B1 two-window ticks CPU', 4, r'B1 240 ticks.*?main-thread p95 ([\d.]+) ms', samples=240,
                source='Packages/OpenKit/Sources/space-editor-render/LiveThemeChecks.swift B1')
        for m in re.finditer(r'PERF (cold tile .+? @2x|field style \d+) ([\d.]+) ms \(loose ceiling (\d+) ms\)', text):
            add('theme ' + m[1], float(m[3]), float(m[2]), metric='elapsed', samples=1, strict=True,
                source='Packages/OpenKit/Sources/space-editor-render/Checks.swift costs()')
    elif group == 'features':
        numeric('PiP offscreen idle CPU', .5, r'PP idle offscreen window CPU ([\d.]+)%', unit='%', metric='mean', samples='1 × 2 s',
                source='Packages/OpenKit/Sources/features-render/PiPChecks.swift PP idle')
    elif group == 'favicons':
        numeric('stored favicons 1000-row scroll', 8.33, r'FV10 1000 stored-icon rows scroll p95 ([\d.]+) ms', samples='all scroll steps',
                source='Packages/OpenKit/Sources/features-render/FaviconChecks.swift FV10')
    elif group == 'feature-idle':
        # s8-speed-gates.md: all observer resources/events zero, both motion modes.
        measured = [line for line in text.splitlines() if re.match(r'(PASS|FAIL) S8 idle ', line)]
        add('S8 toast/swipe idle work', 0, sum(line.startswith('FAIL') for line in measured) if len(measured) == 10 else None,
            unit='failed windows', metric='count', samples='10 × 2 s', evidence=measured,
            source='docs/s8-speed-gates.md; Packages/OpenKit/Sources/features-render/IdleChecks.swift')
    # Retain failures outside parsed budgets. A partial or interrupted harness
    # can never make a clean run. All raw logs remain available for diagnosis.
    if group not in APP:
        add(group + ' harness', 0, receipt.get('returncode'), unit='exit', metric='code', samples=1,
            source='existing CLI exit status (includes functional/structural checks)')
    if not rows:
        add(group, None, evidence='no metrics found', source='existing harness')
    return rows


def preflight(app, groups):
    missing = []
    build = 'OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main OPEN_AUTOMATION=1 ~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh Release'
    cli_build = 'OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main ~/Library/Caches/OpenRE/scripts/heavy.sh swift build -c release --package-path Packages/OpenKit'
    if not (app / 'Contents/MacOS/Open').is_file():
        missing.append('Missing App: ' + str(app) + '\n  ' + build)
    products = needed_products(groups)
    for product in products:
        if not os.access(BIN / product, os.X_OK):
            missing.append('Missing release CLI: ' + product + '\n  ' + cli_build + ' --product ' + product)
    # Keep SwiftPM's bundles beside the release CLIs. Copying a CLI alone can
    # abort in Bundle.module before any harness cleanup can run.
    for name in (('OpenAdBlock', 'OpenBoosts', 'OpenCommands', 'OpenFeatures', 'OpenMedia',
                 'OpenSleep', 'OpenSpaceEditor', 'OpenSuggest', 'OpenTranslate', 'openkit',
                 'sidebar-render', 'sitecontrol-render', 'space-editor-render') if products else ()):
        if not (BIN / ('OpenKit_' + name + '.bundle')).is_dir():
            missing.append('Missing SwiftPM resource bundle: OpenKit_' + name + '.bundle\n  ' + cli_build)
    # Open.__init__ normally compiles these on demand. Refuse before any row so
    # this prebuilt runner cannot build, including helpers, inside a timing lock.
    for name in (('activate-own-app', 'owned-window-count') if any(group in APP for group in groups) else ()):
        source = ROOT / 'tools/e2e' / (name + '.swift')
        target = HELPERS / name
        if not target.exists() or target.stat().st_mtime < source.stat().st_mtime:
            missing.append('Missing/stale automation helper: ' + name + '\n  mkdir -p .re/e2e-tools\n  xcrun swiftc -O -swift-version 6 -parse-as-library tools/e2e/' + name + '.swift -o .re/e2e-tools/' + name)
    probe = HELPERS / 'budgets-idle-probe.dylib'
    if 'feature-idle' in groups and (not probe.exists() or probe.stat().st_mtime < (ROOT / 'tools/verification/feature-idle-probe.m').stat().st_mtime):
        missing.append('Missing/stale idle observer:\n  xcrun clang -dynamiclib -fblocks -fobjc-arc -Wno-deprecated-declarations tools/verification/feature-idle-probe.m -framework AppKit -framework QuartzCore -framework CoreVideo -o .re/e2e-tools/budgets-idle-probe.dylib')
    if missing:
        raise RuntimeError('\n'.join(missing))
    signature = subprocess.run(['codesign', '-dvv', str(app)], capture_output=True, text=True, timeout=15)
    if signature.returncode or re.search(r'flags=.*\bruntime\b', signature.stderr):
        raise RuntimeError('App must be a normal development build, without hardened runtime. Refusing launch; use:\n  ' + build)
    verified = subprocess.run(['codesign', '--verify', '--deep', str(app)], capture_output=True, timeout=60)
    if verified.returncode:
        raise RuntimeError('App signature verification failed; refusing launch. Rebuild with:\n  ' + build)
    if '/Volumes/' in str(app):
        raise RuntimeError('Refusing App on a mounted image; use tools/build.sh Release')


def socket_preflight(groups, data_root):
    # engine_e2e.Open uses <user_data>/automation.sock. macOS sun_path has
    # 104 bytes including its terminator; keep the requested 100-byte ceiling.
    extracted = load_module('budgets_socket_paths', ROOT / 'tools/verification/budgets_app.py')
    paths = []
    for group in groups:
        if group in APP:
            for profile in extracted.profile_roots(group, data_root / group):
                socket = profile / 'automation.sock'
                for path in {str(socket), str(socket.resolve())}:
                    paths.append(dict(path=path, bytes=len(os.fsencode(path)), group=group))
    longest = max(paths, key=lambda entry: entry['bytes']) if paths else None
    check = dict(limit_bytes=100, longest=longest, paths=paths)
    if longest and longest['bytes'] > 100:
        raise RuntimeError('Automation socket preflight refused: ' + json.dumps(check))
    return check


def quiet_start(max_load):
    # Operator guard for the lead's 2026-11-07 quiet window, not a product budget.
    load1 = os.getloadavg()[0]
    listing = subprocess.check_output(['/bin/ps', '-ax', '-o', 'pid=,comm='], text=True, timeout=10)
    blocked = []
    names = {'Open', 'xcodebuild', 'siso', *needed_products(GROUPS)}
    for line in listing.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2:
            name = Path(fields[1]).name
            if name in names or name.startswith('Open Helper'):
                blocked.append({'pid': int(fields[0]), 'name': name})
    check = {'load1': load1, 'limit': max_load, 'blocking_processes': blocked}
    if load1 > max_load or blocked:
        raise RuntimeError('Quiet start refused (no wait): ' + json.dumps(check))
    return check


def time_left(deadline, maximum):
    if deadline is None:
        return maximum
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError('budget run reached its time limit; remaining workloads were not run')
    return min(maximum, remaining)


def priority_wait(deadline):
    flag = Path('/tmp/open-onscreen-priority')
    while flag.exists():
        try:
            if time.time() - flag.stat().st_mtime >= 1800:
                return
        except FileNotFoundError:
            return
        print('Waiting for on-screen priority holder (no load wait).', file=sys.stderr, flush=True)
        time.sleep(time_left(deadline, 15))


def invoke(group, app, scratch, data_root, deadline):
    output = scratch / 'receipt.json'
    argv = [sys.executable, str(Path(__file__).resolve()), '--worker', group, '--app', str(app),
            '--out', str(output), '--data-root', str(data_root)]
    if group in SCREEN:
        priority_wait(deadline)
        argv = ['/usr/bin/lockf', '-k', '/tmp/open-onscreen-e2e.lock', *argv]
    with (scratch / 'worker.log').open('w') as log:
        mask = signal.pthread_sigmask(signal.SIG_BLOCK, (signal.SIGTERM, signal.SIGINT, signal.SIGHUP))
        job = None
        try:
            # Both drivers are single-threaded here. Restore the child's mask
            # before exec, so recording Popen cannot lose a cancellation and
            # the spawned harness still receives ordinary termination signals.
            job = subprocess.Popen(argv, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
                                   preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, mask))
            signal.pthread_sigmask(signal.SIG_SETMASK, mask)
            # Queue wait is outside the worker's measured load interval.
            job.wait(timeout=time_left(deadline, 3600))
        finally:
            signal.pthread_sigmask(signal.SIG_BLOCK, (signal.SIGTERM, signal.SIGINT, signal.SIGHUP))
            if job is not None and job.poll() is None:
                pidfile = scratch / 'worker.pid'
                if pidfile.exists():
                    with contextlib.suppress(ProcessLookupError):
                        os.kill(int(pidfile.read_text()), signal.SIGTERM)
                    try:
                        job.wait(timeout=120)  # Worker restores defaults/reaps App before lock release.
                    except subprocess.TimeoutExpired:
                        pass
                stop(job)
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(job.pid, signal.SIGKILL)
            signal.pthread_sigmask(signal.SIG_SETMASK, mask)
    if not output.exists() or output.stat().st_size > LIMIT:
        raise RuntimeError('worker did not write a bounded receipt; see ' + str(scratch / 'worker.log'))
    return json.loads(output.read_text())


def print_table(rows, max_load, quiet):
    print('| Row | Budget | Measured | Samples | Result | Load1 start (max-load {:g}; guard {}) | Load1 end |'.format(
        max_load, 'on' if quiet else 'off'))
    print('|---|---|---|---|---|---|---|')
    for row in rows:
        budget = row.get('budget_label') or (row['operator'] + ' ' + str(row['budget']) + ' ' + row['unit'])
        measured = ', '.join(key + ' ' + (format(value, '.4f').rstrip('0').rstrip('.') if value is not None else 'missing')
                             for key, value in row['measured'].items()) + ' ' + row['unit']
        print('| {} | {} | {} | {} | {} | {:.2f} | {:.2f} |'.format(
            row['row'], budget, measured, row['samples'], row['status'], row['load1_start'], row['load1_end']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=ROOT / 'build/Release/Open.app')
    parser.add_argument('--out', type=Path, required=True, help='JSON receipt; adjacent .logs directory retains raw harness logs')
    parser.add_argument('--only', choices=GROUPS, help='diagnostic subset; omitted runs every workload once')
    parser.add_argument('--fail-demo', action='store_true', help='copy the cold command-open limit to 1 ms in this receipt only')
    parser.add_argument('--preflight', action='store_true', help='check paths, sockets, signatures and helpers; launch no App or measurement CLI')
    parser.add_argument('--report', type=Path, help='render saved worker receipts using current budget reporting; launch nothing')
    parser.add_argument('--quiet-start', action='store_true', help='refuse above --max-load or with an Open, release CLI, xcodebuild or siso process; never wait')
    parser.add_argument('--max-load', type=float, default=4,
                        help='quiet-start load1 ceiling, recorded in the table and JSON (default 4)')
    parser.add_argument('--max-seconds', type=float, default=2220,
                        help='whole-run deadline before cleanup (default 2220: 37 min, plus at most 3 min cleanup reserve)')
    parser.add_argument('--worker', choices=GROUPS, help=argparse.SUPPRESS)
    parser.add_argument('--data-root', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if not math.isfinite(args.max_seconds) or args.max_seconds <= 0:
        parser.error('--max-seconds must be finite and positive')
    if not math.isfinite(args.max_load) or args.max_load <= 0:
        parser.error('--max-load must be finite and positive')
    if args.data_root is not None and not args.worker:
        parser.error('--data-root is internal to --worker')
    if args.report and (args.worker or args.only or args.fail_demo or args.preflight or args.quiet_start):
        parser.error('--report cannot be combined with measurement or preflight selectors')
    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(number, interrupt)
    app = args.app.resolve()
    output = args.out.resolve()
    if args.worker:
        if args.data_root is None:
            parser.error('--worker requires --data-root')
        worker(args.worker, app, output, args.data_root)
        return 0
    groups = (args.only,) if args.only else GROUPS
    started = time.monotonic()
    deadline = started + args.max_seconds
    result = dict(schema=1, app=str(app), groups=groups, partial=bool(args.only), fail_demo=args.fail_demo,
                  mode='report' if args.report else 'preflight' if args.preflight else 'measure', max_seconds=args.max_seconds,
                  max_load=args.max_load, quiet_start_enabled=args.quiet_start,
                  revision=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                  host=os.uname().nodename, rows=[], receipts=[], complete=False)
    output.parent.mkdir(parents=True, exist_ok=True)
    logs = output.with_name(output.name + '.logs')
    if output.exists() or logs.exists():
        print('Refusing to overwrite an earlier receipt/logs; choose a new --out path.', file=sys.stderr)
        print_table([], args.max_load, args.quiet_start)
        return 1
    data_root = None
    try:
        if args.report:
            source = args.report.resolve()
            if source.stat().st_size > LIMIT:
                raise RuntimeError('saved receipt exceeds 16 MiB')
            encoded = source.read_bytes()
            saved = json.loads(encoded)
            receipts = saved.get('receipts')
            if not isinstance(receipts, list) or not 1 <= len(receipts) <= len(GROUPS):
                raise RuntimeError('saved receipt must contain 1–21 worker receipts')
            result.update(app=saved['app'], groups=saved['groups'], partial=saved['partial'],
                          fail_demo=saved['fail_demo'], max_load=saved['max_load'],
                          quiet_start_enabled=saved['quiet_start_enabled'], receipts=receipts,
                          complete=saved['complete'], artifact_sha256=saved['artifact_sha256'])
            result['reported_from'] = dict(path=str(source), sha256=hashlib.sha256(encoded).hexdigest(),
                                           revision=saved['revision'], source_sha256=saved['source_sha256'],
                                           elapsed_seconds=saved['elapsed_seconds'])
            result['reporter_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
            result['rows'] = [row for receipt in receipts for row in rows_from(receipt, saved['fail_demo'])]
        elif args.quiet_start:
            result['quiet_start'] = quiet_start(args.max_load)
        # Never derive a Unix socket path from --out or the caller's TMPDIR.
        # mkdtemp creates a private (0700) root; logs remain beside --out.
        if args.report:
            return 0 if result['complete'] and all(row['status'] in ('PASS', 'NO NUMERIC BUDGET') for row in result['rows']) else 1
        data_root = Path(tempfile.mkdtemp(prefix='ob.', dir='/tmp'))
        result['data_root'] = str(data_root)
        result['socket_paths'] = socket_preflight(groups, data_root)
        preflight(app, groups)
        artifacts = [app / 'Contents/MacOS/Open', *(BIN / name for name in needed_products(groups))]
        result['artifact_sha256'] = {}
        for artifact in artifacts:
            digest = hashlib.sha256()
            with artifact.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(chunk)
            result['artifact_sha256'][str(artifact)] = digest.hexdigest()
        result['source_sha256'] = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                   for path in (Path(__file__).resolve(), ROOT / 'tools/verification/budgets_app.py',
                                                ROOT / 'tools/e2e/engine_e2e.py')}
        if args.preflight:
            result['preflight'] = 'PASS'
            longest = result['socket_paths']['longest']
            print('Preflight PASS: App, {} release CLIs, bundles and required helpers resolve; longest socket {} bytes (limit 100); no App or measurement CLI launched.'.format(
                len(needed_products(groups)), longest['bytes'] if longest else 0), file=sys.stderr)
        else:
            logs.mkdir(mode=0o700, exist_ok=False)
            for group in groups:
                time_left(deadline, 3600)
                print('Measuring ' + group + '; load1=' + format(os.getloadavg()[0], '.2f'), file=sys.stderr, flush=True)
                scratch = logs / group
                scratch.mkdir()
                work = data_root / group
                work.mkdir(mode=0o700)
                receipt = invoke(group, app, scratch, work, deadline)
                result['receipts'].append(receipt)
                result['rows'].extend(rows_from(receipt, args.fail_demo))
                atomic_json(output, result)
                if receipt.get('crashed') or receipt.get('stop_onscreen') or receipt.get('interrupted') or not receipt.get('cleanup'):
                    raise RuntimeError('Stopped after crash/launch/cleanup error in ' + group + '; notify the S16 lead before more screen work')
            result['complete'] = True
    except BaseException as error:
        result['error'] = str(error)
        print(str(error), file=sys.stderr)
    finally:
        if data_root is not None:
            try:
                shutil.rmtree(data_root)
                result['data_root_removed'] = not data_root.exists()
            except OSError as error:
                result['error'] = 'private data root cleanup failed: ' + str(error)
                result['complete'] = False
                if args.preflight:
                    result['preflight'] = 'FAIL'
        result['elapsed_seconds'] = round(time.monotonic() - started, 3)
        atomic_json(output, result)
        print_table(result['rows'], result['max_load'], result['quiet_start_enabled'])
    if args.preflight:
        return 0 if result.get('preflight') == 'PASS' and not result.get('error') else 1
    return 0 if result['complete'] and all(r['status'] in ('PASS', 'NO NUMERIC BUDGET') for r in result['rows']) else 1


if __name__ == '__main__':
    raise SystemExit(main())
