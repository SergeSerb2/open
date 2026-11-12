#!/usr/bin/env python3
"""Library rail: each item draws its glyph and exactly one label (light and dark).

LEAD 05:55: every rail item drew its label twice (NSButton's own cell title over the glyph plus
Open's text layer below it). The row reads each rail item's `drawnLabels` from the real panel
and saves the real window in both appearances. Run:
python3 tools/e2e/library_rail_labels.py --output DIR [--config Release] [--bundle APP]
"""
import argparse
import json
from pathlib import Path
import tempfile
import time

from engine_e2e import Open
from library_overlay import capture_window


def run(output, config='Release', bundle=None):
    output.mkdir(parents=True, exist_ok=True)
    result = {'checks': {}}
    app = None
    with tempfile.TemporaryDirectory(prefix='open-library-rail-') as data:
        try:
            app = Open(config, 'chrome', data, [], str(output / 'app.log'),
                       extra_env={'OPEN_E2E_APP_BUNDLE': str(bundle)} if bundle else {})
            owner = app.call('shell-windows')[0]['id']
            app.call('window-focus', id=owner, activate=True)
            for name in ('light', 'dark'):
                app.call('appearance', name=name); time.sleep(1.0)
                app.call('library', action='open', section='downloads'); time.sleep(1.5)
                state = app.call('library')
                rail = state.get('rail', [])
                labels = {item['id']: item.get('drawnLabels') for item in rail}
                ok = len(rail) >= 6 and all(count == 1 for count in labels.values())
                result['checks']['rail_one_label_' + name] = {'ok': ok, 'drawnLabels': labels}
                print(('PASS' if ok else 'FAIL') + ' rail_one_label_' + name, labels, flush=True)
                capture_window(state['window'], output / ('library-rail-' + name + '.png'))
                app.call('library', action='close'); time.sleep(.8)
            app.call('appearance', name='system')
        except Exception as error:
            result['checks']['flow_completed'] = {'ok': False, 'error': repr(error)}
            print('FAIL flow_completed', repr(error), flush=True)
        finally:
            if app:
                app.quit()
                result['cleanup'] = getattr(app, 'quit_report', {})
    result['ok'] = all(c['ok'] for c in result['checks'].values()) and bool(result.get('cleanup', {}).get('ok'))
    (output / 'results-library-rail-labels.json').write_text(json.dumps(result, indent=2, default=str))
    print('suite ' + ('PASS' if result['ok'] else 'FAIL'), flush=True)
    return result['ok']


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--config', choices=['Debug', 'Release'], default='Release')
    parser.add_argument('--bundle', type=Path)
    args = parser.parse_args()
    raise SystemExit(0 if run(args.output, args.config, args.bundle) else 1)
