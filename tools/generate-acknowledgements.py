#!/usr/bin/env python3
"""Generate About Credits.rtf and its text twin from the release inventory.

No network, third-party modules, or credentials. Preview mode warns about
missing/sample Chromium credits and an unset public MPL source location.
--require-cef-credits enforces both gates for existing release callers.
"""
import argparse
import hashlib
import html.parser
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
HEADER = ['Component', 'Version', 'License', 'How Open uses it', 'Source / offer']
MIB = 1024 * 1024


def read_bytes(path, limit):
    # Build inputs only. Bound reads before decoding or creating RTF objects;
    # the largest individual input is the 32 MiB Chromium credits document.
    with path.open('rb') as source:
        data = source.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f'input exceeds {limit} bytes: {path.name}')
    return data


def read_text(path, limit):
    return read_bytes(path, limit).decode('utf-8')


def inventory(path):
    rows = []
    inside = False
    for line in read_text(path, 2 * MIB).splitlines():
        if not line.startswith('|'):
            if inside:
                break
            continue
        cells = [cell.strip().replace('`', '') for cell in line.strip('|').split('|')]
        if cells == HEADER:
            inside = True
            continue
        if not inside or all(re.fullmatch(r':?-+:?', c) for c in cells):
            continue
        if len(cells) != 5 or any(not c for c in cells):
            raise ValueError('inventory row needs all five columns: ' + line)
        rows.append(cells)
        if len(rows) > 2048:
            raise ValueError('inventory exceeds 2048 components')
    names = [r[0] for r in rows]
    if not rows or len(names) != len(set(names)):
        raise ValueError('missing inventory table or duplicate component')
    return rows


def versions():
    spec = read_text(ROOT / 'project.yml', MIB)
    def setting(name):
        m = re.search(r'^\s+' + name + r':\s*"?([0-9.]+)"?\s*$', spec, re.M)
        if not m:
            raise ValueError('missing ' + name + ' in project.yml')
        return m[1]
    app = plistlib.loads(read_bytes(ROOT / 'App/Info.plist', MIB))
    stamp = app.get('OpenEngineStamp')
    if not stamp:
        pins = subprocess.check_output(
            ['/bin/bash', '-c', '. "$1"; printf "%s\n%s\n" "$CHROMIUM_TAG" "$CEF_COMMIT"',
             'pins', str(ROOT / 'Engine/fork/VERSIONS')], text=True).splitlines()
        stamp = 'Chromium ' + pins[0] + ' · CEF ' + pins[1][:7]
    return setting('MARKETING_VERSION'), setting('CURRENT_PROJECT_VERSION'), stamp


def check_versions(rows):
    by_name = {r[0]: r for r in rows}
    pins = subprocess.check_output(
        ['/bin/bash', '-c', '. "$1"; printf "%s\n%s\n" "$CHROMIUM_TAG" "$CEF_COMMIT"',
         'pins', str(ROOT / 'Engine/fork/VERSIONS')], text=True).splitlines()
    for name in ('Chromium', 'CEF', 'Public Suffix List', 'FFmpeg (Chromium bundled)',
                 'Sparkle', 'adblock (Brave adblock-rust)'):
        if name not in by_name:
            raise ValueError('missing required inventory row: ' + name)
    if by_name['Chromium'][1] != pins[0] or pins[1][:7] not in by_name['CEF'][1]:
        raise ValueError('Chromium/CEF inventory versions differ from VERSIONS')
    if pins[0] not in by_name['FFmpeg (Chromium bundled)'][1]:
        raise ValueError('FFmpeg inventory must name the current Chromium pin')
    psl = read_text(ROOT / 'Packages/OpenKit/Sources/OpenSuggest/Resources/public_suffix_list.dat', 2 * MIB)
    commit = re.search(r'^// COMMIT: (\w+)$', psl, re.M)
    if not commit or commit[1] not in by_name['Public Suffix List'][1]:
        raise ValueError('PSL inventory commit differs from the shipped source header')
    spec = read_text(ROOT / 'project.yml', MIB)
    if re.search(r'^\s+Sparkle:', spec, re.M):
        pin = re.search(r'exactVersion:\s*["\']?([0-9.]+)', spec)
        if not pin or by_name['Sparkle'][1] != pin[1]:
            raise ValueError('update the Sparkle inventory to the exact linked pin before generating credits')


def public_source_location(path):
    matches = re.findall(r'^Public MPL source location:[ \t]*(\S+)[ \t]*$',
                         read_text(path, 2 * MIB), re.M)
    if len(matches) != 1:
        return None
    location = matches[0]
    url = urlsplit(location)
    if url.scheme != 'https' or not url.hostname or url.username or url.password:
        return None
    return location


