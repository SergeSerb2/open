#!/usr/bin/env python3
"""Replay Open alone against the frozen Phase 2 Arc rows; never launches Arc."""
import argparse
import fnmatch
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from run import ROOT, ARC, OPEN, atomic, background_jobs, existing_pids, now, provenance, sha
from score import compare
from server import Collector
from display import displays_match

PRIVATE = ROOT / '.re/perf'
TASKS = {'ui': 'interaction', 'fps': 'smoothness', 'resume': 'resume'}
MAX_JSON = 16 * 1024 * 1024


def load(path):
    """Bound source bytes, decoded nodes and nesting; refuse non-finite values."""
    path = Path(path)
    if path.stat().st_size > MAX_JSON:
        raise ValueError('JSON exceeds 16 MiB: ' + str(path))
    def integer(value):
        if len(value) > 20 or not -(2**63) <= int(value) < 2**63:
            raise ValueError('JSON integer exceeds signed 64-bit receipt width')
        return int(value)
    def constant(value): raise ValueError('Non-finite JSON value: ' + value)
    value = json.loads(path.read_text(), parse_int=integer, parse_constant=constant)
    pending = [(value, 0)]; count = 0
    while pending:
        item, depth = pending.pop(); count += 1
        if depth > 64 or count > 500_000: raise ValueError('JSON nesting or node limit exceeded')
        if isinstance(item, dict): pending.extend((v, depth + 1) for v in item.values())
        elif isinstance(item, list): pending.extend((v, depth + 1) for v in item)
        elif isinstance(item, float) and not math.isfinite(item): raise ValueError('Non-finite receipt number')
    return value


def private_path(value):
    path = Path(value)
    if not path.is_absolute(): path = ROOT / path
    path = path.resolve()
    try: path.relative_to(PRIVATE.resolve())
    except ValueError: raise ValueError('Private replay inputs and output must stay under .re/perf')
    return path


