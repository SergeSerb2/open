"""Finish only the screen worker's recorded App/native cleanup before unlock."""
import contextlib
import ctypes
import json
import os
from pathlib import Path
import runpy
import re
import signal
import subprocess
import time


def cleanup_owned(ledger, native_roots):
    entries = []
    if ledger.is_file():
        if ledger.stat().st_size > 1024 * 1024:
            raise ValueError('screen process ledger exceeds 1 MiB')
        lines = ledger.read_text().splitlines()
        if len(lines) > 512:
            raise ValueError('screen process ledger exceeds 512 App launches')
        for line in lines:
            entry = json.loads(line)
            root = Path(entry['root'])
            ordinary = (root.parent == Path.home()/'Library/Application Support'
                        and root.name.startswith('Open-E2E-'))
            # Onboarding replay deliberately requires an actual temporary
            # directory. Accept only that fixture's mkdtemp prefix and its
            # eight-character random suffix, alongside exact file identity.
            replay = (root.parent.resolve() == Path('/tmp').resolve()
                      and re.fullmatch(r'open-intro-replay-[a-z0-9_]{8}', root.name))
            if not ordinary and not replay:
                raise ValueError('screen ledger contains a foreign profile root')
            entries.append(entry)
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
    def path_for(pid):
        buffer = ctypes.create_string_buffer(4096)
        count = libproc.proc_pidpath(pid, buffer, len(buffer))
        return os.fsdecode(buffer.value) if count > 0 else ''
    def owned():
        found = set()
        rows = subprocess.check_output(['ps', '-ww', '-axo', 'pid=,args='], text=True)
        for line in rows.splitlines():
            fields = line.strip().split(None, 1)
            if len(fields) != 2:
                continue
            pid, command = int(fields[0]), fields[1]
            for entry in entries:
                marker = '--user-data-dir='+entry['root']
                if marker not in command:
                    continue
                suffix = command.split(marker, 1)[1]
                if suffix and not suffix.startswith(('/', ' ')):
                    continue
                actual = path_for(pid)
                try:
                    stat = os.stat(actual)
                except OSError:
                    continue
                same_file = (stat.st_dev, stat.st_ino) == (entry['device'], entry['inode'])
                helper = os.path.realpath(actual).startswith(os.path.realpath(entry['bundle'])+'/Contents/Frameworks/')
                if same_file or helper:
                    found.add(pid)
        return found
    # The inner native worker normally does this itself. The known private
    # parent also lets us finish it after a forced worker termination.
    native_cleanup = runpy.run_path(str(Path(__file__).with_name('check.py')))['stop_native_suite_apps']
    for root in native_roots.iterdir():
        if root.is_dir() and root.name.startswith('open-onscreen-suite-'):
            native_cleanup(str(root))
    deadline = time.monotonic()+10
    while owned() and time.monotonic() < deadline:
        time.sleep(.1)
    remaining = owned()
    if not remaining:
        return
    for signum in (signal.SIGTERM, signal.SIGKILL):
        for pid in owned():
            with contextlib.suppress(ProcessLookupError):
                os.kill(pid, signum)
        deadline = time.monotonic()+3
        while owned() and time.monotonic() < deadline:
            time.sleep(.1)
    if owned():
        raise RuntimeError('suite-owned App helpers survived outer cleanup')
    raise RuntimeError('suite required emergency outer App cleanup; receipt is not accepted')
