#!/usr/bin/env python3
"""Real-App G2 section migration and frames. Socket input only; no system panels."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import tempfile
import time
from engine_e2e import Open


def run(bundle, out, expected_scale=None, perf=False):
    out.mkdir(parents=True, exist_ok=True)
    data = tempfile.mkdtemp(prefix='open-g2-')
    app = Open('Debug', 'alloy', data, [], str(out/'app.log'), extra_env={'OPEN_E2E_APP_BUNDLE': str(bundle)})
    results, frames, saved = {}, [], {}

    def ui(**args):
        return app.call('settings-ui', **args)

    def settle():
        time.sleep(.2)
        return ui()

    def check(name, condition, **evidence):
        results[name] = dict(ok=bool(condition), **evidence)
        print(name + (' PASS' if condition else ' FAIL'), flush=True)
        if not condition:
            capture('failure')
        assert condition, name

    def node(label=None, role=None, identifier=None):
        s = settle()
        nodes = [c for c in s['controls'] if (label is None or c['label'] == label)
                 and (role is None or c['role'] == role) and (identifier is None or c['id'] == identifier)
                 and c['frame'][2] > 0 and c['frame'][3] > 0]
        if not nodes:
            capture('missing-control')
        assert nodes, 'missing '+str(label or identifier)
        return nodes[-1]

    def click(label=None, role=None, identifier=None):
        c = node(label, role, identifier)
        x,y,w,h = c['frame']
        app.call('mouse', action='click', queued=True, window=c['window'], x=x+w/2, y=y+h/2)
        return settle()

    def key(name=None, modifiers=None, text=None, window=None):
        args = dict(window=window or ui()['window'], route='app')
        if name is not None: args['key'] = name
        if modifiers is not None: args['modifiers'] = modifiers
        if text is not None: args['text'] = text
        return app.call('key', **args)

    def type_field(label, text):
        c = node(label=label, role='AXTextField')
        x,y,w,h = c['frame']
        app.call('mouse', action='click', queued=True, window=c['window'], x=x+w/2, y=y+h/2)
        key('a', ['cmd'], window=c['window']); key('delete', window=c['window'])
        key(text=text, window=c['window']); settle()

    def search(text):
        key('f', ['cmd']); key('a', ['cmd']); key('delete'); key(text=text)
        return settle()

    def link(path):
        ui(action='link', url='open://settings/'+path)
        return settle()

    def snapshot():
        return json.loads((Path(data)/'State/browser.json').read_text())

    def saved_snapshot_matches(predicate):
        # The real SnapshotStore intentionally debounces writes for one second.
        for _ in range(60):
            if predicate(snapshot()):return True
            time.sleep(.1)
        return False

    def capture(name, sheet=False, presentation=None):
        s=settle(); window=s['sheet'] if sheet else s['window']
        assert window, 'missing window for '+name
        receipt=app.call('snapshot', window=window, path=str(out/(name+'.png')))
        (out/(name+'.json')).write_text(json.dumps(s, indent=2))
        frames.append(dict(name=name, file=name+'.png', scale=s['scale'], screen=s['screen'], display=s.get('display'), size=s['size'], snapshot=receipt, presentationFixture=presentation))

    sections=['general','appearance','tabs-archive','search','links','downloads','previews','ad-blocking','site-permissions','passwords-cards','browsing-data','profiles','shortcuts','extensions','advanced']
    defaults_rows=[
        ('general/restore-windows','Restore windows from the previous session','open.advanced.restoreWindowsOnLaunch'),
        ('general/warn-before-quitting','Warn before quitting','open.general.warnBeforeQuitting'),
        ('general/automatic-updates','Update Open automatically','open.general.automaticallyUpdate'),
        ('tabs-archive/include-favorites','Include Favorites in tab numbering','open.shortcuts.includeFavoritesInTabNumbering'),
        ('tabs-archive/ninth-tab','Switch to ninth tab','open.shortcuts.switchToNinthEnabled'),
        ('previews/enabled','Show Open Previews','open.general.previewsEnabled'),
        ('previews/folders','Folders','open.general.previewsFolders'),
        ('previews/pages','Pinned tabs and Favorites','open.general.previewsPages'),
        ('links/little-open-hotkey','Open Little Open in any app','open.links.littleOpenHotkeyEnabled'),
        ('links/option-command-click','Open Little Open with Option-Command-click','open.links.optionCommandClickLittleOpen'),
        ('links/external-links','Links from other apps open in Little Open','open.links.externalInLittleOpen'),
        ('links/peek-shift-click','Open Peek with Shift-click','open.links.openPeekShiftClick'),
        ('links/peek-other-sites','Open Peek for links to other sites','open.links.openPeekOtherSites'),
        ('advanced/sound','Play Open sound effects','open.advanced.playSoundEffects'),
        ('advanced/haptics','Haptic feedback when reordering tabs','open.advanced.hapticOnTabReorder'),
        ('advanced/window-dragging','Allow window dragging from the top of webpages','open.advanced.allowWindowDraggingFromWebTop'),
        ('advanced/shared-quotes','Enable Shared Quotes when highlighting text','open.advanced.enableSharedQuotes'),
        ('advanced/picture-in-picture','Enable Picture in Picture when you leave a video tab','open.advanced.enablePictureInPictureOnLeave'),
        ('advanced/theme-data','Allow websites to get your theme data','open.advanced.allowSitesThemeData'),
        ('advanced/boosts','Enable Boosts on websites you visit','open.advanced.enableBoosts')]
    try:
        keys={r[2] for r in defaults_rows} | {'open.settings.lastPane','open.settings.lastSection','open.general.searchSuggestNoticeDismissed','open.import.lastArcDir','open.advanced.tabSleepMode','open.shortcuts.defaultPriority','open.web.colorScheme','open.appIcon.selectedID','open.advanced.showFullURLWithToolbar'}
        saved={k:app.call('defaults',key=k,persistent=True) for k in keys}
        app.call('defaults',key='open.general.searchSuggestNoticeDismissed',value=True)
        app.call('defaults',key='open.general.previewsEnabled',value=True)
        app.call('defaults',key='open.import.lastArcDir',value=str(Path(data)/'import-source'))
        app.call('appearance',name='light');app.call('menu-perform',id='settings');settle()
        ui(action='resize',width=960,height=660)
        display=settle()['display'];results['display']=display
        check('display_key',expected_scale is None or display['scale']==expected_scale,display=display)
        if expected_scale==1:check('m5_display_mode',display['name']=='AW2726DM' and display['pixels']==[2560,1440] and abs(display['modeHz']-240)<.1,display=display)
        for path,label,keyname in defaults_rows:
            link(path)
            before=app.call('defaults',key=keyname)
            click(label,role='AXCheckBox')
            after=app.call('defaults',key=keyname)
            check('store_'+path,after is (not before),before=before,after=after)
            click(label,role='AXCheckBox')
        link('tabs-archive/sleep');ui(action='choice',label='Sleep inactive tabs',title='Conservative');settle()
        check('sleep_store',app.call('defaults',key='open.advanced.tabSleepMode')=='conservative')
        ui(action='choice',label='Sleep inactive tabs',title='Automatic')
        link('tabs-archive/archive-after');ui(action='choice',label='Archive tabs after',title='24 hours');settle()
        check('archive_profile_store',ui()['profileSettings']['archive']=='twentyFourHours')
        ui(action='choice',label='Archive tabs after',title='12 hours');settle()
        link('tabs-archive/little-open-archive');ui(action='choice',label='Archive Little Open windows after',title='1 hour');settle()
        check('little_archive_profile_store',ui()['profileSettings']['littleArchive']=='oneHour')
        ui(action='choice',label='Archive Little Open windows after',title='6 hours')
        link('search/engine');ui(action='choice',label='Search engine',title='DuckDuckGo');settle()
        check('engine_profile_store',ui()['profileSettings']['engine']=='duckduckgo')
        ui(action='choice',label='Search engine',title='Google')
        click('Include search engine suggestions',role='AXCheckBox')
        check('suggestions_profile_store',ui()['profileSettings']['suggestions'] is False)
        click('Include search engine suggestions',role='AXCheckBox')
        link('downloads/ask');click('Ask where to save each file',role='AXCheckBox')
        check('download_profile_store',ui()['profileSettings']['ask'] is True)
        click('Ask where to save each file',role='AXCheckBox')
        # A second Profile proves that the pill edits independent model settings.
        first=ui()['profile'];link('profiles/manage');click('Create Profile…')
        click('Create Profile');check('create_empty_name_guard',ui()['sheet']!=0 and bool(app.call('profiles-shell')['error']))
        type_field('Profile name','Review Profile');click('Create Profile');settle()
        second=ui()['profile'];link('search/engine');ui(action='choice',label='Search engine',title='Bing');settle()
        check('create_profile_saved',second!=first and saved_snapshot_matches(lambda s:any(p['name']=='Review Profile' for p in s['profiles'])))
        app.call('profiles-shell',profile=first)
        check('profile_pill_isolation',ui()['profileSettings']['engine']=='google' and second!=first)
        ui(action='choice',label='Profile',title='Review Profile');settle()
        check('profile_pill_roundtrip',ui()['profileSettings']['engine']=='bing')
        ui(action='choice',label='Search engine',title='Google')
        link('profiles/name');click('Rename');type_field('Profile name','Renamed Profile');click('Save')
        check('rename_profile_saved',saved_snapshot_matches(lambda s:any(p['name']=='Renamed Profile' for p in s['profiles'])))
        click('Rename');type_field('Profile name','Review Profile');click('Save')
        # Validate external delegate delivery, invalid URL guard and existing commands.
        ui(action='external-link',url='open://settings/downloads/ask');settle()
        check('external_settings_delivery',ui()['section']=='downloads' and ui()['arrival']=='downloads/ask')
        ui(action='external-link',url='open://settings/unknown/row');settle()
        check('invalid_external_link_guard',ui()['section']=='downloads')
        app.call('command',id='search-settings');settle();check('search_command_destination',ui()['section']=='search')
        app.call('command',id='air-traffic-control');settle();check('routing_command_destination',ui()['arrival']=='links/rules')
        previous=ui()['arrivalRevision'];app.call('command',id='air-traffic-control');settle()
        check('repeated_link_arrival',ui()['arrivalRevision']>previous)
        # Existing command-bar providers and ranking dispatch the same stable URL.
        browser = app.call('window-state')
        app.call('window-focus', id=browser['id'], activate=True)
        key('t', ['cmd'], window=browser['number']); key('a', ['cmd'], window=browser['number'])
        key(text='Settings: Include Favorites', window=browser['number']); time.sleep(.3)
        bar=app.call('commandbar-state')
        row_index=next((i for i,r in enumerate(bar.get('rows',[])) if r.get('action')=='settings-link:tabs-archive/include-favorites'),None)
        check('commandbar_settings_provider',row_index is not None,rows=bar.get('rows'))
        current=bar['selected']
        for _ in range(abs(row_index-current)):
            key('down' if row_index>current else 'up',window=browser['number'])
        key('return',window=browser['number']);settle()
        check('commandbar_settings_deep_link',ui()['arrival']=='tabs-archive/include-favorites')
        # Recording, invalid bare key, a real saved binding, conflict and rollback.
        link('shortcuts/search-actions');click('Record shortcut for Search Actions')
        key(text='q');settle();check('record_bare_key_guard',ui()['recording']=='search-actions')
        key('escape');settle();check('record_escape',ui()['recording']=='')
        click('Record shortcut for Search Actions');key('j',['cmd','shift','control','option']);settle()
        binding=Path(ui()['keybindingsFile']);saved_hash=hashlib.sha256(binding.read_bytes()).hexdigest()
        check('shortcut_saved_store','search-actions' in ui()['bindings'])
        link('shortcuts/new-tab');click('Record shortcut for New Tab…');key('j',['cmd','shift','control','option']);settle()
        check('shortcut_conflict_guard',ui()['conflicts']>0 and hashlib.sha256(binding.read_bytes()).hexdigest()==saved_hash)
        ui(action='filter',filter='conflicts');capture('shortcuts-conflict-light')
        ui(action='revert');ui(action='filter',filter='all');settle()
        check('shortcut_revert',ui()['conflicts']==0)
        # Restoring the shipping default also exercises the retained destructive sheet.
        click('Reset All Shortcuts');capture('reset-shortcuts-light',sheet=True);click('Reset All Shortcuts',role='AXButton')
        settle();check('shortcut_reset_all',not ui()['bindings'])
        # Real link validation and rule editor; no file/application chooser is opened.
        link('links/destination');ui(action='choice',label='Destination',title='Most Recent Space')
        changed=search('is:changed');check('routing_changed_scope',any(r['id']=='links/destination' for r in changed['results']))
        key('escape');link('links/destination')
        c=node(identifier='links/destination');x,y,w,h=c['frame'];app.call('mouse',action='hover',window=c['window'],x=x+w/2,y=y+h/2)
        click('Reset Default destination');check('routing_reset_shipping_default','littleOpen' in json.dumps(snapshot()['defaultDestination']))
        link('links/test');type_field('URL or host','not a url');click('Test');capture('link-test-error-light')
        link('links/rules');click('Add Rule…');capture('link-rule-light',sheet=True)
        click('Cancel');settle()
        click('Add Rule…');type_field('Pattern','g2-review.example');click('Save Rule')
        check('routing_rule_saved',not ui()['sheet'] and 'g2-review.example' in json.dumps(snapshot()['routingRules']))
        capture('routing-rule-saved-light');click('Delete rule g2-review.example')
        check('routing_rule_deleted','g2-review.example' not in json.dumps(snapshot()['routingRules']))
        link('search/engines');click('Manage…');click('Add')
        type_field('Engine name','Review Search');type_field('Engine keyword','review-search');type_field('Engine URL','https://example.com/?q=%s')
        click('Save Engine');click('Done')
        check('custom_engine_saved',saved_snapshot_matches(lambda s:'Review Search' in json.dumps(s['profiles'])))
        ui(action='choice',label='Search engine',title='Review Search')
        check('custom_engine_selected',ui()['profileSettings']['engine']!='google')
        click('Manage…');click('Restore Built-ins');click('Done')
        check('custom_engines_restored',saved_snapshot_matches(lambda s:'Review Search' not in json.dumps(s['profiles'])))
        link('ad-blocking/enabled')
        for _ in range(100):
            if app.call('settings-adblock')['ready']:break
            time.sleep(.1)
        before=app.call('settings-adblock')['enabled'];click('Block ads, trackers, and popups',role='AXCheckBox')
        check('adblock_master_store',app.call('settings-adblock')['enabled'] is not before)
        click('Block ads, trackers, and popups',role='AXCheckBox')
        type_field('Search block lists','EasyList');app.call('profiles-shell',action='press',label='Generic');settle()
        capture('adblock-list-expanded-light')
        candidate=next(c for c in ui()['controls'] if c['role']=='AXCheckBox' and c['label']!='Block ads, trackers, and popups')
        before_lists=app.call('settings-adblock')['lists'];click(candidate['label'],role='AXCheckBox')
        for _ in range(100):
            after_lists=app.call('settings-adblock')['lists']
            if after_lists!=before_lists:break
            time.sleep(.1)
        check('adblock_list_store',after_lists!=before_lists)
        click(candidate['label'],role='AXCheckBox');settle();capture('adblock-list-expanded-light')
        check('adblock_list_restored',app.call('settings-adblock')['lists']==before_lists)
        app.call('profiles-shell',action='press',label='Generic');type_field('Search block lists','')
        link('ad-blocking/allowed-sites');type_field('Allowed site','invalid /host');click('Add Site')
        check('allowed_site_invalid_guard',bool(app.call('profiles-shell')['adblockError']) and not app.call('profiles-shell')['adblockDomains'])
        capture('adblock-invalid-site-light');type_field('Allowed site','review.example.com');click('Add Site')
        check('allowed_site_saved','example.com' in app.call('profiles-shell')['adblockDomains'])
        click('Remove');check('allowed_site_removed',not app.call('profiles-shell')['adblockDomains'])
        # All fifteen sections, both appearances, plus the retained sheets.
        for mode in ['light','dark']:
            app.call('appearance',name=mode)
            app.call('profiles-shell',profile=first)
            for section in sections:
                ui(action='open',section=section);settle()
                check('section_'+section+'_'+mode,ui()['section']==section and not any('being prepared' in c['label'] for c in ui()['controls']))
                if section=='general':
                    capture('general-system-default-'+mode)
                    default_state=app.call('default-browser-state')
                    ui(action='default-browser-presentation',isDefault=False)
                    capture(section+'-'+mode,presentation='Non-default browser hero; view state only, system default unchanged')
                    check('hero_did_not_change_system_'+mode,app.call('default-browser-state')==default_state)
                else:capture(section+'-'+mode)
            link('general/import');click('Import…');time.sleep(.5);capture('import-empty-'+mode,sheet=True);click('Cancel')
            link('search/suggestions')
            app.call('defaults',key='open.general.searchSuggestNoticeDismissed',value=False)
            click('Include search engine suggestions',role='AXCheckBox');click('Include search engine suggestions',role='AXCheckBox')
            check('suggest_notice_guard_'+mode,ui()['suggestNotice'] and not ui()['allowsRemoteSuggestions'])
            capture('suggestions-notice-'+mode,sheet=True);click('Got it')
            link('search/engines');click('Manage…');capture('search-engines-'+mode,sheet=True);click('Add');capture('search-engine-editor-'+mode,sheet=True);click('Done')
            link('browsing-data/clear');click('Choose Data…');capture('clear-data-'+mode,sheet=True)
            if mode=='light':
                click('Clear Data')
                for _ in range(100):
                    if ui()['clearStatus']=='Done':break
                    time.sleep(.1)
                check('clear_data_real_flow',ui()['clearStatus']=='Done')
                click('Done')
            else:click('Cancel')
            link('profiles/manage');click('Create Profile…');capture('create-profile-'+mode,sheet=True);click('Cancel')
            app.call('profiles-shell',profile=second);link('profiles/delete');click('Delete…');capture('delete-profile-'+mode,sheet=True)
            check('delete_confirmation_guard_'+mode,app.call('profiles-shell')['deleteEnabled'] is False)
            click('Cancel')
            link('links/rules');click('Add Rule…');capture('link-rule-'+mode,sheet=True);click('Cancel')
            link('shortcuts');click('Reset All Shortcuts');capture('reset-shortcuts-'+mode,sheet=True);click('Cancel')
            search('archive');capture('search-results-'+mode)
            entry=next(r for r in ui()['results'] if r['label']=='View Archive')
            c=node(identifier='settings-result-'+entry['id']);x,y,w,h=c['frame']
            app.call('mouse',action='hover',window=c['window'],x=x+w/2,y=y+h/2)
            capture('search-unassigned-hover-'+mode);key('escape');settle()
            ui(action='resize',width=800,height=540);ui(action='open',section='general');ui(action='default-browser-presentation',isDefault=False);capture('general-minimum-'+mode,presentation='Non-default browser hero; view state only, system default unchanged')
            ui(action='open',section='shortcuts');capture('shortcuts-minimum-'+mode);ui(action='resize',width=960,height=660)
        # A real destructive Profile flow runs against the owned fixture only.
        app.call('profiles-shell',profile=second);link('profiles/delete');click('Delete…')
        app.call('profiles-shell',action='type-delete',text='wrong')
        check('delete_wrong_name_guard',app.call('profiles-shell')['deleteEnabled'] is False)
        app.call('profiles-shell',action='type-delete',text='Review Profile')
        check('delete_exact_name_guard',app.call('profiles-shell')['deleteEnabled'] is True)
        click('Delete')
        for _ in range(50):
            if not any(p['id']==second for p in app.call('profiles-shell')['profiles']):break
            time.sleep(.1)
        check('delete_profile_real_flow',not any(p['id']==second for p in app.call('profiles-shell')['profiles']))
        ui(action='reduce-motion',enabled=True);ui(action='open',section='appearance');settle()
        check('reduce_motion_section',ui()['reduceMotion'] and ui()['section']=='appearance')
        capture('appearance-reduce-motion-dark');ui(action='reduce-motion',enabled=None)
        search('zz-no-setting-zz');capture('search-empty-dark');check('empty_search',not ui()['results']);key('escape')
        if perf:
            ui(action='open',section='general');settle()
            for mode in ['sections','scroll']:
                app.call('settings-perf',action=mode)
                for _ in range(60):
                    time.sleep(.5);measurement=app.call('settings-perf')
                    if not measurement['running']:break
                results['perf_'+mode]=measurement
                (out/('perf-'+mode+'.json')).write_text(json.dumps(measurement,indent=2))
                check('perf_'+mode+'_completed',not measurement['running'] and measurement['missingDraws']==0, missingDraws=measurement['missingDraws'],samples=len(measurement['sections']),frames=measurement['frames'])
        results['load']=list(os.getloadavg())
        results['binarySHA256']=hashlib.sha256((bundle/'Contents/MacOS/Open').read_bytes()).hexdigest()
    finally:
        for k,v in saved.items():
            try:app.call('defaults',key=k,value=v)
            except Exception:pass
        (out/'results.json').write_text(json.dumps(dict(results=results,frames=frames),indent=2))
        app.quit()
    return results

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--bundle',type=Path,required=True);parser.add_argument('--out',type=Path,required=True);parser.add_argument('--expected-scale',type=int);parser.add_argument('--perf',action='store_true')
    args=parser.parse_args();run(args.bundle.resolve(),args.out.resolve(),args.expected_scale,args.perf)
