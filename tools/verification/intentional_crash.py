"""Attribute only the predeclared DevTools Page.crash renderer fault."""
import datetime
import json
from pathlib import Path


def read_markers(path):
    if not path.is_file():
        return []
    if path.stat().st_size > 64 * 1024:
        raise ValueError('intentional fault ledger exceeds 64 KiB')
    markers = [json.loads(line) for line in path.read_text().splitlines()]
    if len(markers) > 16:
        raise ValueError('too many intentional faults')
    return markers


def expected_reports(names, markers, report_root):
    """A marker never exempts App crashes, arbitrary helpers, or other stacks.

    Retain reports on disk. PID ownership is recorded before the command;
    the report must name that App parent and a renderer alive at that point.
    The abort must occur on the DevTools command thread within 30 seconds.
    One declared command can account for at most one report.
    """
    accepted = set()
    used = set()
    for name in sorted(names):
        path = Path(report_root) / name
        if path.suffix != '.ips' or path.stat().st_size > 16 * 1024 * 1024:
            continue
        try:
            header, body = path.read_text().split('\n', 1)
            header, body = json.loads(header), json.loads(body)
            timestamp = datetime.datetime.strptime(body['captureTime'], '%Y-%m-%d %H:%M:%S.%f %z').timestamp()
            thread = body['threads'][body['faultingThread']]
            symbols = [frame.get('symbol', '') for frame in thread['frames']]
            if (header.get('bundleID') != 'io.github.sergeserb2.open.helper.renderer'
                    or body.get('procName') != 'Open Helper (Renderer)'
                    or body.get('exception', {}).get('signal') != 'SIGABRT'
                    or 'abort' not in symbols
                    or not any(symbol.startswith('blink::DevToolsSession::IOSession::DispatchProtocolCommand(')
                               for symbol in symbols)):
                continue
            matches = [i for i, marker in enumerate(markers) if i not in used
                       and marker.get('method') == 'Page.crash'
                       and body.get('parentPid') == marker.get('appPID')
                       and body.get('pid') in marker.get('rendererPIDs', [])
                       and marker['started'] <= timestamp <= marker['started'] + 30]
            if len(matches) == 1:
                accepted.add(name)
                used.add(matches[0])
        except (OSError, ValueError, KeyError, IndexError, TypeError):
            continue  # Incomplete or unrecognized reports remain unexpected.
    return accepted
