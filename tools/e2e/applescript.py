"""Real Cocoa Apple-event checks. Imported by engine_e2e.py, never a unit test."""
import ctypes
import http.server
import json
import os
import plistlib
import runpy
import subprocess
import threading
import time
import urllib.request
import xml.etree.ElementTree as ET

KEY = 'open.developer.allowJavaScriptFromAppleEvents'
MODE_KEY = 'open.developer.modeHosts'
OFF = 'JavaScript from Apple Events is off. Turn it on in View ▸ Developer.'
WRITE_ONLY = ('tabs of application is write-only; make a new tab on application to create a Little Open window, '
              'or read tabs of a window or space.')


def csp_fixture_server():
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = b'<!doctype html><title>AppleScript CSP fixture</title><body>CSP fixture'
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Security-Policy', "script-src 'self'")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, 'http://127.0.0.1:%d/' % server.server_address[1]


def csp_checks(app, script, results):
    """Real execute commands on a response that forbids page-side eval."""
    server, url = csp_fixture_server()
    tab = None
    try:
        with urllib.request.urlopen(url, timeout=5) as response:
            policy = response.headers.get('Content-Security-Policy')
        tab = app.call('open', url=url)['id']
        app.call('wait', tab=tab)
        target = 'tab id %s of window 1' % quote(tab)
        values, errors = {}, {}
        for label, source in [('title', 'document.title'), ('number', '1+1')]:
            try:
                values[label] = script('return execute '+target+' javascript '+quote(source))
            except RuntimeError as error:
                errors[label] = str(error)
        results['A16_CSP_execute'] = {'ok': policy == "script-src 'self'" and not errors
            and values == {'title': 'AppleScript CSP fixture', 'number': '2'},
            'policy': policy, 'values': values, 'errors': errors, 'sender': script.mode}
        blocked = script.error('execute '+target+' javascript '+quote("eval('1+1')"), 1013)
        blocked['ok'] = blocked['ok'] and 'EvalError' in blocked['reply']
        results['A16_CSP_nested_eval_blocked'] = blocked
    finally:
        try:
            if tab is not None: app.call('close', tab=tab)
        finally:
            server.shutdown(); server.server_close()


