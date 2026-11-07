"""C2's separate real-App import block. Runtime gates remain explicit BLOCKED."""
import os
import runpy
import shutil
import time
from pathlib import Path


def run(factory, results, tmp, h):
    root = Path(h.ROOT)
    generator = runpy.run_path(str(root / 'tools/e2e/fixtures/import-boosts/generate.py'))
    cli = runpy.run_path(str(root / 'tools/e2e/import_boosts_cli.py'))
    source = Path(tmp) / 'arc-boosts-app'
    # The harness retries after focus loss in the same scratch root.
    shutil.rmtree(source, ignore_errors=True)
    generator['write'](source)
    binary = root / 'Packages/OpenKit/.build/release/openkit'
    app = None
    saved = {}
    def row(name, ok, **detail):
        results[name] = dict(ok=bool(ok), load=os.getloadavg(), **detail)
    def rendered_boost_row(name):
        inspection = app.call('first-run', action='inspect', timeout=180)
        lines = inspection['renderedText']
        labels = [line for line in lines if line['text'].startswith('Boosts')]
        assert len(labels) == 1, lines
        label = labels[0]
        middle = label['frame'][1] + label['frame'][3] / 2
        aligned = [line for line in lines
                   if abs(line['frame'][1] + line['frame'][3] / 2 - middle) < 8]
        text = ' '.join(line['text'] for line in sorted(aligned, key=lambda line: line['frame'][0]))
        path = Path(h.OUT) / 'firstrun' / ('boosts-' + name + '.png')
        path.parent.mkdir(exist_ok=True)
        app.call('snapshot', path=str(path), window=inspection['window'])
        width, height, pixel = h.read_image(str(path), srgb=True)
        sy = height / inspection['frameSize'][1]
        # Only the value half of the Boosts row, excluding its label and other rows.
        red = sum(r > g + 40 and r > b + 20
                  for y in range(int((middle - 9) * sy), int((middle + 9) * sy))
                  for x in range(int(width * .45), int(width * .95))
                  for r, g, b in [pixel(x, y)])
        # Vision can omit a single isolated digit. Check the native zero's
        # visible ring as well as its real outcome, rather than accepting
        # a blank row because the model says zero.
        left, right = int(width * .88), int(width * .95)
        top, bottom = int((middle - 9) * sy), int((middle + 9) * sy)
        area = {(x, y) for y in range(top, bottom) for x in range(left, right)}
        ink = {point for point in area if min(pixel(*point)) > 120}
        remaining = area - ink
        holes = []
        while remaining:
            seed = remaining.pop(); component = {seed}; pending = [seed]
            while pending:
                x, y = pending.pop()
                for point in ((x-1, y), (x+1, y), (x, y-1), (x, y+1)):
                    if point in remaining:
                        remaining.remove(point); component.add(point); pending.append(point)
            if not any(x in (left, right-1) or y in (top, bottom-1) for x, y in component):
                holes.append(len(component))
        state = app.call('first-run')
        return dict(text=text, redPixels=red, valueInkPixels=len(ink), enclosedAreas=holes,
                    count=state['outcome'].get('Boosts'), failure=state['failures'].get('Boosts'), png=str(path))
    try:
        app = factory(urls=(), fresh=True, extra_args=['--arc-dir=' + str(source)])
        for key in ('open.firstRun.completed', 'open.import.lastArcDir', 'open.settings.lastPane'):
            saved[key] = app.call('defaults', key=key, persistent=True)
            app.call('defaults', key=key, value=None)
        app.call('first-run', action='focus')
        assert h.wait_until(lambda: app.call('first-run').get('probeReady'), timeout=20, step=.05)
        app.call('first-run', action='import')
        # A source without a cache must fail the same count predicate; restore
        # the populated synthetic source before the import.
        empty = Path(tmp) / 'arc-boosts-empty'
        shutil.rmtree(empty, ignore_errors=True)
        generator['write'](empty)
        shutil.rmtree(empty / 'Firestore')
        app.call('first-run', action='choose-dir', directory=str(empty))
        assert h.wait_until(lambda: app.call('first-run').get('probeReady'), timeout=20, step=.05)
        negative_probe = app.call('first-run')['counts'].get('Boosts') == 2
        app.call('first-run', action='choose-dir', directory=str(source))
        assert h.wait_until(lambda: app.call('first-run').get('probeReady'), timeout=20, step=.05)
        probe = app.call('first-run')
        row('boost_app_probe', probe['counts'].get('Boosts') == 2 and not negative_probe, negativeProof='FAIL' if not negative_probe else 'NOT PROVEN')
        refused = cli['invoke'](binary, source, Path(app.user_data))
        # Negative proof for the refusal gate: a different free root is allowed,
        # so applying that same refusal assertion must produce FAIL.
        allowed = cli['invoke'](binary, source, Path(tmp) / 'boost-lock-negative-free-root')
        broken_condition = allowed.returncode != 0 and 'lock data root' in allowed.stderr
        row('boost_cli_app_lock', refused.returncode != 0 and 'lock data root' in refused.stderr
            and not list(Path(app.user_data).glob('Profiles/*/Boosts/boosts.json'))
            and allowed.returncode == 0 and not broken_condition,
            negativeProof='FAIL' if not broken_condition else 'NOT PROVEN', reason='CLI writes to a free temp root')
        def report_seam(state):
            counts = state.get('outcome') or {}
            failures = state.get('failures') or {}
            return counts.get('Boosts found') == 2 and counts.get('Boosts') == 0 and counts.get('Boosts malformed') == 1 and failures.get('Boosts') == 'Not imported in this build' and not list(Path(app.user_data).glob('Profiles/*/Boosts/boosts.json'))
        negative_report = report_seam(app.call('first-run'))  # before import
        app.call('first-run', action='continue')
        assert h.wait_until(lambda: app.call('first-run')['step'] == 'report', timeout=30, step=.05)
        state = app.call('first-run')
        row('boost_app_report_seam', report_seam(state) and not negative_report,
            negativeProof='FAIL' if not negative_report else 'NOT PROVEN')
        populated = rendered_boost_row('found')
        def unavailable(value):
            return 'Boosts Not imported in this build' == value['text'] and value['redPixels'] > 10
        def zero(value):
            return value['text'] in ('Boosts', 'Boosts 0') and value['count'] == 0 and value['failure'] is None \
                and value['redPixels'] == 0 and value['valueInkPixels'] > 10 \
                and len(value['enclosedAreas']) == 1 and value['enclosedAreas'][0] > 2
        app.quit()
        app = factory(urls=(), fresh=True, extra_args=['--arc-dir=' + str(empty)])
        app.call('first-run', action='focus')
        assert h.wait_until(lambda: app.call('first-run').get('probeReady'), timeout=20, step=.05)
        app.call('first-run', action='import')
        app.call('first-run', action='continue')
        assert h.wait_until(lambda: app.call('first-run')['step'] == 'report', timeout=30, step=.05)
        absent = rendered_boost_row('empty')
        # Swap the real populated/empty outcomes: each native row must reject
        # the opposite input, including the text color captured from the window.
        row('boost_app_report_unavailable_red', unavailable(populated) and not unavailable(absent),
            negativeProof='FAIL' if not unavailable(absent) else 'NOT PROVEN', **populated)
        row('boost_app_report_empty_zero', zero(absent) and not zero(populated),
            negativeProof='FAIL' if not zero(populated) else 'NOT PROVEN', **absent)
        # These rows require Section 12's sole live store owner. They cannot
        # pass on the report-only seam or a direct BoostStore/file write.
        for name in ('boost_app_imported_count', 'boost_app_matching_page', 'boost_app_disabled',
                     'boost_app_reimport', 'boost_app_undo', 'boost_app_page_cleared'):
            results[name] = dict(status='BLOCKED', reason='Section 12 AppBoosts (app.stores.boosts)', load=os.getloadavg())
    finally:
        if app:
            h._restore_defaults(app, saved)
            app.quit()
