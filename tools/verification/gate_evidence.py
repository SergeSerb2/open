"""Validate a completed real-App suite receipt; preserve non-PASS statuses."""
import json
from pathlib import Path


MAX_RECEIPT = 64 * 1024 * 1024
METADATA = {
    'extensions': {'chrome_extensions_page_url', 'welcome_tabs'},
    'tabstrip': {'events_seen', 'window_screenshot'},
    'sidebar-completion': {'manager_captures'},
    'window': {'chrome_activation_events', 'chrome_card_capture_sample', 'chrome_snapshot_files',
               'cpu_count', 'launch_runs', 'load_average'},
}


def load_receipt(path):
    if path.stat().st_size > MAX_RECEIPT:
        raise ValueError('real-App receipt exceeds 64 MiB')
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError('real-App receipt must be an object')
    return value


def e2e_rows(directory, suite, identity, engine, config, style, lane):
    candidates = []
    for path in directory.glob('results*.json'):
        receipt = load_receipt(path)
        if suite in receipt:
            candidates.append((path, receipt))
    if len(candidates) != 1:
        raise ValueError('expected exactly one receipt for '+suite)
    path, receipt = candidates[0]
    if receipt.get('source') != identity:
        raise ValueError('receipt source differs from the source that was built')
    if receipt.get('config') != config or receipt.get('style') != style:
        raise ValueError('receipt configuration/style mismatch')
    if receipt.get('lane') != lane:
        raise ValueError('receipt lane mismatch')
    actual = receipt.get('engine', {})
    if (actual.get('source') != 'fork' or actual.get('distributionSHA256') != engine
            or not actual.get('embeddedCodeSHA256')
            or actual.get('embeddedCodeSHA256') != actual.get('distributionCodeSHA256')):
        raise ValueError('receipt engine distribution/code mismatch')
    if receipt.get('interrupted_attempts'):
        raise ValueError('receipt contains interrupted attempts')
    cleanup = receipt.get('cleanup', {})
    if cleanup.get('ok') is not True or not cleanup.get('processes'):
        raise ValueError('missing or failed owned-process cleanup')
    for process in cleanup['processes']:
        if (not isinstance(process, dict) or process.get('ok') is not True
                or process.get('remaining_processes')
                or process.get('windows_after_quit', {}).get('count') != 0):
            raise ValueError('suite-owned process/window survived cleanup')
    checks = receipt[suite]
    if not isinstance(checks, dict) or not checks or len(checks) > 4096:
        raise ValueError('missing or excessive real-App checks')
    rows = []
    if suite == 'measure':
        # This legacy suite has one completion predicate at its group root.
        # Its samples are measurements, rather than independent PASS rows.
        if not isinstance(checks.get('ok'), bool):
            raise ValueError('measurement suite has no completion predicate')
        rows.append(dict(row='measure/ok', status='PASS' if checks['ok'] else 'FAIL',
                         reason='', evidence=str(path)))
        return rows
    for key, value in checks.items():
        if key in METADATA.get(suite, set()):
            continue
        if not isinstance(key, str) or len(key) > 256 or not isinstance(value, dict):
            raise ValueError('invalid real-App row')
        if key == 'suite' and value.get('ok') is False:
            failed_row = value.get('failedRow')
            if (isinstance(failed_row, str) and failed_row != 'suite'
                    and value.get('error') == 'row failed: ' + failed_row
                    and isinstance(checks.get(failed_row), dict)
                    and checks[failed_row].get('ok') is False):
                # CheckedResults stopped at this already-recorded assertion.
                # The raw receipt retains the stack/error; it is one failure,
                # not a second product predicate or an extra exception.
                continue
        # Some passing rows also carry a payload named status (for example
        # History's toast). The explicit boolean is their acceptance predicate.
        if 'ok' in value:
            if not isinstance(value['ok'], bool):
                raise ValueError('non-boolean acceptance predicate')
            status = 'PASS' if value['ok'] else 'FAIL'
        else:
            status = value.get('status')
            if status == 'INFO':
                if 'coveredBy' in value:
                    target = value['coveredBy']
                    if target != 'profiles/durable_second_profile' or suite != 'sidebar':
                        raise ValueError('unknown cross-suite coverage dependency')
                    rows.append(dict(row=suite+'/'+key, status='COVERAGE_REQUIRED',
                                     reason=value.get('reason', ''), coveredBy=target, evidence=str(path)))
                continue
            if status not in ('BLOCKED', 'DEFERRED', 'FAIL', 'INTERRUPTED', 'NOT_RUN',
                              'UNVERIFIED', 'SKIP', 'NOT_REQUESTED'):
                raise ValueError('row has no acceptance predicate: '+key)
        rows.append(dict(row=suite+'/'+key, status=status, reason=value.get('reason') or value.get('error') or '',
                         evidence=str(path), **({k: value[k] for k in ('timing', 'functionalOK', 'timingAfter') if k in value})))
    if not any(row['status'] == 'PASS' for row in rows):
        raise ValueError('suite has no passing real-App acceptance row')
    return rows
