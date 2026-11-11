#!/usr/bin/env python3
"""M5 gate dispatcher: each stage gets a fresh FIFO ticket, never an outer slot."""
import argparse
import copy
import contextlib
import json
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/verification'))
GATE = runpy.run_path(str(ROOT / 'tools/verification/gate.py'))
CANCELLED = None


def plan():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--only')
    parser.add_argument('--quick', action='store_true')
    parser.add_argument('--no-e2e', action='store_true')
    parser.add_argument('--with-arc-data', action='store_true')
    parser.add_argument('--keep-logs', action='store_true')
    parser.add_argument('--lane', choices=('merge', 'observers', 'timing'), default='merge')
    parser.add_argument('--config', choices=('Debug', 'Release'), default='Release')
    parser.add_argument('--m1-receipts', type=Path)
    parser.add_argument('--launch-continuation', type=Path)
    parser.add_argument('--log-dir', type=Path)
    options = parser.parse_args()
    if GATE['machine']() != 'M5' or options.lane != 'merge' or options.launch_continuation:
        parser.error('the queued M5 dispatcher supports the merge lane only')
    if GATE['inside_heavy']():
        parser.error('do not put the M5 dispatcher inside an outer heavy ticket; call heavy.sh tools/verify-all.sh directly')
    names = GATE['suite_names']()
    defaults = [name for name in names if name != 'passwords-probe'] + ['ntp-alloy']
    all_names = ['build', *GATE['CLI'], *GATE['NATIVE'], *GATE['M1_NATIVE'],
                 *('e2e-' + name for name in names), 'e2e-ntp-alloy', 'timing-window']
    selected = ['commands-demo', 'suggest-check', 'commands-dump'] if options.quick else [*GATE['CLI'], *GATE['NATIVE']]
    if not options.no_e2e and not options.quick:
        selected += ['e2e-' + name for name in defaults]
    if options.only:
        requested = [name for item in options.only.split(',') for name in
                     (['e2e-' + name for name in defaults] if item == 'e2e' else [item])]
        if (not requested or len(set(requested)) != len(requested)
                or any(name not in all_names for name in requested)):
            parser.error('unknown, empty or duplicate --only selection')
        selected = [name for name in all_names if name in requested]
    if options.no_e2e and any(name.startswith('e2e-') for name in selected):
        parser.error('--no-e2e conflicts with an e2e selection')
    if any(name in ('timing-window', *GATE['M1_NATIVE']) for name in selected):
        parser.error('selected stage requires an M1 lane')
    for suite, dependencies in GATE['E2E_DEPENDENCIES'].items():
        if 'e2e-' + suite in selected:
            for dependency in dependencies:
                if 'e2e-' + dependency not in selected:
                    selected.append('e2e-' + dependency)
    if 'import-arc' in selected and not options.with_arc_data:
        if options.only:
            parser.error('--only import-arc requires --with-arc-data')
        selected.remove('import-arc')
    partial = sorted(key for key, value in os.environ.items() if value and key.startswith('OPEN_')
                     and (key.endswith(('_ONLY', '_CASE', '_ROWS', '_SCOPE', '_SOURCE_APP',
                                        '_APP_BUNDLE', '_NEGATIVE', '_NEGATIVE_APP'))
                          or key == 'OPEN_E2E_NO_CRASH_PROBES'))
    if not options.only and not options.quick and not options.no_e2e and partial:
        parser.error('full gate refuses partial-suite environment: ' + ', '.join(partial))
    cli = [name for name in selected if name in GATE['CLI']]
    chunks = [cli] if cli else []
    chunks += [[name] for name in selected if name in GATE['NATIVE']]
    # Keep cross-suite acceptance dependencies in the same worker. Otherwise
    # its coverage note would fail, and the dependency would run twice.
    dependent = {'e2e-' + item for suite, items in GATE['E2E_DEPENDENCIES'].items()
                 if 'e2e-' + suite in selected for item in items}
    imports = [name for name in selected if name.startswith('e2e-') and name not in dependent and
               (name[4:] in GATE['M1_E2E'] or name[4:] not in GATE['SAFE_M5'])]
    if imports:
        chunks.append(imports)
    chunks += [[name, *('e2e-' + item for item in GATE['E2E_DEPENDENCIES'].get(name[4:], ()))]
               for name in selected if name.startswith('e2e-') and name not in imports
               and name not in dependent and name != 'e2e-window']
    if 'e2e-window' in selected:
        chunks.append(['e2e-window'])
    return options, selected, partial, chunks or [['build']]


def holder(pid):
    path = Path('/tmp/open-heavy-holder')
    try:
        if path.stat().st_size > 64 * 1024:
            return False
        lines = path.read_text().splitlines()
    except FileNotFoundError:
        return False
    return any(line.split('\t', 1)[0] == str(pid) for line in lines)


