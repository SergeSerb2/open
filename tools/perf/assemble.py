#!/usr/bin/env python3
"""Assemble accepted, interleaved real-app receipts without exporting profiles."""
import argparse
import copy
import datetime as dt
import json
from pathlib import Path
import statistics
import subprocess

from run import ARC, OPEN, BASE, PLANS, ROOT, atomic, now, sha, arc_core
from score import WEIGHTS, benchmark_target, category, compare, freeze, metric_rows, required_n, summarize

REQUIRED = {
    'launch.window_ms', 'launch.first_paint_ms',
    'mem.idle_1tab_mib', 'mem.10tabs_mib', 'mem.30tabs_mib', 'mem.per_tab_mib',
    'cpu.idle_static_pct', 'cpu.idle_10tabs_pct', 'cpu.idle_hidden_pct', 'cpu.animated_pct',
    'wakeups.idle_per_s', 'load.static_ms.cold', 'load.static_ms.warm',
    'load.heavy_dom_ms.cold', 'load.heavy_dom_ms.warm',
    'bench.speedometer', 'bench.jetstream', 'bench.motionmark',
    'disk.app_mib', 'disk.main_binary_mib', 'procs.idle_count',
}


def joined(inputs):
    result = None
    manifests = []
    sources = []
    window_revision = any('window' in tasks for _, tasks in inputs)
    for path, tasks in inputs:
        run = json.loads(path.read_text())
        if result is None:
            result = {k: copy.deepcopy(run[k]) for k in ('schema', 'date', 'provenance', 'blocked')}
            result['samples'] = []
            result['intent_failures'] = []
            result['resumes'] = []
        for key in ('commit', 'app_main_sha256', 'engine_sha256', 'arc_version', 'hardware', 'os', 'display'):
            if result['provenance'][key] != run['provenance'][key]:
                raise ValueError('Cannot combine different ' + key)
        sources.append({'receipt': str(path.relative_to(ROOT)), 'sha256': sha(path), 'tasks': tasks})
        for key in ('intent_failures', 'resumes'):
            for event in run.get(key, []):
                if key == 'intent_failures' and event.get('task') not in tasks:
                    continue
                if event not in result[key]:
                    result[key].append(copy.deepcopy(event))
        for source in run['samples']:
            if source.get('task') not in tasks:
                continue
            sample = copy.deepcopy(source)
            if sample.get('error') == 'KeyboardInterrupt':
                for receipt in [path]+[Path(v['source']) for v in run.get('resumes',[])]:
                    if not receipt.is_absolute():receipt=ROOT/receipt
                    interruption=receipt.with_name(receipt.stem+'-samples')/(
                        f"{sample['round_index']:02}-{sample['browser']}-{sample['task']}")/'operator-stop.json'
                    if interruption.is_file():
                        sample['operator_interruption']=json.loads(interruption.read_text());break
            if (sample.get('task') == 'core' and sample.get('intent_failure') and
                    'mem.per_tab_mib' in sample.get('metrics', {}) and
                    'disk.app_mib' in sample.get('metrics', {})):
                sample['intent_failure_phase'] = 'optional_immediate_relaunch'
            # Launch routes have separate cohorts. A benchmark's preceding
            # launch is setup, not an additional window-latency sample.
            if sample['task'] == 'core' and window_revision:
                sample['metrics'].pop('launch.window_ms', None)
            if sample['task'] not in ('core', 'window'):
                sample['metrics'] = {k: v for k, v in sample['metrics'].items()
                                     if k == 'launch.first_paint_ms' or k.startswith('bench.')}
            sample['source_receipt'] = str(path.relative_to(ROOT))
            result['samples'].append(sample)
        cohort = run['provenance'].get('replay_cohort')
        if cohort:
            manifest = BASE.parent/'cohorts'/cohort/'manifest.json'
            manifests.append((manifest, tasks))
    for event in result['intent_failures']:
        match = next((s for s in result['samples'] if s['browser'] == event['browser'] and
                      s['task'] == event['task'] and s['round_index'] == event['index']), None)
        if match and match.get('intent_failure_phase'):
            event['phase'] = match['intent_failure_phase']
    result['end_date'] = now()
    if 'arc_core' not in result['provenance']:
        result['provenance']['arc_core'] = arc_core()
        result['provenance']['arc_core_qualification']='Version/hash recorded after P1 per LEAD 02:15; old samples had bundle-version guards only'
    result['provenance']['open_chromium_version']='156.0.8078.48'
    for task in {s['task'] for s in result['samples']}:
        good = {s['round_index'] for s in result['samples'] if s['task']==task and all(
            any(v['task']==task and v.get('round_index')==s['round_index'] and
                v['browser']==browser and v.get('valid') for v in result['samples'])
            for browser in ('arc','open'))}
        for sample in result['samples']:
            if sample['task']==task and sample['round_index'] not in good:
                sample['valid']=False
                sample['pair_excluded']='One or both browsers did not qualify this identical-start pair'
    result['provenance']['source_receipts'] = sources
    if window_revision:
        result['provenance']['window_row_revision'] = {
            'authorization': 'LEAD 01:35 item 2', 'detector_version': max(s.get('launch_detector_version',1) for s in result['samples'] if s['task']=='window'), 'target_poll_interval_ms':.1,
            'scope': 'Only launch.window_ms remeasured in both browsers on the pinned build; original core row retained in archived receipts',
            'method': 'Exact executable owner matching; all-window polling independent of LaunchServices completion; first onscreen layer-0 window with positive area and alpha'}
    if result['provenance'].get('sampling_policy'):
        for task in {s['task'] for s in result['samples'] if s['task'].startswith('bench-')}:
            benchmark_target(result,result,task,('arc','open'))
    result['provenance']['launch_routes'] = {
        'launch.window_ms': 'default LaunchServices plain application launch, no URL',
        'launch.first_paint_ms': 'default LaunchServices shared URL startup intent with a unique synthetic token; observed window counts in context',
    }
    result['provenance']['workload'] = 'Pair-matched imported sidebar; 1/10/30 newly visited synthetic pages; native sleep policies retained'
    if result['provenance']['commit'] == '1593ece6f92a50feac5b44cc5a5b5c1161f900fd':
        result['provenance']['cohort_build_note'] = (
            'Per LEAD 23:40, the pinned build predates PR 308, so its idle rows may include '
            'the Chromium sampling profiler thread. This cohort did not isolate that cause; '
            'the lead will order an idle/launch re-measure on current main as the first hill-climb step.')
    result['blocked'].update({
        'mem.after_close_mib': 'Phase 2: normal Arc tabs refuse script self-close',
        'disk.fresh_profile_mib': 'Arc S-empty is blocked on M5; Open S-empty information only',
        'mem.pressure_30tabs_swap': 'Whole-machine swap retained as information; shared-machine attribution is unavailable',
        'ui.*': 'Phase 2', 'fps.*': 'Phase 2', 'resume.*': 'Phase 2',
    })
    if not result['provenance'].get('exclusive_quit_interval'):
        result['blocked']['launch.warm_vs_cold'] = (
            'Optional: own-session quit gaps do not prove Arc stayed quit during other agents\u2019 sessions; raw comparisons retained without a score')
        for sample in result['samples']:
            sample['metrics'].pop('launch.warm_vs_cold', None)
    # Optional rows must meet the same N requirement. Never let an incomplete
    # optional warm/cold ratio qualify a primary baseline.
    for browser in ('arc', 'open'):
        for (_, key), row in metric_rows(result, browser).items():
            if row['summary']['n'] < required_n(key,result['provenance']) and key not in REQUIRED:
                result['blocked'][key] = 'Below the declared sample target; optional row pending'
                for sample in result['samples']:
                    sample['metrics'].pop(key, None)
    return result, manifests


