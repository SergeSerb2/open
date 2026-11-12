#!/usr/bin/env python3
"""Release Library receipts from real App/SQLite/native submission paths.

Run under heavy.sh + the on-screen lock on the M1. No desktop events.
Native submission is distinct from physical scan-out; scroll submission cost
is reported separately from the still-unqualified compositor dropped frames.
"""
import argparse
import copy
import json
import os
from pathlib import Path
import shutil
import sqlite3
import statistics
import subprocess
import tempfile
import time
import uuid
from engine_e2e import Open, wait_until
from downloads import server
from library_frame_probe import Frames, TICK_MS
from library_cpu import snapshot as cpu_snapshot, delta as cpu_delta


def cpu(exclude_bundle=None):
    # Exclude the whole owned Open tree, WindowServer and this harness. Chromium
    # helpers are part of Open; subtracting only the main PID counts them twice.
    total=0
    for line in subprocess.check_output(['ps','-A','-o','pid=,pcpu=,comm='],text=True).splitlines():
        parts=line.strip().split(None,2)
        if len(parts)!=3:continue
        pid,value,path=parts
        if int(pid)==os.getpid() or path.endswith('/WindowServer'):continue
        if exclude_bundle and path.startswith(str(exclude_bundle)+'/'):continue
        total+=float(value)
    return total


def other_processes(exclude_bundle=None):
    rows=[]
    for line in subprocess.check_output(['ps','-A','-o','pid=,pcpu=,comm='],text=True).splitlines():
        parts=line.strip().split(None,2)
        if len(parts)!=3:continue
        pid,value,path=parts
        if int(pid)==os.getpid() or exclude_bundle and path.startswith(str(exclude_bundle)+'/'):continue
        rows.append({'pid':int(pid),'cpuPercent':float(value),'process':Path(path).name})
    return sorted(rows,key=lambda row:row['cpuPercent'],reverse=True)[:5]


def quiet(deadline=None):
    attempts=[];deadline=deadline if deadline is not None else time.monotonic()+900
    while time.monotonic()<deadline:
        loads=[os.getloadavg()[0]];time.sleep(10);loads.append(os.getloadavg()[0]);foreign=cpu()
        attempts.append({'loads':loads,'foreignCPU':foreign,'otherProcesses':other_processes()})
        if max(loads)<=3.5:return loads,foreign,attempts
        print('WAIT quiet prerequisites '+json.dumps(attempts[-1]),flush=True)
    raise RuntimeError('quiet-sample prerequisites did not pass in fifteen minutes: '+json.dumps(attempts))


def launch(root,bundle,output,index,extra_env=None):
    app=Open('Release','chrome',str(root),[],str(output/('app-%s.log'%index)),urls=('about:blank',),extra_env=dict({'OPEN_E2E_APP_BUNDLE':str(bundle)},**(extra_env or {})))
    owner=app.call('shell-windows')[0]['id'];app.call('window-focus',id=owner,activate=True)
    return app


def idle_window(app):
    before=app.call('library-performance',operation='cpu');start=time.monotonic();processes_before=cpu_snapshot(app)
    time.sleep(30)
    processes_after=cpu_snapshot(app);after=app.call('library-performance',operation='cpu');seconds=time.monotonic()-start
    return {'cpuPercent':100*(after['cpuSeconds']-before['cpuSeconds'])/seconds,'seconds':seconds,
            'attribution':cpu_delta(processes_before,processes_after,seconds),'counters':after['counters'],
            'counterDelta':{k:v-before['counters'].get(k,0) for k,v in after['counters'].items()}}


