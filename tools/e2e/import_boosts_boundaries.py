"""Resource boundaries through the actual import-arc command, with own cache bytes."""
import argparse
import json
import os
import runpy
import shutil
import struct
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
H = runpy.run_path(str(ROOT / 'tools/e2e/import_boosts_cli.py'))
G = H['GENERATOR']
MIB = 1024 * 1024


def run(binary, work):
    source = Path(work) / 'source'
    G['write'](source)
    cache = source / 'Firestore/main'
    enabled = source / 'StorableBoostsData.json'
    enabled_bytes = enabled.read_bytes()
    identifier = G['IDS']['enabled']
    results = {}
    serial = 0

    def database(rows=None, raw=None, key=None):
        shutil.rmtree(cache)
        cache.mkdir()
        if rows is None:
            value = raw if raw is not None else G['document'](identifier, {'hostPattern': 'example.com', 'data': '{}'})
            user = key if key is not None else G['remote_key']('boosts', identifier)
            rows = [(user + struct.pack('<Q', (10 << 8) | 1), value)]
        table = G['table'](rows)
        (cache / '000005.ldb').write_bytes(table)
        edit = G['varint'](1) + G['blob'](b'leveldb.BytewiseComparator')
        edit += G['varint'](7) + G['varint'](0) + G['varint'](5) + G['varint'](len(table)) + G['blob'](b'') + G['blob'](b'')
        (cache / 'MANIFEST-000001').write_bytes(G['log']([edit]))
        (cache / 'CURRENT').write_text('MANIFEST-000001\n')
        enabled.write_bytes(enabled_bytes)

    def invoke():
        nonlocal serial
        serial += 1
        return H['invoke'](binary, source, Path(work) / ('output-%d' % serial))

    def valid(process, count=1):
        return process.returncode == 0 and 'boosts: read' in process.stdout and H['numbers'](process.stdout).get('imported') == count

    def malformed(process):
        return process.returncode == 0 and 'boosts: read' in process.stdout and H['numbers'](process.stdout).get('malformed') == 1 and H['numbers'](process.stdout).get('imported') == 0

    def unreadable(process):
        return process.returncode == 0 and 'boosts: unreadable or exceeds limit' in process.stdout and H['numbers'](process.stdout).get('imported') == 0

    def pair(name, make, accepted=valid, refused=malformed):
        make(False)
        at_limit = invoke()
        make(True)
        above = invoke()
        positive = accepted(at_limit) and refused(above)
        # Apply exactly the same pair predicate while the over-limit refusal
        # is absent. It must FAIL, then PASS with the refused input restored.
        negative = accepted(at_limit) and refused(at_limit)
        results[name] = {'ok': bool(positive and not negative), 'negativeProof': 'FAIL' if not negative else 'NOT PROVEN', 'load': os.getloadavg()}

    def payload(components=None, fields=None, doc_id=None):
        return G['document'](doc_id or identifier, fields or {'hostPattern': 'example.com', 'data': json.dumps(components or {}, separators=(',', ':'))})

    def string_size(over):
        base = json.dumps({'css': ''}, separators=(',', ':'))
        body = json.dumps({'css': 'a' * (MIB - len(base) + int(over))}, separators=(',', ':'))
        database(raw=payload(fields={'hostPattern': 'example.com', 'data': body}))
    pair('string_1MiB', string_size)

    def document_size(over):
        size = 2*MIB + int(over)
        fields = {'hostPattern': 'example.com', 'data': '{}', 'padding1': 'a'*MIB, 'padding2': ''}
        for _ in range(4):
            raw = payload(fields=fields)
            delta = size - len(raw)
            if not delta:
                break
            fields['padding2'] = 'b' * (len(fields['padding2']) + delta)
        assert len(raw) == size
        database(raw=raw)
    pair('document_2MiB', document_size)

    pair('field_map_128', lambda over: database(raw=payload(fields=dict(
        {'hostPattern': 'example.com', 'data': '{}'}, **{'f%03d' % i: 'x' for i in range(126 + int(over))}))))
    pair('selectors_1024', lambda over: database(raw=payload({'zaps': ['#example']*(1024 + int(over))})))
    pair('selector_bytes_4096', lambda over: database(raw=payload({'zaps': ['#' + 'a'*(4095 + int(over))]})))
    pair('font_bytes_1024', lambda over: database(raw=payload({'font': {'family': 'a'*(1024 + int(over))}})))
    pair('host_bytes_253', lambda over: database(raw=payload(fields={'hostPattern': '.'.join(['a'*63]*3 + ['a'*(61 + int(over))]), 'data': '{}'})))
    pair('component_key_bytes_256', lambda over: database(raw=payload({'a'*(256 + int(over)): 0})))
    pair('field_key_bytes_256', lambda over: database(raw=payload(fields={'hostPattern': 'example.com', 'data': '{}', 'a'*(256 + int(over)): 'x'})))
    def document_id(over):
        doc_id = 'a'*(256 + int(over))
        database(raw=payload(doc_id=doc_id), key=G['remote_key']('boosts', doc_id))
    pair('document_id_bytes_256', document_id)

    def component_depth(over):
        value = 0
        for _ in range(14 + int(over)):
            value = {'future': value}
        database(raw=payload({'future': value}))
    pair('component_depth_16', component_depth)

    def component_nodes(over):
        value = [[None]*1024 for _ in range(7)] + [[None]*(1014 + int(over))]
        database(raw=payload({'future': value}))
    pair('component_nodes_8192', component_nodes)

    def protobuf_fields(over):
        raw = payload() + G['field'](100, 0, wire=0)*(4094 + int(over))
        database(raw=raw)
    pair('protobuf_fields_4096', protobuf_fields)

    def key_size(over):
        database(key=b'k'*(4096 + int(over)), raw=b'')
    pair('leveldb_key_bytes_4096', key_size, accepted=lambda p: valid(p, 0), refused=unreadable)

    def block_size(over):
        desired = 8*MIB + int(over)
        key = b'padding' + struct.pack('<Q', (10 << 8) | 1)
        count = desired - 32
        for _ in range(4):
            rows = [(key, b'x'*count)]
            delta = desired - len(G['block'](rows))
            if not delta:
                break
            count += delta
        assert len(G['block'](rows)) == desired
        database(rows=rows)
    pair('snappy_block_8MiB', block_size, accepted=lambda p: valid(p, 0), refused=unreadable)

    def records(over):
        rows = [(('padding-%06d' % i).encode() + struct.pack('<Q', (10 << 8) | 1), b'') for i in range(100000 + int(over))]
        database(rows=rows)
    pair('current_records_100000', records, accepted=lambda p: valid(p, 0), refused=unreadable)

    def source_files(over):
        database()
        for i in range(256 - len(list(cache.iterdir())) + int(over)):
            (cache / ('padding-%03d' % i)).write_bytes(b'')
    pair('source_files_256', source_files, refused=unreadable)

    def total_bytes(over):
        database()
        base = sum(p.stat().st_size for p in cache.iterdir())
        for name, size in [('padding1', 32*MIB), ('padding2', 32*MIB - base + int(over))]:
            with (cache / name).open('wb') as stream:
                stream.truncate(size)
    pair('source_bytes_64MiB', total_bytes, refused=unreadable)

    def local_ids(over):
        database()
        enabled.write_text(json.dumps({'version': 1, 'locallyEnabledBoostIDs': [{'value': identifier}]*(4096 + int(over))}))
    def known_enablement(p):
        return valid(p) and H['numbers'](p.stdout).get('enablementUnknown') == 0
    def unknown_enablement(p):
        return valid(p) and H['numbers'](p.stdout).get('enablementUnknown') == 1
    pair('enabled_ids_4096', local_ids, accepted=known_enablement, refused=unknown_enablement)

    def local_bytes(over):
        database()
        enabled.write_bytes(enabled_bytes + b' '*(2*MIB - len(enabled_bytes) + int(over)))
    pair('enablement_bytes_2MiB', local_bytes, accepted=known_enablement, refused=unknown_enablement)
    return results


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='open-boost-boundaries-') as work:
        results = run(args.cli, work)
    args.report.write_text(json.dumps(results, indent=2))
    for name, row in results.items():
        print(name, 'PASS' if row['ok'] else 'FAIL', 'negative=' + row['negativeProof'], 'load=' + str(row['load']))
    raise SystemExit(0 if all(row['ok'] for row in results.values()) else 1)
