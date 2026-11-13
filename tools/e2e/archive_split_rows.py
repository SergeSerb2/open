#!/usr/bin/env python3
"""Split Archive Item → ordinary tab rows → native hover, Peek, Restore/Delete.

Uses only the real App socket and isolated synthetic loopback pages.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from engine_e2e import Open, new_tab, wait_until
from downloads import server
from library_overlay import capture_window


def run(output, frames=False):
    output.mkdir(parents=True, exist_ok=True)
    result = {'checks': {}}
    app = None
    def check(name, ok, **evidence):
        result['checks'][name] = dict(ok=bool(ok), **evidence)
        print(('PASS ' if ok else 'FAIL ') + name, flush=True)
        if not ok:
            if app:
                for label, command in [('library', 'library'), ('peek', 'peek-state'), ('bar', 'commandbar-state'), ('focus', 'focus-state')]:
                    try: result[label] = app.call(command)
                    except Exception as error: result[label] = repr(error)
            raise AssertionError(name + ': ' + repr(evidence))
    def wait(fn): return wait_until(fn, timeout=8, step=.05)
    def state(**kw): return app.call('library', **kw)
    def row(id): return next((r for r in state().get('rows', []) if r['id'] == id), {})
    def key(name, mods=()): return app.call('key', key=name, modifiers=list(mods), route='app')
    def pointer(action, box, dx=None):
        # Library's cached rows can arrive before its sidebar fade finishes.
        # Wait for the real hit surface, rather than clicking through that sidebar.
        assert wait(lambda: not app.call('window-state')['sidebarVisible']), 'Library sidebar fade did not finish'
        x, y, w, h = box
        return app.call('mouse', action=action, queued=True, window=state()['window'], x=x+(w/2 if dx is None else dx), y=y+h/2)
    def archive_rows(): return app.call('archive-list')['rows']
    def open_preview(id):
        box = row(id)['frame']
        pointer('click', box, 90)
        return wait(lambda: app.call('peek-state')['shown'])
    def dismiss(name, mods=()):
        key(name, mods)
        return wait(lambda: not app.call('peek-state')['shown'])
    with tempfile.TemporaryDirectory(prefix='open-archive-split-') as data, server() as base:
        try:
            app = Open('Debug', 'chrome', data, [], str(output/'app.log'), urls=(base+'/arm?s1',))
            app.call('defaults', key='open.sidebar.hideHintShown', value=True)
            first = app.call('tabs')[0]['id']; app.call('wait', tab=first)
            second = new_tab(app, base+'/arm?s2')
            space = next(s for s in app.call('spaces') if s['focused'])
            app.call('window-frame', frame=[0, 40, 1280, 800], unconstrained=True)
            owner = app.call('shell-windows')[0]['id']; app.call('window-focus', id=owner, activate=True)
            app.call('split'); split = app.call('split', op='state')
            check('real_two_pane_split', {p['id'] for p in split['panes']} == {first, second}, split=split)
            app.call('sidebar-menu', node=split['id'], item='Archive Item')
            check('split_becomes_two_tab_records', wait(lambda: len(archive_rows()) == 2)
                  and {r['id'] for r in archive_rows()} == {first, second}
                  and all(r['kind'] == 'tab' and r['space'] == space['id'] and r['profile'] == space['profile']
                          and r['originalLocation'] == 'split:'+split['id'] for r in archive_rows()), rows=archive_rows())
            check('archived_panes_leave_sidebar', not any(t['id'] in {first, second} for t in app.call('tabs')))
            check('empty_space_preview_context', not app.call('tabs'))
            state(action='open', section='archive'); check('two_library_rows', wait(lambda: bool(row(first) and row(second))))
            before_records = archive_rows(); before_tabs = {t['id'] for t in app.call('tabs')}
            for width in [1280, 900]:
                app.call('window-frame', frame=[0, 40, width, 800], unconstrained=True)
                for id in [first, second]:
                    state(action='row-select', id=id)
                    for side in ['left', 'tail']:
                        box = row(id)['frame']; pointer('hover', box, 80 if side == 'left' else box[2]-28)
                        check(f'hover_{width}_{id == second}_{side}', wait(lambda: row(id).get('buttonToolTips') == ['Delete', 'Restore']), row=row(id))
                    # Move out through real tracking; selection survives with hidden controls.
                    app.call('mouse', action='hover', window=state()['window'], x=600, y=110)
                    check(f'away_{width}_{id == second}', wait(lambda: not row(id).get('buttonToolTips')) and row(id)['selected'], row=row(id))
                    check(f'title_peek_{width}_{id == second}', open_preview(id), peek=app.call('peek-state'))
                    peek = app.call('peek-state')['stack'][-1]
                    expected = next(r['url'] for r in before_records if r['id'] == id)
                    check(f'preview_preserves_{width}_{id == second}', state()['open'] and archive_rows() == before_records
                          and {t['id'] for t in app.call('tabs')} == before_tabs and peek['url'] == expected
                          and peek['profile'] == space['profile'] and peek['librarySpace'] == space['id'])
                    check(f'escape_peek_{width}_{id == second}', dismiss('escape') and state()['open'] and bool(row(id)))
            # Standard real application keys in the new Peek-over-Library focus context.
            check('cmd_w_preview_open', open_preview(first))
            check('cmd_w_only_dismisses_peek', dismiss('w', ['cmd']) and state()['open'] and archive_rows() == before_records)
            for name in ['t', 'l']:
                check('cmd_'+name+'_preview_open', open_preview(first))
                key(name, ['cmd'])
                check('cmd_'+name+'_command_bar', wait(lambda: app.call('commandbar-state')['presented'])
                      and app.call('commandbar-state')['mode'] == ('newTab' if name == 't' else 'editCurrentURL'))
                key('escape')
                check('cmd_'+name+'_bar_escape', wait(lambda: not app.call('commandbar-state')['presented']
                      and app.call('commandbar-state')['hidden']) and state()['open'])
                app.call('peek-close')
            check('return_preview_open', open_preview(first)); key('return')
            check('return_does_not_restore_behind_peek', state()['open'] and archive_rows() == before_records)
            app.call('peek-close')
            # All-Profiles Archive must use the record owner's engine Profile,
            # even when opened from a different empty Space.
            state(action='close')
            other_space = app.call('space-create', title='Preview owner', profile='Preview Profile')
            app.call('space', space=other_space); state(action='open', section='archive')
            check('other_profile_archive_visible', wait(lambda: bool(row(first))))
            check('other_profile_peek', open_preview(first))
            peek = app.call('peek-state')['stack'][-1]
            check('peek_uses_archive_owner_profile', peek['profile'] == space['profile'] and peek['librarySpace'] == other_space)
            check('other_profile_escape', dismiss('escape') and state()['open'])
            state(action='close'); app.call('space', space=space['id']); state(action='open', section='archive')
            check('original_space_rows_retained', wait(lambda: bool(row(first) and row(second))))
            if frames:
                app.call('window-frame', frame=[0, 40, 1280, 800], unconstrained=True)
                for appearance in ['light', 'dark']:
                    app.call('appearance', name=appearance)
                    pointer('hover', row(first)['frame'], 80); time.sleep(.25)
                    capture_window(state()['window'], output/('split-archive-'+appearance+'.png'))
                    (output/('split-archive-'+appearance+'.json')).write_text(json.dumps(state(), indent=2))
            # Actual native button hit targets use the row's visible control geometry.
            pointer('hover', row(first)['frame'], 80)
            trash = next(b for b in row(first)['buttons'] if b['title'] == 'Delete')
            pointer('click', trash['frame'])
            alert = app.call('alert', window='library')
            check('trash_confirmation', 'Delete this archived tab?' in alert['texts'] and set(alert['buttons']) == {'Delete', 'Cancel'}, alert=alert)
            if os.environ.get('OPEN_ARCHIVE_FORCE_ALERT_FAILURE') == '1':
                check('forced_alert_cleanup_probe', False)
            app.call('alert', window='library', button='Cancel')
            check('trash_cancel_keeps_both', archive_rows() == before_records)
            pointer('hover', row(first)['frame'], 80)
            trash = next(b for b in row(first)['buttons'] if b['title'] == 'Delete')
            pointer('click', trash['frame']); app.call('alert', window='library', button='Delete')
            check('trash_deletes_only_one', wait(lambda: not row(first)) and {r['id'] for r in archive_rows()} == {second})
            pointer('hover', row(second)['frame'], 80)
            restore = next(b for b in row(second)['buttons'] if b['title'] == 'Restore')
            pointer('click', restore['frame'])
            check('restore_single_tab', wait(lambda: not state()['open']) and wait(lambda: not archive_rows())
                  and any(t['id'] == second for t in app.call('tabs')) and app.call('split', op='state')['id'] == '')
            state(action='open', section='archive')
            check('archive_empty_after_actions', wait(lambda: not state()['rows'] and state()['emptyVisible']))
            result['ok'] = True
        except Exception as error:
            result.update(ok=False, error=repr(error)); raise
        finally:
            if app:
                app.quit(); result['cleanup'] = app.quit_report
                if not app.quit_report.get('ok'): result.update(ok=False, error='Owned app cleanup failed')
            (output/'result.json').write_text(json.dumps(result, indent=2))
    assert result['ok'], result.get('error')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--output', required=True, type=Path); parser.add_argument('--frames', action='store_true')
    args = parser.parse_args(); run(args.output, args.frames)