def idle_sample_attribution(sample):
    """Keep high idle samples unresolved until their work is attributed.

    LEAD 08:30 clarified that a main-thread delta above the sample ceiling
    fails even when a worker has a larger delta. A separate order-swapped
    receipt can explain launch-time overlap; this table keeps the raw verdict.
    Cumulative Library counters use their window deltas; live gauges use
    their settled values as well. Cached timings and lifetime totals do not
    describe activity during the window.
    """
    windows=sample['idleWindows']
    def threads(window):
        totals={}
        for row in window['attribution']['threads']:
            name=row['name'];totals[name]=totals.get(name,0)+row['cpuPercent']
        return totals
    before,opened,after=[threads(windows[key]) for key in ['closedBefore','open','closedAfter']]
    deltas={name:opened.get(name,0)-statistics.mean([before.get(name,0),after.get(name,0)])
            for name in set(before)|set(opened)|set(after)}
    main=deltas.get('CrBrowserMain',0)
    dominant=max(deltas,key=deltas.get,default='')
    counters=windows['open']['counterDelta'];gauges=windows['open']['counters']
    activity={key:value for key,value in counters.items() if value>0 and
              (key.startswith('wake.') or key in ['created','configured','reloadData','tableUpdates','formatting','listLayout','rasterStores','rasterPixels','textRasters','glyphRasters'])}
    activity.update({key:gauges.get(key,0) for key in ['tasks','timers','displayLinks','animations'] if gauges.get(key,0)>0})
    high=sample['idleDeltaPercentagePoints']>.075
    main_attributed=main>.075
    failed=high and (main_attributed or bool(activity))
    return {'deltaPercentagePoints':sample['idleDeltaPercentagePoints'],'aboveSampleCeiling':high,
            'mainThreadDeltaPercentagePoints':main,'dominantAppThreadGroup':dominant,
            'threadGroupDeltasPercentagePoints':deltas,'mainThreadAttributed':main_attributed,
            'libraryActivity':activity,'status':'FAIL' if failed else 'INFO' if high else 'PASS','ok':not failed}


def seed(root,bundle,output):
    app=None
    with server() as base:
        try:
            app=launch(root,bundle,output,'seed');tab=app.call('tabs')[0]['id']
            profile=next(s['profile'] for s in app.call('spaces') if s['focused'])
            folder=root/'files';folder.mkdir();app.call('download-settings',profile=profile,directory=str(folder),ask=False)
            app.call('navigate',tab=tab,url=base+'/arm');app.call('wait',tab=tab)
            app.eval(tab,'(()=>{const a=document.createElement("a");a.id="fixture";a.href='+json.dumps(base+'/file')+';a.textContent="File";document.body.append(a)})()')
            app.call('click',tab=tab,selector='#fixture')
            assert wait_until(lambda:any(d['state']=='completed' for d in app.call('downloads-state')['items']),timeout=20)
            app.call('download-history-flush');app.call('history-state')
            app.call('command',id='archive-tab');app.call('library',action='open',section='archive')
            assert wait_until(lambda:bool(app.call('library')['rows']),timeout=10)
            app.call('library',action='open',section='downloads')
        finally:
            if app:
                app.quit();assert app.quit_report['ok'],app.quit_report
    snapshot=json.loads((root/'State/browser.json').read_text())
    profile=snapshot['profiles'][0];state=root/'Profiles'/profile['dataDirectoryName']/'State'
    now=time.time()
    with sqlite3.connect(state/'downloads.sqlite3') as db:
        source=json.loads(db.execute('SELECT payload FROM downloads LIMIT 1').fetchone()[0]);db.execute('DELETE FROM downloads')
        for i in range(1000):
            item=dict(source,id='library-%05d'%i,fileName='Library document %05d%s.txt'%(i,' Z' if i==999 else ''),startedAt=now-i-1,endedAt=now-i)
            db.execute('INSERT INTO downloads VALUES(?,?,?,?)',(item['id'],item['startedAt'],item['endedAt'],json.dumps(item)))
    with sqlite3.connect(state/'history.sqlite3') as db:
        db.execute('DELETE FROM visits');db.execute('DELETE FROM urls')
        for i in range(5000):
            row=db.execute('INSERT INTO urls(url,title,visit_count,typed_count,last_visit) VALUES(?,?,1,0,?)',('https://history.example.test/%05d'%i,'Library history %05d'%i,now-i))
            db.execute('INSERT INTO visits(url_id,time,transition) VALUES(?,?,?)',(row.lastrowid,now-i,'link'))
    with sqlite3.connect(state/'archive.sqlite3') as db:
        source=db.execute('SELECT * FROM archived_tabs LIMIT 1').fetchone();columns=[row[1] for row in db.execute('PRAGMA table_info(archived_tabs)')];template=dict(zip(columns,source));db.execute('DELETE FROM archived_tabs')
        for i in range(2000):
            item=dict(template,id=str(uuid.uuid4()).upper(),title='Archived Library %05d'%i,url='https://archive.example.test/%05d'%i,archived_at=now-i)
            payload=json.loads(item['payload']);payload.update(id=item['id'],title=item['title'],url=item['url']);item['payload']=json.dumps(payload)
            db.execute('INSERT INTO archived_tabs('+','.join(columns)+') VALUES('+','.join('?' for _ in columns)+')',[item[k] for k in columns])
    return snapshot


