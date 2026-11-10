"""Real navigation between the URL snapshot and asynchronous browser creation."""
from pathlib import Path
import time
import uuid


DELAY_KEY = 'OPEN_AUTOMATION_BROWSER_CREATION_DELAY_MS'
DELAY_MS = 1500


def run(app, results, origin, api):
    token = uuid.uuid4().hex
    name = 'Pending Navigation ' + token
    app.call('profiles-shell', action='create', name=name)
    app.call('space-create', title=name, profile=name)
    path_a = '/pending-navigation-a-' + token
    path_b = '/pending-navigation-b-' + token
    url_a, url_b = origin + path_a, origin + path_b
    log = Path(app.log.name if app.direct_child else app.launch_log_path)
    offset = log.stat().st_size
    tab = app.call('open', url=url_a)['id']
    document = None

    def arrived(url, marker):
        nonlocal document
        state = app.call('tab-state', tab=tab)
        if not (state.get('page') or {}).get('live'):
            return False
        try:
            document = app.call('eval', tab=tab, timeout=3, js='''({
                url: location.href, title: document.title,
                marker: document.body ? document.body.textContent.trim() : '',
                readyState: document.readyState
            })''')
        except RuntimeError as error:
            if 'context was destroyed' in str(error) or 'Cannot find context' in str(error):
                return False
            raise
        return (document['url'] == url and document['title'] == marker
                and document['marker'] == marker and document['readyState'] == 'complete')

    release = app.config == 'Release'
    held = None
    if release:
        assert api['wait_until'](lambda: arrived(url_a, 'Profiles shell ' + path_a),
                                 timeout=20, step=.05), document
        assert b'browser-creation-delay' not in log.read_bytes()[offset:]
    else:
        def snapshot_held():
            state = app.call('tab-state', tab=tab)
            page = state.get('page') or {}
            message = 'browser-creation-delay page=%s ms=%s' % (page.get('identifier'), DELAY_MS)
            return state if message.encode() in log.read_bytes()[offset:] and not page.get('live') else None
        held = api['wait_until'](snapshot_held, timeout=5, step=.02)
        assert held, 'browser snapshot was not held before navigation: ' + repr(app.call('tab-state', tab=tab))

    # Exactly one later navigation through the App's normal content path.
    started = time.monotonic()
    app.call('navigate', tab=tab, url=url_b)
    after_request = app.call('tab-state', tab=tab)
    loaded = api['wait_until'](lambda: arrived(url_b, 'Profiles shell ' + path_b),
                               timeout=10, step=.05)
    state = app.call('tab-state', tab=tab)
    page = state.get('page') or {}
    results['shell_pending_navigation_' + ('delay_ignored_release' if release else 'during_creation')] = {
        'ok': bool(loaded) and state['url'] == url_b and state['visible']
              and page.get('live') and not page.get('hidden')
              and (release or not after_request['page']['live']),
        'delayMs': DELAY_MS, 'heldBeforeNavigation': held is not None,
        'liveWhenNavigationSubmitted': (after_request.get('page') or {}).get('live'),
        'initialURL': url_a, 'requestedURL': url_b, 'modelURL': state['url'],
        'document': document, 'page': page,
        'elapsedAfterNavigationSeconds': time.monotonic() - started,
    }
