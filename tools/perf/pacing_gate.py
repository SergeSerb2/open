#!/usr/bin/env python3
"""Shared pacing gate (LEAD ruling 2026-11-16 22:15) over existing stock frame-detector ledgers.

The scorer reads ledgers only. It never re-runs a capture and never changes the detector, its ROI or its
pixel thresholds. One ledger path = one App launch. Every trial in every given ledger is scored and
reported; there is no best-of-N.

Rules (per action = trial label without its trailing "-N"):
  true late      an interval between consecutive stock changes >= 16.7 ms. An exactly-12.50 ms interval
                 (3 vsyncs at 240 Hz) is cadence, never late.
  late budget    at most 1 true late interval per trial (START and OTHER both count).
  motion p99     pooled over every change interval of the action (nearest rank): <= 16.7 ms.
  START          a true late interval that ends <= 50 ms after the trial's first change, in an app-idle trial
                 (no native sample in the 25 ms before the first change). Everything else is OTHER.
  START rate     AFTER (trials with START / app-idle motion trials) <= same-session BEFORE rate + 15 points.
                 Only trials with >= 3 changes count; with no such BEFORE trial the reference rate is 0.
  OTHER          target 0 (reported); each OTHER interval still uses the trial's late budget.
  stop rule      >= 9 trials from >= 3 launches per action (predeclared run set).
  motion         every trial has >= 3 stock changes (the stock detector's own minimum).
Optional (--first-change-latency, Split #569 ruling): AFTER median first-change latency <= BEFORE median
  + one display refresh.

Accepted ledger forms (auto-detected):
  * a JSON list of stock rows (tools/perf frame_client rows, e.g. surface-measure/split-measure result.json);
  * a JSON object with a "trials" list of stock rows (e.g. D3 measure-motion result.json);
  * a run directory holding such a result.json, or a frames/ directory of per-trial row files
    (e.g. Peek/NT frames/<label>.json; frame-config/frame-ready files are skipped).
A stock row needs: label, changes (mach ticks), frames (objects with ticks), input_ticks.
The mach timebase comes from the ledger's display.json / display.mach_timebase; otherwise 125/3 (Apple
Silicon) is assumed and reported.

Usage:
  pacing_gate.py --before B1 B2 B3 --after A1 A2 A3 [--json OUT] [--first-change-latency]
  pacing_gate.py --after A1 A2 A3          (START rate then reads NO-BEFORE and the verdict is INCOMPLETE)
Exit status: 0 every action PASS, 1 any action FAIL, 2 incomplete (no BEFORE for an action) or bad input.
"""
import argparse
import json
import math
import re
import statistics
import sys
from pathlib import Path

LATE_MS = 16.7
P99_MS = 16.7
START_WINDOW_MS = 50.0
IDLE_LOOKBACK_MS = 25.0
START_MARGIN_POINTS = 15.0
MIN_TRIALS = 9
MIN_LAUNCHES = 3
MIN_CHANGES = 3
DEFAULT_TIMEBASE = (125, 3)
SKIP_FILES = {'frame-config.json', 'frame-ready.json'}
# Input limits (ledgers come from disk). The stock frames helper itself stops at 4096 frames per trial.
MAX_LEDGER_BYTES = 64 * 1024 * 1024
MAX_ROWS = 4096
MAX_SAMPLES = 4096
MAX_LEDGERS = 64


def _load(path):
    if Path(path).stat().st_size > MAX_LEDGER_BYTES:
        raise ValueError('%s exceeds %d bytes' % (path, MAX_LEDGER_BYTES))
    with open(path) as handle:
        return json.load(handle)  # json refuses trailing data after the value


def _checked(rows, path):
    if len(rows) > MAX_ROWS:
        raise ValueError('%s: %d rows exceeds %d' % (path, len(rows), MAX_ROWS))
    for row in rows:
        if len(row['changes']) > MAX_SAMPLES or len(row['frames']) > MAX_SAMPLES:
            raise ValueError('%s: trial %r exceeds %d samples' % (path, row.get('label'), MAX_SAMPLES))
    return rows


def _is_row(value):
    return isinstance(value, dict) and isinstance(value.get('changes'), list) and isinstance(value.get('frames'), list)