def scroll_fixture(root,snapshot):
    """Ten supported 1,000-row stores, never bypassing the per-Profile cap."""
    destination=root/'scroll'
    shutil.copytree(root,destination,ignore=shutil.ignore_patterns('baseline','scroll','automation.sock'))
    model=copy.deepcopy(snapshot);original=model['profiles'][0]
    source=root/'Profiles'/original['dataDirectoryName']/'State/downloads.sqlite3'
    for number in range(1,10):
        profile=dict(original,id=str(uuid.uuid4()).upper(),name='Library Scroll '+str(number),dataDirectoryName='LibraryScroll'+str(number))
        model['profiles'].append(profile)
        state=destination/'Profiles'/profile['dataDirectoryName']/'State';state.mkdir(parents=True)
        shutil.copyfile(source,state/'downloads.sqlite3')
        with sqlite3.connect(state/'downloads.sqlite3') as db:
            records=[json.loads(row[0]) for row in db.execute('SELECT payload FROM downloads')];db.execute('DELETE FROM downloads')
            for item in records:
                item.update(id=item['id']+'-profile-'+str(number),profileID=profile['id'])
                db.execute('INSERT INTO downloads VALUES(?,?,?,?)',(item['id'],item['startedAt'],item['endedAt'],json.dumps(item)))
    (destination/'State/browser.json').write_text(json.dumps(model))
    return destination


