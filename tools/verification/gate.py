#!/usr/bin/env python3
"""Merge gate inside one FIFO build slot, with one screen lock per suite."""
import argparse
import ast
import contextlib
import hashlib
import json
import os
from pathlib import Path
from gate_evidence import e2e_rows
from gate_exceptions import read_bounded, assert_shrink_only, evaluate
import signal
import shutil
import subprocess
import sys
import tempfile
import time
from screen_cleanup import cleanup_owned

ROOT = Path(__file__).resolve().parents[2]  # final location tools/verification/gate.py
NATIVE = ('space-editor', 'settings-preview', 'features-render', 'sitecontrol-render')
M1_NATIVE = {'features-idle'}
# Transitive observer/fault-probe flows, not only direct suite implementations.
M1_E2E = {'ntp', 'ntp-alloy', 'features', 'profiles', 'profiles-engine', 'passwords',
          'passwords-probe', 'secrets-import', 'owner-watch'}
OBSERVER_SUITES = {'sitecontrol', 'find', 'split', 'littleopen', 'downloads'}
M5_E2E = {'applescript'}  # No external AppleScript/osascript over SSH on the M1.
SAFE_M5 = set('ntp onboarding welcome import-robust firstrun shell extensions tabstrip window sidebar peek commandbar app-actions actions extensions-p3 extensions-ui sitecontrol extensions-e2 sidebar-completion toolbar numbering media relaunch page page-chrome sleep context-menus routing history applescript boosteditor boost-gallery space-editor incognito sitedata find split littleopen downloads measure'.split())
CLI = ('commands-demo roundtrip space-legacy space-pad-compare suggest-check commands-dump '
       'route favicons media-demo sleep-demo adblock-perf adblock-catalog profiles '
       'sidebar-render sidebar-compare commandbar-render extensions-render '
       'onboarding-render boosts import-arc verify-secrets-fixture').split()


def ancestors():
    pid = os.getppid()
    for _ in range(64):
        if pid <= 1:
            return
        row = subprocess.check_output(['ps', '-p', str(pid), '-o', 'ppid=,args='], text=True).strip()
        if not row:
            return
        parent, _, args = row.partition(' ')
        yield pid, args.strip()
        pid = int(parent)


def inside_heavy():
    # A launcher may mention heavy.sh in its arguments without owning a slot.
    # Require the live FIFO holder itself in our ancestry, not that text.
    holder = Path('/tmp/open-heavy-holder')
    if not holder.is_file() or holder.stat().st_size > 4096:
        return False
    fields = holder.read_text().split('\t', 1)
    if not fields[0].isdigit():
        return False
    return any(pid == int(fields[0]) for pid, _ in ancestors())


def machine():
    chip = subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip()
    return 'M1' if chip.startswith('Apple M1') else 'M5' if chip.startswith('Apple M5') else chip


def suite_names():
    tree = ast.parse((ROOT / 'tools/e2e/engine_e2e.py').read_text())
    choices = []
    for call in ast.walk(tree):
        if isinstance(call, ast.Call) and isinstance(call.func, ast.Attribute) and call.func.attr == 'add_argument':
            if call.args and isinstance(call.args[0], ast.Constant) and call.args[0].value == '--only':
                choices.append(ast.literal_eval(next(k.value for k in call.keywords if k.arg == 'choices')))
    if len(choices) != 1 or not choices[0] or any(not isinstance(s, str) or len(s) > 40 for s in choices[0]):
        raise RuntimeError('cannot read complete real-App suite list; gate refuses to omit suites')
    return choices[0] + ['owner-watch']


def fingerprint():
    cef = ROOT / 'Vendor/cef/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework'
    if not cef.is_file():
        engine_root = Path(os.environ.get('OPEN_ENGINE_ROOT', str(Path.home() / 'Developer/open-engine')))
        record = engine_root / '.open-engine-state/distrib.txt'
        distribution = Path(record.read_text().strip())
        cef = distribution / 'Release/Chromium Embedded Framework.framework/Chromium Embedded Framework'
    digest = hashlib.sha256()
    with cef.open('rb') as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            digest.update(block)
    dirty = subprocess.check_output(['git', 'diff', 'HEAD', '--', 'App', 'Engine', 'Packages', 'tools'], cwd=ROOT)
    untracked = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '--',
        'App', 'Engine', 'Packages', 'tools'], cwd=ROOT, text=True).strip()
    if untracked:
        raise RuntimeError('untracked source inputs must be committed before qualification: ' + untracked[:1024])
    return dict(head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                clean=not dirty, diffSHA256=hashlib.sha256(dirty).hexdigest(), engineSHA256=digest.hexdigest())


