#!/usr/bin/env python3
"""PB1 Library folder sources: real App, fixture folders only (no user folders, no consent prompt).

Flow: Media first-use card -> "Choose Folders..." -> folder files appear as Media rows (images and
movies only; hidden files, symlinks and other types never) -> the Library button's right-click
"Show media from:" menu turns sources off and on -> "Hide from Open" hides one file and
survives a relaunch. Run: python3 tools/e2e/library_media_folders.py --output DIR --config Release
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import zlib
import struct

from engine_e2e import Open, wait_until
from library_overlay import capture_window


def png(path, rgb=(200, 40, 40)):
    raw = b''.join(b'\x00' + bytes(rgb) * 4 for _ in range(4))
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 4, 4, 8, 2, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def fixture(root):
    folders = {name: root / name for name in ('Documents', 'Desktop', 'Downloads', 'Screenshots')}
    for folder in folders.values():
        folder.mkdir(parents=True)
    png(folders['Documents'] / 'doc-photo.png')
    png(folders['Desktop'] / 'desk-photo.png')
    shot = folders['Desktop'] / 'Screen Shot fixture.png'
    png(shot)
    # Finder's screen-capture mark: a Screenshot wherever it is.
    subprocess.run(['xattr', '-w', 'com.apple.metadata:kMDItemIsScreenCapture', '1', str(shot)], check=True)
    (folders['Downloads'] / 'clip.mp4').write_bytes(b'\x00\x00\x00\x18ftypmp42')
    # Never listed: another type, a hidden file, a symlink, a subfolder's image.
    (folders['Documents'] / 'notes.txt').write_text('not media')
    png(folders['Desktop'] / '.hidden.png')
    os.symlink(folders['Documents'] / 'doc-photo.png', folders['Desktop'] / 'link.png')
    (folders['Documents'] / 'Sub').mkdir()
    png(folders['Documents'] / 'Sub' / 'deep.png')
    return folders


def run(output, config='Release', frames=False):
    output.mkdir(parents=True, exist_ok=True)
    result = {'checks': {}}
    app = None

    def check(name, ok, **evidence):
        result['checks'][name] = dict(ok=bool(ok), **evidence)
        print(('PASS ' if ok else 'FAIL ') + name, flush=True)

    with tempfile.TemporaryDirectory(prefix='open-library-media-') as data, \
            tempfile.TemporaryDirectory(prefix='open-library-media-folders-') as folders_root:
        folders = fixture(Path(folders_root))
        env = {'OPEN_LIBRARY_MEDIA_FIXTURE': folders_root}
        try:
            app = Open(config, 'chrome', data, [], str(output / 'app.log'), extra_env=env)
            def state(**kw): return app.call('library', **kw)
            def rows(): return [r for r in state().get('rows', []) if r['id'].startswith('file:')]
            def names(): return sorted(Path(r['id'][5:]).name for r in rows())
            def menu(item=None): return app.call('library-button-menu', **({'item': item} if item else {}))['items']
            owner = app.call('shell-windows')[0]['id']
            app.call('window-focus', id=owner, activate=True)

            items = wait_until(lambda: (lambda m: m if len(m) == 6 else None)(menu()), timeout=5, step=.05) or menu()
            check('menu_items', [i['title'] for i in items] == ['Show media from:', 'Documents', 'Desktop', 'Screenshots', 'Captures', 'Downloads']
                  and items[0]['enabled'] is False and all(i['on'] for i in items[1:]), items=items)

            state(action='open', section='media')
            empty = wait_until(lambda: (lambda s: s if s.get('emptyVisible') else None)(state()), timeout=8, step=.05) or state()
            # C-LF-5 (LEAD 20:45): Arc's two first-use strings with "Open"; the whole body shows and the button sits below it.
            es = empty['emptyState']
            body_y, button_y = sorted([es['bodyFrame'], es['buttonFrame']], key=lambda r: r[1])
            check('first_use_card', es['title'] == 'Show your media here'
                  and es['body'] == 'Allow Open to show your Documents, Desktop, and Download Folders to see them here alongside your Captures.'
                  and es['buttonToolTip'] == es['buttonHelp'] == 'Quickly grab screenshots, images, and videos from your computer by showing them in the Open Library!'
                  and es['bodyFrame'][3] >= es['bodyNeededHeight'] and body_y[1] + body_y[3] <= button_y[1]
                  and 'Arc' not in es['body'] + es['buttonToolTip']
                  and es['buttonVisible'] and es['buttonEnabled'] and not rows(),
                  state=es)

            if frames:
                # Look STOP frames of the first-use card (C-LF-5), light and dark, before Choose Folders.
                for name in ('light', 'dark'):
                    app.call('appearance', name=name); time.sleep(.6)
                    capture_window(state()['window'], output / ('media-first-use-' + name + '.png'))
                app.call('appearance', name='system')
            state(action='empty-button')
            expected = ['Screen Shot fixture.png', 'clip.mp4', 'desk-photo.png', 'doc-photo.png']
            listed = wait_until(lambda: names() == expected, timeout=8, step=.1)
            subtitles = {Path(r['id'][5:]).name: r.get('subtitle', '') for r in rows()}
            check('choose_folders_lists_media', listed and subtitles['doc-photo.png'].startswith('Documents ·')
                  and subtitles['desk-photo.png'].startswith('Desktop ·') and subtitles['Screen Shot fixture.png'].startswith('Screenshots ·')
                  and subtitles['clip.mp4'].startswith('Downloads ·') and not state()['emptyVisible'],
                  names=names(), subtitles=subtitles)

            if frames:
                # Look STOP frames: the real window, light and dark (Open's own appearance only).
                for name in ('light', 'dark'):
                    app.call('appearance', name=name); time.sleep(.6)
                    capture_window(state()['window'], output / ('media-folders-' + name + '.png'))
                app.call('appearance', name='system')
            menu('Screenshots')
            off = wait_until(lambda: names() == ['clip.mp4', 'desk-photo.png', 'doc-photo.png'], timeout=8, step=.1)
            check('source_off_hides_rows', off and not next(i for i in menu() if i['title'] == 'Screenshots')['on'], names=names())
            menu('Screenshots')
            back = wait_until(lambda: names() == expected, timeout=8, step=.1)
            check('source_on_restores_rows', back and next(i for i in menu() if i['title'] == 'Screenshots')['on'], names=names())

            doc = next(r for r in rows() if r['id'].endswith('/doc-photo.png'))
            actions = state(action='row-menu', id=doc['id'])['items']
            titles = [a['title'] if isinstance(a, dict) else a for a in actions]
            check('file_row_menu', titles[:3] == ['Open in Preview', 'Send via iMessage', 'AirDrop'] and titles[3].startswith('Copy')
                  and titles[4:] == ['Show in Finder', 'separator', 'Hide from Open'] and 'Delete' not in json.dumps(actions), items=actions)
            state(action='row-action', id=doc['id'], name='Hide from Open')
            hidden = wait_until(lambda: 'doc-photo.png' not in names(), timeout=5, step=.05)
            check('hide_from_library', hidden and (folders['Documents'] / 'doc-photo.png').exists(), names=names())

            app.quit()
            app = Open(config, 'chrome', data, [], str(output / 'app.log'), extra_env=env)
            owner = app.call('shell-windows')[0]['id']
            app.call('window-focus', id=owner, activate=True)
            state(action='open', section='media')
            relaunched = wait_until(lambda: names() == ['Screen Shot fixture.png', 'clip.mp4', 'desk-photo.png'], timeout=10, step=.1)
            check('state_survives_relaunch', relaunched and not state()['emptyVisible'], names=names())
            state(action='close')
        except Exception as error:  # a crash is a failed row, with the reason kept
            check('flow_completed', False, error=repr(error))
        finally:
            if app:
                app.quit()
                result['cleanup'] = getattr(app, 'quit_report', {})
    result['ok'] = all(c['ok'] for c in result['checks'].values()) and bool(result.get('cleanup', {}).get('ok'))
    (output / 'results-library-media-folders.json').write_text(json.dumps(result, indent=2, default=str))
    print('suite ' + ('PASS' if result['ok'] else 'FAIL'), flush=True)
    return result['ok']


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--config', choices=['Debug', 'Release'], default='Release')
    parser.add_argument('--frames', action='store_true')
    args = parser.parse_args()
    raise SystemExit(0 if run(args.output, args.config, args.frames) else 1)
