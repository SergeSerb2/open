#!/usr/bin/env python3
"""Publish Phase 2 with explicit carried-row and current-build provenance."""
import argparse
import copy
import json
import statistics
from pathlib import Path
from campaign import MAIN_DELTA
from run import ROOT, PLANS, atomic, now, sha
from score import WEIGHTS, compare, freeze, metric_rows

REQUIRED_UI={'ui.tab_switch_ms','ui.new_tab_ms','ui.cmdbar_keystroke_ms','ui.cmdbar_keystroke_p95_ms','ui.space_switch_ms',
 'ui.sidebar_toggle_ms','ui.split_open_ms','ui.peek_open_ms','ui.library_open_ms','ui.settings_open_ms','ui.window_new_ms'}
REQUIRED_RESUME={'resume.sleeping_tab_ms','resume.app_unhide_ms'}
SCENARIOS=('sidebar_scroll','space_swipe','page_scroll_article','commandbar_open_close','sidebar_collapse_expand')
REQUIRED_FPS={f'fps.{name}.{suffix}' for name in SCENARIOS for suffix in ('late_pct','p95_ms','p99_ms','longest_stall_ms')}

def main():
    p=argparse.ArgumentParser();p.add_argument('--phase2',type=Path,required=True);p.add_argument('--delta',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();phase=json.loads(a.phase2.read_text());delta=json.loads(a.delta.read_text())
    if phase.get('calibration_only'):raise RuntimeError('Unscored calibration cannot be published as Phase 2')
    space_scenario='space_change_keyboard' if phase['provenance']['space_transition_route']['scored_route']=='keyboard' else 'space_swipe'
    required_fps={f'fps.{name}.{suffix}' for name in ('sidebar_scroll',space_scenario,'page_scroll_article','commandbar_open_close','sidebar_collapse_expand')
                  for suffix in ('late_pct','p95_ms','p99_ms','longest_stall_ms')}
    pinned=json.loads((ROOT/'.re/perf/aw2726dm-accepted-window-v3.json').read_text())
    for key in ('commit','engine_sha256'):
        if phase['provenance'][key]!=delta['provenance'][key]:raise RuntimeError('Delta and Phase 2 are different builds')
    exception=phase['provenance']['delta_artifact_exception']
    if (delta['provenance']['app_main_sha256']!=exception['delta_app_sha256'] or
        phase['provenance']['app_main_sha256']!=exception['phase2_app_sha256']):
        raise RuntimeError('Artifact mismatch outside LEAD 05:00 exception')
    paired=copy.deepcopy(phase)
    for task in {s['task'] for s in paired['samples']}:
        good={s['round_index'] for s in paired['samples'] if s['task']==task and all(any(v['task']==task and v['round_index']==s['round_index'] and v['browser']==name and v.get('valid') for v in paired['samples']) for name in ('arc','open'))}
        for s in paired['samples']:
            if s['task']==task and s['round_index'] not in good:s['valid']=False;s['pair_excluded']=True
    arc_rows=metric_rows(paired,'arc');open_rows=metric_rows(paired,'open')
    expected=REQUIRED_UI|REQUIRED_RESUME|required_fps
    unqualified=[name+':'+key for name,rows in (('arc',arc_rows),('open',open_rows))
                 for key in sorted(expected)
                 if rows.get(('S-real',key),{}).get('summary',{}).get('n',0)<7]
    if unqualified:raise RuntimeError('Phase 2 has unfinished rows: '+','.join(unqualified))
    for sample in paired['samples']:
        if sample.get('valid') and sample['browser']=='open' and sample['task']=='interaction' and sample.get('input_boundary_version',1)<2:
            raise RuntimeError('Open interaction sample predates the corrected socket-dispatch boundary')
        if sample.get('valid') and sample['browser']=='arc' and sample['task']=='resume':
            override=sample.get('debug_pages_override',{})
            if (override.get('original_enabled') is not False or not override.get('enabled_confirmed') or
                sample.get('debug_pages_restored') is not True):
                raise RuntimeError('Arc resume lacks a complete debugging-setting restoration receipt')
    delta_rows=metric_rows(delta,'open')
    if any(delta_rows.get(('S-real',key),{}).get('summary',{}).get('n',0)<5 for key in MAIN_DELTA):
        raise RuntimeError('Main delta has unfinished rows')
    base=ROOT/'.re/perf/phase2-reference-base.json'
    if not base.exists():base.write_bytes((ROOT/'docs/perf/arc-reference-m5.json').read_bytes())
    reference=json.loads(base.read_text());new_reference=freeze(paired)
    oldkeys={(r['state'],r['id']) for r in reference['metrics']}
    if any((r['state'],r['id']) in oldkeys for r in new_reference['metrics']):raise RuntimeError('Phase 2 must not replace a Phase 1 Arc row')
    reference['metrics'].extend(new_reference['metrics'])
    reference['provenance']['phase2']={'date':phase['date'],'source':str(a.phase2.resolve().relative_to(ROOT)),'sha256':sha(a.phase2),'arc_core':phase['provenance']['arc_core'],'detector':phase['provenance'].get('detector'), 'base_reference_sha256':sha(base)}
    composite={'schema':1,'date':now(),'provenance':copy.deepcopy(phase['provenance']),'samples':[],'blocked':copy.deepcopy(phase.get('blocked',{}))}
    composite['provenance']['sampling_policy']=copy.deepcopy(pinned['provenance']['sampling_policy'])
    composite['provenance']['sampling_policy']['metric_required_n'].update({k:5 for k in MAIN_DELTA})
    for sample in pinned['samples']:
        if sample['browser']!='open':continue
        s=copy.deepcopy(sample);s['metrics']={k:v for k,v in s['metrics'].items() if k not in MAIN_DELTA}
        s['commit']=pinned['provenance']['commit'];s['app_main_sha256']=pinned['provenance']['app_main_sha256']
        if s['metrics']:composite['samples'].append(s)
    for source in (delta,paired):
        for sample in source['samples']:
            if sample['browser']!='open':continue
            s=copy.deepcopy(sample);s['commit']=source['provenance']['commit'];s['app_main_sha256']=source['provenance']['app_main_sha256'];composite['samples'].append(s)
    score=compare(reference,composite)
    # These are numerical comparisons only. The detector records the first
    # changed image, not a verified fully presented surface or every scanout.
    proxies={
        'ui.tab_switch_ms':(16.,'First changed content; selected live target verified after input'),
        'ui.new_tab_ms':(50.,'First changed app image after Cmd+T; first results not independently timed'),
        'fps.sidebar_scroll.late_pct':(0.,'Observed late changed-image intervals at the 8.3 ms detector rate'),
    }
    for row in score['rows']:
        if row['id'] not in proxies:continue
        limit,qualification=proxies[row['id']];value=row['open']['median']
        row['budget']={'source':'docs/architecture.md:75','limit':limit,'distance':value-limit,
            'numerical_status':'PASS' if value<=limit else 'FAIL',
            'status':'DETECTOR / FIXTURE PROXY; NOT FULL BUDGET ACCEPTANCE',
            'qualification':qualification}
    protocol=ROOT/'.re/perf/phase2-protocol-v2/manifest.json'
    score['measurement_protocol']={'path':str(protocol.relative_to(ROOT)),
        'sha256':sha(protocol),'report_generator_sha256':sha(Path(__file__)),
        'qualification':'Measurement sources stayed frozen through cohort completion; publication adds budget annotations without changing scores'}
    ids={r['id'] for r in score['rows'] if r['qualified']}
    missing=sorted((REQUIRED_UI|REQUIRED_RESUME|required_fps)-ids)
    smooth={k for k in ids if k.startswith('fps.')}
    complete=set(score['categories'])==set(WEIGHTS) and not missing and bool(smooth)
    score.update(label='Phase 2 complete' if complete else 'Phase 2 incomplete',status='COMPLETE' if complete else 'INCOMPLETE',
                 provenance=phase['provenance'],missing_required_rows=missing,
                 carried_pinned_commit=pinned['provenance']['commit'],main_delta=PLANS.joinpath('P-scorecard-1.json').name,
                 raw_receipts=[str(a.phase2),str(a.delta)],reference_sha256=None)
    score['phase2_attempts']={}
    for task in sorted({s['task'] for s in paired['samples']}):
        score['phase2_attempts'][task]={}
        for name in ('arc','open'):
            samples=[s for s in paired['samples'] if s['task']==task and s['browser']==name]
            score['phase2_attempts'][task][name]={'attempted':len(samples),
                'qualified':sum(bool(s.get('valid')) for s in samples),
                'excluded':sum(not s.get('valid') for s in samples),
                'reasons':[s.get('error') or s.get('boundary_invalidation') or ('unmatched counterpart' if s.get('pair_excluded') else 'qualification refused')
                           for s in samples if not s.get('valid')]}
    atomic(ROOT/'docs/perf/arc-reference-m5.json',reference);score['reference_sha256']=sha(ROOT/'docs/perf/arc-reference-m5.json')
    atomic(a.out,composite);atomic(PLANS/'P-scorecard-2.json',score)
    prov=phase['provenance'];core=prov['arc_core'];build=json.loads((ROOT/'.re/perf/phase2-build.json').read_text())
    boundary_excluded=sum(bool(s.get('boundary_invalidation')) for s in paired['samples'])
    control_path=ROOT/'.re/perf/phase2-control-corrected/qualified-controls.json'
    controls=json.loads(control_path.read_text())
    score['phase2_negative_proofs']={'source':str(control_path.relative_to(ROOT)),
        'sha256':sha(control_path),'results':controls,
        'coverage':'Shared colour-latency and continuous-pacing detector; native page-scroll route and invalid input refusal. Not an independent fault injection for every UI intent or discarded-tab resume.'}
    lines=['# Arc / Open performance — Phase 2','',f"**{score['status']}: {score['overall']}/10 clamped; {score['overall_raw']}/10 raw.** Arc is fixed at 7.0.",'',
       f"Arc {prov['arc_version'][0]} ({prov['arc_version'][1]}), ArcCore / Chromium **{core['version']}**; Open Chromium **156.0.8078.48**. This compares products with different engines. Open uses the existing developer engine build without PGO/ThinLTO.",'',
       f"Main Release `{prov['commit']}`; app SHA-256 `{prov['app_main_sha256']}`; engine SHA-256 `{prov['engine_sha256']}`. Automation scroll patch SHA-256 `{build['automation_patch_sha256']}`.",'',
       f"LEAD 05:00 artifact exception: the completed main delta retains app SHA-256 `{exception['delta_app_sha256']}`. All scored Phase 2 rows use corrected app SHA-256 `{exception['phase2_app_sha256']}`. Only the automation adapter's finger-phase mapping changed; correction patch SHA-256 `{exception['phase_fix_sha256']}`. The hook was inert in every delta session.",'',
       f"ArcCore binary SHA-256 `{core['binary_sha256']}`. Every Phase 2 session checks bundle version, ArcCore version/hash, display and Open artifact hashes before/after.",'',
       'AW2726DM, 2560×1440, 1×, 240 Hz. **The shared detector resolves 8.3 ms (about 120 frames/s); drops shorter than that are not seen. These results do not establish 240 Hz frame delivery.** Native-rate capture was tried; its measured median remains 8.334 ms.','',
       'Exclusive FIFO sessions, one browser session per ticket; load1 ceiling 10. Arc receives system events; Open receives socket actions and own-window native events. The same app-scoped ScreenCaptureKit detector measures both. Input-to-first-frame latency includes different routing costs. Scroll/swipe latency is informative; pacing carries the score.','',
       'Before each Arc session, Open performs a fresh real import of the saved Arc sidebar within the same lock hold. Its exact private starting state is preserved for the immediately following Open session. Both add the same synthetic workload and match the content viewport; saved tabs and native sleep policies remain in place. The counts and bounds in the receipts define each pair.','',
       'Tab switching uses Ctrl+Tab and modifier release, with the expected synthetic page verified before and after. Command-bar p50/p95 comes from a fixed 40-character sequence of one-character queries; each query is cleared outside its timed interval. The long appended-query calibration is unscored because result text eventually truncates.','',
       f'Open key/text timestamps are taken immediately before the actual socket call. Preflight and target discovery run before that boundary. {boundary_excluded} earlier Open interaction samples included preflight cost and are excluded with their unmatched Arc counterparts; replacement pairs use boundary version 2. Arc uses its instrumented posted CGEvent timestamps.','',
       'Synthetic page geometry is resolved with temporary process-level AXManualAccessibility and restored before scored input. The unreadable original and successful explicit false restore are recorded. AXEnhancedUserInterface and other Arc defaults are untouched. Web reads are limited to synthetic fixtures, internal debugging controls and the discards page, depth 30, 3,000 nodes and 3 seconds. This is a software capture comparison, not physical input-to-scanout latency.','',
       'Arc disables its internal debugging pages by default. For discarded-tab resume only, user approval at 06:14 permits the real chrome://chrome-urls enable control. Each session records the disabled original, confirms enable, uses the synthetic tab\'s urgent-discard control, and confirms disabled again before Arc quits, including failure cleanup. The override is absent from interaction and smoothness runs.','',
       'The stored internal_only_uis_enabled state is checked after each later Arc launch, before any override, as required by LEAD 06:20. Arc resume confirms a one-count discard increment and unloaded state in the exact synthetic row; Open uses its own sleep/discard route on the same fixture. Both require a fresh page report and the known nonblank content signature.','',
       'Unhide requires the native hidden flag and zero visible owned windows before input. ScreenCaptureKit can retain the old visible image while the app is hidden; that cached baseline may equal the target. Only fresh capture timestamps after unhide count toward the known-content latency.','',
       f"The eight ruled launch/idle delta rows and all new Phase 2 rows use `{prov['commit'][:8]}`. Other Phase 1 rows retain `{pinned['provenance']['commit'][:8]}` and their original dates/hashes. No old benchmark, memory or disk value is relabeled as main.",'',
       '| Category | Clamped | Raw | Weight | Rows |','|---|---:|---:|---:|---:|']
    for cat,weight in WEIGHTS.items():
        s=score['categories'].get(cat)
        lines.append(f"| {cat} | {s['score'] if s else 'pending'} | {s['raw_score'] if s else 'pending'} | {weight} | {s['metric_count'] if s else 0} |")
    lines.extend(['','| Phase 2 attempts | Arc attempted / qualified / excluded | Open attempted / qualified / excluded |',
                  '|---|---:|---:|'])
    for task,browsers in score['phase2_attempts'].items():
        cells=[' / '.join(str(browsers[name][k]) for k in ('attempted','qualified','excluded')) for name in ('arc','open')]
        lines.append('| '+task+' | '+' | '.join(cells)+' |')
    lines.extend(['','Timing medians are conditional on qualified successful actions. Failed or unmatched attempts contribute no finite latency; their counts and reasons remain in the JSON. Calibration samples are separate and excluded.',''])
    lines.extend(['','| Metric | Arc median | Open median | Unit | N Arc / Open | Ratio | Raw score | Category score | Open build | Detector limit |','|---|---:|---:|---|---:|---:|---:|---:|---|---|'])
    for r in score['rows']:
        mark=' ≈' if r['overlap'] else '';clamp=' *' if r['ratio_clamped'] else ''
        limit='detector resolves 8.3 ms; drops shorter than that are not seen' if r['id'].startswith('fps.') else '—'
        lines.append(f"| `{r['id']}` | {r['arc']['median']:.3f} | {r['open']['median']:.3f} | {r['unit']} | {r['arc']['n']} / {r['open']['n']} | {r['ratio']:.3f}{clamp} | {r['computed_score']:.1f}{mark} | {r['category_metric_score']:.1f} | `{r['open_commit'][:8]}` | {limit} |")
    lines.extend(['','| Absolute budget comparison | Open median | Limit | Distance | Numerical result | Qualification |',
                  '|---|---:|---:|---:|---|---|'])
    for r in score['rows']:
        budget=r['budget']
        if 'limit' not in budget:continue
        lines.append(f"| `{r['id']}` | {r['open']['median']:.3f} {r['unit']} | {budget['limit']:g} {r['unit']} | {budget['distance']:+.3f} {r['unit']} | {budget['numerical_status']} | {budget.get('qualification',budget['status'])} |")
    lines.extend(['','These comparisons use the budgets in docs/architecture.md. A numerical PASS on a different fixture is not architecture-budget acceptance. Command-bar first response is not a separate first-results measurement. Sidebar late share is limited to changed images seen by this detector; shorter drops remain unseen.',''])
    transition='keyboard Space change (LEAD 03:40 fallback)' if space_scenario=='space_change_keyboard' else 'Space swipe'
    lines.extend(['',f'The five smoothness scenarios are native sidebar scrolling, {transition}, long-article page scrolling, command bar open/close, and sidebar collapse/expand. Late frames exceed 1.5× the detector median. The scored rows are late share, p95/p99 interval and longest stall, per LEAD 03:00/03:40.','',
                  'Pacing uses intervals between changed images within each trial. Deliberate quiet gaps between separate trials are excluded. A surface with only one instantaneous repaint has no observed frame interval and uses the detector resolution as a floor; that floor does not establish continuous 120 Hz motion. The raw receipts mark these cases.','',
                  '| Page rAF during scroll (informative; not scored) | Arc | Open |','|---|---:|---:|'])
    from score import summarize
    score['informative_raf']={}
    for field in ('median_ms','p95_ms'):
        stats={name:summarize([s['raf_cadence_informative'][field] for s in paired['samples'] if s['browser']==name and s.get('valid') and s.get('raf_cadence_informative')]) for name in ('arc','open')}
        score['informative_raf'][field]=stats
        lines.append('| '+field+' | '+' | '.join(f"{stats[name]['median']:.3f} ms (N={stats[name]['n']})" if stats[name] else 'pending' for name in ('arc','open'))+' |')
    score['smoothness_detector_floor_samples']={}
    lines.extend(['','| Pacing samples with no observed changed-image interval (detector floor used) | Arc / 7 | Open / 7 |',
                  '|---|---:|---:|'])
    for scenario in ('sidebar_scroll',space_scenario,'page_scroll_article','commandbar_open_close','sidebar_collapse_expand'):
        counts={name:sum(bool(s.get('smoothness',{}).get(scenario,{}).get('detector_floor_used'))
                        for s in paired['samples'] if s['browser']==name and s.get('valid') and s['task']=='smoothness')
                for name in ('arc','open')}
        score['smoothness_detector_floor_samples'][scenario]=counts
        lines.append(f"| {scenario} | {counts['arc']} | {counts['open']} |")
    lines.extend(['','A floor sample records a visible response but no interval between changed images. Its 8.334 ms value is a resolution floor, not measured continuous 120 fps delivery.',''])
    score['informative_motion_response']={}
    lines.extend(['','| Motion response (informative, ms) | Arc first response | Open first response | Arc last change | Open last change |',
                  '|---|---:|---:|---:|---:|'])
    for scenario in ('sidebar_scroll',space_scenario,'page_scroll_article','commandbar_open_close','sidebar_collapse_expand'):
        stats={}
        for name in ('arc','open'):
            stats[name]={}
            for field in ('first_response_ms_informative','settle_ms_informative'):
                values=[]
                for sample in paired['samples']:
                    if sample['browser']!=name or not sample.get('valid'):continue
                    trials=sample.get('smoothness',{}).get(scenario,{}).get(field,[])
                    valid=[v for v in trials if isinstance(v,(int,float))]
                    if valid:values.append(statistics.median(valid))
                stats[name][field]=summarize(values)
        score['informative_motion_response'][scenario]=stats
        cells=[]
        for field,name in (('first_response_ms_informative','arc'),('first_response_ms_informative','open'),
                           ('settle_ms_informative','arc'),('settle_ms_informative','open')):
            summary=stats[name][field];cells.append(f"{summary['median']:.3f}" if summary else 'unobserved')
        lines.append('| '+scenario+' | '+' | '.join(cells)+' |')
    lines.extend(['','Motion response uses the same 8.3 ms detector. First response and last change include the different Arc/Open input routes and do not contribute to the score. Last change is the last observed changed frame within the declared capture window, not a proof of eventual quiescence.',''])
    lines.extend(['','Raw metric score: `clamp(7 + 3 log2(r), 0, 10)`. Each category contribution first bounds the ratio to [0.5,2.0]. Overlapping p25–p75 intervals contribute 7.0. `*` marks a bounded ratio; `≈` marks overlapping intervals. CPU/POWER epsilon is 0.1, wakeups 1/s, smoothness percentage rows 0.1 percentage points.','',
       'Medians, p25/p75, min/max, exact sample counts, per-row dates/load ranges and build hashes are in P-scorecard-2.json. Existing architecture budget comparisons remain qualified by their actual fixture; a listed window is not a presented sidebar frame.','',
       'No cause investigation or product optimization is included. Raw rejected attempts remain in the receipt. Private AX trees and event scripts remain under ignored .re/perf; frames are never written.',''])
    score['phase2_open_only_replay']={'status':'AVAILABLE',
        'qualification':'tools/perf/run.sh open --phase 2 replays the retained, hashed private paired starts. Full replay requires N7; named subsets permit a declared smaller N. It never launches Arc.'}
    lines.extend(['Open-only replay is exposed by `tools/perf/run.sh open --phase 2`; see docs/perf/README.md for the required private manifest and named-row replay. Replay scores cover the selected Phase 2 rows only.',''])
    normal=controls['pacing']['cadence'];fault=controls['pacing']['cadence-stalled']
    lines.extend([f"Real detector controls: a +200 ms colour delay added {controls['latency']['delta_ms']:.3f} ms (N3). A 25 ms/frame injected stall raised p95 {normal['p95_ms']:.3f} → {fault['p95_ms']:.3f} ms, late share {normal['late_pct']:.1f}% → {fault['late_pct']:.1f}%, p99 {normal['p99_ms']:.3f} → {fault['p99_ms']:.3f} ms, and longest stall {normal['longest_stall_ms']:.3f} → {fault['longest_stall_ms']:.3f} ms.",
        '',f"The real page moved {controls['scroll']['after']-controls['scroll']['before']:.0f} px through the own-window scroll route. Invalid window, phase and momentum requests were refused. Controls had normal cleanup and no new system window. Receipt `{control_path.relative_to(ROOT)}`.",
        '', 'These controls prove the shared detector and scroll route. They do not independently inject a regression into each native UI intent or discarded-tab resume. Phase 1 retains the control gaps stated in report 1.',''])
    if missing:lines.extend(['Pending required rows: '+', '.join(missing),''])
    route=phase['provenance']['space_transition_route']
    if route['scored_route']=='keyboard':
        lines.extend([route['unscored']+'. The bounded two-direction proof used three Spaces, real pixel-wheel events through NSApp.sendEvent, horizontal dominance, threshold-crossing distance, and finger/momentum phases. Receipt: `'+route['receipt']+'`, SHA-256 `'+route['sha256']+'`.',
                      '', 'Lead follow-up: '+route['lead_action']+'.',''])
    first=(PLANS/'P-report-1.md').read_text()
    if '<!-- main-delta -->' in first:lines.extend([first.split('<!-- main-delta -->',1)[1]])
    atomic(PLANS/'P-scorecard-2.json',score)
    (PLANS/'P-report-2.md').write_text('\n'.join(lines))
    print(json.dumps({'status':score['status'],'overall':score['overall'],'rows':len(score['rows']),'missing':missing}))
if __name__=='__main__':main()
