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


def ping(path):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(1)
        sock.connect(str(path))
        sock.sendall(b'{"id":1,"cmd":"ping","args":{}}\n')
        data = b''
        while not data.endswith(b'\n'):
            part = sock.recv(65536)
            if not part:
                break
            data += part
        return json.loads(data)


def run(negative, output):
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
    with (output / ('negative.log' if negative else 'positive.log')).open('w') as log:
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
                assert sum(p.read_text(errors='replace').count(message) for p in launch_logs) == 1, 'expected one owner-exit log line'
            return dict(ok=True, negative=negative, ping=reply, elapsed=elapsed,
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
            for root in roots:
                shutil.rmtree(root, ignore_errors=True)
                shutil.rmtree(Path.home() / 'Library/Caches' / root.name, ignore_errors=True)
                for scratch in Path(tempfile.gettempdir()).glob(root.name + '-scratch-*'):
                    shutil.rmtree(scratch, ignore_errors=True)


if __name__ == '__main__':
    output = Path(sys.argv[1]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    results = [run(False, output), run(True, output)]
    assert not matches(BUNDLE), 'cleanup left app helpers'
    (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results, indent=2))
