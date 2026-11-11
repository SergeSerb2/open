#!/usr/bin/env python3
"""Merge gate inside one FIFO build slot, with one screen lock per suite."""
import argparse
import ast
import contextlib
import functools
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
from intentional_crash import expected_reports, read_markers
from timing_sample import preflight as timing_preflight, finish as timing_finish
from launch_sample import continuation as launch_continuation

ROOT = Path(__file__).resolve().parents[2]  # final location tools/verification/gate.py
NATIVE = ('space-editor', 'settings-preview', 'features-render', 'sitecontrol-render')
M1_NATIVE = {'features-idle'}
TIMING_SUITES = {'window', 'import-robust', 'welcome', 'find', 'commandbar', 'app-actions', 'sitecontrol', 'split', 'media', 'measure', 'sleep'}
# Transitive observer/fault-probe flows, not only direct suite implementations.
M1_E2E = {'ntp', 'ntp-alloy', 'features', 'profiles', 'profiles-engine', 'passwords',
          'passwords-probe', 'secrets-import', 'owner-watch', 'actions', 'incognito'}
E2E_DEPENDENCIES = {'sidebar': ('profiles',)}
OBSERVER_SUITES = {'sitecontrol', 'find', 'split', 'littleopen', 'downloads'}
M5_E2E = {'applescript'}  # No external AppleScript/osascript over SSH on the M1.
# Rented Macs (NS-MACS.md) qualify functional merge/observers stages only for
# suites proven to run there (LEAD 16:50). Add a suite only with a passing rented
# receipt. Display-keyed visual stages (incognito) and timing rows stay M1-only.
RENTED_ALLOWED_E2E = {'owner-watch', 'shell'}
RENTED_LANES = ('merge', 'observers')
REFUSED = []  # Receipts found under --m1-receipts that were refused, with the reason.
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
    if not holder.is_file() or holder.stat().st_size > 64 * 1024:
        return False
    # Queue v3 records every holder on its own line. The fifth field (kind)
    # is optional so an already-running v2 holder remains recognizable.
    holders = set()
    for line in holder.read_text().splitlines():
        fields = line.split('\t')
        if len(fields) in (4, 5) and fields[0].isdigit():
            holders.add(int(fields[0]))
    return any(pid in holders for pid, _ in ancestors())


@functools.lru_cache(maxsize=1)
def machine_info():
    """Host metadata recorded in every receipt; rented Macs are identified from it."""
    def sysctl(name):
        return subprocess.run(['sysctl', '-n', name], capture_output=True, text=True).stdout.strip()
    def sw(flag):
        return subprocess.run(['sw_vers', flag], capture_output=True, text=True).stdout.strip()
    return dict(chip=sysctl('machdep.cpu.brand_string'), model=sysctl('hw.model'),
                virtual=sysctl('kern.hv_vmm_present') == '1', osVersion=sw('-productVersion'), osBuild=sw('-buildVersion'))


def is_rented(info):
    # A rented Namespace Mac: macOS 27 on a virtual Apple M5 Max (NS-MACS.md).
    return (info.get('virtual') is True and str(info.get('chip', '')).startswith('Apple M5')
            and str(info.get('model', '')).startswith('VirtualMac') and str(info.get('osVersion', '')).startswith('27.'))