def state(row):
    """The use column states inclusion, independently of the version string."""
    for prefix in ('Ships:', 'Build only:', 'Not shipped:'):
        if row[3].startswith(prefix):
            return prefix
    raise ValueError('inventory needs an explicit shipping state: ' + row[0])


def license_texts(path, rows):
    # Each included row names its own texts; adding a crate cannot silently
    # omit its notice. Identical upstream bytes share one committed file.
    directory = (path.parent / 'licenses').resolve()
    pins = dict(re.findall(r'^\| licenses/([\w.-]+\.txt) \| [^|]+ \| `([a-f0-9]{64})` \|$',
                           read_text(path, 2 * MIB), re.M))
    names = set()
    for row in rows:
        refs = set(re.findall(r'licenses/([\w.-]+\.txt)', row[4]))
        if not refs and row[2] != 'Open-owned':
            raise ValueError('included component needs committed license text: ' + row[0])
        names.update(refs)
        if len(names) > 256:
            raise ValueError('inventory exceeds 256 distinct license texts')
    priority = ['MPL-2.0.txt', 'GPL-3.0.txt', 'MIT-Sparkle.txt', 'BSD-CEF.txt']
    ordered = [name for name in priority if name in names] + sorted(names - set(priority))
    result = []
    total = 0
    for name in ordered:
        source = directory / name
        if source.resolve().parent != directory:
            raise ValueError('license path leaves inventory directory: ' + name)
        data = read_bytes(source, 4 * MIB)
        total += len(data)
        if total > 16 * MIB:
            raise ValueError('license texts exceed 16 MiB total')
        if name not in pins or hashlib.sha256(data).hexdigest() != pins[name]:
            raise ValueError('license text differs from inventory SHA-256: ' + name)
        if len(data) < 100:
            raise ValueError('missing/truncated upstream license: ' + name)
        result.append((name, data.decode('utf-8')))
    return result


