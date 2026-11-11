#!/usr/bin/env python3
"""One LEAD 12:50 no-flush comparison: launch control and A settling only.

Wheel input establishes the same after-motion state; its scrolling budgets
are not rerun or rescored. Run under quiet M1 heavy and screen ownership.
"""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile
import time

from engine_e2e import Open, wait_until
from library_performance import seed, scroll_fixture, quiet
from library_scroll_profiles import idle_work


def run(args):
    out=args.output.resolve();out.mkdir(parents=True,exist_ok=False)
    result={'rule':'LEAD 12:50 (11 Nov)','experiment':'remove idle transaction flush once',
            'configuration':'Release','complete':False,
            'executableSHA256':hashlib.sha256((args.bundle/'Contents/MacOS/Open').read_bytes()).hexdigest()}
    app=None
    def save(): (out/'result.json').write_text(json.dumps(result,indent=2))
    save()
    try:
        with tempfile.TemporaryDirectory(prefix='olif-',dir='/tmp') as directory:
            root=Path(directory);model=seed(root,args.bundle,out);root=scroll_fixture(root,model)
            result['quietBeforeLaunch']=quiet()
            app=Open('Release','chrome',str(root),[],str(out/'app.log'),urls=('about:blank',),
                     extra_env={'OPEN_E2E_APP_BUNDLE':str(args.bundle)})
            app.call('window-focus',id=app.call('shell-windows')[0]['id'],activate=True)
            result['open']=app.call('library-performance',operation='open',section='downloads')
            assert result['open']['providerRows']==10000
            result['control']=app.call('library-performance',operation='scroll-series',profile='control',beginAtLaunchMilliseconds=2000)
            result['controlIdle']=idle_work(result['control']);save()
            age=app.call('library-performance',operation='cpu')['launchElapsedMilliseconds']
            print('WAIT launch age '+str(age),flush=True)
            while age<150000:
                seconds=min(30,(150000-age)/1000);time.sleep(seconds);age+=seconds*1000
            app.call('library-performance',operation='scroll',row=0)
            assert wait_until(lambda:app.call('library-performance',operation='cpu')['counters'].get('tasks',0)==0,timeout=20)
            result['quietBeforeMotion']=quiet()
            result['motionSetupAndTail']=app.call('library-performance',operation='scroll-series',profile='wheel')
            result['afterMotionIdle']=idle_work(result['motionSetupAndTail'])
            result['complete']=True
            print(json.dumps({'controlSliceMaximum':result['controlIdle']['maximumSliceMilliseconds'],
                'controlBusyMaximumRaw':result['controlIdle']['largestLibraryBusyMilliseconds'],
                'afterMotionSliceMaximum':result['afterMotionIdle']['maximumSliceMilliseconds'],
                'afterMotionBusyMaximum':result['afterMotionIdle']['largestLibraryBusyMilliseconds']}),flush=True)
    except Exception as error:
        result['error']=repr(error);raise
    finally:
        if app:app.quit();result['cleanup']=app.quit_report
        save()
    return 0 if result['complete'] and result['cleanup']['ok'] else 1


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bundle',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    raise SystemExit(run(p.parse_args()))
