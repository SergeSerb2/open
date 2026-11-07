"""Own synthetic Firestore/LevelDB writer. No Arc files or assets are copied."""
import json
import runpy
import struct
import uuid
from pathlib import Path

IDS = {name: str(uuid.uuid5(uuid.NAMESPACE_URL, 'https://example.com/boost-import/' + name)).upper()
       for name in ('enabled', 'disabled', 'malformed', 'deleted', 'unknown', 'obsolete', 'wal-deleted')}


def varint(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    return bytes(result + bytes([value]))


def field(number, value, wire=2):
    return varint(number * 8 + wire) + (varint(len(value)) + value if wire == 2 else varint(value))


def text(value):
    return field(17, value.encode())


def timestamp(seconds):
    return field(1, seconds, wire=0)


def remote_key(collection, identifier):
    return b'\x85remote_document\x00\x01' + b'\xbe' + collection.encode() + b'\x00\x01\xbe' + identifier.encode() + b'\x00\x01\x80'


def document(identifier, fields, collection='boosts', variant=2):
    name = 'projects/bcny-arc-server/databases/(default)/documents/' + collection + '/' + identifier
    payload = field(1, name.encode())
    if variant == 2:
        for key, value in fields.items():
            payload += field(2, field(1, key.encode()) + field(2, text(value)))
        payload += field(3, timestamp(1780000000)) + field(4, timestamp(1780000123))
    else:
        payload += field(2, timestamp(1780000123))
    return field(variant, payload) + field(4, 0, wire=0)


def boost(name, css='body{outline:3px solid rgb(1,2,3)}', **extra):
    components = dict(css=css, js="document.body.dataset.exampleBoost='1'", font={'family': 'Georgia'},
                      textTransform='uppercase', zaps=['#example-promo'], textZoom={'level': 2},
                      colorScheme={'colorWheelDriven': {'_0': dict(primaryHueDegrees=90, primarySaturation=.4,
                                                                  secondaryHueOffset=30, invertLightness=False,
                                                                  baseAppearance={'light': {}}, advancedSettings={})}})
    components.update(extra)
    return dict(title='Example ' + name, hostPattern='example.com', creatorID='synthetic-creator',
                author='Example author', type='edited', lastModified='2026-05-28T20:28:43Z', isActive='true',
                data=json.dumps(components, separators=(',', ':')))


def crc(data):
    value = 0xffffffff
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = (value >> 1) ^ (0x82f63b78 if value & 1 else 0)
    value = (~value) & 0xffffffff
    return (((value >> 15) | (value << 17)) + 0xa282ead8) & 0xffffffff


def log(records):
    output = bytearray()
    for payload in records:
        first = True
        while payload:
            remaining = 32768 - len(output) % 32768
            if remaining < 7:
                output += bytes(remaining)
                remaining = 32768
            size = min(len(payload), remaining - 7)
            fragment, payload = payload[:size], payload[size:]
            kind = (1 if first else 4) if not payload else (2 if first else 3)
            output += struct.pack('<IHB', crc(bytes([kind]) + fragment), size, kind) + fragment
            first = False
    return bytes(output)


def blob(data):
    return varint(len(data)) + data


def snappy(data):
    # Literal plus all three copy tags for repeated bytes. This is an own tiny
    # compressor, not a copied Snappy implementation. The reader must handle
    # overlapping copies and the extended-length literal too.
    result = bytearray(varint(len(data)))
    at = 0
    while at < len(data):
        run = 1
        while at + run < len(data) and data[at + run] == data[at]:
            run += 1
        if run >= 15:
            result += bytes([0, data[at]])
            remaining = run - 1
            for kind in (1, 2, 3):
                if remaining < 4:
                    break
                count = min(11 if kind == 1 else 64, remaining)
                if kind == 1:
                    result += bytes([((count - 4) << 2) | 1, 1])
                elif kind == 2:
                    result += bytes([((count - 1) << 2) | 2, 1, 0])
                else:
                    result += bytes([((count - 1) << 2) | 3, 1, 0, 0, 0])
                remaining -= count
            at += run - remaining
            continue
        end = min(len(data), at + 256)
        for index in range(at + 1, end):
            if data[index:index + 15] == data[index:index + 1] * 15:
                end = index
                break
        literal = data[at:end]
        size = len(literal) - 1
        if size < 60:
            result += bytes([size << 2])
        else:
            width = max(1, (size.bit_length() + 7) // 8)
            result += bytes([(59 + width) << 2]) + size.to_bytes(width, 'little')
        result += literal
        at = end
    return bytes(result)


def block(entries):
    result = bytearray()
    restarts = []
    # Each key is a restart. Prefix compression is exercised separately by the
    # second and later entries, with a restart only at the first key.
    previous = b''
    restarts.append(0)
    for key, value in entries:
        shared = 0
        while shared < min(len(key), len(previous)) and key[shared] == previous[shared]:
            shared += 1
        result += varint(shared) + varint(len(key) - shared) + varint(len(value)) + key[shared:] + value
        previous = key
    return bytes(result) + b''.join(struct.pack('<I', r) for r in restarts) + struct.pack('<I', len(restarts))


def table(entries):
    output = bytearray()
    def append(data, compress=False):
        if compress:
            data = snappy(data)
        offset = len(output)
        kind = int(compress)
        output.extend(data + bytes([kind]) + struct.pack('<I', crc(data + bytes([kind]))))
        return varint(offset) + varint(len(data))
    entries = sorted(entries)
    handle = append(block(entries), compress=True)
    meta = append(block([]))
    index = append(block([(entries[-1][0] if entries else b'', handle)]))
    footer = meta + index
    output += footer + bytes(40 - len(footer)) + struct.pack('<Q', 0xdb4775248b80fb57)
    return bytes(output)


def write(root, sidebar=True):
    root = Path(root)
    if sidebar:
        runpy.run_path(str(Path(__file__).resolve().parents[2] / 'firstrun.py'))['fixture'](root)
    cache = root / 'Firestore/main'
    cache.mkdir(parents=True, mode=0o700, exist_ok=True)
    rows = []
    for name in ('enabled', 'disabled', 'malformed', 'deleted', 'unknown', 'wal-deleted'):
        fields = boost(name, futureFixtureField='unknown') if name == 'enabled' else boost(name)
        if name == 'disabled':
            fields['forkedFromBoostID'] = IDS['enabled']
        if name == 'malformed':
            fields['data'] = 'malformed JSON'
        if name == 'enabled':
            # Repeated CSS exercises Snappy overlapping copies with no personal data.
            fields['data'] = json.dumps(dict(json.loads(fields['data']), css='/*' + 'a' * 200 + '*/' + json.loads(fields['data'])['css']))
        variant = 1 if name == 'deleted' else 3 if name == 'unknown' else 2
        key = remote_key('boosts', IDS[name])
        rows.append((key + struct.pack('<Q', (10 << 8) | 1), document(IDS[name], fields, variant=variant)))
    rows.append((remote_key('boostSnapshots', 'synthetic-snapshot') + struct.pack('<Q', (10 << 8) | 1),
                 document('synthetic-snapshot', {}, collection='boostSnapshots')))
    obsolete = [(remote_key('boosts', IDS['obsolete']) + struct.pack('<Q', (5 << 8) | 1), document(IDS['obsolete'], boost('obsolete')))]
    (cache / '000004.ldb').write_bytes(table(obsolete))
    (cache / '000005.ldb').write_bytes(table(rows))
    # Current version removes 4 and retains 5. Scanning every table resurrects
    # the obsolete Boost and must fail the full CLI flow's count gate.
    # VersionEdit uses plain numeric tags, not protobuf wire keys.
    edit = varint(1) + blob(b'leveldb.BytewiseComparator') + varint(2) + varint(9)
    def add(number, rows):
        return varint(7) + varint(0) + varint(number) + varint((cache / ('%06d.ldb' % number)).stat().st_size) + blob(rows[0][0]) + blob(rows[-1][0])
    edit += add(4, obsolete) + varint(6) + varint(0) + varint(4) + add(5, sorted(rows))
    (cache / 'MANIFEST-000001').write_bytes(log([edit]))
    (cache / 'CURRENT').write_text('MANIFEST-000001\n')
    key = remote_key('boosts', IDS['wal-deleted'])
    batch = struct.pack('<QI', 20, 1) + bytes([0]) + blob(key)
    (cache / '000009.log').write_bytes(log([batch]) + b'\x00\x00')  # valid torn tail
    (cache / 'LOCK').write_bytes(b'')
    (root / 'StorableBoostsData.json').write_text(json.dumps({'version': 1, 'locallyEnabledBoostIDs': [{'value': IDS['enabled']}]}))
    return IDS


if __name__ == '__main__':
    import sys
    write(Path(sys.argv[1]))
