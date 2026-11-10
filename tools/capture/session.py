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
import os
from pathlib import Path
import plistlib
import re
import signal
import socket
import subprocess
import sys
import time

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


class Session:
    def __init__(self, script, out, backend, native):
        self.script, self.out, self.backend = script, out, backend
        self.native = native
        self.started = time.monotonic()
        self.max_seconds = min(float(script.get('max_seconds', 170)), 180)
        self.initial = self.state()
        self.pid = None
        self.proc = None
        self.owned = False
        self.window = script.get('window')
        self.active_window = None
        self.gaps = []
        self.cleaning = False
        self.original_frame = None
        self.mouse_down = False
        self.saved_defaults = {}
        self.logfile = (out / 'session.jsonl').open('a')
        self.rulings = QUESTIONS.read_text() if QUESTIONS.exists() else ''
        (out / 'lead-rulings.txt').write_text(self.rulings)
        self.version = self.arc_version()
        self.log('start', state=self.initial, arc_version=self.version,
                 rulings_sha256=hashlib.sha256(self.rulings.encode()).hexdigest())

    def arc_version(self):
        with open('/Applications/Arc.app/Contents/Info.plist', 'rb') as stream:
            p = plistlib.load(stream)
        return [p.get('CFBundleShortVersionString'), p.get('CFBundleVersion')]

    def state(self):
        return json.loads(run(self.native, 'state'))

    def log(self, step, **kwargs):
        self.logfile.write(json.dumps({'t': datetime.datetime.now().astimezone().isoformat(),
                                      'monotonic': time.monotonic(), 'step': step, **kwargs}) + '\n')
        self.logfile.flush()

    def guard(self, event=False):
        if time.monotonic() - self.started >= self.max_seconds:
            raise Stopped('short-block deadline reached')
        now = self.state()
        if now['screens'] != self.initial['screens']:
            raise Stopped('display changed')
        if event and now['frontmostPID'] != self.pid:
            raise Stopped('frontmost app changed; no event sent')
        if not now['trusted'] and self.backend == 'arc':
            raise Stopped('Accessibility is not trusted')
        if now['frontmostBundle'] in ('com.apple.SecurityAgent', 'com.apple.systempreferences'):
            raise Stopped('system dialog or System Settings is frontmost')
        if self.backend == 'arc' and self.pid:
            # Inspect only the owned app. Never interact with sign-in/permission UI.
            windows = json.loads(run(SCRIPTS / 'axframes', self.pid, 3))
            for n in walk(windows):
                title = str(n.get('title', ''))
                if n.get('subrole') == 'AXSystemDialog' or re.search(r'^(Sign [Ii]n|Log [Ii]n|Accessibility Access|Screen Recording)$', title):
                    raise Stopped('sign-in or system permission dialog in Arc')
        return now

    def call(self, cmd, **args):
        if not self.cleaning:
            self.guard(event=cmd in ('key', 'mouse', 'type', 'sidebar-click', 'sidebar-key', 'download-home'))
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
        reply = json.loads(buf)
        if not reply.get('ok'):
            raise RuntimeError(str(reply.get('error')))
        return reply['result']

    def launch(self, step):
        if self.backend == 'arc':
            if not self.initial['trusted'] or not self.initial['screenRecording']:
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
        for command in ('window-state', 'space-manager-state', 'library-captures-state'):
            try:
                result[command] = self.call(command)
            except RuntimeError as error:
                result[command] = {'unavailable': str(error)}
        return result

    def target(self, predicate):
        menu = str(predicate.get('role','')).startswith('AXMenu')
        nodes = [n for n in walk(self.tree(include_menus=menu)) if matches(n, predicate) and n.get('frame', [0, 0, 0, 0])[2] > 0]
        if 'index' in predicate:
            index = int(predicate['index'])
            if index >= len(nodes):
                raise Stopped('AX target index unavailable')
            nodes = [nodes[index]]
        if len(nodes) != 1:
            raise Stopped('AX target must match exactly one visible element; matched %d' % len(nodes))
        n = nodes[0]
        if n.get('enabled') is False or 'disabled' in n.get('flags', []):
            raise Stopped('AX target is disabled')
        return n

    def input(self, *args):
        self.guard(event=True)
        run(SCRIPTS / 'uidrive', *args)

    def shot(self, name):
        self.guard()
        path = self.out / (name + '.png')
        tree = self.tree()
        (self.out / (name + '.ax.json')).write_text(json.dumps(tree, indent=2))
        if self.backend == 'arc':
            wins = json.loads(run(self.native, 'windows', self.pid))
            (self.out / (name + '.windows.json')).write_text(json.dumps(wins, indent=2))
            wins = [w for w in wins if w['onscreen'] and w['bounds']['Width'] > 2 and w['bounds']['Height'] > 2]
            if not wins:
                raise Stopped('no owned visible window')
            ax_main = [n['frame'] for n in walk(tree) if n.get('role') == 'AXWindow' and n.get('main') and n.get('frame')]
            matched = [w for w in wins if any(all(abs(w['bounds'][key] - value) < 2 for key,value in zip(('X','Y','Width','Height'),f)) for f in ax_main)]
            base = matched or [w for w in wins if w['layer'] == 0 and w['bounds']['Width'] > 100]
            if not base:
                raise Stopped('no owned browser window matched the AX geometry')
            win = next((w for w in wins if w['number'] == self.window), None) or max(base, key=lambda w: w['bounds']['Width'] * w['bounds']['Height'])
            self.active_window = win['number']
            subprocess.run(['/usr/sbin/screencapture', '-x', '-o', '-l', str(win['number']), str(path)], check=True, timeout=8)
            metadata = {'window': win, 'screens': self.initial['screens']}
            # Context menus/popovers are separate windows. Preserve each own
            # visible window as a native-scale PNG, never the whole desktop.
            for extra in wins:
                if extra['number'] != win['number']:
                    subprocess.run(['/usr/sbin/screencapture', '-x', '-o', '-l', str(extra['number']), str(self.out / (name + '-window-' + str(extra['number']) + '.png'))], check=True, timeout=8)
        else:
            kwargs = {'window': self.window} if self.window is not None else {}
            metadata = self.call('snapshot', path=str(path), **kwargs)
        (self.out / (name + '.ax.json')).write_text(json.dumps(tree, indent=2))
        (self.out / (name + '.meta.json')).write_text(json.dumps(metadata, indent=2))
        self.log('shot', frame_file=str(path), ax_file=name + '.ax.json')
        return path

    def burst(self, step):
        self.shot(step['name'] + '-before')
        directory = self.out / step['name']
        directory.mkdir(exist_ok=True)
        fps = min(float(step.get('fps', 20)), 120)
        duration = min(float(step.get('duration', 1)), 5)
        stream_tool = Path('/tmp/open-capture-burst')
        if self.backend == 'arc' and stream_tool.exists():
            self.guard(event=True)
            log = (directory / 'stream.log').open('a')
            process = subprocess.Popen([str(stream_tool), str(self.pid), str(self.active_window), str(directory), str(int(fps)), str(duration), str(self.initial['screens'][0]['scale'])], stdout=log, stderr=subprocess.STDOUT)
            try:
                ready_deadline = time.monotonic() + 4
                while not (directory / 'ready').exists():
                    self.guard(event=True)
                    if process.poll() is not None or time.monotonic() > ready_deadline:
                        raise Stopped('window stream did not become ready; inspect stream.log')
                    time.sleep(.02)
                time.sleep(float(step.get('trigger_after', .15)))
                if step.get('trigger'):
                    self.step(step['trigger'])
                result = process.wait(timeout=8)
                if result:
                    raise Stopped('window stream stopped; exit %d' % result)
                self.log('burst', method='ScreenCaptureKit', receipt=str(directory / 'timestamps.json'))
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=3)
                log.close()
            self.shot(step['name'] + '-after')
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
                subprocess.run(['/usr/sbin/screencapture', '-x', '-o', '-l', str(self.active_window), str(path)], check=True, timeout=8)
            else:
                self.call('snapshot', path=str(path), **({'window': self.window} if self.window is not None else {}))
            after = time.monotonic()
            frames.append({'frame': path.name, 'start': before, 'end': after, 'elapsed': (before + after) / 2 - start, 'uncertainty': (after - before) / 2})
            if after - start >= duration:
                break
            time.sleep(max(0, start + (i + 1) / fps - time.monotonic()))
        (directory / 'timestamps.json').write_text(json.dumps({'requested_fps': fps, 'duration': duration, 'frames': frames, 'effective_fps': (len(frames) - 1) / max(.001, frames[-1]['elapsed'] - frames[0]['elapsed']) if len(frames) > 1 else 0}, indent=2))
        self.shot(step['name'] + '-after')

    def step(self, step):
        self.guard()
        op = step['op']
        self.log('begin', operation=step)
        # A mapping is explicit. The same declarative script runs both apps.
        mapping = step.get('open') if self.backend == 'open' else None
        if self.backend == 'open' and op not in ('launch', 'shot', 'axdump', 'burst', 'sleep') and mapping is None:
            self.gaps.append({'step': step, 'finding': 'Open: no action'})
            self.log('no-action', operation=step, finding='Open: no action')
            return
        if mapping is not None:
            for action in mapping if isinstance(mapping, list) else [mapping]:
                args = dict(action.get('args', {}))
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
        elif op in ('click_ax', 'hover_ax', 'down_ax', 'scroll'):
            n = self.target(step['target'])
            x, y, w, h = n['frame']
            self.log('target', ax_target=n)
            if op == 'scroll':
                self.input('scroll', step['dy'], step.get('dx', 0), x + w / 2, y + h / 2)
            elif op == 'down_ax':
                self.input('down', x + w / 2, y + h / 2)
                self.mouse_down = True
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
            result = json.loads(run(self.native, 'set-frame', self.pid, frame[0], frame[1], step['width'], step.get('height',frame[3])))
            self.log('resize-result', result=result)
            if any(result.values()):
                raise Stopped('AX resize refused')
        elif op == 'type':
            # Require a real focused text field before Unicode events.
            if not any(n.get('focused') and n.get('role') in ('AXTextField', 'AXTextArea', 'AXComboBox', 'AXSearchField') for n in walk(self.tree())):
                raise Stopped('no verified focused text input')
            self.input('type', step['text'])
        elif op == 'wait_ax':
            end = time.monotonic() + min(float(step.get('timeout', 5)), 10)
            while True:
                try:
                    self.target(step['target'])
                    break
                except Stopped:
                    if time.monotonic() >= end:
                        raise
                    self.guard()
                    time.sleep(.1)
        elif op == 'shot':
            self.shot(step['name'])
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
        # Never send a key to quit. NSRunningApplication.terminate is addressed
        # to the captured PID and cannot type in a user's new frontmost app.
        now = self.state()
        if self.backend == 'arc' and now['frontmostPID'] == self.pid:
            if self.mouse_down:
                run(SCRIPTS / 'uidrive', 'up')
            if self.original_frame:
                self.log('restore-frame', result=json.loads(run(self.native, 'set-frame', self.pid, *self.original_frame)))
            run(SCRIPTS / 'uidrive', 'move', *self.initial['pointer'])
        elif self.backend == 'arc':
            self.log('pointer-restore-skipped', reason='foreground takeover; no more system events')
        if self.owned and self.pid:
            if self.backend == 'arc':
                run(self.native, 'quit', self.pid)
            else:
                try:
                    for key, value in self.saved_defaults.items():
                        self.call('defaults', key=key, value=value)
                    self.call('quit')
                except Exception as error:
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
                self.log('quit-incomplete', pid=self.pid)
        current = self.state()
        # Restore prior app unless the user already selected a new app.
        if current['frontmostPID'] in (self.pid, 0) or now['frontmostPID'] == self.pid:
            try:
                run(self.native, 'activate', self.initial['frontmostPID'])
            except Exception as error:
                self.log('restore-error', error=str(error))
        self.log('cleanup', final=self.state(), arc_version=self.arc_version(), elapsed=time.monotonic() - self.started)
        (self.out / 'no-actions.json').write_text(json.dumps(self.gaps, indent=2))
        self.logfile.close()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('script', type=Path)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--backend', choices=('arc', 'open'), default='arc')
    p.add_argument('--native', type=Path, default=Path('/tmp/open-capture-native'))
    args = p.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    script = json.loads(args.script.read_text())
    (args.out / 'script.json').write_text(json.dumps(script, indent=2))
    session = Session(script, args.out, args.backend, args.native)
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
    return code


if __name__ == '__main__':
    sys.exit(main())
