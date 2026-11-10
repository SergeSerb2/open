"""Chromium NTP navigation through real shell and renderer entry points."""
import json


def run(factory, results, api, style):
    aliases = ('chrome://newtab/', 'about:newtab', 'chrome://new-tab-page/',
               'chrome://new-tab-page-third-party/')
    app = None
    try:
        app = factory(urls=(aliases[0],))
        tab = app.call('tabs')[0]['id']
        pid = app.call('ping')['pid']

        def loaded(name, address):
            state = api.wait_until(lambda: (lambda p: p if p.get('live') and not p.get('loading', True) else None)(app.page(tab)),
                                   timeout=15, step=.05)
            expected = 'about:blank' if style == 'alloy' else 'Chrome NTP'
            correct = bool(state) and (state['url'] == 'about:blank' if style == 'alloy'
                else state['url'] in aliases)
            results[name] = {'ok': correct
                             and app.call('ping')['pid'] == pid,
                             'requested': address, 'page': state, 'expected': expected}

        loaded('initial_newtab', aliases[0])
        for index, address in enumerate(aliases):
            app.call('navigate', tab=tab, url=address)
            loaded('navigate_alias_' + str(index), address)
        if style == 'alloy':
            # A renderer navigation bypasses OEWebContent.loadURL. The page's
            # own script and a real DOM link must also stay out of NTP WebUI.
            for index, address in enumerate(aliases):
                app.eval(tab, 'document.body.innerHTML = \'<a id="ntp">New tab</a>\';'
                         'document.querySelector("a").href=' + json.dumps(address))
                app.call('click', tab=tab, selector='#ntp')
                loaded('link_alias_' + str(index), address)
        # The refusal must not disable ordinary engine navigation.
        app.call('navigate', tab=tab, url='data:text/html,<title>NTP control</title>')
        app.call('wait', tab=tab)
        results['ordinary_navigation'] = {'ok': app.eval(tab, 'document.title') == 'NTP control'}
    finally:
        if app:
            app.quit()
