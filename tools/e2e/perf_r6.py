"""Bug sweep r6 idle and tab-switch cost rows, counted in the real App (no timing budget).

PERF-06: a background tab whose title ticks every 1.5 s no longer rewrites browser.json after
each tick (title-only changes save within 10 s), and no longer wakes Handoff; quit still
saves its latest title.
PERF-07: switching between two Today tabs while a third holds the earliest auto-archive
deadline keeps the armed archive timer (no invalidation, no re-arm per switch).
"""
import http.server
import json
import os
import threading
import time
from loopback_http import LoopbackHTTPServer

TICKER = b'''<!doctype html><title>T0</title><h1>ticker</h1>
<script>let n = 0; setInterval(() => { document.title = 'T' + (++n); }, 1500);</script>'''


def run(factory, results, wait_until):
    class Page(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = TICKER if self.path == '/ticker' else ('<!doctype html><title>R6 %s</title><h1>%s</h1>' % (self.path, self.path)).encode()
            self.send_response(200); self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        def log_message(self, *_): pass
    server = LoopbackHTTPServer(Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = 'http://127.0.0.1:%d' % server.server_address[1]
    app = factory(urls=(base + '/oldest',), fresh=True)
    try:
        oldest = app.call('tabs')[0]['id']
        app.call('wait', tab=oldest)
        a = app.call('open', url=base + '/a')['id']; app.call('wait', tab=a)
        b = app.call('open', url=base + '/b')['id']; app.call('wait', tab=b)

        # PERF-07: A <-> B ten times; the oldest tab keeps the earliest deadline.
        time.sleep(1.5)
        before, saves = app.call('archive-state'), app.call('frame-save-counters')
        for index in range(10):
            app.call('select', tab=a if index % 2 == 0 else b)
            time.sleep(.15)
        time.sleep(.5)
        after, saves_after = app.call('archive-state'), app.call('frame-save-counters')
        rearms = after.get('timerGeneration', 0) - before.get('timerGeneration', 0)
        results['perf_tab_switch_keeps_archive_timer'] = {
            'ok': before.get('running') is True and after.get('timerArmed') is True and rearms == 0,
            'timerRearms': rearms, 'invalidations': after.get('invalidations', 0) - before.get('invalidations', 0),
            'nextExpiry': [before.get('nextExpiry'), after.get('nextExpiry')],
            # PERF-10 evidence (reported, not asserted): strip syncs and save requests per 10 switches.
            'mirrorSyncs': saves_after['mirrorSyncs'] - saves['mirrorSyncs'], 'saveRequests': saves_after['scheduled'] - saves['scheduled']}

        # PERF-06: a background ticker for 12 s while A is shown.
        ticker = app.call('open', url=base + '/ticker', background=True)['id']
        app.call('wait', tab=ticker)
        app.call('select', tab=a)
        time.sleep(2)
        counts, handoff = app.call('frame-save-counters'), app.call('handoff-state')
        time.sleep(12)
        counts_after, handoff_after = app.call('frame-save-counters'), app.call('handoff-state')
        last_title = app.eval(ticker, 'document.title')
        captures = counts_after['captures'] - counts['captures']
        wakes = handoff_after['updates'] - handoff['updates']
        results['perf_background_title_saves_coalesced'] = {
            'ok': captures <= 2 and wakes <= 1 and handoff_after.get('published') is True,
            'captures': captures, 'metadataRequests': counts_after.get('metadataScheduled', 0) - counts.get('metadataScheduled', 0),
            'handoffUpdates': wakes, 'lastTitle': last_title}
        user_data = app.user_data
    finally:
        app.quit()
        server.shutdown(); server.server_close()
    # Quit flushes the title that waited for its 10 s save.
    with open(os.path.join(user_data, 'State', 'browser.json')) as stream:
        saved = json.dumps(json.load(stream))
    numbers = [int(part[1:]) for part in saved.replace('"', ' ').split() if part.startswith('T') and part[1:].isdigit()]
    final = int(last_title[1:]) if last_title and last_title[1:].isdigit() else -1
    results['perf_background_title_saved_on_quit'] = {'ok': bool(numbers) and max(numbers) >= final >= 1,
                                                      'savedMax': max(numbers) if numbers else None, 'lastSeen': final}
