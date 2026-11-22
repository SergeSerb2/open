"""Bug sweep r6 seed 7: a key bindings file with one command ID this build does not know.

The whole file used to be dropped (every custom shortcut lost). Lead ruling: the known bindings
apply, only the unknown ID is ignored, and loading never rewrites the file (another build keeps
its binding). Run by the commandbar suite; OPEN_COMMANDBAR_R6_KEYS_ONLY=1 runs only this row.
"""
import json
import time
from pathlib import Path


def run(factory, results):
    app = factory(urls=('about:blank',), fresh=True)
    bindings = Path(app.user_data, 'State/keybindings.json')
    try:
        mixed = json.dumps({'version': 1, 'bindings': {
            'new-tab': {'shortcuts': [{'key': 'o', 'modifiers': ['command', 'option', 'control']}]},
            'r6-command-from-a-later-build': {'shortcuts': [{'key': 'j', 'modifiers': ['command', 'option', 'control']}]}}})
        bindings.parent.mkdir(parents=True, exist_ok=True)
        bindings.write_text(mixed)
        app.call('reload-keybindings'); time.sleep(.1)
        keys = sorted({n['key'] for n in app.call('menu-state') if n['id'] == 'new-tab'})
        kept = bindings.read_text() == mixed
        ok = keys == ['o'] and kept
        results['R6_unknown_binding_keeps_known'] = {'ok': ok, 'newTabKeys': keys, 'fileKept': kept}
        print('R6_unknown_binding_keeps_known', 'PASS' if ok else 'FAIL', keys, flush=True)
    finally:
        bindings.unlink(missing_ok=True)
        app.quit()
