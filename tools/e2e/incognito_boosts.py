"""Real normal/private windows sharing one parent Profile and matching site."""
def check_boosts_private(app, normal, base, wait, results, harness):
    saved = {}
    private = None
    def focus(window):
        app.call('window-focus', id=window['id'], activate=True)
    def editor(action='state', **args):
        return app.call('boost-editor', action=action, **args)
    def tap(control):
        editor('tap', id=control)
    def probe(tab):
        return app.eval(tab, "({js:window.s12PrivateBoost??null,style:!!document.getElementById('open-boosts-style'),runtime:typeof window.__openBoosts,filter:getComputedStyle(document.documentElement).filter})")
    try:
        focus(normal)
        for key, value in {'open.advanced.enableBoosts': True,
                           'open.boosts.hasDismissedInterstitial': False,
                           'open.boosts.hasDismissedJSNotice': False,
                           'open.boosts.codeEditorSize': '480x588'}.items():
            saved[key] = app.call('defaults', key=key, persistent=True)
            app.call('defaults', key=key, value=value)
        normal_tab = app.call('open', url=base + '/boost-normal')['id']
        app.call('wait', tab=normal_tab)
        assert editor('customize') is True, 'normal Customize must open the editor'
        if editor()['interstitial']:
            tap('firstRun.makeABoost')
        assert wait(lambda: editor()['colorsReady'], timeout=10, step=.05)
        tap('editor.color.invert'); tap('code')
        assert wait(lambda: editor()['mode'] == 'code', timeout=5, step=.02)
        tap('editor.code.js')
        source = 'window.s12PrivateBoost="normal-only";'
        editor('type', text=source)
        assert wait(lambda: editor()['boost']['js'] == source, timeout=5, step=.02)
        profile = editor()['profile']; editor('close')
        # A new document/browser uses the saved document-start plan. No postload JS.
        normal_tab = app.call('open', url=base + '/boost-matching')['id']
        app.call('wait', tab=normal_tab)
        active = probe(normal_tab)
        normal_context = app.page(normal_tab)['context']
        assert active['js'] == 'normal-only' and active['style'] and active['runtime'] == 'object', active
        previous = {w['id'] for w in app.call('incognito-state')['windows']}
        app.call('menu-perform', id='new-incognito-window')
        private = wait(lambda: next((w for w in app.call('incognito-state')['windows']
                        if w['private'] and w['id'] not in previous), None), timeout=5, step=.05)
        assert private, 'same-Profile private window did not open'
        focus(private)
        if app.call('commandbar-state').get('presented'):
            app.call('key', key='escape', route='app')
        private_tab = app.call('open', url=base + '/boost-matching')['id']
        app.call('wait', tab=private_tab)
        state = app.call('incognito-state', private=True)
        first = probe(private_tab)
        refused = []
        for command, args in [('boost-editor', {'action': 'open'}),
                              ('command', {'id': 'new-boost'}),
                              ('command', {'id': 'edit-boost'}),
                              ('command', {'id': 'new-legacy-boost'})]:
            try:
                app.call(command, **args)
            except RuntimeError:
                refused.append(command + ':' + str(args))
        customize = editor('customize')
        for enabled in (False, True):
            app.call('defaults', key='open.advanced.enableBoosts', value=enabled)
            target = editor()['refreshCount']
            assert wait(lambda: editor()['completedRefreshCount'] >= target, timeout=10, step=.02)
        after = probe(private_tab)
        empty = {'js': None, 'style': False, 'runtime': 'undefined', 'filter': 'none'}
        results['boosts_disabled'] = dict(
            ok=state['private'] and state['ephemeral'] and state['parent'] == profile
                and state['originalContext'] == normal_context and not state['boostScriptIDs']
                and first == after == empty and len(refused) == 4
                and customize is False and not editor()['open'],
            negative=active['js'] == 'normal-only' and active['style'],
            normal=active, privateFirstDocument=first, privateAfterRefresh=after,
            parent=state['parent'], originalContext=state['originalContext'],
            boostScriptIDs=state['boostScriptIDs'], editorRefusals=len(refused),
            customizeRefused=customize is False)
    finally:
        if private:
            focus(private); app.call('window-close')
        focus(normal)
        editor('close')
        harness._restore_defaults(app, saved)