def read_json(path):
    if path.stat().st_size > 16 * 1024 * 1024:
        raise RuntimeError('receipt exceeds 16 MiB')
    return json.loads(path.read_text())


def write_json(path, value):
    target = path.with_suffix('.tmp')
    target.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    target.replace(path)


def cli_rows(path):
    if not path.is_file():
        return []
    return [dict(name=name, result=result, seconds=int(seconds))
            for name, result, seconds in (line.split('\t') for line in path.read_text().splitlines())]


def run_heavy(args):
    if not inside_heavy():
        raise RuntimeError('internal heavy worker requires host heavy.sh')
    log = Path(args.log)
    env = dict(os.environ, VERIFY_LOG_DIR=str(log / 'cli'))
    command = [str(ROOT / 'tools/verification/cli-worker.sh'), '--only', args.selection, '--keep-logs']
    if args.arc:
        command.append('--with-arc-data')
    with (log / 'cli-worker.log').open('w') as output:
        status = subprocess.call(command, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT)
    rows = cli_rows(log / 'cli/results.tsv')
    if not rows or rows[0].get('result') != 'PASS':
        return status or 1
    with (log / 'screen-guard-build.log').open('w') as output:
        rc = subprocess.call(['xcrun', 'swiftc', '-O', str(ROOT/'tools/verification/system-windows.swift'),
                              '-o', str(log/'system-windows')], cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
    write_json(log/'screen-guard-build.json', dict(result='PASS' if rc == 0 else 'FAIL', exit=rc))
    if rc:
        return rc
    if args.app_config:
        start = time.monotonic()
        with (log / 'app-build.log').open('w') as output:
            rc = subprocess.call([str(ROOT / 'tools/build.sh'), args.app_config], cwd=ROOT,
                                 env=dict(os.environ, OPEN_AUTOMATION='1'),
                                 stdout=output, stderr=subprocess.STDOUT)
        write_json(log / 'app-build.json', dict(name='app-build', result='PASS' if rc == 0 else 'FAIL',
                                              seconds=round(time.monotonic() - start, 3), exit=rc))
        status = status or rc
    return status


def run_screen(args):
    # A literal pathname lockf parent owns the lock through this process's
    # cleanup. Native nested workers borrow that lock after checking ancestry.
    if not any('/tmp/open-onscreen-e2e.lock' in command and '/usr/bin/lockf' in command
               for _, command in ancestors()):
        raise RuntimeError('screen worker requires pathname lockf parent')
    directory = Path(args.log)
    write_json(directory / 'screen-start.json', dict(pid=os.getpid(), started=time.time(), monotonic=time.monotonic()))
    def system_windows():
        result = subprocess.check_output([str(directory.parent/'system-windows')], text=True, timeout=10)
        return json.loads(result)
    report_root = Path.home()/'Library/Logs/DiagnosticReports'
    reports_before = {p.name for p in report_root.glob('Open*.ips')}
    dialogs = system_windows()
    if dialogs:
        write_json(directory/'screen-end.json', dict(safe=False, systemWindows=dialogs, reason='system dialog present; left untouched'))
        return 2
    command = json.loads(args.command)
    if not isinstance(command, list) or not all(isinstance(s, str) for s in command):
        raise RuntimeError('invalid internal screen command')
    job = None
    code = 1
    errors = []
    interrupted = None
    leaked_group = False
    native_roots = directory / 'native-roots'
    native_roots.mkdir(mode=0o700)
    ledger = directory / 'processes.jsonl'

    def cancel(signum, _):
        nonlocal interrupted
        interrupted = interrupted or signum
        if job and job.poll() is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(job.pid, signal.SIGTERM)

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, cancel)
    started = time.monotonic()
    try:
        with (directory / 'output.log').open('w') as output:
            job = subprocess.Popen(command, cwd=args.cwd or ROOT, stdout=output, stderr=subprocess.STDOUT,
                                   env=dict(os.environ, OPEN_VERIFY_EXTERNAL_SCREEN_LOCK='1',
                                       OPEN_VERIFY_GATE_SCREEN_ROOT=str(native_roots),
                                       OPEN_VERIFY_PROCESS_LEDGER=str(ledger)), start_new_session=True)
            deadline = time.monotonic() + args.timeout
            while job.poll() is None:
                if interrupted or time.monotonic() >= deadline:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(job.pid, signal.SIGTERM)
                    try:
                        job.wait(30)
                    except subprocess.TimeoutExpired:
                        os.killpg(job.pid, signal.SIGKILL); job.wait()
                    break
                try:
                    job.wait(.25)
                except subprocess.TimeoutExpired:
                    pass
        code = job.returncode
        if interrupted:
            code = 128 + interrupted
        elif time.monotonic() >= deadline:
            code = 124
    except Exception as error:
        errors.append(str(error))
    finally:
        if job and job.poll() is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(job.pid, signal.SIGTERM)
            try:
                job.wait(30)
            except subprocess.TimeoutExpired:
                os.killpg(job.pid, signal.SIGKILL); job.wait()
        if job:
            # A direct child can exit before its nested native worker finishes
            # cleanup. Retain the pathname lock until that process group is gone.
            deadline = time.monotonic() + 30
            def members():
                text = subprocess.check_output(['ps', '-axo', 'pgid=,stat='], text=True)
                return any(fields[0] == str(job.pid) and not fields[1].startswith('Z')
                           for line in text.splitlines() if len(fields := line.split()) == 2)
            while members() and time.monotonic() < deadline:
                time.sleep(.1)
            leaked_group = members()
            if leaked_group:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(job.pid, signal.SIGKILL)
        try:
            cleanup_owned(ledger, native_roots)
        except Exception as error:
            errors.append('owned cleanup: ' + str(error))
        try:
            dialogs = system_windows()
        except Exception as error:
            dialogs = []
            errors.append('system window postflight: ' + str(error))
        crashes = sorted({p.name for p in report_root.glob('Open*.ips')}-reports_before)
        safe = not dialogs and not crashes and not leaked_group and not errors
        write_json(directory / 'screen-end.json', dict(ended=time.time(), seconds=time.monotonic() - started,
                                                     interrupted=interrupted, safe=safe, systemWindows=dialogs,
                                                     newCrashes=crashes, errors=errors, leakedGroup=leaked_group))
        if not safe:
            code = code or 2
    return code