def sessions(run):
    """Keep failed intents and pair exclusions beside conditional timings."""
    result = {}
    for browser in ('arc', 'open'):
        tasks = {}
        for task in sorted({s['task'] for s in run['samples']}):
            samples = [s for s in run['samples'] if s['browser'] == browser and s['task'] == task]
            failures = [s for s in samples if s.get('intent_failure') or
                        s.get('error') == 'LaunchServices did not produce an owned window']
            optional_failures = [s for s in failures if s.get('intent_failure_phase') == 'optional_immediate_relaunch']
            optional_attempts = sum('launch_gap_comparison' in s or
                                    s.get('intent_failure_phase') == 'optional_immediate_relaunch' for s in samples)
            tasks[task] = {
                'attempted_sessions': len(samples),
                'accepted_matched_sessions': sum(bool(s.get('valid')) for s in samples),
                'no_window_intent_failures': len(failures),
                'primary_no_window_intent_failures': len(failures) - len(optional_failures),
                'optional_relaunch_no_window_failures': len(optional_failures),
                'optional_relaunch_attempts': optional_attempts,
                'primary_no_window_failure_fraction': (len(failures)-len(optional_failures))/len(samples) if samples else None,
                'optional_relaunch_no_window_failure_fraction': len(optional_failures)/optional_attempts if optional_attempts else None,
                'no_window_failure_fraction': len(failures) / len(samples) if samples else None,
                'other_error_sessions': sum(bool(s.get('error')) and s not in failures for s in samples),
                'operator_interrupted_sessions': sum(bool(s.get('operator_interruption')) for s in samples),
                'pair_or_load_exclusions': sum(not s.get('valid') and not s.get('error') for s in samples),
                'cleanup_failures': sum(not s.get('cleanup') for s in samples),
            }
        result[browser] = tasks
    return result


def replay_manifest(manifests, cohort, run):
    destination = BASE.parent/'cohorts'/cohort
    destination.mkdir(parents=True, exist_ok=True)
    merged = None
    seen = set()
    for path, tasks in manifests:
        source = json.loads(path.read_text())
        if merged is None:
            merged = {k: copy.deepcopy(source[k]) for k in ('schema', 'port', 'navigation_origin', 'route_suffix')}
            merged.update(cohort=cohort, pairs=[])
        for key in ('port', 'navigation_origin', 'route_suffix'):
            if merged[key] != source[key]:
                raise ValueError('Private replay routing differs: ' + key)
        for pair in source['pairs']:
            if pair['task'] not in tasks:
                continue
            if not any(s.get('valid') and s['task']==pair['task'] and
                       s['round_index']==pair['index'] for s in run['samples']):
                continue
            ident = (pair['task'], pair['index'])
            if ident in seen:
                raise ValueError('Ambiguous private replay pair')
            seen.add(ident)
            link = destination/pair['snapshot']
            target = path.parent/pair['snapshot']
            if not link.exists():
                link.symlink_to(target.resolve(), target_is_directory=True)
            if sha(link/'State/browser.json') != pair['snapshot_browser_sha256']:
                raise ValueError('Private replay snapshot hash differs')
            merged['pairs'].append(pair)
    atomic(destination/'manifest.json', merged)