def main(args):
    output=args.output.resolve();output.mkdir(parents=True,exist_ok=False)
    receipt={'configuration':'Release','samples':[],'method':'LEAD 06:50 clocks/validity; LEAD 09:20 provider and scroll qualification. App-side event dispatch to the CATransaction flush containing the complete first screen or filtered result. Physical clocks and row-setup sub-targets are informational. Idle median is open minus mean(closed before, closed after); high samples fail only when attributed to the main thread or Library activity.','validity':{'load1Maximum':3.5,'loadReadings':2,'spacingSeconds':10,'foreignCPUThreshold':None,'quietDeadlineSecondsPerPair':900},'limits':{'firstSubmittedMilliseconds':8,'contentSubmittedMilliseconds':100,'coldSectionMilliseconds':50,'warmSectionMilliseconds':8.3,'searchMilliseconds':16,'idleDeltaPercentagePoints':.05},'complete':False}
    if args.resume_from:
        previous=json.loads(args.resume_from.read_text())
        assert previous['configuration']==receipt['configuration'] and previous['limits']==receipt['limits']
        assert previous['method']==receipt['method'] and not previous['complete']
        assert previous['baseline']['bundle']==str(args.baseline_bundle)
        valid=[];baselines=[]
        for row,baseline in zip(previous['samples'],previous['baseline']['samples']):
            if not row['valid']:break
            assert row['cleanup']['ok'] and baseline['cleanup']['ok']
            assert max(row['loads'])<=3.5 and max(baseline['loads'])<=3.5
            assert row['search']['providerRows']==1
            valid.append(row);baselines.append(baseline)
        assert 0<len(valid)<args.samples
        receipt.update(samples=valid,resumedFrom=str(args.resume_from.resolve()),baseline={'bundle':str(args.baseline_bundle),'samples':baselines})
        for index in range(len(valid)):
            source=args.resume_from.parent/previous['samples'][index].get('physicalDirectory','physical-'+str(index))
            if source.exists():shutil.copytree(source,output/source.name,ignore=shutil.ignore_patterns('commands'))
    active=None;frames=None
    def save(): (output/'result.json').write_text(json.dumps(receipt,indent=2))
    save()
    try:
        with tempfile.TemporaryDirectory(prefix='olp-',dir='/tmp') as directory:
            root=Path(directory);snapshot=seed(root,args.bundle,output)
            receipt['fixture']={'downloads':1000,'history':5000,'archive':2000}
            baseline_root=root/'baseline'
            if args.baseline_bundle:
                shutil.copytree(root,baseline_root,ignore=shutil.ignore_patterns('baseline','automation.sock'))
                receipt.setdefault('baseline',{'bundle':str(args.baseline_bundle),'samples':[]})
            cold_loads,cold_cpu,cold_waits=quiet()
            active=launch(root,args.bundle,output,'early-cold',{'OPEN_AUTOMATION_LIBRARY_PREBUILD_DISABLED':'1'})
            assert active.call('library')['created'] is False
            early=active.call('library-performance',operation='open',section='downloads')
            uncached_archive=active.call('library-performance',operation='section',section='archive')
            assert uncached_archive['counters']['providerWarm']==0
            cold_end_cpu=cpu(active.bundle)
            # Keep the persisted seed selection identical to the baseline.
            # The uncached provider probe must not select the next prebuild.
            active.call('library',action='open',section='downloads')
            active.quit();assert active.quit_report['ok']
            receipt['earlyCold']={'loads':cold_loads,'foreignCPU':[cold_cpu,cold_end_cpu],'quietAttempts':cold_waits,'timing':early,'uncachedArchive':uncached_archive,'uncachedMethod':'First provider read in a fresh process, before idle warming. OS file cache is uncontrolled; no disk-cache purge.','cleanup':active.quit_report,'limit':50,'ok':early['firstSubmittedMilliseconds']<=50 and uncached_archive['firstSubmittedMilliseconds']<=16 and uncached_archive['contentSubmittedMilliseconds']<=150}
            active=None;save()
            attempt=0;previous_index=None;pair_deadline=None
            while len(receipt['samples'])<args.samples:
                index=len(receipt['samples']);attempt+=1
                attempt_tag=str(index)+'-attempt-'+str(attempt)
                if index!=previous_index:
                    pair_deadline=time.monotonic()+900;previous_index=index
                loads,foreign,quiet_attempts=quiet(pair_deadline)
                baseline_row=None
                if args.baseline_bundle:
                    base_loads,base_cpu,base_waits=loads,foreign,quiet_attempts
                    baseline_other_before=other_processes()
                    active=launch(baseline_root,args.baseline_bundle,output,'baseline-'+attempt_tag)
                    base_timing=active.call('timing')
                    end_base_cpu=cpu(active.bundle)
                    active.quit();assert active.quit_report['ok']
                    baseline_row={'index':index,'attempt':attempt,'loads':base_loads,'foreignCPU':[base_cpu,end_base_cpu],'otherProcessesBefore':baseline_other_before,'otherProcessesAfter':other_processes(active.bundle),'quietAttempts':base_waits,'timing':base_timing,'cleanup':active.quit_report}
                    active=None
                    receipt['pendingBaseline']=baseline_row;save()
                candidate_other_before=other_processes();candidate_load_before=os.getloadavg()[0]
                active=launch(root,args.bundle,output,attempt_tag)
                launch_settled=time.monotonic()
                startup=active.call('timing')
                assert wait_until(lambda:active.call('library',action='prebuild-state').get('ready',False),timeout=12)
                prebuild=active.call('library',action='prebuild-state')
                assert prebuild['section']=='downloads',prebuild
                assert prebuild['builtAt']-prebuild['firstSidebarDraw']>=3,prebuild
                assert prebuild['builtAt']-prebuild['lastInput']>=3,prebuild
                physical=None
                if args.frame_helper:
                    try:frames=Frames(active,args.frame_helper,output/('physical-'+attempt_tag))
                    except Exception as error:receipt.setdefault('physicalErrors',[]).append(repr(error));save()
                action=lambda:active.call('library-performance',operation='open',section='downloads')
                if frames:
                    opened,physical=frames.measure('open',action);frames.close();frames=None
                else:opened=action()
                assert opened['providerRows']==1000,opened
                # First-visit UI hosts use data explicitly warmed by the real
                # input-cancelled idle scheduler. Do not relabel a disk read.
                assert wait_until(lambda:active.call('library-performance',operation='cpu')['counters'].get('warmedSectionPages',0)>=5,timeout=15)
                provider_warm=active.call('library-performance',operation='cpu')['counters']
                cold=[];warm=[]
                for section in ['history','archive','downloads']:
                    result=active.call('library-performance',operation='section',section=section)
                    assert result['counters']['providerWarm']==1,result
                    cold.append(dict(section=section,**result))
                for section in ['history','archive','downloads']:
                    warm.append(dict(section=section,**active.call('library-performance',operation='section',section=section)))
                # A real single keystroke selects one populated row. Timing a
                # five-character burst would include five synchronous updates.
                search=active.call('library-performance',operation='search',text='z')
                assert search['providerRows']==1,search
                stamps=search['searchTimestamps']
                assert all(key in stamps for key in ['dispatch','editorKeyDown','textChanged','handlerEntry','commit']),stamps
                assert [stamps[key] for key in ['dispatch','editorKeyDown','textChanged','handlerEntry','commit']]==sorted(stamps.values()),stamps
                active.call('key',key='escape',route='app');active.call('library',action='focus-rail')
                active.call('library',action='close')
                # Timing operations happen first. The first closed CPU window
                # starts >=30s after launch settled and >=5.3s after closing.
                time.sleep(max(5.3,launch_settled+30-time.monotonic()))
                closed_before=idle_window(active)
                active.call('library',action='open',section='downloads');active.call('library',action='focus-rail');time.sleep(5.3)
                opened_idle=idle_window(active)
                active.call('library',action='close');time.sleep(5.3)
                closed_after=idle_window(active)
                idle=opened_idle['cpuPercent'];closed_idle=statistics.mean([closed_before['cpuPercent'],closed_after['cpuPercent']])
                end_cpu=cpu(active.bundle)
                row={'index':index,'attempt':attempt,'physicalDirectory':'physical-'+attempt_tag,'loads':loads,'quietAttempts':quiet_attempts,'candidateLoadBefore':candidate_load_before,'endLoad':os.getloadavg()[0],'foreignCPU':[foreign,end_cpu],'otherProcessesBefore':candidate_other_before,'otherProcessesAfter':other_processes(active.bundle),'startup':startup,'open':opened,'physicalOpen':physical,'providerWarmup':provider_warm,'coldSections':cold,'warmSections':warm,'search':search,'idleWindows':{'closedBefore':closed_before,'open':opened_idle,'closedAfter':closed_after},'idleAttribution':{key:window['attribution'] for key,window in [('closedBefore',closed_before),('open',opened_idle),('closedAfter',closed_after)]},'idleCPUPercent':idle,'closedIdleCPUPercent':closed_idle,'idleDeltaPercentagePoints':idle-closed_idle,'idleCounters':opened_idle['counters'],'idleCounterDelta':opened_idle['counterDelta'],'prebuild':prebuild}
                active.quit();row['cleanup']=active.quit_report;assert row['cleanup']['ok'];active=None
                row['valid']=max(loads)<=3.5
                receipt['samples'].append(row)
                if baseline_row:receipt['baseline']['samples'].append(baseline_row)
                receipt.pop('pendingBaseline',None)
                save()
                # Keep the full compositor signatures and cleanup receipt in
                # result.json; console output needs only the measured summary.
                print(json.dumps({'index':index,'valid':row['valid'],'firstMS':opened['firstSubmittedMilliseconds'],'fullMS':opened['contentSubmittedMilliseconds'],'coldMS':max(x['contentSubmittedMilliseconds'] for x in cold),'warmMS':max(x['contentSubmittedMilliseconds'] for x in warm),'searchMS':search['contentSubmittedMilliseconds'],'idleDelta':idle-closed_idle}),flush=True)
            def verdict(values,limit):return {'values':values,'median':statistics.median(values),'limit':limit,'ok':statistics.median(values)<=limit and max(values)<=1.5*limit}
            receipt['summary']={
                'firstSubmission':verdict([s['open']['firstSubmittedMilliseconds'] for s in receipt['samples']],8),
                'fullyDrawnContent':verdict([s['open']['contentSubmittedMilliseconds'] for s in receipt['samples']],100),
                'coldSectionFirstCommit':verdict([max(r['firstSubmittedMilliseconds'] for r in s['coldSections']) for s in receipt['samples']],16/1.5),
                'coldSection':verdict([max(r['contentSubmittedMilliseconds'] for r in s['coldSections']) for s in receipt['samples']],50),
                'warmSection':verdict([max(r['contentSubmittedMilliseconds'] for r in s['warmSections']) for s in receipt['samples']],8.3),
                'search':verdict([s['search']['contentSubmittedMilliseconds'] for s in receipt['samples']],16)}
            receipt['summary']['coldSectionFirstCommit'].update(limit=16,ok=all(r['firstSubmittedMilliseconds']<=16 for sample in receipt['samples'] for r in sample['coldSections']))
            attribution=[idle_sample_attribution(s) for s in receipt['samples']]
            idle_values=[s['idleDeltaPercentagePoints'] for s in receipt['samples']]
            receipt['summary']['idleDelta']={'values':idle_values,'median':statistics.median(idle_values),'limit':.05,
                'sampleAttribution':attribution,'ok':statistics.median(idle_values)<=.05 and all(s['ok'] for s in attribution)}
            def diagnostic(values,target):return {'values':values,'median':statistics.median(values),'diagnosticTarget':target,'status':'INFO','informational':True}
            receipt['summary']['rowConfigureP95']=diagnostic([s['idleCounters']['configureP95'] for s in receipt['samples']],.3)
            receipt['summary']['coldApply']=diagnostic([max(x['counters'].get('last.apply',0) for x in s['coldSections'] if x['counterDelta'].get('tableUpdates',0)>0) for s in receipt['samples']],4)
            maxima=[s['idleCounters']['configureMaximum'] for s in receipt['samples']]
            receipt['summary']['rowConfigureMaximum']=dict(diagnostic(maxima,1),maximum=max(maxima))
            receipt['warmZeroConfiguration']=all(s['counterDelta'].get('configured',-1)==0 and s['counterDelta'].get('reloadData',-1)==0 for row in receipt['samples'] for s in row['warmSections'])
            receipt['idleCountersOK']=all(all(row['idleCounters'].get(k,-1)==0 for k in ['tasks','timers','displayLinks','animations']) for row in receipt['samples'])
            receipt['nativeBudgetsOK']=all(v['ok'] for v in receipt['summary'].values() if not v.get('informational')) and receipt['warmZeroConfiguration'] and receipt['idleCountersOK'] and receipt['earlyCold']['ok']
            receipt['scroll']={'status':'UNVERIFIED','reason':'10,000-row native submission and physical 120Hz dropped-frame qualification are separate from the 1,000-download fixture.'}
            receipt['returningLaunch']={'status':'UNVERIFIED','reason':'No baseline artifact supplied.'}
            if args.baseline_bundle:
                candidate=[s['startup']['sidebarDrawn'] for s in receipt['samples']]
                baseline=[s['timing']['sidebarDrawn'] for s in receipt['baseline']['samples']]
                receipt['returningLaunch']={'status':'MEASURED','candidate':candidate,'baseline':baseline,'medianDeltaMilliseconds':statistics.median(candidate)-statistics.median(baseline),'pairedDeltaMilliseconds':[a-b for a,b in zip(candidate,baseline)]}
            if args.frame_helper and len([s for s in receipt['samples'] if s['physicalOpen']])==args.samples:
                receipt['physicalFirstChange']={'values':[s['physicalOpen']['first_changed_ms'] for s in receipt['samples']],'informational':True}
                receipt['physicalFinalContent']={'values':[s['physicalOpen']['first_final_content_ms'] for s in receipt['samples']],'informational':True}
            if args.frame_helper and args.samples==5:
                scroll_root=scroll_fixture(root,snapshot)
                scroll_loads,scroll_cpu,scroll_waits=quiet()
                active=launch(scroll_root,args.bundle,output,'scroll')
                opened=active.call('library-performance',operation='open',section='downloads')
                assert opened['providerRows']==10000,opened
                time.sleep(.4);frames=Frames(active,args.frame_helper,output/'physical-scroll')
                assert wait_until(lambda:active.call('library-performance',operation='cpu')['counters'].get('tasks')==0,timeout=10)
                def scroll():return active.call('library-performance',operation='scroll-series')['frames']
                costs,physical=frames.measure('scroll',scroll,duration=1800);frames.close();frames=None
                end_scroll_cpu=cpu(active.bundle)
                active.quit();cleanup=active.quit_report;assert cleanup['ok'];active=None
                frame_ms=[c['milliseconds'] for c in costs]
                p95=sorted(frame_ms)[min(len(frame_ms)-1,int(len(frame_ms)*.95))]
                breakdown={key:max(c['counterDelta'].get(key,0) for c in costs) for key in ['formatting','listLayout']}
                breakdown.update({key:max(c['counters'].get('last.'+key,0) for c in costs) for key in ['layout','display','flush']})
                breakdown.update({key:max(c['counterDelta'].get(key,0) for c in costs) for key in costs[-1]['counterDelta'] if key.startswith('scroll.') or key=='wake.trackingMilliseconds'})
                gaps=[dict(index=i,startTicks=costs[i-1]['endTicks'],endTicks=c['startTicks'],intervalMilliseconds=c['intervalMilliseconds'],heartbeat=c.get('heartbeat',{})) for i,c in enumerate(costs) if i>0 and c['intervalMilliseconds']>12.5]
                physical_misses=physical['missed120HzIntervals']
                # Raw physical gaps stay visible. A sleeping main thread with
                # no callback is INFO under09:20, rather than App work.
                idle_gaps=[g for g in gaps if g['heartbeat'].get('watchdogSamples',0)>0 and g['heartbeat'].get('maxBusyAgeMilliseconds',999)<8.3 and g['heartbeat'].get('maxIdleAgeMilliseconds',0)>=8.3]
                # Native and physical records share mach_absolute_time ticks.
                # Match each missed interval to its gap; never subtract an
                # unrelated idle gap merely because the counts are equal.
                physical_gaps=[];info_intervals=0;first_ten_physical=[]
                for left,right in zip(physical['changes'],physical['changes'][1:]):
                    missing=max(0,round((right-left)*TICK_MS/(1000/120))-1)
                    if not missing:continue
                    points=[left+(right-left)*(j+1)/(missing+1) for j in range(missing)]
                    explained=[point for point in points if any(g['startTicks']<=point<=g['endTicks'] for g in idle_gaps)]
                    info_intervals+=len(explained)
                    gap={'startTicks':left,'endTicks':right,'missingIntervals':missing,'idleMainNoCallbackIntervals':len(explained)}
                    physical_gaps.append(gap)
                    if left<=costs[9]['endTicks'] and len(explained)<missing:first_ten_physical.append(gap)
                attributed_misses=max(0,physical_misses-info_intervals)
                first_ten_busy=[g for g in gaps if g['index']<10 and g not in idle_gaps]
                created=sum(c['counterDelta'].get('created',0) for c in costs)
                scroll_ok=len(physical['changes'])>=100 and p95<=4 and max(frame_ms)<=8.3 and created==0 and attributed_misses<=1 and not first_ten_busy and not first_ten_physical
                receipt['scroll']={'physicalGapAttribution':physical_gaps,'firstTenPhysicalGaps':first_ten_physical,'gapAttribution':gaps,'idleMainNoCallbackGaps':idle_gaps,'rawPhysicalMissedIntervals':physical_misses,'appAttributedMissedIntervals':attributed_misses,'createdDuringScroll':created,'firstTenBusyGaps':first_ten_busy,'p95MainThreadMilliseconds':p95,'maxMainThreadMilliseconds':max(frame_ms),'phaseMaximumMilliseconds':breakdown,'workOver4ms':{k:v for k,v in breakdown.items() if v>4},'status':'MEASURED' ,'rows':10000,'profiles':10,'loads':scroll_loads,'foreignCPU':[scroll_cpu,end_scroll_cpu],'quietAttempts':scroll_waits,'submissions':costs,'physical':physical,'cleanup':cleanup,'ok':scroll_ok}
            receipt['complete']=True
            receipt['sampleCount']=args.samples
            receipt['prQualification']=args.samples==5
            receipt['ok']=receipt['nativeBudgetsOK'] and (args.samples==3 or receipt['scroll'].get('ok',False))
            save()
    except Exception as error:
        receipt['error']=repr(error);save();raise
    finally:
        if frames:frames.close()
        if active:active.quit();receipt['lastCleanup']=active.quit_report;save()
    return 0 if receipt.get('ok') else 1

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--bundle',required=True,type=Path);p.add_argument('--baseline-bundle',type=Path);p.add_argument('--frame-helper',type=Path);p.add_argument('--output',required=True,type=Path);p.add_argument('--samples',type=int,choices=[3,5],default=5);p.add_argument('--resume-from',type=Path,help='Retain only the valid paired prefix of an incomplete receipt with the same artifact and fixture.')
    raise SystemExit(main(p.parse_args()))
