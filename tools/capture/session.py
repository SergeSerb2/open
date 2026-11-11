#!/usr/bin/env python3
"""Short, guarded capture blocks. Raw evidence must live outside tracked sources.

Run under lockf -k /tmp/open-onscreen-e2e.lock. Compile native.swift beforehand.
AX predicates match exact attributes, or regex with a `re:` prefix. Ambiguous
matches refuse input. Open actions use its socket exclusively.
"""
import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import signal
import socket
import subprocess
import sys
import time
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = Path(__file__).resolve().parent
SCRIPTS = Path.home() / 'Library/Caches/OpenRE/scripts'
QUESTIONS = Path.home() / '.t3/projects/open/.re/handoff/plans/C-questions.md'


def run(*args, timeout=10):
    return subprocess.check_output([str(x) for x in args], text=True, timeout=timeout).strip()


def walk(node):
    if isinstance(node, list):
        for child in node:
            yield from walk(child)
    elif isinstance(node, dict):
        yield node
        for child in node.get('children', []):
            yield from walk(child)


def matches(node, predicate):
    for key, expected in predicate.items():
        if key == 'index':
            continue
        actual = str(node.get({'identifier': 'id'}.get(key, key), ''))
        if isinstance(expected, str) and expected.startswith('re:'):
            if not re.search(expected[3:], actual, re.I):
                return False
        elif actual != str(expected):
            return False
    return True


class Stopped(RuntimeError):
    pass


class UnavailableAX(Stopped):
    pass