def context(run):
    out = {}
    for browser in ('arc', 'open'):
        accepted = [s for s in run['samples'] if s.get('valid') and s['browser'] == browser]
        out[browser] = {'accepted_sessions': len(accepted), 'memory': {}, 'window_counts': {},
                        'cpu_by_kind': {}, 'wakeups_by_kind_per_s': {}, 'footprint_by_kind_mib': {},
                        'launch_detector': {}}
        motion = [s for s in accepted if 'bench.motionmark' in s.get('metrics', {})]
        out[browser]['motionmark_configuration'] = {
            'reported_start_stages': [s['benchmark_start_stage'] for s in motion if s.get('benchmark_start_stage')],
            'unreported_configuration_sessions': sum(not s.get('benchmark_start_stage') for s in motion),
            'method': 'Unchanged official automatic frame-rate detection; pinned suite maps to at most 144 fps',
        }
        for name in ('1tab', '10tab', '30tab'):
            details = [s['mem_'+name+'_details'] for s in accepted if 'mem_'+name+'_details' in s]
            out[browser]['memory'][name] = {
                key: summarize([r[key] for r in details if key in r])
                for key in ('process_count', 'renderer_count', 'browser_share',
                            'focused_space_saved_tabs', 'focused_space_loaded_tabs')
            }
        for task in ('paint', 'core', 'window', 'bench-speedometer', 'bench-jetstream', 'bench-motionmark'):
            values = [len(s.get('window_bounds', [])) for s in accepted if s['task'] == task]
            if values:
                out[browser]['window_counts'][task] = summarize(values)
        values=[len(s['startup_windows']) for s in accepted if 'startup_windows' in s]
        if values:out[browser]['window_counts']['paint_after_visible_report']=summarize(values)
        core = [s for s in accepted if s['task'] == 'core']
        def evidence(sample, filename):
            receipts = [sample['source_receipt']] + [v['source'] for v in run.get('resumes', [])]
            for source in receipts:
                receipt = ROOT/source
                path = receipt.with_name(receipt.stem+'-samples') / (
                    f"{sample['round_index']:02}-{browser}-{sample['task']}") / filename
                if path.is_file():
                    return json.loads(path.read_text())
            return None
        window_samples = [s for s in accepted if s['task'] == 'window']
        launches = [evidence(s, 'launch-cold.json') or evidence(s, 'launch.json') for s in (window_samples or core)]
        launches = [v for v in launches if v]
        out[browser]['launch_detector'] = {
            key: summarize([v[key] for v in launches if key in v])
            for key in ('average_poll_hz', 'last_poll_gap_ms', 'poll_p50_ms', 'poll_p95_ms', 'poll_max_ms')
        }
        out[browser]['launch_detector']['every_session_at_least_250_hz'] = (
            bool(launches) and all(v.get('average_poll_hz', 0) >= 250 for v in launches))
        if window_samples:
            out[browser]['launch_audit'] = {
                'detector_version': max(v.get('detector_version',1) for v in launches), 'samples': len(launches),
                'windows_before_completion': sum(v.get('window_before_completion', False) for v in launches),
                'completion_observed': sum(v.get('completion_received', False) for v in launches),
                'completion_after_birth_ms': summarize([v['completion_after_birth_ms'] for v in launches if 'completion_after_birth_ms' in v]),
                'earlier_offscreen_or_zero_size': sum(any(not e['onscreen'] or e['bounds'][2] <= 0 or e['bounds'][3] <= 0 for e in v.get('window_timeline', [])) for v in launches),
                'first_offscreen_or_zero_after_birth_ms': summarize([min(e['after_birth_ms'] for e in v.get('window_timeline',[]) if not e['onscreen'] or e['bounds'][2]<=0 or e['bounds'][3]<=0) for v in launches if any(not e['onscreen'] or e['bounds'][2]<=0 or e['bounds'][3]<=0 for e in v.get('window_timeline',[]))]),
                'first_visible_after_birth_ms': summarize([v['window_ms'] for v in launches]),
                'restored_startup_reports': sum(bool(s.get('restored_startup_page')) for s in window_samples)}
        for label, metric in [('1tab', 'mem.idle_1tab_mib'), ('10tab', 'mem.10tabs_mib'),
                              ('30tab', 'mem.30tabs_mib')]:
            values = {}
            for sample in core:
                snapshot = evidence(sample, metric.replace('.', '-')+'.json')
                if snapshot:
                    grouped = {}
                    for process in snapshot['processes']:
                        kind = process['kind']
                        grouped[kind] = grouped.get(kind, 0) + process['footprint_bytes']/2**20
                    for kind, value in grouped.items():
                        values.setdefault(kind, []).append(value)
            out[browser]['footprint_by_kind_mib'][label] = {k: summarize(v) for k, v in values.items()}
        for label in ('static', 'hidden', '10tabs', 'animated'):
            values = {}
            wakeups = {}
            for sample in core:
                interval = evidence(sample, 'cpu-'+label+'.json')
                if interval:
                    grouped = {}
                    grouped_wakeups = {}
                    for process in interval['processes']:
                        kind = process['kind']
                        grouped[kind] = grouped.get(kind, 0) + process['cpu_pct']
                        grouped_wakeups[kind] = grouped_wakeups.get(kind, 0) + process['wakeups_per_s']
                    for kind, value in grouped.items():
                        values.setdefault(kind, []).append(value)
                    for kind, value in grouped_wakeups.items():
                        wakeups.setdefault(kind, []).append(value)
            out[browser]['cpu_by_kind'][label] = {k: summarize(v) for k, v in values.items()}
            out[browser]['wakeups_by_kind_per_s'][label] = {k: summarize(v) for k, v in wakeups.items()}
        swaps = [s['swap_30tabs'] for s in core if s.get('swap_30tabs')]
        out[browser]['swap_information'] = swaps
        out[browser]['saved_sidebar_counts'] = {
            key: summarize([s['pair_setup']['arc_counts'][key] for s in core if s.get('pair_setup')])
            for key in ('spaces', 'favorites', 'pinned', 'today', 'extensions_enabled')
        }
    return out


def reading(row, card):
    """A measured process split can locate a cost, but cannot prove its cause."""
    key = row['id']
    ctx = card['context']
    if key.startswith('mem.'):
        label = '30tab' if '30tabs' in key or 'per_tab' in key else '10tab' if '10tabs' in key else '1tab'
        pieces = []
        for browser in ('arc', 'open'):
            counts = ctx[browser]['memory'].get(label, {})
            renderers, share = counts.get('renderer_count'), counts.get('browser_share')
            if renderers and share:
                pieces.append(f"{browser}: median {renderers['median']:g} renderers, "
                              f"browser process {share['median']*100:.1f}% of footprint")
        return '; '.join(pieces) + '. Normal sleep policies are retained. A lifecycle or per-renderer cost difference is a candidate, not a proven cause.'
    if key.startswith(('cpu.', 'wakeups.')):
        label = 'hidden' if 'hidden' in key else 'animated' if 'animated' in key else '10tabs' if '10tabs' in key else 'static'
        field = 'wakeups_by_kind_per_s' if key.startswith('wakeups.') else 'cpu_by_kind'
        unit = ' wakeups/s' if key.startswith('wakeups.') else '%'
        pieces = []
        for browser in ('arc', 'open'):
            detail = ctx[browser][field].get(label, {})
            pieces.append(browser + ': ' + ', '.join(f"{kind} {v['median']:.3f}{unit}" for kind, v in sorted(detail.items())))
        return '; '.join(pieces) + '. These are common-process counter splits; total scores include reaped-child counters. No stack trace was collected, so the responsible code is unknown.'
    if key.startswith('bench.'):
        return 'The pinned official suite completed through the same reporter and matched CSS viewport. The result locates a workload gap; it does not distinguish engine, embedding or shell overhead.'
    if key.startswith('energy.'):
        return 'This is top\u2019s rounded POWER counter, summed over the initial process tree and averaged after its first frame. It is a proxy, not a physical energy measurement. No causal trace was collected.'
    if key.startswith('load.'):
        return 'The local reporter observes load/paint with network or cached subresources checked. Scheduling, rendering and cache state are candidates; no causal trace was collected.'
    if key.startswith('launch.'):
        return 'The shared launch detector measures the approved route. Startup state and window creation can affect it. No component-level timing trace establishes the cause.'
    return 'The size/count is measured directly. No causal attribution is established.'


