"""Notes with Peek and Little Open through the real App: a link in a Note follows the
window's link policy (Peek for a pinned Note's link to another site or with Shift;
Little Open with ⌥⌘; otherwise a new tab, ⌘ in the background), and New Note with a
Little Open window in front lands in the browser window. Socket only; loopback pages.
"""
import time


def run(factory, results, tmp, h):
    def row(name, ok, **evidence):
        results[name] = dict(ok=bool(ok), **evidence)
        print('notes-peek %-34s %s' % (name, 'PASS' if ok else 'FAIL'), flush=True)

    def key(name, *mods, **kw): return app.call('key', key=name, modifiers=list(mods), route='app', **kw)

    def peek(): return app.call('peek-state')

    def note(): return app.call('note')

    server, origin = h._fixture_server('NotesPeek')
    target = origin + '/target'
    app = factory(urls=(origin + '/page',), fresh=True)
    try:
        web = app.call('tabs')[0]['id']
        app.call('wait', tab=web)
        app.call('note', action='create'); app.call('key', text='Links'); key('return'); app.call('key', text='go to map')
        s = note(); tab = s['tab']
        at = s['body'].find('map')
        app.call('note', action='select', start=at, length=3)
        app.call('note', action='press', item='link'); app.call('key', text=target); key('return')
        has_link = any(f['type'] == 'link' for f in note()['formats'])

        # 1. Today Note: plain click → new foreground tab; ⌘-click → background tab (unread).
        before = {t['id'] for t in app.call('tabs')}
        app.call('note', action='click-link', at=at + 1)
        fg = h.wait_until(lambda: [t for t in app.call('tabs') if t['id'] not in before] or None, timeout=5, step=.05) or []
        selected_fg = app.call('note')['tab']
        app.call('select', tab=tab); h.wait_until(lambda: note()['shown'] and note()['tab'] == tab, timeout=5, step=.05)
        before = {t['id'] for t in app.call('tabs')}
        app.call('note', action='click-link', at=at + 1, modifiers=['command'])
        bg = h.wait_until(lambda: [t for t in app.call('tabs') if t['id'] not in before] or None, timeout=5, step=.05) or []
        row('today_note_link_opens_tab', has_link and len(fg) == 1 and fg[0]['url'].startswith(target) and selected_fg == fg[0]['id']
            and len(bg) == 1 and bg[0]['unread'] and note()['tab'] == tab, fg=fg, bg=bg)

        # 2. Shift-click on a Today Note → Peek (Settings ▸ Links "Open Peek with Shift-click", on by default).
        app.call('note', action='click-link', at=at + 1, modifiers=['shift'])
        p = h.wait_until(lambda: (lambda x: x if x['shown'] else None)(peek()), timeout=5, step=.05) or peek()
        row('shift_click_opens_peek', p['shown'] and p['stack'] and p['stack'][-1]['source'] == tab, peek=p)
        key('escape'); h.wait_until(lambda: not peek()['shown'] or None, timeout=5, step=.05)

        # 3. Pinned Note: a plain click on a link to another site → Peek.
        app.call('command', id='pin-unpin-tab')
        pinned = any(t['id'] == tab and t['section'] == 'pinned' for t in app.call('tabs'))
        count = len(app.call('tabs'))
        app.call('note', action='click-link', at=at + 1)
        p = h.wait_until(lambda: (lambda x: x if x['shown'] else None)(peek()), timeout=5, step=.05) or peek()
        row('pinned_note_link_opens_peek', pinned and p['shown'] and p['stack'][-1]['source'] == tab and len(app.call('tabs')) == count,
            pinned=pinned, peek=p)
        key('escape'); h.wait_until(lambda: not peek()['shown'] or None, timeout=5, step=.05)

        # 4. ⌥⌘-click → Little Open with the link.
        sessions = {s['id'] for s in app.call('little-open-state')['sessions']}
        app.call('note', action='click-link', at=at + 1, modifiers=['command', 'option'])
        lo = h.wait_until(lambda: [s for s in app.call('little-open-state')['sessions'] if s['id'] not in sessions] or None, timeout=8, step=.1) or []
        row('option_command_click_opens_little_open', len(lo) == 1 and lo[0]['url'].startswith(target), littleOpen=lo)

        # 5. ⌃⇧N with the Little Open window in front: the Note lands in the browser window.
        if lo:
            # The Little Open window must really be key, and the menu rebuilt for it (the App is
            # then the menu's dispatcher): that is the state in which ⌃⇧N did nothing (DMG d).
            is_key = h.wait_until(lambda: any(s['id'] == lo[0]['id'] and s['key'] for s in app.call('little-open-state')['sessions']) or None, timeout=5, step=.05)
            time.sleep(.6)
            notes_before = [t['id'] for t in app.call('tabs') if t['url'].startswith('open://note/')]
            key('n', 'control', 'shift', window=lo[0]['window'])
            made = h.wait_until(lambda: [t for t in app.call('tabs') if t['url'].startswith('open://note/') and t['id'] not in notes_before] or None, timeout=5, step=.05) or []
            still = any(s['id'] == lo[0]['id'] for s in app.call('little-open-state')['sessions'])
            shown = note()
            row('new_note_from_little_open_goes_to_browser_window', bool(is_key) and len(made) == 1 and still and shown['tab'] == made[0]['id'] and shown['shown'],
                made=made, littleOpenKey=bool(is_key), littleOpenStillOpen=still, shown={k: shown.get(k) for k in ('tab', 'shown')})
        else:
            row('new_note_from_little_open_goes_to_browser_window', False, reason='no Little Open window')
    finally:
        app.quit()
        server.shutdown()