def machine():
    info = dict(machine_info()); chip = info['chip']
    if is_rented(info):
        return 'rented'
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
    fault_ledger = directory / 'intentional-faults.jsonl'

    def cancel(signum, _):
        nonlocal interrupted
        interrupted = interrupted or signum
        if job and job.poll() is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(job.pid, signal.SIGTERM)

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, cancel)
    started = time.monotonic()
    timing = None
    try:
        if args.timing:
            timing = timing_preflight(require_quiet=args.timing == 'required', cancelled=lambda: interrupted is not None)
            write_json(directory/'timing-sample.json', timing)
            if args.timing == 'required' and not timing['validBefore']:
                raise RuntimeError('quiet timing preflight exhausted six minutes; no App launched')
        with (directory / 'output.log').open('w') as output:
            job = subprocess.Popen(command, cwd=args.cwd or ROOT, stdout=output, stderr=subprocess.STDOUT,
                                   env=dict(os.environ, OPEN_VERIFY_EXTERNAL_SCREEN_LOCK='1',
                                       OPEN_VERIFY_GATE_SCREEN_ROOT=str(native_roots),
                                       OPEN_VERIFY_PROCESS_LEDGER=str(ledger),
                                       OPEN_VERIFY_TIMING_REQUIRED='1' if args.timing == 'required' else '0',
                                       OPEN_VERIFY_INTENTIONAL_CRASH_LEDGER=str(fault_ledger)), start_new_session=True)
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
        if timing is not None:
            write_json(directory/'timing-sample.json', timing_finish(timing))
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
        try:
            expected = sorted(expected_reports(crashes, read_markers(fault_ledger), report_root))
        except Exception as error:
            expected = []
            errors.append('intentional fault attribution: ' + str(error))
        unexpected = sorted(set(crashes) - set(expected))
        safe = not dialogs and not unexpected and not leaked_group and not errors
        write_json(directory / 'screen-end.json', dict(ended=time.time(), seconds=time.monotonic() - started,
                                                     interrupted=interrupted, safe=safe, systemWindows=dialogs,
                                                     newCrashes=crashes, expectedCrashes=expected,
                                                     unexpectedCrashes=unexpected, errors=errors, leakedGroup=leaked_group))
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
        host = receipt.get('machine')
        if host == 'rented':
            stage_names = {stage.get('name') for stage in receipt.get('stages', [])}
            if row_name not in stage_names:
                continue
            if not is_rented(receipt.get('machineInfo') or {}):
                refuse(path, row_name, 'rented receipt lacks Namespace host metadata (virtual Apple M5, VirtualMac, macOS 27)')
                continue
            if receipt.get('lane') not in RENTED_LANES:
                refuse(path, row_name, 'rented receipts qualify only the merge and observers lanes')
                continue
            if row_name[4:] not in RENTED_ALLOWED_E2E:
                refuse(path, row_name, 'suite is not on the rented allowlist (owner-watch, shell); add it only with rented proof')
                continue
        elif host != 'M1':
            continue
        if (receipt.get('source') == identity
                and receipt.get('config') == config
                and receipt.get('lane') == lane and receipt.get('partialSelectors') == []):
            stages = [stage for stage in receipt.get('stages', []) if stage.get('name') == row_name]
            if (len(stages) != 1 or stages[0].get('exit') != 0
                    or stages[0].get('style') != style):
                continue
            stage = stages[0]
            checks = stage.get('rows')
            if host == 'rented':
                # Rented timing observations are never acceptance: drop them here;
                # the M5 merge run then requires the quiet M1 timing receipt.
                if not isinstance(checks, list):
                    continue
                timing = [row for row in checks if isinstance(row, dict) and row.get('timing') is True]
                if any(row.get('functionalOK') is not True or row not in receipt.get('rows', []) for row in timing):
                    continue
                if timing:
                    refuse(path, row_name, 'rented timing rows are INFO only; the quiet M1 timing receipt is still required: '
                           + ', '.join(row.get('row', '?') for row in timing[:8]))
                functional = [row for row in checks if row not in timing]
                if (not functional or any(row not in receipt.get('rows', [])
                        or row.get('status') not in ('PASS', 'BLOCKED', 'DEFERRED') for row in functional)):
                    continue
                rows = [dict(row, sourceMachine=host) for row in functional]
                # The M5 merge run renames these and requires the M1 timing row.
                rows += [dict(row, sourceMachine=host, status='INFO', observedStatus=row.get('status'),
                              reason='Rented timing observation; not acceptance') for row in timing]
                matches.append(dict(stage, rows=rows, evidence=str(path), machine=host))
                continue
            if (not isinstance(checks, list) or not checks or len(checks) > 4096
                    or any(row not in receipt.get('rows', []) or row.get('status') not in ('PASS', 'BLOCKED', 'DEFERRED') for row in checks)):
                continue
            matches.append(dict(stage, rows=[dict(row, sourceMachine=host) for row in checks],
                                evidence=str(path), machine=host))
    if len(matches) > 1:
        raise ValueError('ambiguous M1/rented receipts for '+row_name)
    return matches[0] if matches else None


