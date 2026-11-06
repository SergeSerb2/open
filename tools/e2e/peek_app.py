"""Section 9 Peek acceptance through the real App automation socket."""
import json
import os
import time


def run(factory, results, tmp, harness):
    new_tab, wait_until = harness['new_tab'], harness['wait_until']
    server, port = harness['_sleep_server']()
    app = factory(urls=(), fresh=True)
    keys = ('open.peek.otherSites', 'open.peek.shiftClick')
    saved = {key: app.call('defaults', key=key, persistent=True) for key in keys}
    for key in keys:
        app.call('defaults', key=key, value=None)
    def url(host='a.localhost', path='a.html'):
        return 'http://%s:%d/%s' % (host, port, path)
    def state(): return app.call('peek-state')
    def top(): return state()['stack'][-1]['content']
    def clear(): app.call('peek-close')
    def opened():
        def ready():
            s=state()
            return s['shown'] and s['stack'][-1]['content'] > 0
        return wait_until(ready,timeout=5,step=.05)
    def close():
        app.call('peek-button', id='confirmCloseModal')
        return wait_until(lambda: not state()['stack'], timeout=5, step=.05)
    def navigate(tab, target):
        app.call('navigate', tab=tab, url=target)
        app.call('wait', tab=tab)
    def click(tab, target, shift=False, command=False):
        point = app.eval(tab, '''(() => { const a=document.createElement('a'); a.id='peek-link';
          a.textContent='Peek target'; a.href=%s; document.body.replaceChildren(a);
          const r=a.getBoundingClientRect(); return [r.x+r.width/2,r.y+r.height/2] })()''' % json.dumps(target))
        for kind in ('mousePressed', 'mouseReleased'):
            app.call('devtools', tab=tab, method='Input.dispatchMouseEvent', params={
                'type': kind, 'x': point[0], 'y': point[1], 'button': 'left', 'clickCount': 1, 'modifiers': (8 if shift else 0) | (4 if command else 0)})
    source_split = None
    def select_source():
        if app.call('window-state')['space'] != source_space:
            app.call('space', space=source_space)
        if source_split:
            app.call('sidebar-click', node=source_split)
            app.call('key', key='1', modifiers=['control','shift'], route='app')
        else:
            app.call('select', tab=source)
    def menu(id):
        def find(rows):
            for row in rows:
                if row.get('id') == id: return row
                found = find(row.get('items', []))
                if found: return found
        return find(app.call('menu-state')) or {}
    try:
        app.call('window-frame', frame=[80, 60, 1280, 820])
        source_window = app.call('window-state')['id']
        source_space = app.call('window-state')['space']
        source = new_tab(app, url())
        # A first Shift-click in a new standard window must create Peek lazily.
        app.call('menu-perform',id='new-window')
        wait_until(lambda:app.call('window-state')['id']!=source_window,timeout=5,step=.05)
        fresh=new_tab(app,url())
        lazy=app.call('window-state')['peekCreated'] is False
        click(fresh,url(),shift=True)
        results['peek_shift_fresh_window']={'ok':lazy and bool(opened()),'lazyBeforeClick':lazy}
        clear()
        for _ in range(3):
            if app.call('window-state')['id']==source_window: break
            app.call('window-close')
        app.call('window-focus',id=source_window,activate=True)
        app.call('pin', tab=source)
        click(source, url('b.localhost'))
        results['peek_policy_pinned_cross_site'] = {'ok': bool(opened()) and app.eval(source, 'location.hostname') == 'a.localhost'}
        clear()
        navigate(source,url())
        click(source, url('docs.a.localhost'))
        same = wait_until(lambda: app.eval(source, 'location.hostname') == 'docs.a.localhost', timeout=8, step=.05)
        results['peek_policy_same_site'] = {'ok': bool(same) and not state()['stack']}
        today = new_tab(app, url())
        click(today,url('b.localhost'))
        moved=wait_until(lambda:app.eval(today,'location.hostname')=='b.localhost',timeout=8,step=.05)
        results['peek_policy_today_navigates']={'ok':bool(moved) and not state()['stack']}
        navigate(today,url())
        count=len(app.call('tabs'))
        click(today,url('b.localhost'),command=True)
        tab_created=wait_until(lambda:len(app.call('tabs'))==count+1,timeout=8,step=.05)
        results['peek_command_click_keeps_new_tab']={'ok':bool(tab_created) and not state()['stack'] and app.eval(today,'location.hostname')=='a.localhost'}
        click(today, url(), shift=True)
        results['peek_policy_shift_today'] = {'ok': bool(opened())}
        if app.call('window-state')['id'] != source_window:
            app.call('window-close'); app.call('window-focus',id=source_window,activate=True)
        clear()
        favorite = new_tab(app, url())
        app.call('favorite', tab=favorite)
        click(favorite, url('b.localhost'))
        results['peek_policy_favorite'] = {'ok': bool(opened()) and app.eval(favorite, 'location.hostname') == 'a.localhost'}
        if not state()['shown']:
            app.call('peek-open', tab=favorite, url=url('b.localhost')); opened()
        count = len(app.call('tabs')); page = top()
        app.call('peek-button', id='openInSplit')
        results['peek_split_favorite_refused'] = {'ok': state()['shown'] and top() == page and len(app.call('tabs')) == count}
        clear()
        app.call('select', tab=source)
        for key, shifted in zip(keys, (False, True)):
            for k in keys: app.call('defaults', key=k, value=k!=key)
            target_tab = today if shifted else source
            app.call('select',tab=target_tab)
            navigate(target_tab, url())
            click(target_tab, url('b.localhost'), shift=shifted)
            if shifted:
                different = wait_until(lambda: app.call('window-state')['id'] != source_window, timeout=5, step=.05)
                no_peek = not state()['stack']
                results['peek_setting_off_shiftClick'] = {'ok': bool(different) and no_peek, 'defaultNewWindow': bool(different)}
                if different: app.call('window-close')
                app.call('window-focus', id=source_window, activate=True)
            else:
                moved = wait_until(lambda: app.eval(source, 'location.hostname') == 'b.localhost', timeout=8, step=.05)
                results['peek_setting_off_otherSites'] = {'ok': bool(moved) and not state()['stack']}
            for k in keys: app.call('defaults', key=k, value=True)
        app.call('select',tab=source)
        navigate(source, url())
        app.call('peek-open', tab=source, url=url('b.localhost'))
        opened(); app.call('wait', tab=top())
        ui = app.call('peek-ui'); panel, content = ui['panel'], ui['content']
        button_ids = [b['id'] for b in ui['buttons']]
        geometry = abs(panel[2] - round(ui['baseWidth'] * .8)) <= 1 and abs(panel[3] - (content[3] - 4)) <= 1
        geometry &= abs(panel[0] - (content[0] + (ui['baseWidth'] - panel[2])/2)) <= 1 and abs(panel[1] - (content[1] + 2)) <= 1
        geometry &= all(b['frame'][2:] == [35,33] and abs(b['frame'][0]-panel[0]-panel[2]-13)<=1
            and abs(b['frame'][1]-panel[1]-9-i*43)<=1 for i,b in enumerate(ui['buttons']))
        results['peek_overlay_geometry_dim_buttons'] = {'ok': geometry and not ui['dimHidden'] and ui['dimAlpha'] == 1
            and button_ids == ['confirmCloseModal', 'openInSpaceExpander', 'openInSplit'], 'ui': ui}
        results['peek_badge_sidebar_state'] = {'ok': source in ui['badges'] and ui['sourceRow'] == source, 'badges': ui['badges']}
        # Actual dim click in OUR window. The native overlay receives mouseDown.
        app.call('mouse', action='click', x=content[0]+2, y=content[1]+content[3]/2)
        dismissed = wait_until(lambda: not state()['stack'], timeout=5, step=.05)
        toast = app.call('toasts')['toasts']
        undo = app.call('toast-action', index=0)
        results['peek_click_outside_undo'] = {'ok': bool(dismissed) and any(t['title'] == 'Peek closed' for t in toast) and undo and bool(opened())}
        clear()
        # A real link click in each nested page; the sixth target navigates in place.
        app.call('peek-open', tab=source, url=url('n0.localhost'))
        opened(); depths=[]; native_nesting=True
        for i in range(1, 6):
            page = top(); app.call('wait', tab=page)
            click(page, url('n%d.localhost' % i))
            wait_until(lambda: len(state()['stack']) == min(i+1, 5), timeout=5, step=.05)
            actual_depth=len(state()['stack']); native_nesting &= actual_depth == min(i+1,5)
            depths.append(len(state()['stack']))
        at_cap = wait_until(lambda: app.eval(top(), 'location.hostname') == 'n5.localhost', timeout=8, step=.05)
        stack=state()['stack']; ui=app.call('peek-ui'); pages={p['identifier']:p for p in app.call('pages')}
        results['peek_nested_visibility']={'ok':len(stack)==5 and stack[-1]['originalHostTab'] in ui['visible']
            and all(item['originalHostTab'] not in ui['visible'] and pages[item['content']]['hidden'] for item in stack[:-1]),
            'visible':ui['visible'],'stackHosts':[item['originalHostTab'] for item in stack]}
        app.call('key', key='escape', route='app')
        popped = wait_until(lambda: len(state()['stack']) == 4, timeout=5, step=.05)
        results['peek_nesting_cap'] = {'ok': native_nesting and depths == [2,3,4,5,5] and bool(at_cap) and bool(popped), 'depths': depths}
        clear()
        # Source becomes a split while its Peek is open. The Peek follows the source row.
        app.call('select', tab=source)
        app.call('peek-open', tab=source, url=url('b.localhost'))
        opened()
        other = new_tab(app, url('c.localhost'))
        hidden=app.call('peek-ui')
        results['peek_source_selection_hides']={'ok':not hidden['shown'] and hidden['hostHidden'] and source in hidden['badges']
            and all(item['originalHostTab'] not in hidden['visible'] for item in state()['stack']), 'ui':hidden}
        app.call('select', tab=source)
        app.call('split', tabs=[source, other])
        ui = app.call('peek-ui')
        source_split = ui['sourceRow']
        results['peek_follows_source_split'] = {'ok': ui['shown'] and ui['sourceRow'] != source and source in ui['badges'], 'ui': ui}
        clear()
        app.call('command', id='expand-current-split')
        maximized = app.call('peek-ui')['maximized']
        # Top Peek has priority over a maximized split, through View > Exit and real App Esc.
        app.call('peek-open', tab=source, url=url('b.localhost')); opened()
        enabled = menu('exit-modal').get('enabled')
        try: performed = app.call('menu-perform', id='exit-modal')
        except RuntimeError: performed = False
        closed = wait_until(lambda: not state()['stack'], timeout=3, step=.05) if performed else False
        still_max = app.call('peek-ui')['maximized']
        if performed: app.call('key', key='escape', route='app')
        restored = not app.call('peek-ui')['maximized']
        results['peek_exit_modal_menu_priority'] = {'ok': enabled and performed and bool(closed) and bool(maximized) and still_max == maximized and restored,
            'enabled': enabled, 'performed': performed, 'restored': restored}
        clear()
        if app.call('peek-ui')['maximized']: app.call('key', key='escape', route='app')
        app.call('peek-open', tab=source, url=url('b.localhost')); opened()
        app.call('key', key='escape', route='app')
        closed = wait_until(lambda: not state()['stack'], timeout=5, step=.05)
        results['peek_exit_modal_app_escape'] = {'ok': bool(closed) and any(t['title']=='Peek closed' for t in app.call('toasts')['toasts'])}
        clear()
        if app.call('peek-ui')['maximized']: app.call('command',id='expand-current-split')
        # Plain Esc must reach the page while Exit is disabled.
        app.call('focus', tab=source)
        app.eval(source, "window.escapeCount=0; document.addEventListener('keydown', e => {if(e.key==='Escape') window.escapeCount++}); true")
        disabled = menu('exit-modal').get('enabled') is False
        app.call('key', key='escape', route='app')
        reached = wait_until(lambda: app.eval(source, 'window.escapeCount') == 1, timeout=3, step=.05)
        results['peek_escape_without_surface_reaches_page'] = {'ok': disabled and bool(reached), 'exitDisabled': disabled}
        # Third button adds a pane beside the source. Preserve the page in Alloy style.
        app.call('peek-open', tab=source, url=url('b.localhost')); opened(); page=top(); app.call('wait', tab=page)
        app.eval(page, 'window.peekSplitState=91')
        transient=state()['stack'][-1]['originalHostTab']
        app.call('peek-button', id='openInSplit')
        split_closed = wait_until(lambda: not state()['stack'], timeout=5, step=.05)
        new = next(t['id'] for t in app.call('tabs') if t['selected'])
        app.call('wait',tab=new)
        alloy=app.page(source)['style']=='alloy'
        tree=app.call('sidebar-tree')
        source_row=next((n for n in tree['pinned']+tree['today'] if n.get('id')==source_split),{})
        members=[n['id'] for n in source_row.get('children',[])]
        results['peek_split_beside_source'] = {'ok': bool(split_closed) and source in members and new in members and new != source
            and app.eval(new,'location.hostname')=='b.localhost' and (app.eval(new,'window.peekSplitState')==91 if alloy else app.page(new)['style']=='chrome'),
            'promoted':new,'members':members,'sameLiveState':alloy}

        visible=app.call('peek-ui')['visible']
        results['peek_visibility_split']={'ok':transient not in visible and new in visible and source in visible, 'visible':visible}
        # Cmd+O opens the real Space picker, whose real menu action chooses Today top.
        for choose_current in (True, False):
            select_source()
            spaces=app.call('spaces'); current=next(s['id'] for s in spaces if s['focused'])
            target=current if choose_current else app.call('space-create', title='Peek target')
            app.call('space', space=current)
            app.call('peek-open', tab=source, url=url('b.localhost')); opened()
            app.call('peek-move-arm', space=target)
            app.call('key', key='o', modifiers=['command'], route='app')
            moved=wait_until(lambda: not state()['stack'], timeout=5, step=.05)
            chosen=app.call('peek-move-state'); tab=next(t for t in app.call('tabs') if t['selected'])
            tree=app.call('sidebar-tree')
            results['peek_cmd_o_' + ('current' if choose_current else 'chosen')] = {'ok': bool(moved) and chosen.get('tracked') and chosen.get('chosen')
                and app.call('window-state')['space'] == target and tree['today'][0]['id'] == tab['id'], 'menu': chosen, 'tab': tab['id'], 'tree': tree}
        select_source()
        app.call('peek-open', tab=source, url=url('b.localhost', 'ticker.html')); opened(); page=top(); app.call('wait', tab=page)
        app.call('sleep-start')
        app.call('sleep-clock', advance=31.0); app.call('sleep-tick')
        ui=app.call('peek-ui'); transient=state()['stack'][-1]['originalHostTab']
        before=app.eval(page, "Number(document.querySelector('#ticks').textContent)")
        progressed=wait_until(lambda: app.eval(page, "Number(document.querySelector('#ticks').textContent)") > before, timeout=4, step=.15)
        page_visible=app.eval(page, 'document.visibilityState')
        freeze=app.call('engine-sleep',tab=page,op='freeze')
        source_gate=app.call('sleep-state',tab=source)['tabs'][0]['freezeGate']
        results['peek_visibility_ticker'] = {'ok': transient in ui['visible'] and source in ui['visible'] and not ui['hostHidden']
            and page_visible=='visible' and source_gate=='visible' and bool(progressed) and freeze.get('ok') is False and not freeze['frozen'], 'ui': ui, 'pageVisibility': page_visible,
            'sourceGate': source_gate, 'freeze':freeze, 'pastFreezeDelay':31, 'ticksBefore':before, 'load':os.getloadavg()}
        close()
        results['peek_visibility_dismissed'] = {'ok': transient not in app.call('peek-ui')['visible'] and source in app.call('peek-ui')['visible']}
        app.call('peek-open',tab=source,url=url('b.localhost')); opened(); transient=state()['stack'][-1]['originalHostTab']
        app.call('peek-button',id='openInSpaceExpander')
        wait_until(lambda: not state()['stack'],timeout=5,step=.05)
        selected=next(t['id'] for t in app.call('tabs') if t['selected']); visible=app.call('peek-ui')['visible']
        results['peek_visibility_expanded']={'ok':transient not in visible and selected in visible, 'visible':visible}
        results['peek_email_disabled']={'ok':menu('peek-email').get('enabled') is False}
        # History swipe events use the same Open indicator as a pane, with the engine arrow off.
        select_source()
        app.call('peek-open',tab=source,url=url('b.localhost','a.html')); opened(); page=top(); app.call('wait',tab=page)
        navigate(page,url('b.localhost','b.html'))
        app.call('events')
        back=app.call('swipe',tab=page,direction='back',progress=1.2)
        at_a=wait_until(lambda:app.eval(page,'location.pathname')=='/a.html',timeout=8,step=.05)
        events=[e for e in app.call('events') if e['type']=='historySwipe']
        gone=wait_until(lambda:app.call('swipe-indicator',tab=page).get('hidden'),timeout=3,step=.05)
        results['peek_swipe_indicator']={'ok':back['ran'] and not back['engineOverlay'] and bool(at_a) and bool(gone)
            and back['indicator'].get('made') and events and all(e.get('indicator') for e in events), 'swipe':back,'events':events}
        clear()
        # Q5: Alloy keeps the same live page. Chrome uses the history/scroll/form fallback.
        select_source()
        app.call('peek-open',tab=source,url=url('b.localhost','a.html')); opened(); page=top(); app.call('wait',tab=page)
        navigate(page,url('b.localhost','c.html'))
        app.eval(page,"window.peekPromotion=73; document.querySelector('#q').value='peek-kept'; scrollTo(0,innerHeight*2); true")
        y=app.eval(page,'scrollY'); time.sleep(6)  # Chromium saves a live document's PageState.
        history=app.call('engine-sleep',tab=page,op='capture')
        alloy=app.page(source)['style']=='alloy'
        app.call('peek-button',id='openInSpaceExpander')
        promoted=wait_until(lambda:next((t['id'] for t in app.call('tabs') if t['selected'] and t['id']!=source),None)
            if not state()['stack'] else None,timeout=8,step=.05)
        app.call('wait',tab=promoted)
        preserved=wait_until(lambda:app.eval(promoted,"({q:document.querySelector('#q')?.value,y:scrollY,path:location.pathname,n:history.length})")
            if app.eval(promoted,"document.querySelector('#q')?.value")=='peek-kept' else None,timeout=5,step=.1)
        same=app.page(promoted)['identifier']==page
        results['peek_expand_page_state']={'ok':bool(preserved) and abs(preserved['y']-y)<=1 and preserved['path']=='/c.html'
            and app.page(promoted)['canGoBack'] and (same and app.eval(promoted,'window.peekPromotion')==73 if alloy else not same),
            'sameHost':same,'savedHistory':history,'restored':preserved,'scrollBefore':y,'style':'alloy' if alloy else 'chrome'}
    finally:
        try:
            for key,value in saved.items(): app.call('defaults',key=key,value=value)
        finally:
            try: app.quit()
            finally:
                server.shutdown(); server.server_close()

    find_escape_checks(factory,results,tmp,harness)


