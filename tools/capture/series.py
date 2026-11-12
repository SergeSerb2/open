#!/usr/bin/env python3
"""Run several capture blocks inside ONE M1 queue ticket (LEAD 10:22, plan C3).

The caller starts this under `heavy.sh /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock`,
so the build slot and the screen lock are held together for the whole series.
Each block still launches, guards and quits its own app (<=170 s per block).
The series stops before a block that could end after the 10-minute ticket limit.
"""
import json, subprocess, sys, time
from pathlib import Path

LIMIT, BLOCK = 900, 175  # LEAD 14:00: series up to 15 minutes


GUARD_STOPS = ('system', 'frontmost', 'foreground', 'another new window', 'display changed', 'permission',
               'Accessibility', 'covered', 'Notification Centre', 'signal', 'deadline', 'sign-in')


def script_level_stop(out):
    """True when the block stopped on its own script expectation and Arc has exited."""
    reason = ''
    log = out / 'session.jsonl'
    if log.exists():
        for line in log.read_text().splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get('step') == 'STOP':
                reason = row.get('reason', '')
    if not reason or any(g in reason for g in GUARD_STOPS):
        return False
    for _ in range(40):
        if subprocess.run(['/usr/bin/pgrep', '-x', 'Arc'], capture_output=True).returncode != 0:
            return True
        time.sleep(.25)
    return False


def main():
    stage, output, native, burst, launcher, backend = map(str, sys.argv[1:7])
    names = [n for n in sys.argv[7:] if not n.startswith('--compile=')]
    start = time.monotonic()
    for spec in (n for n in sys.argv[7:] if n.startswith('--compile=')):
        # The ticket already holds the build slot (heavy.sh is the outer command).
        name, source, binary = spec[len('--compile='):].split(':')
        Path(binary).parent.mkdir(parents=True, exist_ok=True)
        flags = ['-parse-as-library'] if name == 'burst' else []
        built = subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '6', *flags, source, '-o', binary])
        print(json.dumps({'compiled': name, 'exit': built.returncode, 'seconds': round(time.monotonic() - start, 1)}), flush=True)
        if built.returncode:
            return 74
    receipt = []
    code = 0
    for name in names:
        if time.monotonic() - start + BLOCK > LIMIT:
            receipt.append({'block': name, 'skipped': 'ticket limit'})
            code = code or 75
            break
        out = Path(output) / name
        out.mkdir(parents=True, exist_ok=True)
        t0 = time.monotonic()
        p = subprocess.run(['python3', str(Path(stage) / 'session.py'), str(Path(stage) / 'scripts' / (name + '.json')),
                            '--backend', backend, '--out', str(out), '--native', native, '--burst-tool', burst,
                            '--rulings', str(Path(stage) / 'lead-rulings.txt'), '--pixel-launcher', launcher])
        receipt.append({'block': name, 'exit': p.returncode, 'seconds': round(time.monotonic() - t0, 2)})
        if backend == 'arc':
            # The block launched its own Arc inside this ticket. A modal dialog can refuse
            # the normal quit; never leave it running past the block (C3 17:42 note).
            for _ in range(40):
                if subprocess.run(['/usr/bin/pgrep', '-x', 'Arc'], capture_output=True).returncode != 0:
                    break
                time.sleep(.25)
            else:
                pids = subprocess.run(['/usr/bin/pgrep', '-x', 'Arc'], capture_output=True, text=True).stdout.split()
                subprocess.run(['/bin/kill', '-TERM', *pids])
                receipt[-1]['owned_arc_terminated'] = pids
                time.sleep(2)
        print(json.dumps(receipt[-1]), flush=True)
        if p.returncode:
            code = code or p.returncode
            # Exit 3: a script-level AX miss after a clean quit; the next block is independent.
            if p.returncode != 3 and not script_level_stop(out):
                break
    leftover = subprocess.run(['/usr/bin/pgrep', '-x', 'Arc'], capture_output=True, text=True).stdout.split()
    receipt.append({'series_seconds': round(time.monotonic() - start, 2), 'arc_running_after': leftover})
    (Path(output) / 'series-receipt.json').write_text(json.dumps(receipt, indent=2))
    return code or (76 if leftover and backend == 'arc' else 0)


if __name__ == '__main__':
    sys.exit(main())
