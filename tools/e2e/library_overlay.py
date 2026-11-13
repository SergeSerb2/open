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

from engine_e2e import Open, wait_until

SECTIONS = ['media', 'downloads', 'spaces', 'boosts', 'archive', 'history']
KEYS = ['libraryShowsEasels', 'open.library.lastSection', 'open.sidebar.hideHintShown']


def capture_window(number,path):
    launcher=Path.home()/'Applications/OpenCapture.app'
    command=['/usr/sbin/screencapture','-x','-o','-l',str(number),str(path)]
    if launcher.exists():
        log=path.with_suffix('.pixels.log')
        pixels=Path(__file__).resolve().parents[1]/'capture/pixels.sh'
        subprocess.run(['/usr/bin/open','-n','-W',str(launcher),'--args',str(pixels),str(log),*command],timeout=15)
        assert Path(str(log)+'.rc').read_text().strip()=='0',log.read_text()
    else:subprocess.run(command,check=True,timeout=15)


def run(output, frames=False, bundle=None, mockups=None, capture_sections=None):
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

    def settled(motion):
        if motion.get('preparingClose'): return False
        # AppKit may retain an expired key until the next event/transaction.
        # Read presentation geometry and layer time to test actual movement.
        for name in ['page', 'panel', 'sidebar']:
            layer = motion[name]
            if any(abs(a-b) > .01 for a,b in zip(layer['frame'],layer['presentation'])):
                return False
            for animation in layer['animations']:
                if 'library' in animation['key'].lower() and (
                    animation['repeatCount'] != 0 or
                    layer['localTime'] < animation['beginTime'] + animation['duration']):
                    return False
        return True

    def capture(name, width, height, **extra):
        current = state()
        # Window number comes from the owning browser's socket state.
        path = output / (name + '.png')
        capture_window(current['window'],path)
        dimensions = struct.unpack('>II', path.read_bytes()[16:24])
        check(name + '_native_2x', dimensions == (width*2, height*2), pixels=dimensions)
        if current['section'] == 'spaces':
            page = current['pageCardFrame']
            check(name + '_page_strip', page[0] == width-56 and page[2] == width-427,
                  page=page, visibleWidth=width-page[0])
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
            for name, value in [('libraryShowsEasels', False), ('open.sidebar.hideHintShown', True)]:
                app.call('defaults', key=name, value=value)
            check('lazy_at_launch', state()['created'] is False)
            owner = app.call('shell-windows')[0]
            before = app.call('window-state')
            result['display'] = {name: before[name] for name in
                                 ['screenFrame', 'mainScreenName', 'mainScreenScale']}
            current = state(action='open', section='downloads')
            time.sleep(.22)
            current = state()
            check('embedded_geometry', current['open'] and current['window'] == owner['number']
                  and current['panelFrame'][2] == 417 and current['pageCardFrame'][0] == 417,
                  state=current)
            check('six_tile_rail', [x['id'] for x in current['rail']] == SECTIONS)
            check('rail_native_hit_targets', all(tile['hitClass'] == 'LibraryControl' and not tile['canDragWindow'] for tile in current['rail']),
                  hits=[dict(id=t['id'],hit=t['hitClass'],windowDrag=t['canDragWindow']) for t in current['rail']])
            for section in SECTIONS:
                current = state(action='select', section=section)
                assert wait_until(lambda: settled(state()['motion']), timeout=2), 'section motion did not settle'
                current = state()
                expected = app.call('window-state')['frame'][2]-56 if section == 'spaces' else 417
                check('section_' + section, current['section'] == section and current['panelFrame'][2] == expected,
                      panel=current['panelFrame'], page=current['pageCardFrame'])
                if section == 'spaces':
                    window_width = app.call('window-state')['frame'][2]
                    check('spaces_pushes_full_page_card', current['pageCardFrame'][0] == window_width-56
                          and current['pageCardFrame'][2] == window_width-427,
                          page=current['pageCardFrame'],windowWidth=window_width)
            state(action='select', section='downloads')
            state(action='focus-rail')
            key('right')
            check('rail_right_arrow', state()['section'] == 'spaces')
            key('left')
            check('rail_left_arrow', state()['section'] == 'downloads')
            target = next(tile for tile in state()['rail'] if tile['id'] == 'history')
            x,y,w,h = target['frame']
            app.call('mouse', action='hover', window=state()['window'], x=x+w/2, y=y+h/2)
            check('native_tile_hover', next(t for t in state()['rail'] if t['id'] == 'history')['hovered'])
            started = time.monotonic()
            app.call('mouse', action='click', queued=True, window=state()['window'], x=x+w/2, y=y+h/2)
            immediate = state()['section']
            deadline = time.monotonic()+2
            while state()['section'] != 'history' and time.monotonic() < deadline:
                time.sleep(.005)
            check('native_tile_click', state()['section'] == 'history', immediateSection=immediate,
                  elapsedMilliseconds=(time.monotonic()-started)*1000, state=state())
            state(action='select', section='downloads')
            state(action='search', text='unmatched synthetic name')
            check('no_results_copy', state()['emptyState']['title'] == 'No matches')
            key('escape')
            check('escape_clears_search', state()['open'] and state()['search'] == '')
            key('f', ['cmd'])
            check('cmd_f_search', state()['firstResponder'] == 'LibrarySearchEditor', state=state())
            app.call('key', text='socket typing', route='app')
            check('native_search_typing', state()['search'] == 'socket typing')
            key('escape')
            key('escape')
            check('escape_closes_panel', wait_until(lambda:not state()['open'], timeout=2))
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

            app.call('command', id='view-downloads')
            check('only_embedded_library',app.call('settings-state')['library']==owner['number'])
            state(action='close')
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

            state(action='close')
            time.sleep(.25)
            app.call('window-motion', reduced=False)
            closed_frame = state()['motion']['page']['frame']
            opened = state(action='open', section='downloads')
            motion = app.call('window-motion')
            check('open_moves_page', 'libraryFrame' in motion['active']['panel'], motion=motion)
            check('open_keeps_live_page_geometry', opened['motion']['page']['frame'] == closed_frame,
                  before=closed_frame, during=opened['motion']['page']['frame'])
            properties = next(a['properties'] for a in opened['motion']['page']['animations'] if a['key'] == 'libraryFrame')
            check('page_motion_is_position_only', properties == ['position'], properties=properties)
            time.sleep(.25)
            motion = state()['motion']
            check('open_motion_settles', settled(motion), motion=motion)
            state(action='select', section='spaces')
            check('spaces_moves_page', 'libraryFrame' in app.call('window-motion')['active']['panel'])
            time.sleep(.25)
            open_frame = state()['motion']['page']['frame']
            closed = state(action='close')
            assert wait_until(lambda:not state()['open'] and not state()['motion']['preparingClose'],
                              timeout=2, step=.005), 'close preparation did not finish committing'
            closed = state()
            check('close_moves_page', 'libraryFrame' in app.call('window-motion')['active']['panel'], motion=closed['motion'])
            timing = closed['motion']['timing']
            check('close_commits_width_before_motion', closed['motion']['page']['frame'] == closed_frame
                  and not timing['opening'] and 0 < timing['layoutCommit'] <= timing['start'],
                  before=open_frame, during=closed['motion']['page']['frame'], timing=timing)
            check('close_uses_page_snapshot', closed['motion']['snapshotCount'] > 0, motion=closed['motion'])
            check('close_hides_live_views', closed['motion']['snapshotLiveViewsHidden'], motion=closed['motion'])
            check('close_separates_preparation_commit', timing['start'] - timing['layoutCommit'] >= 1/240,
                  timing=timing)
            second = state()['motion']
            check('close_keeps_final_viewport_fixed', second['page']['frame'] == closed['motion']['page']['frame'], motion=second)
            time.sleep(.25)
            motion = state()['motion']
            check('closed_motion_stops', settled(motion), motion=motion)
            for section in ['downloads', 'spaces', 'downloads']:
                state(action='open', section=section)
                time.sleep(.025)
                key('escape')
            assert wait_until(lambda: settled(state()['motion']), timeout=2), 'interrupted motion did not settle'
            interrupted = state()
            check('rapid_open_close_restores_page', not interrupted['open'] and interrupted['pageCardFrame'] == closed_frame,
                  page=interrupted['pageCardFrame'], expected=closed_frame)
            original_frame = app.call('window-state')['frame']
            state(action='open', section='downloads')
            state(action='resize', width=1024, height=700)
            assert wait_until(lambda: settled(state()['motion']), timeout=2), 'resized motion did not settle'
            resized = state()
            check('resize_cancels_stale_page_target', resized['pageCardFrame'][0] == 417 and resized['pageCardFrame'][2] == 597,
                  page=resized['pageCardFrame'])
            state(action='close')
            app.call('window-frame', frame=original_frame)
            assert wait_until(lambda: settled(state()['motion']), timeout=2), 'restored frame did not settle'
            app.call('window-motion', reduced=True)
            state(action='open', section='downloads')
            check('reduced_motion_no_page_move', 'libraryFrame' not in app.call('window-motion')['active']['panel'])
            time.sleep(.12)
            state(action='close')
            check('reduced_motion_close_no_page_move', 'libraryFrame' not in app.call('window-motion')['active']['panel'])
            time.sleep(.12)
            app.call('window-motion', reduced=False)
            state(action='open', section='downloads')

            if frames:
                colors = {'peach': (0.94, 0.49, 0.35), 'ocean': (0.26, 0.53, 0.90),
                          'night': (0.35, 0.27, 0.60)}
                space = app.call('spaces')[0]['id']
                for theme, rgb in colors.items():
                    for appearance in ['light', 'dark']:
                        app.call('appearance', name=appearance)
                        app.call('theme-set', space=space, style=dict(
                            keyColor=dict(zip(['red','green','blue'], rgb), alpha=1), colorCount=3,
                            appearance=appearance, noiseFactor=0, intensityFactor=0.8))
                        time.sleep(.35)
                        palette = app.call('theme-get', space=space)
                        for width, height in [(1280,800),(900,850)]:
                            app.call('window-frame', frame=[40,50,width,height], unconstrained=True)
                            for section in SECTIONS:
                                if capture_sections and section not in capture_sections: continue
                                state(action='select', section=section)
                                app.call('mouse', action='hover', window=state()['window'], x=width-30, y=height-30)
                                app.call('mouse', action='click', window=state()['window'], x=width-30, y=height-30)
                                time.sleep(.23)
                                name = '%s-%s-%dx%d-%s' % (theme,appearance,width,height,section)
                                capture(name,width,height,theme=theme,appearance=appearance,themeState=palette)
                if not capture_sections:
                    app.call('defaults', key='libraryShowsEasels', value=True)
                    state(action='refresh')
                    state(action='select', section='easels')
                    time.sleep(.22)
                    capture('easels-flag-seven-tiles',900,850)
                    check('seven_tile_flag', len(state()['rail']) == 7)
                    app.call('defaults', key='libraryShowsEasels', value=False)
                    state(action='refresh')
                if mockups:
                    state(action='close')
                    time.sleep(.25)
                    if app.call('window-state')['sidebarMode'] != 'hidden':
                        app.call('command', id='toggle-sidebar')
                    for source in sorted(mockups.glob('mock-*.html')):
                        # The binding HTML is ours. Render it in the real engine
                        # through the socket, with a page viewport of the same size.
                        size = source.stem.split('-')[2]
                        width,height = map(int,size.split('x'))
                        app.call('window-frame', frame=[40,50,width+20,height+20], unconstrained=True)
                        app.call('navigate', url=source.resolve().as_uri())
                        app.call('wait')
                        time.sleep(.05)
                        destination = output / (source.stem + '.png')
                        app.call('snapshot', page=True, path=str(destination))
                        dimensions = struct.unpack('>II', destination.read_bytes()[16:24])
                        check(source.stem+'_reference_2x', dimensions == (width*2,height*2),pixels=dimensions)
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
    parser.add_argument('--mockups', type=Path)
    parser.add_argument('--sections', nargs='+', choices=SECTIONS)
    args = parser.parse_args()
    answer = run(args.output.resolve(),args.frames,args.bundle,args.mockups,args.sections)
    raise SystemExit(0 if answer['ok'] else 1)