def find_escape_checks(factory, results, tmp, harness):
    """Find keeps first refusal before Peek or split restoration (Section 11 contract)."""
    app=factory(urls=(),fresh=True)
    wait_until=harness['wait_until']
    try:
        source=harness['new_tab'](app,harness['fixture']('Find source'))
        for route in ('app','menu'):
            app.call('peek-open',tab=source,url=harness['fixture']('Find in Peek'))
            wait_until(lambda:app.call('peek-state')['shown'] and app.call('peek-state')['stack'][-1]['content']>0,timeout=5,step=.05)
            before=app.call('peek-state')['stack'][-1]['content']
            app.call('key',key='f',modifiers=['command'],route='app')
            shown=wait_until(lambda:app.call('focus-state')['findVisible'],timeout=3,step=.05)
            if route=='app': app.call('key',key='escape',route='app')
            else: app.call('menu-perform',id='exit-modal')
            closed=wait_until(lambda:not app.call('focus-state')['findVisible'],timeout=3,step=.05)
            stack=app.call('peek-state')['stack']
            results['peek_find_first_'+route]={'ok':bool(shown) and bool(closed) and len(stack)==1 and stack[-1]['content']==before,
                'findShown':bool(shown),'findClosed':bool(closed),'peekDepth':len(stack)}
            app.call('peek-close')
            # Also clean the old-code negative case, where Peek was dismissed first.
            if app.call('focus-state')['findVisible']:
                app.call('key',key='f',modifiers=['command'],route='app')
                app.call('key',key='escape',route='app')
        app.call('key',key='f',modifiers=['command'],route='app')
        shown=wait_until(lambda:app.call('focus-state')['findVisible'],timeout=3,step=.05)
        app.call('key',key='escape',route='app')
        closed=wait_until(lambda:not app.call('focus-state')['findVisible'],timeout=3,step=.05)
        results['peek_window_find_first']={'ok':bool(shown) and bool(closed) and not app.call('peek-state')['stack']}
        app.call('split')
        app.call('command',id='expand-current-split')
        maximized=app.call('peek-ui')['maximized']
        app.call('key',key='f',modifiers=['command'],route='app')
        shown=wait_until(lambda:app.call('focus-state')['findVisible'],timeout=3,step=.05)
        app.call('key',key='escape',route='app')
        closed=wait_until(lambda:not app.call('focus-state')['findVisible'],timeout=3,step=.05)
        retained=app.call('peek-ui')['maximized']==maximized
        app.call('key',key='escape',route='app')
        results['peek_split_find_first']={'ok':bool(maximized) and bool(shown) and bool(closed) and retained and not app.call('peek-ui')['maximized']}

    finally:
        app.quit()
