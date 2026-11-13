"""Full import-arc CLI flows over own synthetic Firestore caches. No unit tests."""
import hashlib
import json
import os
import re
import runpy
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GENERATOR = runpy.run_path(str(ROOT / 'tools/e2e/fixtures/import-boosts/generate.py'))


def invoke(binary, source, output, counts_only=True):
    return subprocess.run([str(binary), 'import-arc', '--arc-dir', str(source), '--out', str(output),
                           '--counts-only' if counts_only else '--show-titles'],
                          capture_output=True, text=True, timeout=120)


def numbers(text):
    result = {}
    for line in text.splitlines():
        if line.startswith('  boosts '):
            result.update({key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', line)})
    return result


def source_hashes(root):
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in root.rglob('*') if path.is_file()}


def saved_boosts(output):
    paths = list(Path(output).glob('Profiles/*/Boosts/boosts.json'))
    if len(paths) != 1:
        return [], None
    return json.loads(paths[0].read_text())['boosts'], paths[0]


def initial_checks(process, output, ids):
    counts = numbers(process.stdout)
    boosts, _ = saved_boosts(output)
    by_id = {boost['id']: boost for boost in boosts}
    enabled = by_id.get(ids['enabled'], {})
    disabled = by_id.get(ids['disabled'], {})
    return {
        'boost_cli_counts': process.returncode == 0 and counts.get('found') == 3 and counts.get('imported') == 2 and counts.get('storedNew') == 2,
        'boost_cli_mapping': enabled.get('name') == 'Example enabled' and enabled.get('siteMatch', {}).get('domain') == 'example.com'
            and 'outline:3px solid rgb(1,2,3)' in enabled.get('css', '') and enabled.get('js') == "document.body.dataset.exampleBoost='1'"
            and enabled.get('fontFamily') == 'Georgia' and enabled.get('textTransform') == 'uppercase'
            and [zap['selector'] for zap in enabled.get('zaps', [])] == ['#example-promo']
            and enabled.get('forkedFromID') is None and enabled.get('createdAt') == 1780000000
            and disabled.get('forkedFromID') == ids['enabled'],
        'boost_cli_enabled': enabled.get('isEnabled') is True,
        'boost_cli_disabled': disabled.get('isEnabled') is False,
        'boost_cli_malformed': counts.get('malformed') == 1,
        'boost_cli_unknown': counts.get('unknownFields') == 1,
        # PB4 row 4: hue, saturation and invert map (3 leaves per Boost); the rest stays counted.
        # PB4 row 4, zoom part (capture C11): textZoom.level is the percent, mapped too (1 leaf per Boost).
        # The second Boost's level 2 is outside 50…200: dropped, not clamped.
        # Capture C11: secondaryHueOffset 45 (Arc's fixed second knob) maps; the second Boost's 30 is dropped.
        # Session 11: advancedSettings maps (3 leaves) and the untouched baseAppearance maps (1).
        'boost_cli_dropped': counts.get('droppedFields') == 8 and counts.get('mappedFields') == 29,
        'boost_cli_text_zoom': enabled.get('textZoom') == 1.25 and disabled.get('textZoom') is None,
        # Capture session 11: the advanced sliders come back as Open's slider values (Brightness 40 → 0.9,
        # Contrast 70 → 1.2, Original Saturation 60 → 1.2); the untouched Boost keeps Open's defaults.
        'boost_cli_advanced': abs(enabled.get('colorWheel', {}).get('brightness', 0) - 0.9) < 1e-9
            and abs(enabled.get('colorWheel', {}).get('contrast', 0) - 1.2) < 1e-9
            and abs(enabled.get('colorWheel', {}).get('originalSaturation', 0) - 1.2) < 1e-9
            and disabled.get('colorWheel', {}).get('brightness') == 1 and disabled.get('colorWheel', {}).get('contrast') == 1
            and disabled.get('colorWheel', {}).get('originalSaturation') == 1,
        'boost_cli_color': enabled.get('colorWheel', {}).get('hue') == 90 and enabled.get('colorWheel', {}).get('intensity') == .4
            and enabled.get('colorWheel', {}).get('invertLightness') is False and disabled.get('colorWheel', {}).get('hue') == 90
            and enabled.get('colorWheel', {}).get('intensity') == .4,
        'boost_cli_tombstones': counts.get('deleted') == 1 and counts.get('unknownDocuments') == 1 and counts.get('otherCollections') == 1
            and not any(value in by_id for key, value in ids.items() if key in ('deleted', 'unknown', 'obsolete', 'wal-deleted')),
        'boost_cli_privacy': all(value not in process.stdout + process.stderr for value in
            ['Example enabled', 'example.com', 'dataset.exampleBoost', '#example-promo', 'synthetic-creator']),
    }


def run(binary, work, rows, negative_binary=None):
    work = Path(work)
    source, output = work / 'boost-source', work / 'boost-output'
    ids = GENERATOR['write'](source)
    before = source_hashes(source)
    started = time.monotonic()
    process = invoke(binary, source, output)
    counts = numbers(process.stdout)
    negative = {}
    def row(name, ok, **detail):
        rows[name] = dict(ok=bool(ok), load=os.getloadavg(), **detail)
    for name, ok in initial_checks(process, output, ids).items():
        row(name, ok, counts=counts)
    # No raw command output is persisted: a future error must not leak fields.
    # Break this condition once on the owned source, then restore its bytes.
    storable = source / 'StorableBoostsData.json'
    original = storable.read_bytes()
    storable.write_bytes(original + b' ')
    negative['boost_cli_source_unchanged'] = source_hashes(source) == before
    storable.write_bytes(original)
    row('boost_cli_source_unchanged', source_hashes(source) == before)
    boosts, path = saved_boosts(output)
    assert path is not None, 'CLI did not persist Boosts'
    initial = path.read_bytes()
    def reimport_ok(result, content):
        values = numbers(result.stdout)
        return result.returncode == 0 and values.get('storedNew') == 0 and values.get('storedDuplicates') == 2 and content == initial
    negative['boost_cli_reimport'] = reimport_ok(process, initial)  # first import adds records
    repeat = invoke(binary, source, output)
    repeated = numbers(repeat.stdout)
    row('boost_cli_reimport', reimport_ok(repeat, path.read_bytes()), counts=repeated)
    def preserves_edit(result, values):
        return result.returncode == 0 and numbers(result.stdout).get('protectedEdits') == 2 and next(
            boost for boost in values if boost['id'] == ids['enabled'])['css'] == 'body{color:rgb(9,8,7)}'
    negative['boost_cli_preserves_edit'] = preserves_edit(repeat, boosts)  # edit not present yet
    dto = json.loads(path.read_text())
    next(boost for boost in dto['boosts'] if boost['id'] == ids['enabled']).update(css='body{color:rgb(9,8,7)}', updatedAt=4000000000)
    path.write_text(json.dumps(dto))
    edited = invoke(binary, source, output)
    after, _ = saved_boosts(output)
    row('boost_cli_preserves_edit', preserves_edit(edited, after))
    def missing_enablement(result, values):
        return result.returncode == 0 and numbers(result.stdout).get('enablementUnknown') == 2 and len(values) == 2 and all(not b['isEnabled'] for b in values)
    negative['boost_cli_missing_enablement'] = missing_enablement(process, boosts)
    (source / 'StorableBoostsData.json').unlink()
    no_enable = invoke(binary, source, work / 'boost-no-enablement')
    disabled, _ = saved_boosts(work / 'boost-no-enablement')
    row('boost_cli_missing_enablement', missing_enablement(no_enable, disabled))
    # Missing cache is a valid empty import. A corrupt cache is reported and
    # cannot fail the independent sidebar import or leak partial Boosts.
    cache = source / 'Firestore/main'
    shutil.rmtree(cache)
    absent = invoke(binary, source, work / 'boost-absent')
    def absent_ok(result):
        return result.returncode == 0 and numbers(result.stdout).get('imported') == 0 and 'boosts: not found' in result.stdout
    negative['boost_cli_absent'] = absent_ok(process)  # populated cache
    row('boost_cli_absent', absent_ok(absent))
    cache.mkdir()
    (cache / 'CURRENT').write_text('../outside\n')
    broken = invoke(binary, source, work / 'boost-broken')
    def corrupt_ok(result):
        return result.returncode == 0 and numbers(result.stdout).get('imported') == 0 and 'boosts: unreadable or exceeds limit' in result.stdout and 'accounted check: OK' in result.stdout
    negative['boost_cli_corrupt_cache'] = corrupt_ok(process)  # valid cache
    row('boost_cli_corrupt_cache', corrupt_ok(broken))
    # Size boundaries run through the actual import command and private-copy
    # path. One ignored cache file at the limit is valid; one byte over refuses.
    (cache / 'CURRENT').write_text('MANIFEST-000001\n')
    edit = GENERATOR['varint'](1) + GENERATOR['blob'](b'leveldb.BytewiseComparator')
    (cache / 'MANIFEST-000001').write_bytes(GENERATOR['log']([edit]))
    with (cache / 'padding').open('wb') as stream:
        stream.truncate(32 * 1024 * 1024)
    boundary = invoke(binary, source, work / 'boost-limit')
    with (cache / 'padding').open('ab') as stream:
        stream.write(b'x')
    above = invoke(binary, source, work / 'boost-over-limit')
    def limits_ok(at_limit, over_limit):
        return at_limit.returncode == 0 and 'boosts: read' in at_limit.stdout and over_limit.returncode == 0 and 'boosts: unreadable or exceeds limit' in over_limit.stdout
    negative['boost_cli_limits'] = limits_ok(boundary, boundary)  # over-limit refusal absent
    row('boost_cli_limits', limits_ok(boundary, above))
    # Damage owned on-disk inputs and use the full command path. None of these
    # checks calls an internal Swift parser or replaces a production service.
    damaged = work / 'boost-damaged-source'
    GENERATOR['write'](damaged)
    damaged_cache = damaged / 'Firestore/main'
    table_path = damaged_cache / '000005.ldb'
    valid_table = table_path.read_bytes()
    corruption = {}
    altered = bytearray(valid_table)
    altered[0] ^= 0x80  # data block checksum must reject this bit flip
    table_path.write_bytes(altered)
    corruption['crc'] = corrupt_ok(invoke(binary, damaged, work / 'boost-bad-crc'))
    table_path.write_bytes(valid_table)
    current = damaged_cache / 'CURRENT'
    saved_current = current.read_bytes()
    current.unlink()
    current.symlink_to(source / 'StorableSidebar.json')
    corruption['symlink'] = corrupt_ok(invoke(binary, damaged, work / 'boost-bad-symlink'))
    current.unlink()
    current.write_bytes(saved_current)
    # More than 256 flat files refuses before copying database bytes.
    for index in range(257):
        (damaged_cache / ('extra-%03d' % index)).write_bytes(b'')
    corruption['file_count'] = corrupt_ok(invoke(binary, damaged, work / 'boost-bad-file-count'))
    negative['boost_cli_corrupt_inputs'] = corrupt_ok(process)  # undamaged cache
    row('boost_cli_corrupt_inputs', all(corruption.values()), cases=corruption)
    if negative_binary:
        negative_source = work / 'boost-negative-source'
        GENERATOR['write'](negative_source)
        negative_output = work / 'boost-negative-output'
        parent = invoke(negative_binary, negative_source, negative_output)
        negative.update({key: ok for key, ok in initial_checks(parent, negative_output, ids).items() if key != 'boost_cli_privacy'})
        # Counts-only privacy must detect a real command that prints source
        # values. Use the explicit titles mode on this synthetic source only.
        visible = invoke(binary, negative_source, work / 'boost-visible-output', counts_only=False)
        negative['boost_cli_privacy'] = initial_checks(visible, work / 'boost-visible-output', ids)['boost_cli_privacy']
        for name, result in rows.items():
            result['negativeProof'] = 'FAIL' if negative.get(name) is False else 'NOT PROVEN'
            result['ok'] = result['ok'] and negative.get(name) is False
    return dict(seconds=time.monotonic() - started, source=str(source), output=str(output))


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--negative-cli', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    results = {}
    with tempfile.TemporaryDirectory(prefix='open-import-boosts-cli-') as work:
        metadata = run(args.cli, work, results, args.negative_cli)
    args.report.write_text(json.dumps(dict(checks=results, metadata=metadata), indent=2))
    for name, result in results.items():
        print(name, 'PASS' if result['ok'] else 'FAIL', 'load=' + str(result['load']))
    raise SystemExit(0 if all(result['ok'] for result in results.values()) else 1)
