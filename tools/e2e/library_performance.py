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


def cpu():
    return sum(float(line) for line in subprocess.check_output(['ps','-A','-o','%cpu='],text=True).splitlines() if line.strip())


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
            item=dict(source,id='library-%05d'%i,fileName='Library document %05d.txt'%i,startedAt=now-i-1,endedAt=now-i)
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


def main(args):
    output=args.output.resolve();output.mkdir(parents=True,exist_ok=False)
    receipt={'configuration':'Release','samples':[],'method':'Native layout, displayIfNeeded and CATransaction.flush; provider completion awaited. No physical scan-out claim.','limits':{'firstSubmittedMilliseconds':16,'contentSubmittedMilliseconds':100,'coldSectionMilliseconds':50,'warmSectionMilliseconds':8.3,'searchMilliseconds':16,'idleCPUPercent':.2},'complete':False}
    active=None
    def save(): (output/'result.json').write_text(json.dumps(receipt,indent=2))
    save()
    try:
        with tempfile.TemporaryDirectory(prefix='open-library-perf-') as directory:
            root=Path(directory);snapshot=seed(root,args.bundle,output)
            receipt['fixture']={'downloads':1000,'history':5000,'archive':2000}
            for index in range(5):
                loads=[os.getloadavg()[0]];time.sleep(10);loads.append(os.getloadavg()[0]);foreign=cpu()
                if max(loads)>3 or foreign>200:
                    receipt['invalidSample']={'index':index,'loads':loads,'foreignCPU':foreign};save();raise RuntimeError('quiet-sample prerequisites failed; no timing verdict')
                active=launch(root,args.bundle,output,index)
                assert active.call('library')['created'] is False
                startup=active.call('startup')
                opened=active.call('library-performance',operation='open',section='downloads')
                cold=[];warm=[]
                for section in ['history','archive','downloads']:
                    cold.append(dict(section=section,**active.call('library-performance',operation='section',section=section)))
                for section in ['history','archive','downloads']:
                    warm.append(dict(section=section,**active.call('library-performance',operation='section',section=section)))
                search=active.call('library-performance',operation='search',text='00999')
                active.call('key',key='escape',route='app');time.sleep(2)
                before=active.call('library-performance',operation='cpu')['cpuSeconds'];start=time.monotonic();time.sleep(10)
                after=active.call('library-performance',operation='cpu')['cpuSeconds'];idle=100*(after-before)/(time.monotonic()-start)
                # Exclude the owned App process from the post-sample CPU total.
                own=float(subprocess.check_output(['ps','-p',str(active.pid),'-o','%cpu='],text=True).strip() or 0)
                end_cpu=max(0,cpu()-own)
                row={'index':index,'loads':loads,'endLoad':os.getloadavg()[0],'foreignCPU':[foreign,end_cpu],'startup':startup,'open':opened,'coldSections':cold,'warmSections':warm,'search':search,'idleCPUPercent':idle}
                active.quit();row['cleanup']=active.quit_report;assert row['cleanup']['ok'];active=None
                row['valid']=end_cpu<=200;receipt['samples'].append(row);save();print(json.dumps(row),flush=True)
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
            receipt['returningLaunch']={'status':'UNVERIFIED','reason':'Five startup receipts retained; no same-head main artifact comparison in this run.'}
            receipt['complete']=True;receipt['ok']=all(v['ok'] for v in receipt['summary'].values());save()
    except Exception as error:
        receipt['error']=repr(error);save();raise
    finally:
        if active:active.quit();receipt['lastCleanup']=active.quit_report;save()
    return 0 if receipt.get('ok') else 1

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--bundle',required=True,type=Path);p.add_argument('--output',required=True,type=Path)
    raise SystemExit(main(p.parse_args()))
