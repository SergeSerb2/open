#!/usr/bin/env python3
"""Real App Icon picker, reset and relaunch. Socket actions only; no OS events."""
import argparse
import json
from pathlib import Path
import tempfile
import time
from engine_e2e import Open, wait_until
from library_overlay import capture_window


def run(output, config):
    output.mkdir(parents=True, exist_ok=True)
    checks = {}
    app = None
    def check(name, ok, **evidence):
        checks[name] = dict(ok=bool(ok), **evidence)
        print(('PASS ' if ok else 'FAIL ') + name, flush=True)
        assert ok, (name, evidence)
    with tempfile.TemporaryDirectory(prefix='open-icons-') as tmp:
        def launch():
            return Open(config, 'alloy', str(Path(tmp)/'data'), [], str(Path(tmp)/'app.log'), urls=())
        try:
            app = launch()
            app.call('settings-pane', pane='appIcon')
            for option in ['openDefault', 'openDark', 'openLight', 'openMono', 'openColor', 'openRetro']:
                state = app.call('settings-icon', select=option)
                check('select_'+option, state['selected'] == option and state['applied'] == option
                      and state['matchesApplication'] and not state['error'], state=state)
            first = app.call('settings-icon', select='openDark')
            again = app.call('settings-icon', select='openDark')
            check('cached_alternate', first['imageObject'] == again['imageObject'])
            reset = app.call('settings-icon', select='openDefault')
            check('reset_bundle_pixels', reset['matchesApplication'] and reset['imageObject'] == 'bundle', state=reset)
            time.sleep(.3)
            capture_window(app.call('settings-state')['settings'], output/'app-icon-settings.png')
            app.quit(); app = launch()
            state = app.call('settings-icon')
            check('default_relaunch', state['selected'] == 'openDefault' and state['applied'] == 'openDefault'
                  and state['matchesApplication'] and state['restoreStartedMs'] is None, state=state)
            # The picker refuses an unknown option through its public socket action.
            try:
                app.call('settings-icon', select='not-an-icon')
                refused = False
            except RuntimeError:
                refused = True
            check('unknown_option_refused', refused and app.call('settings-icon')['applied'] == 'openDefault')
        finally:
            if app: app.quit()
            (output/'results.json').write_text(json.dumps(checks, indent=2))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--config', default='Debug', choices=['Debug', 'Release'])
    args = parser.parse_args()
    run(args.output, args.config)
