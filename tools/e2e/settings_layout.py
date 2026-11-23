#!/usr/bin/env python3
"""Real-App Settings layout rows (UX round 1, lane UXF). Socket input only; no system panels.

Each row reads accessibility frames of the real Settings window over the automation socket:
  settings_info_clears_header   the info box of Site Permissions, Passwords & Cards, Browsing Data
                                and Extensions starts below the header's Profile pill (F5)
  settings_one_popup_style      every pop-up in the detail pane and in the link rule sheet is Open's
                                drawn pop-up (26 pt; the Profile pill 28 pt), none the stock 24 pt one (F6)
  settings_shortcuts_fill_pane  in a 1400 × 1000 window the shortcut list grows past the 352 pt cap and
                                the overlap card still fits in the window (F9)
  settings_download_button      the download location button says "Choose…" (F18)

Usage (hold the on-screen lock):
  lockf -k /tmp/open-onscreen-e2e.lock python3 tools/e2e/settings_layout.py --out DIR [--bundle APP] [--config Debug]
"""
import argparse
import json
import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from engine_e2e import Open  # noqa: E402


def run(out, bundle=None, config='Debug'):
    out.mkdir(parents=True, exist_ok=True)
    data = tempfile.mkdtemp(prefix='open-settings-layout-')
    env = {'OPEN_E2E_APP_BUNDLE': str(bundle)} if bundle else {}
    app = Open(config, 'chrome', data, [], str(out / 'app.log'), extra_env=env)
    results = {}

    def ui(**args):
        return app.call('settings-ui', **args)

    def settle(seconds=.35):
        time.sleep(seconds)
        return ui()

    def row(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('settings-layout %-30s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)
        if not ok:
            app.call('snapshot', window=ui()['window'], path=str(out / (name + '-failure.png')))

    def controls(state, window=None):
        window = window or state['window']
        return [c for c in state['controls'] if c['window'] == window and c['frame'][2] > 0 and c['frame'][3] > 0]

    try:
        app.call('wait', tab=app.call('tabs')[0]['id'])
        app.call('defaults', key='open.general.searchSuggestNoticeDismissed', value=True)
        app.call('menu-perform', id='settings'); settle(1)
        ui(action='resize', width=960, height=660); settle()

        # F5: the inline explanation box clears the Profile pill in the four destination sections.
        rows = []
        for section in ['site-permissions', 'passwords-cards', 'browsing-data', 'extensions']:
            ui(action='open', section=section); s = settle(.5)
            nodes = controls(s)
            pill = next((c for c in nodes if c['label'] == 'Profile'), None)
            info = next((c for c in nodes if c['id'] == 'info.circle'), None)
            # The box draws 12 pt of padding above its icon; the pill sits at the header's bottom.
            box_top = info['frame'][1] - 12 if info else None
            # Extensions is not per-Profile: no pill, so the header's subtitle (ends at y 88) is the limit.
            pill_bottom = pill['frame'][1] + pill['frame'][3] if pill else 88
            rows.append(dict(section=section, boxTop=box_top, pillBottom=pill_bottom,
                             ok=box_top is not None and pill_bottom is not None and box_top >= pill_bottom + 4))
        row('settings_info_clears_header', all(r['ok'] for r in rows), rows=rows)

        # F6: one pop-up style in the panes that had the stock control, and in the link rule sheet.
        heights = []
        for section in ['links', 'tabs-archive', 'search', 'shortcuts', 'profiles']:
            ui(action='open', section=section); s = settle(.5)
            for c in controls(s):
                if c['role'] == 'AXPopUpButton':
                    heights.append(dict(section=section, label=c['label'], height=c['frame'][3]))
        ui(action='link', url='open://settings/links/rules'); settle()
        s = ui(); add = next((c for c in controls(s) if c['label'] == 'Add rule…'), None)
        sheet_heights = []
        if add:
            x, y, w, h = add['frame']
            app.call('key', text='', window=add['window'], route='app')
            app.call('mouse', action='click', queued=True, window=add['window'], x=x + w / 2, y=y + h / 2)
            s = settle(.6)
            if s.get('sheet'):
                sheet_heights = [dict(label=c['label'], height=c['frame'][3]) for c in controls(s, s['sheet']) if c['role'] == 'AXPopUpButton']
                app.call('key', key='escape', window=s['sheet'], route='app'); settle()
        stock = [hgt for hgt in heights + sheet_heights if hgt['height'] not in (26, 28)]
        row('settings_one_popup_style', heights and len(sheet_heights) >= 3 and not stock,
            stock=stock, panes=len(heights), sheet=sheet_heights)

        # F9: a tall window gives the shortcut list the extra height; the overlap card stays in view.
        ui(action='resize', width=1400, height=1000); ui(action='open', section='shortcuts'); s = settle(.8)
        table = next((c for c in controls(s) if c['role'] == 'AXTable' and c['label'] == 'Keyboard shortcuts'), None)
        overlap = next((c for c in controls(s) if c['id'] == 'shortcuts/priority'), None)
        height = s['size'][1]
        row('settings_shortcuts_fill_pane', table is not None and overlap is not None and table['frame'][3] > 560
            and overlap['frame'][1] + overlap['frame'][3] <= height, table=table and table['frame'],
            overlap=overlap and overlap['frame'], window=s['size'])
        ui(action='resize', width=960, height=660); settle()

        # F18: the download location button only says what it does.
        ui(action='open', section='downloads'); s = settle(.5)
        labels = [c['label'] for c in controls(s) if c['role'] == 'AXButton']
        row('settings_download_button', any(l.startswith('Choose download location') for l in labels)
            and not any('· Choose' in l for l in labels), buttons=labels)
    finally:
        (out / 'settings-layout.json').write_text(json.dumps(results, indent=1))
        try:
            w = ui()['window']; app.call('key', key='w', modifiers=['cmd'], window=w, route='app')
        except Exception:
            pass
        app.quit()
    failed = [k for k, v in results.items() if not v['ok']]
    print('settings-layout:', 'PASS' if not failed and results else 'FAIL ' + ', '.join(failed), flush=True)
    return not failed and bool(results)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--config', default='Debug')
    opts = parser.parse_args()
    sys.exit(0 if run(opts.out, opts.bundle, opts.config) else 1)
