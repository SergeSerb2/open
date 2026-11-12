"""Continue the lead-approved five-pair receipt without reinstalling its App."""
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess


def read(path, limit=64 * 1024 * 1024):
    if path.stat().st_size > limit:
        raise ValueError('launch receipt exceeds size limit')
    return json.loads(path.read_text())


def continuation(directory, root, engine):
    directory, root = Path(directory).resolve(), Path(root).resolve()
    gate = read(directory/'gate.json', 16 * 1024 * 1024)
    receipt = read(directory/'input-timing-window/results-window-release.json')
    if (gate.get('machine') != 'M1' or gate.get('lane') != 'timing'
            or gate.get('config') != 'Release' or gate.get('selected') != ['timing-window']
            or gate.get('partialSelectors') != [] or gate['source'].get('clean') is not True
            or gate['source'].get('engineSHA256') != engine
            or receipt.get('interrupted_attempts') or receipt.get('config') != 'Release'
            or receipt.get('style') != 'chrome' or receipt.get('lane') != 'merge'
            or receipt.get('source', {}).get('head') != gate['source']['head']
            or receipt.get('source', {}).get('clean') is not True
            or receipt.get('engine', {}).get('distributionSHA256') != engine
            or not receipt.get('engine', {}).get('embeddedCodeSHA256')
            or receipt['engine']['embeddedCodeSHA256'] != receipt['engine'].get('distributionCodeSHA256')):
        raise ValueError('not the original clean M1 five-pair launch receipt')
    changed = subprocess.check_output(['git', 'diff', '--name-only', gate['source']['head'], 'HEAD',
        '--', 'App', 'Engine', 'Packages', 'project.yml', 'tools/build.sh', 'tools/fetch-cef.sh'], cwd=root, text=True)
    if changed:
        raise ValueError('launch continuation product/build inputs changed: '+changed)
    cleanup = receipt.get('cleanup', {})
    if (cleanup.get('ok') is not True or not cleanup.get('processes')
            or any(p.get('ok') is not True or p.get('remaining_processes')
                   or p.get('windows_after_quit', {}).get('count') != 0 for p in cleanup['processes'])):
        raise ValueError('prior launch cleanup did not pass')
    end = read(directory/'timing-window/screen-end.json')
    if end.get('safe') is not True:
        raise ValueError('prior screen stage was unsafe')
    values = receipt['window']
    runs, validity = values['launch_runs'], values['launch_validity']
    labels = ('cold_fresh_profile', 'warm_existing_profile')
    if set(runs) != set(labels) or any(len(runs[k]) != 5 for k in labels) or len(validity) != 5:
        raise ValueError('continuation requires exactly five original pairs')
    if any(isinstance(v, dict) and v.get('ok') is False for k, v in values.items() if k not in labels):
        raise ValueError('prior launch flow has a functional failure')
    for samples in runs.values():
        for sample in samples:
            if (sample.get('kernelProcessStart') is not True or sample.get('firstFrameConfirmed') is not True
                    or any(type(sample.get(k)) not in (int, float) or not math.isfinite(sample[k]) or sample[k] < 0
                           for k in ('windowShown', 'sidebarDrawn', 'firstContentfulPaint'))):
                raise ValueError('prior launch phase sample is incomplete')
    for pair in validity:
        before = pair['before']
        if (len(before) != 2 or before[1]['at']-before[0]['at'] < 10
                or any(not r['load'][0] <= 3.5 for r in before)):
            raise ValueError('prior pair did not meet LEAD 06:50')
    binary = root/'build/Release/Open.app/Contents/MacOS/Open'
    stat = binary.stat()
    ledger = directory/'timing-window/processes.jsonl'
    if ledger.stat().st_size > 64 * 1024:
        raise ValueError('prior process ledger exceeds 64 KiB')
    identities = [json.loads(line) for line in ledger.read_text().splitlines()]
    if not identities or any((p.get('executable'), p.get('device'), p.get('inode')) !=
                            (str(binary), stat.st_dev, stat.st_ino) for p in identities):
        raise ValueError('the original App executable was replaced')
    key = hashlib.sha256(os.path.realpath(binary).encode()).hexdigest()
    marker = read(root/'.re/e2e-tools'/('last-launched-binary-'+key+'.json'), 4096)
    identity = [os.path.realpath(binary), stat.st_dev, stat.st_ino, stat.st_mtime_ns, stat.st_size]
    if marker != identity:
        raise ValueError('the last-launched App identity changed')
    return dict(runs={k: runs[k][1:] for k in labels}, validity=validity[1:],
                warmup=dict(status='INFO', reason='first launch after install',
                    cold=runs[labels[0]][0], warm=runs[labels[1]][0], validity=validity[0],
                    owner='performance lane', followup='https://github.com/SergeSerb2/open/issues/313', limit=None),
                prior=dict(directory=str(directory), head=gate['source']['head'], binaryIdentity=identity))
