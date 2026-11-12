"""Real Favorites clicks before and after the Site Control presenter cycle.

Uses Open's own native event queue; never moves the desktop pointer.
Run each invocation through the shared on-screen lock.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

import engine_e2e as e
from sitecontrol_fixtures import fixture_server


def run(label, bundle, output):
    tracker = e.FocusTracker(capture_frontmost_command=True)
    e._ACTIVE_FOCUS_TRACKER = tracker
    name = 'Open-SCC-Favorites-' + str(os.getpid())
    data = Path.home() / 'Library/Application Support' / name
    cache = Path.home() / 'Library/Caches' / name
    key = 'open.advanced.showToolbar'
    exported = subprocess.run(['defaults', 'export', __import__('prefs_domain').domain(), '-'], capture_output=True)
    initial = plistlib.loads(exported.stdout) if exported.returncode == 0 else {}
    report = dict(label=label, bundle=str(bundle), startLoad=os.getloadavg(), rows={},
                  binarySHA256=hashlib.sha256((bundle / 'Contents/MacOS/Open').read_bytes()).hexdigest())
    app = None
    try:
        e._restore_defaults(None, {key: False})
        with tempfile.TemporaryDirectory(prefix='scc-favorites-') as tmp, fixture_server(tmp) as origin:
            app = e.Open('Release', 'chrome', str(data), ['--use-mock-keychain'],
                         str(output.with_suffix('.app.log')),
                         extra_env={'OPEN_E2E_APP_BUNDLE': str(bundle)})
            app.focus_tracker = tracker
            tracker.apps.append(app)
            app.call('window-frame', frame=[80, 60, 1200, 800])
            app.call('window-focus', id=app.call('window-state')['id'], activate=True)
            favorite = e.new_tab(app, origin + '/boost.html?favorite')
            app.call('favorite', tab=favorite)
            control = e.new_tab(app, origin + '/boost.html?control')

            def selected():
                return app.call('window-state')['selected']

            def click_favorite():
                # The existing hover route resolves this specific tile's real
                # layout frame, without selecting it. Dispatch through AppKit's
                # dequeue path so NSWindow hit testing includes every overlay.
                app.call('hover', favorite=favorite, ms=0)
                point = app.call('window-state')['automationPointer']
                assert len(point) == 2
                app.call('mouse', action='click', x=point[0], y=point[1], queued=True)
                activated = bool(e.wait_until(lambda: selected() == favorite, timeout=3, step=.05))
                return dict(point=point, selected=selected(), activated=activated)

            def positive(row):
                app.call('select', tab=control)
                assert selected() == control
                value = click_favorite()
                value.update(ok=value['activated'], expected=favorite, control=control, load=os.getloadavg())
                report['rows'][row] = value

            # Neither state reads nor this first click open the presenter.
            positive('FAV_before_first_panel_open')
            app.call('select', tab=control)
            try:
                shown = app.call('site-controls', action='open', via='urlField')
                assert shown['presented']
                closed = app.call('site-controls', action='close')
                assert closed['presented'] is False
                report['panelCycle'] = dict(opened=True, closed=True)
            except RuntimeError as error:
                if label != 'main':
                    raise
                # Unchanged main predates #276's presenter and automation.
                # Repeat the same native click; do not claim a panel cycle.
                report['panelCycle'] = dict(available=False, reason=str(error),
                                            control='same click repeated; presenter absent on main')
            positive('FAV_after_panel_close')

            if label == 'branch':
                app.call('select', tab=control)
                assert app.call('site-controls', action='open', via='urlField')['presented']
                negative = click_favorite()
                report['rows']['FAV_visible_panel_negative'] = dict(
                    ok=not negative['activated'], positivePredicateRejected=not negative['activated'],
                    **negative)
                app.call('site-controls', action='close')
            report['ok'] = all(row['ok'] for row in report['rows'].values())
    except BaseException as error:
        report['error'] = repr(error)
        raise
    finally:
        if app:
            app.quit()
            report['cleanup'] = app.quit_report
        e._restore_defaults(None, {key: initial.get(key)})
        exported = subprocess.run(['defaults', 'export', __import__('prefs_domain').domain(), '-'], capture_output=True)
        after = plistlib.loads(exported.stdout) if exported.returncode == 0 else {}
        report['defaultsRestored'] = after.get(key) == initial.get(key)
        report['focus'] = tracker.loss()
        report['interrupted'] = bool(report['focus'])
        report['newCrashReports'] = list(e._open_crash_reports() - tracker.crashes_before)
        report['endLoad'] = os.getloadavg()
        shutil.rmtree(data, ignore_errors=True)
        shutil.rmtree(cache, ignore_errors=True)
        output.write_text(json.dumps(report, indent=2))
        print(json.dumps(report), flush=True)
    if report['interrupted']:
        return 79
    return 0 if report['ok'] and report['cleanup']['ok'] and report['defaultsRestored'] and not report['newCrashReports'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--label', choices=['branch', 'main'], required=True)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    raise SystemExit(run(args.label, args.bundle.resolve(), args.output.resolve()))
