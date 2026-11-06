#!/usr/bin/env python3
"""Real LaunchServices owner-death proof. Run under the on-screen lock.

The negative control removes only the owner env argument at the launch boundary.
No app behavior is mocked. Each runner is killed with SIGKILL after socket ping.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = str(ROOT / 'build/Debug/Open.app')


def matches(pattern):
    result = subprocess.run(['pgrep', '-fl', pattern], capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise RuntimeError(result.stderr)
    return result.stdout.splitlines()


def request(path, command, **args):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(30)
        sock.connect(str(path))
        sock.sendall((json.dumps(dict(id=1, cmd=command, args=args)) + '\n').encode())
        data = b''
        while not data.endswith(b'\n'):
            part = sock.recv(65536)
            if not part:
                break
            data += part
        return json.loads(data)


def ping(path):
    return request(path, 'ping')


def run(negative, output, download_base=None):
    # Stop at the first successful real ping, before the suite can mutate any
    # shared defaults. The parent can then inspect the app and kill only runner.
    code = '''
import os, runpy, signal, subprocess, sys
sys.path.insert(0, 'tools/e2e')
import engine_e2e as e
original_call = e.Open.call
def call(self, cmd, *args, **kwargs):
    result = original_call(self, cmd, *args, **kwargs)
    if cmd == 'ping': os.kill(os.getpid(), signal.SIGSTOP)
    return result
e.Open.call = call
'''
    if negative:
        code += '''
original_popen = subprocess.Popen
def popen(args, *a, **kw):
    if isinstance(args, list) and args[0] == '/usr/bin/open':
        args = list(args)
        for i in range(len(args)-1, 0, -1):
            if args[i].startswith('OPEN_E2E_OWNER_PID=') and args[i-1] == '--env':
                del args[i-1:i+1]
    return original_popen(args, *a, **kw)
subprocess.Popen = popen
'''
    code += "sys.argv = ['engine_e2e.py', '--only', 'shell', '--style', 'chrome', '--keep']; e.main()\n"
    roots = []
    runner = None
    with (output / ('download.log' if download_base else 'negative.log' if negative else 'positive.log')).open('w') as log:
        try:
            runner = subprocess.Popen([sys.executable, '-c', code], cwd=ROOT,
                                      stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            prefix = 'Open-E2E-shell-chrome-%d-' % runner.pid
            support = Path.home() / 'Library/Application Support'
            deadline = time.monotonic() + 90
            reply = None
            while time.monotonic() < deadline:
                roots = list(support.glob(prefix + '*'))
                if roots:
                    try:
                        reply = ping(roots[0] / 'automation.sock')
                        break
                    except (OSError, ValueError):
                        pass
                if runner.poll() is not None:
                    raise RuntimeError('runner exited before ping')
                time.sleep(.05)
            assert reply, 'app did not answer ping'
            if download_base:
                sock = roots[0] / 'automation.sock'
                def call(command, **args):
                    response = request(sock, command, **args)
                    assert response.get('ok'), response
                    return response['result']
                opened = call('open', url=download_base + '/')
                call('wait', tab=opened['id'])
                tab = next(item for item in call('tabs') if item['id'] == opened['id'])
                call('download-settings', profile=tab['profile'], directory=str(roots[0] / 'Downloads'), ask=False)
                # If the no-prompts guard regresses, dismiss its real alert with
                # the existing native-button policy and fail on its log line.
                call('download-policy', quit='keep')
                call('navigate', tab=tab['id'], url=download_base + '/slow')
                download_deadline = time.monotonic() + 15
                while time.monotonic() < download_deadline:
                    downloads = call('downloads-state')
                    if downloads['running'] and any(item['received'] > 0 for item in downloads['items']):
                        break
                    time.sleep(.05)
                assert downloads['running'] and any(item['received'] > 0 for item in downloads['items']), downloads
            before = matches(BUNDLE) + matches(prefix)
            assert before, 'no matching app processes'
            started = time.monotonic()
            os.kill(runner.pid, signal.SIGKILL)  # deliberately NOT killpg
            runner.wait()
            remaining = before
            while time.monotonic() - started < 10:
                remaining = matches(BUNDLE) + matches(prefix)
                if not remaining:
                    break
                time.sleep(.1)
            elapsed = time.monotonic() - started
            if negative:
                assert remaining, 'negative control unexpectedly exited'
                assert ping(roots[0] / 'automation.sock'), 'negative app stopped answering'
            else:
                assert not remaining, 'orphan processes: ' + repr(remaining)
                launch_logs = list((ROOT / 'docs/engine-spike').rglob('*.launch-*.log')) + [p for scratch in Path(tempfile.gettempdir()).glob(prefix + '*-scratch-*') for p in scratch.rglob('*.launch-*.log')]
                message = 'Open: e2e owner %d exited; quitting' % runner.pid
                texts = [p.read_text(errors='replace') for p in launch_logs]
                assert sum(value.count(message) for value in texts) == 1, 'expected one owner-exit log line'
                if download_base:
                    assert not any('downloads-quit-alert-presented' in value for value in texts if message in value), 'owner death presented download quit alert'
            return dict(ok=True, negative=negative, active_download=bool(download_base), ping=reply, elapsed=elapsed,
                        before=before, remaining=remaining)
        finally:
            if runner is not None:
                if runner.poll() is None:
                    runner.kill(); runner.wait()
                # Only this worktree's app and its uniquely named profile.
                for row in matches(BUNDLE) + matches('Open-E2E-shell-chrome-%d-' % runner.pid):
                    try:
                        os.kill(int(row.split()[0]), signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            cleanup_deadline = time.monotonic() + 5
            while matches(BUNDLE) and time.monotonic() < cleanup_deadline:
                time.sleep(.05)
            assert not matches(BUNDLE), 'cleanup left app helpers'
            for root in roots:
                shutil.rmtree(root, ignore_errors=True)
                shutil.rmtree(Path.home() / 'Library/Caches' / root.name, ignore_errors=True)
                for scratch in Path(tempfile.gettempdir()).glob(root.name + '-scratch-*'):
                    shutil.rmtree(scratch, ignore_errors=True)


if __name__ == '__main__':
    output = Path(sys.argv[1]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    from downloads import server
    results = [run(False, output), run(True, output)]
    with server() as base:
        results.append(run(False, output, download_base=base))
    assert not matches(BUNDLE), 'cleanup left app helpers'
    (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results, indent=2))
