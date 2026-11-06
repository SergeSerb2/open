#!/usr/bin/env python3
"""Private, optional session-2 pad gate; only the compare CLI reads pixels."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FRAMES = (27, 29, 31, 33, 35, 37, 39, 41, 43, 45, 65, 92, 93, 95, 98, 100, 102, 112, 114, 116, 118)


def default_root():
    common = subprocess.run(['git', 'rev-parse', '--git-common-dir'], cwd=ROOT,
                            check=True, capture_output=True, text=True).stdout.strip()
    return (ROOT / common).resolve().parent / '.re/runtime/sessions/20261026-104045-17-theme-editor'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--probe', action='store_true')
    parser.add_argument('--capture-root', type=Path)
    args = parser.parse_args()
    supplied = os.environ.get('SPACE_EDITOR_CAPTURE_ROOT')
    source = args.capture_root or (Path(supplied) if supplied else default_root())
    if not source.is_dir():
        print('session2-pad SKIP: private capture root is absent')
        return 77
    # Bound the inventory too; malformed available inputs must fail, not SKIP.
    entries = []
    with os.scandir(source) as scan:
        for entry in scan:
            entries.append(Path(entry.path))
            if len(entries) > 512:
                raise ValueError('capture root exceeds 512 entries')
    for number in FRAMES:
        folders = [p for p in entries if p.name.startswith('%04d-' % number) and p.is_dir()]
        if not folders:
            print('session2-pad SKIP: a required private frame is absent')
            return 77
        if len(folders) != 1:
            raise ValueError('duplicate capture frame number')
        if not any((folders[0] / ('win-70352.' + suffix)).is_file() for suffix in ('png', 'same')):
            print('session2-pad SKIP: a required private window image is absent')
            return 77
    if args.probe:
        return 0
    parent = ROOT / '.re/space-pad-compare'
    parent.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
    command = [str(ROOT / 'Packages/OpenKit/.build/release/space-editor-render'), 'compare', '--spec', 'session2-pad',
               '--capture-root', str(source), '--out', str(output)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=180)
    # CLI output consists only of frame numbers, counts, and fixed metric rows.
    print(result.stdout, end='')
    if result.returncode:
        print(result.stderr, end='', file=sys.stderr)
        return 1
    table = (output / 'table.md').read_text()
    if '| FAIL |' in table or '| PASS |' not in table:
        raise ValueError('missing or failed session2-pad gate rows')
    print('session2-pad: %d gate rows PASS' % table.count('| PASS |'))
    print('Private comparison artifacts: ' + str(output))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('session2-pad FAIL: ' + str(error), file=sys.stderr)
        sys.exit(1)
