#!/usr/bin/env python3
"""Compile external callers against the built module. Never execute an object."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
modules = root / 'Packages/OpenKit/.build/release/Modules'
if not modules.is_dir():
    modules = root / 'Packages/OpenKit/.build/out/Products/Release'
# The package backend can use an older SDK than xcrun's default. Swift
# refuses that mismatch, so use the SDK path recorded in the built module.
built_module = modules / 'OpenImport.swiftmodule'
if built_module.is_dir():
    built_module = built_module / 'arm64-apple-macos.swiftmodule'
module_strings = subprocess.check_output(['strings', str(built_module)], text=True).splitlines()
sdk = next((line for line in module_strings if line.startswith('/') and '/SDKs/' in line and line.endswith('.sdk') and Path(line).is_dir()), None)
if sdk is None:
    sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
calls = [
    'fetchKeychainPassword(service: "fixture", account: "fixture")',
    'keychainItemExists(service: "fixture", account: "fixture")',
    'probeChromiumKeychainPair()',
    'decryptChromiumBlob([], key: [])',
    'ArcSecretsReader(profileDirectory: URL(fileURLWithPath: "/fixture")).readWithKey([])',
    'ArcSecretsReader(profileDirectory: URL(fileURLWithPath: "/fixture")).validateWithKey([])',
    'ArcSecretsBatchReader(profileDirectory: URL(fileURLWithPath: "/fixture"), file: .logins, key: [])',
]
with tempfile.TemporaryDirectory(prefix='open-consent-') as scratch:
    source, obj = Path(scratch) / 'external.swift', Path(scratch) / 'external.o'
    def compile(text):
        source.write_text('import Foundation\nimport OpenImport\n' + text)
        return subprocess.run(['xcrun', 'swiftc', '-c', '-swift-version', '6', '-target', 'arm64-apple-macos26.0', '-sdk', sdk, '-I', str(modules), str(source), '-o', str(obj)], capture_output=True, text=True)
    for index, call in enumerate(calls):
        result = compile('func check() throws { _ = try ' + call + ' }')
        if result.returncode == 0 or "missing argument for parameter 'consent'" not in result.stderr:
            sys.exit(f'FAIL token-less caller {index + 1}')
    result = compile('let token = SecretsImportConsent(reason: "fixture")')
    if result.returncode == 0 or 'private' not in result.stderr:
        sys.exit('FAIL private consent initializer')
    valid = ['_ = try ' + call[:-1] + ('' if call.endswith('()') else ', ') + 'consent: token)' for call in calls]
    result = compile('func check(token: SecretsImportConsent) throws {\n' + '\n'.join(valid) + '\n}')
    if result.returncode != 0:
        sys.exit('FAIL token-bearing signatures')
    result = compile('@MainActor func check(importer: ArcSecretsImporter, token: SecretsImportConsent) async throws { _ = try await importer.run(key: [], consent: token, sinks: [:]) }')
    if result.returncode != 0:
        sys.exit('FAIL token-bearing importer')
    result = compile('@MainActor func check(importer: ArcSecretsImporter) async throws { _ = try await importer.run(key: [], sinks: [:]) }')
    if result.returncode == 0 or "missing argument for parameter 'consent'" not in result.stderr:
        sys.exit('FAIL token-less importer')
print('PASS external consent compile: 8 token-less calls rejected; private initializer rejected; 8 token-bearing signatures compiled')
