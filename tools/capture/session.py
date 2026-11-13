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
import shutil
import signal
import socket
import subprocess
import sys
import time
import threading
from http.server import BaseHTTPRequestHandler
sys.path.append(str(Path(__file__).resolve().parents[1] / 'e2e'))  # loopback_http; appended, so the stdlib wins
from loopback_http import LoopbackHTTPServer

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
        if key in ('min_h', 'max_h'):
            h = (node.get('frame') or [0, 0, 0, 0])[3]
            if (key == 'min_h' and h < expected) or (key == 'max_h' and h > expected):
                return False
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
        self.companion = None
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
        self.nc_frames = None
        self.drag_geometry = None
        self.allow_boost = False
        self.boost_frames = set()
        self.drag_rail_ids = set()
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
                unexpected = [w for w in unexpected if not self.drag_rail(w, now)]
                if len(dialogs) == 1 and not self.drag_windows:
                    frame = tuple(dialogs[0].get('frame', []))
                    allowed = [w['bounds'] for w in current if w['number'] in self.drag_cg_ids]
                    if not frame or not any(frame) or any(all(abs(v-b[k]) < 2 for v,k in zip(frame,('X','Y','Width','Height'))) for b in allowed):
                        self.drag_windows.add(frame)
                if unexpected or len(dialogs) > max(1, len(self.drag_windows), 1 + len(self.drag_rail_ids)):
                    self.log('unexpected-window-during-drag', windows=unexpected, dialog_count=len(dialogs))
                    raise Stopped('another new window appeared during the owned drag')
            for n in walk(windows):
                title = str(n.get('title', ''))
                if n.get('subrole') == 'AXSystemDialog' and self.owned_drag_window(n, now):
                    continue
                if n.get('subrole') == 'AXSystemDialog' and self.boost_editor_window(n):
                    continue
                if n.get('subrole') == 'AXSystemDialog' and self.pip_window(n, now):
                    continue
                if n.get('subrole') == 'AXSystemDialog' or re.search(r'^(Sign [Ii]n|Log [Ii]n|Accessibility Access|Screen Recording)$', title):
                    # Passive record for the lead: the owned app's AX windows and CG window list only.
                    try:
                        stamp = '%.2f' % (time.monotonic() - self.started)
                        (self.out / ('stop-dialog-%s.ax.json' % stamp)).write_text(json.dumps(windows, indent=2))
                        (self.out / ('stop-dialog-%s.windows.json' % stamp)).write_text(run(self.native, 'windows', self.pid))
                    except Exception as error:
                        self.log('stop-dialog-record-incomplete', error=str(error))
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

    def pip_window(self, node, state):
        # LEAD 02:45: a possible auto-PiP window is recorded (never clicked) only when
        # (1) its title is empty or matches the playing tab, (2) its full AX subtree has
        # no text/secure field and no sign-in/allow/OK button, and (3) its CG window is
        # owned by the Arc PID, above layer 0 and smaller than half the screen.
        if not (self.script.get('pip_window_exception') is True and 'LEAD 02:45 readback: auto-PiP window exception' in self.rulings
                and self.backend == 'arc' and self.pid):
            return False
        title = str(node.get('title') or '')
        if title and not re.search(self.script.get('pip_title_re', r'(?!)'), title):
            return False
        frame = node.get('frame') or []
        if len(frame) != 4:
            return False
        full = json.loads(run(self.native, 'ax-windows', self.pid))
        twins = [n for n in walk(full) if n.get('role') == 'AXWindow' and all(abs(a - b) < 2 for a, b in zip(n.get('frame') or [0, 0, 0, 0], frame))]
        if len(twins) != 1:
            return False
        for n in walk(twins[0]):
            label = ' '.join(str(n.get(k) or '') for k in ('title', 'desc', 'value'))
            if n.get('role') in ('AXTextField', 'AXSecureTextField', 'AXTextArea', 'AXComboBox') or n.get('subrole') == 'AXSecureTextField':
                return False
            if n.get('role') == 'AXButton' and re.search(r'\b(sign\s*in|log\s*in|allow|ok)\b', label, re.I):
                return False
        cg = json.loads(run(self.native, 'windows', self.pid))
        sx, sy, sw, sh = state['screens'][0]['frame']
        hits = [w for w in cg if all(abs(w['bounds'][k] - v) < 2 for k, v in zip(('X', 'Y', 'Width', 'Height'), frame))]
        if len(hits) != 1:
            return False
        w = hits[0]
        if w.get('pid', self.pid) != self.pid or not w.get('layer', 0) > 0 or w['bounds']['Width'] * w['bounds']['Height'] >= 0.5 * sw * sh:
            return False
        recorded = getattr(self, 'pip_recorded', set())
        self.pip_recorded = recorded
        if w['number'] not in recorded:
            recorded.add(w['number'])
            stem = 'pip-window-%d' % w['number']
            (self.out / (stem + '.ax.json')).write_text(json.dumps(twins[0], indent=2))
            (self.out / (stem + '.windows.json')).write_text(json.dumps(cg, indent=2))
            try:
                self.pixel_run(['/usr/sbin/screencapture', '-x', '-o', '-l', str(w['number']), str(self.out / (stem + '.png'))])
            except Exception as error:
                self.log('pip-window-frame-incomplete', error=str(error))
            self.log('pip-window-recorded', number=w['number'], layer=w['layer'], bounds=w['bounds'], title=title,
                     t=round(time.monotonic() - self.started, 3))
        return True

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

    def drag_rail(self, w, now):
        """LEAD 13:00: Arc's own drop-target rails and drag layer during C3's held sidebar drag."""
        if not (self.s3_ruling() and '## LEAD 13:00' in self.rulings and self.drag_geometry and self.mouse_down):
            return False
        if w['number'] in self.drag_rail_ids:
            return True
        b = w['bounds']
        for (ox, oy, ow, oh), oedge in self.drag_geometry.get('others', []):
            # LEAD 13:15 cross-window drag: the same rail shapes on the destination window, any time during the drag.
            if (w['layer'] == 0 and abs(b['Height'] - oh) <= 2 and abs(b['Y'] - oy) <= 2 and b['Width'] <= 80
                    and (b['X'] - 2 <= ox <= b['X'] + b['Width'] + 2 or b['X'] - 2 <= oedge <= b['X'] + b['Width'] + 2)):
                self.drag_rail_ids.add(w['number'])
                self.drag_windows.add((b['X'], b['Y'], b['Width'], b['Height']))
                self.log('drag-rail-accepted', window=w, rule='LEAD 13:15', kind='destination rail')
                return True
        if self.drag_first_move_at is None or time.monotonic() - self.drag_first_move_at > 1:
            return False
        wx, wy, ww, wh = self.drag_geometry['window']; edge = self.drag_geometry['sidebar_edge']
        screen = self.initial['screens'][0]['frame']
        rail = (w['layer'] == 0 and abs(b['Height'] - wh) <= 2 and abs(b['Y'] - wy) <= 2 and b['Width'] <= 80
                and (b['X'] - 2 <= wx <= b['X'] + b['Width'] + 2 or b['X'] - 2 <= edge <= b['X'] + b['Width'] + 2))
        layer = (w['layer'] == 500 and abs(b['X'] - screen[0]) < 1 and abs(b['Y'] - screen[1]) < 1
                 and abs(b['Width'] - screen[2]) < 1 and abs(b['Height'] - screen[3]) < 1)
        if rail or layer:
            self.drag_rail_ids.add(w['number'])
            self.drag_windows.add((b['X'], b['Y'], b['Width'], b['Height']))
            self.log('drag-rail-accepted', window=w, rule='LEAD 13:00', kind='rail' if rail else 'drag layer',
                     after_first_move=time.monotonic() - self.drag_first_move_at)
            return True
        return False

    BOOST_FORBIDDEN = re.compile(r'sign ?in|log ?in|account|password|permission|allow', re.I)
    BOOST_REQUIRED = re.compile(r'\bzap\b|\bfont|colou?r|\bcode\b', re.I)

    def boost_editor_window(self, node):
        """LEAD 18:00: after 'New Boost', an Arc-owned AXSystemDialog window may be the Boost editor."""
        if not (self.allow_boost and self.s3_ruling() and 'LEAD 18:00 (pending answer) readback: Boost editor dialog' in self.rulings):
            return False
        frame = tuple(node.get('frame') or [])
        if frame in self.boost_frames:
            return True
        # Once accepted, the editor keeps its AX identifier while it resizes (Code view).
        if self.boost_frames and node.get('id') == 'boostsEditor':
            return True
        full = json.loads(run(self.native, 'ax-windows', self.pid))
        wins = [w for w in walk(full) if w.get('role') == 'AXWindow' and tuple(w.get('frame') or []) == frame]
        if len(wins) != 1:
            return False
        text = ' '.join(str(v) for e in walk(wins[0]) for k, v in e.items() if k in ('title', 'desc', 'value', 'help', 'placeholder'))
        (self.out / 'boost-dialog.ax.json').write_text(json.dumps(wins[0], indent=2))
        if self.BOOST_FORBIDDEN.search(text) or not self.BOOST_REQUIRED.search(text):
            self.log('boost-dialog-refused', frame=frame, forbidden=bool(self.BOOST_FORBIDDEN.search(text)))
            return False
        self.boost_frames.add(frame)
        self.log('boost-dialog-accepted', frame=frame, rule='LEAD 18:00')
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

    def companion_call(self, cmd, **args):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(10)
            conn.connect(str(self.companion_socket))
            conn.sendall((json.dumps({'id': 1, 'cmd': cmd, 'args': args}) + '\n').encode())
            buf = b''
            while not buf.endswith(b'\n'):
                chunk = conn.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
        reply = json.loads(buf)
        if not reply.get('ok'):
            raise RuntimeError(str(reply.get('error')))
        return reply['result']

    def stop_arc_log(self):
        proc = getattr(self, 'arc_log_proc', None)
        self.arc_log_proc = None
        if proc is None:
            return
        time.sleep(0.5)
        proc.terminate()
        try:
            proc.wait(5)
        except subprocess.TimeoutExpired:
            proc.kill()
        self.arc_log_file.close()
        self.log('arc-log-stop', code=proc.returncode)

    def end_companion(self):
        # SIGTERM to the exact Open PID this block started; never another process.
        proc, self.companion = self.companion, None
        if proc is None:
            return
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(10)
            except subprocess.TimeoutExpired:
                self.cleanup_ok = False
                self.log('open-cover-still-running', pid=proc.pid)
                return
        self.log('open-cover-ended', pid=proc.pid, code=proc.returncode)

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
        for command in ('window-state', 'settings-state', 'space-manager-state', 'space-manager-lifecycle', 'library-captures-state', 'library-history-state', 'downloads-state', 'commandbar-state', 'find-state', 'peek-state', 'little-open-state', 'theme-get', 'sidebar-tree'):
            try:
                result[command] = self.call(command)
            except RuntimeError as error:
                result[command] = {'unavailable': str(error)}
        return result

    def arc_library_visible(self, tree):
        descriptions = {n.get('desc') for n in walk(tree)
                        if n.get('role') == 'AXButton' and n.get('depth', 99) <= 3}
        return {'Media', 'Downloads', 'Easels', 'Archived Tabs'} <= descriptions

    def target(self, predicate, frame_required=True, allow_disabled=False):
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
        if self.s3_ruling() and frame_required and not menu:
            # Arc keeps neighbouring Spaces' sidebars in AX, off-screen. Count only
            # elements whose centre lies inside one of the app's own AX windows.
            wins = [w['frame'] for w in walk(tree) if w.get('role') == 'AXWindow' and w.get('frame')]
            if not wins:
                wins = [w['frame'] for w in walk(json.loads(run(self.native, 'window-info', self.pid))) if w.get('role') == 'AXWindow' and w.get('frame')]
            def inside(f):
                cx, cy = f[0] + f[2] / 2, f[1] + f[3] / 2
                return any(a <= cx < a + c and b <= cy < b + d for a, b, c, d in wins)
            nodes = [n for n in nodes if n.get('role') == 'AXWindow' or inside(n['frame'])]
            # Neighbouring Spaces' sidebars sit beside the visible one (under the page).
            # The visible outline starts at the window's left edge; keep sidebar items inside it.
            outlines = [o['frame'] for o in walk(tree) if o.get('id') == 'sidebarAllTabList' and o.get('frame')]
            if outlines and wins:
                # One visible outline per window: the one that starts at that window's left edge.
                vis_all = [min(outlines, key=lambda f, x=w[0]: abs(f[0] - x)) for w in wins]
                def in_sidebar(n):
                    if not ('/AXOutline' in n.get('anc', '') or n.get('id') == 'sidebarAllTabList' or n.get('id') == 'sidebarSpaceName'):
                        return True
                    cx = n['frame'][0] + n['frame'][2] / 2
                    return any(v[0] - 2 <= cx <= v[0] + v[2] + 2 for v in vis_all)
                nodes = [n for n in nodes if in_sidebar(n)]
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
        if not allow_disabled and (n.get('enabled') is False or 'disabled' in n.get('flags', [])):
            raise Stopped('AX target is disabled')
        return n

    def m1_input_ruling(self):
        return (self.backend == 'arc' and socket.gethostname().lower().startswith('m1-')
                and '## LEAD 19:30' in self.rulings
                and 'AX-resolved clicks are allowed on the M1 for Arc capture' in self.rulings)

    def s2_ruling(self):
        # Session 3 (plan C3) keeps every Session 2 synthetic-input guard.
        return self.m1_input_ruling() and self.script.get('capture_scope') in ('session2', 'session3') and '## LEAD 23:45' in self.rulings

    def s3_ruling(self):
        return self.s2_ruling() and self.script.get('capture_scope') == 'session3'

    # Arc shortcuts used by plan C3. Never quit, settings, delete-data or system panels.
    S3_KEYS = {('s','cmd'), ('t','cmd'), ('l','cmd'), ('d','cmd'), ('left','cmd,opt'), ('right','cmd,opt'),
               ('left','opt,cmd'), ('right','opt,cmd'), ('space',''), ('delete',''), ('n','cmd,shift'), ('b','cmd,shift'), ('=','cmd'), ('-','cmd'), ('0','cmd'),
               ('n','ctrl,shift'), ('n','ctrl,opt'), ('e','ctrl,shift'), ('j','ctrl,cmd'), ('t','cmd,shift')} | {(str(i),'ctrl') for i in range(1,10)}

    ARC_DEFAULT_KEYS = {'domainToProfilePreferences', 'topAppsEmptyStateDismissed', 'topAppsEmptyStateDismissedForProfiles',
                        'topAppsBadgingDisabledHosts', 'topAppsSubtitleDisabledHosts', 'twitterBadgeEnabled', 'playUserInterfaceSoundsDisabled'}

    # Arc deep links the capture plan may open (PB1-c); nothing else is passed to `open`.
    DEEP_LINKS = {'arcBrowser://quit', 'arcBrowser://space', 'arcBrowser://space/1', 'arcBrowser://restart'}

    def point_in(self, n, at=None):
        x,y,w,h = n['frame']
        fx,fy = at if at else (.5,.5)
        if not (0 <= fx <= 1 and 0 <= fy <= 1):
            raise Stopped('target fraction must lie inside the AX frame')
        return x + w*fx, y + h*fy

    def synthetic_field(self, text=None):
        focused = json.loads(run(self.native, 'focused', self.pid))
        roles = ('AXTextField', 'AXSearchField', 'AXTextArea') if self.s3_ruling() else ('AXTextField', 'AXSearchField')
        fields = [focused] if focused.get('focused') and focused.get('role') in roles else []
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
        if args[0] == 'move' and self.s3_ruling():
            args = ('move-checked',) + tuple(args[1:])
        if args[0] in ('click', 'down', 'dragto', 'key', 'type', 'click-check', 'move-checked'):
            if not self.m1_input_ruling():
                raise Stopped('synthetic clicks/keys require the M1 LEAD19:30 ruling')
            if args[0] == 'move-checked':
                verified_pointer = True
            if args[0] in ('click', 'down', 'dragto', 'click-check', 'move-checked'):
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
                    if '## LEAD 11:32' in self.rulings:
                        command.append('lead-m1-nc23-rule')
                    result = subprocess.run(command, capture_output=True, text=True, timeout=8)
                    check = json.loads(result.stdout)
                    frames = sorted(map(tuple, check.get('ncFrames') or []))
                    if frames:
                        # LEAD 11:32 rule 5: a new alert or banner stops the block.
                        if self.nc_frames is None:
                            self.nc_frames = frames
                        elif frames != self.nc_frames:
                            self.log('nc-frames-changed', before=self.nc_frames, after=frames)
                            raise Stopped('Notification Centre alert/banner frames changed; stop')
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
                elif self.s3_ruling() and (key,modifiers) in self.S3_KEYS:
                    if key in ('space','delete'):
                        self.synthetic_field()
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
        if args[0] == 'click-check':
            return
        if args[0] == 'move-checked':
            args = ('move',) + tuple(args[1:])
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
            if args[0] == 'click' and len(args) > 5:
                self.log('click-flags', result=json.loads(run(self.native, 'click-flags', *args[1:6])))
            else:
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
            win = next((w for w in wins if w['number'] == self.window and w.get('onscreen')), None) or max(base, key=lambda w: w['bounds']['Width'] * w['bounds']['Height'])
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
            self.fixture_server = LoopbackHTTPServer(Fixture)
            threading.Thread(target=self.fixture_server.serve_forever, daemon=True).start()
            url = 'http://127.0.0.1:%d/%s' % (self.fixture_server.server_port, filename)
            self.log('fixture-download', filename=filename, url=url, bytes=size, transfer_seconds=duration)
            if self.backend == 'arc':
                self.guard(event=True)
                dispatched = time.time()
                run('/usr/bin/open', '-a', '/Applications/Arc.app', url)
                if self.burst_events is not None:
                    self.burst_events.append({'operation': 'fixture-download', 'start_unix': dispatched, 'end_unix': time.time()})
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
            if op == 'click_ax' and step.get('action'):
                if not self.s3_ruling() or step['action'] not in ('AXIncrement', 'AXDecrement', 'AXShowMenu', 'AXConfirm', 'AXPick'):
                    raise Stopped('click_ax action override needs Session3 and an approved AX action')
                action = step['action']
            try:
                for _ in range(max(1, min(int(step.get('repeat', 1)), 30))):
                    self.ax_action(step['target'], action, step.get('text'))
            except UnavailableAX as error:
                if not step.get('optional'):
                    raise
                self.gaps.append({'step': step, 'finding': 'Arc: not captured; ' + str(error)})
                self.log('not-captured', operation=step, reason=str(error))
        elif op == 'pointer_ax':
            if step.get('expect') == 'selected' and not self.s3_ruling():
                raise Stopped('selected expectation needs the Session3 scope')
            if step.get('expect') == 'observe' and step.get('button') != 'right':
                raise Stopped('observe expectation is allowed only for a right-click')
            if not self.m1_input_ruling() or step.get('expect') not in ('change', 'menu', 'selected', 'observe') or not step.get('name'):
                raise Stopped('M1 pointer click needs the lead ruling, a named frame and an expected result')
            if step.get('button','left') not in ('left','right') or int(step.get('count',1)) not in (1,2):
                raise Stopped('one verified left/right click or double-click is allowed')
            # A burst already captured its before frame before starting the
            # recorder. A second AX/PNG pass can outlast a short movie.
            before = None if step['expect'] == 'selected' else (self.burst_before or self.shot(step['name'] + '-before', step.get('ax_depth')))
            n = self.target(step['target'])
            x,y,w,h = n['frame']
            window_info = json.loads(run(self.native, 'window-info', self.pid))
            windows = [e['frame'] for e in walk(window_info) if e.get('role') == 'AXWindow' and e.get('frame')]
            point = self.point_in(n, step.get('at'))
            if not any(a <= point[0] < a+c and b <= point[1] < b+d for a,b,c,d in windows):
                raise Stopped('fresh AX target centre is outside the owned AX windows')
            self.log('pointer-target', ax_target=n, expected=step['expect'])
            mods = step.get('modifiers') or []
            if not set(mods) <= {'cmd', 'opt', 'shift'}:
                raise Stopped('pointer modifiers must be cmd, opt or shift')
            self.input('click', *point, step.get('button','left'), int(step.get('count',1)), *([','.join(mods)] if mods else []), verified_pointer=True, target_predicate=step['target'])
            deadline = time.monotonic() + 2
            if step['expect'] == 'selected':
                # A sidebar row counts as selected when its AXRow/AXCell reports selected.
                while True:
                    self.guard(event=True)
                    tree = json.loads(run(self.native, 'ax-depth', self.pid, 10))
                    hit = [e for e in walk(tree) if e.get('role') in ('AXRow', 'AXCell') and e.get('selected') in (True, 1)
                           and e.get('frame') and abs(e['frame'][1] - y) < 2]
                    if hit:
                        self.log('pointer-result', selected=True)
                        break
                    if time.monotonic() >= deadline:
                        raise Stopped('expected row selection not observed within2s; no further click sent')
                    time.sleep(.1)
                self.log('end', operation=op)
                return
            if step['expect'] == 'observe':
                # D2 Library rows: a right-click that may open no menu. Record, never stop.
                time.sleep(1.2)
                self.guard(event=True)
                old_ids = {w['number'] for w in json.loads(before.with_suffix('.windows.json').read_text()) if w['onscreen']}
                wins = json.loads(run(self.native, 'windows', self.pid))
                scoped = json.loads(run(self.native, 'ax-depth', self.pid, 3))
                menu = any(e.get('role') in ('AXMenu',) for e in walk(scoped))
                new = [w for w in wins if w['number'] not in old_ids and w['onscreen']]
                self.log('pointer-observed', menu=menu, new_windows=new)
                self.shot(step['name'], step.get('ax_depth'))
                self.log('end', operation=op)
                return
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
                    threshold = float(step.get('min_change', .001)) if self.s3_ruling() else .001
                    appeared = difference['meanDifference'] > max(threshold, 1e-6)
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
                self.input('move', *self.point_in(n, step.get('at')))
        elif op == 'deep_link':
            if not self.s3_ruling() or step.get('url') not in self.DEEP_LINKS:
                raise Stopped('deep link is not on the session-3 allowlist')
            self.guard(event=True)
            dispatched = time.time()
            result = subprocess.run(['/usr/bin/open', step['url']], capture_output=True, text=True, timeout=10)
            self.log('deep-link', url=step['url'], exit=result.returncode, stderr=result.stderr[-300:])
            if self.burst_events is not None:
                self.burst_events.append({'operation': 'deep-link', 'start_unix': dispatched, 'end_unix': time.time()})
        elif op == 'open_cover':
            # LEAD 02:10: cover Arc with an Open window on a fresh test profile,
            # placed only through Open's automation socket. No input reaches Open.
            if not self.s3_ruling() or 'LEAD 02:10 readback: PiP cover with Open' not in self.rulings or self.companion is not None:
                raise Stopped('Open cover needs the LEAD 02:10 ruling and one companion per block')
            exe = str(step.get('executable', ''))
            if not re.fullmatch(r'/Users/[^/]+/\.re/open-c-capture/main-[0-9a-f]+/Open\.app/Contents/MacOS/Open', exe) or not Path(exe).exists():
                raise Stopped('Open cover needs an owned capture build of Open')
            root = Path.home() / '.re/open-c-capture' / ('s7-cover-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
            root.mkdir(parents=True, exist_ok=False)
            sock = root / 'automation.sock'
            self.guard(event=True)
            x, y, w, h = self.target({'role': 'AXWindow', 'identifier': 're:^bigBrowserWindow'})['frame']
            env = dict(os.environ, OPEN_USER_DATA=str(root), OPEN_SKIP_FIRST_RUN='1', OPEN_E2E_NO_CRASH_PROBES='1', OPEN_E2E_OWNER_PID=str(os.getpid()), OPEN_AUTOMATION_SKIP_MAC_NOTIFICATIONS='1')
            self.companion_log = (self.out / 'open-cover-app.log').open('a')
            self.companion = subprocess.Popen([exe, '--user-data-dir=' + str(root), '--automation-socket=' + str(sock), '--skip-first-run', '--use-mock-keychain', '--style=chrome', 'about:blank'], env=env, stdout=self.companion_log, stderr=subprocess.STDOUT)
            self.companion_socket = sock
            for _ in range(150):
                if sock.exists():
                    break
                if self.companion.poll() is not None:
                    raise Stopped('Open cover exited during launch')
                time.sleep(.1)
            else:
                raise Stopped('Open cover socket did not appear')
            if self.companion_call('ping')['pid'] != self.companion.pid:
                raise Stopped('Open cover socket PID mismatch')
            height = self.initial['screens'][0]['frame'][3]
            m = float(step.get('margin', 12))
            frame = [x - m, height - (y + h) - m, w + 2 * m, h + 2 * m]
            placed = self.companion_call('window-frame', frame=frame)
            self.companion_call('activate')
            activation = json.loads(run(self.native, 'activate', self.companion.pid))
            ready = time.monotonic() + 3
            while self.state()['frontmostPID'] != self.companion.pid and time.monotonic() < ready:
                time.sleep(.05)
            now = self.state()
            self.log('open-cover', pid=self.companion.pid, data_root=str(root), frame=frame, placed=placed, activation=activation,
                     frontmost_pid=now['frontmostPID'], frontmost_bundle=now['frontmostBundle'])
            if now['frontmostPID'] != self.companion.pid:
                raise Stopped('Open cover did not become frontmost')
            if self.burst_events is not None:
                self.burst_events.append({'operation': 'open-cover', 'start_unix': time.time(), 'end_unix': time.time()})
        elif op == 'open_uncover':
            if self.companion is None:
                raise Stopped('no Open cover to end')
            self.end_companion()
            dispatched = time.time()
            activation = json.loads(run(self.native, 'activate', self.pid))
            ready = time.monotonic() + 2
            while self.state()['frontmostPID'] != self.pid and time.monotonic() < ready:
                time.sleep(.05)
            if self.state()['frontmostPID'] != self.pid:
                run('/usr/bin/open', '-a', '/Applications/Arc.app')
                ready = time.monotonic() + 3
                while self.state()['frontmostPID'] != self.pid and time.monotonic() < ready:
                    time.sleep(.05)
            now = self.state()
            self.log('open-uncover', activation=activation, frontmost_pid=now['frontmostPID'], frontmost_bundle=now['frontmostBundle'])
            if self.burst_events is not None:
                self.burst_events.append({'operation': 'open-uncover', 'start_unix': dispatched, 'end_unix': time.time()})
            if now['frontmostPID'] != self.pid:
                raise Stopped('Arc did not return to the front after the Open cover')
        elif op == 'arc_windows':
            # Window list plus one frame per visible owned Arc window (a PiP window included).
            if not step.get('name'):
                raise Stopped('arc_windows needs a name')
            self.guard()
            wins = json.loads(run(self.native, 'windows', self.pid))
            (self.out / (step['name'] + '.windows.json')).write_text(json.dumps(wins, indent=2))
            seen = []
            for w in wins:
                if w.get('onscreen') and w['bounds']['Width'] > 2 and w['bounds']['Height'] > 2:
                    path = self.out / ('%s-%d.png' % (step['name'], w['number']))
                    self.pixel_run(['/usr/sbin/screencapture', '-x', '-o', '-l', str(w['number']), str(path)])
                    seen.append({'number': w['number'], 'layer': w['layer'], 'bounds': w['bounds']})
            self.log('arc-windows', name=step['name'], onscreen=seen, frontmost=self.state()['frontmostBundle'])
        elif op == 'modkey':
            # D2 item 3b: hold or release Option while an owned Arc menu is open.
            if not self.s3_ruling() or step.get('key') != 'opt' or step.get('state') not in ('down', 'up'):
                raise Stopped('modkey allows only Option down/up in the Session3 scope')
            self.guard(event=True)
            self.log('modkey', result=json.loads(run(self.native, 'modkey', 'opt', step['state'])))
            self.opt_down = step['state'] == 'down'
        elif op == 'arc_store_grep':
            # NT C11 (LEAD 11:50): read-only extract of Boost zoom/colour numbers from Arc's own store files.
            # Runs only while Arc is not running (before `launch`). Fixed pattern: no titles, hosts or URLs.
            if self.pid or not step.get('name') or self.script.get('capture_scope') != 'session3':
                raise Stopped('arc_store_grep runs before launch, with a name, in the Session3 scope')
            root = Path.home() / 'Library/Application Support/Arc'
            pattern = re.compile(r'"(textZoom|level|primaryHueDegrees|primarySaturation|secondaryHueOffset|invertLightness|baseAppearance)"\s*:\s*(\{[^{}]{0,80}\}|-?[0-9.eE+-]+|true|false|"[a-zA-Z]{0,24}")')
            lines = []
            for f in sorted(root.glob('Storable*.json')):
                if re.search(r'\.\d{4}-\d{2}-\d{2}-', f.name) or f.stat().st_size > 64 << 20:
                    continue
                text = f.read_text(errors='replace')
                if 'textZoom' in text or 'primaryHueDegrees' in text:
                    lines.append('## ' + f.name)
                    lines += ['%s: %s' % m for m in pattern.findall(text)][:200]
            (self.out / (step['name'] + '.store.txt')).write_text('\n'.join(lines) or 'no Boost numbers found')
            self.log('arc-store-grep', name=step['name'], lines=len(lines))
        elif op == 'arc_firestore_copy':
            # NT C11: private copy of Arc's Firestore offline cache (Boost documents) while Arc is not running.
            # The copy holds account documents: it stays in the run folder under .re/ and is never committed.
            if self.pid or not re.fullmatch(r'[a-z0-9-]{1,40}', str(step.get('name', ''))) or self.script.get('capture_scope') != 'session3':
                raise Stopped('arc_firestore_copy runs before launch, with a simple name, in the Session3 scope')
            source = Path.home() / 'Library/Application Support/firestore/Arc/bcny-arc-server/main'
            size = sum(f.stat().st_size for f in source.glob('*') if f.is_file())
            if not source.is_dir() or size > 64 << 20:
                raise Stopped('Firestore cache missing or larger than 64 MiB')
            shutil.copytree(source, self.out / ('firestore-' + step['name']))
            self.log('arc-firestore-copy', name=step['name'], bytes=size)
        elif op == 'arc_defaults':
            # Read-only `defaults read` of allowlisted Arc preference keys. Raw output stays in the run folder.
            if not self.s3_ruling() or not step.get('name') or not set(step.get('keys') or ['?']) <= self.ARC_DEFAULT_KEYS:
                raise Stopped('arc_defaults needs the Session3 scope, a name and allowlisted keys')
            lines = []
            for key in step['keys']:
                r = subprocess.run(['/usr/bin/defaults', 'read', 'company.thebrowser.Browser', key], capture_output=True, text=True, timeout=10)
                lines.append('## %s (exit %d)\n%s' % (key, r.returncode, r.stdout if r.returncode == 0 else 'absent'))
            (self.out / (step['name'] + '.defaults.txt')).write_text('\n'.join(lines))
            self.log('arc-defaults', name=step['name'], keys=step['keys'])
        elif op == 'arc_log':
            # LEAD 10:50: read-only `log stream` of the owned Arc process (PB1-e / PB4 C9 sound mapping).
            if not self.s3_ruling() or step.get('state') not in ('start', 'stop', 'mark'):
                raise Stopped('arc_log needs the Session3 scope and start/stop/mark')
            if step['state'] == 'start':
                if getattr(self, 'arc_log_proc', None) is not None or not self.pid:
                    raise Stopped('one Arc log stream per block, after launch')
                self.arc_log_file = (self.out / 'arc-log.ndjson').open('a')
                self.arc_log_proc = subprocess.Popen(['/usr/bin/log', 'stream', '--style', 'ndjson', '--level', 'debug',
                                                      '--predicate', 'processIdentifier == %d' % self.pid],
                                                     stdout=self.arc_log_file, stderr=subprocess.STDOUT)
                time.sleep(1.0)
                self.log('arc-log-start', pid=self.arc_log_proc.pid, arc_pid=self.pid)
            elif step['state'] == 'mark':
                self.log('arc-log-mark', label=str(step.get('label', ''))[:80], unix=time.time())
            else:
                self.stop_arc_log()
        elif op == 'allow_boost_editor':
            if not self.s3_ruling() or 'LEAD 18:00 (pending answer) readback: Boost editor dialog' not in self.rulings:
                raise Stopped('Boost editor capture needs the LEAD 18:00 ruling')
            self.allow_boost = True
            self.log('boost-editor-armed')
        elif op == 'drag_ax':
            # Plan C3: a complete AX-anchored drag (divider, tab reorder, colour handle).
            # Both ends come from fresh AX frames in this block; never stored points.
            if not self.s3_ruling() or not step.get('name'):
                raise Stopped('drag_ax needs the Session3 scope and a name')
            start = self.target(step['target'])
            sx,sy = self.point_in(start, step.get('at'))
            if step.get('offset'):
                ox, oy = step['offset']
                if abs(ox) > 8 or abs(oy) > 8:
                    raise Stopped('drag start offset is limited to 8 pt')
                sx, sy = sx + ox, sy + oy
            if 'to' in step:
                end = self.target(step['to'])
                ex,ey = self.point_in(end, step.get('to_at'))
            else:
                dx,dy = step['by']
                if abs(dx) > 600 or abs(dy) > 600:
                    raise Stopped('drag offset is limited to600pt')
                ex,ey = sx+dx, sy+dy
            info = json.loads(run(self.native, 'window-info', self.pid))
            frames = [e['frame'] for e in walk(info) if e.get('role') == 'AXWindow' and e.get('frame')]
            if not any(a <= ex < a+c and b <= ey < b+d for a,b,c,d in frames):
                raise Stopped('drag end is outside the owned AX windows')
            main = [e['frame'] for e in walk(info) if e.get('role') == 'AXWindow' and e.get('main') and e.get('frame')]
            outline = [e['frame'] for e in walk(self.tree()) if e.get('id') == 'sidebarAllTabList' and e.get('frame')]
            if len(main) != 1 or not outline:
                raise UnavailableAX('AX target: drag needs one main window and a sidebar outline')
            # Neighbouring Spaces' outlines are present too; the visible one starts at the window's left edge.
            all_outlines = list(outline)
            outline = [min(outline, key=lambda f: abs(f[0] - main[0][0]))]
            edge = outline[0][0] + outline[0][2] - 1
            self.drag_geometry = {'window': main[0], 'sidebar_edge': edge}
            if step.get('kind', 'tab') == 'canvas':
                # Easel canvas drawing: both ends inside the window, right of the sidebar, no rails.
                if not (edge + 20 <= sx and edge + 20 <= ex <= main[0][0] + main[0][2] - 20
                        and main[0][1] + 60 <= min(sy, ey) and max(sy, ey) <= main[0][1] + main[0][3] - 60):
                    raise Stopped('canvas drag must stay inside the page area')
            elif step.get('kind', 'tab') == 'divider':
                # Sidebar width drag: start on the divider, end inside the window; no tab drop.
                if abs(sx - edge) > 6 or not (main[0][0] + 40 <= ex <= main[0][0] + main[0][2] - 200):
                    raise Stopped('divider drag must start on the sidebar edge and stay inside the window')
            elif step.get('kind') == 'cross_window':
                # LEAD 13:15 item 1(a): drop into the tab list of another owned Arc window, >= 20 pt from its edges.
                if 'LEAD 13:15 readback: session 11' not in self.rulings:
                    raise Stopped('cross-window drag needs the LEAD 13:15 ruling')
                mx, my, mw, mh = main[0]
                lists = [f for f in all_outlines if f[2] > 0 and f[0] >= 0 and abs(f[0] - mx) > 2
                         and any(a - 2 <= f[0] < a + c and b - 2 <= f[1] < b + d for a, b, c, d in frames)]
                hit = [f for f in lists if f[0] + 20 <= ex <= f[0] + f[2] - 20 and f[1] <= ey < f[1] + f[3]]
                if len(hit) != 1 or (mx <= ex < mx + mw and my <= ey < my + mh):
                    raise Stopped('cross-window drop must be inside another window\'s tab list, 20 pt from its edges, not under the source window')
                dest = min(frames, key=lambda f: abs(f[0] - hit[0][0]))
                self.drag_geometry['others'] = [(dest, hit[0][0] + hit[0][2] - 1)]
            # LEAD 13:00: drop inside the same sidebar, >= 20 pt from both rails.
            elif not (main[0][0] + 40 <= ex <= edge - 20):
                raise Stopped('drop point is within 20 pt of a drop-target rail or outside the sidebar')
            self.drag_rail_ids = set()
            self.drag_prior_frames = {tuple(f) for f in frames}
            self.drag_windows.clear(); self.drag_cg_ids.clear()
            self.drag_prior_cg_ids = {e['number'] for e in json.loads(run(self.native, 'windows', self.pid)) if e['onscreen']}
            self.log('drag-plan', start=start, end=[ex,ey], begin=[sx,sy])
            self.input('down', sx, sy, verified_pointer=True, target_predicate=step['target'])
            self.mouse_down = True
            time.sleep(float(step.get('press_seconds', .15)))
            self.drag_first_move_at = time.monotonic()
            # A short first stroke starts the drag; the guard then sees Arc's rails
            # within the LEAD 13:00 one-second window and registers them.
            fx, fy = sx + (ex - sx) * .08, sy + (ey - sy) * .08 + (4 if abs(ey - sy) < 4 else 0)
            self.input('dragto', fx, fy, 3, .12, verified_pointer=True)
            # input() spends its guard time before dispatch; the stroke itself lasts 0.12 s.
            self.drag_first_move_at = time.monotonic() - .14
            # Fast CG-only poll (no AX) so Arc's rails are first seen within one second.
            until = self.drag_first_move_at + .9
            while time.monotonic() < until:
                for w in json.loads(run(self.native, 'windows', self.pid)):
                    if w['onscreen'] and w['number'] not in self.drag_prior_cg_ids:
                        self.drag_rail(w, None)
                if len(self.drag_rail_ids) >= 3:
                    break
                time.sleep(.05)
            self.log('drag-rails-registered', ids=sorted(self.drag_rail_ids), after_first_move=time.monotonic() - self.drag_first_move_at)
            self.guard()
            sx, sy = fx, fy
            hold = step.get('hold_shot')
            steps = int(step.get('steps', 24)); seconds = float(step.get('seconds', .6))
            if hold:
                # Stop just short of the end, record the drop indicator, then finish.
                mx,my = sx+(ex-sx)*.97, sy+(ey-sy)*.97
                self.input('dragto', mx, my, steps, seconds, verified_pointer=True)
                self.remember_drag_windows()
                time.sleep(.25)
                self.input('dragto', ex, ey, 3, .1, verified_pointer=True)
                time.sleep(.2)
                self.shot(hold, step.get('ax_depth'))
            else:
                self.input('dragto', ex, ey, steps, seconds, verified_pointer=True)
                self.remember_drag_windows()
                time.sleep(.15)
            if step.get('cancel'):
                self.input('key', 'escape', '')
            self.input('up')
            self.mouse_down = False
            self.drag_first_move_at = None
            time.sleep(.3)
            self.shot(step['name'], step.get('ax_depth'))
        elif op == 'swipe_ax':
            if not self.s3_ruling():
                raise Stopped('swipe_ax needs the Session3 scope')
            n = self.target(step['target'])
            x,y = self.point_in(n, step.get('at'))
            self.input('click-check', x, y, verified_pointer=True, target_predicate=step['target'])
            dispatched = time.time()
            result = json.loads(run(self.native, 'swipe', x, y, step.get('dx',0), step.get('dy',0), int(step.get('steps',20)), float(step.get('seconds',.3)), *(['momentum'] if step.get('momentum') else []), timeout=10))
            if self.burst_events is not None:
                self.burst_events.append({'operation':'swipe','start_unix':dispatched,'end_unix':time.time()})
            self.log('swipe', target=n, point=[x,y], result=result)
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
            desired = self.original_frame if step.get('original') else [step.get('x', frame[0]), step.get('y', frame[1]), step['width'], step.get('height',frame[3])]
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
                    self.target(step['target'], frame_required=False, allow_disabled=True)
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
        try:
            self.stop_arc_log()
        except Exception as error:
            self.cleanup_ok = False
            self.log('arc-log-stop-incomplete', error=str(error))
        if getattr(self, 'opt_down', False):
            try:
                run(self.native, 'modkey', 'opt', 'up'); self.opt_down = False; self.log('modkey-released')
            except Exception as error:
                self.cleanup_ok = False; self.log('modkey-release-incomplete', error=str(error))
        try:
            self.end_companion()
        except Exception as error:
            self.cleanup_ok = False
            self.log('open-cover-end-incomplete', error=str(error))
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
    p.add_argument('--series', type=Path, nargs='+', help='M1 only: run these block scripts in one strict queue ticket (LEAD 10:22)')
    args = p.parse_args()
    if args.script.stat().st_size > 262144:
        p.error('capture script exceeds256KiB')
    script = json.loads(args.script.read_text())
    validate_script(script)
    for extra in args.series or []:
        if extra.stat().st_size > 262144:
            p.error('capture script exceeds256KiB')
        validate_script(json.loads(extra.read_text()))
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
        # 3 = the script named an AX target that was missing, ambiguous or disabled.
        code = 3 if isinstance(error, UnavailableAX) or str(error).startswith(('AX target', 'AX action unavailable', 'expected row selection',
                                                                          'movie did not contain', 'expected pointer result not observed',
                                                                          'expected pointer menu not observed', 'expected drag-start result',
                                                                          'drag end is outside', 'divider drag must', 'drop point is within',
                                                                          'manual accessibility needs', 'Session2 input requires')) else 1
    finally:
        session.cleanup()
    return code if session.cleanup_ok and session.permission_handoff is None else 1  # noqa: cleanup failure always 1


if __name__ == '__main__':
    sys.exit(main())
