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
from library_frame_probe import Frames


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


def quiet():
    attempts=[];deadline=time.monotonic()+300
    while time.monotonic()<deadline:
        loads=[os.getloadavg()[0]];time.sleep(10);loads.append(os.getloadavg()[0]);foreign=cpu()
        attempts.append({'loads':loads,'foreignCPU':foreign})
        if max(loads)<=3 and foreign<=200:return loads,foreign,attempts
        print('WAIT quiet prerequisites '+json.dumps(attempts[-1]),flush=True)
    raise RuntimeError('quiet-sample prerequisites did not pass in five minutes: '+json.dumps(attempts))


def launch(root,bundle,output,index):
    app=Open('Release','chrome',str(root),[],str(output/('app-%s.log'%index)),urls=('about:blank',),extra_env={'OPEN_E2E_APP_BUNDLE':str(bundle)})
    owner=app.call('shell-windows')[0]['id'];app.call('window-focus',id=owner,activate=True)
    return app


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
    receipt={'configuration':'Release','samples':[],'method':'Native layout, displayIfNeeded and CATransaction.flush; provider completion awaited. Search starts at native key dispatch after focus setup, without fixed harness delivery waits. No physical scan-out claim.','limits':{'firstSubmittedMilliseconds':16,'contentSubmittedMilliseconds':100,'coldSectionMilliseconds':50,'warmSectionMilliseconds':8.3,'searchMilliseconds':16,'idleCPUPercent':.2},'complete':False}
    if args.resume_from:
        previous=json.loads(args.resume_from.read_text())
        assert previous['configuration']==receipt['configuration'] and previous['limits']==receipt['limits']
        assert previous['method']==receipt['method'] and not previous['complete']
        assert previous['baseline']['bundle']==str(args.baseline_bundle)
        valid=[];baselines=[]
        for row,baseline in zip(previous['samples'],previous['baseline']['samples']):
            if not row['valid'] or max(baseline['foreignCPU'])>200:break
            assert row['cleanup']['ok'] and baseline['cleanup']['ok']
            assert max(row['loads'])<=3 and max(baseline['loads'])<=3
            assert row['search']['providerRows']==1
            valid.append(row);baselines.append(baseline)
        assert 0<len(valid)<5
        receipt.update(samples=valid,resumedFrom=str(args.resume_from.resolve()),baseline={'bundle':str(args.baseline_bundle),'samples':baselines})
        for index in range(len(valid)):
            source=args.resume_from.parent/('physical-'+str(index))
            if source.exists():shutil.copytree(source,output/source.name,ignore=shutil.ignore_patterns('commands'))
    active=None;frames=None
    def save(): (output/'result.json').write_text(json.dumps(receipt,indent=2))
    save()
    try:
        with tempfile.TemporaryDirectory(prefix='open-library-perf-') as directory:
            root=Path(directory);snapshot=seed(root,args.bundle,output)
            receipt['fixture']={'downloads':1000,'history':5000,'archive':2000}
            baseline_root=root/'baseline'
            if args.baseline_bundle:
                shutil.copytree(root,baseline_root,ignore=shutil.ignore_patterns('baseline','automation.sock'))
                receipt.setdefault('baseline',{'bundle':str(args.baseline_bundle),'samples':[]})
            for index in range(len(receipt['samples']),5):
                if args.baseline_bundle:
                    base_loads,base_cpu,base_waits=quiet()
                    active=launch(baseline_root,args.baseline_bundle,output,'baseline-'+str(index))
                    base_timing=active.call('timing')
                    end_base_cpu=cpu(active.bundle)
                    active.quit();assert active.quit_report['ok']
                    receipt['baseline']['samples'].append({'index':index,'loads':base_loads,'foreignCPU':[base_cpu,end_base_cpu],'quietAttempts':base_waits,'timing':base_timing,'cleanup':active.quit_report})
                    active=None;save()
                    if end_base_cpu>200:raise RuntimeError('Baseline foreign CPU invalidated sample')
                loads,foreign,quiet_attempts=quiet()
                active=launch(root,args.bundle,output,index)
                assert active.call('library')['created'] is False
                startup=active.call('timing')
                physical=None
                if args.frame_helper:
                    try:frames=Frames(active,args.frame_helper,output/('physical-'+str(index)))
                    except Exception as error:receipt.setdefault('physicalErrors',[]).append(repr(error));save()
                action=lambda:active.call('library-performance',operation='open',section='downloads')
                if frames:
                    opened,physical=frames.measure('open',action);frames.close();frames=None
                else:opened=action()
                assert opened['providerRows']==1000,opened
                cold=[];warm=[]
                for section in ['history','archive','downloads']:
                    cold.append(dict(section=section,**active.call('library-performance',operation='section',section=section)))
                for section in ['history','archive','downloads']:
                    warm.append(dict(section=section,**active.call('library-performance',operation='section',section=section)))
                # A real single keystroke selects one populated row. Timing a
                # five-character burst would include five synchronous updates.
                search=active.call('library-performance',operation='search',text='z')
                assert search['providerRows']==1,search
                active.call('key',key='escape',route='app');time.sleep(2)
                before=active.call('library-performance',operation='cpu')['cpuSeconds'];start=time.monotonic();time.sleep(10)
                after=active.call('library-performance',operation='cpu')['cpuSeconds'];idle=100*(after-before)/(time.monotonic()-start)
                end_cpu=cpu(active.bundle)
                row={'index':index,'loads':loads,'quietAttempts':quiet_attempts,'endLoad':os.getloadavg()[0],'foreignCPU':[foreign,end_cpu],'startup':startup,'open':opened,'physicalOpen':physical,'coldSections':cold,'warmSections':warm,'search':search,'idleCPUPercent':idle}
                active.quit();row['cleanup']=active.quit_report;assert row['cleanup']['ok'];active=None
                row['valid']=end_cpu<=200;receipt['samples'].append(row);save()
                # Keep the full compositor signatures and cleanup receipt in
                # result.json; console output needs only the measured summary.
                print(json.dumps({key:value for key,value in row.items() if key not in ['physicalOpen','quietAttempts','cleanup','startup']}),flush=True)
                if not row['valid']:raise RuntimeError('foreign CPU invalidated sample')
            def verdict(values,limit):return {'values':values,'median':statistics.median(values),'limit':limit,'ok':statistics.median(values)<=limit and max(values)<=1.5*limit}
            receipt['summary']={
                'firstSubmission':verdict([s['open']['firstSubmittedMilliseconds'] for s in receipt['samples']],16),
                'fullyDrawnContent':verdict([s['open']['contentSubmittedMilliseconds'] for s in receipt['samples']],100),
                'coldSection':verdict([max(r['contentSubmittedMilliseconds'] for r in s['coldSections']) for s in receipt['samples']],50),
                'warmSection':verdict([max(r['contentSubmittedMilliseconds'] for r in s['warmSections']) for s in receipt['samples']],8.3),
                'search':verdict([s['search']['contentSubmittedMilliseconds'] for s in receipt['samples']],16),
                'idle':verdict([s['idleCPUPercent'] for s in receipt['samples']],.2)}
            receipt['scroll']={'status':'UNVERIFIED','reason':'10,000-row native submission and physical 120Hz dropped-frame qualification are separate from the 1,000-download fixture.'}
            receipt['returningLaunch']={'status':'UNVERIFIED','reason':'No baseline artifact supplied.'}
            if args.baseline_bundle:
                candidate=[s['startup']['sidebarDrawn'] for s in receipt['samples']]
                baseline=[s['timing']['sidebarDrawn'] for s in receipt['baseline']['samples']]
                receipt['returningLaunch']={'status':'MEASURED','candidate':candidate,'baseline':baseline,'medianDeltaMilliseconds':statistics.median(candidate)-statistics.median(baseline),'pairedDeltaMilliseconds':[a-b for a,b in zip(candidate,baseline)]}
            if args.frame_helper and len([s for s in receipt['samples'] if s['physicalOpen']])==5:
                receipt['physicalFirstChange']=verdict([s['physicalOpen']['first_changed_ms'] for s in receipt['samples']],16)
                receipt['physicalFinalContent']=verdict([s['physicalOpen']['first_final_content_ms'] for s in receipt['samples']],100)
                scroll_root=scroll_fixture(root,snapshot)
                scroll_loads,scroll_cpu,scroll_waits=quiet()
                active=launch(scroll_root,args.bundle,output,'scroll')
                opened=active.call('library-performance',operation='open',section='downloads')
                assert opened['providerRows']==10000,opened
                time.sleep(.4);frames=Frames(active,args.frame_helper,output/'physical-scroll')
                def scroll():
                    costs=[];start=time.monotonic()
                    for index in range(120):
                        time.sleep(max(0,start+index/120-time.monotonic()))
                        costs.append(active.call('library-performance',operation='scroll',row=round(index*9999/119)))
                    return costs
                costs,physical=frames.measure('scroll',scroll,duration=1300);frames.close();frames=None
                end_scroll_cpu=cpu(active.bundle)
                active.quit();cleanup=active.quit_report;assert cleanup['ok'];active=None
                receipt['scroll']={'status':'MEASURED','rows':10000,'profiles':10,'loads':scroll_loads,'foreignCPU':[scroll_cpu,end_scroll_cpu],'quietAttempts':scroll_waits,'submissions':costs,'physical':physical,'cleanup':cleanup,'ok':end_scroll_cpu<=200 and len(physical['changes'])>=100 and physical['missed120HzIntervals']==0}
            receipt['complete']=True
            receipt['nativeBudgetsOK']=all(v['ok'] for v in receipt['summary'].values())
            receipt['ok']=receipt['nativeBudgetsOK'] and receipt.get('physicalFirstChange',{}).get('ok',False) and receipt.get('physicalFinalContent',{}).get('ok',False) and receipt['scroll'].get('ok',False)
            save()
    except Exception as error:
        receipt['error']=repr(error);save();raise
    finally:
        if frames:frames.close()
        if active:active.quit();receipt['lastCleanup']=active.quit_report;save()
    return 0 if receipt.get('ok') else 1

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--bundle',required=True,type=Path);p.add_argument('--baseline-bundle',type=Path);p.add_argument('--frame-helper',type=Path);p.add_argument('--output',required=True,type=Path);p.add_argument('--resume-from',type=Path,help='Retain only the valid paired prefix of an incomplete receipt with the same artifact and fixture.')
    raise SystemExit(main(p.parse_args()))
