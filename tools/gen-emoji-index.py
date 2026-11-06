#!/usr/bin/env python3
"""Generate Open's name-only index from pinned, fully-qualified Unicode data.

Unicode Emoji 17.0 is supported by macOS 26.4 and later. No CLDR or Arc data.
Toned sequences stay verbatim; names and category order come from Unicode.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import urllib.request

VERSION = '17.0'
URL = 'https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt'
SHA256 = '1d8a944f88d7952f7ef7c5167fef3c67995bcae24543949710231b03a201acda'
CATEGORIES = ['Smileys & People', 'Animals & Nature', 'Food & Drink', 'Activities',
              'Travel & Places', 'Objects', 'Symbols', 'Flags']
GROUPS = {'Smileys & Emotion': 0, 'People & Body': 0, 'Animals & Nature': 1,
          'Food & Drink': 2, 'Activities': 3, 'Travel & Places': 4, 'Objects': 5,
          'Symbols': 6, 'Flags': 7}

def skeleton(value):
    return ''.join(c for c in value if not 0x1F3FB <= ord(c) <= 0x1F3FF and ord(c) != 0xFE0F)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--out', type=Path, default=Path(__file__).resolve().parents[1] /
                        'Packages/OpenKit/Sources/OpenSpaceEditor/Resources/emoji-index.json')
    args = parser.parse_args()
    data = args.source.read_bytes() if args.source else urllib.request.urlopen(URL, timeout=30).read(2_000_001)
    if len(data) > 2_000_000 or hashlib.sha256(data).hexdigest() != SHA256:
        raise SystemExit('Unicode source size or SHA-256 mismatch')
    entries, bases, names, pending = [], {}, {}, []
    category = None
    for line in data.decode('utf-8').splitlines():
        if line.startswith('# group: '):
            category = GROUPS.get(line.removeprefix('# group: '))
        match = re.match(r'^([0-9A-F ]+)\s*; fully-qualified\s*# \S+ E[0-9.]+ (.+)$', line)
        if not match or category is None:
            continue
        value = ''.join(chr(int(c, 16)) for c in match[1].split())
        if any(0x1F3FB <= ord(c) <= 0x1F3FF for c in value):
            pending.append((value, match[2]))
        else:
            entry = [value, match[2], category, []]
            bases[skeleton(value)] = entry
            names[match[2]] = entry
            entries.append(entry)
    for value, name in pending:
        # Unicode uses different untoned sequences for some mixed-tone pairs
        # (for example handshake). Match their official base name as a fallback.
        base_name = re.sub(r'(?:, |: )?(?:medium-light|medium-dark|light|medium|dark) skin tone', '', name).strip(':, ')
        base = bases.get(skeleton(value)) or names.get(base_name) or names.get(base_name.removesuffix(': person, person'))
        if base is None:
            raise SystemExit('fully-qualified toned sequence has no base: ' + name)
        base[3].append(value)
    result = json.dumps({'version': VERSION, 'categories': CATEGORIES, 'entries': entries},
                        ensure_ascii=False, separators=(',', ':')).encode() + b'\n'
    if len(result) > 400_000:
        raise SystemExit('index exceeds 400 KB')
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(result)
    print(f'Unicode Emoji {VERSION}: {len(entries)} entries, {len(result)} bytes')

if __name__ == '__main__':
    main()