def quote(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def permission(pid):
    """Read-only TCC preflight. false never requests consent or changes settings."""
    class Desc(ctypes.Structure):
        _fields_ = [('type', ctypes.c_uint32), ('handle', ctypes.c_void_p)]
    ae = ctypes.CDLL('/System/Library/Frameworks/CoreServices.framework/CoreServices')
    ae.AECreateDesc.argtypes = [ctypes.c_uint32, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(Desc)]
    ae.AEDeterminePermissionToAutomateTarget.argtypes = [ctypes.POINTER(Desc), ctypes.c_uint32, ctypes.c_uint32, ctypes.c_ubyte]
    ae.AEDeterminePermissionToAutomateTarget.restype = ctypes.c_int32
    ae.AEDisposeDesc.argtypes = [ctypes.POINTER(Desc)]
    target, value = Desc(), ctypes.c_int32(pid)
    status = ae.AECreateDesc(int.from_bytes(b'kpid', 'big'), ctypes.byref(value), ctypes.sizeof(value), ctypes.byref(target))
    if status: raise RuntimeError('AECreateDesc failed: %d' % status)
    try:
        return ae.AEDeterminePermissionToAutomateTarget(ctypes.byref(target), int.from_bytes(b'core', 'big'),
                                                     int.from_bytes(b'getd', 'big'), False)
    finally:
        ae.AEDisposeDesc(ctypes.byref(target))


class Scripts:
    def __init__(self, app):
        self.app = app
        self.permission = permission(app.pid)
        self.mode = 'osascript' if self.permission == 0 else 'self NSAppleScript'
        self.external = {'status': 'PASS' if self.permission == 0 else 'BLOCKED', 'permissionStatus': self.permission,
                         'targetPID': app.pid, 'targetBundle': app.bundle,
                         'reason': 'read-only AEDeterminePermissionToAutomateTarget, askUserIfNeeded=false'}
        # Preflight is no permission substitute. An exact-bundle osascript probe must
        # also succeed before the external path can count as verified.
        if self.mode == 'osascript':
            try:
                answer = self('return name')
                if answer != 'Open': raise RuntimeError('unexpected application name: ' + answer)
            except Exception as error:
                self.external.update(status='BLOCKED', reason=str(error))
                self.mode = 'self NSAppleScript'

    def __call__(self, body, unavailable=None, language=None):
        if self.mode == 'self NSAppleScript' or unavailable:
            if language:
                raise RuntimeError('JXA external Automation consent unavailable')
            args = {'body': body}
            if unavailable: args['unavailable'] = unavailable
            reply = self.app.call('applescript', **args)
            if reply['number']:
                raise RuntimeError('AppleScript %s: %s' % (reply['number'], reply['message']))
            return reply['text']
        if language:
            source = 'var a = Application(%s); %s' % (json.dumps(self.app.bundle), body)
        else:
            source = 'tell application %s\n%s\nend tell' % (quote(self.app.bundle), body)
        try:
            run = subprocess.run(['/usr/bin/osascript'] + (['-l', language] if language else []) + ['-e', source],
                                 capture_output=True, text=True, timeout=18)
        except subprocess.TimeoutExpired:
            raise RuntimeError('exact-bundle osascript timed out (18 s); no consent/settings changed')
        if run.returncode:
            raise RuntimeError(run.stderr.strip())
        return run.stdout.rstrip('\n')

    def error(self, command, number, message=None, unavailable=None):
        body = 'try\n%s\nreturn "NO ERROR"\non error msg number n\nreturn (n as text) & "|" & msg\nend try' % command
        text = self(body, unavailable=unavailable)
        prefix = str(number) + '|'
        return {'ok': text.startswith(prefix) and (message is None or text[len(prefix):] == message),
                'number': number, 'reply': text, 'sender': self.mode}


def javascript_gate_checks(app, results):
    """D4 through actual Apple events, including the normal settings/menu command."""
    script = Scripts(app)
    old = app.call('defaults', key=KEY)
    try:
        app.call('defaults', key=KEY, value=None)
        tab = app.call('tabs')[0]['id']
        app.call('wait', tab=tab)
        target = 'tab id %s of window 1' % quote(tab)
        off = script.error('execute %s javascript "1 + 2"' % target, 1013, OFF)
        app.call('command', id='allow-js-apple-events')
        on = script('return execute %s javascript "1 + 2"' % target)
        app.call('command', id='allow-js-apple-events')
        off_again = script.error('execute %s javascript "1 + 2"' % target, 1013, OFF)
        results['D4_allow_js_apple_events_osascript'] = {'ok': off['ok'] and on == '3' and off_again['ok'],
            'off': off, 'on': on, 'offAgain': off_again, 'sender': script.mode, 'external': script.external}
    finally:
        app.call('defaults', key=KEY, value=old)


def run(factory, results, tmp, fixture_server, restore_defaults, wait_until):
    """A1–A18/R1–R3 on a new App instance; repeat after cold relaunch with stable IDs."""
    server, origin = fixture_server('AppleScript')
    app = factory(urls=(origin + '/research-pinned',), fresh=True)
    saved = {key: app.call('defaults', key=key) for key in (KEY,MODE_KEY)}
    try:
        for key in saved: app.call('defaults', key=key, value=None)
        script = Scripts(app)
        results['external_osascript'] = dict(script.external, sender=script.mode)
        bundle_sdef = os.path.join(app.bundle, 'Contents/Resources/Open.sdef')
        extracted = subprocess.run(['/usr/bin/sdef', app.bundle], capture_output=True, text=True, check=True).stdout
        with open(os.path.join(tmp, 'Open.sdef'), 'w') as f: f.write(extracted)
        root = ET.fromstring(extracted)
        command_codes = [e.get('code') for e in root.iter('command')]
        expected = ['corecrel','corecnte','coreclos','CrSelect','CrSuBack','CrSuFwd ','CrSuRlod','CrSustop','CrSuExJa','SpaFocus']
        with open(os.path.join(app.bundle, 'Contents/Info.plist'),'rb') as f: info=plistlib.load(f)
        classes=[(e.get('name'),e.get('code')) for e in root.iter('class')]
        results['H3_H4_dictionary'] = {'ok': os.path.isfile(bundle_sdef) and command_codes == expected
            and classes==[('application','capp'),('window','WiND'),('tab','tAbB'),('space','sPaC')]
            and info.get('NSAppleScriptEnabled') is True and info.get('OSAScriptingDefinition')=='Open.sdef'
            and info.get('NSAppleEventsUsageDescription')=='Scripts control Open windows, spaces, and tabs.'
            and info.get('CFBundleName')=='Open' and info.get('CFBundleIdentifier')=='io.github.sergeserb2.open',
            'commands': command_codes, 'classes': classes}
        research = app.call('spaces')[0]['id']
        pinned = app.call('tabs')[0]['id']
        app.call('wait', tab=pinned)
        app.call('pin', tab=pinned)
        today = app.call('open', url=origin + '/research-today')['id']
        app.call('wait', tab=today)
        fun = app.call('space-create', title='Fun')
        fun_tab = app.call('open', url=origin + '/fun')['id']
        app.call('wait', tab=fun_tab)
        app.call('space', space=research)
        app.call('select', tab=today)
        # The first Space's default title is a shell-owned value; reference its stable ID.
        setup_ids = script('return (id of window 1) & "|" & (id of space 1 of window 1) & "|" & (id of tab 1 of space 1 of window 1)')
        for cold in (False, True):
            prefix = 'cold_' if cold else ''
            def check(name, body, expected):
                text = script(body)
                results[prefix + name] = {'ok': text == expected, 'actual': text, 'expected': expected}
                return text
            check('A1_application', 'return name & "|" & version & "|" & (count windows) & "|" & (count spaces of window 1)', 'Open|'+info['CFBundleShortVersionString']+'|1|2')
            frontmost=script('return frontmost as text')
            results[prefix+'A1_frontmost']={'ok':frontmost in ('true','false'),'actual':frontmost}
            name=script('return name of window 1')
            zoomed=script('return zoomed of window 1 as text')
            results[prefix+'A2_name_zoomed']={'ok':bool(name) and zoomed in ('true','false'),'name':name,'zoomed':zoomed}
            check('A2_window', 'set w to window 1\nreturn (index of w as text) & "|" & closeable of w & "|" & minimizable of w & "|" & resizable of w & "|" & zoomable of w & "|" & visible of w & "|" & minimized of w & "|" & mode of w & "|" & incognito of w', '1|true|true|true|true|true|false|normal|false')
            check('A3_flatten_counts', 'return ((count tabs of space 1 of window 1) as text) & "|" & (count tabs of space 2 of window 1) & "|" & (count tabs of window 1)', '2|1|3')
            check('A4_R1_enumeration', 'set rows to {}\nrepeat with w in windows\nrepeat with s in spaces of w\nrepeat with t in tabs of s\nset end of rows to {spaceTitle:title of s, tabTitle:title of t, tabURL:URL of t, tabID:id of t}\nend repeat\nend repeat\nend repeat\nreturn count rows', '3')
            check('A5_tab_properties', 'set t to tab 1 of space 1 of window 1\nreturn (id of t) & "|" & (URL of t) & "|" & (location of t) & "|" & (loading of t)', pinned+'|'+origin+'/research-pinned|pinned|false')
            check('A5_title', 'return title of tab 1 of space 1 of window 1', 'AppleScript /research-pinned')
            check('A6_R2_select', 'set targetID to id of tab 1 of space 2 of window 1\nset found to first tab of window 1 whose id is targetID\nselect found\nreturn (title of active space of window 1) & "|" & (id of active tab of window 1)', 'Fun|'+fun_tab)
            check('A7_focus', 'set targetTitle to title of space id %s of window 1\nset researchSpace to first space of window 1 whose title is targetTitle\nfocus researchSpace\nreturn id of active space of window 1' % quote(research), research)
            check('A8_A9_R3_make_close', 'set s to first space of window 1 whose title is "Fun"\nset nt to make new tab at s with properties {URL:%s, title:"ignored"}\nset nid to id of nt\nset again to first tab of s whose id is nid\nset good to (id of again is nid) and ((count tabs of s) is 2)\nclose nt\nreturn (good as text) & "|" & (count tabs of s)' % quote(origin+'/made'), 'true|1')
            nid = script('set nt to make new tab at window 1 with properties {URL:%s}\nreturn id of nt' % quote(origin+'/nav-a'))
            app.call('wait', tab=nid)
            target = 'tab id %s of window 1' % quote(nid)
            script('set URL of %s to %s' % (target,quote(origin+'/nav-b')))
            wait_until(lambda: app.call('tab-state',tab=nid).get('url') == origin+'/nav-b' or None, timeout=10,step=.1)
            app.call('wait',tab=nid)
            check('A11_URL_set', 'return URL of '+target, origin+'/nav-b')
            script('go back '+target)
            at_a = wait_until(lambda: script('return URL of '+target) == origin+'/nav-a' or None,timeout=10,step=.1)
            script('go forward '+target)
            at_b = wait_until(lambda: script('return URL of '+target) == origin+'/nav-b' or None,timeout=10,step=.1)
            script('reload '+target+'\nstop '+target)
            results[prefix+'A10_navigation'] = {'ok': bool(at_a) and bool(at_b), 'back':bool(at_a),'forward':bool(at_b)}
            check('A12_location', 'set t to '+target+'\nset location of t to "pinned"\nset location of t to "topApp"\nset location of t to "unpinned"\nreturn location of t', 'unpinned')
            script('close '+target)
            check('A13_window', 'set w2 to make new window\nset n to count windows\nset sameID to (id of tab 1 of space 1 of w2 is id of tab 1 of space 1 of window 2)\nclose w2\nreturn (n as text) & "|" & sameID & "|" & (count windows)', '2|true|1')
            target = 'tab id %s of window 1' % quote(today)
            negatives = [(1000,'get tab id "00000000-0000-0000-0000-000000000000" of window 1',None),
                (1001,'set URL of '+target+' to "invalid text"','"invalid text" is not a valid URL.'),
                (1002,'set location of '+target+' to "nowhere"','"nowhere" is not a location. Use topApp, pinned, or unpinned.'),
                (1004,'get tabs',WRITE_ONLY), (1004,'count tabs',WRITE_ONLY),
                (1007,'set index of window 1 to 2','Only set index to 1 (bring to front) is supported.'),
                (1008,'set mode of window 1 to "incognito"','mode can be set only once during creation of the window.'),
                (1008,'set incognito of window 1 to true','mode can be set only once during creation of the window.'),
                (1009,'make new space','Making a new space is not supported. Create a Space in the sidebar.'),
                (1010,'make new window with properties {mode:"incognito"}','Incognito windows are not available in this build.')]
            for i,(number,body,message) in enumerate(negatives):
                results[prefix+'error_%d_%d'%(number,i)] = script.error(body,number,message)
            for number,unavailable,body,message in [
                (1005,'model','make new window','Open is not ready.'),
                (1006,'engine','reload '+target,'The page engine is not ready.'),
                (1012,'window','make new window','There is no browser window.')]:
                results[prefix+'error_'+str(number)] = script.error(body,number,message,unavailable)
            results[prefix+'error_1011'] = script.error('make new tab', 1011,
                'Little windows are not available yet.', unavailable='little')
            runpy.run_path(os.path.join(os.path.dirname(__file__), 'applescript_littleopen.py'))['run'](
                app, script, results, wait_until, quote, KEY, OFF, prefix)
            # Refused split-pane move uses the real Split View model and production creation.
            app.call('space',space=research)
            split_peer=app.call('open',url=origin+'/split-peer')['id']
            app.call('wait',tab=split_peer)
            app.call('select',tab=today)
            app.call('split')
            results[prefix+'error_1003'] = script.error('set location of '+target+' to "topApp"',1003,'A split pane cannot move to favorites. Separate it first.')
            app.call('split')
            app.call('close',tab=split_peer)
            app.call('defaults',key=KEY,value=True)
            app.call('wait',tab=today)
            checks = [('number','1 + 2','3'),('title','document.title','AppleScript /research-today'),
                      ('undefined','undefined',''),('null','null',''),('boolean','true','true'),
                      ('object','({a:1,b:[2]})','{"a":1,"b":[2]}'),('promise','Promise.resolve(42)','42'),
                      ('false','false','false'),('string',"'hello / é'",'hello / é'),
                      ('fraction','1.25','1.25'),('large_fixed','1e20','100000000000000000000'),
                      ('large_exponent','1e21','1e+21'),('small_fixed','1e-6','0.000001'),
                      ('small_exponent','1e-7','1e-7'),('negative_zero','-0','0'),
                      ('nan','NaN','NaN'),('infinity','Infinity','Infinity'),('negative_infinity','-Infinity','-Infinity'),
                      ('bigint','123456789012345678901234567890n','123456789012345678901234567890'),
                      ('symbol',"Symbol('fixture')",'Symbol(fixture)'),
                      ('function','(function scriptingFixture() {})','function scriptingFixture() {}'),
                      ('array','[null,true,1.25,1e-7,1e20]','[null,true,1.25,1e-7,100000000000000000000]'),
                      ('object_evaluated_once','globalThis.scriptFixtureRuns = (globalThis.scriptFixtureRuns || 0) + 1; ({runs:globalThis.scriptFixtureRuns})','{"runs":1}'),
                      ('object_order','({z:1,a:2})','{"z":1,"a":2}'),
                      ('toJSON','({toJSON() { return {converted:true}; }})','{"converted":true}')]
            for label,source,expected in checks:
                check('A16_'+label,'return execute '+target+' javascript '+quote(source),expected)
            # Other automation paths use the engine's gesture-granting convenience
            # evaluator. Observe with raw CDP (no gesture) until that activation
            # expires, then check whether this actual Apple event grants a new one.
            inactive = wait_until(lambda: {'inactive': True} if app.call('devtools', tab=today,
                method='Runtime.evaluate', params={'expression':'navigator.userActivation.isActive',
                'returnByValue':True, 'userGesture':False})['result'].get('value') is False else None,
                timeout=10, step=.1)
            actual = script('return execute '+target+' javascript "navigator.userActivation.isActive"')
            results[prefix+'A16_no_user_gesture'] = {'ok':bool(inactive) and actual=='false',
                'inactiveBefore':bool(inactive), 'actual':actual, 'expected':'false'}
            if not cold:
                csp_checks(app, script, results)
                app.call('select',tab=pinned)
                hidden=app.call('engine-sleep',tab=today,op='freeze')
                value=script('return execute '+target+' javascript '+quote('document.title'))
                selected=app.call('window-state')['selected']
                results['A16_hidden_frozen_tab']={'ok':hidden.get('ok') is True and value=='AppleScript /research-today' and selected==pinned,'freeze':hidden,'value':value,'selected':selected}
                discarded=app.call('engine-sleep',tab=today,op='discard')
                value=script('return execute '+target+' javascript '+quote('document.title'))
                selected=app.call('window-state')['selected']
                results['A16_hidden_discarded_tab']={'ok':discarded.get('ok') is True and value=='AppleScript /research-today' and selected==pinned,'discard':discarded,'value':value,'selected':selected}
                app.call('select',tab=today)
                marker='OPEN_SCRIPT_SOURCE_MUST_STAY_PRIVATE_4B9C'
                value=script('return execute '+target+' javascript '+quote('(() => { const privateSource = '+json.dumps(marker)+'; return 9; })()'))
                results['A16_script_source_not_logged']={'ok':value=='9' and marker not in app.log_text()}
            results[prefix+'error_1013'] = script.error('execute '+target+' javascript "throw new Error(\'boom\')"',1013,'JavaScript error: Error: boom')
            results[prefix+'error_1013_cyclic_result'] = script.error('execute '+target+' javascript '+quote('(() => { const v = {}; v.self = v; return v; })()'),1013)
            results[prefix+'error_1013_nested_bigint'] = script.error('execute '+target+' javascript '+quote('({value:1n})'),1013)
            results[prefix+'error_1002_execute'] = script.error('execute '+target+' javascript ""',1002,'execute needs a javascript string.')
            if not cold:
                started=time.monotonic()
                results['error_1014'] = script.error('execute '+target+' javascript "new Promise(() => {})"',1014,'JavaScript did not finish in 10 seconds.')
                results['error_1014']['elapsedSeconds']=time.monotonic()-started
                results['error_1014']['loadAverage']=list(os.getloadavg())
                # A late page resolution cannot resume an already-completed reply.
                check('after_timeout','return execute '+target+' javascript "6 * 7"','42')
                started=time.monotonic()
                source='new Promise(resolve => setTimeout(() => resolve({toJSON() { while (true) {} }}), 250))'
                results['serializer_error_1014'] = script.error('execute '+target+' javascript '+quote(source),1014,'JavaScript did not finish in 10 seconds.')
                results['serializer_error_1014']['elapsedSeconds']=time.monotonic()-started
                results['serializer_error_1014']['loadAverage']=list(os.getloadavg())
                check('after_serializer_timeout','return execute '+target+' javascript "6 * 7"','42')
            javascript_gate_checks(app, results if not cold else {})
            app.call('defaults',key=KEY,value=None)
            check('A17_counts','return ((count tabs of space 1 of window 1) as text) & "|" & (count spaces of window 1)','2|2')
            if not cold:
                # Send quit by Apple event; cleanup verifies the exact owned PID exits.
                quit_error=None
                try: script('quit')
                except (OSError,json.JSONDecodeError) as error: quit_error=type(error).__name__
                except RuntimeError as error:
                    # App termination can first return terminateCancel while the bounded
                    # sleep-history save runs. Only the verified PID exit proves quit.
                    if 'AppleScript -128:' not in str(error): raise
                    quit_error=str(error)
                deadline=time.monotonic()+10
                while app.process_path(app.pid)==app.executable and time.monotonic()<deadline: time.sleep(.05)
                gone=app.process_path(app.pid)!=app.executable
                app.quit()
                results['A18_quit']={'ok':bool(gone) and not app.quit_report.get('forced'),'sender':script.mode,'closedSocket':quit_error}
                # Exercise the real closed-App defaults fallback, then read its
                # collection type through UserDefaults in the relaunched App.
                fixture_hosts=[('%04d'%i)+'a'*56+'.'+('a'*60+'.')*2+'b'*62+'.invalid' for i in range(1000)]
                restore_defaults(app,{MODE_KEY:fixture_hosts})
                app=factory(urls=())
                restored_hosts=app.call('defaults',key=MODE_KEY)
                results['defaults_closed_array_restore']={'ok':restored_hosts==fixture_hosts,'type':type(restored_hosts).__name__,'count':len(fixture_hosts),'maxHostLength':max(map(len,fixture_hosts))}
                app.call('defaults',key=MODE_KEY,value=saved[MODE_KEY])
                script=Scripts(app)
                ids=script('return (id of window 1) & "|" & (id of space 1 of window 1) & "|" & (id of tab 1 of space 1 of window 1)')
                results['A18_cold_ID_stability']={'ok':ids==setup_ids,'before':setup_ids,'after':ids}
        if script.mode=='osascript':
            results['A1_JXA']={'ok':script('a.name() + "|" + a.windows.length',language='JavaScript')=='Open|1'}
        else:
            results['A1_JXA']={'status':'BLOCKED','reason':'external JXA needs macOS Automation consent; self AppleScript pass is separate'}
    finally:
        restore_defaults(app,saved)
        app.quit()
        server.shutdown();server.server_close()
