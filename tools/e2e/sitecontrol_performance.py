"""SCC first-draw and native idle observation in separate real App runs."""
from pathlib import Path
import os
import statistics
import subprocess
import time


def run(factory, results, origin, tmp, env):
    app = factory(urls=(origin + '/ads.html',))
    saved = {}
    try:
        key = 'open.advanced.playSoundEffects'
        saved[key] = app.call('defaults', key=key, persistent=True)
        app.call('defaults', key=key, value=False)
        tab = app.call('tabs')[0]['id']; app.call('wait', tab=tab)
        app.call('window-focus', id=app.call('window-state')['id'], activate=True)
        for _ in range(35):
            app.call('site-controls', action='open')
            time.sleep(.3)
            app.call('site-controls', action='close')
        all_samples = app.call('site-controls', action='state')['firstDrawMilliseconds']
        samples = all_samples[-30:]
        p95 = sorted(samples)[int(.95 * (len(samples) - 1))]
        p95_all = sorted(all_samples)[int(.95 * (len(all_samples) - 1))]
        data = dict(milliseconds=samples, allMilliseconds=all_samples,p95=p95,p95IncludingCold=p95_all,limit=8,warmups=5,coldMilliseconds=all_samples[0],
                    load=list(os.getloadavg()))
        if app.config == 'Release': data['ok'] = len(all_samples) == 35 and len(samples) == 30 and p95 < 8 and p95_all < 8
        else: data.update(status='BLOCKED', reason='Release required for first-draw budget')
        results['P1_first_draw'] = data
    finally:
        env['_restore_defaults'](app, saved)
        app.quit()

    # Inject a delay into the real native SCC display call. This proves that
    # the first-draw receipt includes display work, not just data construction.
    delay_source = Path(tmp, 'sitecontrol-delay.m')
    delay_source.write_text('''#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <unistd.h>
@interface NSView (SCCDelay)
- (void)openSCCDelayedDisplay;
@end
@implementation NSView (SCCDelay)
+ (void)load {
    method_exchangeImplementations(class_getInstanceMethod(self,@selector(displayIfNeeded)),
                                   class_getInstanceMethod(self,@selector(openSCCDelayedDisplay)));
}
- (void)openSCCDelayedDisplay {
    if ([NSStringFromClass(self.class) hasSuffix:@".SiteControlView"]) usleep(12000);
    [self openSCCDelayedDisplay];
}
@end
''')
    delay_probe = str(Path(tmp, 'sitecontrol-delay.dylib'))
    subprocess.run(['xcrun','clang','-dynamiclib','-fobjc-arc',str(delay_source),
                    '-framework','AppKit','-o',delay_probe],check=True,timeout=30)
    app = factory(urls=(origin + '/ads.html',), extra_env={'DYLD_INSERT_LIBRARIES': delay_probe})
    try:
        tab=app.call('tabs')[0]['id']; app.call('wait',tab=tab)
        app.call('site-controls',action='open')
        delayed=app.call('site-controls',action='state')['firstDrawMilliseconds'][-1]
        results['P1_first_draw']['negativeRejected']=delayed>=12
        results['P1_first_draw']['negativeMilliseconds']=delayed
        if 'ok' in results['P1_first_draw']:
            results['P1_first_draw']['ok']=results['P1_first_draw']['ok'] and delayed>=12
    finally:
        app.quit()

    # Observe real view invalidation and native schedulers. The observer is
    # injected before SCC initialization; it never ships in the App.
    source = Path(env['ROOT'], 'tools/verification/feature-idle-probe.m').read_text()
    source = source.replace('if (!strstr(path, "/features-render")) return NO;',
                            'if (!strstr(path, "/Open.app/Contents/MacOS/Open")) return NO;')
    source = source.replace('return strstr(info.dli_sname, "OpenFeatures") || strstr(info.dli_sname, "observerProof");',
                            'return strstr(info.dli_sname, "OpenSiteControl") || strstr(info.dli_sname, "siteControlIdle");')
    file = Path(tmp, 'sitecontrol-idle.m'); file.write_text(source)
    probe = str(Path(tmp, 'idle-probe.dylib'))
    subprocess.run(['xcrun', 'clang', '-dynamiclib', '-fblocks', '-fobjc-arc',
                    '-Wno-deprecated-declarations', str(file), '-framework', 'AppKit',
                    '-framework', 'QuartzCore', '-framework', 'CoreVideo', '-o', probe],
                   check=True, timeout=30)
    app = factory(urls=(origin + '/ads.html',), extra_env={'DYLD_INSERT_LIBRARIES': probe})
    try:
        tab = app.call('tabs')[0]['id']; app.call('wait', tab=tab)
        app.call('site-controls-idle', action='begin')
        app.call('site-controls', action='open'); time.sleep(.5)
        app.call('site-controls-idle', action='watch')
        app.call('site-controls-idle', action='reset')
        before = app.call('site-controls-idle'); start = time.monotonic()
        time.sleep(2)
        after = app.call('site-controls-idle'); elapsed = time.monotonic() - start
        canary = app.call('site-controls-idle', action='canary')
        results['P2_idle'] = dict(ok=after['counts'] == [0] * 10 and canary['live'] > 0
            and canary['after'] == 0, observer=after['counts'], canary=canary,
            cpuPercent=100 * (after['cpuSeconds'] - before['cpuSeconds']) / elapsed,
            elapsed=elapsed, load=list(os.getloadavg()))
        app.call('site-controls-idle', action='end')
    finally:
        app.quit()
