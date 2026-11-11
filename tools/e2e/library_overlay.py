#!/usr/bin/env python3
"""Real Library shell acceptance through Open's socket; never desktop input.

Build Debug first. Run under the on-screen lock. --frames is the L1 STOP
capture, not an iteration default. Pixels use the approved OpenCapture launcher.
"""
import argparse
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import time

from engine_e2e import Open

SECTIONS = ['media', 'downloads', 'spaces', 'boosts', 'archive', 'history']
KEYS = ['libraryShowsEasels', 'libraryShowsHistory', 'OpenLibraryLegacyWindow',
        'open.library.lastSection', 'open.sidebar.hideHintShown']


def run(output, frames=False, bundle=None):
    output.mkdir(parents=True, exist_ok=True)
    checks, shots = {}, []
    app = None
    saved = {}
    result = {'checks': checks, 'frames': shots, 'timingQualification':
              'Debug setup observations only. Final Release five-launch budgets are L3.'}

    def check(name, valid, **evidence):
        checks[name] = dict(ok=bool(valid), **evidence)
        print(('PASS ' if valid else 'FAIL ') + name, flush=True)
        if not valid:
            raise AssertionError(name + ': ' + repr(evidence))

    def state(**args):
        return app.call('library', **args)

    def key(value, modifiers=()):
        return app.call('key', key=value, modifiers=list(modifiers), route='app')

    def capture(name, width, height, **extra):
        current = state()
        # Window number comes from the owning browser's socket state.
        path = output / (name + '.png')
        subprocess.run(['/usr/sbin/screencapture', '-x', '-o', '-l',
                        str(current['window']), str(path)], check=True, timeout=15)
        dimensions = struct.unpack('>II', path.read_bytes()[16:24])
        check(name + '_native_2x', dimensions == (width*2, height*2), pixels=dimensions)
        metadata = dict(current, path=path.name, pixelSize=dimensions, **extra)
        (output / (name + '.json')).write_text(json.dumps(metadata, indent=2))
        shots.append(metadata)

    with tempfile.TemporaryDirectory(prefix='open-library-l1-') as data:
        try:
            env = {'OPEN_E2E_APP_BUNDLE': str(bundle)} if bundle else {}
            app = Open('Debug', 'chrome', data, [], str(output / 'app.log'),
                       urls=('about:blank',), extra_env=env)
            for name in KEYS:
                saved[name] = app.call('defaults', key=name, persistent=True)
            for name, value in [('libraryShowsEasels', False), ('libraryShowsHistory', True),
                                ('OpenLibraryLegacyWindow', False), ('open.sidebar.hideHintShown', True)]:
                app.call('defaults', key=name, value=value)
            check('lazy_at_launch', state()['created'] is False)
            owner = app.call('shell-windows')[0]
            before = app.call('window-state')
            current = state(action='open', section='downloads')
            time.sleep(.22)
            current = state()
            check('embedded_geometry', current['open'] and current['window'] == owner['number']
                  and current['panelFrame'][2] == 417 and current['pageCardFrame'][0] == 417,
                  state=current)
            check('six_tile_rail', [x['id'] for x in current['rail']] == SECTIONS)
            for section in SECTIONS:
                current = state(action='select', section=section)
                expected = app.call('window-state')['frame'][2]-56 if section == 'spaces' else 417
                check('section_' + section, current['section'] == section and current['panelFrame'][2] == expected,
                      panel=current['panelFrame'], page=current['pageCardFrame'])
            state(action='select', section='downloads')
            state(action='search', text='unmatched synthetic name')
            check('no_results_copy', state()['emptyState']['title'] == 'No matches')
            key('escape')
            check('escape_clears_search', state()['open'] and state()['search'] == '')
            key('f', ['cmd'])
            check('cmd_f_search', state()['firstResponder'] == 'NSTextView', state=state())
            key('escape')
            check('escape_closes_panel', not state()['open'])
            after = app.call('window-state')
            check('sidebar_preserved', all(before[k] == after[k] for k in ['sidebarWidth', 'sidebarMode', 'selected']),
                  before={k: before[k] for k in ['sidebarWidth','sidebarMode','selected']},
                  after={k: after[k] for k in ['sidebarWidth','sidebarMode','selected']})

            for command, section in [('view-downloads','downloads'), ('view-archive','archive'),
                                     ('view-history','history'), ('view-media','media'),
                                     ('view-boosts','boosts'), ('manage-spaces','spaces')]:
                app.call('command', id=command)
                check('entry_' + command, state()['open'] and state()['section'] == section)
                state(action='back')
            app.call('command', id='toggle-sidebar')
            hidden = app.call('window-state')
            check('hidden_sidebar_fixture', hidden['sidebarMode'] == 'hidden')
            state(action='open', section='history')
            check('open_with_hidden_sidebar', state()['open'] and state()['pageCardFrame'][0] == 417)
            state(action='close')
            check('returns_to_hidden_sidebar', app.call('window-state')['sidebarMode'] == 'hidden')
            app.call('command', id='toggle-sidebar')

            state(action='open', section='downloads')
            app.call('command', id='new-window')
            other = next(w for w in app.call('shell-windows') if w['id'] != owner['id'])
            check('new_window_unconstructed', state()['created'] is False)
            state(action='open', section='history')
            app.call('window-focus', id=owner['id'], activate=True)
            check('per_window_selection', state()['section'] == 'downloads' and state()['open'])
            app.call('window-focus', id=other['id'], activate=True)
            check('second_window_selection', state()['section'] == 'history' and state()['open'])
            state(action='close')
            app.call('window-close')
            app.call('window-focus', id=owner['id'], activate=True)

            if frames:
                colors = {'peach': (0.94, 0.49, 0.35), 'ocean': (0.26, 0.53, 0.90),
                          'night': (0.35, 0.27, 0.60)}
                space = app.call('spaces')[0]['id']
                for theme, rgb in colors.items():
                    for appearance in ['light', 'dark']:
                        app.call('appearance', name=appearance)
                        app.call('theme-set', space=space, style=dict(
                            keyColor=dict(zip(['red','green','blue'], rgb)), colorCount=3,
                            appearance=appearance, noiseFactor=0, intensityFactor=0.8))
                        time.sleep(.35)
                        palette = app.call('theme-get', space=space)
                        for width, height in [(1280,800),(900,850)]:
                            app.call('window-frame', frame=[40,50,width,height], unconstrained=True)
                            for section in SECTIONS:
                                state(action='select', section=section)
                                time.sleep(.23)
                                name = '%s-%s-%dx%d-%s' % (theme,appearance,width,height,section)
                                capture(name,width,height,theme=theme,appearance=appearance,themeState=palette)
                app.call('defaults', key='libraryShowsEasels', value=True)
                state(action='refresh')
                state(action='select', section='easels')
                time.sleep(.22)
                capture('easels-flag-seven-tiles',900,850)
                check('seven_tile_flag', len(state()['rail']) == 7)
                app.call('defaults', key='libraryShowsEasels', value=False)
                state(action='refresh')
            result['ok'] = True
        except Exception as error:
            result.update(ok=False,error=repr(error))
            raise
        finally:
            if app:
                for name,value in saved.items():
                    try: app.call('defaults', key=name, value=value)
                    except Exception: pass
                try: app.call('appearance', name='system')
                except Exception: pass
                app.quit()
                result['cleanup'] = app.quit_report
                # Exact executable-path audit, independent of the harness PID ledger.
                rows = subprocess.check_output(['ps','-axo','pid=,comm='], text=True)
                remaining = [row for row in rows.splitlines()
                             if len(parts := row.strip().split(None,1)) == 2
                             and parts[1].startswith(app.bundle + '/')]
                result['pathAudit'] = dict(ok=not remaining,remaining=remaining)
                result['ok'] = result.get('ok',False) and app.quit_report['ok'] and not remaining
            (output/'result.json').write_text(json.dumps(result,indent=2))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--frames', action='store_true')
    args = parser.parse_args()
    answer = run(args.output.resolve(),args.frames,args.bundle)
    raise SystemExit(0 if answer['ok'] else 1)
