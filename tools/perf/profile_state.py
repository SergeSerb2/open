"""Read-only evidence for second-launch idle/memory measurements."""
import json
import os
from pathlib import Path
import time

from run import ROOT, now, sha


def quiet_pair(ceiling=6):
    readings = []
    for index in range(2):
        if index: time.sleep(10)
        readings.append({'date': now(), 'load': list(os.getloadavg())})
        if readings[-1]['load'][0] >= ceiling: break
    return readings, len(readings) == 2 and all(r['load'][0] < ceiling for r in readings)


def bounded_json(path):
    path = Path(path)
    if path.is_symlink() or path.stat().st_size > 4 * 1024 * 1024:
        raise ValueError('Profile-state JSON must be regular and at most 4 MiB')
    return json.loads(path.read_text())


def components(root):
    """Inspect installed component manifests, never browsing history or cache contents."""
    result = []
    excluded = {'Default', 'BrowserMetrics', 'GraphiteDawnCache', 'GPUPersistentCache',
                'Safe Browsing', 'NativeMessagingHosts', 'component_crx_cache'}
    engine = Path(root) / 'Engine'
    if not engine.is_dir(): return result
    for directory in sorted(engine.iterdir()):
        if directory.name in excluded or not directory.is_dir() or directory.is_symlink(): continue
        for parent, dirs, files in os.walk(directory, followlinks=False):
            parent = Path(parent)
            dirs[:] = sorted(d for d in dirs if not (parent / d).is_symlink())
            if len(parent.relative_to(directory).parts) >= 3: dirs[:] = []
            if 'manifest.json' not in files: continue
            manifest = parent / 'manifest.json'; value = bounded_json(manifest)
            version = value.get('version')
            if not isinstance(version, str) or len(version) > 128: continue
            result.append({'component': directory.name, 'version': version,
                'manifest': str(manifest.relative_to(engine)), 'manifest_sha256': sha(manifest)})
            if len(result) > 128: raise ValueError('Component manifest count exceeded')
    return result


def adblock(browser):
    native = browser.call('settings-adblock-engine')
    model = bounded_json(browser.root / 'State/browser.json')
    directories = {p['id']: p['dataDirectoryName'] for p in model['profiles']}
    catalog = bounded_json(ROOT / 'Packages/OpenKit/Sources/OpenAdBlock/Resources/catalog.json')
    source_counts = {v['id']: len(v['urls']) for v in catalog['lists']}
    profiles = []
    for entry in native['profiles']:
        contexts = [c for c in entry['contexts'] if not c['offTheRecord']]
        if not contexts: continue
        directory = directories[entry['profile']]
        if Path(directory).name != directory: raise ValueError('Invalid Profile directory')
        base = browser.root / 'Profiles' / directory / 'AdBlock'
        state = bounded_json(base / 'catalog-state.json')
        pointer = bounded_json(base / 'lists/current.json')['live']
        generation = base / 'lists/generations' / str(int(pointer['generation']))
        manifest = generation / 'manifest.json'
        verified = sha(manifest) == pointer['manifestSHA256']
        checked = []
        for identifier in state['enabledBlockLists']:
            receipt = state['lists'][identifier]
            stamp = receipt['lastCheck'] + 978307200  # Foundation Date's 2001 epoch.
            age = time.time() - stamp
            path = generation / (identifier + '.txt')
            intact = path.stat().st_size == receipt['bytes'] and sha(path) == receipt['sha256']
            complete = len(receipt['sources']) == source_counts[identifier]
            checked.append({'id': identifier, 'last_check_unix': stamp, 'age_seconds': age,
                'source_count': len(receipt['sources']), 'sha256': receipt['sha256'],
                'bytes': receipt['bytes'], 'verified': intact,
                'fresh': 0 <= age < 86400 and complete and intact})
        enabled = entry['storeReady'] and entry['storeEnabled'] and all(
            c['adBlockEnabled'] and c['listDirectoryMatchesProfile'] for c in contexts)
        profiles.append({'profile': entry['profile'], 'store_ready': entry['storeReady'],
            'enabled': enabled, 'generation': pointer['generation'], 'generation_verified': verified,
            'last_error': state.get('lastError'), 'lists': checked,
            'fresh': bool(checked) and enabled and verified and not state.get('lastError') and all(v['fresh'] for v in checked)})
    return {'profiles': profiles, 'fresh': bool(profiles) and all(p['fresh'] for p in profiles)}


def evidence(browser, snapshot=None):
    stamp = snapshot['wall_seconds'] if snapshot else time.time()
    return {'date': now(), 'launch_number': 2, 'launch_age_seconds': stamp - browser.launch['birth_wall_seconds'],
        'load': list(os.getloadavg()), 'components': components(browser.root), 'adblock': adblock(browser)}