class CreditsParser(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.hidden = 0

    def handle_starttag(self, tag, attrs):
        if tag in ('script', 'style'):
            self.hidden += 1
        elif tag in ('p', 'div', 'br', 'pre', 'li', 'h1', 'h2', 'h3') and not self.hidden:
            self.parts.append('\n')

    def handle_endtag(self, tag):
        if tag in ('script', 'style'):
            self.hidden = max(0, self.hidden - 1)
        elif tag in ('p', 'div', 'pre', 'li', 'h1', 'h2', 'h3') and not self.hidden:
            self.parts.append('\n')

    def handle_data(self, data):
        if not self.hidden:
            self.parts.append(data)


def rtf(text):
    # RTF uses signed UTF-16 code units, including surrogate pairs for non-BMP
    # text. Escape braces/backslashes before emitting control words.
    escaped = []
    for char in text:
        if char in '\\{}':
            escaped.append('\\' + char)
        elif char == '\n':
            escaped.append('\\par\n')
        elif char == '\t':
            escaped.append('\\tab ')
        elif 32 <= ord(char) < 127:
            escaped.append(char)
        else:
            data = char.encode('utf-16-le')
            for i in range(0, len(data), 2):
                unit = int.from_bytes(data[i:i + 2], 'little')
                escaped.append('\\u%d?' % (unit if unit < 32768 else unit - 65536))
    return '{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\\uc1\\f0\\fs20\n' + ''.join(escaped) + '}\n'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('output', type=Path, help='Credits.rtf output path')
    p.add_argument('--text-output', type=Path, help='defaults to Acknowledgements.txt beside the RTF')
    p.add_argument('--inventory', type=Path, default=ROOT / 'docs/release/licenses.md')
    p.add_argument('--cef-credits', type=Path, default=ROOT / 'Vendor/cef/CREDITS.html')
    p.add_argument('--require-cef-credits', action='store_true',
                   help='release mode: require full CEF credits and the public MPL source location')
    p.add_argument('--require-public-source', action='store_true',
                   help='refuse an unset public MPL source location, even without full CEF credits')
    p.add_argument('--marketing-version')
    p.add_argument('--build-number')
    p.add_argument('--engine-stamp')
    p.add_argument('--app-info-plist', type=Path,
                   help='read versions and OpenEngineStamp from the built app')
    p.add_argument('--ubo-source', type=Path, help='bundled corresponding-source directory if the conditional GPL row ships')
    a = p.parse_args()
    marketing, build, stamp = versions()
    if a.app_info_plist:
        app = plistlib.loads(read_bytes(a.app_info_plist, MIB))
        marketing, build, stamp = (app[key] for key in
                                   ('CFBundleShortVersionString', 'CFBundleVersion', 'OpenEngineStamp'))
    marketing, build, stamp = a.marketing_version or marketing, a.build_number or build, a.engine_stamp or stamp
    if not re.fullmatch(r'\d+\.\d+\.\d+', marketing) or not re.fullmatch(r'[1-9]\d*', build):
        raise ValueError('expected SemVer marketing version and positive integer build')
    rows = inventory(a.inventory)
    check_versions(rows)
    shipped = [r for r in rows if state(r) == 'Ships:']
    included = [r for r in rows if state(r) != 'Not shipped:']
    texts = license_texts(a.inventory, included)
    source_location = public_source_location(a.inventory)
    needs_source = any('MPL-2.0' in r[2] for r in shipped)
    warnings = []
    failures = []
    if needs_source and not source_location:
        message = 'INCOMPLETE PREVIEW: public MPL source location is unset; user decision U-8 is required.'
        warnings.append(message)
        if a.require_public_source or a.require_cef_credits:
            failures.append(message)
    gpl = any(r[0] == 'uBlock Origin resources / scriptlets' for r in shipped)
    if gpl:
        row = next(r for r in shipped if r[0] == 'uBlock Origin resources / scriptlets')
        if 'GPL-3.0' not in row[2] or not re.search(r'https://\S+', row[4]):
            raise ValueError('uBlock assets need GPL-3.0 and a public corresponding-source URL')
        if not any(name == 'GPL-3.0.txt' for name, _ in texts):
            raise ValueError('uBlock assets need the full committed GPL-3.0.txt text')
        if not a.ubo_source or not a.ubo_source.is_dir():
            raise ValueError('uBlock assets require --ubo-source containing bundled source text')
        files = []
        for index, f in enumerate(a.ubo_source.rglob('*')):
            if index >= 8192 or len(f.relative_to(a.ubo_source).parts) > 64:
                raise ValueError('uBlock source exceeds 8192 paths or 64 directory levels')
            if f.is_file():
                files.append(f)
        if not files:
            raise ValueError('uBlock corresponding-source directory is empty')
        total = 0
        for f in files:
            data = read_bytes(f, 16 * MIB)
            total += len(data)
            if total > 64 * MIB:
                raise ValueError('uBlock corresponding source exceeds 64 MiB')
            data.decode('utf-8')

    paragraphs = [f'Open {marketing} ({build})', stamp, '']
    for name, version, license_name, use, offer in shipped:
        paragraphs.extend([f'{name} — {version} — {license_name}\n{use}\n{offer}', ''])
    if needs_source:
        paragraphs.extend(['Public MPL source location: ' + (source_location or 'UNSET (U-8 pending)'), ''])
    paragraphs.extend(['License texts', ''])
    for name, text in texts:
        paragraphs.extend([name, text.rstrip(), ''])
    complete = False
    cef_bytes = None
    if a.cef_credits.is_file():
        cef_bytes = read_bytes(a.cef_credits, 32 * MIB)
        raw = cef_bytes.decode('utf-8')
        complete = len(raw) > 10000 and 'This is sample credits page' not in raw
        if complete:
            parser = CreditsParser()
            parser.feed(raw)
            paragraphs.extend(['Chromium and third-party credits (HTML twin: CREDITS.html)',
                               ''.join(parser.parts).strip(), ''])
    if not complete:
        message = 'INCOMPLETE PREVIEW: full Chromium/codec CREDITS.html is missing or is the upstream sample.'
        if a.require_cef_credits:
            failures.append(message)
        warnings.append(message)
    if failures:
        raise ValueError('\n'.join(failures))
    for message in warnings:
        print('WARNING: ' + message, file=sys.stderr)
        paragraphs.extend([message, ''])
    text = '\n'.join(paragraphs)
    twin = a.text_output or a.output.with_name('Acknowledgements.txt')
    if a.output.resolve() == twin.resolve():
        raise ValueError('RTF and TXT outputs must be different paths')
    if any(output.resolve() == (directory / 'CREDITS.html').resolve()
           for output in (a.output, twin) for directory in (a.output.parent, twin.parent)):
        raise ValueError('RTF and TXT outputs must not overwrite the HTML twin')
    a.output.parent.mkdir(parents=True, exist_ok=True)
    twin.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(rtf(text), encoding='ascii')
    twin.write_text(text, encoding='utf-8')
    # Keep the exact distribution HTML next to each text output, including
    # previews. A sample twin is labelled incomplete above, never accepted.
    if cef_bytes is not None:
        for directory in {a.output.parent, twin.parent}:
            target = directory / 'CREDITS.html'
            if target.resolve() != a.cef_credits.resolve():
                target.write_bytes(cef_bytes)
    print(f'Generated {a.output} and {twin}')
    print(f"Component paragraphs: {len(shipped)}; conditional GPL: {'included' if gpl else 'omitted (assets not shipped)'}; Chromium credits: {'complete' if complete else 'INCOMPLETE PREVIEW'}")
    if needs_source:
        print('Public MPL source location: ' + (source_location or 'UNSET (U-8 pending)'))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print('acknowledgements: ' + str(error), file=sys.stderr)
        sys.exit(1)
