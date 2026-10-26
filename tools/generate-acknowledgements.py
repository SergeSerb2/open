#!/usr/bin/env python3
"""Generate About Credits.rtf and its text twin from the release inventory.

No network, third-party modules, or credentials. Without --require-cef-credits,
missing/sample Chromium credits produce a visibly incomplete local preview.
"""
import argparse
import html.parser
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
HEADER = ['Component', 'Version', 'License', 'How Open uses it', 'Source / offer']


def inventory(path):
    rows = []
    inside = False
    for line in path.read_text(encoding='utf-8').splitlines():
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
    names = [r[0] for r in rows]
    if not rows or len(names) != len(set(names)):
        raise ValueError('missing inventory table or duplicate component')
    return rows


def versions():
    spec = (ROOT / 'project.yml').read_text(encoding='utf-8')
    def setting(name):
        m = re.search(r'^\s+' + name + r':\s*"?([0-9.]+)"?\s*$', spec, re.M)
        if not m:
            raise ValueError('missing ' + name + ' in project.yml')
        return m[1]
    app = plistlib.loads((ROOT / 'App/Info.plist').read_bytes())
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
    psl = (ROOT / 'Packages/OpenKit/Sources/OpenSuggest/Resources/public_suffix_list.dat').read_text()
    commit = re.search(r'^// COMMIT: (\w+)$', psl, re.M)
    if not commit or commit[1] not in by_name['Public Suffix List'][1]:
        raise ValueError('PSL inventory commit differs from the shipped source header')
    spec = (ROOT / 'project.yml').read_text()
    if re.search(r'^\s+Sparkle:', spec, re.M):
        pin = re.search(r'exactVersion:\s*["\']?([0-9.]+)', spec)
        if not pin or by_name['Sparkle'][1] != pin[1]:
            raise ValueError('update the Sparkle inventory to the exact linked pin before generating credits')


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
    p.add_argument('--require-cef-credits', action='store_true')
    p.add_argument('--marketing-version')
    p.add_argument('--build-number')
    p.add_argument('--engine-stamp')
    p.add_argument('--ubo-source', type=Path, help='bundled corresponding-source directory if the conditional GPL row ships')
    a = p.parse_args()
    marketing, build, stamp = versions()
    marketing, build, stamp = a.marketing_version or marketing, a.build_number or build, a.engine_stamp or stamp
    if not re.fullmatch(r'\d+\.\d+\.\d+', marketing) or not re.fullmatch(r'[1-9]\d*', build):
        raise ValueError('expected SemVer marketing version and positive integer build')
    rows = inventory(a.inventory)
    check_versions(rows)
    shipped = [r for r in rows if not re.search(r'not yet linked|not bundled', r[1], re.I)]
    gpl = any(r[0] == 'uBlock Origin resources / scriptlets' for r in shipped)
    if gpl:
        row = next(r for r in shipped if r[0] == 'uBlock Origin resources / scriptlets')
        if 'GPL-3.0' not in row[2] or not re.search(r'https://\S+', row[4]):
            raise ValueError('uBlock assets need GPL-3.0 and a public corresponding-source URL')
        if not a.ubo_source or not a.ubo_source.is_dir():
            raise ValueError('uBlock assets require --ubo-source containing bundled source text')
        files = [f for f in a.ubo_source.rglob('*') if f.is_file()]
        if not files:
            raise ValueError('uBlock corresponding-source directory is empty')
        for f in files:
            f.read_text(encoding='utf-8')

    paragraphs = [f'Open {marketing} ({build})', stamp, '']
    for name, version, license_name, use, offer in shipped:
        paragraphs.extend([f'{name} — {version} — {license_name}\n{use}\n{offer}', ''])
    paragraphs.extend(['License texts', ''])
    texts = ['MPL-2.0.txt'] + (['GPL-3.0.txt'] if gpl else []) + ['MIT-Sparkle.txt', 'BSD-CEF.txt']
    for name in texts:
        text = (a.inventory.parent / 'licenses' / name).read_text(encoding='utf-8')
        if len(text) < 500:
            raise ValueError('missing/truncated upstream license: ' + name)
        paragraphs.extend([name, text.rstrip(), ''])
    complete = False
    if a.cef_credits.is_file():
        raw = a.cef_credits.read_text(encoding='utf-8')
        complete = len(raw) > 10000 and 'This is sample credits page' not in raw
        if complete:
            parser = CreditsParser()
            parser.feed(raw)
            paragraphs.extend(['Chromium and third-party credits', ''.join(parser.parts).strip(), ''])
    if not complete:
        message = 'INCOMPLETE PREVIEW: full Chromium/codec CREDITS.html is missing or is the upstream sample.'
        if a.require_cef_credits:
            raise ValueError(message)
        print('WARNING: ' + message, file=sys.stderr)
        paragraphs.extend([message, ''])
    text = '\n'.join(paragraphs)
    twin = a.text_output or a.output.with_name('Acknowledgements.txt')
    if a.output.resolve() == twin.resolve():
        raise ValueError('RTF and TXT outputs must be different paths')
    a.output.parent.mkdir(parents=True, exist_ok=True)
    twin.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(rtf(text), encoding='ascii')
    twin.write_text(text, encoding='utf-8')
    print(f'Generated {a.output} and {twin}')
    print(f"Component paragraphs: {len(shipped)}; conditional GPL: {'included' if gpl else 'omitted (assets not shipped)'}; Chromium credits: {'complete' if complete else 'INCOMPLETE PREVIEW'}")


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print('acknowledgements: ' + str(error), file=sys.stderr)
        sys.exit(1)
