#!/usr/bin/env python3
"""Real App Icon picker, reset and relaunch, and the real Dock tile. Socket actions only; no OS events."""
import argparse
import base64
import json
import math
import os
import plistlib
import subprocess
from pathlib import Path
import tempfile
import time
from engine_e2e import Open
from library_overlay import capture_window


DOCK_REFERENCES = ['Mail', 'Calculator', 'Finder']  # Apple icons; Finder is always in the Dock.


class RealDock:
    """Open's real Dock tile against an Apple icon's tile in the same capture. Read-only: the Dock's accessibility
    frames and a screen capture, never input or Dock settings. It runs only where the Dock stays visible on a 2x
    panel with the accessibility and pixel grants (the M1 rule); elsewhere it reports why it did not run."""

    def __init__(self, root, output):
        self.output = output
        self.helper = output/'dock-tiles'
        subprocess.run(['xcrun', 'swiftc', '-O', str(root/'tools/e2e/dock-tiles.swift'), '-o', str(self.helper)], check=True)
        self.pixels = root/'tools/capture/pixels.sh'
        self.launcher = Path.home()/'Applications/OpenCapture.app'
        autohide = subprocess.run(['defaults', 'read', 'com.apple.dock', 'autohide'], capture_output=True, text=True).stdout.strip()
        frames = self.frames()
        self.skip = ('the Dock auto-hides' if autohide in ('1', 'true') else
                     'no accessibility grant to read Dock frames' if not frames['trusted'] else
                     'the main display is not 2x' if frames['scale'] != 2 else None)

    def frames(self):
        return json.loads(subprocess.run([str(self.helper), 'frames'], capture_output=True, text=True, check=True).stdout)

    def capture(self, region, path):
        command = ['/usr/sbin/screencapture', '-x', '-R', ','.join(map(str, region)), str(path)]
        if self.launcher.exists():  # the approved pixel launcher (library_overlay.capture_window)
            log = path.with_suffix('.pixels.log')
            subprocess.run(['/usr/bin/open', '-n', '-W', str(self.launcher), '--args', str(self.pixels), str(log), *command], timeout=15)
            return Path(str(log) + '.rc').read_text().strip() == '0' and path.is_file()
        return subprocess.run(command, timeout=15).returncode == 0 and path.is_file()

    def measure(self, bundle, name):
        """Plate geometry (2x px) of Open's tile and the first Apple reference tile in one Dock capture."""
        frames = self.frames()
        target = os.path.realpath(bundle)
        tiles = frames['tiles']
        mine = [t for t in tiles if t['url'] and os.path.realpath(t['url']) == target]
        reference = next((t for title in DOCK_REFERENCES for t in tiles if t['title'] == title), None)
        if len(mine) != 1 or reference is None:
            return dict(error='Dock tiles not found', open=len(mine), reference=reference)
        x0 = math.floor(min(t['x'] for t in tiles)); y0 = math.floor(min(t['y'] for t in tiles))
        x1 = math.ceil(max(t['x'] + t['w'] for t in tiles)); y1 = math.ceil(max(t['y'] + t['h'] for t in tiles))
        path = self.output/('dock-' + name + '.png')
        if not self.capture([x0, y0, x1 - x0, y1 - y0], path):
            return dict(error='screen capture failed (no pixel grant?)')
        def geometry(tile):
            rect = [round((tile['x'] - x0) * 2), round((tile['y'] - y0) * 2), round(tile['w'] * 2), round(tile['h'] * 2)]
            out = subprocess.run([str(self.helper), 'measure', str(path), *map(str, rect)], capture_output=True, text=True, check=True)
            return dict(json.loads(out.stdout), rect=rect)
        return dict(open=geometry(mine[0]), reference=dict(geometry(reference), title=reference['title']), capture=path.name)


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
        fresh_next = [True]
        def launch():
            if factory is not None:
                fresh, fresh_next[0] = fresh_next[0], False
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
            # A runtime icon is shown as is, so each alternate carries that margin itself (Dock, Cmd-Tab, plug-in),
            # with the body scaled 1.015 and lifted 5 px, because the Dock draws a runtime image that much smaller
            # and lower (tools/generate-app-icons.sh; the real Dock rows below measure the result).
            grid = bounds(app.bundle)
            check('bundle_icon_grid', all(abs(a - b) <= 2 for a, b in zip(grid, [100, 100, 924, 924])), bounds=grid)
            middle, half = (grid[0] + grid[2]) / 2, (grid[2] - grid[0]) / 2 * 1.015
            runtime_grid = [middle - half, middle - half - 5, middle + half, middle + half - 5]
            # The bundle icon is an Icon Composer document: Assets.car holds its layered image stack, so macOS draws
            # the squircle, rim and glass itself (a flat PNG icon set has no IconImageStack rendition).
            car = subprocess.run(['xcrun', 'assetutil', '--info', str(Path(app.bundle)/'Contents/Resources/Assets.car')],
                                 capture_output=True, text=True)
            stacks = sorted({r.get('Name') for r in (json.loads(car.stdout)[1:] if car.returncode == 0 else [])
                             if r.get('AssetType') == 'IconImageStack'})
            check('bundle_icon_native', 'AppIcon' in stacks, imageStacks=stacks)
            dock = RealDock(root, output)
            if dock.skip:
                print('SKIP real Dock rows: ' + dock.skip, flush=True)
                (output/'dock-rows-skipped.txt').write_text(dock.skip + '\n')
            for option in ['openDefault', 'openDark', 'openLight', 'openMono', 'openColor', 'openRetro']:
                state = app.call('settings-icon', select=option)
                check('select_'+option, state['selected'] == option and state['applied'] == option
                      and state['matchesApplication'] and not state['error'], state=state)
                if option != 'openDefault':
                    cached = sorted((Path(app.user_data)/'Cache/AppIcons').glob(option + '-v*.png'))
                    measured = bounds(cached[-1]) if cached else None
                    check('grid_'+option, measured is not None and all(abs(a - b) <= 2 for a, b in zip(measured, runtime_grid)),
                          bounds=measured, expected=runtime_grid, files=[p.name for p in cached])
                if not dock.skip:
                    # The Dock redraws a changed application icon within a frame or two; allow a generous second.
                    time.sleep(1)
                    tile = dock.measure(app.bundle, option)
                    mine, apple = tile.get('open'), tile.get('reference')
                    check('dock_found_'+option, mine is not None and apple is not None, tile=tile)
                    # Plate width and top edge within 1 px (2x) of the Apple tile. (A dark plate's bottom rim can match
                    # the Dock behind it, so the bottom edge is not a reliable measure.)
                    check('dock_size_'+option, abs(mine['width'] - apple['width']) <= 1 and abs(mine['top'] - apple['top']) <= 1, tile=tile)
                    # Corner profile: the squircle's left-edge insets 2 ... 16 px below the top, each within 1.5 px.
                    # Apple's own tiles spread 0.6 px at 2 px (Mail 12.4, Calculator 12.2, Safari 12.0, Finder 11.8);
                    # the flat art's smaller circular corner measured 8.8.
                    check('dock_corner_'+option, max(abs(a - b) for a, b in zip(mine['corner'][1:], apple['corner'][1:])) <= 1.5, tile=tile)
                    # The system's light rim on the plate's top edge: Apple tiles measure about +30, flat art about 0.
                    # A bright plate shows little of it (Safari about 0, Spectrum about +9), so only plates at or below
                    # luminance 160 are judged: Original, Midnight and Graphite.
                    if mine['plate'] <= 160:
                        check('dock_rim_'+option, mine['rim'] >= 12, tile=tile)
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