def proof_coverage(card):
    result = {}
    for row in card['rows']:
        key = row['id']
        if card['negative_proofs'].get(key, {}).get('detected'):
            result[key] = {'status': 'DIRECT REAL-FLOW CONTROL', 'proof': key}
        elif key.startswith('mem.'):
            result[key] = {'status': 'COUNTER FAMILY ONLY; DERIVED ROW UNPROVED', 'proof': 'mem.footprint'}
        elif key.startswith('cpu.'):
            result[key] = {'status': 'COUNTER FAMILY ONLY; STATE-SPECIFIC ROW UNPROVED', 'proof': 'cpu.tree'}
        elif key.startswith('wakeups.'):
            result[key] = {'status': 'COUNTER FAMILY ONLY; IDLE ROW UNPROVED', 'proof': 'wakeups.tree'}
        elif key.startswith('launch.') and card['negative_proofs'].get('launch.detector', {}).get('detected'):
            result[key] = {'status': 'LAUNCH DETECTOR FAMILY ONLY; PRIMARY ROUTE UNPROVED', 'proof': 'launch.detector'}
        else:
            result[key] = {'status': 'NO QUALIFIED INJECTED-REGRESSION CONTROL'}
    return result


def preference_state():
    keys = ('SUEnableAutomaticChecks', 'SUAutomaticallyUpdate',
            'openExternalLinksInLittleBrowserEnabled')
    values = {}
    for key in keys:
        result = subprocess.run(['/usr/bin/defaults', 'read', 'company.thebrowser.Browser', key],
                                capture_output=True, text=True)
        values[key] = {'original_present': False, 'temporary_value': False,
                       'current_present': result.returncode == 0,
                       'current_value': result.stdout.strip() if result.returncode == 0 else None}
    receipts = []
    for path in sorted((ROOT/'.re/perf/setup').glob('arc-defaults-*.json')):
        receipts.append({'receipt': str(path.relative_to(ROOT)), 'sha256': sha(path)})
    return {'checked_date': now(), 'keys': values,
            'restored_to_original_absence': all(not v['current_present'] for v in values.values()),
            'receipts': receipts}


def stability(run):
    """Read only crash metadata; never export crash frames or other content."""
    directory = Path.home()/'Library/Logs/DiagnosticReports'
    intervals = {name: [(dt.datetime.fromisoformat(s['date']).timestamp(), s['quit_wall_seconds'])
                        for s in run['samples'] if s['browser'] == name and s.get('quit_wall_seconds')]
                 for name in ('arc', 'open')}
    first = min((start for ranges in intervals.values() for start, _ in ranges), default=0)
    counts = {'arc': 0, 'open': 0}
    unread = 0
    for parent in (directory, directory/'Retired'):
        paths = set(parent.glob('Arc*.ips')) | set(parent.glob('Open*.ips'))
        for path in paths:
            try:
                info = path.stat()
                if info.st_mtime < first:
                    continue
                if info.st_size > 64*1024*1024:
                    raise ValueError('metadata size bound')
                header, body = path.read_text().split('\n', 1)
                metadata = json.loads(header)
                event = json.loads(body)
                captured = event.get('captureTime', metadata.get('timestamp', ''))
                stamp = dt.datetime.fromisoformat(captured.replace('Z', '+00:00')).timestamp()
                process_path = event.get('procPath', '')
                for name, bundle in [('arc', ARC), ('open', OPEN)]:
                    if process_path.startswith(str(bundle)+'/') and any(start <= stamp <= end for start, end in intervals[name]):
                        counts[name] += 1
            except (ValueError, OSError, TypeError):
                unread += 1
    return {'checked_date': now(), 'matching_native_crash_reports': counts,
            'unread_recent_browser_reports': unread,
            'scope': 'User DiagnosticReports and Retired, Arc/Open filename prefixes; procPath must match the measured bundle and captureTime a recorded session interval',
            'qualification': 'Native .ips records only; absence of a record does not prove no crash. Renderer Crashpad-only events are not a complete census.',
            'session_cleanup_failures': sum(not s.get('cleanup') for s in run['samples'])}


def historical_information():
    path = ROOT/'.re/perf/open-empty-fast.json'
    if not path.is_file():
        return None
    old = json.loads(path.read_text())
    keys = {'launch.window_ms', 'launch.first_paint_ms', 'disk.app_mib', 'disk.main_binary_mib',
            'disk.fresh_profile_mib', 'load.static_ms.cold', 'load.static_ms.warm',
            'load.heavy_dom_ms.cold', 'load.heavy_dom_ms.warm'}
    return {'status': 'INFORMATION ONLY — OLDER DISPLAY; NOT A SCORE INPUT',
            'state': 'S-empty', 'date': old['date'], 'commit': old['provenance']['commit'],
            'display': old['provenance']['display'], 'source_receipt': str(path.relative_to(ROOT)),
            'source_sha256': sha(path),
            'qualification': 'Legacy preparation launch route; not the qualified S-real startup intent. S-empty memory/CPU attempts did not qualify.',
            'metrics': [v for (_, key), v in metric_rows(old, 'open').items() if key in keys]}


