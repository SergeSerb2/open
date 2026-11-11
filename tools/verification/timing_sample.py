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


def preflight(require_quiet=False):
    deadline = time.monotonic() + (360 if require_quiet else 10)
    readings = [snapshot()]
    while True:
        time.sleep(10)
        readings.append(snapshot())
        valid = all(r['load'][0] <= 3 and r['foreignCPU'] <= 200 for r in readings[-2:])
        if valid or time.monotonic() >= deadline:
            return dict(before=readings[-2:], validBefore=valid,
                        waitSeconds=readings[-1]['at']-readings[0]['at'])


def finish(sample):
    sample['after'] = snapshot()
    # After-run load includes our own work and is deliberately not a condition.
    sample['valid'] = sample['validBefore'] and sample['after']['foreignCPU'] <= 200
    return sample
