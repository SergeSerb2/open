#!/usr/bin/env python3
"""Real App Icon picker, reset and relaunch. Socket actions only; no OS events."""
import argparse
import base64
import json
import plistlib
import subprocess
from pathlib import Path
import tempfile
import time
from engine_e2e import Open
from library_overlay import capture_window


def run(output, config, factory=None):
    """`factory` (engine_e2e's suite factory) records each launch for the gate's owned-process cleanup."""
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    checks = {}
    app = None
    root = Path(__file__).resolve().parents[2]
    probe = output/'icon-readback'
    subprocess.run(['xcrun', 'swiftc', str(root/'tools/release-icon.swift'), '-o', str(probe)], check=True)
    def check(name, ok, **evidence):
        checks[name] = dict(ok=bool(ok), **evidence)
        print(('PASS ' if ok else 'FAIL ') + name, flush=True)
        if not ok and app:
            image = app.call('settings-icon', exportImage=True).get('applicationIconPNG')
            if image: (output/'application-icon-failure.png').write_bytes(base64.b64decode(image))
        assert ok, (name, evidence)
    with tempfile.TemporaryDirectory(prefix='open-icons-') as tmp:
        first = [True]
        def launch():
            if factory is not None:
                fresh, first[0] = first[0], False
                return factory(urls=(), fresh=fresh)
            return Open(config, 'alloy', str(Path(tmp)/'data'), [], str(Path(tmp)/'app.log'), urls=())
        try:
            app = launch()
            info = plistlib.loads((Path(app.bundle)/'Contents/Info.plist').read_bytes())
            check('bundle_icon_declared', info.get('CFBundleIconName') == 'AppIcon' and bool(info.get('CFBundleIconFile')))
            baseline = app.call('settings-icon', exportImage=True)
            before = output/'default-before.png'
            before.write_bytes(base64.b64decode(baseline['applicationIconPNG']))
            app.call('settings-pane', pane='appIcon')
            def bounds(path):
                return json.loads(subprocess.run([str(probe), 'bounds', str(path)], capture_output=True, text=True, check=True).stdout)
            # macOS draws a bundle icon's body 824 of 1024 px, 100 px in (Calculator and Terminal measure the same).
            # A runtime icon is shown as is, so each alternate must carry the same margin (Dock, Cmd-Tab, plug-in).
            grid = bounds(app.bundle)
            check('bundle_icon_grid', all(abs(a - b) <= 2 for a, b in zip(grid, [100, 100, 924, 924])), bounds=grid)
            for option in ['openDefault', 'openDark', 'openLight', 'openMono', 'openColor', 'openRetro']:
                state = app.call('settings-icon', select=option)
                check('select_'+option, state['selected'] == option and state['applied'] == option
                      and state['matchesApplication'] and not state['error'], state=state)
                if option != 'openDefault':
                    cached = sorted((Path(app.user_data)/'Cache/AppIcons').glob(option + '-v*.png'))
                    measured = bounds(cached[-1]) if cached else None
                    check('grid_'+option, measured is not None and all(abs(a - b) <= 2 for a, b in zip(measured, grid)),
                          bounds=measured, bundle=grid, files=[p.name for p in cached])
            first = app.call('settings-icon', select='openDark')
            again = app.call('settings-icon', select='openDark')
            check('cached_alternate', first['imageObject'] == again['imageObject'])
            reset = app.call('settings-icon', select='openDefault', exportImage=True)
            after = output/'default-after-reset.png'
            after.write_bytes(base64.b64decode(reset.pop('applicationIconPNG')))
            compare = subprocess.run([str(probe), 'compare', str(after), str(before)], capture_output=True, text=True)
            check('reset_bundle_pixels', compare.returncode == 0 and reset['imageObject'] == 'bundle',
                  state=reset, pixels=compare.stdout)
            app.call('settings-ui', action='link', url='open://settings/appearance/app-icon')
            check('app_icon_section', app.call('settings-state')['scrollTarget'] == 'appearance/app-icon')
            time.sleep(.3)
            capture_window(app.call('settings-state')['settings'], output/'app-icon-settings.png')
            app.quit(); app = launch()
            state = app.call('settings-icon', exportImage=True)
            relaunched = output/'default-after-relaunch.png'
            relaunched.write_bytes(base64.b64decode(state.pop('applicationIconPNG')))
            compare = subprocess.run([str(probe), 'compare', str(relaunched), str(before)], capture_output=True, text=True)
            check('default_relaunch', state['selected'] == 'openDefault' and state['applied'] == 'openDefault'
                  and compare.returncode == 0 and state['restoreStartedMs'] is None, state=state, pixels=compare.stdout)
            # The picker refuses an unknown option through its public socket action.
            try:
                app.call('settings-icon', select='not-an-icon')
                refused = False
            except RuntimeError as error:
                refused = 'unknown icon' in str(error)
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
