"""Bug sweep round 7 (lane PERSIST7): persistence and recovery rows, through the real App.

Z-01 a Profile folder that cannot be removed no longer stops the launch; Z-04 deleted-Profile trees
are removed off the main thread and swept at launch; Z-02 a damaged Archive or History database is
kept aside and a new one works; Z-03 download history survives a fresh model; Z-05 a failed snapshot
write shows a toast and stays unsaved; Z-06 a page that keeps changing cannot hold the snapshot save
back; Z-07 Blank Windows survive a force quit; Z-08 a repeated Space ID keeps the second Space and the
repair save keeps a copy first. Socket only; loopback pages; synthetic data in the suite's own root.
"""
import glob
import json
import os
import signal
import subprocess
import time
import uuid
from pathlib import Path


def run(factory, results, tmp, h):
    server, origin = h._fixture_server('Persist')
    try:
        rows(factory, results, tmp, h, origin)
    finally:
        server.shutdown()
        server.server_close()


def rows(factory, results, tmp, h, origin):
    wait = h.wait_until
    apps = []

    def row(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('persist %-48s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)

    def launch(**kw):
        app = factory(**kw)
        apps.append(app)
        return app

    def section(name, body):
        # One failed section must not hide the others (the unfixed App exits at launch in Z-01).
        try:
            body()
        except Exception as error:
            row(name + '_section', False, error=repr(error)[:600])
        finally:
            for instance in apps:
                if not instance.closed:
                    instance.quit()

    def force_quit(app):
        # A crash or force quit: no quit path runs. Owned helpers are found first, then cleaned up.
        app.discover_owned_processes()
        os.kill(app.pid, signal.SIGKILL)
        wait(lambda: app.process_path(app.pid) is None or None, timeout=10, step=.1)
        app.quit()


    # The first launch makes the suite's own data root; every later launch reuses it.
    app = launch(urls=(origin + '/start',), fresh=True)
    root = Path(app.user_data)
    state_dir = root / 'State'
    snapshot = state_dir / 'browser.json'
    app.call('wait', tab=app.call('tabs')[0]['id'])

    def z05_z06():
        # Z-05: the snapshot folder refuses writes. A save shows one toast and the state stays unsaved;
        # once the folder takes writes again, the next change saves everything.
        app.call('save')
        mode = state_dir.stat().st_mode & 0o7777
        os.chmod(state_dir, 0o500)
        try:
            h.new_tab(app, origin + '/z05-unsaved')
            toast = wait(lambda: next((t for t in app.call('toasts')['toasts'] if t['title'] == 'Your tabs could not be saved'), None),
                         timeout=8, step=.2)
            counters = wait(lambda: (lambda c: c if c.get('dirty') else None)(app.call('frame-save-counters')), timeout=5, step=.1) \
                or app.call('frame-save-counters')
            on_disk = '/z05-unsaved' in snapshot.read_text()
        finally:
            os.chmod(state_dir, mode)
        h.new_tab(app, origin + '/z05-after')
        saved = wait(lambda: ('/z05-unsaved' in snapshot.read_text() and '/z05-after' in snapshot.read_text()) or None, timeout=8, step=.2)
        row('persist_z05_snapshot_write_failure_toast', bool(toast) and counters.get('dirty') is True and not on_disk and bool(saved),
            toast=toast, counters=counters, writtenWhileRefused=on_disk, savedAfter=bool(saved))

        # Z-06: the selected page changes its address every 200 ms. Another tab pinned
        # meanwhile (the page stays in front, so it keeps ticking) still reaches browser.json within the
        # maximum wait (10 s) plus the 1 s debounce, with no automation save.
        marker = h.new_tab(app, origin + '/z06-pinned')
        ticker_tab = h.new_tab(app, origin + '/z06-ticker')
        app.call('select', tab=ticker_tab)
        # Address only: a title-only change takes its own 10 s path once #665 is in (PERF-06).
        app.eval(ticker_tab, "let n=0;setInterval(()=>{n++;history.replaceState(null,'','#'+n)},200);1")
        time.sleep(1.5)
        # Start from a saved model: the maximum wait counts from the first change after this save.
        app.call('save')
        before = app.call('frame-save-counters')
        app.call('pin', tab=marker)
        started = time.monotonic()

        def pinned_on_disk():
            spaces = json.loads(snapshot.read_text())['spaces']
            return any('/z06-pinned' in json.dumps(s.get('pinned', [])) for s in spaces) or None
        landed = wait(pinned_on_disk, timeout=16, step=.25)
        elapsed = time.monotonic() - started
        after = app.call('frame-save-counters')
        selected = next((t['id'] for t in app.call('tabs') if t.get('selected')), None)
        row('persist_z06_save_not_starved_by_changing_page', bool(landed) and elapsed <= 13
            and after['scheduled'] - before['scheduled'] >= 20 and selected == ticker_tab,
            selectedTicker=selected == ticker_tab,
            elapsed=round(elapsed, 2), maximumWait=10, load=os.getloadavg(), before=before, after=after)

    def z08():
        # Z-08: two Spaces share an ID; the second differs (its own title and tab IDs). It is kept under
        # a new ID, and the file as it was is kept before the repair save replaces it.
        data = json.loads(snapshot.read_text())
        space = data['spaces'][0]
        duplicate = json.dumps(space)
        for tab_id in sorted({v for v in _values(space, 'id') if v != space['id']}):
            duplicate = duplicate.replace(tab_id, str(uuid.uuid4()).upper())
        duplicate = json.loads(duplicate)
        duplicate['title'] = 'R7 Repeated Space'
        data['spaces'].append(duplicate)
        written = json.dumps(data).encode()
        snapshot.write_bytes(written)
        for old in glob.glob(str(state_dir / 'browser.repaired-*.json')):
            os.unlink(old)
        app = launch(urls=())
        spaces = app.call('spaces')
        kept = [s for s in spaces if s.get('title') == 'R7 Repeated Space']
        copies = glob.glob(str(state_dir / 'browser.repaired-*.json'))
        row('persist_z08_repeated_space_kept_with_copy', len(kept) == 1 and kept[0]['id'] != space['id']
            and any(s['id'] == space['id'] for s in spaces) and len(copies) == 1 and Path(copies[0]).read_bytes() == written,
            spaces=[(s['id'], s.get('title')) for s in spaces], copies=[Path(c).name for c in copies])

    def z02():
        # Z-02: damaged Archive and History databases (random bytes, as a crash during a disk error can
        # leave). Each is kept aside and a new one records closed tabs and visits.
        default_state = root / 'Profiles/Default/State'
        for name in ('archive.sqlite3', 'history.sqlite3'):
            for suffix in ('', '-wal', '-shm'):
                target = default_state / (name + suffix)
                if target.exists():
                    target.unlink()
            (default_state / name).write_bytes(os.urandom(8192))
        app = launch(urls=())
        closed = h.new_tab(app, origin + '/z02-closed')
        h.new_tab(app, origin + '/z02-open')
        app.call('select', tab=closed)
        app.call('close')
        archived = wait(lambda: any('/z02-closed' in r['url'] for r in app.call('archive-list')['rows']) or None, timeout=8, step=.2)
        history = wait(lambda: any('/z02-open' in r['url'] for r in app.call('history-state')['rows']) or None, timeout=8, step=.2)
        kept = sorted(Path(p).name for p in glob.glob(str(default_state / '*.damaged-*')))
        row('persist_z02_damaged_archive_set_aside', bool(archived) and any(n.startswith('archive.sqlite3.damaged-') for n in kept),
            archive=[r['url'] for r in app.call('archive-list')['rows']][:5], kept=kept)
        row('persist_z02_damaged_history_set_aside', bool(history) and any(n.startswith('history.sqlite3.damaged-') for n in kept),
            history=[r['url'] for r in app.call('history-state')['rows']][:5], kept=kept)

    def z02_toast():
        # Z-02 (review r1 of #670): a closed tab that cannot be written to the Archive shows a toast.
        # The Profile's State folder refuses new files before the Archive database exists or opens.
        default_state = root / 'Profiles/Default/State'
        for suffix in ('', '-wal', '-shm'):
            target = default_state / ('archive.sqlite3' + suffix)
            if target.exists():
                target.unlink()
        app = launch(urls=())
        closed = h.new_tab(app, origin + '/z02-toast-closed')
        h.new_tab(app, origin + '/z02-toast-open')
        mode = default_state.stat().st_mode & 0o7777
        os.chmod(default_state, 0o500)
        try:
            app.call('select', tab=closed)
            app.call('close')
            toast = wait(lambda: next((t for t in app.call('toasts')['toasts']
                                       if t['title'] == 'Closed tabs could not be saved to the Archive'), None), timeout=8, step=.2)
        finally:
            os.chmod(default_state, mode)
        row('persist_z02_archive_write_failure_toast', bool(toast), toast=toast,
            archiveExists=(default_state / 'archive.sqlite3').exists())

    def z07():
        # Z-07: a Blank Window with a tab, then a force quit. It comes back at relaunch, and again after
        # a second force quit of that launch.
        app = launch(urls=())
        try:
            app.call('key', key='n', modifiers=['control', 'command'], route='app')
            wait(lambda: app.call('blank-window')['isBlankWindow'] or None, timeout=8, step=.1)
            app.call('key', key='escape', route='app')
            h.new_tab(app, origin + '/z07-blank')
            time.sleep(2.5)
            before_kill = app.call('blank-window')
        finally:
            force_quit(app)

        def restored(app):
            s = app.call('blank-window')
            if s['browserWindows'] != 2:
                return None
            if not s['isBlankWindow']:
                other = next((w['id'] for w in app.call('shell-windows') if w['id'] != s['window']), None)
                if other:
                    app.call('window-focus', id=other, activate=True)
                    s = app.call('blank-window')
            return s if s['isBlankWindow'] else None

        app = launch(urls=())
        try:
            first_restore = wait(lambda: restored(app), timeout=10, step=.2) or app.call('blank-window')
            time.sleep(2.5)
        finally:
            force_quit(app)
        app = launch(urls=())
        second_restore = wait(lambda: restored(app), timeout=10, step=.2) or app.call('blank-window')
        urls = lambda s: [t['url'].rsplit('/', 1)[-1] for t in s.get('tabs', [])]
        row('persist_z07_blank_window_survives_force_quit', first_restore.get('isBlankWindow') and urls(first_restore) == ['z07-blank'],
            beforeKill=urls(before_kill), restored=first_restore)
        row('persist_z07_restored_blank_window_survives_second_force_quit',
            second_restore.get('isBlankWindow') and urls(second_restore) == ['z07-blank'], restored=second_restore)
        # Review r2 of #670: the Blank Window closes last, and a Dock reopen comes at once (before its
        # 1 s save). Only the browser window comes back: a closed Blank Window is not restored (C10).
        blank_id = second_restore.get('window')
        for other in [w['id'] for w in app.call('shell-windows') if w['id'] != blank_id]:
            app.call('window-focus', id=other, activate=True)
            app.call('window-close')
        wait(lambda: len(app.call('shell-windows')) == 1 or None, timeout=5, step=.05)
        app.call('window-focus', id=blank_id, activate=True)
        closed_at = time.monotonic()
        app.call('window-close')
        wait(lambda: not app.call('shell-windows') or None, timeout=5, step=.02)
        app.call('window-reopen')
        reopen_after = round(time.monotonic() - closed_at, 3)
        wait(lambda: app.call('shell-windows') or None, timeout=8, step=.1)
        time.sleep(1.5)
        after_reopen = app.call('blank-window')
        row('persist_z07_closed_blank_window_not_reopened', after_reopen['browserWindows'] == 1
            and not after_reopen['isBlankWindow'] and reopen_after < 1.0,
            reopenAfterSeconds=reopen_after, state={k: after_reopen.get(k) for k in ('browserWindows', 'isBlankWindow', 'tabs')})
        app.quit()
        # Later sections start with the browser window only.
        (state_dir / 'blank-windows.json').unlink(missing_ok=True)

    def z03():
        # Z-03: a real download, then an unreadable browser.json: the fresh model gives the Default
        # Profile a new ID for the same folder. Library > Downloads still lists the download, no error.
        downloads_dir = Path(tmp) / 'persist-r7-downloads'
        downloads_dir.mkdir(exist_ok=True)
        env = {'OPEN_DOWNLOADS_DEFAULT_DIRECTORY': str(downloads_dir)}
        app = launch(urls=(origin + '/z03-source',), extra_env=env)
        source = app.call('tabs')[0]['id']
        app.call('wait', tab=source)
        app.call('select', tab=source)
        before_ids = {v['id'] for v in app.call('downloads-state')['items']}
        # The fixture serves pages, so the download is a data: link with a download attribute.
        app.eval(source, '(() => {let a=document.createElement("a"); a.href="data:application/octet-stream;base64,T3BlbiByNyBkb3dubG9hZA=="; '
                         'a.download="persist-r7.txt"; a.id="download"; a.textContent="download"; document.body.replaceChildren(a)})()')
        app.call('click', tab=source, selector='#download')
        done = wait(lambda: next((v for v in app.call('downloads-state')['items']
                                  if v['id'] not in before_ids and v['state'] == 'completed'), None), timeout=20, step=.2)
        old_profile = app.call('spaces')[0]['profile']
        app.quit()
        snapshot.write_bytes(b'{"truncated":')
        app = launch(urls=(), extra_env=env)
        app.call('command', id='view-downloads')
        loaded = wait(lambda: (lambda s: s if s.get('historyLoaded') else None)(app.call('downloads-state')), timeout=10, step=.2) \
            or app.call('downloads-state')
        new_profile = app.call('spaces')[0]['profile']
        listed = [v for v in loaded['items'] if v['name'] == 'persist-r7.txt']
        unreadable = glob.glob(str(state_dir / 'browser.unreadable-*.json'))
        row('persist_z03_download_history_after_fresh_model', bool(done) and bool(listed) and not loaded.get('historyError')
            and bool(unreadable) and new_profile != old_profile,
            download=done, listed=listed, historyError=loaded.get('historyError'), profiles=[old_profile, new_profile],
            unreadable=[Path(u).name for u in unreadable])
        try:
            app.call('download-library-close')
        except Exception:
            pass

    def z01_z04():
        # Z-01: a journaled Profile folder that cannot be removed (an immutable folder, EPERM). The launch
        # goes on, the other journaled folder is removed, and the locked name stays journaled with its
        # Local State entry. Once the folder can be removed, the next launch finishes the cleanup.
        # Z-04: a deleted-Profile tree left aside by an earlier delete is swept after the launch.
        engine_root = root / 'Engine'
        locked, free = 'Locked-R7', 'Free-R7'
        for name in (locked, free):
            for folder in (root / 'Profiles' / name, engine_root / name):
                folder.mkdir(parents=True, exist_ok=True)
                (folder / 'synthetic-marker').write_text('synthetic persistence fixture')
        local_state = engine_root / 'Local State'
        state = json.loads(local_state.read_bytes()) if local_state.exists() else {}
        cache = state.setdefault('profile', {}).setdefault('info_cache', {})
        cache[locked] = {'name': 'Synthetic Locked'}
        cache[free] = {'name': 'Synthetic Free'}
        local_state.write_text(json.dumps(state))
        pending = root / 'Profiles/.pending-wipe.json'
        pending.write_text(json.dumps([locked, free]))
        trash = [engine_root / '.open-trash-r7-fixture', root / 'Profiles/.open-trash-r7-fixture']
        for folder in trash:
            (folder / 'nested').mkdir(parents=True, exist_ok=True)
            (folder / 'nested/synthetic-marker').write_text('left by an interrupted delete')
        subprocess.run(['chflags', 'uchg', str(engine_root / locked)], check=True)
        launched, launch_error = None, None
        try:
            try:
                app = launch(urls=())
                launched = app.call('tabs') is not None
            except Exception as error:
                launch_error = str(error)[:400]
            journal = json.loads(pending.read_text()) if pending.exists() else None
            info = json.loads(local_state.read_text()).get('profile', {}).get('info_cache', {})
            swept = wait(lambda: all(not f.exists() for f in trash) or None, timeout=10, step=.2)
            row('persist_z01_locked_profile_folder_does_not_block_launch', bool(launched) and journal == [locked]
                and (engine_root / locked / 'synthetic-marker').exists() and not (engine_root / free).exists()
                and not (root / 'Profiles' / free).exists() and locked in info and free not in info,
                launched=launched, launchError=launch_error, journal=journal, lockedKept=(engine_root / locked).exists(),
                freeGone=not (engine_root / free).exists(), infoCache=sorted(k for k in info if k in (locked, free)))
            row('persist_z04_trash_swept_after_launch', bool(launched) and bool(swept), left=[str(f) for f in trash if f.exists()])
        finally:
            subprocess.run(['chflags', '-R', 'nouchg', str(engine_root / locked)], check=False)
            for instance in apps:
                if not instance.closed:
                    instance.quit()
        app = launch(urls=())
        info = json.loads(local_state.read_text()).get('profile', {}).get('info_cache', {})
        row('persist_z01_cleanup_finishes_when_folder_unlocks', not pending.exists() and not (engine_root / locked).exists()
            and locked not in info, journal=pending.read_text() if pending.exists() else None,
            lockedGone=not (engine_root / locked).exists())

    section('persist_z05_z06', z05_z06)
    section('persist_z08', z08)
    section('persist_z02', z02)
    section('persist_z02_toast', z02_toast)
    section('persist_z07', z07)
    section('persist_z03', z03)
    section('persist_z01_z04', z01_z04)



def _values(value, key):
    if isinstance(value, dict):
        for k, v in value.items():
            if k == key and isinstance(v, str):
                yield v
            else:
                yield from _values(v, key)
    elif isinstance(value, list):
        for v in value:
            yield from _values(v, key)