def _timebase(directory, document=None):
    if isinstance(document, dict) and isinstance(document.get('display'), dict):
        tb = document['display'].get('mach_timebase')
        if tb:
            return tuple(tb), 'ledger display.mach_timebase'
    for candidate in (directory / 'display.json', directory.parent / 'display.json'):
        if candidate.is_file():
            tb = _load(candidate).get('mach_timebase')
            if tb:
                return tuple(tb), str(candidate)
    return DEFAULT_TIMEBASE, 'assumed 125/3 (Apple Silicon)'


def _refresh_hz(directory, document=None):
    screens = None
    if isinstance(document, dict) and isinstance(document.get('display'), dict):
        screens = document['display'].get('screens')
    for candidate in (directory / 'display.json', directory.parent / 'display.json'):
        if screens is None and candidate.is_file():
            screens = _load(candidate).get('screens')
    if screens:
        return screens[0].get('refresh_hz')
    return None


def read_ledger(path):
    """Return (rows, provenance) for one launch ledger."""
    path = Path(path)
    if path.is_dir():
        if (path / 'result.json').is_file():
            document = _load(path / 'result.json')
            rows = document if isinstance(document, list) else document.get('trials') if isinstance(document, dict) else None
            if isinstance(rows, list) and rows and all(_is_row(r) for r in rows):
                tb, source = _timebase(path, document)
                return _checked(rows, path), {'path': str(path / 'result.json'), 'timebase': tb, 'timebase_source': source,
                              'refresh_hz': _refresh_hz(path, document)}
        frames = path / 'frames' if (path / 'frames').is_dir() else path
        rows = []
        for item in sorted(frames.glob('*.json')):
            if item.name in SKIP_FILES:
                continue
            value = _load(item)
            if _is_row(value):
                rows.append(value)
        if not rows:
            raise ValueError('%s: no stock rows found (result.json or frames/*.json)' % path)
        tb, source = _timebase(frames)
        return _checked(rows, frames), {'path': str(frames), 'timebase': tb, 'timebase_source': source, 'refresh_hz': _refresh_hz(frames)}
    document = _load(path)
    rows = document if isinstance(document, list) else document.get('trials') if isinstance(document, dict) else None
    if _is_row(document):
        rows = [document]
    if not isinstance(rows, list) or not rows or not all(_is_row(r) for r in rows):
        raise ValueError('%s: not a stock ledger (list of rows or {"trials": [...]})' % path)
    tb, source = _timebase(path.parent, document)
    return _checked(rows, path), {'path': str(path), 'timebase': tb, 'timebase_source': source, 'refresh_hz': _refresh_hz(path.parent, document)}


def action_name(label):
    return re.sub(r'-\d+$', '', str(label))


def score_trial(row, tick_ms):
    changes = [int(t) for t in row['changes']]
    frames = [int(f['ticks']) for f in row['frames']]
    origin = row.get('input_ticks') or row.get('dispatch_ticks') or row.get('dispatchTicks')
    trial = {'label': row.get('label'), 'changes': len(changes), 'motion_ok': len(changes) >= MIN_CHANGES,
             'late': [], 'intervals_ms': []}
    if not changes:
        trial.update(first_change_ms=None, app_idle=None, true_late=0, start=0, other=0, max_interval_ms=None,
                     budget_ok=False)
        return trial
    first = changes[0]
    trial['first_change_ms'] = round((first - origin) * tick_ms, 3) if origin else None
    lookback = first - IDLE_LOOKBACK_MS / tick_ms
    trial['app_idle'] = not any(lookback <= f < first for f in frames)
    for a, b in zip(changes, changes[1:]):
        ms = (b - a) * tick_ms
        trial['intervals_ms'].append(ms)
        if ms >= LATE_MS:
            ends = (b - first) * tick_ms
            kind = 'START' if trial['app_idle'] and ends <= START_WINDOW_MS else 'OTHER'
            trial['late'].append({'class': kind, 'from_first_ms': round((a - first) * tick_ms, 3),
                                  'interval_ms': round(ms, 3), 'native_samples_inside': sum(a < f < b for f in frames)})
    trial['true_late'] = len(trial['late'])
    trial['start'] = sum(g['class'] == 'START' for g in trial['late'])
    trial['other'] = trial['true_late'] - trial['start']
    trial['max_interval_ms'] = round(max(trial['intervals_ms']), 3) if trial['intervals_ms'] else None
    trial['budget_ok'] = trial['true_late'] <= 1
    return trial


def nearest_rank(values, q):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(q * len(ordered)) - 1)] if ordered else None