def refuse(path, row_name, reason):
    entry = dict(receipt=str(path), row=row_name, reason=reason)
    if entry not in REFUSED:
        REFUSED.append(entry)


def collect_e2e(directory, suite, source, config, style, lane):
    identity = {key: source[key] for key in ('head', 'clean', 'diffSHA256')}
    # The real harness hashes its specific source paths. A committed clean
    # checkout must have the SHA-256 of empty bytes in both fingerprints.
    identity['diffSHA256'] = hashlib.sha256(b'').hexdigest()
    return e2e_rows(directory, suite, identity, source['engineSHA256'], config, style, lane)


def use_m1_timing(directory, row_name, identity, config):
    if directory is None:
        return None
    paths = list(directory.glob('*/gate.json')) + ([directory/'gate.json'] if (directory/'gate.json').is_file() else [])
    if len(paths) > 256:
        raise ValueError('too many timing receipts')
    matches = []
    for path in paths:
        receipt = read_json(path)
        if receipt.get('machine') == 'rented' and receipt.get('lane') == 'timing':
            refuse(path, row_name, 'rented timing receipt refused: timing rows need the quiet M1 lane')
            continue
        if (receipt.get('machine') != 'M1' or receipt.get('source') != identity
                or receipt.get('config') != config or receipt.get('lane') != 'timing'
                or receipt.get('partialSelectors') != []):
            continue
        for stage in receipt.get('stages', []):
            sample_path = path.parent/stage['name']/'timing-sample.json'
            if not sample_path.is_file() or read_json(sample_path).get('validBefore') is not True:
                continue
            for row in stage.get('rows', []):
                if (row.get('row') == row_name and row in receipt.get('rows', [])
                        and row.get('sampleValid') is True and row.get('functionalOK') is True
                        and (row.get('status') == 'PASS'
                             or (row.get('status') == 'DEFERRED' and row.get('policy') == 'EXCEPTION'))):
                    matches.append(dict(row, evidence=str(path)))
    if len(matches) > 1:
        raise ValueError('ambiguous M1 timing receipts for '+row_name)
    return matches[0] if matches else None


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


def process_table():
    """Live, non-zombie processes: pid -> (ppid, pgid, command)."""
    text = subprocess.run(['ps', '-axo', 'pid=,ppid=,pgid=,stat=,command='],
                          capture_output=True, text=True, check=True).stdout
    table = {}
    for line in text.splitlines():
        fields = line.split(None, 4)
        if len(fields) >= 4 and not fields[3].startswith('Z'):
            table[int(fields[0])] = (int(fields[1]), int(fields[2]), fields[4] if len(fields) == 5 else '')
    return table


def protected_pids():
    """The gate itself and its ancestors (FIFO heavy.sh, dispatcher) are never signalled."""
    return {os.getpid(), *(pid for pid, _ in ancestors())}


def track_tree(known, root=None):
    """Adds the live descendants of known (and root) and their process-group members.

    heavy.sh traps TERM without forwarding it, so its worker and compilers outlive it;
    swift-build starts compilers in their own process groups. A pid whose command
    changed is dropped, so a reused pid is never signalled. Never adds this gate,
    its ancestors or this gate's own process group.
    """
    table = process_table(); keep = protected_pids()
    for pid in list(known):
        if pid not in table or table[pid][2] != known[pid]:
            known.pop(pid)
    if root is not None and root in table and root not in keep:
        known[root] = table[root][2]
    groups = {table[pid][1] for pid in known} - {os.getpgid(0)}
    changed = True
    while changed:
        changed = False
        for pid, (ppid, pgid, command) in table.items():
            if pid not in known and pid not in keep and (ppid in known or pgid in groups):
                known[pid] = command; groups.add(pgid); groups.discard(os.getpgid(0)); changed = True
    STOPPED.update(known)  # Receipt: every process this cancellation owned.
    return known


