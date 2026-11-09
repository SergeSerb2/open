"""AD3 memory capture through the real App and background memory-infra dumps.

PA is process-wide (including Swift). Its malloc-zone statistics are zero by
design; use its memory-infra roots, and count other malloc zones separately.
"""
import hashlib
import json
import os
from pathlib import Path
import statistics
import time


class InvalidCapture(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise InvalidCapture(message)


def summary(values):
    middle = statistics.median(values)
    return dict(n=len(values), medianBytes=middle, minBytes=min(values), maxBytes=max(values),
                spreadBytes=max(values) - min(values),
                madBytes=statistics.median(abs(value - middle) for value in values))


def purges(app):
    return [line for line in Path(app.log.name).read_text(errors='replace').splitlines()
            if 'OpenAdBlock: idle reclaim runs=' in line]


def inputs(app, profile):
    root = Path(app.user_data) / 'Profiles' / profile['directory'] / 'AdBlock/lists'
    live = json.loads((root / 'current.json').read_text())['live']
    directory = root / 'generations' / str(live['generation'])
    data = (directory / 'manifest.json').read_bytes()
    require(hashlib.sha256(data).hexdigest() == live['manifestSHA256'], 'manifest hash mismatch')
    hashes = {}
    for entry in json.loads(data)['files']:
        body = (directory / entry['file']).read_bytes()
        require(len(body) == entry['bytes'] and hashlib.sha256(body).hexdigest() == entry['sha256'],
                'input hash mismatch: ' + entry['listID'])
        hashes[entry['listID']] = entry['sha256']
    require('_resources' in hashes and len(hashes) > 1, 'missing verified list/resource inputs')
    return hashes


class Capture:
    def __init__(self, app, tab, profiles, status, wait, label):
        self.app, self.tab, self.profiles = app, tab, profiles
        self.status, self.wait = status, wait
        self.events, self.phases, self.active = [], {}, False
        root = Path(os.environ.get('OPEN_E2E_RAW_DIR', Path(__file__).resolve().parents[2] / '.re'))
        root.mkdir(parents=True, exist_ok=True)
        self.path = root / ('ad3-' + label + '-' + str(time.time_ns()) + '.json')

    def call(self, method, **params):
        return self.app.call('devtools', tab=self.tab, method=method, params=params)

    def collect(self):
        complete = False
        for event in self.app.call('events'):
            if event.get('method') == 'Tracing.dataCollected':
                self.events.extend(event['params'].get('value', []))
            if event.get('method') == 'Tracing.tracingComplete':
                complete = True
        return complete

    def start(self):
        self.app.call('events')
        self.call('Tracing.start', traceConfig=dict(recordMode='recordContinuously', traceBufferSizeInKb=32768,
                  includedCategories=['disabled-by-default-memory-infra'], excludedCategories=['*'],
                  memoryDumpConfig=dict(allowed_dump_modes=['background'], triggers=[])))
        self.active = True

    def finish(self):
        try:
            if self.active:
                self.call('Tracing.end')
                require(self.wait(self.collect, timeout=20), 'trace did not complete')
                self.active = False
        finally:
            self.path.write_text(json.dumps(dict(trace=self.events, phases=self.phases,
                                                complete=not self.active), indent=2) + '\n')

    def snapshot(self, name):
        def idle():
            value = self.app.call('adblock-memory')
            states = {s['profile']: s for s in value['stores']}
            require(all(states[p['id']]['ready'] and not states[p['id']]['updating']
                        for p in self.profiles), 'store not ready or IO active during capture')
            return value
        idle()
        time.sleep(6)  # Fixed settle; does not claim that an idle purge occurred.
        samples = []
        for _ in range(5):
            value = idle()
            require(value['pid'] == self.app.pid and value['taskInfoResult'] == 0
                    and value['mallocResult'] == 0, 'process counters unavailable')
            zones = value['mallocZones']
            require(any(z['name'] == 'PartitionAlloc' for z in zones)
                    and any(z['name'] != 'PartitionAlloc' and z['sizeAllocated'] > 0 for z in zones),
                    'malloc zone counters unavailable')
            samples.append(value)
            time.sleep(.2)
        dump = self.call('Tracing.requestMemoryDump', deterministic=False, levelOfDetail='background')
        require(dump.get('success'), 'memory dump failed')
        self.collect()
        self.phases[name] = dict(samples=samples, dump=dump, load=os.getloadavg(),
                                 status={p['id']: self.status(p['id']) for p in self.profiles},
                                 idleReclaimEvents=purges(self.app))

    def totals(self):
        require(not self.active, 'incomplete trace')
        events = [e for e in self.events if e.get('pid') == self.app.pid]
        number = lambda value: int(value, 16) if isinstance(value, str) else value
        starts = {number(e['args']['dump_guid']): e for e in events
                  if e.get('name') == 'GlobalMemoryDump' and e.get('ph') == 'b'
                  and 'dump_guid' in e.get('args', {})}
        ends = {number(e.get('id2', {}).get('local', e.get('id'))): e for e in events
                if e.get('name') == 'GlobalMemoryDump' and e.get('ph') == 'e'}
        dumps = [e for e in events if 'malloc/partitions/allocator' in
                 e.get('args', {}).get('dumps', {}).get('allocators', {})]
        totals, used = {}, []
        for name, phase in self.phases.items():
            key = number(phase['dump']['dumpGuid'])
            require(key in starts and key in ends, 'missing global dump boundary')
            begin, end = starts[key], ends[key]
            require(begin['args'].get('success') and begin['args']['level_of_detail'] == 'background',
                    'unexpected dump detail or failure')
            matches = [e for e in dumps if begin['ts'] <= e['ts'] <= end['ts']]
            require(len(matches) == 1, 'ambiguous browser PA dump')
            event = matches[0]
            used.append(event['ts'])
            require(0 <= event['ts'] / 1e6 - phase['samples'][-1]['uptime'] < 1,
                    'dump does not follow process samples')
            # Exported allocator event IDs are remapped; only the global GUID
            # and timestamp boundaries identify a requested dump reliably.
            payload = event['args']['dumps']
            require(payload['level_of_detail'] == 'background', 'non-background allocator dump')
            roots = [v['attrs'] for k, v in payload['allocators'].items()
                     if k.startswith('malloc/partitions/') and k.count('/') == 2]
            require(roots and all('allocated_size' in r and 'virtual_committed_size' in r for r in roots),
                    'missing PA root counters')
            pa = {key: sum(number(r[key]['value']) for r in roots)
                  for key in ('allocated_size', 'virtual_committed_size')}
            require(pa['allocated_size'] > 0 and pa['virtual_committed_size'] > 0, 'empty PA counters')
            totals[name] = dict(paAllocated=pa['allocated_size'], paCommitted=pa['virtual_committed_size'],
                nonPAMallocInUse=statistics.median(sum(z['sizeInUse'] for z in s['mallocZones']
                    if z['name'] != 'PartitionAlloc') for s in phase['samples']),
                nonPAMallocAllocated=statistics.median(sum(z['sizeAllocated'] for z in s['mallocZones']
                    if z['name'] != 'PartitionAlloc') for s in phase['samples']),
                footprint=statistics.median(s['footprint'] for s in phase['samples']))
        require(len(used) == len(set(used)) == len(dumps) == len(self.phases), 'incomplete PA dump coverage')
        return totals

    def attachment(self, name):
        profile = self.profiles[1]['id']
        self.app.call('adblock-memory', action='unload', profile=profile)
        require(self.wait(lambda: not self.status(profile)['engine_loaded'], timeout=40), 'engine did not unload')
        self.snapshot(name + '-before')
        self.app.call('adblock-memory', action='resume', profile=profile)
        require(self.wait(lambda: self.status(profile)['engine_loaded'], timeout=40), 'engine did not attach')
        self.snapshot(name + '-after')

    @staticmethod
    def delta(totals, name):
        return {k: value - totals[name + '-before'][k] for k, value in totals[name + '-after'].items()}


def measure(app, tab, profiles, status, wait, row, negative=False):
    """Stores and inputs exist before baseline; only native attachment is priced."""
    capture = Capture(app, tab, profiles, status, wait, 'negative' if negative else 'shared')
    try:
        before_inputs = [inputs(app, p) for p in profiles]
        require((before_inputs[0] != before_inputs[1]) if negative else
                (before_inputs[0] == before_inputs[1]), 'unexpected input identity')
        for profile in profiles:
            app.call('adblock-memory', action='pause-updates', profile=profile['id'])
            require(wait(lambda: status(profile['id'])['engine_loaded'], timeout=40), 'fixture not loaded')
        # Keep Settings closed: key-window refresh can reopen fixture stores.
        app.call('ext-shortcuts', action='close')
        original_generation = status(profiles[0]['id'])['load_generation']
        capture.start()
        for index in range(1, 2 if negative else 6):
            capture.attachment(str(index))
            state = status(profiles[1]['id'])
            if negative:
                require(not state['engine_shared'], 'different-list control shared an engine: insensitive capture')
            require(status(profiles[0]['id'])['load_generation'] == original_generation,
                    'first Profile reloaded during attachment capture')
            row(('different_lists' if negative else 'shared') + '_attachment_sample_' + str(index),
                not state['engine_shared'] if negative else state['engine_shared'],
                engineShared=state['engine_shared'], load=os.getloadavg())
        capture.finish()
        require(before_inputs == [inputs(app, p) for p in profiles], 'inputs changed during attachment capture')
        totals = capture.totals()
        deltas = [capture.delta(totals, str(i)) for i in range(1, 2 if negative else 6)]
        evidence = dict(samples=deltas, metrics={k: summary([d[k] for d in deltas]) for k in deltas[0]},
                        inputs=before_inputs, rawCapture=str(capture.path), load=os.getloadavg())
        if negative:
            require(deltas[0]['paAllocated'] >= 8 * 1024 * 1024,
                    'different-list PA delta below 8 MiB: insensitive capture')
            row('sharing_rejects_different_lists_control', True, **evidence)
        else:
            row('shared_engine_footprint', evidence['metrics']['paAllocated']['medianBytes'] <= 2 * 1024 * 1024
                and evidence['metrics']['nonPAMallocInUse']['medianBytes'] <= 2 * 1024 * 1024,
                status='PASS' if all(evidence['metrics'][key]['medianBytes'] <= 2 * 1024 * 1024
                                    for key in ('paAllocated', 'nonPAMallocInUse')) else 'FAIL', **evidence)
    except (InvalidCapture, KeyError, OSError, ValueError) as error:
        row('memory_capture', False, status='INVALID', reason=str(error), rawCapture=str(capture.path))
    finally:
        if capture.active:
            capture.finish()