def use_m1_receipt(directory, row_name, identity, config, style, lane):
    if directory is None:
        return None
    paths = list(directory.glob('*/gate.json')) + ([directory/'gate.json'] if (directory/'gate.json').is_file() else [])
    if len(paths) > 256:
        raise ValueError('too many M1 receipts')
    matches = []
    for path in paths:
        receipt = read_json(path)
        if (receipt.get('machine') == 'M1' and receipt.get('source') == identity
                and receipt.get('config') == config
                and receipt.get('lane') == lane):
            stages = [stage for stage in receipt.get('stages', []) if stage.get('name') == row_name]
            if (len(stages) != 1 or stages[0].get('exit') != 0
                    or stages[0].get('style') != style):
                continue
            stage = stages[0]
            checks = stage.get('rows')
            if (not isinstance(checks, list) or not checks or len(checks) > 4096
                    or any(row not in receipt.get('rows', []) or row.get('status') not in ('PASS', 'BLOCKED', 'DEFERRED') for row in checks)):
                continue
            matches.append(dict(stage, evidence=str(path), machine='M1'))
    if len(matches) > 1:
        raise ValueError('ambiguous M1 receipts for '+row_name)
    return matches[0] if matches else None


def collect_e2e(directory, suite, source, config, style, lane):
    identity = {key: source[key] for key in ('head', 'clean', 'diffSHA256')}
    # The real harness hashes its specific source paths. A committed clean
    # checkout must have the SHA-256 of empty bytes in both fingerprints.
    identity['diffSHA256'] = hashlib.sha256(b'').hexdigest()
    return e2e_rows(directory, suite, identity, source['engineSHA256'], config, style, lane)


