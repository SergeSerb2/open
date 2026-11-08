"""Arc Boost import through first run, Settings, the sole store and live pages."""
import os
import json
import http.server
import threading
from contextlib import contextmanager
import runpy
import shutil
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
    def gate(name, positive, broken, **detail):
        # The same predicate must fail against real pre-action or deliberately
        # changed App state, then pass after the condition is restored.
        print(name, 'negative', 'FAIL' if not broken else 'NOT PROVEN', flush=True)
        row(name, positive and not broken,
            negativeProof='FAIL' if not broken else 'NOT PROVEN', **detail)
    def launch(source):
        nonlocal app
        app = factory(urls=(), fresh=True, extra_args=['--arc-dir=' + str(source),
            '--host-resolver-rules=MAP example.com 127.0.0.1, MAP * ~NOTFOUND', '--no-proxy-server'])
        for key, value in {'open.firstRun.completed': None, 'open.import.lastArcDir': None,
                           'open.settings.lastPane': None, 'open.advanced.enableBoosts': True,
                           'open.advanced.tabSleepMode': 'never', 'open.library.lastSection': 'spaces'}.items():
            if key not in saved: saved[key] = app.call('defaults', key=key, persistent=True)
            app.call('defaults', key=key, value=value)
        app.call('first-run', action='focus')
        assert h.wait_until(lambda: app.call('first-run').get('probeReady'), timeout=20, step=.05)
    def first_import():
        app.call('first-run', action='import')
        app.call('first-run', action='continue')
        assert h.wait_until(lambda: app.call('first-run')['step'] == 'report', timeout=30, step=.05)
        return app.call('first-run')
    def settings_import():
        app.call('first-run', action='settings-import', directory=str(source))
        app.call('first-run', action='settings-select', history=False)
        app.call('first-run', action='settings-next')
        app.call('first-run', action='settings-run')
        assert h.wait_until(lambda: app.call('first-run')['settingsStep'] == 'Report', timeout=30, step=.05)
        state = app.call('first-run')
        app.call('first-run', action='settings-done')
        return state
    def items(): return app.call('boosts')
    def native_undo(redo=False):
        window = app.call('shell-windows')[0]['id']
        app.call('window-focus', id=window, activate=True)
        app.call('sidebar-key', key='z', modifiers=['command', 'shift'] if redo else ['command'])
        assert h.wait_until(lambda: not app.call('first-run')['importUndoInProgress'], timeout=30, step=.02)
        assert not app.call('first-run')['importUndoError']
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
        # Vision can omit an isolated digit. Check visible ink as well as
        # the outcome; the zero case also requires its enclosed ring.
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
        launch(source)
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
        def imported_count(state):
            counts = state.get('outcome') or {}
            failures = state.get('failures') or {}
            return counts.get('Boosts found') == 2 and counts.get('Boosts') == 2 \
                and counts.get('Boosts malformed') == 1 and failures.get('Boosts') is None
        negative_count = imported_count(app.call('first-run'))
        app.call('first-run', action='continue')
        assert h.wait_until(lambda: app.call('first-run')['step'] == 'report', timeout=30, step=.05)
        state = app.call('first-run')
        populated = rendered_boost_row('found')
        assert h.wait_until(lambda: sum(len(json.loads(file.read_text())['boosts'])
            for file in Path(app.user_data).glob('Profiles/*/Boosts/boosts.json')) == 2,
            timeout=5, step=.05)
        app.call('first-run', action='continue')
        app.call('first-run', action='finish')
        first_run_undo_broken = len(items()) == 0
        native_undo()
        gate('boost_app_first_run_undo', len(items()) == 0, first_run_undo_broken, stored=len(items()))
        first_run_redo_broken = len(items()) == 2
        native_undo(redo=True)
        gate('boost_app_first_run_redo', len(items()) == 2, first_run_redo_broken, stored=len(items()))
        def added(value):
            return value['text'] in ('Boosts', 'Boosts 2') and value['count'] == 2 \
                and value['failure'] is None and value['redPixels'] == 0 and value['valueInkPixels'] > 10
        def unreadable(value):
            return value['text'] == 'Boosts Could not be read' and value['redPixels'] > 10
        def zero(value):
            return value['text'] in ('Boosts', 'Boosts 0') and value['count'] == 0 and value['failure'] is None \
                and value['redPixels'] == 0 and value['valueInkPixels'] > 10 \
                and len(value['enclosedAreas']) == 1 and value['enclosedAreas'][0] > 2
        # Flush through normal App shutdown, then read only the synthetic DTO.
        app.quit()
        files = list(Path(app.user_data).glob('Profiles/*/Boosts/boosts.json'))
        stored = [boost for file in files for boost in json.loads(file.read_text())['boosts']]
        gate('boost_app_imported_count', imported_count(state) and len(stored) == 2,
             negative_count, stored=len(stored), counts=state['outcome'])
        launch(empty)
        first_import()
        absent = rendered_boost_row('empty')
        gate('boost_app_report_added', added(populated), added(absent), **populated)
        gate('boost_app_report_empty_zero', zero(absent), zero(populated), **absent)
        app.quit()
        broken = Path(tmp) / 'arc-boosts-unreadable'
        shutil.rmtree(broken, ignore_errors=True)
        generator['write'](broken)
        (broken / 'Firestore/main/CURRENT').write_text('invalid manifest\n')
        launch(broken)
        first_import()
        failed = rendered_boost_row('unreadable')
        gate('boost_app_report_unreadable_red', unreadable(failed), unreadable(populated), **failed)
        app.quit()

        # Settings must map Arc Default to this independently created live
        # Default by role. Keep a page open before import so Undo leaves it live.
        with fixture_server() as origin:
            launch(source)
            app.call('first-run', action='fresh')
            default_id = next(p['id'] for p in json.loads(Path(app.call('save')).read_text())['profiles']
                              if p['dataDirectoryName'] == 'Default')
            tab = h.new_tab(app, origin)
            def style():
                return app.eval(tab, "({outline:getComputedStyle(document.body).outlineColor,"
                    "outlineWidth:getComputedStyle(document.body).outlineWidth,"
                    "border:getComputedStyle(document.body).borderTopWidth})")
            def boosted(value):
                return value['outline'] == 'rgb(1, 2, 3)' and value['outlineWidth'] == '3px'
            def cleared(value):
                return value['outlineWidth'] == '0px' and value['border'] == '0px'
            def reload():
                app.call('devtools', tab=tab, method='Page.reload'); app.call('wait', tab=tab)
            baseline = style()
            first = settings_import()
            assert h.wait_until(lambda: boosted(style()), timeout=10, step=.05)
            initial = items()
            enabled = next(b for b in initial if b['isEnabled'])
            disabled = next(b for b in initial if not b['isEnabled'])
            gate('boost_app_matching_page', boosted(style()) and len(app.call('boosts', profile=default_id)) == 2
                 and len(json.loads(Path(app.call('save')).read_text())['profiles']) == 1,
                 boosted(baseline), computed=style(), profileMappedByRole=True)
            app.call('command', id='view-boosts')
            assert h.wait_until(lambda: app.call('settings-state')['librarySection'] == 'boosts', timeout=5, step=.05)
            app.call('boost-library', action='enabled', boost=disabled['id'], enabled=True)
            assert h.wait_until(lambda: style()['border'] == '7px', timeout=5, step=.05)
            disabled_broken = style()['border'] == '0px'
            app.call('boost-library', action='enabled', boost=disabled['id'], enabled=False)
            assert h.wait_until(lambda: style()['border'] == '0px', timeout=5, step=.05)
            app.call('library-close')
            gate('boost_app_disabled', style()['border'] == '0px' and not next(b for b in items() if b['id'] == disabled['id'])['isEnabled'],
                 disabled_broken, computed=style())
            # Toggling proves disabled CSS, but changes updatedAt. Capture the
            # actual values immediately before the add-only repeat.
            initial = items()
            second = settings_import()
            def no_add(state):
                return state['settingsOutcome'].get('Boosts') == 0 and state['settingsOutcome'].get('Boost duplicates') == 2
            gate('boost_app_reimport', no_add(second) and items() == initial,
                 no_add(first), outcome=second['settingsOutcome'])
            undo_broken, cleared_broken = len(items()) == 0, cleared(style())
            native_undo()
            gate('boost_app_undo', len(items()) == 0, undo_broken, stored=len(items()))
            reload()
            assert h.wait_until(lambda: cleared(style()), timeout=10, step=.05)
            after_undo = style()
            gate('boost_app_page_cleared', cleared(after_undo), cleared_broken, computed=after_undo)
            redo_broken = len(items()) == 2 and boosted(style())
            native_undo(redo=True)
            reload()
            assert h.wait_until(lambda: boosted(style()), timeout=10, step=.05)
            gate('boost_app_redo', len(items()) == 2 and boosted(style()) and style()['border'] == '0px',
                 redo_broken, stored=len(items()), computed=style())
            # Edit through the real Library caller, then re-import the source
            # with the same stable IDs. Compare the entire stored record.
            edited_name = 'Example user-edited Boost'
            duplicate_broken = next(b for b in items() if b['id'] == enabled['id'])['name'] == edited_name
            app.call('command', id='view-boosts')
            assert h.wait_until(lambda: app.call('settings-state')['librarySection'] == 'boosts', timeout=5, step=.05)
            app.call('boost-library', action='rename', boost=enabled['id'], name=edited_name)
            app.call('library-close')
            edited = next(b for b in items() if b['id'] == enabled['id'])
            repeat = settings_import()
            gate('boost_app_duplicate_add_only', no_add(repeat)
                 and next(b for b in items() if b['id'] == enabled['id']) == edited,
                 duplicate_broken, outcome=repeat['settingsOutcome'], editedNameRetained=True)
            app.quit()
    finally:
        try:
            h._restore_defaults(app if app and not app.closed else None, saved)
        finally:
            if app: app.quit()


@contextmanager
def fixture_server():
    """An example.com page served only from an ephemeral loopback socket."""
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = b'<!doctype html><title>Example import Boost</title><body><h1>Example</h1><div id="example-promo">Example promo</div></body>'
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers(); self.wfile.write(body)
        def log_message(self, *args): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield 'http://example.com:%d/' % server.server_address[1]
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=5)
