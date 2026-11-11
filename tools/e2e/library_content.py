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


def run(output,bundle=None,frames=False,mockups=None):
    output.mkdir(parents=True,exist_ok=True)
    result = {'checks':{},'frames':[],'configuration':'Debug; functional evidence, no timing qualification'}
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
        subprocess.run(['/usr/sbin/screencapture','-x','-o','-l',str(current['window']),str(path)],check=True,timeout=15)
        size=struct.unpack('>II',path.read_bytes()[16:24]); frame=app.call('window-state')['frame']
        check(name+'_2x',size==(int(frame[2]*2),int(frame[3]*2)),pixels=size)
        result['frames'].append(dict(name=name,path=path.name,state=current))
        (output/(name+'.json')).write_text(json.dumps(current,indent=2))
    with tempfile.TemporaryDirectory(prefix='open-library-l2-') as data,server() as base,boost_fixture(data) as switches:
        try:
            app=Open('Debug','chrome',data,switches,str(output/'app.log'),urls=(base+'/',),extra_env={'OPEN_E2E_APP_BUNDLE':str(bundle)} if bundle else {})
            for name,value in [('OpenLibraryLegacyWindow',False),('libraryShowsEasels',False),('open.sidebar.hideHintShown',True),('open.advanced.enableBoosts',True),('open.boosts.hasDismissedInterstitial',True),('open.boosts.hasDismissedJSNotice',True)]:
                saved[name]=app.call('defaults',key=name,persistent=True);app.call('defaults',key=name,value=value)
            owner=app.call('shell-windows')[0]['id'];tab=app.call('tabs')[0]['id'];app.call('wait',tab=tab)
            space=next(s for s in app.call('spaces') if s['focused']);profile=space['profile']
            app.call('window-frame',frame=[40,50,1280,800],unconstrained=True)
            app.call('window-focus',id=owner,activate=True)
            state(action='open',section='media')
            check('media_truthful_empty',wait(lambda:state().get('emptyVisible')) and state()['emptyState']['title']=='No media yet' and not state()['emptyState']['buttonVisible'],state=state()['emptyState'])
            index_file=Path(data)/'State/captures.json';index_file.parent.mkdir(exist_ok=True)
            index_file.write_text('broken capture index');state(action='refresh')
            check('media_corrupt_index_error',wait(lambda:state()['emptyState']['title']=='Could not load media'))
            index_file.unlink();state(action='refresh')
            check('media_missing_index_recovers',wait(lambda:state()['emptyState']['title']=='No media yet'))
            # Reopen cancels the old release; the next close releases the actual view.
            state(action='release-delay',seconds=.6);generation=state()['panelGeneration'];state(action='close');time.sleep(.3)
            state(action='open',section='media');time.sleep(.4)
            check('reopen_cancels_release',state()['panelCreated'] and state()['panelGeneration']==generation)
            state(action='close');check('closed_view_released',wait(lambda:not state().get('panelCreated',True)) and not state().get('releasedPanelAlive',True),state=state())
            state(action='open',section='downloads');check('reopen_builds_fresh_panel',state()['panelGeneration']==generation+1)
            app.call('download-policy',recordFiles=True)
            download_dir=Path(data)/'download-files';download_dir.mkdir()
            app.call('download-settings',profile=profile,directory=str(download_dir),ask=False)
            def downloads(): return app.call('downloads-state')['items']
            def item(id): return next((d for d in downloads() if d['id']==id),{})
            def start(route):
                state(action='close');app.call('select',tab=tab)
                old={x['id'] for x in downloads()}
                app.eval(tab,'(()=>{const a=document.createElement("a");a.id="download";a.href='+json.dumps(base+route)+';a.textContent="Download";document.body.replaceChildren(a)})()')
                app.call('click',tab=tab,selector='#download')
                value=wait(lambda:next((d for d in downloads() if d['id'] not in old),None));assert value
                state(action='open',section='downloads');assert wait(lambda:row(value['id']))
                return value['id']
            complete=start('/file');check('completed_download_row',wait(lambda:item(complete).get('state')=='completed') and wait(lambda:row(complete)['subtitle']=='Download'),row=row(complete))
            expected=['Open','Copy','Show in Finder','separator','Hide from Open','Move to Trash']
            check('completed_native_menu', [m['title'] for m in menu(complete)]==expected,items=menu(complete))
            state(action='hover-row',id=complete);check('hover_row',row(complete)['hovered']);capture('downloads-completed-hover')
            menu(complete,'Copy');check('download_copy_file',app.call('downloads-state')['copiedFileURL'].endswith('/sample.txt'))
            payload=state(action='row-drag',id=complete);check('download_drag_file', 'public.file-url' in payload['types'] and payload['url'].endswith('/sample.txt'),payload=payload)
            before_drag=state()['dragSession']['began'];state(action='row-drag-session',id=complete)
            check('download_native_drag_session',wait(lambda:state()['dragSession']['began']>before_drag),session=state()['dragSession'])
            check('download_native_drag_ended',wait(lambda:state()['dragSession']['ended']>0),session=state()['dragSession'])
            menu(complete,'Open');check('download_open_action',bool(app.call('downloads-state')['fileActions']))
            state(action='show-row-menu',id=complete);check('native_menu_presented',wait(lambda:state()['menuOpen']));key('escape')
            check('escape_dismisses_menu_first',state()['open'] and not state()['menuOpen'] and state()['section']=='downloads')
            state(action='search',text='unmatched-library');check('download_search_empty',not rows() and state()['emptyState']['title']=='No matches')
            key('escape');check('escape_clears_search',state()['open'] and state()['search']=='')
            state(action='filter',open=True);check('download_profile_chips',len(state()['header']['chips'])>=1)
            state(action='chip',id='profile:'+profile);check('profile_chip_selected',state()['filterActive']);capture('downloads-profile-filter')
            key('escape');check('escape_closes_filter',not state()['header']['filterOpen'] and state()['open'])
            state(action='filter',open=True);state(action='chip',id='profile:'+profile);state(action='filter',open=False)
            slow=start('/slow');check('running_menu',[m['title'] for m in menu(slow)]==['Pause','Cancel','Show in Finder'])
            menu(slow,'Pause');check('pause_real_transfer',wait(lambda:item(slow).get('state')=='paused'));capture('downloads-paused')
            menu(slow,'Resume');check('resume_real_transfer',wait(lambda:item(slow).get('state')=='inProgress'))
            menu(slow,'Cancel');check('cancel_real_transfer',wait(lambda:item(slow).get('state')=='cancelled'));capture('downloads-cancelled')
            failed=start('/fail');check('failed_real_transfer',wait(lambda:item(failed).get('state')=='failed'))
            check('failed_menu',[m['title'] for m in menu(failed)]==['Retry','Hide from Open']);capture('downloads-failed')
            # History is populated by real engine navigation.
            state(action='close');app.call('navigate',tab=tab,url=base+'/arm');app.call('wait',tab=tab);app.call('history-state')
            key('y',['cmd']);check('cmd_y_history',state()['open'] and state()['section']=='history')
            check('history_real_rows',wait(lambda:any('/arm' in r['id'] for r in rows())),rows=rows())
            history=next(r for r in rows() if '/arm' in r['id']);state(action='hover-row',id=history['id']);capture('history-hover')
            payload=state(action='row-drag',id=history['id']);check('history_drag_url',payload['url']==history['id'],payload=payload)
            state(action='filter',open=True);state(action='chip',id='when:yesterday');check('history_when_empty',not rows());capture('history-filter-no-matches')
            state(action='chip',id='when:yesterday');state(action='chip',id='when:week');check('history_week_includes_today',wait(lambda:bool(row(history['id']))))
            state(action='chip',id='when:week');state(action='filter',open=False)
            history_file=app.call('history-state')['file']
            with sqlite3.connect(history_file) as db:
                for index in range(240):
                    visited=time.time()-1000-index
                    inserted=db.execute('INSERT INTO urls(url,title,visit_count,typed_count,last_visit) VALUES(?,?,1,0,?)',('https://history.example.test/item/%d'%index,'Library history %03d'%index,visited))
                    db.execute('INSERT INTO visits(url_id,time,transition) VALUES(?,?,?)',(inserted.lastrowid,visited,'link'))
            state(action='select',section='history');check('history_first_page',wait(lambda:len(rows())==100))
            state(action='focus-list');first_selected=state()['rows'][0]['id'];key('down')
            check('down_moves_row_focus',any(r['selected'] and r['id']!=first_selected for r in rows()))
            key('up');check('up_moves_row_focus',rows()[0]['selected'])
            state(action='row-select',id=rows()[-1]['id']);check('history_paginates',wait(lambda:len(rows())>100),count=len(rows()))
            state(action='row-select',id=history['id']);key('return');check('return_opens_history',wait(lambda:not state()['open']) and len(app.call('tabs'))>1)
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
            state(action='open',section='media');check('media_capture_rows',wait(lambda:bool(rows())),rows=rows())
            app.call('library-captures-state',recordFileActions=True)
            capture_row=rows()[0];state(action='hover-row',id=capture_row['id']);check('capture_native_menu',[m['title'] for m in menu(capture_row['id'])]==['Open','Copy','Show in Finder','Save As…','separator','Delete']);capture('media-captures')
            payload=state(action='row-drag',id=capture_row['id']);check('capture_drag_file','public.file-url' in payload['types'],payload=payload)
            menu(capture_row['id'],'Copy');check('capture_copy_image',app.call('library-captures-state')['pasteboardHasImage'])
            menu(capture_row['id'],'Save As…');save_path=Path(data)/'saved-capture.png';state(action='save-panel',path=str(save_path))
            check('capture_save_as_file',wait(lambda:save_path.exists()) and save_path.read_bytes().startswith(b'\x89PNG'))
            menu(capture_row['id'],'Open');check('capture_open_recorded',bool(app.call('library-captures-state')['opened']))
            state(action='row-select',id=capture_row['id']);key('delete',['cmd'])
            app.call('alert',window='library',button='Cancel');check('capture_delete_cancel',bool(row(capture_row['id'])))
            state(action='row-select',id=capture_row['id']);key('delete',['cmd']);app.call('alert',window='library',button='Delete')
            check('capture_delete_confirm',wait(lambda:not rows()))
            # Build a Boost with the real editor, then use its native Library controls.
            state(action='close');boost_tab=new_tab(app,'https://alpha.example.test/boost.html');app.call('wait',tab=boost_tab)
            app.call('menu-perform',id='new-boost');check('boost_real_editor',wait(lambda:app.call('boost-editor').get('colorsReady')))
            app.call('boost-editor',action='tap',id='font.Avenir');boost=app.call('boost-editor')['boost']['id'];app.call('boost-editor',action='close')
            state(action='open',section='boosts');check('boost_real_row',wait(lambda:row(boost)),rows=rows())
            state(action='hover-row',id=boost);check('boost_menu',[m['title'] for m in menu(boost)]==['Edit Boost','Turn Off','separator','Delete']);capture('boosts-list-hover')
            menu(boost,'Turn Off');check('boost_toggle_live',wait(lambda:not app.eval(boost_tab,'getComputedStyle(document.querySelector("h1")).fontFamily').startswith('Avenir')))
            menu(boost,'Turn On');check('boost_toggle_on',wait(lambda:app.eval(boost_tab,'getComputedStyle(document.querySelector("h1")).fontFamily').startswith('Avenir')))
            state(action='boost-layout',name='Gallery');check('boost_gallery',state()['boostsLayout']=='Gallery');capture('boosts-gallery')
            state(action='search',text='no-such-boost');check('boost_search_empty',not rows());state(action='search',text='')
            menu(boost,'Edit Boost');check('boost_edit_row',wait(lambda:app.call('boost-editor').get('open')));app.call('boost-editor',action='close')
            state(action='row-action',id=boost,name='Delete');app.call('alert',window='library',button='Cancel')
            check('boost_delete_cancel',any(b['id']==boost for b in app.call('boosts',profile=profile)))
            # Space Manager uses its real model, outline, menus and reorder handle.
            state(action='select',section='spaces');manager=app.call('space-manager-state');check('space_card_geometry',all(c['column'][1:]==[48,240,704] for c in manager['columns']),state=manager)
            capture('spaces-cards')
            second_space=app.call('space-create',title='Reading',profile='Library Work')
            state(action='select',section='spaces');manager=app.call('space-manager-state')
            check('spaces_second_card',len(manager['columns'])==2)
            app.call('space-manager-menu',space=second_space,item='Rename Space…');key('a',['cmd']);app.call('key',text='Reading List',route='app');key('return')
            check('space_visible_rename',wait(lambda:any(s['id']==second_space and s['title']=='Reading List' for s in app.call('spaces'))))
            app.call('space-manager-drag',space=second_space,to=0);check('space_native_reorder',app.call('spaces')[0]['id']==second_space)
            capture('spaces-reordered')
            original_column=next(c for c in app.call('space-manager-state')['columns'] if c['id']==space['id'])
            target=next(r for r in original_column['rows'] if r['id']==tab)
            app.call('mouse',action='click',window=state()['window'],x=target['point'][0],y=target['point'][1],delivery='queued')
            check('space_tab_click_closes',wait(lambda:not state()['open']))
            if frames:
                # Six exact fixture pairs; sidebar is captured and measured first.
                app.call('space',space=space['id']);app.call('select',tab=tab)
                for theme,rgb in [('peach',(.95,.55,.49)),('ocean',(.30,.57,.91)),('night',(.16,.13,.27))]:
                    for appearance in ['light','dark']:
                        app.call('appearance',name=appearance)
                        app.call('theme-set',space=space['id'],style=dict(keyColor=dict(zip(['red','green','blue'],rgb),alpha=1),colorCount=3,appearance=appearance,noiseFactor=0,intensityFactor=.8))
                        state(action='close');time.sleep(.3)
                        sidebar=app.call('sidebar-row',node=tab)
                        capture(theme+'-'+appearance+'-sidebar',sidebar=sidebar,themeState=app.call('theme-get',space=space['id']))
                        state(action='open',section='downloads');time.sleep(.25)
                        capture(theme+'-'+appearance+'-downloads',sidebar=sidebar,themeState=app.call('theme-get',space=space['id']))
                for width,height in [(1280,800),(900,850)]:
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
            (output/'result.json').write_text(json.dumps(result,indent=2))
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--output',required=True,type=Path);p.add_argument('--bundle',type=Path);p.add_argument('--frames',action='store_true');p.add_argument('--mockups',type=Path);a=p.parse_args();run(a.output,a.bundle,a.frames,a.mockups)
