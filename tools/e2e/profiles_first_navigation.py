"""A fresh Profile's first document must load without a second navigation."""
import os
import time
import uuid


def run(app, results, origin, api):
    token = uuid.uuid4().hex
    name = 'First Navigation ' + token
    app.call('profiles-shell', action='create', name=name)
    profile = next(p for p in app.call('profiles-shell')['profiles'] if p['name'] == name)
    assert not profile['loaded'] and profile['spaces'] == 0, profile
    app.call('space-create', title=name, profile=name)
    prepared = os.environ.get('OPEN_PROFILES_FIRST_NAV_PREPARE_CONTEXT') == '1'
    if prepared:
        # A Settings read creates the context without opening a document.
        app.call('credentials-prefs', profile=name)
        app.call('credentials', profile=name)
    path = '/first-navigation-' + token
    url = origin + path
    marker = 'Profiles shell ' + path
    started = time.monotonic()
    tab = app.call('open', url=url)['id']
    # Use the same public load-wait command as the other navigation flows.
    # It may request content before the view's deferred attachment runs.
    app.call('wait', tab=tab, timeout=25)
    document = None

    def arrived():
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

    loaded = api['wait_until'](arrived, timeout=20, step=.1)
    state = app.call('tab-state', tab=tab)
    results['shell_fresh_profile_first_navigation'] = {
        'ok': bool(loaded) and state['visible'] and state['selected']
              and state['profile'] == profile['id'] and state['url'] == url
              and state['page']['live'] and not state['page']['hidden']
              and state['page']['context'] == profile['directory'],
        'profileInitiallyLoaded': profile['loaded'], 'requestedURL': url,
        'contextPreparedBeforeOpen': prepared,
        'waitForLoadBeforeProbe': True,
        'document': document, 'elapsedSeconds': time.monotonic() - started,
        'visible': state['visible'], 'selected': state['selected'],
        'page': state.get('page'), 'modelURL': state['url'],
        'profileMatches': state['profile'] == profile['id'],
    }