def stop_tree(known, grace=10):
    """TERM every tracked process, wait up to grace seconds, then KILL; returns survivors."""
    for signum, wait in ((signal.SIGTERM, grace), (signal.SIGKILL, 5)):
        track_tree(known)
        for pid in list(known):
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.kill(pid, signum)
        end = time.monotonic() + wait
        while time.monotonic() < end:
            if not track_tree(known):
                return {}
            time.sleep(.2)
    return dict(track_tree(known))


def checkout_processes():
    """Processes whose command names a path in this checkout (verification only)."""
    prefix = str(ROOT) + '/'; keep = protected_pids()
    return {pid: command for pid, (_, _, command) in process_table().items()
            if pid not in keep and prefix in command}


GATE_DIRECTORY = None
STOPPED = {}


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
                known = track_tree({}, child.pid)
                if interrupt:
                    # The screen worker quits its App and writes screen-end first;
                    # keep tracking its tree so nothing it started is lost.
                    interrupt(child)
                    while child.poll() is None:
                        track_tree(known)
                        time.sleep(.25)
                survivors = stop_tree(known)
                child.wait()
                if survivors:
                    raise KeyboardInterrupt('owned processes survived KILL: ' + ', '.join(map(str, survivors)))
                raise KeyboardInterrupt('gate cancelled after owned cleanup')
            try:
                child.wait(.25)
            except subprocess.TimeoutExpired:
                pass
    return child.returncode


