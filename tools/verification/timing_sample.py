"""Quiet-sample evidence for budget rows; never changes a numerical limit."""
import os
from pathlib import Path
import subprocess
import time


def snapshot():
    processes = []
    for line in subprocess.check_output(['ps', '-axo', 'pid=,ppid=,pcpu=,comm='], text=True).splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) == 4:
            processes.append(dict(pid=int(fields[0]), parent=int(fields[1]),
                                  cpu=float(fields[2]), name=Path(fields[3]).name))
    owned = {os.getpid()}
    for _ in range(64):
        expanded = owned | {p['pid'] for p in processes if p['parent'] in owned}
        if expanded == owned:
            break
        owned = expanded
    foreign = sorted((p for p in processes if p['pid'] not in owned and p['name'] != 'WindowServer'),
                     key=lambda p: p['cpu'], reverse=True)
    return dict(at=time.time(), load=list(os.getloadavg()),
                foreignCPU=sum(p['cpu'] for p in foreign), topFiveForeign=foreign[:5])


def power():
    """Power source and Low Power Mode, read-only (`pmset -g batt`, `pmset -g`).

    On battery, or with Low Power Mode on, macOS caps the CPU: every launch
    phase and every budget row is slower by a similar factor (M1, 2026-11-12:
    sidebar first draw 229 ms on AC, 329 ms on battery with Low Power Mode).
    A Mac without a battery reports AC Power and has no lowpowermode key.
    """
    def read(*command):
        try:
            return subprocess.run(command, capture_output=True, text=True, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            return ''
    battery, settings = read('pmset', '-g', 'batt'), read('pmset', '-g')
    source = next((part for part in battery.split("'")[1:2]), 'unknown')
    low = next((line.split()[-1] == '1' for line in settings.splitlines()
                if line.split()[:1] == ['lowpowermode']), False)
    return dict(source=source, lowPowerMode=low, full=source == 'AC Power' and not low)


def preflight(require_quiet=False, cancelled=lambda: False):
    state = power()
    if require_quiet and not state['full']:
        # Fail fast: waiting cannot make this sample valid.
        raise RuntimeError('timing preflight refused: power source %r, Low Power Mode %s; '
                           'timing rows need AC Power with Low Power Mode off'
                           % (state['source'], 'on' if state['lowPowerMode'] else 'off'))
    deadline = time.monotonic() + (360 if require_quiet else 10)
    readings = [snapshot()]
    while True:
        for _ in range(40):
            if cancelled():
                raise InterruptedError('timing preflight cancelled before App launch')
            time.sleep(.25)
        readings.append(snapshot())
        valid = all(r['load'][0] <= 3.5 for r in readings[-2:])
        if valid or time.monotonic() >= deadline:
            return dict(before=readings[-2:], validBefore=valid, power=state,
                        readings=readings, waitSeconds=readings[-1]['at']-readings[0]['at'])


def finish(sample):
    sample['after'] = snapshot()
    # After-run load includes our own work and is deliberately not a condition.
    sample['valid'] = sample['validBefore']
    return sample
