"""PB5 A1: Arc hides the Space header on a single unnamed Space; the Space menu toggles it
("Show Space Header" / "Hide Space Header"). Real paths: menu Rename Space + typing, the Space menu a
right-click builds (`sidebar-menu`), New Space through the automation used by other suites."""
import time


def run(factory, results, wait_until):
    app = factory(urls=(), fresh=True)
    key = 'open.sidebar.showSpaceHeaderOnSingleUnnamedSpace'
    saved = app.call('defaults', key=key, persistent=True)
    def header(): return app.call('space-header')
    def menu_titles():
        try: return [i for i in ('Show Space Header', 'Hide Space Header')
                     if _has(app, i)]
        except RuntimeError: return []
    def rename(text):
        app.call('window-focus', id=app.call('window-state')['id'], activate=True)
        app.call('menu-perform', id='rename-space')
        app.call('key', key='a', modifiers=['cmd'], route='app')
        if text: app.call('key', text=text)
        else: app.call('key', key='delete', route='app')
        app.call('key', key='return', route='app')
    try:
        app.call('defaults', key=key, value=None)
        named = app.call('space-header', reload=True)
        rename('')
        hidden = wait_until(lambda: (lambda h: h if h['visible'] is False else None)(header()), timeout=5, step=.05) or header()
        offer = menu_titles()
        results['space_header_hidden_single_unnamed'] = {
            'ok': named['visible'] is True and named['title'] is not None and hidden['title'] is None
                and hidden['spaces'] == 1 and hidden['visible'] is False and offer == ['Show Space Header'],
            'named': named, 'hidden': hidden, 'menu': offer}
        app.call('sidebar-menu', item='Show Space Header')
        shown = wait_until(lambda: (lambda h: h if h['visible'] else None)(header()), timeout=5, step=.05) or header()
        offer2 = menu_titles()
        stored = app.call('defaults', key=key)
        app.call('sidebar-menu', item='Hide Space Header')
        again = wait_until(lambda: (lambda h: h if not h['visible'] else None)(header()), timeout=5, step=.05) or header()
        results['space_header_menu_toggle'] = {
            'ok': shown['visible'] is True and shown['showPreference'] is True and stored is True
                and offer2 == ['Hide Space Header'] and again['visible'] is False and again['showPreference'] is False,
            'shown': shown, 'menu': offer2, 'stored': stored, 'again': again}
        # Rename while hidden: the header shows for the field, then stays (the Space is named).
        rename('Work')
        named_again = wait_until(lambda: (lambda h: h if h['title'] == 'Work' else None)(header()), timeout=5, step=.05) or header()
        results['space_header_rename_while_hidden'] = {'ok': named_again['title'] == 'Work' and named_again['visible'] is True
            and menu_titles() == [], 'after': named_again}
        # Two Spaces: an unnamed one keeps its header.
        rename('')
        app.call('space-create', title='Second')
        two = wait_until(lambda: (lambda h: h if h['spaces'] == 2 else None)(header()), timeout=5, step=.05) or header()
        results['space_header_two_spaces'] = {'ok': two['spaces'] == 2 and two['hidesHeader'] is False, 'state': two}
    finally:
        app.call('defaults', key=key, value=saved)
        app.quit()


def _has(app, title):
    try:
        app.call('sidebar-menu-state', item=title)
        return True
    except RuntimeError:
        return False