def screen_stage(name, command, logs, timeout, expected, cwd=None, timing=None):
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
    if timing:
        args += ['--timing', timing]
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
        parser.add_argument('--timing', choices=('required', 'informative'))
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
    parser.add_argument('--lane', choices=('merge', 'observers', 'timing'), default='merge')
    parser.add_argument('--config', choices=('Debug', 'Release'), default='Release')
    parser.add_argument('--m1-receipts', type=Path, help='exact-head gate receipts produced on M1')
    parser.add_argument('--launch-continuation', type=Path, help='LEAD 07:10: complete the original M1 five-pair receipt with one pair')
    parser.add_argument('--log-dir', type=Path)
    options = parser.parse_args()
    partial = [key for key, value in os.environ.items() if value and key.startswith('OPEN_')
               and (key.endswith(('_ONLY', '_CASE', '_ROWS', '_SCOPE', '_SOURCE_APP',
                                  '_APP_BUNDLE', '_NEGATIVE', '_NEGATIVE_APP'))
                    or key == 'OPEN_E2E_NO_CRASH_PROBES')]
    if not options.only and not options.quick and not options.no_e2e:
        if partial:
            parser.error('full gate refuses partial-suite environment: '+', '.join(sorted(partial)))
    default_e2e = [name for name in names if name != 'passwords-probe'] + ['ntp-alloy']
    all_names = ['build', *CLI, *NATIVE, *M1_NATIVE, *('e2e-' + s for s in names), 'e2e-ntp-alloy', 'timing-window']
    if options.quick and options.lane != 'merge':
        parser.error('--quick applies to the merge lane')
    selected = ['commands-demo', 'suggest-check', 'commands-dump'] if options.quick else [*CLI, *NATIVE]
    if not options.no_e2e and not options.quick:
        selected += ['e2e-' + s for s in default_e2e]
    if options.lane == 'observers':
        selected = ['features-idle', *('e2e-' + s for s in sorted(OBSERVER_SUITES))]
    if options.lane == 'timing':
        selected = ['timing-window', *('e2e-'+s for s in sorted(TIMING_SUITES-{'window'}))]
    if options.only:
        requested = options.only.split(',')
        expanded = [name for item in requested for name in
                    (['e2e-' + s for s in default_e2e] if item == 'e2e' else [item])]
        if not expanded or len(set(expanded)) != len(expanded) or any(name not in all_names for name in expanded):
            parser.error('unknown, empty or duplicate --only selection')
        selected = [name for name in all_names if name in expanded]
    if options.no_e2e and any(n.startswith('e2e-') for n in selected):
        parser.error('--no-e2e conflicts with an e2e selection')
    for suite, dependencies in E2E_DEPENDENCIES.items():
        if 'e2e-' + suite in selected:
            for dependency in dependencies:
                label = 'e2e-' + dependency
                if label not in selected:
                    selected.append(label)
    if 'import-arc' in selected and not options.with_arc_data:
        if options.only:
            parser.error('--only import-arc requires --with-arc-data')
        selected.remove('import-arc')
    if options.lane == 'observers' and any(n not in ['features-idle', *('e2e-'+s for s in OBSERVER_SUITES)] for n in selected):
        parser.error('selected row has no observer stage')
    if options.lane == 'observers' and machine() not in ('M1', 'rented'):
        parser.error('observer lane requires the M1 or a rented Mac; no injected launch is allowed here')
    if options.lane == 'timing':
        if machine() == 'rented':
            parser.error('timing lane refused on a rented Mac: timing rows need the quiet M1 (NS-MACS.md)')
        if machine() != 'M1' or options.config != 'Release':
            parser.error('timing lane requires M1 Release')
        # Queue v3 labels a one-slot M1 holder "build" even when it requested
        # all slots. Ownership is checked above; require the explicit request.
        if os.environ.get('OPEN_HEAVY_EXCLUSIVE') != '1':
            parser.error('timing lane requires OPEN_HEAVY_EXCLUSIVE=1 heavy.sh')
        if any(n != 'timing-window' and n not in ['e2e-'+s for s in TIMING_SUITES] for n in selected):
            parser.error('selected row has no timing lane')
    if 'timing-window' in selected and options.lane != 'timing':
        parser.error('timing-window requires --lane timing')
    # The caller keeps one FIFO build slot throughout the gate.
    # Exclusive timing reruns use every machine slot; there is no private lock.
    source = fingerprint()
    if not source['clean']:
        raise RuntimeError('commit source changes before qualifying a merge gate')
    reused_launch = None
    if options.launch_continuation:
        if options.lane != 'timing' or selected != ['timing-window']:
            parser.error('--launch-continuation requires --lane timing --only timing-window')
        reused_launch = launch_continuation(options.launch_continuation, ROOT, source['engineSHA256'])
    exception_file = ROOT / 'tools/verification/gate-exceptions.json'
    entries = read_bounded(exception_file); assert_shrink_only(ROOT, entries)
    directory = options.log_dir or Path(os.environ.get('VERIFY_LOG_DIR') or tempfile.mkdtemp(prefix='open-gate-'))
    if options.log_dir or os.environ.get('VERIFY_LOG_DIR'):
        directory.mkdir(parents=True, exist_ok=False)
    directory = directory.resolve()
    global GATE_DIRECTORY
    GATE_DIRECTORY = directory
    rows = []; stages = []; start = time.time()
    receipt = dict(schema=1, machine=machine(), machineInfo=machine_info(), refusedReceipts=REFUSED,
                   source=source, config=options.config,
                   style='chrome', lane=options.lane, selected=selected, partialSelectors=sorted(partial),
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
    e2e = [n[4:] for n in selected if n.startswith('e2e-')] + (['window'] if 'timing-window' in selected else [])
    def required_elsewhere(name):
        return ((machine() == 'M5' and (name in M1_E2E or name not in SAFE_M5))
                or (machine() == 'M1' and name in M5_E2E)
                or (machine() == 'rented' and name in M5_E2E))
    local_e2e = [n for n in e2e if not required_elsewhere(n)]
    heavy = Path.home() / 'Library/Caches/OpenRE/scripts/heavy.sh'
    command = [str(heavy), sys.executable, str(Path(__file__).resolve()), '--heavy-worker',
               '--selection', ','.join(n for n in selected if n in CLI) or 'build', '--log', str(directory)]
    if local_e2e and not reused_launch:
        command += ['--app-config', options.config]
    if options.with_arc_data:
        command.append('--arc')
    # Nested build workers keep the caller's normal slot throughout the gate.
    # The installed FIFO heavy.sh handles exclusive measurement jobs.
    rc = command_run(command, directory / 'heavy.log')
    if reused_launch:
        write_json(directory/'app-build.json', dict(name='app-build', result='PASS', seconds=0, exit=0,
                   reusedUnchangedApp=reused_launch['prior']))
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
        # The outer heavy.sh still owns its build slot. Each screen
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
            launch_only = name == 'window' and 'timing-window' in selected
            label = 'timing-window' if launch_only else 'e2e-'+name
            if required_elsewhere(name):
                if machine() in ('M1', 'rented') and name in M5_E2E:
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
                           '--lane','merge' if options.lane == 'timing' else options.lane, '--output-dir', str(inputs), '--stop-on-app-death',
                           '--continue-on-timing-failure', '--suite-timeout', '3600']
                if suite=='passwords-probe':
                    command.append('--passwords-probe-dialog-free')
                if launch_only:
                    command.append('--window-launch-only')
                    if options.launch_continuation:
                        command += ['--window-launch-continuation', str(options.launch_continuation.resolve())]
            generated = GeneratedOutputs(); generated.directory = inputs
            try:
                with generated:
                    rc, out, queued = screen_stage(label,command,directory,3600,source,
                        timing=('required' if options.lane == 'timing' else 'informative') if suite in TIMING_SUITES else None)
                screen_safe = can_continue(out)
                if suite=='owner-watch':
                    values = read_json(inputs/'results/results.json')
                    if len(values)!=4 or not all(v.get('ok') is True for v in values):
                        raise RuntimeError('owner-watch receipt is incomplete or failed')
                    checks=[dict(row='owner-watch/owned_cleanup',status='PASS',reason='',evidence=str(inputs/'results/results.json'))]
                else:
                    checks = collect_e2e(inputs,suite,source,options.config,style,
                                         'merge' if options.lane == 'timing' else options.lane)
                    sample_path = out/'timing-sample.json'
                    sample = read_json(sample_path) if sample_path.is_file() else None
                    for check in checks:
                        if check.get('timing') is not True:
                            continue
                        check['timingSample'] = str(sample_path)
                        check['sampleValid'] = bool(sample and sample.get('validBefore') is True
                                                    and check.get('sampleValid', True) is True)
                        if not check['sampleValid']:
                            check['observedStatus'] = check['status']
                            if check.get('functionalOK') is True:
                                check['status'] = 'INFO' if machine() in ('M5', 'rented') else 'INVALID_SAMPLE'
                                check['reason'] = 'Timing sample did not meet LEAD 06:30 quiet rule; raw assertion retained'
                    if name=='ntp-alloy':
                        for check in checks: check['row']=check['row'].replace('ntp/','ntp-alloy/',1)
                if rc and not any(r['status']=='FAIL' or r.get('observedStatus') == 'FAIL' for r in checks):
                    checks.append(dict(row=label+'/exit',status='FAIL',reason='suite exit '+str(rc),evidence=str(out/'output.log')))
                rows.extend(checks)
                stages.append(dict(name=label,style=style,rows=checks,exit=rc,queued=queued,evidence=str(out)))
            except Exception as error:
                rows.append(dict(row=label+'/evidence',status='FAIL',reason=str(error),evidence=str(inputs)))
                screen_safe = False
    # A coverage note is not a passing assertion. Resolve it only against an
    # actual passing row from the same source/configuration's required suite.
    by_row = {row['row']: row for row in rows}
    for row in rows:
        if row['status'] != 'COVERAGE_REQUIRED':
            continue
        target = by_row.get(row['coveredBy'])
        row['status'] = 'PASS' if target and target['status'] == 'PASS' else 'NOT_RUN'
        row['reason'] = ('Real acceptance row: ' if row['status'] == 'PASS'
                         else 'Missing or failed acceptance row: ') + row['coveredBy']
        if target:
            row['evidence'] = target['evidence']
    if fingerprint() != source:
        rows.append(dict(row='gate/source',status='FAIL',reason='source or engine changed during the gate',evidence=''))
    if machine() == 'M5' and options.lane == 'merge':
        for row in list(rows):
            if row.get('timing') is not True:
                continue
            name = row['row']
            imported = use_m1_timing(options.m1_receipts, name, source, options.config)
            # Keep the M5 observation separate from the authoritative quiet-M1
            # row. A valid M5 miss still fails; an invalid one remains INFO.
            row['row'] = ('rented/' if row.get('sourceMachine') == 'rented' else 'm5/')+name
            rows.append(imported if imported else dict(row=name, status='M1_REQUIRED',
                        reason='Quiet M1 timing lane required (LEAD 06:30)', evidence=''))
    if rc and not any(row['status'] in ('FAIL', 'INTERRUPTED') or row.get('observedStatus') == 'FAIL' for row in rows):
        rows.append(dict(row='gate/worker-exit', status='FAIL', reason='worker exit ' + str(rc), evidence=str(directory)))
    failed, inventory = evaluate(entries, rows, ready=True)
    receipt.update(ended=time.time(), exceptions=inventory, ok=not failed)
    write_json(directory/'gate.json',receipt)
    lines=['| Row | Status | Observed | Policy | Reason |','|---|---|---|---|---|']
    lines += ['| '+r['row']+' | '+r['status']+' | '+r.get('observedStatus', r['status'])+' | '+r['policy']+' | '+r.get('reason','').replace('|','/')+' |' for r in rows]
    if REFUSED:
        lines += ['', '| Refused receipt | Row | Reason |', '|---|---|---|']
        lines += ['| '+r['receipt']+' | '+r['row']+' | '+r['reason'].replace('|','/')+' |' for r in REFUSED]
    lines += ['', '| Exception | Verdict | Clears when |', '|---|---|---|']
    lines += ['| '+r['row']+' | '+r['verdict']+' | '+r['clearsWhen']+' |' for r in inventory]
    lines += ['', 'Logs: '+str(directory), 'Gate: '+('FAIL' if failed else 'PASS')]
    (directory/'summary.md').write_text('\n'.join(lines)+'\n')
    print('\n'.join(lines))
    return 1 if failed else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt as stop:
        # Claim cleanup only after no process from this checkout remains.
        deadline = time.monotonic() + 10
        while (left := checkout_processes()) and time.monotonic() < deadline:
            time.sleep(.2)
        if GATE_DIRECTORY is not None:
            with contextlib.suppress(Exception):
                write_json(GATE_DIRECTORY / 'interrupted.json', dict(
                    status='INTERRUPTED', signal=CANCELLED, ended=time.time(), reason=str(stop),
                    stopped=[dict(pid=pid, command=command[:300]) for pid, command in sorted(STOPPED.items())],
                    remaining=[dict(pid=pid, command=command[:300]) for pid, command in sorted(left.items())],
                    cleanupOk=not left))
        if left:
            print('INTERRUPTED: cleanup INCOMPLETE; processes from this checkout remain: '
                  + ', '.join(str(pid) for pid in sorted(left)), file=sys.stderr)
            sys.exit(2)
        print('INTERRUPTED: owned worker cleanup finished; no process from this checkout remains', file=sys.stderr)
        sys.exit(130)
    except Exception as error:
        print('FAIL:', error, file=sys.stderr)
        sys.exit(2)
