"""Real extension and ad-block contexts in a page and its iframe."""
import contextlib
import tempfile
from pathlib import Path


def run(app, results, wait, new_tab, static_server, darkreader):
    old_enabled = app.call('settings-adblock')['enabled']
    tab = None
    server = None
    try:
        app.call('settings-adblock', enabled=True)
        assert wait(lambda: any(c['adBlockStatus']['engine_loaded']
            for p in app.call('settings-adblock-engine')['profiles']
            for c in p['contexts']), timeout=40), 'native lists did not load'
        with tempfile.TemporaryDirectory(prefix='open-extension-worlds-') as folder:
            fixture = Path(folder)
            common = ('<!doctype html><title>Open world separation</title>'
                      '<link rel="icon" href="data:,"><div class="ad-slot">Cosmetic control</div>')
            (fixture / 'index.html').write_text(common + '<iframe src="/frame.html"></iframe>')
            (fixture / 'frame.html').write_text(common)
            server, origin = static_server(folder)
            tab = new_tab(app, origin + '/index.html')
            frames = app.call('devtools', tab=tab, method='Page.getFrameTree')['frameTree']
            frame_ids = {frames['frame']['id']} | {
                child['frame']['id'] for child in frames.get('childFrames', [])}
            app.call('events')
            app.call('devtools', tab=tab, method='Runtime.enable')
            contexts = {}
            def observe():
                for event in app.call('events'):
                    if event.get('method') == 'Runtime.executionContextCreated':
                        context = event['params']['context']
                        if context.get('auxData', {}).get('frameId') in frame_ids:
                            contexts[context['id']] = context
                return len(contexts) >= 6
            assert wait(observe, timeout=10), 'page and iframe contexts were not reported'
            expression = '''(() => ({
                binding: typeof globalThis.__openAdBlock === 'object',
                extension: globalThis.chrome?.runtime?.id || null,
                mode: document.documentElement.getAttribute('data-darkreader-mode'),
                hidden: getComputedStyle(document.querySelector('.ad-slot')).display === 'none'
            }))()'''
            def sample():
                observe()
                rows = []
                for identifier, context in contexts.items():
                    reply = app.call('devtools', tab=tab, method='Runtime.evaluate', params={
                        'contextId': identifier, 'expression': expression, 'returnByValue': True})
                    assert 'exceptionDetails' not in reply, reply
                    rows.append(dict(context=identifier, frame=context['auxData']['frameId'],
                        name=context.get('name', ''), default=context['auxData'].get('isDefault', False),
                        **reply['result']['value']))
                return rows
            rows = sample()
            def ready():
                nonlocal rows
                rows = sample()
                return all(any(r['frame'] == frame and r['extension'] == darkreader
                               for r in rows) and any(r['frame'] == frame and r['binding']
                               for r in rows) and any(r['frame'] == frame and r['default']
                               and r['mode'] == 'dynamic' and r['hidden']
                               for r in rows) for frame in frame_ids)
            assert wait(ready, timeout=15), 'page and iframe injection did not become ready'
            results['content_scripts_page_and_iframe'] = {
                'ok': len(frame_ids) == 2 and all(
                    any(r['frame'] == frame and r['extension'] == darkreader for r in rows)
                    and any(r['frame'] == frame and r['default'] and r['mode'] == 'dynamic'
                            and r['hidden'] for r in rows) for frame in frame_ids),
                'frames': sorted(frame_ids), 'contexts': rows}
            results['content_script_adblock_context_separation'] = {
                'ok': all(sum(r['frame'] == frame and r['binding'] for r in rows) == 1
                          for frame in frame_ids)
                    and all(not r['binding'] for r in rows if r['extension'])
                    and all(r['extension'] is None and not r['default']
                            for r in rows if r['binding'])
                    and all(not r['binding'] and r['extension'] is None
                            for r in rows if r['default']),
                'contexts': rows}
    finally:
        if tab is not None:
            with contextlib.suppress(Exception):
                app.call('devtools', tab=tab, method='Runtime.disable')
            with contextlib.suppress(Exception):
                app.call('close', tab=tab)
        if server is not None:
            server.shutdown()
            server.server_close()
        app.call('settings-adblock', enabled=old_enabled)