def waiters(pid):
    for path in Path('/tmp/open-heavy-queue').glob('*'):
        try:
            if path.stat().st_size > 64 * 1024:
                continue
            fields = path.read_text().split('\t', 1)
            if fields[0].isdigit() and int(fields[0]) != pid:
                try:
                    os.kill(int(fields[0]), 0)
                    return True
                except ProcessLookupError:
                    pass
        except FileNotFoundError:
            pass  # A queued ticket can acquire and disappear between reads.
    return False


def stop_worker(job):
    """Signal the owned coordinator; its screen worker retains the cleanup lock."""
    table = {}
    for line in subprocess.check_output(['ps', '-ww', '-axo', 'pid=,ppid=,args='], text=True).splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3:
            table[int(fields[0])] = (int(fields[1]), fields[2])
    def descendant(pid):
        for _ in range(64):
            if pid == job.pid:
                return True
            if pid not in table or pid <= 1:
                return False
            pid = table[pid][0]
        return False
    coordinators = [pid for pid, (_, command) in table.items()
                    if str(ROOT/'tools/verification/gate.py') in command
                    and '--heavy-worker' not in command and '--screen-worker' not in command
                    and descendant(pid)]
    if len(coordinators) == 1:
        # Compiler children belong to the heavy-worker session. Stop that
        # complete owned group before asking the coordinator to reap it.
        for pid, (_, command) in table.items():
            if str(ROOT/'tools/verification/gate.py') in command and '--heavy-worker' in command and descendant(pid):
                try:
                    if os.getpgid(pid) == pid:
                        os.killpg(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        try:
            os.kill(coordinators[0], signal.SIGTERM)
        except ProcessLookupError:
            pass
        return True
    elif not holder(job.pid):
        # Still queued: no compiler or screen worker has started. A racing
        # coordinator must pass inside_heavy again before its build worker.
        job.terminate()
        return True
    # Acquisition can race a cancellation. Retry until the owned coordinator
    # is visible; never treat a missed signal as successful cancellation.
    return False


def main():
    global CANCELLED
    options, selected, partial, chunks = plan()
    directory = options.log_dir or Path(os.environ.get('VERIFY_LOG_DIR') or tempfile.mkdtemp(prefix='open-gate-'))
    if options.log_dir or os.environ.get('VERIFY_LOG_DIR'):
        directory.mkdir(parents=True, exist_ok=False)
    directory = directory.resolve()
    planned_head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if not GATE['fingerprint']()['clean']:
        raise RuntimeError('commit source changes before queuing a merge gate')
    receipt = dict(schema=1, machine='M5', config=options.config, style='chrome', lane='merge',
                   selected=selected, partialSelectors=partial, started=time.time(),
                   prReady=not options.only and not options.quick and not options.no_e2e,
                   chunks=[], stages=[], rows=[], source=None)
    rows = {}; stages = {}; unsafe = False
    def cancel(signum, _):
        global CANCELLED
        CANCELLED = CANCELLED or signum
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, cancel)
    for index, selection in enumerate(chunks, 1):
        name = 'chunk-%03d' % index
        if unsafe or CANCELLED:
            for stage in selection:
                rows[name+'/'+stage] = dict(row=name+'/'+stage, status='NOT_RUN',
                    reason='owned cleanup stopped dispatch' if unsafe else 'dispatcher cancelled', evidence='')
            continue
        if subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip() != planned_head:
            raise RuntimeError('source changed between FIFO chunks; remaining stages were not launched')
        out = directory/name
        command = [str(Path.home()/'Library/Caches/OpenRE/scripts/heavy.sh'),
                   str(ROOT/'tools/verify-all.sh'), '--only', ','.join(selection),
                   '--config', options.config, '--log-dir', str(out)]
        if options.m1_receipts:
            command += ['--m1-receipts', str(options.m1_receipts.resolve())]
        if options.with_arc_data:
            command.append('--with-arc-data')
        queued = time.time(); acquired = None; stopping = False
        print(name + ' queued: ' + ', '.join(selection), flush=True)
        with (directory/(name+'.log')).open('x') as output:
            job = subprocess.Popen(command, cwd=ROOT, env=dict(os.environ, OPEN_VERIFY_CHUNK_WORKER='1'),
                                   stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                while job.poll() is None:
                    if acquired is None and holder(job.pid):
                        acquired = time.monotonic()
                    overrun = acquired is not None and time.monotonic()-acquired >= 900 and waiters(job.pid)
                    if (CANCELLED or overrun) and not stopping:
                        stopping = stop_worker(job)
                        if stopping:
                            print(name + ': stopping after owned cleanup (' + ('cancelled' if CANCELLED else '15-minute ticket cap with waiters') + ')', flush=True)
                    try:
                        job.wait(.25)
                    except subprocess.TimeoutExpired:
                        pass
            finally:
                while job.poll() is None:
                    with contextlib.suppress(Exception):
                        if stop_worker(job):
                            break
                    time.sleep(.25)
                if job.poll() is None:
                    job.wait()  # Never abandon a live check on a dispatcher error.
        rc = job.returncode
        record = dict(name=name, selected=selection, queued=queued, ended=time.time(), exit=rc,
                      slotSeconds=None if acquired is None else round(time.monotonic()-acquired, 3),
                      evidence=str(out/'gate.json'))
        receipt['chunks'].append(record)
        path = out/'gate.json'
        if not path.is_file():
            rows[name+'/receipt'] = dict(row=name+'/receipt', status='INTERRUPTED' if stopping else 'FAIL',
                                        reason='chunk has no completed gate receipt', evidence=str(directory/(name+'.log')))
            unsafe = True
            continue
        data = GATE['read_json'](path)
        if data['source']['head'] != planned_head or not data['source']['clean']:
            raise RuntimeError('chunk source differs from the planned clean head')
        if receipt['source'] is None:
            receipt['source'] = data['source']
        if data['source'] != receipt['source'] or data['config'] != options.config or data['lane'] != 'merge':
            raise RuntimeError('source, engine, configuration or lane differs between chunks')
        # LEAD 08:43: this exact row measures the M5 reference display, under
        # its existing M5/load<=12/nominal<=8.34 ms rule. It is not a quiet-M1
        # latency/CPU budget. Keep the real M5 PASS or FAIL and discard only
        # the legacy worker's extra M1 placeholder. Raw worker JSON is intact.
        display_row = next((row for row in data['rows']
                            if row['row'] == 'm5/onboarding/strict_120hz'
                            and row.get('timing') is True
                            and row['status'] in ('PASS', 'FAIL')), None)
        for row in copy.deepcopy(data['rows']):
            key = row['row']
            if key == 'onboarding/strict_120hz' and row['status'] == 'M1_REQUIRED':
                if display_row is None:
                    raise RuntimeError('missing M5 display assertion for onboarding/strict_120hz')
                continue
            if key == 'm5/onboarding/strict_120hz':
                key = row['row'] = 'onboarding/strict_120hz'
            if key == 'cli/build' or key.startswith('build/'):
                key = 'build/'+name+'/'+key.replace('/', '-')
                row['row'] = key
            if key in rows and rows[key] != row:
                raise RuntimeError('conflicting duplicate chunk row: '+key)
            rows[key] = row
        for stage in data['stages']:
            key = stage['name']
            if key in stages and stages[key] != stage:
                raise RuntimeError('conflicting duplicate chunk stage: '+key)
            stages[key] = stage
        unsafe = any(GATE['read_json'](p).get('safe') is not True for p in out.glob('*/screen-end.json'))
        print(name + ': ' + ('PASS' if data['ok'] else 'raw findings retained') + '; ticket released', flush=True)
    receipt['rows'] = list(rows.values()); receipt['stages'] = list(stages.values())
    entries = GATE['read_bounded'](ROOT/'tools/verification/gate-exceptions.json')
    failed, inventory = GATE['evaluate'](entries, receipt['rows'], ready=True)
    receipt.update(ended=time.time(), exceptions=inventory, ok=not failed and not CANCELLED)
    GATE['write_json'](directory/'gate.json', receipt)
    lines = ['| Row | Status | Observed | Policy | Reason |','|---|---|---|---|---|']
    lines += ['| '+row['row']+' | '+row['status']+' | '+row.get('observedStatus',row['status'])+' | '+row['policy']+' | '+row.get('reason','').replace('|','/')+' |' for row in receipt['rows']]
    lines += ['', '| Chunk | Exit | Slot seconds |', '|---|---:|---:|']
    lines += ['| '+chunk['name']+' | '+str(chunk['exit'])+' | '+str(chunk['slotSeconds'])+' |' for chunk in receipt['chunks']]
    lines += ['', '| Exception | Verdict | Clears when |', '|---|---|---|']
    lines += ['| '+entry['row']+' | '+entry['verdict']+' | '+entry['clearsWhen']+' |' for entry in inventory]
    lines += ['', 'Gate: '+('PASS' if receipt['ok'] else 'FAIL'), 'Logs: '+str(directory)]
    (directory/'summary.md').write_text('\n'.join(lines)+'\n')
    print('\n'.join(lines), flush=True)
    return 130 if CANCELLED else 0 if receipt['ok'] else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as error:
        print('FAIL:', error, file=sys.stderr)
        raise SystemExit(2)