class Session:
    def __init__(self, script, out, backend, native, burst_tool=None, rulings=QUESTIONS, pixel_launcher=None):
        self.script, self.out, self.backend = script, out, backend
        self.native = native
        self.burst_tool = burst_tool or Path('/tmp/open-capture-burst')
        self.pixel_launcher = pixel_launcher
        self.pixel_counter = 0
        self.started = time.monotonic()
        # Reserve the remaining 20 seconds of the lead's 170-second block for
        # guarded restoration and normal quit.
        self.max_seconds = min(float(script.get('max_seconds', 150)), 150)
        self.initial = self.state()
        self.pid = None
        self.proc = None
        self.owned = False
        self.window = script.get('window')
        self.active_window = None
        self.gaps = []
        self.cleaning = False
        self.cleanup_ok = True
        self.drag_first_move_at = None
        self.drag_prior_frames = set()
        self.drag_windows = set()
        self.drag_prior_cg_ids = set()
        self.drag_cg_ids = set()
        self.original_frame = None
        self.mouse_down = False
        self.saved_defaults = {}
        self.restore_actions = []
        self.saved_appearance = None
        self.fixture_server = None
        self.fixture_site = None
        self.clipboard_expected = None
        self.manual_original = None
        self.manual_on = False
        self.fixture_page = None
        self.fixture_points = {}
        self.burst_before = None
        self.burst_events = None
        self.download_requested_at = None
        self.permission_handoff = None
        self.logfile = (out / 'session.jsonl').open('a')
        self.rulings = rulings.read_text() if rulings.exists() else ''
        (out / 'lead-rulings.txt').write_text(self.rulings)
        self.version = self.arc_version()
        self.log('start', state=self.initial, arc_version=self.version, host=socket.gethostname(),
                 rulings_sha256=hashlib.sha256(self.rulings.encode()).hexdigest())

    def arc_version(self):
        with open('/Applications/Arc.app/Contents/Info.plist', 'rb') as stream:
            p = plistlib.load(stream)
        return [p.get('CFBundleShortVersionString'), p.get('CFBundleVersion')]

    def state(self):
        return json.loads(run(self.native, 'state'))

    def pixel_command(self, command):
        if not self.pixel_launcher:
            return command, None
        self.pixel_counter += 1
        logfile = self.out / ('pixel-%04d.log' % self.pixel_counter)
        return ['/usr/bin/open', '-n', '-W', str(self.pixel_launcher), '--args',
                str(HERE / 'pixels.sh'), str(logfile), *map(str, command)], logfile

    def pixel_result(self, logfile):
        if logfile is None:
            return ''
        rc = Path(str(logfile) + '.rc')
        if not rc.exists() or rc.read_text().strip() != '0':
            raise Stopped('pixel launcher failed; inspect ' + str(logfile))
        return logfile.read_text()

    def pixel_run(self, command):
        argv, logfile = self.pixel_command(command)
        result = subprocess.run(argv, capture_output=True, text=True, timeout=15)
        if logfile:
            # open -W can lose its process-wait race after a short launcher run.
            # Only a completed, successful child receipt qualifies the pixels.
            output = self.pixel_result(logfile)
            if result.returncode:
                self.log('pixel-launch-wait-warning', open_exit=result.returncode, receipt_exit=0)
            return output
        result.check_returncode()
        return result.stdout

    def log(self, step, **kwargs):
        self.logfile.write(json.dumps({'t': datetime.datetime.now().astimezone().isoformat(),
                                      'monotonic': time.monotonic(), 'step': step, **kwargs}) + '\n')
        self.logfile.flush()

    def guard(self, event=False):
        if not self.cleaning and time.monotonic() - self.started >= self.max_seconds:
            raise Stopped('short-block deadline reached')
        now = self.state()
        self.observe_download_prompt(now)
        if now['screens'] != self.initial['screens']:
            raise Stopped('display changed')
        if event and now['frontmostPID'] != self.pid:
            self.log('foreground-stop', expected_pid=self.pid, actual_pid=now['frontmostPID'], actual_bundle=now['frontmostBundle'])
            raise Stopped('frontmost app changed; no event sent')
        if not now['trusted'] and self.backend == 'arc':
            raise Stopped('Accessibility is not trusted')
        if now['frontmostBundle'] in ('com.apple.SecurityAgent', 'com.apple.systempreferences', 'com.apple.UserNotificationCenter'):
            raise Stopped('system dialog, UserNotificationCenter or System Settings is frontmost')
        if self.backend == 'arc' and self.pid:
            # Inspect only the owned app. Never interact with sign-in/permission UI.
            windows = json.loads(run(self.native, 'window-info', self.pid))
            dialogs = [n for n in walk(windows) if n.get('subrole') == 'AXSystemDialog']
            if self.mouse_down and self.drag_first_move_at is not None:
                current = json.loads(run(self.native, 'windows', self.pid))
                unexpected = [w for w in current if w['onscreen'] and w['number'] not in self.drag_prior_cg_ids | self.drag_cg_ids]
                if len(dialogs) == 1 and not self.drag_windows:
                    frame = tuple(dialogs[0].get('frame', []))
                    allowed = [w['bounds'] for w in current if w['number'] in self.drag_cg_ids]
                    if not frame or not any(frame) or any(all(abs(v-b[k]) < 2 for v,k in zip(frame,('X','Y','Width','Height'))) for b in allowed):
                        self.drag_windows.add(frame)
                if unexpected or len(dialogs) > max(1,len(self.drag_windows)):
                    self.log('unexpected-window-during-drag', windows=unexpected, dialog_count=len(dialogs))
                    raise Stopped('another new window appeared during the owned drag')
            for n in walk(windows):
                title = str(n.get('title', ''))
                if n.get('subrole') == 'AXSystemDialog' and self.owned_drag_window(n, now):
                    continue
                if n.get('subrole') == 'AXSystemDialog' or re.search(r'^(Sign [Ii]n|Log [Ii]n|Accessibility Access|Screen Recording)$', title):
                    self.observe_download_prompt(now, owned_dialog=True)
                    raise Stopped('sign-in or system permission dialog in Arc')
        if event:
            # AX reads can take seconds. Recheck immediately before dispatch.
            now = self.state()
            self.observe_download_prompt(now)
            if now['frontmostPID'] != self.pid:
                self.log('foreground-stop', expected_pid=self.pid, actual_pid=now['frontmostPID'], actual_bundle=now['frontmostBundle'])
                raise Stopped('frontmost app changed during AX read; no event sent')
        return now

    def owned_drag_window(self, node, state):
        if not (self.mouse_down and self.m1_input_ruling() and '## LEAD 20:32' in self.rulings):
            return False
        frame = tuple(node.get('frame', []))
        if frame in self.drag_windows:
            return True
        if len(frame) != 4:
            return False
        if self.drag_first_move_at is None or time.monotonic() - self.drag_first_move_at > 1 or frame in self.drag_prior_frames:
            return False
        x,y,w,h = frame
        px,py = state['pointer']
        if w <= 0 or h <= 0 or not (x-16 <= px <= x+w+16 and y-16 <= py <= y+h+16):
            return False
        self.drag_windows.add(frame)
        self.log('owned-drag-window', frame=frame, first_seen_after_move=time.monotonic()-self.drag_first_move_at, pointer=state['pointer'])
        return True

    def remember_drag_windows(self):
        """AX drag images can have empty frames; qualify their own CG window."""
        now = self.state()
        info = json.loads(run(self.native, 'window-info', self.pid))
        current = json.loads(run(self.native, 'windows', self.pid))
        elapsed = time.monotonic() - self.drag_first_move_at
        (self.out/'drag-initial.ax.json').write_text(json.dumps(info, indent=2))
        (self.out/'drag-initial.windows.json').write_text(json.dumps(current, indent=2))
        self.log('drag-initial', after_first_move=elapsed, pointer=now['pointer'])
        if not (self.m1_input_ruling() and '## LEAD 20:32' in self.rulings and elapsed <= 1):
            return
        px,py = now['pointer']
        new = [w for w in current if w['onscreen'] and w['number'] not in self.drag_prior_cg_ids]
        at_pointer = []
        for w in new:
            b = w['bounds']
            if b['X']-16 <= px <= b['X']+b['Width']+16 and b['Y']-16 <= py <= b['Y']+b['Height']+16:
                at_pointer.append(w)
        dialogs = [n for n in walk(info) if n.get('subrole') == 'AXSystemDialog']
        if len(dialogs) <= 1 and len(new) == len(at_pointer) == 1:
            candidate = at_pointer[0]
            if not dialogs and candidate['layer'] < 500:
                return False
            path = self.out/'drag-image-candidate.png'
            self.pixel_run(['/usr/sbin/screencapture','-x','-o','-l',str(candidate['number']),path])
            alpha = json.loads(self.pixel_run([self.native,'image-alpha-bounds',path]))
            bounds = alpha['alphaBounds']; b = candidate['bounds']
            scale = alpha['pixels'][0]/b['Width']
            near = bool(bounds) and b['X']+bounds[0]/scale-16 <= px <= b['X']+(bounds[0]+bounds[2])/scale+16 and b['Y']+bounds[1]/scale-16 <= py <= b['Y']+(bounds[1]+bounds[3])/scale+16
            compact = bool(bounds) and bounds[2]/scale < 600 and bounds[3]/scale < 200
            self.log('drag-image-alpha', result=alpha, drawn_at_pointer=near, compact=compact)
            if near and compact:
                if dialogs:
                    self.drag_windows.add(tuple(dialogs[0].get('frame', [])))
                self.drag_cg_ids.add(candidate['number'])
                self.log('owned-drag-window', cg_window=candidate, first_seen_after_move=elapsed, pointer=now['pointer'])
                return True
        return False

    def observe_download_prompt(self, now, owned_dialog=False):
        # LEAD18:50 requires preserving the owned Arc process so the user can
        # answer Downloads consent. This is only enabled by an explicit script
        # flag and the recorded ruling, after this block requests its fixture.
        system = now['frontmostBundle'] in ('com.apple.SecurityAgent', 'com.apple.systempreferences', 'com.apple.UserNotificationCenter')
        if (self.backend == 'arc' and self.owned and self.pid and self.download_requested_at
                and self.script.get('download_prompt_handoff') is True
                and (system or owned_dialog)):
            if 'LEAD 18:50' not in self.rulings or 'leave Arc RUNNING' not in self.rulings:
                raise Stopped('download prompt handoff lacks the explicit lead ruling')
            self.permission_handoff = {'pid': self.pid, 'download_requested_at': self.download_requested_at,
                                       'observed_at': datetime.datetime.now().astimezone().isoformat(),
                                       'frontmostPID': now['frontmostPID'], 'frontmostBundle': now['frontmostBundle'],
                                       'mouse_button_may_be_down': self.mouse_down,
                                       'dialog_identity': 'unclassified foreground/system AX signal after synthetic download'}
            raise Stopped('unclassified system-window signal after synthetic download; leaving owned Arc running for the user')

    def call(self, cmd, **args):
        if not self.cleaning:
            self.guard(event=cmd in ('key', 'mouse', 'type', 'sidebar-click', 'sidebar-key', 'download-home'))
        dispatched = time.time()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(10)
            conn.connect(self.script['open']['socket'])
            conn.sendall((json.dumps({'id': 1, 'cmd': cmd, 'args': args}) + '\n').encode())
            buf = b''
            while not buf.endswith(b'\n'):
                chunk = conn.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
                if len(buf) > 8 * 1024 * 1024:
                    raise Stopped('automation reply exceeds8MiB')
        reply = json.loads(buf)
        if not reply.get('ok'):
            raise RuntimeError(str(reply.get('error')))
        if self.burst_events is not None and cmd in ('key','mouse','navigate','peek-open','peek-expand','peek-close','little-open-action'):
            self.burst_events.append({'operation':'socket/'+cmd,'start_unix':dispatched,'end_unix':time.time()})
        return reply['result']

    def launch(self, step):
        if self.backend == 'arc':
            if self.script.get('download_prompt_handoff') is True and ('LEAD 18:50' not in self.rulings or 'leave Arc RUNNING' not in self.rulings):
                raise Stopped('download prompt handoff lacks the explicit lead ruling; no app launched')
            pixels = json.loads(self.pixel_run([self.native, 'screen-permission'])) if self.pixel_launcher else {'screenRecording': self.initial['screenRecording']}
            self.log('pixel-permission', context=str(self.pixel_launcher or 'direct'), result=pixels)
            if not self.initial['trusted'] or not pixels['screenRecording']:
                raise Stopped('permission preflight failed; no request made')
            pids = run('/usr/bin/pgrep', '-x', 'Arc') if subprocess.run(['/usr/bin/pgrep', '-x', 'Arc'], capture_output=True).returncode == 0 else ''
            if pids.strip():
                raise Stopped('Arc already running; ownership needs a lead ruling')
            subprocess.run(['/usr/bin/open', '-a', '/Applications/Arc.app'], check=True)
            self.owned = True
            for _ in range(80):
                p = subprocess.run(['/usr/bin/pgrep', '-x', 'Arc'], capture_output=True, text=True)
                if p.returncode == 0:
                    self.pid = int(p.stdout.split()[0])
                    if self.state()['frontmostPID'] == self.pid:
                        break
                time.sleep(.1)
            if not self.pid:
                raise Stopped('Arc did not launch')
        else:
            config = self.script['open']
            sock = Path(config['socket'])
            if sock.exists():
                raise Stopped('Open socket already exists; refusing to attach to another session')
            env = dict(os.environ, OPEN_USER_DATA=config['data_root'], OPEN_SKIP_FIRST_RUN='1', OPEN_E2E_NO_CRASH_PROBES='1', OPEN_E2E_OWNER_PID=str(os.getpid()), OPEN_AUTOMATION_SKIP_MAC_NOTIFICATIONS='1')
            self.app_log = (self.out / 'app.log').open('a')
            self.proc = subprocess.Popen([config['executable'], '--user-data-dir=' + config['data_root'], '--automation-socket=' + config['socket'], '--skip-first-run', '--use-mock-keychain', '--style=chrome', 'about:blank'], env=env, stdout=self.app_log, stderr=subprocess.STDOUT)
            self.pid = self.proc.pid
            self.owned = True
            for _ in range(150):
                if sock.exists():
                    if self.call('ping')['pid'] != self.pid:
                        raise Stopped('Open socket PID mismatch')
                    break
                if self.proc.poll() is not None:
                    raise Stopped('Open exited during launch')
                time.sleep(.1)
            self.call('activate')
            # Direct children need an external exact-PID activation request,
            # as the existing real-App e2e launcher documents. Never renew it
            # after launch or after a foreground interruption.
            activation = json.loads(run(self.native, 'activate', self.pid))
            self.log('initial-activation', result=activation)
            ready = time.monotonic() + 1
            while self.state()['frontmostPID'] != self.pid and time.monotonic() < ready:
                self.guard()
                time.sleep(.02)
            for key in ('open.library.lastSection',):
                self.saved_defaults[key] = self.call('defaults', key=key, persistent=True)
        self.guard(event=True)
        self.log('launched', pid=self.pid)

    def tree(self, include_menus=False):
        if self.backend == 'arc':
            return json.loads(run(self.native, 'ax' if include_menus else 'ax-windows', self.pid))
        # These are real app-side snapshots. They do not constitute a complete
        # AX tree; retain the missing-action finding instead of inventing one.
        result = {'source': 'Open automation socket', 'windows': self.call('windows', accessibility=True), 'children': []}
        for command in ('window-state', 'settings-state', 'space-manager-state', 'space-manager-lifecycle', 'library-captures-state', 'library-history-state', 'downloads-state', 'commandbar-state', 'find-state', 'peek-state', 'little-open-state'):
            try:
                result[command] = self.call(command)
            except RuntimeError as error:
                result[command] = {'unavailable': str(error)}
        return result

    def arc_library_visible(self, tree):
        descriptions = {n.get('desc') for n in walk(tree)
                        if n.get('role') == 'AXButton' and n.get('depth', 99) <= 3}
        return {'Media', 'Downloads', 'Easels', 'Archived Tabs'} <= descriptions

    def target(self, predicate, frame_required=True):
        if predicate.get('source') in ('fixture','fixture-remembered') and self.s2_ruling() and '## LEAD 00:00' in self.rulings:
            actual = {k:v for k,v in predicate.items() if k not in ('source','remember')}
            if predicate['source'] == 'fixture':
                if not self.manual_on or not self.fixture_page:
                    raise Stopped('fixture AX target requires the recorded accessibility mode')
                tree = json.loads(run(self.native,'fixture-web',self.pid,self.fixture_page,timeout=5))
                nodes = [n for n in walk(tree) if matches(n,actual)]
                if len(nodes) != 1 or (frame_required and not nodes[0].get('frame')):
                    raise UnavailableAX('synthetic page AX target is not unique')
                target = nodes[0]
                if predicate.get('remember'):
                    self.fixture_points[predicate['remember']] = {'target':target,'windows':run(self.native,'window-info',self.pid),'url':self.fixture_page}
                return target
            saved = self.fixture_points.get(predicate.get('remember'))
            if not saved or self.manual_on or not matches(saved['target'],actual):
                raise Stopped('no same-block accessibility-off fixture target')
            before = [n.get('frame') for n in walk(json.loads(saved['windows'])) if n.get('role') == 'AXWindow' and n.get('main')]
            after = [n.get('frame') for n in walk(json.loads(run(self.native,'window-info',self.pid))) if n.get('role') == 'AXWindow' and n.get('main')]
            # This native URL field is at depth two. A full sidebar traversal
            # can outlast the movie before the remembered-point click fires.
            current = json.loads(run(self.native,'ax-depth',self.pid,3))
            fields = [n for n in walk(current) if n.get('id') == 'contentPanelTextField' and n.get('value') == saved['url']]
            if before != after or len(fields) != 1:
                raise Stopped('fixture window or active URL changed after AX point resolution')
            return saved['target']
        if predicate.get('source') == 'focused' and self.s2_ruling():
            node = json.loads(run(self.native,'focused',self.pid))
            if not matches(node,{k:v for k,v in predicate.items() if k != 'source'}) or (frame_required and not node.get('frame')):
                raise UnavailableAX('focused synthetic page control did not match')
            return node
        menu = str(predicate.get('role','')).startswith('AXMenu')
        tree = json.loads(run(self.native, 'ax-depth', self.pid, int(predicate['depth']))) if self.backend == 'arc' and not menu and 'depth' in predicate else self.tree(include_menus=menu)
        nodes = [n for n in walk(tree) if matches(n, predicate)
                 and (not frame_required or n.get('frame', [0, 0, 0, 0])[2] > 0)]
        if 'index' in predicate:
            index = int(predicate['index'])
            if index >= len(nodes):
                raise UnavailableAX('AX target index unavailable')
            nodes = [nodes[index]]
        if len(nodes) != 1:
            if not nodes:
                raise UnavailableAX('AX target unavailable')
            raise Stopped('AX target must match exactly one visible element; matched %d' % len(nodes))
        n = nodes[0]
        if n.get('enabled') is False or 'disabled' in n.get('flags', []):
            raise Stopped('AX target is disabled')
        return n

    def m1_input_ruling(self):
        return (self.backend == 'arc' and socket.gethostname().lower().startswith('m1-')
                and '## LEAD 19:30' in self.rulings
                and 'AX-resolved clicks are allowed on the M1 for Arc capture' in self.rulings)

    def s2_ruling(self):
        return self.m1_input_ruling() and self.script.get('capture_scope') == 'session2' and '## LEAD 23:45' in self.rulings

    def synthetic_field(self, text=None):
        focused = json.loads(run(self.native, 'focused', self.pid))
        fields = [focused] if focused.get('focused') and focused.get('role') in ('AXTextField','AXSearchField') else []
        predicates = self.script.get('synthetic_input_targets', [])
        if len(fields) != 1 or not any(matches(fields[0], p) for p in predicates):
            raise Stopped('Session2 input requires one freshly focused observed synthetic field')
        if text is not None and (len(text) > 2048 or text not in [self.expand_fixture(v) for v in self.script.get('synthetic_inputs', [])]):
            raise Stopped('text is absent from the declared synthetic input list')
        return fields[0]

    def expand_fixture(self, value):
        if isinstance(value, str) and self.fixture_site:
            return value.replace('{{fixture}}', self.fixture_site.urls[0]).replace('{{other}}', self.fixture_site.urls[1])
        if isinstance(value, dict):
            return {k:self.expand_fixture(v) for k,v in value.items()}
        if isinstance(value, list):
            return [self.expand_fixture(v) for v in value]
        return value

    def restore_clipboard(self, saved):
        process = subprocess.run([str(self.native),'clipboard-restore',str(saved),str(self.clipboard_expected)],capture_output=True,text=True,timeout=10)
        result = json.loads(process.stdout)
        self.log('clipboard-restore',result=result)
        if process.returncode or not result.get('restored'):
            raise Stopped('clipboard restore refused: '+str(result))
        saved.unlink()
        self.clipboard_expected = None

    def input(self, *args, verified_pointer=False, target_predicate=None):
        self.guard(event=True)
        if args[0] in ('click', 'down', 'dragto', 'key', 'type'):
            if not self.m1_input_ruling():
                raise Stopped('synthetic clicks/keys require the M1 LEAD19:30 ruling')
            if args[0] in ('click', 'down', 'dragto'):
                if not verified_pointer:
                    raise Stopped('pointer clicks require a fresh AX target')
                info = json.loads(run(self.native, 'window-info', self.pid))
                frames = [n['frame'] for n in walk(info) if n.get('role') == 'AXWindow' and n.get('frame')]
                if not any(x <= args[1] < x+w and y <= args[2] < y+h for x,y,w,h in frames):
                    raise Stopped('pointer point is outside the owned AX windows')
                for attempt in range(3):
                    command = [str(self.native), 'point-guard', str(self.pid), str(args[1]), str(args[2])]
                    if '## LEAD 19:52' in self.rulings:
                        command.append('lead-m1-desktop-rule')
                    if '## LEAD 00:15' in self.rulings:
                        command.append('lead-m1-cursor-rule')
                    result = subprocess.run(command, capture_output=True, text=True, timeout=3)
                    check = json.loads(result.stdout)
                    self.log('pointer-point-guard', attempt=attempt, result=check)
                    if not result.returncode and check['ok']:
                        break
                    if not check.get('retryBanner') or attempt == 2 or target_predicate is None:
                        raise Stopped('pointer point is covered or a system window is on screen; no click sent')
                    self.log('banner-wait', seconds=6, retry=attempt+1)
                    time.sleep(6)
                    self.guard(event=True)
                    fresh = self.target(target_predicate)
                    x,y,w,h = fresh['frame']
                    args = (args[0], x+w/2, y+h/2, *args[3:])
                    self.log('pointer-target-after-banner', ax_target=fresh)
            elif args[0] == 'key':
                key, modifiers = args[1].lower(), args[2]
                if self.s2_ruling() and ((key in ('return','tab','left','right','up','down','escape','esc') and modifiers in ('','cmd','shift','opt')) or (key,modifiers) in (('t','cmd'),('l','cmd'),('f','cmd'),('d','cmd'),('w','cmd'))):
                    pass
                elif self.s2_ruling() and (key,modifiers) == ('a','cmd'):
                    self.synthetic_field()
                elif (key not in ('escape', 'esc', 'left', 'right', 'up', 'down', 'return', 'tab') or modifiers) and (key,modifiers) not in (('l','cmd,shift'),('j','cmd,shift'),('y','cmd'),('s','cmd')):
                    raise Stopped('key is outside the approved Arc navigation shortcuts')
            else:
                if self.s2_ruling():
                    self.synthetic_field(str(args[1]))
                else:
                    tree = self.tree()
                    fields = [n for n in walk(tree) if n.get('focused') and n.get('role') == 'AXTextField' and str(n.get('placeholder','')).startswith('Search ')]
                    if not self.arc_library_visible(tree) or len(fields) != 1 or not str(args[1]).startswith('Open-capture-'):
                        raise Stopped('typing requires one focused Library search and a synthetic capture string')
            self.guard(event=True)
        elif args[0] not in ('move', 'scroll', 'drag', 'dragto', 'down', 'up'):
            raise Stopped('unsupported system input')
        if args[0] == 'type':
            # uidrive posts two events per UTF-16 unit at 20 ms per unit.
            # Bound each batch, and recheck ownership before continuing.
            text = str(args[1])
            for offset in range(0, len(text), 96):
                self.guard(event=True)
                if self.s2_ruling():
                    self.synthetic_field()
                dispatched = time.time()
                run(SCRIPTS / 'uidrive', 'type', text[offset:offset+96])
                if self.burst_events is not None:
                    self.burst_events.append({'operation':'type','start_unix':dispatched,'end_unix':time.time()})
        else:
            dispatched = time.time()
            run(SCRIPTS / 'uidrive', *args)
            if self.burst_events is not None:
                self.burst_events.append({'operation':args[0],'start_unix':dispatched,'end_unix':time.time()})

    def ax_action(self, predicate, action='AXPress', value=None):
        self.guard(event=True)
        command = [str(self.native), 'act', str(self.pid), json.dumps(predicate), action]
        if value is not None:
            command.append(str(value))
        dispatched = time.time()
        result = subprocess.run(command, capture_output=True, text=True, timeout=9)
        if self.burst_events is not None:
            self.burst_events.append({'operation':action,'start_unix':dispatched,'end_unix':time.time()})
        reply = json.loads(result.stdout) if result.stdout.strip() else {'ok': False, 'exit': result.returncode}
        self.log('ax-action', action=action, reply=reply)
        if result.returncode or not reply.get('ok'):
            if result.returncode == 4 or reply.get('result') in (-25205, -25206, -25208):
                raise UnavailableAX('AX target/action unavailable: %s; matches=%s' % (action, reply.get('matches')))
            raise Stopped('AX action unavailable: %s, code %s' % (action, reply.get('result', result.returncode)))
        return reply

    def shot(self, name, ax_depth=None):
        before_state = self.guard()
        path = self.out / (name + '.png')
        def snapshot_tree():
            if self.backend == 'arc' and ax_depth is not None:
                if not 0 <= int(ax_depth) <= 12:
                    raise Stopped('shot AX depth must be between0 and12')
                return json.loads(run(self.native, 'ax-depth', self.pid, int(ax_depth)))
            return self.tree()
        tree = snapshot_tree()
        (self.out / (name + '.ax.json')).write_text(json.dumps(tree, indent=2))
        if self.backend == 'arc':
            wins = json.loads(run(self.native, 'windows', self.pid))
            (self.out / (name + '.windows.json')).write_text(json.dumps(wins, indent=2))
            wins = [w for w in wins if w['bounds']['Width'] > 2 and w['bounds']['Height'] > 2]
            if not wins:
                raise Stopped('no owned visible window')
            ax_main = [n['frame'] for n in walk(tree) if n.get('role') == 'AXWindow' and n.get('main') and n.get('frame')]
            matched = [w for w in wins if any(all(abs(w['bounds'][key] - value) < 2 for key,value in zip(('X','Y','Width','Height'),f)) for f in ax_main)]
            base = matched or [w for w in wins if w['layer'] == 0 and w['bounds']['Width'] > 100]
            if not base:
                raise Stopped('no owned browser window matched the AX geometry')
            win = next((w for w in wins if w['number'] == self.window), None) or max(base, key=lambda w: w['bounds']['Width'] * w['bounds']['Height'])
            self.active_window = win['number']
            self.pixel_run(['/usr/sbin/screencapture', '-x', '-o', '-l', str(win['number']), str(path)])
            before = tree
            tree = snapshot_tree()
            (self.out / (name + '.ax-before.json')).write_text(json.dumps(before, indent=2))
            metadata = {'window': win, 'screens': self.initial['screens'],
                        'observedSurface': 'transition across PNG capture' if self.arc_library_visible(before) != self.arc_library_visible(tree) else 'library' if self.arc_library_visible(tree) else 'browser or other'}
            # Context menus/popovers are separate windows. Preserve each own
            # visible window as a native-scale PNG, never the whole desktop.
            for extra in wins:
                if extra['number'] != win['number'] and extra['onscreen']:
                    self.pixel_run(['/usr/sbin/screencapture', '-x', '-o', '-l', str(extra['number']), str(self.out / (name + '-window-' + str(extra['number']) + '.png'))])
        else:
            metadata = self.open_pixels(path, tree)
        (self.out / (name + '.ax.json')).write_text(json.dumps(tree, indent=2))
        metadata['captureGaps'] = self.gaps
        metadata['accessibilityOn'] = self.manual_on
        metadata['frontmostBeforeCapture'] = {k:before_state[k] for k in ('frontmostPID','frontmostBundle')}
        after_state = self.state()
        metadata['frontmostAfterCapture'] = {k:after_state[k] for k in ('frontmostPID','frontmostBundle')}
        if ax_depth is not None:
            metadata['axDepthLimit'] = ax_depth
        (self.out / (name + '.meta.json')).write_text(json.dumps(metadata, indent=2))
        self.log('shot', frame_file=str(path), ax_file=name + '.ax.json')
        return path

    def open_pixels(self, path, tree):
        kwargs = {'window': self.window} if self.window is not None else {}
        metadata = {'method': 'approved launcher own-window screencapture'} if self.pixel_launcher else self.call('snapshot', path=str(path), **kwargs)
        number = self.window
        if number is None:
            little = [s for s in tree.get('little-open-state',{}).get('sessions',[]) if s.get('key') and s.get('visible')]
            if len(little) == 1:
                number = little[0]['window']
        if number == 'library':
            number = tree.get('library-captures-state', {}).get('window')
        candidates = [w for w in tree.get('windows', [])
                      if w.get('number') == number] if number is not None else [w for w in tree.get('windows', []) if w.get('main')]
        if len(candidates) == 1:
            owned = candidates[0]
            rect = [float(v) for v in re.findall(r'-?\d+(?:\.\d+)?', owned.get('frame', ''))]
            if len(rect) == 4:
                x, y, w, h = rect
                top = max(s['frame'][1] + s['frame'][3] for s in self.initial['screens'])
                metadata['window'] = {'number': owned['number'], 'bounds': {'X': x, 'Y': top - y - h, 'Width': w, 'Height': h}}
                metadata['screens'] = self.initial['screens']
                self.active_window = owned['number']
                if self.pixel_launcher:
                    self.pixel_run(['/usr/sbin/screencapture', '-x', '-o', '-l', str(owned['number']), str(path)])
        if 'window' not in metadata:
            if self.pixel_launcher:
                raise Stopped('Open: no unique own window for the pixel launcher')
            metadata['geometryQualification'] = 'Open window geometry could not be paired; do not infer scale'
        library = tree.get('library-captures-state', {})
        metadata['observedSurface'] = 'library/' + str(library.get('section')) if library.get('visible') and metadata.get('window', {}).get('number') == library.get('window') else 'browser or other'
        return metadata

    def burst(self, step):
        if step.get('format','png') not in ('png','movie'):
            raise Stopped('burst format must be png or movie')
        if step.get('scope','window') not in ('window','application'):
            raise Stopped('burst scope must be window or application')
        before = self.shot(step['name'] + '-before', step.get('ax_depth'))
        directory = self.out / step['name']
        directory.mkdir(exist_ok=True)
        (directory/'capture-context.json').write_text(json.dumps({
            'accessibilityOn':self.manual_on,'scope':step.get('scope','window'),
            'event_qualification':'UNQUALIFIED: recorder or trigger did not finish'}))
        fps = min(float(step.get('fps', 20)), 120)
        duration = min(float(step.get('duration', 1)), 5)
        stream_tool = self.burst_tool
        if (self.backend == 'arc' or self.pixel_launcher) and stream_tool.exists():
            self.guard(event=True)
            log = (directory / 'stream.log').open('a')
            command, pixel_log = self.pixel_command([str(stream_tool), str(self.pid), str(self.active_window), str(directory), str(int(fps)), str(duration), str(self.initial['screens'][0]['scale']), step.get('format', 'png'),step.get('scope','window')])
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            try:
                ready_deadline = time.monotonic() + 4
                while not (directory / 'ready').exists():
                    self.guard(event=True)
                    if process.poll() is not None or time.monotonic() > ready_deadline:
                        raise Stopped('window stream did not become ready; inspect stream.log')
                    time.sleep(.02)
                self.burst_before, self.burst_events = before, []
                self.log('burst-ready', name=step['name'], observed_unix=time.time())
                time.sleep(float(step.get('trigger_after', .15)))
                if step.get('trigger'):
                    self.step(step['trigger'])
                result = process.wait(timeout=8)
                if result:
                    raise Stopped('window stream stopped; exit %d' % result)
                self.pixel_result(pixel_log)
                receipt = json.loads((directory/'timestamps.json').read_text())
                frames = receipt.get('frames', [])
                start = receipt.get('started_unix')
                span = [start + f['presentation_seconds'] - receipt['started_monotonic'] for f in (frames[:1]+frames[-1:])] if start is not None and frames else []
                captured = bool(span and self.burst_events) and all(span[0] <= e['start_unix'] <= e['end_unix'] <= span[-1]-.1 for e in self.burst_events)
                context = {'accessibilityOn':self.manual_on,'scope':step.get('scope','window'),
                           'event_intervals':self.burst_events,'recorded_unix_interval':span,
                           'event_qualification':'dispatch interval captured; inspect visible result' if captured else 'UNQUALIFIED: no dispatch interval with100ms recorded afterward',
                           'clock_qualification':'same-host wall-clock mapping of capture PTS; not an input-latency measurement'}
                (directory/'capture-context.json').write_text(json.dumps(context,indent=2))
                if step.get('trigger') and not captured:
                    if self.backend == 'open' and not self.burst_events:
                        gap = {'step':step['trigger'],'finding':'Open: no action; movie trigger unavailable'}
                        self.gaps.append(gap)
                        self.log('no-action',operation=step['trigger'],finding=gap['finding'])
                    else:
                        raise Stopped('movie did not contain the trigger dispatch interval and100ms afterward')
                self.log('burst', method='ScreenCaptureKit', receipt=str(directory / 'timestamps.json'))
            finally:
                self.burst_before, self.burst_events = None, None
                if process.poll() is None:
                    # The recorder has its own five-second bound. Let the fixed
                    # launcher reap it even when the AX side stops early.
                    process.wait(timeout=10)
                log.close()
            self.shot(step['name'] + '-after', step.get('ax_depth'))
            return
        start = time.monotonic()
        frames = []
        fired = False
        for i in range(max(1, int(fps * duration))):
            self.guard()
            if not fired and time.monotonic() - start >= float(step.get('trigger_after', .15)):
                if step.get('trigger'):
                    self.step(step['trigger'])
                fired = True
            before = time.monotonic()
            path = directory / ('%04d.png' % i)
            if self.backend == 'arc':
                self.pixel_run(['/usr/sbin/screencapture', '-x', '-o', '-l', str(self.active_window), str(path)])
            else:
                self.open_pixels(path, self.tree())
            after = time.monotonic()
            frames.append({'frame': path.name, 'start': before, 'end': after, 'elapsed': (before + after) / 2 - start, 'uncertainty': (after - before) / 2})
            if after - start >= duration:
                break
            time.sleep(max(0, start + (i + 1) / fps - time.monotonic()))
        (directory / 'timestamps.json').write_text(json.dumps({'requested_fps': fps, 'duration': duration, 'frames': frames, 'effective_fps': (len(frames) - 1) / max(.001, frames[-1]['elapsed'] - frames[0]['elapsed']) if len(frames) > 1 else 0}, indent=2))
        self.shot(step['name'] + '-after')

    def step(self, step):
        self.guard()
        step = self.expand_fixture(step)
        op = step['op']
        self.log('begin', operation=step)
        # A mapping is explicit. The same declarative script runs both apps.
        mapping = step.get('open') if self.backend == 'open' else None
        if self.backend == 'open' and op not in ('launch', 'shot', 'axdump', 'burst', 'sleep', 'fixture_download', 'fixture_site') and mapping is None:
            self.gaps.append({'step': step, 'finding': 'Open: no action'})
            self.log('no-action', operation=step, finding='Open: no action')
            return
        if mapping is not None:
            for action in mapping if isinstance(mapping, list) else [mapping]:
                self.guard(event=True)
                args = dict(action.get('args', {}))
                if action.get('lookup') in ('little-open-window','little-open-session'):
                    sessions = self.call('little-open-state')['sessions']
                    if len(sessions) != 1:
                        raise Stopped('Open: no unique Little Open session')
                    args['window' if action['lookup'] == 'little-open-window' else 'id'] = sessions[0]['window' if action['lookup'] == 'little-open-window' else 'id']
                if action['cmd'] == 'appearance' and self.saved_appearance is None:
                    self.saved_appearance = self.call('space-manager-lifecycle')['appAppearance']
                    self.log('appearance-before-change', value=self.saved_appearance)
                if action.get('lookup') == 'library-section':
                    geometry = self.call('space-manager-lifecycle')
                    found = [row for row in geometry['sectionRows'] if row['section'] == action['section']]
                    if len(found) != 1:
                        raise Stopped('Open: no unique section in automation snapshot')
                    args.update(window=self.call('library-captures-state')['window'], x=found[0]['point'][0], y=found[0]['point'][1])
                    self.log('socket-target', target=found[0])
                self.call(action['cmd'], **args)
            if 'window' in step:
                self.window = step['window']
        elif op == 'launch':
            self.launch(step)
        elif op == 'paste':
            if not self.s2_ruling():
                raise Stopped('paste requires the M1 Session2 ruling')
            self.synthetic_field(step['text'])
            saved = self.out/'clipboard-private.json'
            if not saved.exists():
                run(self.native,'clipboard-save',saved)
            self.clipboard_expected = json.loads(run(self.native,'clipboard-set',step['text']))['changeCount']
            # Read again after the short-lived writer exits. The pasteboard
            # service can publish its final generation at that boundary.
            published = json.loads(run(self.native,'clipboard-check',step['text']))
            self.log('clipboard-publication', writer_count=self.clipboard_expected, published=published)
            if not published['matchesExpected']:
                raise Stopped('clipboard changed before the synthetic paste')
            self.clipboard_expected = published['changeCount']
            self.guard(event=True)
            run(SCRIPTS/'uidrive','key','v','cmd')
            deadline = time.monotonic()+2
            while self.synthetic_field().get('value') != step['text']:
                self.guard(event=True)
                if time.monotonic() >= deadline:
                    raise Stopped('synthetic paste was not observed within2s')
                time.sleep(.05)
            # Restore as soon as the target proves it consumed the paste.
            # A later clipboard owner still wins the change-counter check.
            self.restore_clipboard(saved)
        elif op == 'focused_dump':
            (self.out/(step['name']+'.focused.json')).write_text(run(self.native,'focused',self.pid))
        elif op == 'manual_accessibility':
            if not self.s2_ruling() or '## LEAD 00:00' not in self.rulings:
                raise Stopped('manual accessibility needs the narrow lead ruling')
            self.guard(event=True)
            if self.manual_original is None:
                original = json.loads(run(self.native,'manual-accessibility',self.pid))
                self.manual_original = original['value']
                if not original.get('readable'):
                    if '## LEAD 00:15' not in self.rulings:
                        raise Stopped('manual accessibility original is unreadable')
                    self.manual_original = 'unreadable (write-only)'
                self.log('manual-accessibility-original',value=self.manual_original)
            enabled = bool(step['enabled'])
            if enabled:
                url = step['url']
                if not self.fixture_site or not url.startswith(tuple(u+'/' for u in self.fixture_site.urls)) or not any(n.get('id') == 'contentPanelTextField' and n.get('value') == url for n in walk(self.tree())):
                    raise Stopped('manual accessibility needs the actual active synthetic page')
                self.fixture_page = url
            result = json.loads(run(self.native,'manual-accessibility',self.pid,str(enabled).lower()))
            if not result.get('setSucceeded') or (result.get('readable') and result['value'] != enabled):
                raise Stopped('manual accessibility change was not verified')
            self.manual_on = enabled
            self.log('manual-accessibility',value=enabled,verification=result['verification'])
        elif op == 'fixture_web':
            if not self.manual_on or not self.fixture_page:
                raise Stopped('fixture web query needs accessibility on')
            (self.out/(step['name']+'.web.ax.json')).write_text(run(self.native,'fixture-web',self.pid,self.fixture_page,timeout=5))
        elif op == 'copy_fixture_url':
            expected = step['url']
            if not self.s2_ruling() or not self.fixture_site or not expected.startswith(tuple(u+'/' for u in self.fixture_site.urls)):
                raise Stopped('copy URL requires the Session2 synthetic fixture')
            current = json.loads(run(self.native,'ax-depth',self.pid,3))
            fields = [n for n in walk(current) if n.get('id') == 'contentPanelTextField' and n.get('value') == expected]
            if len(fields) != 1:
                raise Stopped('copy URL requires the actual current synthetic URL field')
            saved = self.out/'clipboard-private.json'
            if saved.exists():
                raise Stopped('previous clipboard preservation is still pending')
            run(self.native,'clipboard-save',saved)
            self.ax_action({'role':'AXButton','identifier':'copyLinkButton','depth':2})
            deadline = time.monotonic()+2
            while True:
                self.guard(event=True)
                check = json.loads(run(self.native,'clipboard-check',expected))
                if check['matchesExpected']:
                    self.clipboard_expected = check['changeCount']
                    break
                if time.monotonic() >= deadline:
                    raise Stopped('copy did not produce the synthetic URL within2s')
                time.sleep(.05)
            self.restore_clipboard(saved)
        elif op == 'fixture_site':
            if self.fixture_site is not None:
                raise Stopped('one synthetic site per block')
            from fixture import SyntheticSite
            self.fixture_site = SyntheticSite(int(step.get('port',39171)), int(step.get('other_port',39172)))
            self.log('fixture-site', urls=self.fixture_site.urls)
        elif op == 'external_fixture':
            if not self.fixture_site or not step['url'].startswith(tuple(u+'/' for u in self.fixture_site.urls)):
                raise Stopped('external link must use the owned synthetic fixture')
            self.guard(event=True)
            dispatched = time.time()
            run('/usr/bin/open', '-a', '/Applications/Arc.app', step['url'])
            if self.burst_events is not None:
                self.burst_events.append({'operation':'external-fixture','start_unix':dispatched,'end_unix':time.time()})
        elif op == 'fixture_download':
            self.guard(event=True)
            if self.fixture_server is not None:
                raise Stopped('one synthetic download fixture per block')
            filename = 'Open-capture-synthetic-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '.txt'
            seed = b'Open synthetic capture fixture. No personal data.\n'
            size = int(step.get('bytes', len(seed)))
            duration = float(step.get('transfer_seconds', 0))
            if not len(seed) <= size <= 524288 or not 0 <= duration <= 20:
                raise Stopped('synthetic download must be at most512KiB and20seconds')
            payload = (seed * ((size + len(seed) - 1) // len(seed)))[:size]
            chunks = max(1, round(duration * 8))
            chunk_bytes = max(1, (size + chunks - 1) // chunks)
            class Fixture(BaseHTTPRequestHandler):
                def do_GET(handler):
                    handler.send_response(200)
                    handler.send_header('Content-Type', 'application/octet-stream')
                    handler.send_header('Content-Disposition', 'attachment; filename="' + filename + '"')
                    handler.send_header('Content-Length', str(len(payload)))
                    handler.end_headers()
                    try:
                        for offset in range(0, size, chunk_bytes):
                            handler.wfile.write(payload[offset:offset+chunk_bytes])
                            handler.wfile.flush()
                            if duration:
                                time.sleep(duration / chunks)
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                def log_message(handler, *args):
                    pass
            self.fixture_server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
            threading.Thread(target=self.fixture_server.serve_forever, daemon=True).start()
            url = 'http://127.0.0.1:%d/%s' % (self.fixture_server.server_port, filename)
            self.log('fixture-download', filename=filename, url=url, bytes=size, transfer_seconds=duration)
            if self.backend == 'arc':
                self.guard(event=True)
                run('/usr/bin/open', '-a', '/Applications/Arc.app', url)
                self.download_requested_at = datetime.datetime.now().astimezone().isoformat()
            else:
                self.guard(event=True)
                self.call('navigate', url=url)
        elif op == 'ensure_window':
            deadline = time.monotonic() + 4
            while True:
                self.guard(event=True)
                info = json.loads(run(self.native, 'window-info', self.pid))
                windows = [n for n in walk(info) if n.get('role') == 'AXWindow']
                if windows or time.monotonic() >= deadline:
                    break
                self.log('window-query-retry', windowQueryError=info.get('windowQueryError'),
                         mainWindowQueryError=info.get('mainWindowQueryError'))
                time.sleep(.2)
            (self.out / 'startup-windows.ax.json').write_text(json.dumps(info, indent=2))
            (self.out / 'startup-windows.cg.json').write_text(run(self.native, 'windows', self.pid))
            if not windows:
                if info.get('partial'):
                    raise Stopped('AX window list is partial; no New Window action sent')
                self.ax_action({'role': 'AXMenuItem', 'identifier': 'newWindow'})
                time.sleep(.3)
        elif op == 'ensure_surface':
            desired = step['surface'] == 'library'
            # A previous AX menu press can still be animating. Observe its
            # result before deciding whether another toggle is needed.
            time.sleep(.35)
            if self.arc_library_visible(self.tree()) != desired:
                title = r're:^(Open Library…|View Library)$' if desired else 'Close Library'
                self.ax_action({'role': 'AXMenuItem', 'title': title})
            deadline = time.monotonic() + 3
            while self.arc_library_visible(self.tree()) != desired:
                self.guard()
                if time.monotonic() >= deadline:
                    raise Stopped('requested Arc surface not observed')
                time.sleep(.05)
        elif op in ('click_ax', 'show_menu_ax', 'focus_ax', 'raise_ax', 'set_ax', 'select_ax', 'cancel_ax'):
            action = {'click_ax':'AXPress', 'show_menu_ax':'AXShowMenu', 'focus_ax':'focus', 'raise_ax':'AXRaise', 'set_ax':'value', 'select_ax':'selected', 'cancel_ax':'AXCancel'}[op]
            if step.get('restore') and step['restore'] not in self.restore_actions:
                # The script must name an observed original state. Register it
                # before changing appearance so an interrupted block restores it.
                original = step['restore'].get('original')
                if not original or sum(matches(n, original) for n in walk(self.tree(include_menus=True))) != 1:
                    if not (self.m1_input_ruling() and step['restore']['target'].get('identifier') == '_NS:640'):
                        raise Stopped('original AX state not verified; no temporary change sent')
                    self.log('appearance-original-note', note='Automatic checkmark unavailable; LEAD19:30 permits the view change and requests Automatic at session end')
                self.restore_actions.append(step['restore'])
                self.log('restore-registered', action=step['restore'])
            try:
                self.ax_action(step['target'], action, step.get('text'))
            except UnavailableAX as error:
                if not step.get('optional'):
                    raise
                self.gaps.append({'step': step, 'finding': 'Arc: not captured; ' + str(error)})
                self.log('not-captured', operation=step, reason=str(error))
        elif op == 'pointer_ax':
            if not self.m1_input_ruling() or step.get('expect') not in ('change', 'menu') or not step.get('name'):
                raise Stopped('M1 pointer click needs the lead ruling, a named frame and an expected result')
            if step.get('button','left') not in ('left','right') or int(step.get('count',1)) not in (1,2):
                raise Stopped('one verified left/right click or double-click is allowed')
            # A burst already captured its before frame before starting the
            # recorder. A second AX/PNG pass can outlast a short movie.
            before = self.burst_before or self.shot(step['name'] + '-before', step.get('ax_depth'))
            n = self.target(step['target'])
            x,y,w,h = n['frame']
            window_info = json.loads(run(self.native, 'window-info', self.pid))
            windows = [e['frame'] for e in walk(window_info) if e.get('role') == 'AXWindow' and e.get('frame')]
            point = (x+w/2,y+h/2)
            if not any(a <= point[0] < a+c and b <= point[1] < b+d for a,b,c,d in windows):
                raise Stopped('fresh AX target centre is outside the owned AX windows')
            self.log('pointer-target', ax_target=n, expected=step['expect'])
            self.input('click', *point, step.get('button','left'), int(step.get('count',1)), verified_pointer=True, target_predicate=step['target'])
            deadline = time.monotonic() + 2
            if step['expect'] == 'menu':
                old_ids = {w['number'] for w in json.loads(before.with_suffix('.windows.json').read_text()) if w['onscreen']}
                while True:
                    self.guard(event=True)
                    wins = json.loads(run(self.native, 'windows', self.pid))
                    appeared = any(w['number'] not in old_ids and w['onscreen'] and w['bounds']['Width'] >= 100 and w['bounds']['Height'] >= 40 for w in wins)
                    if not appeared:
                        scoped = json.loads(run(self.native, 'ax-depth', self.pid, 3))
                        appeared = any(e.get('role') in ('AXMenu','AXMenuItem') for e in walk(scoped))
                    if appeared and time.monotonic() <= deadline:
                        self.log('pointer-result', appeared=True, observed_before_deadline=True)
                        self.shot(step['name'], step.get('ax_depth'))
                        break
                    if time.monotonic() >= deadline:
                        self.shot(step['name'], step.get('ax_depth'))
                        raise Stopped('expected pointer menu not observed within2s; no further click sent')
                    time.sleep(.05)
                self.log('end', operation=op)
                return
            while True:
                after = self.shot(step['name'], step.get('ax_depth'))
                self.guard(event=True)
                tree = json.loads(after.with_suffix('.ax.json').read_text())
                if step['expect'] == 'menu':
                    appeared = any(e.get('role') in ('AXMenu','AXMenuItem') for e in walk(tree))
                    wins = json.loads(after.with_suffix('.windows.json').read_text())
                    old = json.loads(before.with_suffix('.windows.json').read_text())
                    old_ids = {w['number'] for w in old if w['onscreen']}
                    appeared = appeared or any(w['number'] not in old_ids and w['onscreen'] and w['bounds']['Width'] >= 100 and w['bounds']['Height'] >= 40 for w in wins)
                else:
                    difference = json.loads(self.pixel_run([self.native,'image-change',before,after]))
                    self.log('pointer-result-image-change', result=difference)
                    appeared = difference['meanDifference'] > .001
                if appeared and time.monotonic() <= deadline:
                    self.log('pointer-result', appeared=True)
                    break
                if time.monotonic() >= deadline:
                    raise Stopped('expected pointer result not observed within2s; no further click sent')
                time.sleep(.05)
        elif op in ('hover_ax', 'down_ax', 'scroll'):
            try:
                n = self.target(step['target'])
            except UnavailableAX as error:
                if not step.get('optional'):
                    raise
                self.gaps.append({'step': step, 'finding': 'Arc: not captured; ' + str(error)})
                self.log('not-captured', operation=step, reason=str(error))
                return
            x, y, w, h = n['frame']
            self.log('target', ax_target=n)
            if op == 'scroll':
                self.input('scroll', step['dy'], step.get('dx', 0), x + w / 2, y + h / 2)
            elif op == 'down_ax':
                if not step.get('name') or step.get('expect') != 'change':
                    raise Stopped('drag start requires named before/after evidence and a two-second change check')
                before = self.shot(step['name'] + '-before', step.get('ax_depth'))
                n = self.target(step['target'])
                x,y,w,h = n['frame']
                info = json.loads(run(self.native, 'window-info', self.pid))
                self.drag_prior_frames = {tuple(e['frame']) for e in walk(info) if e.get('role') == 'AXWindow' and e.get('frame')}
                self.drag_windows.clear()
                self.drag_cg_ids.clear()
                self.drag_prior_cg_ids = {e['number'] for e in json.loads(run(self.native, 'windows', self.pid)) if e['onscreen']}
                self.input('down', x + w / 2, y + h / 2, verified_pointer=True, target_predicate=step['target'])
                self.mouse_down = True
                deadline = time.monotonic() + 2
                drag_observed = False
                if step.get('drag'):
                    # Start a drag inside the same fresh target, then hold it.
                    # Never drop onto another app or a guessed destination.
                    self.drag_first_move_at = time.monotonic()
                    self.input('dragto', x + w / 2 + min(8,w/4), y + h / 2, 2, .1, verified_pointer=True)
                    drag_observed = self.remember_drag_windows() and time.monotonic() <= deadline
                after = self.shot(step['name'], step.get('ax_depth'))
                self.guard(event=True)
                difference = json.loads(self.pixel_run([self.native,'image-change',before,after]))
                appeared = drag_observed or (difference['meanDifference'] > .001 and time.monotonic() <= deadline)
                self.log('drag-start-result', appeared=appeared, result=difference)
                if not appeared:
                    raise Stopped('expected drag-start result not observed within2s')
            else:
                self.input('move' if op == 'hover_ax' else 'click', x + w / 2, y + h / 2, *([] if op == 'hover_ax' else [step.get('button', 'left'), step.get('count', 1)]))
        elif op == 'key':
            self.input('key', step['key'], ','.join(step.get('modifiers', [])))
        elif op == 'mouse_up':
            self.input('up')
            self.mouse_down = False
        elif op == 'resize':
            self.guard(event=True)
            windows = [n for n in walk(self.tree()) if n.get('role') == 'AXWindow' and n.get('main') and n.get('frame')]
            if len(windows) != 1:
                raise Stopped('resize needs one verified main AX window')
            frame = windows[0]['frame']
            self.original_frame = self.original_frame or frame
            self.log('frame-before-resize', frame=frame)
            desired = self.original_frame if step.get('original') else [frame[0], frame[1], step['width'], step.get('height',frame[3])]
            result = json.loads(run(self.native, 'set-frame', self.pid, *desired))
            self.log('resize-result', result=result)
            if any(result.values()):
                raise Stopped('AX resize refused')
        elif op == 'type':
            # Require a real focused text field before Unicode events.
            if self.s2_ruling():
                self.synthetic_field(step['text'])
            elif not any(n.get('focused') and n.get('role') in ('AXTextField', 'AXTextArea', 'AXComboBox', 'AXSearchField') for n in walk(self.tree())):
                raise Stopped('no verified focused text input')
            self.input('type', step['text'])
        elif op == 'wait_ax':
            end = time.monotonic() + min(float(step.get('timeout', 5)), 10)
            while True:
                try:
                    self.target(step['target'], frame_required=False)
                    break
                except Stopped:
                    if time.monotonic() >= end:
                        raise
                    self.guard()
                    time.sleep(.1)
        elif op == 'shot':
            self.shot(step['name'], step.get('ax_depth'))
        elif op == 'axdump':
            if self.backend == 'arc':
                (self.out / (step['name'] + '.windows.json')).write_text(run(self.native, 'windows', self.pid))
            (self.out / (step['name'] + '.ax.json')).write_text(json.dumps(self.tree(include_menus=True), indent=2))
        elif op == 'burst':
            self.burst(step)
        elif op == 'sleep':
            time.sleep(min(float(step['seconds']), 5))
        else:
            raise ValueError('unknown operation ' + op)
        self.log('end', operation=op)

    def cleanup(self):
        self.cleaning = True
        if self.mouse_down and self.m1_input_ruling() and '## LEAD 20:32' in self.rulings:
            # The lead explicitly requires ending our held gesture before
            # any stop/handoff. Do not route Esc to a foreign foreground app.
            try:
                now = self.state()
                if now['frontmostPID'] == self.pid:
                    run(SCRIPTS / 'uidrive', 'key', 'escape', '')
                    self.log('held-drag-cancel-escape')
                else:
                    self.log('held-drag-escape-skipped', reason='foreign foreground app')
                run(SCRIPTS / 'uidrive', 'up')
                self.mouse_down = False
                if self.permission_handoff is not None:
                    self.permission_handoff['mouse_button_may_be_down'] = False
                self.log('held-drag-released', ruling='LEAD20:32; end only our pending gesture')
            except Exception as error:
                self.cleanup_ok = False
                self.log('held-drag-release-incomplete', error=str(error))
        clipboard = self.out/'clipboard-private.json'
        if clipboard.exists():
            try:
                self.restore_clipboard(clipboard)
            except Exception as error:
                self.cleanup_ok = False
                self.log('clipboard-restore-incomplete',error=str(error))
            finally:
                clipboard.unlink(missing_ok=True)
        if self.fixture_site is not None:
            self.fixture_site.close()
        if self.manual_original is not None and self.pid:
            try:
                desired = self.manual_original if isinstance(self.manual_original,bool) else False
                result = json.loads(run(self.native,'manual-accessibility',self.pid,str(desired).lower()))
                self.log('manual-accessibility-restore',result=result)
                self.cleanup_ok = self.cleanup_ok and result.get('setSucceeded',False) and (not result.get('readable') or result['value'] == desired)
            except Exception as error:
                self.cleanup_ok = False
                self.log('manual-accessibility-restore-incomplete',error=str(error))
        if self.fixture_server is not None:
            self.fixture_server.shutdown()
            self.fixture_server.server_close()
        # Never send a key to quit. NSRunningApplication.terminate is addressed
        # to the captured PID and cannot type in a user's new frontmost app.
        now = self.state()
        if self.permission_handoff is None:
            try:
                self.observe_download_prompt(now)
            except Stopped as error:
                self.log('STOP', reason=str(error))
        if self.permission_handoff is not None:
            # Do not restore the pointer/app, resize, send AX actions or quit.
            # Release the screen slot with the prompt and exact owned PID intact.
            elapsed = time.monotonic() - self.started
            self.cleanup_ok = elapsed <= 170
            (self.out / 'arc-permission-handoff.json').write_text(json.dumps(self.permission_handoff, indent=2))
            (self.out / 'no-actions.json').write_text(json.dumps(self.gaps, indent=2))
            self.log('cleanup', final=now, arc_version=self.arc_version(), elapsed=elapsed,
                     ok=self.cleanup_ok, status='permission handoff; capture incomplete',
                     owned_arc_left_running=self.pid)
            self.logfile.close()
            return
        if self.backend == 'arc' and now['frontmostPID'] == self.pid:
            if self.mouse_down:
                try:
                    self.guard(event=True)
                    run(SCRIPTS / 'uidrive', 'up')
                except Exception as error:
                    self.cleanup_ok = False
                    self.log('mouse-release-incomplete', error=str(error))
            for action in reversed(self.restore_actions):
                try:
                    original = action['original']
                    if sum(matches(n, original) for n in walk(self.tree(include_menus=True))) == 1:
                        self.log('restore-ax', status='original state already present', original=original)
                        continue
                    result = self.ax_action(action['target'], action.get('action', 'AXPress'), action.get('text'))
                    deadline = time.monotonic() + 2
                    while True:
                        self.guard(event=True)
                        verified = sum(matches(n, original) for n in walk(self.tree(include_menus=True))) == 1
                        if verified or time.monotonic() >= deadline:
                            break
                        time.sleep(.1)
                    self.log('restore-ax', result=result, verified=verified, original=original)
                    if not verified and self.m1_input_ruling() and action['target'].get('identifier') == '_NS:640':
                        checked = [n.get('title') for n in walk(self.tree(include_menus=True)) if n.get('id') in ('_NS:640','_NS:1121','_NS:305') and n.get('mark')]
                        self.log('appearance-restore-note', note='appearance left at Light' if 'Light' in checked else 'Automatic checkmark not observed after2s; M1 view preference only', checked=checked)
                    elif not verified:
                        self.cleanup_ok = False
                        self.log('restore-ax-incomplete', error='original AX state not observed after restoration')
                except Exception as error:
                    self.cleanup_ok = False
                    self.log('restore-ax-incomplete', error=str(error))
            if self.original_frame:
                try:
                    result = json.loads(run(self.native, 'set-frame', self.pid, *self.original_frame))
                    self.cleanup_ok = self.cleanup_ok and not any(result.values())
                    self.log('restore-frame', result=result)
                except Exception as error:
                    self.cleanup_ok = False
                    self.log('restore-frame-incomplete', error=str(error))
            if self.state()['frontmostPID'] == self.pid:
                try:
                    self.guard(event=True)
                    run(SCRIPTS / 'uidrive', 'move', *self.initial['pointer'])
                except Exception as error:
                    self.cleanup_ok = False
                    self.log('pointer-restore-incomplete', error=str(error))
            else:
                self.log('pointer-restore-skipped', reason='foreground takeover during cleanup')
        elif self.backend == 'arc':
            self.log('pointer-restore-skipped', reason='foreground takeover; no more system events')
        before_quit = self.state()
        if self.owned and self.pid:
            if self.backend == 'arc':
                try:
                    run(self.native, 'quit', self.pid)
                except Exception as error:
                    self.cleanup_ok = False
                    self.log('quit-error', error=str(error))
            else:
                try:
                    for key, value in self.saved_defaults.items():
                        self.call('defaults', key=key, value=value)
                    if self.saved_appearance is not None:
                        original = 'dark' if 'Dark' in self.saved_appearance else 'light' if 'Aqua' in self.saved_appearance else 'system'
                        self.call('appearance', name=original)
                        actual = self.call('space-manager-lifecycle')['appAppearance']
                        self.log('restore-appearance', verified=actual == self.saved_appearance)
                        self.cleanup_ok = self.cleanup_ok and actual == self.saved_appearance
                    self.call('quit')
                except Exception as error:
                    self.cleanup_ok = False
                    self.log('quit-error', error=str(error))
            for _ in range(50):
                if self.proc is not None and self.proc.poll() is not None:
                    break
                try:
                    os.kill(self.pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(.1)
            else:
                self.cleanup_ok = False
                self.log('quit-incomplete', pid=self.pid)
        current = self.state()
        # Restore prior app unless the user already selected a new app.
        if current['frontmostPID'] in (self.pid, 0) or before_quit['frontmostPID'] == self.pid:
            try:
                run(self.native, 'activate', self.initial['frontmostPID'])
            except Exception as error:
                self.cleanup_ok = False
                self.log('restore-error', error=str(error))
        elapsed = time.monotonic() - self.started
        self.cleanup_ok = self.cleanup_ok and elapsed <= 170
        self.log('cleanup', final=self.state(), arc_version=self.arc_version(), elapsed=elapsed, ok=self.cleanup_ok)
        (self.out / 'no-actions.json').write_text(json.dumps(self.gaps, indent=2))
        self.logfile.close()


def validate_script(script):
    if not isinstance(script, dict) or not isinstance(script.get('steps'), list) or len(script['steps']) > 300:
        raise ValueError('capture script needs at most300 steps')
    pending, count = [(script,0)], 0
    while pending:
        value,depth = pending.pop(); count += 1
        if count > 10000 or depth > 20:
            raise ValueError('capture script exceeds10000 values or20 levels')
        if isinstance(value, str) and len(value) > 2048:
            raise ValueError('capture string exceeds2048 characters')
        if isinstance(value, float) and not math.isfinite(value):
            raise ValueError('capture numbers must be finite')
        if isinstance(value, dict):
            if 'op' in value and 'name' in value and not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', str(value['name'])):
                raise ValueError('capture name must be a short safe filename')
            pending.extend((v,depth+1) for v in value.values())
        elif isinstance(value, list):
            pending.extend((v,depth+1) for v in value)


def main():
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('script', type=Path)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--backend', choices=('arc', 'open'), default='arc')
    p.add_argument('--native', type=Path, default=Path('/tmp/open-capture-native'))
    p.add_argument('--burst-tool', type=Path, default=Path('/tmp/open-capture-burst'))
    p.add_argument('--rulings', type=Path, default=QUESTIONS)
    p.add_argument('--pixel-launcher', type=Path, help='Existing approved launcher for pixel readers only')
    p.add_argument('--host', choices=('local', 'm1'), default='local')
    p.add_argument('--remote-root', help='Absolute private staging path on M1; default is under its home')
    p.add_argument('--lock-timeout', type=int, default=1800, help='Remote screen-lock wait in seconds')
    p.add_argument('--prepare-only', action='store_true', help='Stage/compile/preflight M1 without launching any app')
    args = p.parse_args()
    if args.script.stat().st_size > 262144:
        p.error('capture script exceeds256KiB')
    script = json.loads(args.script.read_text())
    validate_script(script)
    if args.host == 'm1':
        from host import remote_session
        return remote_session(args)
    if args.prepare_only:
        p.error('--prepare-only requires --host m1')
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / 'script.json').write_text(json.dumps(script, indent=2))
    session = Session(script, args.out, args.backend, args.native, args.burst_tool, args.rulings, args.pixel_launcher)
    def interrupted(signum, frame):
        raise Stopped('signal ' + str(signum))
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, interrupted)
    code = 0
    try:
        for step in script['steps']:
            session.step(step)
    except Exception as error:
        session.log('STOP', reason=str(error))
        print('STOP: ' + str(error), file=sys.stderr)
        code = 1
    finally:
        session.cleanup()
    return code if session.cleanup_ok and session.permission_handoff is None else 1


if __name__ == '__main__':
    sys.exit(main())