def score_side(ledgers):
    actions = {}
    provenance = []
    seen = set()
    if len(ledgers) > MAX_LEDGERS:
        raise ValueError('%d ledgers exceeds %d' % (len(ledgers), MAX_LEDGERS))
    for launch, path in enumerate(ledgers):
        resolved = str(Path(path).resolve())
        if resolved in seen:
            raise ValueError('%s given twice; every launch counts once' % path)
        seen.add(resolved)
        rows, prov = read_ledger(path)
        tick_ms = prov['timebase'][0] / prov['timebase'][1] / 1e6
        prov['launch'] = launch
        prov['trials'] = len(rows)
        provenance.append(prov)
        for row in rows:
            trial = score_trial(row, tick_ms)
            trial['launch'] = launch
            actions.setdefault(action_name(trial['label']), []).append(trial)
    summary = {}
    for name, trials in actions.items():
        intervals = [ms for t in trials for ms in t['intervals_ms']]
        # START rate counts motion trials only (>= 3 changes): an instant BEFORE change has no motion start.
        idle = [t for t in trials if t['app_idle'] and t['motion_ok']]
        with_start = [t for t in idle if t['start']]
        firsts = [t['first_change_ms'] for t in trials if t['first_change_ms'] is not None]
        summary[name] = {
            'trials': len(trials), 'launches': len({t['launch'] for t in trials}),
            'motion_ok': all(t['motion_ok'] for t in trials),
            'trials_over_budget': sum(not t['budget_ok'] for t in trials),
            'true_late': sum(t['true_late'] for t in trials),
            'other_late': sum(t['other'] for t in trials),
            'p99_ms': round(nearest_rank(intervals, .99), 3) if intervals else None,
            'idle_trials': len(idle), 'start_trials': len(with_start),
            'start_rate_pct': round(100 * len(with_start) / len(idle), 1) if idle else None,
            'first_change_median_ms': round(statistics.median(firsts), 3) if firsts else None,
            'trial_rows': trials,
        }
    return summary, provenance


def rule(ok):
    return 'PASS' if ok else 'FAIL'


def gate(before, after, first_change_latency=False, refresh_ms=None):
    verdicts = {}
    for name, a in after.items():
        b = before.get(name) if before is not None else None
        rules = {
            'stop_rule_>=9_trials_>=3_launches': rule(a['trials'] >= MIN_TRIALS and a['launches'] >= MIN_LAUNCHES),
            'motion_>=3_changes_every_trial': rule(a['motion_ok']),
            'late_<=1_per_trial': rule(a['trials_over_budget'] == 0),
            'motion_p99_<=16.7ms': rule(a['p99_ms'] is not None and a['p99_ms'] <= P99_MS),
        }
        if b is None:
            rules['start_rate_<=before+15pts'] = 'NO-BEFORE'
        elif a['idle_trials'] == 0:
            rules['start_rate_<=before+15pts'] = 'PASS'  # no app-idle trial, so no START can exist
        else:
            reference = b['start_rate_pct'] if b['start_rate_pct'] is not None else 0.0
            rules['start_rate_<=before+15pts'] = rule(a['start_rate_pct'] <= reference + START_MARGIN_POINTS)
        if first_change_latency:
            if b is None or refresh_ms is None or a['first_change_median_ms'] is None or b['first_change_median_ms'] is None:
                rules['first_change_<=before+1_refresh'] = 'NO-BEFORE'
            else:
                rules['first_change_<=before+1_refresh'] = rule(a['first_change_median_ms'] <= b['first_change_median_ms'] + refresh_ms)
        values = set(rules.values())
        verdict = 'FAIL' if 'FAIL' in values else 'INCOMPLETE' if 'NO-BEFORE' in values else 'PASS'
        verdicts[name] = {'verdict': verdict, 'rules': rules, 'other_late_target_0': a['other_late'] == 0}
    return verdicts


def fmt(value, digits=2):
    return '-' if value is None else ('%.*f' % (digits, value) if isinstance(value, float) else str(value))


