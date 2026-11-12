"""PB5 A7: Undo of an Import from Arc that created Profiles removes them physically (folders and engine
context, through the Profile teardown), not only from the model; that Undo is final (no Redo).
Real paths: Settings ▸ Import wizard, ⌘Z in the browser window. Synthetic two-Profile Arc folder."""
import json
import os
import runpy
from pathlib import Path
from types import SimpleNamespace


def run(factory, results, tmp, root, wait_until):
    source = Path(tmp) / 'import-undo-arc'
    source.mkdir(parents=True, exist_ok=True)
    runpy.run_path(str(Path(root) / 'tools/e2e/firstrun_multiprofile.py'))['fixture'](source, SimpleNamespace(ROOT=root))
    app = factory(urls=(), fresh=True, extra_args=['--host-resolver-rules=MAP * ~NOTFOUND'])
    try:
        def state(): return app.call('first-run')
        def profiles():
            with open(app.call('save')) as f: return [(p['id'], p['dataDirectoryName']) for p in json.load(f)['profiles']]
        before = profiles()
        app.call('first-run', action='settings-import', directory=str(source))
        app.call('first-run', action='settings-next')
        app.call('first-run', action='settings-run')
        report = wait_until(lambda: (lambda s: s if s.get('settingsStep') == 'report' else None)(state()), timeout=120, step=.05) or state()
        created = report.get('importCreatedProfiles', [])
        after_import = profiles()
        folders = {d: os.path.isdir(os.path.join(app.user_data, 'Profiles', d)) for d in created}
        try: app.call('first-run', action='settings-done')
        except RuntimeError: pass
        app.call('window-focus', id=app.call('shell-windows')[0]['id'], activate=True)
        app.call('sidebar-key', key='z', modifiers=['command'])
        wait_until(lambda: not state().get('importUndoInProgress', False), timeout=60, step=.05)
        undone = state()
        after_undo = profiles()
        gone = {d: not os.path.isdir(os.path.join(app.user_data, 'Profiles', d)) for d in created}
        redo = next((r for r in app.call('menu-state') if r['id'] == 'redo'), {})
        results['import_undo_removes_created_profiles'] = {
            'ok': len(before) == 1 and len(created) >= 1 and all(folders.values()) and len(after_import) == len(before) + len(created)
                and sorted(undone.get('importWipedProfiles', [])) == sorted(created) and all(gone.values())
                and [d for _, d in after_undo] == [d for _, d in before] and not undone.get('importUndoError'),
            'before': before, 'created': created, 'foldersAfterImport': folders, 'afterUndo': after_undo,
            'wiped': undone.get('importWipedProfiles'), 'gone': gone, 'error': undone.get('importUndoError')}
        results['import_undo_final_no_redo'] = {
            'ok': 'Import' not in redo.get('title', '') or redo.get('enabled') is False, 'redo': redo}
    finally:
        app.quit()
