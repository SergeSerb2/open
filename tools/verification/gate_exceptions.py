"""Exact, shrink-only exceptions for the real merge gate."""
import datetime
import json
import re
from pathlib import Path
import subprocess

FIELDS = {'row', 'status', 'reason', 'clearsWhen', 'owner', 'added', 'expires'}


def read_bounded(path, limit=1024 * 1024):
    if path.stat().st_size > limit:
        raise ValueError('gate exceptions exceed 1 MiB')
    data = json.loads(path.read_text())
    if not isinstance(data, list) or len(data) > 256:
        raise ValueError('gate exceptions require an array of at most 256 entries')
    seen = set()
    for entry in data:
        if not isinstance(entry, dict) or set(entry) != FIELDS:
            raise ValueError('unknown or missing gate exception fields')
        if any(not isinstance(v, str) or not v.strip() or len(v) > 1024 for v in entry.values()):
            raise ValueError('invalid gate exception string')
        if entry['row'] in seen or any(c in entry['row'] for c in '*?[]'):
            raise ValueError('duplicate or wildcard gate exception')
        if entry['status'] not in ('BLOCKED', 'DEFERRED'):
            raise ValueError('only BLOCKED and DEFERRED can be excepted')
        datetime.date.fromisoformat(entry['added'])
        seen.add(entry['row'])
    return data


def assert_shrink_only(root, entries):
    # Compare with the main this source is based on: the merge base of HEAD and
    # origin/main. A pinned main commit is its own base, so a pinned DMG run keeps
    # passing while origin/main moves on (DMG c, 2026-11-12); a PR still cannot
    # add entries relative to the main it merged.
    base = subprocess.run(['git', 'merge-base', 'HEAD', 'origin/main'], cwd=root, capture_output=True, text=True)
    if base.returncode:
        raise ValueError('no merge base with origin/main for the exceptions check')
    prior = subprocess.run(['git', 'show', base.stdout.strip() + ':tools/verification/gate-exceptions.json'],
                           cwd=root, capture_output=True, text=True)
    if prior.returncode:
        # First introduction is reviewed against the lead's explicit rulings.
        return
    if len(prior.stdout.encode()) > 1024 * 1024:
        raise ValueError('origin/main exceptions exceed 1 MiB')
    old = json.loads(prior.stdout)
    if not isinstance(old, list) or any(entry not in old for entry in entries):
        raise ValueError('gate exceptions can only shrink relative to the merge base with origin/main')


def panel_ready(path):
    """Only an affirmative LEAD section can expire the panel exceptions."""
    if not path.is_file():
        return False
    if path.stat().st_size > 1024 * 1024:
        raise ValueError('lead rulings exceed 1 MiB')
    lead = False
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith('#'):
            title = stripped.lstrip('#').strip()
            lead = title.startswith('LEAD ')
            if lead and re.search(r'\bM5 panel ready\b', title):
                return True
        elif lead and re.match(r'^M5 panel ready(?:[.!]|$)', re.sub(r'[*`_]', '', stripped).lstrip('- ')):
            return True
    return False


# Rows whose result depends on the Mac, not on the product: the row passes where an
# OS asset is installed and is BLOCKED where it is not. A pass on one Mac must not
# mark the exception STALE, because the entry is still needed on the others.
# page/X1_apple_backend: the French → English macOS translation asset (on the M1;
# not on the M5 or the rented Macs, 2026-11-12).
ENVIRONMENT_ROWS = {'page/X1_apple_backend'}


def evaluate(entries, rows, ready=False):
    """Return original row states, their policy verdicts, and a printed inventory."""
    by_id = {entry['row']: entry for entry in entries}
    if len({row['row'] for row in rows}) != len(rows):
        raise ValueError('duplicate merge-gate row identity')
    observed = set()
    inventory = []
    failed = False
    for row in rows:
        entry = by_id.get(row['row'])
        if entry:
            observed.add(row['row'])
        state = row['status']
        if (entry and entry['status'] == 'DEFERRED' and state == 'FAIL'
                and row.get('reason') == entry['reason']):
            # An approved product-gap row keeps its failed assertion in the
            # raw real-App receipt and reports the explicit deferral here.
            # Exact row AND reason are required; a repaired row becomes STALE.
            row['observedStatus'] = state
            state = row['status'] = 'DEFERRED'
        absent_target = (state == 'SKIP' and row['row'].startswith('cli/')
                         and row.get('reason', '').startswith('target does not exist yet: '))
        informative = state == 'INFO' and row.get('timing') is True and row.get('functionalOK') is True
        informative = informative or (state == 'INFO' and row['row'] == 'window/first_launch_after_install'
                                     and row.get('firstLaunchAfterInstall') is True)
        informative = informative or (state == 'INFO' and row['row'] in ('measure/media_idle_cpu_early', 'media/media_idle_cpu_early')
                                     and row.get('informational') is True)
        verdict = 'PASS' if state == 'PASS' else 'INFO' if informative else 'SKIP' if absent_target else 'FAIL'
        if entry:
            if ready and entry['expires'] == 'M5 panel ready':
                verdict = 'EXPIRED'
            elif state == 'PASS' and row['row'] in ENVIRONMENT_ROWS:
                verdict = 'PASS'
            elif state == 'PASS':
                verdict = 'STALE'
            elif state == entry['status'] and row.get('reason') == entry['reason']:
                verdict = 'EXCEPTION'
            else:
                verdict = 'MISMATCH'
            inventory.append(dict(entry, verdict='NOT_NEEDED_ON_THIS_MAC' if verdict == 'PASS' else verdict))
        row['policy'] = verdict
        failed = failed or verdict not in ('PASS', 'SKIP', 'EXCEPTION', 'INFO')
    for entry in entries:
        if entry['row'] not in observed:
            verdict = 'EXPIRED' if ready and entry['expires'] == 'M5 panel ready' else 'UNEXERCISED'
            inventory.append(dict(entry, verdict=verdict))
            failed = failed or verdict == 'EXPIRED'
    return failed, inventory