def print_report(before, after, verdicts, provenance):
    for side, prov in provenance.items():
        for p in prov:
            print('%s launch %d: %s (%d trials; timebase %s/%s from %s)' % (
                side, p['launch'], p['path'], p['trials'], p['timebase'][0], p['timebase'][1], p['timebase_source']))
    print()
    print('Every trial (true late = interval >= %.1f ms; START = ends <= %d ms after first change in an app-idle trial):' % (LATE_MS, START_WINDOW_MS))
    print('| side | action | launch | trial | changes | first change ms | app idle | true late | START | OTHER | max interval ms | late intervals (from first ms / ms / class / native inside) |')
    print('|---|---|---|---|---|---|---|---|---|---|---|---|')
    for side, data in (('BEFORE', before), ('AFTER', after)):
        if not data:
            continue
        for name in sorted(data):
            for t in data[name]['trial_rows']:
                gaps = '; '.join('%s/%s/%s/%d' % (fmt(g['from_first_ms'], 1), fmt(g['interval_ms']), g['class'], g['native_samples_inside']) for g in t['late']) or '-'
                print('| %s | %s | %d | %s | %d | %s | %s | %d | %d | %d | %s | %s |' % (
                    side, name, t['launch'], t['label'], t['changes'], fmt(t['first_change_ms'], 1),
                    t['app_idle'], t['true_late'], t['start'], t['other'], fmt(t['max_interval_ms']), gaps))
    print()
    print('| action | side | trials | launches | p99 ms | trials >1 late | OTHER late | START trials / idle trials (rate) | median first change ms |')
    print('|---|---|---|---|---|---|---|---|---|')
    for name in sorted(set(after) | set(before or {})):
        for side, data in (('BEFORE', before), ('AFTER', after)):
            if data and name in data:
                s = data[name]
                print('| %s | %s | %d | %d | %s | %d | %d | %d/%d (%s%%) | %s |' % (
                    name, side, s['trials'], s['launches'], fmt(s['p99_ms'], 3), s['trials_over_budget'], s['other_late'],
                    s['start_trials'], s['idle_trials'], fmt(s['start_rate_pct'], 1), fmt(s['first_change_median_ms'], 1)))
    print()
    print('| action | verdict | ' + ' | '.join(next(iter(verdicts.values()))['rules']) + ' | OTHER target 0 |' if verdicts else '')
    if verdicts:
        print('|---|---|' + '---|' * (len(next(iter(verdicts.values()))['rules']) + 1))
        for name in sorted(verdicts):
            v = verdicts[name]
            print('| %s | %s | %s | %s |' % (name, v['verdict'], ' | '.join(v['rules'].values()), 'met' if v['other_late_target_0'] else 'not met'))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--before', nargs='*', default=None, help='BEFORE ledgers, one per launch (same session)')
    parser.add_argument('--after', nargs='+', required=True, help='AFTER ledgers, one per launch')
    parser.add_argument('--json', type=Path, help='write the full machine-readable result here')
    parser.add_argument('--first-change-latency', action='store_true',
                        help='also gate AFTER median first-change latency <= BEFORE median + 1 refresh (Split #569)')
    parser.add_argument('--refresh-hz', type=float, help='display refresh for --first-change-latency (default: ledger display.json)')
    args = parser.parse_args(argv)
    try:
        after, after_prov = score_side(args.after)
        before, before_prov = score_side(args.before) if args.before else (None, [])
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('pacing_gate: bad input: %s' % error, file=sys.stderr)
        return 2
    refresh_hz = args.refresh_hz or next((p['refresh_hz'] for p in after_prov if p.get('refresh_hz')), None)
    refresh_ms = 1000 / refresh_hz if refresh_hz else None
    verdicts = gate(before, after, args.first_change_latency, refresh_ms)
    print_report(before or {}, after, verdicts, {'BEFORE': before_prov, 'AFTER': after_prov})
    if args.json:
        args.json.write_text(json.dumps({'rules': {'late_ms': LATE_MS, 'p99_ms': P99_MS, 'start_window_ms': START_WINDOW_MS,
                                                   'idle_lookback_ms': IDLE_LOOKBACK_MS, 'start_margin_points': START_MARGIN_POINTS,
                                                   'min_trials': MIN_TRIALS, 'min_launches': MIN_LAUNCHES, 'min_changes': MIN_CHANGES,
                                                   'refresh_ms': refresh_ms},
                                         'provenance': {'before': before_prov, 'after': after_prov},
                                         'before': before, 'after': after, 'verdicts': verdicts}, indent=1, default=float) + '\n')
    results = {v['verdict'] for v in verdicts.values()}
    return 1 if 'FAIL' in results else 2 if 'INCOMPLETE' in results else 0


if __name__ == '__main__':
    sys.exit(main())
