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
        # These rows require Section 12's sole live store owner. They cannot
        # pass on the report-only seam or a direct BoostStore/file write.
        for name in ('boost_app_imported_count', 'boost_app_matching_page', 'boost_app_disabled',
                     'boost_app_reimport', 'boost_app_undo', 'boost_app_page_cleared'):
            results[name] = dict(status='BLOCKED', reason='Section 12 AppBoosts (app.stores.boosts)', load=os.getloadavg())
    finally:
        if app:
            h._restore_defaults(app, saved)
            app.quit()
