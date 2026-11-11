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
    prior = subprocess.run(['git', 'show', 'origin/main:tools/verification/gate-exceptions.json'],
                           cwd=root, capture_output=True, text=True)
    if prior.returncode:
        # First introduction is reviewed against the lead's explicit rulings.
        return
    if len(prior.stdout.encode()) > 1024 * 1024:
        raise ValueError('origin/main exceptions exceed 1 MiB')
    old = json.loads(prior.stdout)
    if not isinstance(old, list) or any(entry not in old for entry in entries):
        raise ValueError('gate exceptions can only shrink relative to origin/main')


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
        verdict = 'PASS' if state == 'PASS' else 'SKIP' if absent_target else 'FAIL'
        if entry:
            if ready and entry['expires'] == 'M5 panel ready':
                verdict = 'EXPIRED'
            elif state == 'PASS':
                verdict = 'STALE'
            elif state == entry['status'] and row.get('reason') == entry['reason']:
                verdict = 'EXCEPTION'
            else:
                verdict = 'MISMATCH'
            inventory.append(dict(entry, verdict=verdict))
        row['policy'] = verdict
        failed = failed or verdict not in ('PASS', 'SKIP', 'EXCEPTION')
    for entry in entries:
        if entry['row'] not in observed:
            verdict = 'EXPIRED' if ready and entry['expires'] == 'M5 panel ready' else 'UNEXERCISED'
            inventory.append(dict(entry, verdict=verdict))
            failed = failed or verdict == 'EXPIRED'
    return failed, inventory