def metric_digest(reference):
    return hashlib.sha256(json.dumps(reference['metrics'], sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def tree_digest(root, copied=False):
    """Hash file names/content, without following links or allocating file-sized buffers."""
    # Only the runner-created short socket root may bypass the input-path rule.
    root = Path(root) if copied else private_path(root)
    if not root.is_dir(): raise ValueError('Private starting state is missing: ' + str(root))
    h = hashlib.sha256(); count = 0; total = 0
    for parent, directories, files in os.walk(root, followlinks=False):
        directories.sort(); files.sort()
        for name in directories + files:
            path = Path(parent) / name
            if path.is_symlink(): raise ValueError('Private state contains a symbolic link')
        for name in files:
            path = Path(parent) / name
            if not path.is_file(): raise ValueError('Private state contains a non-regular file')
            count += 1; total += path.stat().st_size
            if count > 100_000 or total > 8 * 1024**3: raise ValueError('Private state exceeds file/byte limit')
            h.update(path.relative_to(root).as_posix().encode()); h.update(b'\0')
            h.update(bytes.fromhex(sha(path))); h.update(b'\0')
    if not (root / 'State/browser.json').is_file(): raise ValueError('Private starting state lacks browser.json')
    return h.hexdigest()


def export(reference_path, source, output):
    reference = load(reference_path); source = private_path(source)
    phase = load(source); frozen = reference['provenance']['phase2']
    if phase.get('calibration_only') or sha(source) != frozen['sha256']:
        raise ValueError('Only the accepted frozen Phase 2 cohort can create replay states')
    pairs = []
    for task in TASKS.values():
        samples = [s for s in phase['samples'] if s['task'] == task]
        indices = sorted({s['round_index'] for s in samples if all(any(
            v['round_index'] == s['round_index'] and v['browser'] == name and v.get('valid')
            and (name != 'open' or task != 'interaction' or v.get('input_boundary_version', 1) >= 2)
            for v in samples) for name in ('arc', 'open'))})
        if len(indices) < 7: raise ValueError('Accepted cohort lacks seven matched pairs: ' + task)
        for index in indices:
            sample = next(s for s in samples if s['round_index'] == index and s['browser'] == 'arc')
            snapshot = private_path(Path(sample['source_directory']).parent / f'{task}-{index:02}-paired-start')
            bounds = sample['window_bounds']; height = phase['provenance']['display']['screens'][0]['height']
            pairs.append({'task': task, 'index': index, 'snapshot': str(snapshot.relative_to(ROOT)),
                'snapshot_sha256': tree_digest(snapshot),
                'frame': [bounds[0], height - bounds[1] - bounds[3], bounds[2], bounds[3]],
                'viewport': [sample['workload_page']['viewport_width'], sample['workload_page']['viewport_height']]})
    setup = load(source.parent / (source.stem + '-samples') / 'worker-config.json')
    # Origin/port are part of restored local URLs, so a different port is refused.
    from urllib.parse import urlsplit
    origin = setup['origin']; port = urlsplit(origin).port
    manifest = {'schema': 1, 'source': str(source.relative_to(ROOT)), 'source_sha256': sha(source),
        'reference_metrics_sha256': metric_digest(reference), 'pairs': pairs,
        'origin': origin, 'port': port, 'route': setup.get('route', ''),
        'detector': phase['provenance']['detector'],
        'space_transition_route': phase['provenance']['space_transition_route']}
    atomic(output, manifest)
    reference['provenance']['phase2']['replay_manifest'] = str(output.relative_to(ROOT))
    reference['provenance']['phase2']['replay_manifest_sha256'] = sha(output)
    atomic(reference_path, reference)
    print(json.dumps({'exported_pairs': len(pairs), 'manifest': str(output.relative_to(ROOT))}))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('browser', choices=['open'])
    p.add_argument('--state', choices=['S-real'], default='S-real')
    p.add_argument('--reference', type=Path, default=ROOT / 'docs/perf/arc-reference-m5.json')
    p.add_argument('--manifest', type=Path)
    p.add_argument('--export-replay', type=Path, help='Bind accepted private paired starts to the frozen reference; no app launches')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--samples', type=int, default=7)
    p.add_argument('--metrics', help='Comma-separated Phase 2 metric IDs or glob patterns; named subsets may use smaller N')
    p.add_argument('--calibrate', action='store_true', help='Unscored real-flow check; may use N1')
    p.add_argument('--preflight', action='store_true', help='Validate private starts and live provenance without opening windows')
    p.add_argument('--allow-display-drift', action='store_true', help='Legacy calibration flag: retain both display keys; colour identity still must match')
    p.add_argument('--app-cadence', action='store_true', help='Record bounded App display-link and sidebar bounds-change timestamps (informative)')
    p.add_argument('--fail-after-metric', help='Calibration-only cleanup proof after a real measured action')
    p.add_argument('--max-load', type=float, default=10)
    p.add_argument('--max-wait-seconds', type=int, default=3600, help='Gate retry budget; FIFO queue time can exceed this budget')
    a = p.parse_args(); os.umask(0o077)
    a.out = private_path(a.out)
    if a.out.exists(): p.error('Preserve receipts: output already exists')
    if a.allow_display_drift and not a.calibrate: p.error('--allow-display-drift requires --calibrate; scoring remains forbidden')
    if a.app_cadence and not a.calibrate: p.error('--app-cadence requires --calibrate; the extra display link must stay off for scoring')
    if a.export_replay: return export(a.reference, a.export_replay, a.out)
    if not a.calibrate and background_jobs():
        p.error('Background build is active: score measurements are invalid; only --calibrate is allowed (under load, not for scoring)')
    if not 1 <= a.samples <= 7: p.error('Use 1–7 replay samples per task')
    if not 0 < a.max_load <= 10 or not math.isfinite(a.max_load): p.error('Load ceiling must be in (0,10]')
    if not 1 <= a.max_wait_seconds <= 86400: p.error('Wait limit must be 1–86400 seconds')
    if a.fail_after_metric and not a.calibrate: p.error('Failure injection requires --calibrate')
    reference = load(a.reference); frozen = reference['provenance']['phase2']
    if reference.get('kind') != 'frozen-arc-reference': raise ValueError('Expected a frozen Arc reference')
    manifest_path = private_path(a.manifest or frozen['replay_manifest'])
    if sha(manifest_path) != frozen['replay_manifest_sha256']: raise ValueError('Private replay manifest changed')
    manifest = load(manifest_path)
    if manifest['schema'] != 1 or len(manifest['pairs']) > 64: raise ValueError('Unsupported replay manifest')
    if manifest['source_sha256'] != frozen['sha256'] or manifest['reference_metrics_sha256'] != metric_digest(reference):
        raise ValueError('Replay manifest belongs to a different frozen reference')
    available = {r['id'] for r in reference['metrics'] if r['id'].split('.')[0] in TASKS}
    patterns = a.metrics.split(',') if a.metrics else ['*']
    if len(patterns) > 64 or any(len(v) > 256 for v in patterns): p.error('Metric selector limit exceeded')
    selected = set()
    for pattern in patterns:
        matches = {v for v in available if fnmatch.fnmatchcase(v, pattern)}
        if not matches: p.error('Unknown Phase 2 metric selector: ' + pattern)
        selected.update(matches)
    if selected == available and a.samples < 7 and not a.calibrate: p.error('Full Phase 2 replay requires N7; use --calibrate for an unscored check')
    if a.fail_after_metric and a.fail_after_metric not in selected: p.error('Failure metric must be selected')
    tasks = [task for task in TASKS.values() if any(TASKS[k.split('.')[0]] == task for k in selected)]
    pairs = [v for task in tasks for v in manifest['pairs'] if v['task'] == task][:]
    pairs = [v for task in tasks for v in sorted((x for x in pairs if x['task'] == task), key=lambda x: x['index'])[:a.samples]]
    if any(sum(v['task'] == task for v in pairs) != a.samples for task in tasks): raise ValueError('Insufficient private starting states')
    for pair in pairs:
        if tree_digest(pair['snapshot']) != pair['snapshot_sha256']: raise ValueError('Private replay state changed')
    current = provenance(include_arc=False)
    for key in ('hardware', 'os', 'display'):
        matches = displays_match(reference['provenance'][key], current[key]) if key == 'display' else current[key] == reference['provenance'][key]
        if not matches:
            raise ValueError('Cannot replay across different ' + key)
    if a.allow_display_drift:
        current['calibration_display_metadata'] = {'frozen': reference['provenance']['display'], 'actual': current['display'],
            'qualification': 'Legacy calibration flag; normalized colour identity, mode and scale still match'}
    current.update(phase2_run_id=f'{time.time_ns():x}', detector=manifest['detector'],
        space_transition_route=manifest['space_transition_route'], max_load1=a.max_load,
        measurement_helpers={name: sha(PRIVATE / 'bin' / name) for name in ('frames', 'probe', 'ax-perf')},
        sampling_policy={'core_required_n': 7, 'metric_required_n': {v: a.samples for v in selected} if a.metrics else {}},
        frozen_reference_sha256=sha(a.reference), replay_manifest_sha256=sha(manifest_path),
        arc_access='Frozen reference only; no Arc launch, defaults or live data access')
    if a.preflight:
        result = {'schema': 1, 'kind': 'replay-preflight', 'date': now(), 'calibration_only': True,
            'provenance': current, 'selected_metrics': sorted(selected), 'pairs': len(pairs),
            'foreign_browser_present': bool(existing_pids(ARC) or existing_pids(OPEN)),
            'qualification': 'Offscreen provenance check only; no input, capture, windows or scoring'}
        atomic(a.out, result)
        print(json.dumps({'status': 'PREFLIGHT', 'metrics': len(selected), 'pairs': len(pairs),
            'foreign_browser_present': result['foreign_browser_present']}))
        return 0
    run = {'schema': 1, 'date': now(), 'provenance': current, 'samples': [], 'blocked': {},
        'calibration_only': a.calibrate, 'selected_metrics': sorted(selected), 'gate_attempts': [],
        'qualification': 'unscored functional calibration; actual load retained' if a.calibrate else 'scored replay; background jobs forbidden'}
    work = a.out.parent / (a.out.stem + '-samples'); work.mkdir(parents=True)
    collector = Collector(work / 'collector', port=manifest['port'])
    root = Path(tempfile.mkdtemp(prefix='op.')); atomic(a.out, run)
    try:
        for pair in pairs:
            wait_end = time.monotonic() + a.max_wait_seconds; accepted = False; attempt = 0
            while not accepted:
                if time.monotonic() >= wait_end: raise RuntimeError('Timed out waiting for a qualified replay session')
                if not a.calibrate and background_jobs():raise RuntimeError('Background build started; score measurements are invalid')
                if (not a.calibrate and os.getloadavg()[0] > a.max_load) or Path('/tmp/open-onscreen-priority').exists() or (ROOT / '.re/hold-on-screen').exists():
                    time.sleep(5); continue
                snapshot = private_path(pair['snapshot'])
                if tree_digest(snapshot) != pair['snapshot_sha256']: raise ValueError('Private replay state changed')
                shutil.rmtree(root); shutil.copytree(snapshot, root)
                if tree_digest(root, copied=True) != pair['snapshot_sha256']:
                    raise ValueError('Copied replay state changed')
                directory = work / f"{pair['task']}-{pair['index']:02}-attempt-{attempt:02}"
                cfg = {'browser': 'open', 'open_only': True, 'task': pair['task'], 'index': pair['index'],
                    'out': str(directory), 'root': str(root), 'collector': collector.url,
                    'origin': manifest['origin'], 'route': manifest['route'], 'provenance': current,
                    'frame': pair['frame'], 'viewport': pair['viewport'],
                    'metric_filter': sorted(selected), 'fail_after_metric': a.fail_after_metric,
                    'app_cadence': a.app_cadence, 'calibration_only': a.calibrate}
                config = work / 'worker-config.json'; atomic(config, cfg)
                command = [str(Path.home() / 'Library/Caches/OpenRE/scripts/heavy.sh'),
                    '/usr/bin/lockf', '-k', '-t', '30', '/tmp/open-onscreen-e2e.lock',
                    sys.executable, str(ROOT / 'tools/perf/phase2.py'), '--worker', str(config)]
                status = subprocess.run(command, env=dict(os.environ, OPEN_HEAVY_EXCLUSIVE='1')).returncode
                path = directory / 'sample.json'; sample = load(path) if path.exists() else None
                attempt += 1
                if not sample and status not in (75, 73):
                    raise RuntimeError('Replay worker stopped before writing a sample; exit ' + str(status))
                if not sample or sample.get('gate_refused'):
                    run['gate_attempts'].append({'date': now(), 'status': status}); atomic(a.out, run); continue
                sample['source_directory'] = str(directory.relative_to(ROOT))
                sample['replay_snapshot_sha256'] = pair['snapshot_sha256']
                sample['metrics'] = {k: v for k, v in sample['metrics'].items() if k in selected}
                run['samples'].append(sample); atomic(a.out, run)
                if status: raise RuntimeError(sample.get('error') or ('Foreign browser blocks preflight' if sample.get('foreign_browser') else 'Replay worker failed'))
                accepted = bool(sample.get('valid'))
                if attempt >= 3 and not accepted: raise RuntimeError('Three unqualified attempts for one replay state')
        for metric in selected:
            if sum(s.get('valid') and metric in s['metrics'] for s in run['samples']) != a.samples:
                raise RuntimeError('Replay metric did not meet its declared N: ' + metric)
    except BaseException as exc:
        run['stop_reason'] = str(exc) or type(exc).__name__
    finally:
        if a.calibrate and any(s.get('qualification') == 'under load, not for scoring' for s in run['samples']):
            run['qualification'] = 'under load, not for scoring'
        run['end_date'] = now(); atomic(a.out, run); collector.close(); shutil.rmtree(root)
    if not run.get('stop_reason') and not a.calibrate:
        score = compare(reference, run)
        score['label'] = 'Open-only Phase 2 selected rows' if a.metrics else 'Open-only Phase 2'
        score['qualification'] += '; score covers selected Phase 2 rows only; no carried Phase 1 values'
        atomic(a.out.with_name(a.out.stem + '-scorecard.json'), score)
    print(json.dumps({'status': 'FAILED' if run.get('stop_reason') else 'CALIBRATION' if a.calibrate else 'COMPLETE',
        'metrics': len(selected), 'samples_per_metric': a.samples, 'stop_reason': run.get('stop_reason')}))
    return 1 if run.get('stop_reason') else 0


if __name__ == '__main__':
    try: raise SystemExit(main())
    except (ValueError, KeyError, OSError, RecursionError) as exc: raise SystemExit('Replay refused: ' + str(exc))
