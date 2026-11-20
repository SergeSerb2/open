"""Today auto-archive of split panes (BrowserModel.archiveExpiredTabs), real App.

A saved session holds two Today splits whose panes have different ages:
- a 3-pane split in the focused Space, widths [0.5, 0.3, 0.2], oldest pane expired;
- a 2-pane split in another Space that the window had selected, one pane expired.
The launch sweep archives the expired panes. The survivors of the first split keep
their relative widths ([0.6, 0.4], also in the live layout), and the window's selection
in the second Space moves from the dissolved split to its surviving tab.
"""
import json
from pathlib import Path
import time
import uuid


def checks(h, factory, results, tmp):
    def record(name, condition, **detail):
        results['AS_' + name] = dict(detail, ok=bool(condition))

    app = factory(urls=(), fresh=True)
    try:
        app.call('save')
        snapshot = json.loads((Path(app.user_data) / 'State/browser.json').read_text())
    finally:
        app.quit()
    now = time.time()

    def tab(title, age):
        page = Path(tmp) / ('archive-split-' + title.replace(' ', '-') + '.html')
        page.write_text('<title>%s</title><h1>%s</h1>' % (title, title))
        return {'id': str(uuid.uuid4()).upper(), 'url': page.as_uri(), 'title': title,
                'createdAt': now - age, 'lastActiveAt': now - age, 'isMuted': False, 'isUnread': False}

    def split(panes, fractions):
        return {'split': {'_0': {'id': str(uuid.uuid4()).upper(), 'orientation': 'horizontal',
                                 'fractions': fractions, 'panes': panes, 'focusedPaneID': panes[0]['id']}}}

    old = 3 * 86400  # Past the default 12-hour Today threshold.
    shown = tab('AS Shown', 0)
    p1, p2, p3 = tab('AS P1 old', old), tab('AS P2', 0), tab('AS P3', 0)
    q1, q2 = tab('AS Q1 old', old), tab('AS Q2', 0)
    first, second = split([p1, p2, p3], [0.5, 0.3, 0.2]), split([q1, q2], [0.5, 0.5])
    space = snapshot['spaces'][0]
    space['today'] = [{'tab': {'_0': shown}}, first]
    other = json.loads(json.dumps(space))
    other.update(id=str(uuid.uuid4()).upper(), title='AS Second', pinned=[], today=[second])
    snapshot['spaces'].append(other)
    window = snapshot['windows'][0]
    window['focusedSpaceID'] = space['id']
    window['selectedNodeBySpace'] = {space['id']: shown['id'], other['id']: second['split']['_0']['id']}
    fixture = Path(tmp) / 'archive-split-sweep.json'
    fixture.write_text(json.dumps(snapshot))

    app = factory(urls=(), snapshot=str(fixture))
    try:
        app.call('save')
        saved = json.loads((Path(app.user_data) / 'State/browser.json').read_text())
        today = {s['id']: s['today'] for s in saved['spaces']}
        node = next((n['split']['_0'] for n in today.get(space['id'], []) if 'split' in n), None)
        fractions = node['fractions'] if node else None
        expected = [0.3 / 0.5, 0.2 / 0.5]
        record('split_survivors_keep_relative_widths',
               node is not None and [p['id'] for p in node['panes']] == [p2['id'], p3['id']]
               and len(fractions) == 2 and all(abs(a - b) < 1e-9 for a, b in zip(fractions, expected)),
               split=node, expected=expected)
        survivor = [n['tab']['_0']['id'] for n in today.get(other['id'], []) if 'tab' in n]
        selected = saved['windows'][0]['selectedNodeBySpace'].get(other['id'])
        record('dissolved_split_selection_moves_to_survivor',
               survivor == [q2['id']] and selected == q2['id'], today=survivor, selected=selected)
        archived = {r['id'].upper(): r for r in app.call('archive-list')['rows']}
        record('expired_panes_archived',
               {p1['id'], q1['id']} <= set(archived) and all(archived[i]['reason'] == 'autoArchived' for i in (p1['id'], q1['id']))
               and not ({p2['id'], p3['id'], q2['id']} & set(archived)), archived=sorted(archived))
        # The live layout uses the stored widths (a count mismatch would fall back to equal widths).
        app.call('sidebar-click', node=node['id'])
        state = h.wait_until(lambda: (lambda s: s if len(s.get('panes', [])) == 2 else None)(app.call('split', op='state')),
                             timeout=5, step=.05) or {}
        widths = [p['frame'][2] for p in state.get('panes', [])]
        record('split_layout_uses_kept_widths',
               len(widths) == 2 and state.get('fractions') == fractions and widths[0] > widths[1] * 1.3,
               widths=widths, fractions=state.get('fractions'))
    finally:
        app.quit()