class GeneratedOutputs:
    """Restore only outputs that the real harness owns; never discard code."""
    prefixes = ('docs/engine-spike/', 'docs/profiles-shell/')

    def __enter__(self):
        dirty = subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no', '--',
                                         *self.prefixes], cwd=ROOT, text=True)
        if dirty:
            raise RuntimeError('generated evidence already has edits; preserve them before running the gate')
        return self

    def __exit__(self, *error):
        changed = subprocess.check_output(['git', 'diff', '--name-only', '--', *self.prefixes],
                                          cwd=ROOT, text=True).splitlines()
        archive = self.directory / 'generated'
        for name in changed:
            path = ROOT / name
            if path.is_file():
                dest = archive / name; dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, dest)
        if changed:
            subprocess.run(['git', 'restore', '--', *changed], cwd=ROOT, check=True)


def command_run(command, log, interrupt=None):
    """Foreground wait; a screen lock parent outlives its worker's cleanup."""
    global CANCELLED
    if CANCELLED:
        raise KeyboardInterrupt('gate cancelled before starting another worker')
    with log.open('w') as output:
        child = subprocess.Popen(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                 start_new_session=True)
        while child.poll() is None:
            if CANCELLED:
                if interrupt:
                    interrupt(child)
                else:
                    child.send_signal(signal.SIGTERM)
                child.wait()
                raise KeyboardInterrupt('gate cancelled after owned cleanup')
            try:
                child.wait(.25)
            except subprocess.TimeoutExpired:
                pass
    return child.returncode


def screen_stage(name, command, logs, timeout, expected, cwd=None):
    directory = logs / name; directory.mkdir()
    queued = time.time()
    def cancel(lock):
        receipt = directory / 'screen-start.json'
        if receipt.is_file():
            pid = read_json(receipt)['pid']
            # This worker remains under our live lockf parent until cleanup.
            if any(parent == lock.pid for parent, _ in ancestors_of(pid)):
                with contextlib.suppress(ProcessLookupError):
                    os.kill(pid, signal.SIGTERM)
                return
        lock.terminate()  # Still queued: no App has started.
    args = [sys.executable, str(Path(__file__).resolve()), '--screen-worker', '--log', str(directory),
            '--command', json.dumps(command), '--timeout', str(timeout), '--expected', json.dumps(expected)]
    if cwd is not None:
        args += ['--cwd', str(cwd)]
    status = command_run(['/usr/bin/lockf', '-k', '/tmp/open-onscreen-e2e.lock', *args],
                         directory / 'lock.log', cancel)
    return status, directory, queued


def ancestors_of(pid):
    for _ in range(64):
        result = subprocess.run(['ps', '-p', str(pid), '-o', 'ppid=,args='], capture_output=True, text=True)
        fields = result.stdout.strip().split(None, 1)
        if len(fields) != 2 or int(fields[0]) <= 1:
            return
        pid = int(fields[0]); yield pid, fields[1]


def native_command(name, directory):
    scratch = directory / 'scratch'; scratch.mkdir(); seed = scratch / 'seed'; seed.mkdir()
    return [sys.executable, str(ROOT / 'tools/verification/check.py'), name, str(ROOT), str(seed)]


CANCELLED = None


