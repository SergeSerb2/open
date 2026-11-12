#!/usr/bin/env python3
"""L2: real stores, engine transfers and native Library controls via socket."""
import argparse
import json
import os
from pathlib import Path
import struct
import sqlite3
import subprocess
import tempfile
import time
from engine_e2e import Open, wait_until, new_tab
from boost_gallery import fixture as boost_fixture
from downloads import server
from library_overlay import capture_window


def run(output,bundle=None,frames=False,mockups=None,config='Debug'):
    output.mkdir(parents=True,exist_ok=True)
    result = {'checks':{},'frames':[],'configuration':config+'; functional evidence, no timing qualification'}
    app = None
    saved = {}
    def check(name,ok,**evidence):
        result['checks'][name] = dict(ok=bool(ok),**evidence)
        print(('PASS ' if ok else 'FAIL ')+name,flush=True)
        if not ok: raise AssertionError(name+': '+repr(evidence))
    def state(**kw): return app.call('library',**kw)
    def key(name,mods=()): return app.call('key',key=name,modifiers=list(mods),route='app')
    def wait(fn): return wait_until(fn,timeout=8,step=.05)
    def rows(): return state().get('rows',[])
    def row(id): return next((r for r in rows() if r['id']==id),None)
    def menu(id,select=None): return state(action='row-menu',id=id,**({'select':select} if select else {}))['items']
    def capture(name,**extra):
        if not frames: return
        app.call('window-focus',id=owner,activate=True)
        current=state(); current.update(extra); check(name+'_key',current['key'])
        path=output/(name+'.png')
        capture_window(current['window'],path)
        size=struct.unpack('>II',path.read_bytes()[16:24]); frame=app.call('window-state')['frame']
        check(name+'_2x',size==(int(frame[2]*2),int(frame[3]*2)),pixels=size)
        result['frames'].append(dict(name=name,path=path.name,state=current))
        (output/(name+'.json')).write_text(json.dumps(current,indent=2))
    with tempfile.TemporaryDirectory(prefix='open-library-l2-') as data,server() as base,boost_fixture(data) as switches:
        try:
            app=Open(config,'chrome',data,switches,str(output/'app.log'),urls=(base+'/',),extra_env={'OPEN_E2E_APP_BUNDLE':str(bundle)} if bundle else {})
            for name,value in [('libraryShowsEasels',False),('open.sidebar.hideHintShown',True),('open.advanced.enableBoosts',True),('open.boosts.hasDismissedInterstitial',True),('open.boosts.hasDismissedJSNotice',True)]:
                saved[name]=app.call('defaults',key=name,persistent=True);app.call('defaults',key=name,value=value)
            owner=app.call('shell-windows')[0]['id'];tab=app.call('tabs')[0]['id'];app.call('wait',tab=tab)
            space=next(s for s in app.call('spaces') if s['focused']);profile=space['profile']
            # Keep the exact viewport, with its right edge on a real screen.
            # The rented display is 1280 points wide; x=40 put that edge offscreen
            # and prevented the native Boost editor from choosing its screen.
            sx,sy,sw,sh=app.call('window-state')['screenFrame']
            app.call('window-frame',frame=[min(40,sx+sw-1280),min(50,sy+sh-800),1280,800],unconstrained=True)
            app.call('window-focus',id=owner,activate=True)
            state(action='open',section='media')
            # Folder sources exist (PB1): before Choose Folders, Media shows the first-use card with a live button.
            check('media_truthful_empty',wait(lambda:state().get('emptyVisible')) and state()['emptyState']['title']=='Show your media here' and state()['emptyState']['buttonVisible'] and state()['emptyState']['buttonEnabled'],state=state()['emptyState'])
            index_file=Path(data)/'State/captures.json';index_file.parent.mkdir(exist_ok=True)
            index_file.write_text('broken capture index');state(action='select',section='media')
            check('media_corrupt_index_error',wait(lambda:state()['emptyState']['title']=='Could not load media'))
            index_file.unlink();state(action='select',section='media')
            check('media_missing_index_recovers',wait(lambda:state()['emptyState']['title']=='Show your media here'))
            # Reopen cancels the old release; the next close releases the actual view.
            state(action='release-delay',seconds=.6);generation=state()['panelGeneration'];state(action='close');time.sleep(.3)
            state(action='open',section='media');time.sleep(.4)
            check('reopen_cancels_release',state()['panelCreated'] and state()['panelGeneration']==generation)
            state(action='close');check('closed_view_released',wait(lambda:not state().get('panelCreated',True)) and not state().get('releasedPanelAlive',True),state=state())
            state(action='open',section='downloads');check('reopen_builds_fresh_panel',state()['panelGeneration']==generation+1)
            sessions=len(state(action='sessions')['sessions'])
            app.call('command',id='new-window');state(action='open',section='history')
            check('second_window_owns_session',len(state(action='sessions')['sessions'])==sessions+1)
            app.call('window-close')
            check('closed_window_releases_panel',wait(lambda:len(state(action='sessions')['sessions'])==sessions and not state(action='sessions')['closedPanelAlive']))
            app.call('window-focus',id=owner,activate=True)
            app.call('download-policy',recordFiles=True)
            download_dir=Path(data)/'download-files';download_dir.mkdir()
            app.call('download-settings',profile=profile,directory=str(download_dir),ask=False)
            def downloads(): return app.call('downloads-state')['items']
            def item(id): return next((d for d in downloads() if d['id']==id),{})
            def start(route,open_after=True):
                state(action='close');app.call('select',tab=tab)
                old={x['id'] for x in downloads()}
                app.eval(tab,'(()=>{const a=document.createElement("a");a.id="download";a.href='+json.dumps(base+route)+';a.textContent="Download";document.body.replaceChildren(a)})()')
                app.call('click',tab=tab,selector='#download')
                value=wait(lambda:next((d for d in downloads() if d['id'] not in old),None));assert value
                if open_after:
                    state(action='open',section='downloads');assert wait(lambda:row(value['id']))
                return value['id']
            complete=start('/file');check('completed_download_row',wait(lambda:item(complete).get('state')=='completed') and wait(lambda:row(complete)['subtitle']=='Download'),row=row(complete))
            # Arc's download menu (D2c #394): "Open ‹ext›", "Copy ‹ext›", then the fixed items.
            titles=[m['title'] for m in menu(complete)]
            check('completed_native_menu', len(titles)==6 and titles[0].startswith('Open') and titles[1].startswith('Copy') and titles[2:]==['Show in Finder','separator','Hide from Open','Move to Trash'],items=menu(complete))
            check('completed_no_right_click_menu',row(complete).get('contextMenu') is False,row=row(complete))  # Arc: right-click only selects (C3 s8 item 9)
            state(action='hover-row',id=complete);check('hover_row',row(complete)['hovered']);capture('downloads-completed-hover')
            menu(complete,titles[1]);check('download_copy_file',wait(lambda:app.call('downloads-state')['copiedFileURL'].endswith('/sample.txt')))
            payload=state(action='row-drag',id=complete);check('download_drag_file', 'public.file-url' in payload['types'] and payload['url'].endswith('/sample.txt'),payload=payload)
            menu(complete,titles[0]);check('download_open_action',bool(app.call('downloads-state')['fileActions']))
            # Complete several real engine transfers while the Library is closed.
            for _ in range(3):
                newest=start('/file',open_after=False);assert wait(lambda:item(newest).get('state')=='completed')
            check('badge_three_files',wait(lambda:app.call('downloads-state')['badge'].get('stackCount')==3),badge=app.call('downloads-state')['badge'])
            badge=app.call('downloads-state')['badge'];check('badge_size_and_name',badge['thumbnailSize']==39 and badge['tooltipTitle']==item(newest)['name'])
            check('badge_file_drag','public.file-url' in badge['drag']['types'] and badge['drag']['url'].endswith(item(newest)['name'].replace(' ','%20')));capture('download-badge')
            box=badge['frame'];time.sleep(.25)
            app.call('mouse',action='click',queued=True,window=state()['window'],x=box[0]+box[2]/2,y=box[1]+box[3]/2)
            check('badge_click_opens_downloads',wait(lambda:state()['open'] and state()['section']=='downloads'))
            check('opening_library_clears_badge',wait(lambda:app.call('downloads-state')['badge']['stackCount']==0) and not app.call('downloads-state')['badgeExpiryScheduled'])
            app.call('download-badge-lifetime',seconds=.6)
            expiring=start('/file',open_after=False);assert wait(lambda:item(expiring).get('state')=='completed')
            check('badge_expiry_scheduled',app.call('downloads-state')['badgeExpiryScheduled'])
            check('badge_expiry_releases_task',wait(lambda:app.call('downloads-state')['badge']['stackCount']==0 and not app.call('downloads-state')['badgeExpiryScheduled']))
            app.call('download-badge-lifetime',seconds=60);state(action='open',section='downloads')
            check('pointer_selected_tile_no_ring',not any(t.get('focusRing') for t in state()['rail']))
            state(action='focus-rail');key('right');check('keyboard_tile_ring',any(t.get('focusRing') and t['selected'] for t in state()['rail']))
            target=next(t for t in state()['rail'] if t['id']=='downloads');x,y,w,h=target['frame']
            app.call('mouse',action='click',queued=True,window=state()['window'],x=x+w/2,y=y+h/2)
            check('pointer_clears_ring',wait(lambda:state()['section']=='downloads') and not any(t.get('focusRing') for t in state()['rail']))
            if os.environ.get('OPEN_LIBRARY_SKIP_MENU_PROBE')=='1':result['nativeMenuOmitted']=True
            else:
                menu_count=state()['menuLifecycle']['opened'];state(action='show-row-menu',id=complete,escape=True)
                check('native_menu_presented',wait(lambda:state()['menuLifecycle']['opened']>menu_count))
                check('escape_dismisses_menu_first',state()['open'] and not state()['menuOpen'] and state()['section']=='downloads')
            state(action='search',text='unmatched-library');check('download_search_empty',wait(lambda:not rows() and state()['emptyState']['title']=='No matches'))
            key('escape');check('escape_clears_search',state()['open'] and state()['search']=='')
            state(action='filter',open=True);check('download_profile_chips',len(state()['header']['chips'])>=1)
            # Outside entry selected the owner already. Exercise native clear
            # and select, rather than toggling that selected chip off.
            if state()['profiles']['downloads']==profile:
                state(action='chip',id='profile:'+profile)
                check('profile_chip_clears',state()['profiles']['downloads']=='all' and not state()['filterActive'])
            state(action='chip',id='profile:'+profile);check('profile_chip_selected',state()['filterActive'] and state()['profiles']['downloads']==profile);capture('downloads-profile-filter')
            key('escape');check('escape_closes_filter',not state()['header']['filterOpen'] and state()['open'])
            state(action='filter',open=True);state(action='chip',id='profile:'+profile);state(action='filter',open=False)
            slow=start('/slow');check('running_numeric_progress',not row(slow)['subtitle'].startswith('Zero'));check('running_menu',[m['title'] for m in menu(slow)][2:]==['Show in Finder','separator','Cancel Download','separator','Hide from Open'],items=menu(slow));capture('downloads-running')
            state(action='row-action',id=slow,name='Pause');check('pause_real_transfer',wait(lambda:item(slow).get('state')=='paused') and wait(lambda:'Resume' in row(slow).get('actions',[])));capture('downloads-paused')
            state(action='row-action',id=slow,name='Resume');check('resume_real_transfer',wait(lambda:item(slow).get('state')=='inProgress'))
            menu(slow,'Cancel Download');check('cancel_real_transfer',wait(lambda:item(slow).get('state')=='cancelled'));capture('downloads-cancelled')
            failed=start('/fail');check('failed_real_transfer',wait(lambda:item(failed).get('state')=='failed'))
            check('failed_menu',[m['title'] for m in menu(failed)][2:]==['Show in Finder','separator','Hide from Open'] and not any(m['enabled'] for m in menu(failed)[:3]) and 'Retry' in row(failed).get('actions',[]));capture('downloads-failed')
            # History is populated by real engine navigation.
            state(action='close');app.call('navigate',tab=tab,url=base+'/arm');app.call('wait',tab=tab);app.call('history-state')
            key('y',['cmd']);check('cmd_y_history',state()['open'] and state()['section']=='history')
            check('history_real_rows',wait(lambda:any('/arm' in r['id'] for r in rows())),rows=rows())
            history=next(r for r in rows() if '/arm' in r['id']);state(action='hover-row',id=history['id']);capture('history-hover')
            payload=state(action='row-drag',id=history['id']);check('history_drag_url',payload['url']==history['id'],payload=payload)
            state(action='filter',open=True);state(action='chip',id='when:yesterday');check('history_when_empty',wait(lambda:not rows()));capture('history-filter-no-matches')
            state(action='chip',id='when:yesterday');state(action='chip',id='when:week');check('history_week_includes_today',wait(lambda:bool(row(history['id']))))
            state(action='chip',id='when:week');state(action='filter',open=False)
            history_file=app.call('history-state')['file']
            with sqlite3.connect(history_file) as db:
                for index in range(240):
                    visited=time.time()-1000-index
                    inserted=db.execute('INSERT INTO urls(url,title,visit_count,typed_count,last_visit) VALUES(?,?,1,0,?)',('https://history.example.test/item/%d'%index,'Library history %03d'%index,visited))
                    db.execute('INSERT INTO visits(url_id,time,transition) VALUES(?,?,?)',(inserted.lastrowid,visited,'link'))
            state(action='select',section='history');check('history_first_page',wait(lambda:len(rows())==100))
            state(action='focus-rail');key('tab');check('tab_rail_to_search',state()['firstResponder'] in ['NSTextView','LibrarySearchEditor'],responder=state()['firstResponder'])
            key('tab');check('tab_search_to_filter',state()['firstResponder']=='LibraryControl',responder=state()['firstResponder'])
            key('space');check('keyboard_opens_filter',state()['header']['filterOpen']);key('escape')
            state(action='focus-rail');key('tab');key('tab');key('tab');check('tab_filter_to_list',state()['firstResponder']=='LibraryTableView')
            first_selected=rows()[0]['id'];state(action='row-select',id=first_selected);key('down')
            check('down_moves_row_focus',wait(lambda:any(r['selected'] and r['id']!=first_selected for r in rows())),state=state())
            key('up');check('up_moves_row_focus',rows()[0]['selected'])
            state(action='row-select',id=rows()[-1]['id']);check('history_paginates',wait(lambda:len(rows())>100),count=len(rows()))
            state(action='row-select',id=history['id']);key('return');check('return_opens_history',wait(lambda:not state()['open']) and len(app.call('tabs'))>1)
            state(action='open',section='history');assert wait(lambda:bool(rows()))
            assert wait(lambda:row(history['id']));time.sleep(.25);box=row(history['id'])['frame']
            app.call('mouse',action='click',queued=True,window=state()['window'],x=box[0]+80,y=box[1]+box[3]/2)
            check('native_row_click_opens_history',wait(lambda:not state()['open']))
            state(action='open',section='history');assert wait(lambda:bool(rows()))
            delete_id=next(r['id'] for r in rows() if r['id']!=history['id'])
            state(action='row-select',id=delete_id);key('delete',['cmd']);app.call('alert',window='library',button='Cancel')
            check('history_delete_cancel',bool(row(delete_id)))
            state(action='row-select',id=delete_id);key('delete',['cmd']);app.call('alert',window='library',button='Delete')
            check('history_delete_confirm',wait(lambda:not row(delete_id)))
            state(action='close')
            # Closing an ordinary real tab archives it through the existing path.
            other=app.call('tabs')[-1]['id'];app.call('select',tab=other);app.call('command',id='archive-tab')
            state(action='open',section='archive');check('archive_real_rows',wait(lambda:bool(rows())),rows=rows())
            archived=rows()[0];state(action='hover-row',id=archived['id']);check('archive_hover_actions',row(archived['id'])['actions']==['Delete','Restore']);capture('archive-hover')
            state(action='filter',open=True);check('archive_filters',len(state()['header']['chips'])>=4);capture('archive-filters')
            state(action='chip',id='reason:auto');check('archive_reason_empty',wait(lambda:not rows()))
            state(action='chip',id='reason:auto');state(action='chip',id='reason:manual');check('archive_manual_filter',wait(lambda:bool(row(archived['id']))))
            state(action='chip',id='reason:manual');state(action='chip',id='space:little');check('archive_location_empty',wait(lambda:not rows()))
            state(action='chip',id='space:little');check('archive_location_reset',wait(lambda:bool(row(archived['id']))))
            state(action='filter',open=False);state(action='row-action',id=archived['id'],name='Restore');check('archive_restore_closes',wait(lambda:not state()['open']))
            # Use the real capture pipeline and persisted index.
            capture_tab=new_tab(app,base+'/');app.call('focus',tab=capture_tab)
            check('capture_ready_page',wait(lambda:next(m['enabled'] for m in app.call('menu-state') if m['id']=='capture-page')))
            receipt=app.call('capture',mode='area',rect=[30,30,240,150]);check('capture_real_file',receipt['state']['phase'] in ['showing'],receipt=receipt)
            app.call('capture-action',action='cancel')
            state(action='open',section='media');check('media_capture_rows',wait(lambda:bool(rows())),rows=rows());check('capture_page_title',rows()[0]['title']=='Downloads fixture' and '127.0.0.1' in rows()[0]['subtitle'])
            app.call('library-captures-state',recordFileActions=True)
            capture_row=rows()[0];state(action='hover-row',id=capture_row['id']);check('capture_native_menu',[m['title'] for m in menu(capture_row['id'])]==['Open in Preview','Send via iMessage','AirDrop','Copy Image','Show in Finder','Save As…','separator','Delete']);capture('media-captures')
            payload=state(action='row-drag',id=capture_row['id']);check('capture_drag_file','public.file-url' in payload['types'],payload=payload)
            menu(capture_row['id'],'Copy Image');check('capture_copy_image',app.call('library-captures-state')['pasteboardHasImage'])
            menu(capture_row['id'],'Save As…');save_path=Path(data)/'saved-capture.png';state(action='save-panel',path=str(save_path))
            check('capture_save_as_file',wait(lambda:save_path.exists()) and save_path.read_bytes().startswith(b'\x89PNG'))
            menu(capture_row['id'],'Open in Preview');check('capture_open_recorded',bool(app.call('library-captures-state')['opened']))
            state(action='row-select',id=capture_row['id']);key('delete',['cmd'])
            app.call('alert',window='library',button='Cancel');check('capture_delete_cancel',bool(row(capture_row['id'])))
            state(action='row-select',id=capture_row['id']);key('delete',['cmd']);app.call('alert',window='library',button='Delete')
            check('capture_delete_confirm',wait(lambda:not rows()))
            # Build a Boost with the real editor, then use its native Library controls.
            state(action='close');boost_tab=new_tab(app,'https://alpha.example.test/boost.html');app.call('wait',tab=boost_tab)
            app.call('menu-perform',id='new-boost');check('boost_real_editor',wait(lambda:app.call('boost-editor').get('colorsReady')))
            app.call('boost-editor',action='tap',id='font.Avenir');boost=app.call('boost-editor')['boost']['id'];app.call('boost-editor',action='close')
            state(action='open',section='boosts');check('boost_real_row',wait(lambda:row(boost)),rows=rows())
            check('boost_no_right_click_menu',row(boost).get('contextMenu') is False,row=row(boost))  # Arc: no card menu (C3 s8 item 14)
            state(action='hover-row',id=boost);check('boost_menu',[m['title'] for m in menu(boost)]==['Edit Boost','Turn Off','separator','Delete']);capture('boosts-list-hover')
            menu(boost,'Turn Off');check('boost_toggle_live',wait(lambda:not app.eval(boost_tab,'getComputedStyle(document.querySelector("h1")).fontFamily').startswith('Avenir')))
            menu(boost,'Turn On');check('boost_toggle_on',wait(lambda:app.eval(boost_tab,'getComputedStyle(document.querySelector("h1")).fontFamily').startswith('Avenir')))
            state(action='boost-layout',name='Gallery');check('boost_gallery',state()['boostsLayout']=='Gallery');capture('boosts-gallery')
            state(action='search',text='no-such-boost');check('boost_search_empty',wait(lambda:not rows()));state(action='search',text='');assert wait(lambda:row(boost))
            menu(boost,'Edit Boost');check('boost_edit_row',wait(lambda:app.call('boost-editor').get('open')));app.call('boost-editor',action='close')
            state(action='row-action',id=boost,name='Delete');app.call('alert',window='library',button='Cancel')
            check('boost_delete_cancel',any(b['id']==boost for b in app.call('boosts',profile=profile)))
            # Space Manager uses its real model, outline, menus and reorder handle.
            state(action='select',section='spaces');manager=app.call('space-manager-state');check('space_card_geometry',all(c['column'][1:]==[48,240,704] for c in manager['columns']),state=manager)
            capture('spaces-cards')
            second_space=app.call('space-create',title='Reading',profile='Library Work')
            state(action='select',section='boosts');app.call('boost-gallery-ui',action='profile',name='Library Work')
            check('boost_profile_empty',wait(lambda:not rows()))
            snapshot=json.loads(Path(app.call('save')).read_text());profile_name=next(p['name'] for p in snapshot['profiles'] if p['id']==profile)
            app.call('boost-gallery-ui',action='profile',name=profile_name);check('boost_profile_restored',wait(lambda:bool(row(boost))))
            state(action='select',section='spaces');manager=app.call('space-manager-state')
            check('spaces_second_card',len(manager['columns'])==2)
            app.call('space-manager-menu',space=second_space,item='Rename Space…');key('a',['cmd']);app.call('key',text='Reading List',route='app');key('return')
            check('space_visible_rename',wait(lambda:any(s['id']==second_space and s['title']=='Reading List' for s in app.call('spaces'))))
            check('space_rename_returns_focus',state()['firstResponder']!='NSTextView',responder=state()['firstResponder'])
            app.call('space-manager-drag',space=second_space,to=0);check('space_native_reorder',app.call('spaces')[0]['id']==second_space)
            capture('spaces-reordered')
            app.call('space-manager-menu',space=second_space,item='Delete Space');app.call('alert',window='library',button='Cancel')
            check('space_delete_cancel',any(s['id']==second_space for s in app.call('spaces')))
            app.call('space-manager-menu',space=second_space,item='Delete Space');app.call('alert',window='library',button='Delete')
            check('space_delete_confirm',wait(lambda:all(s['id']!=second_space for s in app.call('spaces'))))
            key('z',['cmd']);check('space_delete_undo',wait(lambda:any(s['id']==second_space for s in app.call('spaces'))))
            original_column=next(c for c in app.call('space-manager-state')['columns'] if c['id']==space['id'])
            target=next(r for r in original_column['rows'] if r['id']==tab)
            app.call('mouse',action='click',window=state()['window'],x=target['point'][0],y=target['point'][1],delivery='queued')
            check('space_tab_click_closes',wait(lambda:not state()['open']))
            if frames:
                # Review both populated and empty Media, and a populated Archive,
                # using the same real engine and capture paths as the flow above.
                review_archive=new_tab(app,base+'/arm');app.call('wait',tab=review_archive);app.call('command',id='archive-tab')
                app.call('select',tab=capture_tab);app.call('focus',tab=capture_tab)
                assert wait(lambda:next(m['enabled'] for m in app.call('menu-state') if m['id']=='capture-page'))
                app.call('capture',mode='area',rect=[30,30,240,150]);app.call('capture-action',action='cancel')
                # Six exact fixture pairs; sidebar is captured and measured first.
                app.call('space',space=space['id']);app.call('select',tab=tab)
                if os.environ.get('OPEN_LIBRARY_L3_FRAMES')!='1':
                    for theme,rgb in [('peach',(.94,.49,.35)),('ocean',(.26,.53,.90)),('night',(.35,.27,.60))]:
                        for appearance in ['light','dark']:
                            app.call('appearance',name=appearance)
                            app.call('theme-set',space=space['id'],style=dict(keyColor=dict(zip(['red','green','blue'],rgb),alpha=1),colorCount=3,appearance=appearance,noiseFactor=0,intensityFactor=.8))
                            state(action='close');time.sleep(.3)
                            sidebar=app.call('sidebar-row',node=tab)
                            capture(theme+'-'+appearance+'-sidebar',sidebar=sidebar,themeState=app.call('theme-get',space=space['id']))
                            state(action='open',section='downloads');time.sleep(.25)
                            capture(theme+'-'+appearance+'-downloads',sidebar=sidebar,themeState=app.call('theme-get',space=space['id']))
                state(action='open',section='downloads')
                for width,height in ([] if os.environ.get('OPEN_LIBRARY_L3_FRAMES')=='1' else [(1280,800),(900,850)]):
                    app.call('window-frame',frame=[40,50,width,height],unconstrained=True)
                    for section in ['downloads','archive','history','media','boosts','spaces']:
                        state(action='select',section=section);time.sleep(.25)
                        capture('content-%dx%d-%s'%(width,height,section))
                if mockups:
                    state(action='close');time.sleep(.25)
                    if app.call('window-state')['sidebarMode']!='hidden':app.call('command',id='toggle-sidebar')
                    for source in sorted(mockups.glob('mock-*.html')):
                        width,height=map(int,source.stem.split('-')[2].split('x'))
                        app.call('window-frame',frame=[40,50,width+20,height+20],unconstrained=True)
                        app.call('navigate',url=source.resolve().as_uri());app.call('wait');time.sleep(.1)
                        path=output/(source.stem+'.png');app.call('snapshot',page=True,path=str(path))
                        size=struct.unpack('>II',path.read_bytes()[16:24])
                        check(source.stem+'_reference_2x',size==(width*2,height*2),pixels=size)
            if os.environ.get('OPEN_LIBRARY_SKIP_DRAG_PROBE')=='1':result['nativeDragOmitted']=True
            else:
                # Run last: local NSEvents start the real AppKit source session,
                # but cannot qualify a foreign app's WindowServer drop. Quitting
                # the owned app below must also remove its native drag image.
                state(action='open',section='downloads');assert wait(lambda:row(complete));time.sleep(.25)
                before_drag=state()['dragSession']['began'];probe=state(action='row-drag-session',id=complete)
                check('download_native_drag_session',wait(lambda:state()['dragSession']['began']>before_drag),session=state()['dragSession'],hit=probe.get('dragStartHit'))
                result['nativeDragQualification']='Real native source session and file pasteboard; foreign-app drop/end is UNVERIFIED under socket-only input.'
                if os.environ.get('OPEN_LIBRARY_REQUIRE_DRAG_END')=='1':
                    box=row(complete)['frame'];app.call('mouse',action='up',window=state()['window'],x=box[0]+510,y=box[1]+box[3]/2+12)
                    check('download_native_drag_ended',wait(lambda:state()['dragSession']['ended']>0),session=state()['dragSession'])
            result['ok']=True
        except Exception as e:
            result.update(ok=False,error=repr(e));raise
        finally:
            if app:
                for name,value in saved.items():
                    try:app.call('defaults',key=name,value=value)
                    except Exception:pass
                app.quit();result['cleanup']=app.quit_report
                prefix=str(bundle or Path(__file__).resolve().parents[2]/'build/Debug/Open.app')+'/'
                audit=[line for line in subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines() if prefix in line]
                result['processPathAudit']=audit
                if not app.quit_report.get('ok') or audit:result.update(ok=False,error='Owned app cleanup failed')
            (output/'result.json').write_text(json.dumps(result,indent=2))
    assert result['ok'],result.get('error')
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--output',required=True,type=Path);p.add_argument('--bundle',type=Path);p.add_argument('--frames',action='store_true');p.add_argument('--mockups',type=Path);p.add_argument('--config',choices=['Debug','Release'],default='Debug');a=p.parse_args();run(a.output,a.bundle,a.frames,a.mockups,a.config)
