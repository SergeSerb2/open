"""Automation socket stress: clients that disconnect in the middle of a reply.

The server once wrote a late reply to a closed client's fd number. The kernel reuses fd numbers at
once, so the bytes went to another client, or to a guarded system fd (EXC_GUARD crash, 2026-11-12).
Rows: a witness client that connects right after each abandoned client gets only its own replies;
half-open and oversize-free garbage clients do no harm; the App is the same process at the end and
has written no crash report.
"""
import glob
import json
import os
import socket
import time


def connect(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(path)
    return s


def read_lines(s, count):
    data = b''
    while data.count(b'\n') < count:
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    return [json.loads(line) for line in data.split(b'\n') if line]


def run(factory, results, tmp, h):
    def row(name, ok, **detail):
        results[name] = dict(ok=bool(ok), **detail)
    reports = os.path.expanduser('~/Library/Logs/DiagnosticReports/Open-*.ips')
    before = set(glob.glob(reports))
    app = factory(urls=('about:blank',), fresh=True)
    pid = app.call('ping')['pid']
    rounds = int(os.environ.get('OPEN_AUTOMATION_STRESS_ROUNDS', '3000'))
    foreign, missing, errors = [], 0, []
    started = time.time()
    for i in range(rounds):
        try:
            # The abandoned client: several requests, then close without reading a byte.
            a = connect(app.sock)
            a.sendall(b''.join(json.dumps({'id': 'abandoned-%d-%d' % (i, k), 'cmd': 'ping'}).encode() + b'\n' for k in range(8)))
            a.close()
            # The witness usually gets the fd number the server just closed.
            b = connect(app.sock)
            b.sendall(json.dumps({'id': 'witness-%d' % i, 'cmd': 'ping'}).encode() + b'\n')
            replies = read_lines(b, 1)
            # Give a late foreign reply a moment to show up, on some rounds.
            if i % 50 == 0:
                b.settimeout(.05)
                try: replies += [json.loads(l) for l in b.recv(65536).split(b'\n') if l]
                except (socket.timeout, TimeoutError): pass
            b.close()
            ids = [r.get('id') for r in replies]
            if 'witness-%d' % i not in ids: missing += 1
            foreign += [x for x in ids if x != 'witness-%d' % i]
        except Exception as error:  # a dead App shows up here as connection errors
            errors.append('%d: %s' % (i, error))
            if len(errors) > 5: break
    row('witness_gets_only_its_replies', not foreign and not missing and not errors, rounds=rounds, foreign=foreign[:5],
        foreignCount=len(foreign), missing=missing, errors=errors[:3], seconds=round(time.time() - started, 1))

    # Clients that close in the middle of a request line, and many parallel abandoned clients.
    try:
        for i in range(200):
            s = connect(app.sock); s.sendall(b'{"id": "half-%d", "cmd": "pi' % i); s.close()
        batch = [connect(app.sock) for _ in range(100)]
        for k, s in enumerate(batch): s.sendall(json.dumps({'id': 'batch-%d' % k, 'cmd': 'ping'}).encode() + b'\n')
        for s in batch[::2]: s.close()
        kept = [read_lines(s, 1) for s in batch[1::2]]
        for s in batch[1::2]: s.close()
        ok = all(len(r) == 1 and r[0].get('id') == 'batch-%d' % (2 * k + 1) for k, r in enumerate(kept))
        row('half_lines_and_parallel_clients', ok, kept=len(kept))
    except Exception as error:
        row('half_lines_and_parallel_clients', False, error=str(error))

    time.sleep(1)
    try: alive = app.call('ping')['pid']
    except Exception as error: alive = str(error)
    new_reports = sorted(set(glob.glob(reports)) - before)
    row('app_alive_no_crash_report', alive == pid and not new_reports, pid=pid, after=alive, reports=[os.path.basename(p) for p in new_reports])