def render(card, run, interim):
    screen = run['provenance']['display']['screens'][0]
    lines = ['# Plan P — ' + ('INTERIM scored report 1' if card.get('in_progress') else
                             'interim report' if interim else 'report 1'), '',
             'Published: '+card['published_date']+'.', '',
             '**Phase 1 partial** — interaction, smoothness and resume await Phase 2.', '',
             f"Open overall: **{card['overall']:.1f}/10 clamped**; **{card['overall_raw']:.1f}/10 raw** "
             'over the measured category weights. '
             'Arc is fixed at **7.0** for every qualified reference row.', '',
             f"Arc **{run['provenance']['arc_version'][0]} ({run['provenance']['arc_version'][1]})**. "
             f"Arc runs Chromium {run['provenance'].get('arc_core', {}).get('version', '157.0.8103.51')}; Open runs Chromium 156.0.8078.48. This compares products with different engines. "
             f"Open Release `{run['provenance']['commit']}`. Engine SHA-256 "
             f"`{run['provenance']['engine_sha256']}`.", '',
             f"Display: AW2726DM, {screen['width']}×{screen['height']}, "
             f"{screen['scale']}×, {screen['refresh_hz']} Hz; ICC SHA-256 "
             f"`{screen['icc_sha256']}`. The display key is recorded in the JSON. "
             'Power: AC; the recorded AC power mode is 2 (not Low Power Mode).', '']
    if run['provenance'].get('arc_core'):
        lines += ['ArcCore binary SHA-256 `'+run['provenance']['arc_core']['binary_sha256']+'`. '+run['provenance'].get('arc_core_qualification','ArcCore version/hash guarded before and after each new session.'), '']
    if run['provenance'].get('cohort_build_note'):
        lines += [run['provenance']['cohort_build_note'], '']
    if not interim and not card.get('in_progress'):
        lines += ['**P1 cohort complete:** all required Phase 1 rows meet the declared '
                  'sample targets. The overall remains labelled Phase 1 partial because '
                  'Phase 2 is unmeasured. Optional and blocked rows, plus incomplete '
                  'negative-proof coverage, are disclosed below.', '']
    if run['provenance'].get('sampling_policy'):
        lines += ['Sample targets (LEAD 23:45): core timing, memory, CPU and page rows require '
                  '7 matched pairs. Web benchmarks require 3, extended to 5 when '
                  '`(max-min)/median` of the first three accepted results exceeds 5% in '
                  'either browser. Disk requires 1; the existing seven samples are retained.', '']
    lines += ['| Metric (S-real) | Unit | Arc median | Open median | Raw ratio r | Raw score | Category ratio | N A/O | Budget proxy |',
              '|---|---|---:|---:|---:|---:|---:|---|---|']
    for row in card['rows']:
        marker = ' ≈' if row['overlap'] else ''
        clamp_mark = ' †' if row['ratio_clamped'] else ''
        budget = row['budget']
        proxy = (f"{budget['numerical_status']} ({budget['distance']:+.3f} {row['unit']})"
                 if 'numerical_status' in budget else '—')
        lines.append(f"| {row['id']} | {row['unit']} | {row['arc']['median']:.3f} | "
                     f"{row['open']['median']:.3f} | {row['ratio']:.3f}{clamp_mark} | "
                     f"{row['computed_score']:.1f}{marker} | {row['category_ratio']:.3f} | {row['arc']['n']}/{row['open']['n']} | {proxy} |")
    lines += ['', '`≈` means that the p25–p75 intervals overlap. The computed score is shown; '
              'that row uses ratio 1 and score 7.0 in totals. Full p25/p75, min/max, dates, '
              'load1/5/15 ranges and commit are in the JSON. `†` marks a raw ratio outside '
              '[0.5, 2.0]; only its category contribution is bounded (LEAD 01:35).', '',
              '| Category | Clamped score | Raw score | Weight | Metrics |', '|---|---:|---:|---:|---:|']
    for name, row in card['categories'].items():
        value = f"{row['score']:.1f}" if row['score'] is not None else '**pending**'
        if row.get('status') == 'PARTIAL':
            value += ' (partial)'
        raw=f"{row['raw_score']:.1f}" if row['score'] is not None else '**pending**'
        lines.append(f"| {name} | {value} | {raw} | {row['weight']} | {row['metric_count']} |")
    policy = run['provenance'].get('sampling_policy', {})
    spreads = policy.get('web_first_three_relative_ranges', {})
    if spreads:
        lines += ['', '| Web benchmark | Required matched pairs | Arc first-three range | Open first-three range |',
                  '|---|---:|---:|---:|']
        for key, values in sorted(spreads.items()):
            ranges = [f"{values[b]*100:.2f}%" if b in values else 'pending' for b in ('arc', 'open')]
            lines.append(f"| {key} | {required_n(key, run['provenance'])} | {ranges[0]} | {ranges[1]} |")
    motion = {b: card['context'][b]['motionmark_configuration'] for b in ('arc', 'open')}
    if any(v['reported_start_stages'] for v in motion.values()):
        lines += ['', 'MotionMark 1.3 uses its unchanged automatic frame-rate detector. Its '
                  'pinned rate list stops at 144 fps, although the physical display is 240 Hz. '
                  'Reported configurations: ' + '; '.join(
                      b + ': ' + ', '.join(sorted(set(v['reported_start_stages']))) +
                      f" ({v['unreported_configuration_sessions']} earlier session(s) without rate telemetry)"
                      for b, v in motion.items()) + '.']
    launch_rows = {r['id']: r for r in card['rows'] if r['category'] == 'Launch'}
    if ({'launch.window_ms', 'launch.first_paint_ms'} <= launch_rows.keys() and
            card['categories']['Launch']['raw_score'] == 10.0 and
            launch_rows['launch.first_paint_ms']['computed_score'] < 7.0 and
            launch_rows['launch.window_ms']['ratio'] > 1.0):
        lines += ['', 'The Launch category uses both distinct routes. Its raw aggregate reached '
                  '10.0 because of the large plain-window ratio. Bounding each metric ratio '
                  'before the category mean limits that contribution. Neither route establishes '
                  'the architecture\u2019s confirmed-sidebar or restored-paint budget.']
    if card.get('in_progress'):
        lines += ['', '**INTERIM:** the pipeline is still running. Only rows that meet their '
                  'declared matched-sample targets receive a score. '
                  'The current overall score covers only those rows and categories. '
                  'It is not a completed Phase 1 result.', '',
                  '| Required row still pending | Accepted N Arc/Open | Target |', '|---|---:|---:|']
        for pending in card['pending_metrics']:
            lines.append(f"| {pending['id']} | {pending['arc_n']}/{pending['open_n']} | {pending['required_n']} |")
    lines += ['', '## Session outcomes', '',
              'Timing medians use successful, load-qualified matched pairs. A failed startup '
              'is retained in the denominator below; it is not assigned a finite latency. '
              'Arc’s fixed 7.0 is a timing reference, not a reliability score.', '',
              '| Browser / task | Attempts | Matched accepted | No-window failures (primary / optional relaunch) | Other errors | Pair/load exclusions |',
              '|---|---:|---:|---:|---:|---:|']
    for browser, tasks in card['session_outcomes'].items():
        for task, outcome in tasks.items():
            lines.append(f"| {browser} / {task} | {outcome['attempted_sessions']} | "
                         f"{outcome['accepted_matched_sessions']} | {outcome['primary_no_window_intent_failures']} / {outcome['optional_relaunch_no_window_failures']} | "
                         f"{outcome['other_error_sessions']} | {outcome['pair_or_load_exclusions']} |")
    lines += ['', 'A no-window failure means the app remained live and unhidden but did not '
              'produce an owned on-screen window within 60 seconds. Its cause is unknown. '
              'Both sides of that pair are excluded from latency totals. Cleanup, Arc build '
              'and display guards still apply to every attempt.']
    if any(s.get('intent_failure_phase') == 'optional_immediate_relaunch' for s in run['samples']):
        lines += ['', 'One Arc core session completed its primary measurements, then the optional '
                  'immediate-relaunch probe timed out without a window. The whole pair remains '
                  'excluded as originally recorded. This was not a failed primary plain launch. '
                  'Subsequent workers skip optional relaunch probes in both browsers, per '
                  'LEAD 16:00; primary workloads and detectors are unchanged. Optional relaunch '
                  'attempt denominators are retained separately in the JSON.']
    if any(s.get('operator_interruption') for s in run['samples']):
        lines += ['', 'One benchmark attempt was stopped by the harness after more than ten '
                  'minutes without a result or error callback (the earlier suite sessions took '
                  '25–30 seconds). Arc remained frontmost with one owned window. The interrupted '
                  'attempt is excluded from matched scores; no browser crash is inferred. Later '
                  'benchmark entry URLs include the matched starting-state hash, with fresh '
                  'reporter URLs and stage telemetry. The stall\u2019s cause remains unproved.']
    if any(s.get('error') == 'LaunchServices returned an existing process; refusing to adopt or quit it'
           for s in run['samples']):
        lines += ['', 'One Open launch was interrupted because LaunchServices returned a process '
                  'already started by another checkout. The helper refused to adopt or quit '
                  'that process. This ownership interruption and its Arc counterpart are '
                  'excluded; it is not classified as an Open crash. The resumed worker now '
                  'checks for other-checkout Open processes before requesting launch.']
    lines += ['', '| Observed owned-window counts | Arc min–max | Open min–max |',
              '|---|---:|---:|']
    for label,key in [('Startup: first window detection','paint'),
                      ('Startup: after visible page report','paint_after_visible_report'),
                      ('Plain core launch','core')]:
        values=[card['context'][browser]['window_counts'].get(key) for browser in ('arc','open')]
        text=[f"{int(v['min'])}–{int(v['max'])}" if v else 'pending' for v in values]
        lines.append(f'| {label} | {text[0]} | {text[1]} |')
    lines += ['', '| Plain-launch detector | N | Average polling Hz min–max | Largest final detection gap (ms) |',
              '|---|---:|---:|---:|']
    for browser, data in card['context'].items():
        detector = data['launch_detector']
        rate, gap = detector.get('average_poll_hz'), detector.get('last_poll_gap_ms')
        if rate and gap:
            lines.append(f"| {browser} | {rate['n']} | {rate['min']:.1f}–{rate['max']:.1f} | {gap['max']:.3f} |")
    lines += ['', ('The corrected helper targets a 0.1 ms polling interval. ' if run['provenance'].get('window_row_revision') else 'The helper targets a 1 ms polling interval. ') + 'The final poll gap bounds the '
              'window-list sampling delay; window-list visibility is not proof of a presented '
              'sidebar frame. Full per-session polling-gap summaries remain in the raw receipts.', '',
              *([
                  'Arc plain launch: the old receipts list a 6.4 s process-birth-to-window median but did not observe before the LaunchServices callback or retain off-screen states; that series cannot establish what appeared earlier. The revised row alone is remeasured at N=7 (Arc 2319.491 ms, Open 342.168 ms).',
                  'In the revised Arc receipts, LaunchServices returns at 86.9–158.5 ms; zero-size/off-screen owned windows first appear at 434.3–589.7 ms, then one 1884×1030 on-screen window at 2274.0–2446.2 ms. No window precedes the callback, and the selected saved session produces no fresh startup-page report; no internal cause or cause for the old/new difference is assigned.', ''
              ] if run['provenance'].get('window_row_revision') else []),
              'Scoring: `clamp(7 + 3 log2(r), 0, 10)`, one decimal. '
              'For lower-is-better rows `r=Arc/Open`; higher-is-better rows use `Open/Arc`. '
              'Categories use the geometric mean of effective ratios. Overall uses the '
              'plan weights for measured categories only. CPU adds ε=0.1 percentage point '
              'and wakeups add ε=1/s to both browsers before division. POWER adds ε=0.1 '
              'of top’s reported unit because that counter is rounded to tenths.', '',
              '## Absolute budgets', '',
              '| Open proxy | Limit | Distance | Numerical result | Qualification |',
              '|---|---:|---:|---|---|']
    for row in card['rows']:
        budget = row['budget']
        if 'limit' in budget:
            lines.append(f"| {row['id']} | {budget['limit']} | {budget['distance']:+.3f} | "
                         f"{budget['numerical_status']} | Different fixture; no architecture acceptance |")
    lines += ['', 'The 250 ms budget requires a confirmed sidebar frame; this detector sees '
              'the first listed window. The 700 ms budget requires a restored-tab paint; '
              'this run uses an external URL startup request. The 0.5% CPU budget uses '
              'the Section 8 ordered ten-page fixture with different settle/sample lengths. '
              'Memory, disk and web benchmarks have no separate numeric architecture budget.', '',
              '## Five lowest Open scores', '']
    for row in sorted(card['rows'], key=lambda r: (r['computed_score'], r['id']))[:5]:
        lines.append(f"- `{row['id']}`: **{row['computed_score']:.1f}**; "
                     f"Arc {row['arc']['median']:.3f}, Open {row['open']['median']:.3f} {row['unit']}. "
                     + reading(row, card))
    lines += ['', '## Process and memory context', '',
              '| Browser / visited pages | Context N | Processes median | Renderers median | Browser share |',
              '|---|---:|---:|---:|---:|']
    for browser, data in card['context'].items():
        for label, values in data['memory'].items():
            if not values.get('process_count'):
                continue
            lines.append(f"| {browser} / {label} | {values['process_count']['n']} | {values['process_count']['median']:g} | "
                         f"{values['renderer_count']['median']:g} | {values['browser_share']['median']*100:.1f}% |")
    lines += ['', 'Per-kind footprint, CPU and wakeup splits, saved/loaded counts, and machine-wide '
              'swap observations are in the scorecard context. Process-common CPU splits '
              'do not include costs of exited processes; the scored whole-tree total does.', '',
              '## Stability observations', '',
              f"Matching native crash reports: Arc {card['stability']['matching_native_crash_reports']['arc']}, "
              f"Open {card['stability']['matching_native_crash_reports']['open']}. "
              f"Session cleanup failures: {card['stability']['session_cleanup_failures']}. "
              f"Unread recent browser reports: {card['stability']['unread_recent_browser_reports']}.", '',
              card['stability']['scope']+'. '+card['stability']['qualification'], '',
              '## Load ranges', '', '| Browser | Load1 min–max | Load5 min–max | Load15 min–max |',
              '|---|---:|---:|---:|']
    for browser, field in [('arc', 'arc_load_range'), ('open', 'load_range')]:
        ranges = [[min(row[field][i][0] for row in card['rows']),
                   max(row[field][i][1] for row in card['rows'])] for i in range(3)]
        lines.append('| '+browser+' | '+' | '.join(f'{low:.2f}–{high:.2f}' for low, high in ranges)+' |')
    lines += ['', '## Method and limits', '',
              '- Each pair starts from Arc while quit. Open uses the real Settings Import from Arc flow. '
              'Count-only live checks require equal Spaces, Favorites, pinned and Today counts. '
              'A private source view only reorders Arc’s global-container map for the current importer. '
              'Original Arc inputs remain read-only outside its sessions.',
              '- Arc external URLs add tabs. Saved sidebar counts therefore grow across pairs. '
              'Every private Open starting snapshot is saved and hashed for exact Open-only replay. '
              '“1/10/30” means newly visited synthetic pages in addition to that matched saved sidebar. '
              'It does not mean an empty browser or thirty resident renderers.',
              '- Normal main-workload sessions use one browser window each. The approved first-paint '
              'route uses the same default LaunchServices URL startup intent with a unique synthetic '
              'token. Its observed window counts are disclosed above. Plain launch does not reload Arc’s selected local page. '
              'No restored-page reload is claimed.',
              '- Page and benchmark pairs match the actual CSS viewport. Arc keeps its restored bounds; '
              'Open adjusts its outer frame through the socket. Display dimensions, refresh, scale and '
              'ICC SHA-256 are frozen in the reference.',
              '- Every visible sample holds the on-screen lock. Earlier sessions also held the '
              'shared quiet lock; FIFO resumes delegate build exclusion to heavy.sh, one ticket '
              'per browser session. Queue v3 takes all three M5 build slots exclusively. '
              'Load1 ceiling is 10; waiting holds no measurement slot or screen lock. Before/after load averages and '
              'in-session checkpoints remain in raw receipts. Over-limit attempts are excluded, never deleted.',
              '- Memory sums process-tree physical footprints after 60 seconds. CPU and wakeups use '
              '120-second kernel-counter deltas; one core is 100%. Live and reaped-child counters '
              'retain exited helpers. Hidden-state runs use the same NSRunningApplication helper in both apps.',
              '- The static CPU window is T+60 to T+180 seconds after the initial visible page. '
              'Hidden, ten-tab and animated windows follow in a fixed order. A fall in CPU later '
              'in the session can reflect startup work ending as well as a visibility or workload change; '
              'these windows do not isolate those causes.',
              '- Cold/warm page rows refer to observed network/cached subresources. HTML documents '
              'are served without caching. These are local fixture loads, not internet navigation or '
              'browser disk-cold measurements.',
              '- Arc’s original 1.170.0 (89123) backup was copied and verified before the first launch. '
              'It remains untouched and was never restored or launched after Arc updated. The performance '
              'reference is the lead-approved installed 1.172.2 (90755), guarded before/after each session.',
              '- Temporary Arc defaults are SUEnableAutomaticChecks=false, SUAutomaticallyUpdate=false, '
              'and openExternalLinksInLittleBrowserEnabled=false. All originals were absent. '
              + ('All three keys are now absent again; restoration passed.' if card['arc_preferences']['restored_to_original_absence'] else
                 'The authorized temporary values remain applied while the cohort runs; restoration is pending.')
              + ' Preference-state checks and receipt hashes are in the JSON.', '',
              '## Negative proofs', '']
    for name, proof in card.get('negative_proofs', {}).items():
        lines.append(f"- `{name}`: {'DETECTED' if proof.get('detected') else 'UNQUALIFIED'}; "
                     f"{proof.get('injection', '')}. "
                     + ', '.join(f'{k}={v}' for k, v in proof.items()
                                 if k not in ('detected', 'injection', 'before', 'after')))
    lines += ['', 'Fault samples never enter the reference or scorecard. '
              'Counter-family controls do not independently qualify every derived metric. '
              'Any unproved row remains listed in the negative-proof coverage metadata.', '',
              '| Negative-proof coverage | Metric rows |', '|---|---|']
    for status in sorted({v['status'] for v in card['negative_proof_coverage'].values()}):
        keys = [key for key, value in card['negative_proof_coverage'].items() if value['status'] == status]
        lines.append(f"| {status} | " + ', '.join('`'+key+'`' for key in keys) + ' |')
    lines += ['', 'Negative-proof coverage is incomplete. Numerical N qualification and '
              'injected-regression qualification are separate fields in the JSON.', '',
              '## Pending and excluded', '']
    for name, reason in sorted(run['blocked'].items()):
        lines.append(f'- `{name}`: {reason}.')
    lines += ['', '## Earlier-display appendix — excluded from scoring', '',
              'The earlier 1920×1080, 1×, 60 Hz cohort is retained privately in '
              '`.re/perf/paired-paint-bench-4.json` and its sample directory. '
              'Its seven Speedometer pairs were Arc 54.776 / Open 35.857 median. '
              'These are historical numbers only. They supply no row or ratio '
              'to the AW2726DM reference. The interrupted '
              '`.re/perf/paired-core-1.json` stopped at the display change and '
              'has no accepted core sample. Earlier Open S-empty preparation '
              'also belongs to the old display and remains unscored information.']
    old = card.get('historical_open_empty')
    if old:
        lines += ['', 'Open S-empty historical information: **1920×1080, 1×, 60 Hz**. '
                  'These rows have no Arc counterpart, ratio or score. '+old['qualification'], '',
                  '| Historical Open S-empty metric | Median | Unit | N |', '|---|---:|---|---:|']
        for row in old['metrics']:
            lines.append(f"| {row['id']} | {row['summary']['median']:.3f} | {row['unit']} | {row['summary']['n']} |")
        lines += ['', f"Evidence: [{old['source_receipt']}]({ROOT/old['source_receipt']}); "
                  f"SHA-256 `{old['source_sha256']}`."]
    lines += ['', '## Evidence', '']
    for source in run['provenance']['source_receipts']:
        lines.append(f"- Raw receipt: [{source['receipt']}]({ROOT/source['receipt']}); "
                     f"SHA-256 `{source['sha256']}`. Adjacent `*-samples/` directories hold "
                     'the launch, memory, CPU, load and cleanup receipts.')
    if card.get('in_progress'):
        lines += ['', 'Pipeline continues. This interim report will be replaced as more rows qualify. '
                  'Phase 2 has not started.']
    elif interim:
        lines += ['', 'Web benchmark completion is still running or queued. This is the requested '
                  'Launch/Memory/Idle CPU/Disk interim report, not the final P1 handoff.']
    else:
        lines += ['', 'P1 measurement handoff — stop for lead review.']
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', action='append', required=True, help='RECEIPT:TASK,TASK')
    parser.add_argument('--negative', action='append', type=Path, default=[])
    parser.add_argument('--window-control',type=Path,help='Real plain-launch startup-delay control for the revised observer')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--plans', type=Path, default=PLANS)
    parser.add_argument('--interim', action='store_true')
    parser.add_argument('--progress', action='store_true', help='Publish scored qualified rows in P-report-1 while the cohort continues; do not freeze the permanent reference')
    args = parser.parse_args()
    inputs = []
    for value in args.input:
        path, tasks = value.rsplit(':', 1)
        inputs.append((Path(path).resolve(), tasks.split(',')))
    run, manifests = joined(inputs)
    rows = {name: metric_rows(run, name) for name in ('arc', 'open')}
    required = REQUIRED - ({'bench.speedometer', 'bench.jetstream', 'bench.motionmark'} if args.interim else set())
    missing = [f'{name}:{key}' for name in rows for key in required
               if rows[name].get(('S-real', key), {}).get('summary', {}).get('n', 0) < required_n(key,run['provenance'])]
    if missing and not args.progress:
        raise SystemExit('Incomplete required N: ' + ', '.join(sorted(missing)))
    proofs = {}
    normal_launch = []
    fault_launch = []
    for path in args.negative:
        negative = json.loads(path.read_text())
        for key in ('hardware', 'os', 'display', 'commit', 'app_main_sha256', 'engine_sha256'):
            if negative['provenance'][key] != run['provenance'][key]:
                raise SystemExit('Negative-control receipt has different '+key)
        for sample in negative.get('samples', []):
            for key, value in sample.get('negative_proofs', {}).items():
                proofs[key] = {k: v for k, v in value.items() if k not in ('before', 'after')}
            value = sample.get('metrics', {}).get('launch.window_ms', {}).get('value')
            if value is not None and sample.get('cleanup') and max(sample['load_before'][0], sample['load_after'][0]) <= negative['provenance']['max_load1']:
                if sample.get('mode') == 'negative-launch':
                    fault_launch.append(value)
                elif sample.get('mode') == 'negative':
                    normal_launch.append(value)
    if normal_launch and fault_launch:
        delta = statistics.median(fault_launch)-statistics.median(normal_launch)
        proofs['launch.detector'] = {
            'injection': 'Separate 200 ms startup-constructor dylib in real Open S-empty launches',
            'normal_n': len(normal_launch), 'fault_n': len(fault_launch),
            'normal_median_ms': statistics.median(normal_launch),
            'fault_median_ms': statistics.median(fault_launch), 'delta_ms': delta,
            'detected': delta >= 100,
            'qualification': 'Detector-family evidence only: a single normal control; startup-page argument route differs from the primary plain/URL intents',
        }
    if args.window_control:
        control=json.loads(args.window_control.read_text())
        if not control.get('valid'):raise SystemExit('Window control did not qualify')
        for key in ('hardware','os','display','commit','app_main_sha256','engine_sha256'):
            if control['provenance'][key]!=run['provenance'][key]:raise SystemExit('Window control differs: '+key)
        proofs['launch.detector']={
            'injection':'Separate 200 ms startup-constructor dylib, real plain Open S-empty launch; revised observer v3',
            'normal_n':control['normal']['n'],'fault_n':control['delayed']['n'],
            'normal_median_ms':control['normal']['median'],'fault_median_ms':control['delayed']['median'],
            'delta_ms':control['median_delta_ms'],'detected':control['detected'],
            'source':str(args.window_control),'source_sha256':sha(args.window_control),
            'qualification':'Same plain-launch observer/route; S-empty detector-family proof, not the S-real workload'}
    run['negative_proofs'] = proofs
    cohort = 'p1-' + run['date'].replace(':', '').replace('+', '').replace('.', '')
    run['provenance']['replay_cohort'] = cohort
    run['provenance']['replay_tasks'] = list(dict.fromkeys(task for _, tasks in inputs for task in tasks))
    if not args.interim and not args.progress:
        replay_manifest(manifests, cohort, run)
    atomic(args.out, run)
    scoring_run = copy.deepcopy(run)
    pending = []
    if args.progress:
        for key in sorted(REQUIRED):
            counts = {b: rows[b].get(('S-real', key), {}).get('summary', {}).get('n', 0)
                      for b in ('arc', 'open')}
            target=required_n(key,run['provenance'])
            if min(counts.values()) < target:
                pending.append({'id': key, 'category': category(key),
                                'arc_n': counts['arc'], 'open_n': counts['open'], 'required_n':target})
        qualified = {key for key in rows['arc'] if min(rows[b].get(key, {}).get('summary', {}).get('n', 0)
                                                      for b in ('arc', 'open')) >= required_n(key[1],run['provenance'])}
        for sample in scoring_run['samples']:
            sample['metrics'] = {key: value for key, value in sample['metrics'].items()
                                 if (sample['state'], key) in qualified}
        if not qualified:
            raise SystemExit('No qualified interleaved row to score yet')
    reference = freeze(scoring_run)
    reference['context'] = context(run)
    card = compare(reference, scoring_run)
    card['context'] = reference['context']
    card['display'] = reference['display']
    card['arc_preferences'] = preference_state()
    card['stability'] = stability(run)
    card['historical_open_empty'] = historical_information()
    card['reference_date'] = reference['date']
    card['arc_version'] = reference['arc_version']
    card['arc_build'] = reference['arc_build']
    card['session_outcomes'] = sessions(run)
    card['intent_failures'] = run['intent_failures']
    card['resumes'] = run['resumes']
    card['latency_qualification'] = 'Conditional on successful startup; all intent failures retained with denominators'
    card['negative_proof_coverage'] = proof_coverage(card)
    reference['session_outcomes'] = card['session_outcomes']
    reference['intent_failures'] = card['intent_failures']
    reference['latency_qualification'] = card['latency_qualification']
    reference['negative_proof_coverage'] = card['negative_proof_coverage']
    reference['stability'] = card['stability']
    card['status'] = 'INTERIM — COHORT RUNNING' if args.progress else 'INTERIM' if args.interim else 'P1 — LEAD REVIEW'
    card['in_progress'] = args.progress
    card['published_date'] = now()
    card['pending_metrics'] = pending
    if args.progress:
        for name, weight in WEIGHTS.items():
            if name not in card['categories']:
                card['categories'][name] = {'score': None, 'weight': weight, 'metric_count': 0, 'status': 'PENDING'}
            else:
                card['categories'][name]['status'] = 'PARTIAL' if any(v['category'] == name for v in pending) else 'QUALIFIED'
    args.plans.mkdir(parents=True, exist_ok=True)
    if args.interim:
        (args.plans/'P-report-0.md').write_text(render(card, run, True))
        atomic(args.out.with_name(args.out.stem+'-scorecard.json'), card)
    else:
        if not args.progress:
            atomic(ROOT/'docs/perf/arc-reference-m5.json', reference)
        atomic(args.plans/'P-scorecard-1.json', card)
        (args.plans/'P-report-1.md').write_text(render(card, run, False))
    print(json.dumps({'status': card['status'], 'overall': card['overall'],
                      'metrics': len(card['rows']), 'categories': card['categories']}))


if __name__ == '__main__':
    main()