def main():
    global CANCELLED
    if '--heavy-worker' in sys.argv:
        parser = argparse.ArgumentParser()
        parser.add_argument('--heavy-worker', action='store_true')
        parser.add_argument('--selection', required=True)
        parser.add_argument('--log', required=True)
        parser.add_argument('--app-config')
        parser.add_argument('--arc', action='store_true')
        return run_heavy(parser.parse_args())
    if '--screen-worker' in sys.argv:
        parser = argparse.ArgumentParser()
        parser.add_argument('--screen-worker', action='store_true')
        parser.add_argument('--log', required=True)
        parser.add_argument('--command', required=True)
        parser.add_argument('--timeout', type=int, required=True)
        parser.add_argument('--expected', required=True)
        parser.add_argument('--cwd')
        args = parser.parse_args()
        if fingerprint() != json.loads(args.expected):
            raise RuntimeError('source/engine changed while waiting for the screen lock; rebuild required')
        return run_screen(args)
    if '--require-heavy' in sys.argv:
        return 0 if inside_heavy() else 2
    if not inside_heavy():
        raise RuntimeError('run ~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh; the caller must hold the machine build slot')
    names = suite_names()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--only', help='comma-separated CLI/native names or e2e-NAME; e2e selects every default suite')
    parser.add_argument('--quick', action='store_true')
    parser.add_argument('--no-e2e', action='store_true', help='intermediate checks only; not a PR-ready receipt')
    parser.add_argument('--with-arc-data', action='store_true')
    parser.add_argument('--keep-logs', action='store_true')
    parser.add_argument('--lane', choices=('merge', 'observers'), default='merge')
    parser.add_argument('--config', choices=('Debug', 'Release'), default='Release')
    parser.add_argument('--m1-receipts', type=Path, help='exact-head gate receipts produced on M1')
    parser.add_argument('--log-dir', type=Path)
    options = parser.parse_args()
    if not options.only and not options.quick and not options.no_e2e:
        partial = [key for key, value in os.environ.items() if value and key.startswith('OPEN_')
                   and (key.endswith(('_ONLY', '_CASE', '_ROWS')) or key == 'OPEN_E2E_NO_CRASH_PROBES')]
        if partial:
            parser.error('full gate refuses partial-suite environment: '+', '.join(sorted(partial)))
    default_e2e = [name for name in names if name != 'passwords-probe'] + ['ntp-alloy']
    all_names = ['build', *CLI, *NATIVE, *M1_NATIVE, *('e2e-' + s for s in names), 'e2e-ntp-alloy']
    if options.quick and options.lane != 'merge':
        parser.error('--quick applies to the merge lane')
    selected = ['commands-demo', 'suggest-check', 'commands-dump'] if options.quick else [*CLI, *NATIVE]
    if not options.no_e2e and not options.quick:
        selected += ['e2e-' + s for s in default_e2e]
    if options.lane == 'observers':
        selected = ['features-idle', *('e2e-' + s for s in sorted(OBSERVER_SUITES))]
    if options.only:
        requested = options.only.split(',')
        expanded = [name for item in requested for name in
                    (['e2e-' + s for s in default_e2e] if item == 'e2e' else [item])]
        if not expanded or len(set(expanded)) != len(expanded) or any(name not in all_names for name in expanded):
            parser.error('unknown, empty or duplicate --only selection')
        selected = [name for name in all_names if name in expanded]
    if options.no_e2e and any(n.startswith('e2e-') for n in selected):
        parser.error('--no-e2e conflicts with an e2e selection')
    if 'import-arc' in selected and not options.with_arc_data:
        if options.only:
            parser.error('--only import-arc requires --with-arc-data')
        selected.remove('import-arc')
    if options.lane == 'observers' and any(n not in ['features-idle', *('e2e-'+s for s in OBSERVER_SUITES)] for n in selected):
        parser.error('selected row has no observer stage')
    if options.lane == 'observers' and machine() != 'M1':
        parser.error('observer lane requires the M1; no injected launch is allowed here')
    # The outer FIFO build slot serializes this checkout as well as other
    # checkouts on the machine. No private second build lock is needed.
    source = fingerprint()
    if not source['clean']:
        raise RuntimeError('commit source changes before qualifying a merge gate')
    exception_file = ROOT / 'tools/verification/gate-exceptions.json'
    entries = read_bounded(exception_file); assert_shrink_only(ROOT, entries)
    directory = options.log_dir or Path(os.environ.get('VERIFY_LOG_DIR') or tempfile.mkdtemp(prefix='open-gate-'))
    if options.log_dir or os.environ.get('VERIFY_LOG_DIR'):
        directory.mkdir(parents=True, exist_ok=False)
    directory = directory.resolve()
    rows = []; stages = []; start = time.time()
    receipt = dict(schema=1, machine=machine(), source=source, config=options.config,
                   style='chrome', lane=options.lane, selected=selected,
                   prReady=not options.only and not options.quick and not options.no_e2e and options.lane=='merge',
                   started=start, rows=rows, stages=stages)
    def cancelled(signum, _):
        global CANCELLED
        CANCELLED = CANCELLED or signum
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, cancelled)
    native = [n for n in selected if n in (*NATIVE, *M1_NATIVE)]
    screen_safe = True
    def can_continue(out):
        end = out/'screen-end.json'
        return end.is_file() and read_json(end).get('safe') is True
    e2e = [n[4:] for n in selected if n.startswith('e2e-')]
    def required_elsewhere(name):
        return ((machine() == 'M5' and (name in M1_E2E or name not in SAFE_M5))
                or (machine() == 'M1' and name in M5_E2E))
    local_e2e = [n for n in e2e if not required_elsewhere(n)]
    heavy = Path.home() / 'Library/Caches/OpenRE/scripts/heavy.sh'
    command = [str(heavy), sys.executable, str(Path(__file__).resolve()), '--heavy-worker',
               '--selection', ','.join(n for n in selected if n in CLI) or 'build', '--log', str(directory)]
    if local_e2e:
        command += ['--app-config', options.config]
    if options.with_arc_data:
        command.append('--arc')
    # The installed FIFO heavy.sh owns quiet-lock arbitration. Nested
    # build workers keep the caller's single slot throughout the full gate.
    rc = command_run(command, directory / 'heavy.log')
    cli = cli_rows(directory / 'cli/results.tsv')
    for row in cli:
        evidence = directory/'cli'/(row['name']+'.log')
        reason = evidence.read_text().strip() if row['result']=='SKIP' else ''
        rows.append(dict(row='cli/'+row['name'], status=row['result'], reason=reason, evidence=str(evidence)))
    guard_ok = ((directory/'screen-guard-build.json').is_file()
                and read_json(directory/'screen-guard-build.json')['result']=='PASS')
    rows.append(dict(row='build/screen-guard', status='PASS' if guard_ok else 'FAIL',
                     reason='' if guard_ok else 'CoreGraphics preflight helper build failed',
                     evidence=str(directory/'screen-guard-build.log')))
    if not cli or cli[0]['result'] != 'PASS' or not guard_ok:
        rows.append(dict(row='build/worker',status='FAIL',reason='heavy build worker failed',evidence=str(directory/'heavy.log')))
    else:
        if (directory/'app-build.json').is_file():
            app = read_json(directory/'app-build.json')
            rows.append(dict(row='build/app',status=app['result'],reason='',evidence=str(directory/'app-build.log')))
        # The outer heavy.sh still owns the one build slot. Each screen
        # worker acquires and releases the screen lock before the next suite.
        for name in native:
            if not screen_safe:
                rows.append(dict(row='native/'+name,status='NOT_RUN',reason='screen safety guard stopped the gate',evidence=''))
                continue
            scratch = directory / ('input-'+name); scratch.mkdir()
            if name == 'features-idle':
                command = [sys.executable, str(ROOT/'tools/verification/features-idle.py')]
            else:
                command = native_command(name, scratch)
            rc, out, queued = screen_stage(name, command, directory, 600, source, scratch)
            screen_safe = can_continue(out)
            rows.append(dict(row='native/'+name,status='PASS' if rc==0 else 'INTERRUPTED' if rc==2 else 'FAIL',reason='' if rc==0 else 'native worker exit '+str(rc),evidence=str(out/'output.log')))
            stages.append(dict(name=name,exit=rc,queued=queued,evidence=str(out)))
        app_ok = not local_e2e or ((directory/'app-build.json').is_file() and read_json(directory/'app-build.json')['result']=='PASS')
        for name in e2e:
            label = 'e2e-'+name
            if required_elsewhere(name):
                if machine() == 'M1':
                    rows.append(dict(row=label+'/receipt',status='M5_REQUIRED',
                                     reason='M1 forbids external AppleScript over SSH',evidence=''))
                    continue
                imported = use_m1_receipt(options.m1_receipts, label, source, options.config,
                                          'alloy' if name == 'ntp-alloy' else 'chrome', options.lane)
                if imported is None:
                    rows.append(dict(row=label+'/receipt',status='M1_REQUIRED',reason='exact-head M1 receipt required',evidence=''))
                else:
                    rows.extend(imported['rows']); stages.append(dict(imported, name=label))
                continue
            if not screen_safe:
                rows.append(dict(row=label+'/screen',status='NOT_RUN',reason='screen safety guard stopped the gate',evidence=''))
                continue
            if not app_ok:
                rows.append(dict(row=label+'/build',status='NOT_RUN',reason='App build failed',evidence=''))
                continue
            suite = 'ntp' if name=='ntp-alloy' else name
            style = 'alloy' if name=='ntp-alloy' else 'chrome'
            inputs = directory/('input-'+label); inputs.mkdir()
            if suite == 'owner-watch':
                command = [sys.executable,str(ROOT/'tools/e2e/owner_watch_e2e.py'),str(inputs/'results'),'--config',options.config]
            else:
                command = [sys.executable,str(ROOT/'tools/e2e/engine_e2e.py'),'--only',suite,'--style',style,
                           '--config',options.config,'--engine-sha256',source['engineSHA256'], '--focus-attempts','1',
                           '--lane',options.lane, '--output-dir', str(inputs), '--stop-on-app-death',
                           '--continue-on-timing-failure', '--suite-timeout', '3600']
                if suite=='passwords-probe':
                    command.append('--passwords-probe-dialog-free')
            generated = GeneratedOutputs(); generated.directory = inputs
            try:
                with generated:
                    rc, out, queued = screen_stage(label,command,directory,3600,source)
                screen_safe = can_continue(out)
                if suite=='owner-watch':
                    values = read_json(inputs/'results/results.json')
                    if len(values)!=4 or not all(v.get('ok') is True for v in values):
                        raise RuntimeError('owner-watch receipt is incomplete or failed')
                    checks=[dict(row='owner-watch/owned_cleanup',status='PASS',reason='',evidence=str(inputs/'results/results.json'))]
                else:
                    checks = collect_e2e(inputs,suite,source,options.config,style,options.lane)
                    if name=='ntp-alloy':
                        for check in checks: check['row']=check['row'].replace('ntp/','ntp-alloy/',1)
                if rc and not any(r['status']=='FAIL' for r in checks):
                    checks.append(dict(row=label+'/exit',status='FAIL',reason='suite exit '+str(rc),evidence=str(out/'output.log')))
                rows.extend(checks)
                stages.append(dict(name=label,style=style,rows=checks,exit=rc,queued=queued,evidence=str(out)))
            except Exception as error:
                rows.append(dict(row=label+'/evidence',status='FAIL',reason=str(error),evidence=str(inputs)))
                screen_safe = False
    if fingerprint() != source:
        rows.append(dict(row='gate/source',status='FAIL',reason='source or engine changed during the gate',evidence=''))
    if rc and not any(row['status'] in ('FAIL', 'INTERRUPTED') for row in rows):
        rows.append(dict(row='gate/worker-exit', status='FAIL', reason='worker exit ' + str(rc), evidence=str(directory)))
    failed, inventory = evaluate(entries, rows, ready=True)
    receipt.update(ended=time.time(), exceptions=inventory, ok=not failed)
    write_json(directory/'gate.json',receipt)
    lines=['| Row | Status | Policy | Reason |','|---|---|---|---|']
    lines += ['| '+r['row']+' | '+r['status']+' | '+r['policy']+' | '+r.get('reason','').replace('|','/')+' |' for r in rows]
    lines += ['', '| Exception | Verdict | Clears when |', '|---|---|---|']
    lines += ['| '+r['row']+' | '+r['verdict']+' | '+r['clearsWhen']+' |' for r in inventory]
    lines += ['', 'Logs: '+str(directory), 'Gate: '+('FAIL' if failed else 'PASS')]
    (directory/'summary.md').write_text('\n'.join(lines)+'\n')
    print('\n'.join(lines))
    return 1 if failed else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('INTERRUPTED: owned worker cleanup finished', file=sys.stderr)
        sys.exit(130)
    except Exception as error:
        print('FAIL:', error, file=sys.stderr)
        sys.exit(2)
