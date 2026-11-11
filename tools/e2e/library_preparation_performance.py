#!/usr/bin/env python3
"""LEAD 12:50 scoped Release ready-open, warm section and search receipts.

Three baseline/candidate pairs through real App sockets. No idle rerun.
Requires the M1 heavy slots and screen lock for the entire invocation.
"""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import tempfile

from engine_e2e import wait_until
from library_performance import seed, launch, quiet, other_processes


def run(args):
    out=args.output.resolve();out.mkdir(parents=True,exist_ok=False)
    result={'rule':'LEAD 12:50 (11 Nov)','configuration':'Release','samples':[],
            'executableSHA256':hashlib.sha256((args.bundle/'Contents/MacOS/Open').read_bytes()).hexdigest(),
            'complete':False,'idleRerun':False}
    app=None
    def save(): (out/'result.json').write_text(json.dumps(result,indent=2))
    save()
    try:
        with tempfile.TemporaryDirectory(prefix='olip-',dir='/tmp') as directory:
            root=Path(directory);seed(root,args.bundle,out)
            for index in range(3):
                baseline_quiet=quiet()
                app=launch(root,args.baseline_bundle,out,'baseline-'+str(index))
                baseline={'quiet':baseline_quiet,'timing':app.call('timing')}
                app.quit();baseline['cleanup']=app.quit_report;assert app.quit_report['ok'];app=None
                candidate_quiet=quiet()
                app=launch(root,args.bundle,out,str(index))
                assert wait_until(lambda:app.call('library',action='prebuild-state')['ready'],timeout=25)
                prebuild=app.call('library',action='prebuild-state')
                assert prebuild['builtAt']-prebuild['firstSidebarDraw']>=3,prebuild
                opened=app.call('library-performance',operation='open',section='downloads')
                assert opened['providerRows']==1000
                assert wait_until(lambda:app.call('library-performance',operation='cpu')['counters'].get('warmedSectionPages',0)>=5,timeout=25)
                for section in ['history','archive','downloads']:
                    app.call('library-performance',operation='section',section=section)
                warm=[dict(section=section,**app.call('library-performance',operation='section',section=section))
                      for section in ['history','archive','downloads']]
                search=app.call('library-performance',operation='search',text='z')
                assert search['providerRows']==1,search
                stamps=search['searchTimestamps']
                assert all(k in stamps for k in ['dispatch','editorKeyDown','textChanged','handlerEntry','commit'])
                row={'index':index,'baseline':baseline,'quiet':candidate_quiet,'prebuild':prebuild,
                     'open':opened,'warm':warm,'search':search,'otherProcessesAfter':other_processes(app.bundle)}
                app.quit();row['cleanup']=app.quit_report;assert app.quit_report['ok'];app=None
                row['valid']=max(baseline_quiet[0]+candidate_quiet[0])<=3.5
                result['samples'].append(row);save()
                print(json.dumps({'pair':index+1,'valid':row['valid'],'readyOpen':opened['firstSubmittedMilliseconds'],
                      'warm':max(x['contentSubmittedMilliseconds'] for x in warm),'search':search['contentSubmittedMilliseconds']}),flush=True)
            def verdict(values,limit):
                return {'values':values,'median':statistics.median(values),'maximum':max(values),'limit':limit,
                        'ok':statistics.median(values)<=limit and max(values)<=1.5*limit}
            samples=result['samples']
            result['summary']={
                'readyOpen':verdict([s['open']['firstSubmittedMilliseconds'] for s in samples],8),
                'warmSection':verdict([max(x['contentSubmittedMilliseconds'] for x in s['warm']) for s in samples],8.3),
                'search':verdict([s['search']['contentSubmittedMilliseconds'] for s in samples],16)}
            result['warmZeroConfiguration']=all(x['counterDelta'].get('configured',-1)==0 and
                x['counterDelta'].get('reloadData',-1)==0 for s in samples for x in s['warm'])
            result['complete']=True
            result['ok']=all(s['valid'] for s in samples) and result['warmZeroConfiguration'] and all(x['ok'] for x in result['summary'].values())
    except Exception as error:
        result['error']=repr(error);raise
    finally:
        if app: app.quit();result['errorCleanup']=app.quit_report
        save()
    return 0 if result['ok'] else 1


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bundle',type=Path,required=True)
    p.add_argument('--baseline-bundle',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    raise SystemExit(run(p.parse_args()))
