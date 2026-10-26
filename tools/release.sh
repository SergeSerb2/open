#!/bin/bash
# Local release orchestration. No engine builds, uploads, or production key creation.
# Bash 3.2: guard empty arrays under set -u.
set -euo pipefail
set -E
umask 077
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
export PATH="/opt/homebrew/bin:$PATH"
DRY=0 CHANNEL=stable SKIP_ENGINE=0 SKIP_NOTARY=0
IDENTITY=${OPEN_SIGN_IDENTITY:-}
PHASE=arguments
usage() {
    cat <<'EOF'
Usage: tools/release.sh [--dry-run] [--config stable|beta] [--skip-engine]
                        [--skip-notarize] [--identity "<full identity name>"]
Env: OPEN_SIGN_IDENTITY, OPEN_SPARKLE_TOOLS, OPEN_ENGINE_ROOT,
     OPEN_BUILD_JOBS (default 6)
Production requires the completed release prerequisites, an existing Developer ID
identity and open-notary profile. This script never creates them or publishes.
Dry runs use ad-hoc signing and a temporary file-based Sparkle seed, never Keychain.
Unfinished Steps 2, 4–8 or 10 cause explicit mode-SKIP rows in dry runs.
--skip-engine reuses Vendor/cef but still requires official-engine provenance.
--skip-notarize produces NOT-NOTARIZED internal artifacts, never a publishable feed.
EOF
}
log() { printf 'release [%s]: %s\n' "$PHASE" "$*"; }
die() { log "FAIL: $*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --dry-run) DRY=1; shift ;;
        --config) [[ $# -ge 2 ]] || die '--config needs stable or beta'; CHANNEL=$2; shift 2 ;;
        --skip-engine) SKIP_ENGINE=1; shift ;;
        --skip-notarize) SKIP_NOTARY=1; shift ;;
        --identity) [[ $# -ge 2 && -n "$2" ]] || die '--identity needs a full name'; IDENTITY=$2; shift 2 ;;
        *) die "unknown option: $1" ;;
    esac
done
case "$CHANNEL" in stable|beta) ;; *) die "invalid channel: $CHANNEL" ;; esac
case "${OPEN_BUILD_JOBS:-6}" in ''|*[!0-9]*|0) die 'OPEN_BUILD_JOBS must be a positive integer' ;; esac
command -v python3 >/dev/null || die 'python3 required'
settings=$(python3 - <<'PY'
import plistlib,re
from pathlib import Path
s=Path('project.yml').read_text()
def get(k):
 m=re.search(r'^\s+'+k+r':\s*"?([\w.]+)"?\s*$',s,re.M)
 if not m: raise SystemExit('missing '+k)
 return m[1]
v,b=get('MARKETING_VERSION'),get('CURRENT_PROJECT_VERSION')
if not re.fullmatch(r'\d+\.\d+\.\d+',v) or not re.fullmatch(r'[1-9]\d*',b): raise SystemExit('invalid version/build')
print(v);print(b)
p=plistlib.loads(Path('App/Info.plist').read_bytes())
print(p.get('OpenEngineStamp',''))
pin=re.search(r'Sparkle:\s*\{[^}]*exactVersion:\s*"?([0-9.]+)',s)
if not pin:
 block=re.search(r'^\s+Sparkle:\s*\n((?:[ \t]+[^\n]*\n)+)',s,re.M)
 pin=re.search(r'exactVersion:\s*"?([0-9.]+)',block[1]) if block else None
print(pin[1] if pin else '')
PY
)
VERSION=$(printf '%s\n' "$settings" | sed -n '1p')
BUILD=$(printf '%s\n' "$settings" | sed -n '2p')
ENGINE_STAMP=$(printf '%s\n' "$settings" | sed -n '3p')
SPARKLE_PIN=$(printf '%s\n' "$settings" | sed -n '4p')
# shellcheck source=../Engine/fork/VERSIONS
. "$ROOT/Engine/fork/VERSIONS"
ENGINE_ROOT=${OPEN_ENGINE_ROOT:-$HOME/$ENGINE_ROOT_DEFAULT}
SRC="$ENGINE_ROOT/$CHROMIUM_SRC_SUBDIR"
REL="$ROOT/build/release/$VERSION-$BUILD"
STAGE="$REL/.staging"
STAMPS="$REL/.stamps"
APP="$REL/Open.app"
DMG="$REL/Open-$VERSION.dmg"
TAG="v$VERSION"
[[ "$CHANNEL" != beta ]] || TAG="v$VERSION-beta.$BUILD"
FEED=appcast.xml
[[ "$CHANNEL" != beta ]] || FEED=appcast-beta.xml
TOOLS=${OPEN_SPARKLE_TOOLS:-$HOME/Developer/open-release-tools/sparkle-${SPARKLE_PIN:-UNCONFIGURED}/bin}
MODE=production
[[ $SKIP_NOTARY == 0 ]] || MODE=NOT-NOTARIZED
if [[ $DRY == 1 ]]; then MODE=dry-run; IDENTITY=-; fi
mkdir -p "$STAGE" "$STAMPS"
[[ ! -L "$REL" && ! -L "$STAGE" && ! -L "$STAMPS" ]] || die 'release directories must not be symlinks'
mkdir "$REL/.release-lock" 2>/dev/null || die "another release owns $REL/.release-lock; inspect its PID before removing a stale lock"
printf '%s\n' "$$" > "$REL/.release-lock/pid"
KEY_DIR=
MOUNT_DIR=
cleanup() {
    [[ -z "$MOUNT_DIR" ]] || hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
    [[ -z "$KEY_DIR" ]] || rm -rf "$KEY_DIR"
    rm -f "$REL/.release-lock/pid"
    rmdir "$REL/.release-lock" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM
trap 'die "command failed (exit $?) in this phase; see $REL/release.log"' ERR
exec > >(tee -a "$REL/release.log") 2>&1

# Content hashes include paths, file modes, symlink targets and bytes. Phase
# snapshots are immutable, so later signing/stapling cannot invalidate earlier
# build/hygiene stamps. Changing modes, source, tools, engine or outputs reruns work.
digest() {
    python3 - "$@" <<'PY'
import hashlib,os,stat,sys
from pathlib import Path
h=hashlib.sha256()
def add(p):
 h.update(str(p).encode()+b'\0')
 if p.is_symlink(): h.update(b'link\0'+os.readlink(p).encode());return
 if not p.exists(): h.update(b'missing');return
 h.update(str(stat.S_IMODE(p.stat().st_mode)).encode())
 if p.is_dir():
  for c in sorted(p.iterdir()): add(c)
 elif p.is_file():
  with p.open('rb') as f:
   for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
for name in sys.argv[1:]:add(Path(name))
print(h.hexdigest())
PY
}
result() { printf '%s\t%s\n' "$1" "$2" > "$STAMPS/$PHASE.result"; }
output() { printf '%s\n' "$@" >> "$STAMPS/$PHASE.outputs"; }
mode_skip() {
    [[ $DRY == 1 ]] || die "$*"
    result mode-SKIP "$*"
    log "mode-SKIP: $*"
}
ready() { [[ -f "$STAMPS/$1.result" ]] && [[ $(cut -f1 "$STAMPS/$1.result") == PASS ]]; }
reason() { cut -f2- "$STAMPS/$1.result"; }
row() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STAGE/acceptance.tsv"; }
replace_row() {
    sed "/^$1[[:space:]]/d" "$STAGE/acceptance.tsv" > "$STAGE/acceptance.tmp"
    mv "$STAGE/acceptance.tmp" "$STAGE/acceptance.tsv"
    row "$@"
}
print_acceptance_table() {
    printf '\n%-7s %-12s %s\n' CHECK RESULT EVIDENCE
    while IFS=$'\t' read -r id status evidence; do printf '%-7s %-12s %s\n' "$id" "$status" "$evidence"; done < <(LC_ALL=C sort -t $'\t' -k1.3n "$STAGE/acceptance.tsv")
}
require_release_inputs() {
    local missing=0 id status evidence
    for file in "$ROOT/tools/release-locales.txt" "$ROOT/docs/release/notes/$VERSION.md" "$ROOT/tools/generate-acknowledgements.py"; do
        [[ -f "$file" ]] || missing=1
    done
    [[ $missing == 1 ]] || return 0
    PHASE=required-inputs
    : > "$STAGE/acceptance.tsv"
    for id in {1..15}; do
        status=NOT-RUN evidence='blocked by missing required release inputs'
        case "$id" in
            8) if [[ ! -f "$ROOT/tools/release-locales.txt" ]]; then status=FAIL; evidence='Step 3 missing: tools/release-locales.txt'; fi ;;
            12) if [[ ! -f "$ROOT/docs/release/notes/$VERSION.md" ]]; then status=FAIL; evidence="Step 9/version bump missing: docs/release/notes/$VERSION.md"; fi ;;
            14) if [[ ! -f "$ROOT/tools/generate-acknowledgements.py" ]]; then status=FAIL; evidence='Step 9 missing: tools/generate-acknowledgements.py'; fi ;;
        esac
        row "A-$id" "$status" "$evidence"
    done
    printf 'FAIL\tmissing required release inputs\n' > "$STAMPS/12-summary.result"
    rm -f "$STAMPS/12-summary.stamp"
    print_acceptance_table
    die 'required input files are missing; see FAIL rows above'
}
require_release_inputs
# Source prerequisite checks are data, not edits to files owned by other steps.
prerequisites=$(python3 - <<'PY'
import plistlib,re
from pathlib import Path
s=Path('project.yml').read_text();p=plistlib.loads(Path('App/Info.plist').read_bytes())
missing=[]
if 'PRODUCT_BUNDLE_IDENTIFIER: io.github.sergeserb2.open' not in s or 'app.open.browser' in s:missing.append('Step 4 bundle-ID migration')
e=plistlib.loads(Path('App/Open.entitlements').read_bytes())
if not e.get('com.apple.security.personal-information.photos-library') or not e.get('com.apple.security.device.print'):missing.append('Step 5 app entitlements')
if any(k.startswith('com.apple.security.cs.') for k in e) or e.get('com.apple.security.get-task-allow'):raise SystemExit('unexpected main-app signing exceptions')
for k in ['OpenChromiumVersion','OpenCEFCommit','OpenEngineStamp','SUFeedURL','SUPublicEDKey']:
 if not p.get(k):missing.append('Step 6 Info.plist '+k)
if not re.search(r'Release:\s*\n\s+ENABLE_HARDENED_RUNTIME:\s*YES',s):missing.append('Step 6 Release runtime setting')
if not re.search(r'^\s+Sparkle:',s,re.M):missing.append('Step 7 Sparkle dependency')
if not Path('App/UpdaterController.swift').is_file():missing.append('Step 8 updater controller')
print('; '.join(missing))
PY
)
# Resolving an existing identity is read-only. Dry runs never query Keychain.
TEAM=
if [[ $DRY == 0 ]]; then
    identities=$(security find-identity -v -p codesigning)
    if [[ -z "$IDENTITY" ]]; then
        candidates=$(printf '%s\n' "$identities" | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p')
        count=$(printf '%s\n' "$candidates" | sed '/^$/d' | wc -l | tr -d ' ')
        [[ "$count" == 1 ]] || die "expected exactly one Developer ID identity; supply --identity. Candidates: $candidates"
        IDENTITY=$candidates
    fi
    [[ "$IDENTITY" == 'Developer ID Application: '* ]] || die 'production requires a Developer ID Application identity'
    printf '%s\n' "$identities" | grep -Fq "\"$IDENTITY\"" || die 'requested identity is not installed/valid'
    TEAM=$(printf '%s\n' "$IDENTITY" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')
    [[ -n "$TEAM" ]] || die 'cannot read Team ID from identity'
fi
LOCALES=$(python3 - <<'PY'
import re
from pathlib import Path
values={'en'}
for l in Path('tools/release-locales.txt').read_text().splitlines():
 l=l.split('#',1)[0].strip()
 if not l:continue
 if not re.fullmatch(r'[A-Za-z0-9_@-]+',l):raise SystemExit('invalid locale line: '+l)
 values.add(l)
print(' '.join(sorted(values)))
PY
)
recorded=$(cat "$ENGINE_ROOT/.open-engine-state/distrib.txt" 2>/dev/null || true)
official_fw="$SRC/$OUT_DIR_RELEASE/cefclient.app/Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework"
# The current fork also supports the flat framework layout.
[[ -f "$official_fw" ]] || official_fw="$SRC/$OUT_DIR_RELEASE/Chromium Embedded Framework.framework/Chromium Embedded Framework"
source_list="$STAGE/source-inputs.txt"
git ls-files --cached --others --exclude-standard -- App Helper Engine Packages tools assets docs/release project.yml > "$source_list"
source_hash=$(python3 - "$source_list" <<'PY'
import hashlib,subprocess,sys
from pathlib import Path
h=hashlib.sha256(subprocess.check_output(['git','rev-parse','HEAD']))
for name in sorted(set(Path(sys.argv[1]).read_text().splitlines())):
 p=Path(name);h.update(name.encode())
 if p.is_symlink():h.update(str(p.readlink()).encode())
 elif p.is_file():h.update(p.read_bytes());h.update(str(p.stat().st_mode).encode())
print(h.hexdigest())
PY
)
BASE=$(printf '%s\n' "$source_hash" "$MODE" "$CHANNEL" "$SKIP_ENGINE" "$SKIP_NOTARY" "$IDENTITY" "$LOCALES" "$TOOLS" "${OPEN_BUILD_JOBS:-6}" "$prerequisites" "$(digest "$SRC/$OUT_DIR_RELEASE/args.gn" "$official_fw" "$ENGINE_ROOT/.open-engine-state/distrib.txt" "${recorded:-$STAGE/no-distrib}/README.txt" "${recorded:-$STAGE/no-distrib}/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework" "${recorded:-$STAGE/no-distrib}/CREDITS.html" "$ENGINE_ROOT/.open-engine-state/applied.json" "$TOOLS/generate_appcast" "$TOOLS/sign_update")" | shasum -a 256 | awk '{print $1}')
CHAIN=$BASE
run_phase() {
    PHASE=$1
    local fn=$2 extra_input=${3:-} want got stamp="$STAMPS/$1.stamp" result_file="$STAMPS/$1.result" outputs="$STAMPS/$1.outputs"
    want=$(printf '%s\n%s\n%s\n%s\n' "$BASE" "$CHAIN" "$PHASE" "$extra_input" | shasum -a 256 | awk '{print $1}')
    if [[ -f "$stamp" && -f "$outputs" && -f "$result_file" ]] && [[ $(head -1 "$stamp") == "$want" ]]; then
        local paths=()
        while IFS= read -r path; do paths+=("$path"); done < "$outputs"
        got=$(digest ${paths[@]+"${paths[@]}"})
        if [[ "$got" == "$(sed -n '2p' "$stamp")" ]]; then
            log "NO-OP (stamp): $(cat "$result_file")"
            CHAIN=$(digest "$stamp")
            return
        fi
    fi
    log START
    : > "$outputs"
    result PASS 'completed'
    output "$result_file"
    "$fn"
    local paths=()
    while IFS= read -r path; do paths+=("$path"); done < "$outputs"
    got=$(digest ${paths[@]+"${paths[@]}"})
    printf '%s\n%s\n' "$want" "$got" > "$stamp.tmp"
    mv "$stamp.tmp" "$stamp"
    CHAIN=$(digest "$stamp")
    log "END: $(cat "$result_file")"
}
preflight() {
    [[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || die 'macOS arm64 required'
    [[ $(sw_vers -productVersion | cut -d. -f1) -ge 26 ]] || die 'macOS 26 or newer required'
    for tool in xcodebuild xcodegen python3 ditto hdiutil codesign xcrun curl xmllint openssl swift lipo; do
        command -v "$tool" >/dev/null || die "missing $tool"
    done
    xcodebuild -version
    command -v gh >/dev/null || log 'WARN: gh unavailable (manual publishing only)'
    python3 - "$REL" <<'PY'
import shutil,sys
free=shutil.disk_usage(sys.argv[1]).free
print('Free bytes:',free)
if free < 5*1024**3: raise SystemExit('at least 5 GB free required')
PY
    if [[ $DRY == 0 && $SKIP_NOTARY == 0 ]]; then xcrun notarytool history --keychain-profile open-notary > "$STAGE/notary-history.txt"; fi
    if [[ -n "$prerequisites" ]]; then
        [[ $DRY == 1 ]] || die "$prerequisites"
        log "Dry-run prerequisites not landed: $prerequisites"
    fi
    if [[ ! -x "$TOOLS/generate_appcast" || ! -x "$TOOLS/sign_update" ]]; then
        [[ $DRY == 1 ]] || die "Step 7 Sparkle tools missing: $TOOLS"
        log "Step 7 tools unavailable: $TOOLS"
    else
        "$TOOLS/generate_appcast" --help > "$STAGE/generate_appcast-help.txt"
        for flag in --ed-key-file --download-url-prefix --link --channel; do
            grep -q -- "$flag" "$STAGE/generate_appcast-help.txt" || die "pinned generate_appcast lacks $flag; stop for tool contract drift"
        done
    fi
    printf 'mode=%s\nchannel=%s\nlocales=%s\nprerequisites=%s\n' "$MODE" "$CHANNEL" "$LOCALES" "$prerequisites" > "$STAGE/preflight.txt"
    output "$STAGE/preflight.txt"
}
engine() {
    if [[ ! -f "$official_fw" || ! -f "$SRC/$OUT_DIR_RELEASE/args.gn" ]]; then
        mode_skip 'Steps 2/10: official engine output/provenance unavailable; the engine lead owns the build and packaging (PGO must be fetched first). No engine build attempted.'
        return
    fi
    [[ -n "$recorded" && -d "$recorded" ]] || die 'Step 10 must record an official directory distribution before release'
    python3 - "$SRC/$OUT_DIR_RELEASE/args.gn" "$recorded" "$CHROMIUM_COMMIT" "$CEF_COMMIT" "$official_fw" <<'PY'
from pathlib import Path
import hashlib,re,sys
args,dist,chromium,cef,fw=sys.argv[1:];s=Path(args).read_text()
for key,value in [('is_official_build','true'),('chrome_pgo_phase','2'),('use_thin_lto','true'),('enable_widevine','false')]:
 vals=re.findall(r'^\s*'+key+r'\s*=\s*(\w+)\s*(?:#.*)?$',s,re.M)
 if not vals or vals[-1]!=value:raise SystemExit('official args mismatch: '+key)
d=Path(dist);readme=(d/'README.txt').read_text()
if chromium not in readme or cef not in readme:raise SystemExit('distrib README commits differ from VERSIONS')
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
 return h.hexdigest()
f=d/'Release/Chromium Embedded Framework.framework/Chromium Embedded Framework'
if not f.is_file() or sha(f)!=sha(Path(fw)):raise SystemExit('distrib is not the official output binary; never ship dev output')
print('Official output/distrib SHA-256:',sha(f))
PY
    # engine-status has no --config flag. Override only its pins file locally so
    # its S-6 probe targets the official output, without editing the shared tree.
    { printf '. "%s"\n' "$ROOT/Engine/fork/VERSIONS"; printf 'OUT_DIR_DEV=%s\n' "$OUT_DIR_RELEASE"; } > "$STAGE/official-versions"
    OPEN_ENGINE_VERSIONS="$STAGE/official-versions" "$ROOT/Engine/fork/scripts/engine-status" --strict > "$STAGE/engine-status.txt"
    if [[ $SKIP_ENGINE == 0 ]]; then "$ROOT/tools/fetch-engine.sh" --run; fi
    [[ -f "$ROOT/Vendor/cef/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework" ]] || die 'Vendor/cef has no framework; run tools/fetch-engine.sh --run after Step 10'
    cmp "$official_fw" "$ROOT/Vendor/cef/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework" || die 'Vendor/cef does not hold the official framework'
    mkdir -p "$REL/symbols"
    while IFS= read -r -d '' d; do ditto "$d" "$REL/symbols/$(basename "$d")"; done < <(find "$SRC/$OUT_DIR_RELEASE" -maxdepth 4 -name '*.dSYM' -type d -print0)
    find "$SRC/$OUT_DIR_RELEASE" -maxdepth 4 -name '*.sym' -type f -exec cp {} "$REL/symbols/" \;
    [[ -n $(find "$REL/symbols" -type f -print -quit) ]] || die 'no release symbols found for the local archive'
    output "$STAGE/engine-status.txt" "$REL/symbols" "$official_fw" "$ROOT/Vendor/cef/Release/Chromium Embedded Framework.framework/Chromium Embedded Framework"
}
prepare_notes_inputs() {
    # Observe external inputs before consulting the notes stamp. Preserve the
    # snapshot bytes/mtime when unchanged so an identical run remains a no-op.
    PHASE=03-notes-inputs
    local status fetch_exit=0
    status=$(curl -sS -L --connect-timeout 5 --max-time 15 -o "$STAGE/current-feed.fetch" -w '%{http_code}' "https://sergeserb2.github.io/open/$FEED" 2>/dev/null) || fetch_exit=$?
    python3 - "$ROOT/build/release" "$REL" "$BUILD" "$CHANNEL" "$MODE" "$FEED" "${status:-offline}" "$fetch_exit" <<'PY'
from pathlib import Path
import hashlib,json,sys
base,current,build,channel,mode,feed,status,exit_code=sys.argv[1:]
stage=Path(current)/'.staging'
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
 return h.hexdigest()
def save(name,data):
 p=stage/name
 if not p.is_file() or p.read_bytes()!=data:p.write_bytes(data)
present=status=='200' and exit_code=='0'
body=(stage/'current-feed.fetch').read_bytes() if present else b''
feed_digest=hashlib.sha256(body).hexdigest() if present else 'absent'
save('current-feed.xml',body)
save('feed-fetch.txt',(('present' if present else 'absent')+'\nHTTP '+status+'; curl exit '+exit_code+'\n').encode())
candidates=[]
for p in Path(base).glob('*/RELEASE-MANIFEST.txt'):
 if str(p.parent)==current:continue
 values=dict(l.split('=',1) for l in p.read_text().splitlines() if '=' in l and not l.startswith('SHA256'))
 if values.get('channel')==channel and values.get('mode')==mode and values.get('build','').isdigit() and int(values['build'])<int(build):
  d=p.parent/('Open-'+values.get('marketing','')+'.dmg')
  if d.is_file():candidates.append((int(values['build']),str(d)))
previous={'sha256':'absent'}
previous_text=''
if candidates:
 b,name=max(candidates);d=Path(name);previous_feed=d.parent/feed
 previous={'build':b,'path':name,'sha256':sha(d),'feed_sha256':sha(previous_feed) if previous_feed.is_file() else 'absent'}
 previous_text=str(b)+'\n'+name+'\n'
save('previous.txt',previous_text.encode())
inputs={'feed_sha256':feed_digest,'predecessor':previous}
save('notes-live-inputs.json',(json.dumps(inputs,sort_keys=True,indent=2)+'\n').encode())
print('Live notes inputs: feed='+feed_digest+'; predecessor='+previous['sha256'])
PY
    rm -f "$STAGE/current-feed.fetch"
}
notes() {
    require_release_inputs
    local source="$ROOT/docs/release/notes/$VERSION.md"
    if grep -Eq '<[^>]+>|release-notes template' "$source"; then
        [[ $DRY == 1 ]] || die 'replace release-note template placeholders before production'
        log 'WARN: release notes are an explicitly labeled local template'
    fi
    cp "$source" "$REL/release-notes.md"
    if [[ $(head -1 "$STAGE/feed-fetch.txt") == present ]]; then
        python3 - "$STAGE/current-feed.xml" "$BUILD" <<'PY'
import sys,xml.etree.ElementTree as E
root=E.parse(sys.argv[1]).getroot();ns='{http://www.andymatuschak.org/xml-namespaces/sparkle}'
versions=[int(e.text) for e in root.iter(ns+'version') if e.text and e.text.isdecimal()]
if versions and int(sys.argv[2])<=max(versions):raise SystemExit('build number must exceed current feed: '+str(max(versions)))
print('Build exceeds current feed:',max(versions) if versions else 'empty')
PY
    else
        log "WARN: current feed unavailable ($(tail -1 "$STAGE/feed-fetch.txt")); build monotonicity needs confirmation before publish"
    fi
    [[ -s "$STAGE/previous.txt" ]] || log 'No previous same-channel local DMG: no delta will be generated'
    output "$REL/release-notes.md" "$STAGE/previous.txt" "$STAGE/current-feed.xml" "$STAGE/feed-fetch.txt" "$STAGE/notes-live-inputs.json"
}
acknowledgements() {
    require_release_inputs
    if [[ -z "$ENGINE_STAMP" ]]; then mode_skip 'Step 6 OpenEngineStamp is not present in App/Info.plist'; return; fi
    if ! ready 02-engine; then mode_skip "$(reason 02-engine)"; return; fi
    python3 tools/generate-acknowledgements.py "$STAGE/credits/Credits.rtf" --text-output "$REL/Acknowledgements.txt" --marketing-version "$VERSION" --build-number "$BUILD" --engine-stamp "$ENGINE_STAMP" --require-cef-credits
    cp Vendor/cef/CREDITS.html "$REL/CREDITS.html"
    output "$STAGE/credits/Credits.rtf" "$REL/Acknowledgements.txt" "$REL/CREDITS.html"
}
app_build() {
    if ! ready 02-engine; then mode_skip "$(reason 02-engine)"; return; fi
    if [[ -n "$prerequisites" ]]; then mode_skip "$prerequisites"; return; fi
    if ! ready 04-acknowledgements; then mode_skip "$(reason 04-acknowledgements)"; return; fi
    [[ ${OPEN_AUTOMATION:-0} != 1 ]] || die 'OPEN_AUTOMATION must be off for release'
    # No gclient, engine-build, or autoninja. This is the Swift/ObjC++ shell build.
    OPEN_AUTOMATION=0 CEF_SOURCE=fork OPEN_KEEP_LOCALES="$LOCALES" python3 -c 'import subprocess,sys;sys.exit(subprocess.call(sys.argv[1:],start_new_session=True))' "$ROOT/tools/build.sh" Release
    rm -rf "$STAGE/built"
    mkdir -p "$STAGE/built"
    ditto "$ROOT/build/Release/Open.app" "$STAGE/built/Open.app"
    cp "$ROOT/build/xcodebuild-Release.log" "$STAGE/app-build.log"
    output "$STAGE/built" "$STAGE/app-build.log"
}
bundle_check() {
    python3 - "$1" "$LOCALES" "$VERSION" "$BUILD" "$CHROMIUM_TAG" "$CEF_COMMIT" "$ENGINE_STAMP" "$SPARKLE_PIN" <<'PY'
from pathlib import Path
import plistlib,re,subprocess,sys
app,locales,version,build,chromium,cef,stamp,sparkle=sys.argv[1:];a=Path(app)
p=plistlib.loads((a/'Contents/Info.plist').read_bytes())
for k,v in [('CFBundleIdentifier','io.github.sergeserb2.open'),('CFBundleShortVersionString',version),('CFBundleVersion',build),('OpenChromiumVersion',chromium),('OpenCEFCommit',cef),('OpenEngineStamp',stamp),('LSMinimumSystemVersion','26.0')]:
 if p.get(k)!=v:raise SystemExit('bundle metadata mismatch: '+k)
if stamp!=f'Chromium {chromium} · CEF {cef[:7]}':raise SystemExit('engine display stamp differs from VERSIONS')
if p.get('SUFeedURL')!='https://sergeserb2.github.io/open/appcast.xml':raise SystemExit('unexpected update feed URL')
fw=a/'Contents/Frameworks/Chromium Embedded Framework.framework'
binaries=[a/'Contents/MacOS/Open',a/'Contents/Frameworks/OpenEngine.framework/OpenEngine',fw/'Chromium Embedded Framework']
for name in ['Open Helper','Open Helper (GPU)','Open Helper (Renderer)','Open Helper (Plugin)','Open Helper (Alerts)']:
 binaries.append(a/'Contents/Frameworks'/(name+'.app')/'Contents/MacOS'/name)
for binary in binaries:
 archs=subprocess.check_output(['lipo','-archs',str(binary)],text=True).split()
 if archs!=['arm64']:raise SystemExit('expected arm64-only binary: '+str(binary)+'; got '+repr(archs))
print('Architecture: arm64 only (app, five helpers, OpenEngine, CEF)')
actual=sorted(x.name[:-6] for x in (fw/'Resources').glob('*.lproj'))
if actual!=locales.split():raise SystemExit('locale mismatch: '+repr(actual))
for f in a.rglob('*'):
 if f.name.endswith(('.dSYM','.delta')) or re.search(r'(^|[-_])(test[-_]?fixtures?)([-_.]|$)',f.name,re.I):raise SystemExit('unshippable bundle item: '+str(f))
 if f.is_symlink() and not f.resolve().is_relative_to(a.resolve()):raise SystemExit('bundle symlink escapes app: '+str(f))
for name in ['icudtl.dat','resources.pak','chrome_100_percent.pak','chrome_200_percent.pak']:
 if not (fw/'Resources'/name).is_file():raise SystemExit('required CEF resource missing: '+name)
if not list((fw/'Resources').glob('v8_context_snapshot*.bin')):raise SystemExit('missing V8 snapshot')
if not (fw/'Libraries/libvk_swiftshader.dylib').is_file():raise SystemExit('missing SwiftShader')
if b'automation.sock' in subprocess.check_output(['strings',str(a/'Contents/MacOS/Open')]):raise SystemExit('automation socket compiled into release')
sp=a/'Contents/Frameworks/Sparkle.framework/Resources/Info.plist'
if not sp.is_file() or plistlib.loads(sp.read_bytes()).get('CFBundleShortVersionString')!=sparkle:raise SystemExit('embedded Sparkle differs from exact project pin')
print('Bundle metadata, locales, symbols, fixtures, engine resources and automation: PASS')
PY
}
hygiene() {
    if ! ready 05-app-build; then mode_skip "$(reason 05-app-build)"; return; fi
    rm -rf "$STAGE/hygiene"
    mkdir -p "$STAGE/hygiene"
    ditto "$STAGE/built/Open.app" "$STAGE/hygiene/Open.app"
    cp "$STAGE/credits/Credits.rtf" "$STAGE/hygiene/Open.app/Contents/Resources/Credits.rtf"
    grep -Eq -- '-D[[:space:]]*OPEN_AUTOMATION|automation.sock' "$STAGE/app-build.log" && die 'automation condition found in release build log'
    bundle_check "$STAGE/hygiene/Open.app"
    output "$STAGE/hygiene"
}
sign_one() {
    local target=$1 entitlements=${2:-} preserve=${3:-0}
    local args=(--force --options runtime --sign "$IDENTITY")
    if [[ $DRY == 1 ]]; then args+=(--timestamp=none); else args+=(--timestamp); fi
    [[ -z "$entitlements" ]] || args+=(--entitlements "$entitlements")
    # Keep Sparkle's existing XPC entitlement sets when replacing its authority.
    [[ "$preserve" == 0 ]] || args+=(--preserve-metadata=entitlements)
    codesign "${args[@]}" "$target"
}
sign_app() {
    if ! ready 06-hygiene; then mode_skip "$(reason 06-hygiene)"; return; fi
    rm -rf "$STAGE/signed"
    mkdir -p "$STAGE/signed"
    ditto "$STAGE/hygiene/Open.app" "$STAGE/signed/Open.app"
    local a="$STAGE/signed/Open.app" frameworks="$STAGE/signed/Open.app/Contents/Frameworks" file
    while IFS= read -r file; do sign_one "$file"; done < <(find -H "$frameworks/Chromium Embedded Framework.framework/Libraries" -type f -name '*.dylib' | LC_ALL=C sort)
    sign_one "$frameworks/Chromium Embedded Framework.framework"
    local sp="$frameworks/Sparkle.framework/Versions/B"
    [[ -d "$sp" ]] || die 'Step 7 Sparkle bundle missing'
    sign_one "$sp/Autoupdate" '' 1
    sign_one "$sp/XPCServices/Downloader.xpc" '' 1
    sign_one "$sp/XPCServices/Installer.xpc" '' 1
    sign_one "$sp/Updater.app" '' 1
    sign_one "$frameworks/Sparkle.framework" '' 1
    sign_one "$frameworks/OpenEngine.framework"
    local suffix name ent
    for suffix in '' .gpu .renderer .plugin .alerts; do
        case "$suffix" in '') name='Open Helper' ;; .gpu) name='Open Helper (GPU)' ;; .renderer) name='Open Helper (Renderer)' ;; .plugin) name='Open Helper (Plugin)' ;; .alerts) name='Open Helper (Alerts)' ;; esac
        ent="$ROOT/Helper/Entitlements/helper$suffix.entitlements"
        sign_one "$frameworks/$name.app" "$ent"
    done
    if [[ $DRY == 0 ]]; then
        python3 - "$a/Contents/Info.plist" <<'PYKEY'
import base64,plistlib,sys
with open(sys.argv[1],'rb') as f:p=plistlib.load(f)
try:key=base64.b64decode(p.get('SUPublicEDKey',''),validate=True)
except ValueError:raise SystemExit('invalid production Sparkle public key')
if len(key)!=32:raise SystemExit('Step 12 must install the real Sparkle public key before production signing')
PYKEY
    fi
    sign_one "$a" "$ROOT/App/Open.entitlements"
    codesign --verify --deep --strict --verbose=2 "$a"
    codesign -dvv "$a" 2> "$STAGE/signature.txt"
    grep -q runtime "$STAGE/signature.txt" || die 'signature lacks Hardened Runtime'
    if [[ $DRY == 1 ]]; then
        grep -q 'TeamIdentifier=not set' "$STAGE/signature.txt" || die 'dry-run unexpectedly has a Team ID'
        log 'Known dry-run limits: mock Keychain; Sparkle may refuse ad-hoc loading under Library Validation'
    else
        grep -q "TeamIdentifier=$TEAM" "$STAGE/signature.txt" || die 'app signature Team ID mismatch'
        python3 - "$a" "$TEAM" <<'PY'
from pathlib import Path
import subprocess,sys
app=Path(sys.argv[1]);team=sys.argv[2]
for f in sorted(app.rglob('*')):
 if f.suffix in ('.app','.framework','.xpc','.dylib') or f.name=='Autoupdate':
  p=subprocess.run(['codesign','-dv',str(f)],capture_output=True,text=True)
  if p.returncode or 'TeamIdentifier='+team not in p.stderr:raise SystemExit('nested Team ID mismatch: '+str(f))
print('All nested signatures use the selected Team ID')
PY
    fi
    for suffix in '' .gpu .renderer .plugin .alerts; do
        case "$suffix" in '') name='Open Helper' ;; .gpu) name='Open Helper (GPU)' ;; .renderer) name='Open Helper (Renderer)' ;; .plugin) name='Open Helper (Plugin)' ;; .alerts) name='Open Helper (Alerts)' ;; esac
        codesign -d --entitlements - "$frameworks/$name.app" > "$STAGE/helper${suffix:-.generic}.plist"
        python3 - "$STAGE/helper${suffix:-.generic}.plist" "$ROOT/Helper/Entitlements/helper$suffix.entitlements" <<'PY'
import plistlib,sys
from pathlib import Path
actual,expected=[plistlib.loads(Path(p).read_bytes()) for p in sys.argv[1:]]
if actual!=expected:raise SystemExit('helper entitlement seal differs from role file')
PY
    done
    output "$STAGE/signed" "$STAGE/signature.txt"
}
notarize() {
    local target=$1 label=$2 receipt="$REL/notary-$2.json" failed="$REL/notary-$2.rejected.sha256" hash submission status
    hash=$(digest "$target")
    # ZIP container metadata can change between attempts. Bind app rejection
    # protection to the unchanged signed app, rather than its transport ZIP.
    [[ "$label" != app ]] || hash=$(digest "$APP")
    # hdiutil image bytes are not reproducible. A rejected DMG stays blocked
    # until its stapled app, background or volume name changes.
    if [[ "$label" == dmg ]]; then
        hash=$(printf '%s\n%s\n%s\n' "$(digest "$APP")" "$(digest "$ROOT/assets/release/dmg-background.png")" "Open $VERSION" | shasum -a 256 | awk '{print $1}')
    fi
    if [[ -f "$failed" && $(cat "$failed") == "$hash" ]]; then die "unchanged $label was rejected previously; inspect saved log and fix it before resubmitting"; fi
    local submit_exit=0
    xcrun notarytool submit "$target" --keychain-profile open-notary --wait --output-format json > "$receipt" || submit_exit=$?
    submission=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("id",""))' "$receipt")
    status=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("status",""))' "$receipt")
    if [[ "$status" != Accepted ]]; then
        [[ -z "$submission" ]] || xcrun notarytool log "$submission" --keychain-profile open-notary > "$REL/notary-$label-log.json"
        printf '%s\n' "$hash" > "$failed"
        die "notary $label status=$status; inspect $receipt and saved log"
    fi
    [[ $submit_exit == 0 ]] || die "notary $label exited $submit_exit despite Accepted status; inspect $receipt"
    output "$receipt"
}
notarize_app() {
    if ! ready 07-sign; then mode_skip "$(reason 07-sign)"; return; fi
    rm -rf "$APP"
    ditto "$STAGE/signed/Open.app" "$APP"
    if [[ $DRY == 1 || $SKIP_NOTARY == 1 ]]; then
        log "SKIP notarization/stapling: $MODE (no notary credential used)"
    else
        # An unnotarized app must not be recorded as Gatekeeper-accepted.
        if spctl -a -vvv --type execute "$APP"; then die 'fresh pre-notarization app unexpectedly accepted; inspect its existing ticket'; fi
        ditto -c -k --keepParent "$APP" "$REL/Open-app-notarize.zip"
        notarize "$REL/Open-app-notarize.zip" app
        xcrun stapler staple "$APP"
        xcrun stapler validate "$APP"
        rm -f "$REL/Open-app-notarize.zip"
    fi
    codesign --verify --deep --strict "$APP"
    output "$APP"
}
size_check() {
    python3 - "$@" <<'PY'
from pathlib import Path
import subprocess,sys
for arg in sys.argv[1:]:
 p=Path(arg)
 size=int(subprocess.check_output(['du','-sk',str(p)]).split()[0])*1024 if p.is_dir() else p.stat().st_size
 mb=size/1_000_000
 print(f'{p.name}: {mb:.2f} MB ({size} bytes)')
 if mb>320:raise SystemExit('FAIL: size exceeds 320 MB hard limit')
 if mb>285:print('WARN: size exceeds 285 MB warning threshold')
 if mb>300:print('WARN: above the 300 MB target; within hard limit')
PY
}
dmg() {
    if ! ready 08-notarize-app; then mode_skip "$(reason 08-notarize-app)"; return; fi
    size_check "$APP"
    local staging="$REL/dmg-staging"
    rm -rf "$staging"
    mkdir -p "$staging/.background"
    ditto "$APP" "$staging/Open.app"
    ln -s /Applications "$staging/Applications"
    install -m 0644 "$ROOT/assets/release/dmg-background.png" "$staging/.background/background.png"
    log 'DMG background/icon layout: Open-owned placeholder; Finder geometry/positions are not configured in v1'
    hdiutil create -volname "Open $VERSION" -srcfolder "$staging" -ov -format UDZO "$DMG"
    if [[ $DRY == 1 || $SKIP_NOTARY == 1 ]]; then
        log "SKIP DMG notarization/stapling: $MODE"
    else
        notarize "$DMG" dmg
        xcrun stapler staple "$DMG"
        xcrun stapler validate "$DMG"
    fi
    hdiutil verify "$DMG"
    (cd "$REL" && shasum -a 256 "Open-$VERSION.dmg" > "Open-$VERSION.dmg.sha256" && shasum -a 256 -c "Open-$VERSION.dmg.sha256")
    { cat "$REL/release-notes.md"; printf '\nSHA-256: '; cat "$DMG.sha256"; } > "$REL/release-body.md"
    size_check "$APP" "$DMG" > "$STAGE/sizes.txt"
    cat "$STAGE/sizes.txt"
    output "$DMG" "$DMG.sha256" "$REL/release-body.md" "$STAGE/sizes.txt"
}
appcast() {
    if ! ready 09-dmg; then mode_skip "$(reason 09-dmg)"; return; fi
    if [[ $SKIP_NOTARY == 1 && $DRY == 0 ]]; then result mode-SKIP 'NOT-NOTARIZED internal mode: no production update signing or publication'; return; fi
    if [[ ! -x "$TOOLS/generate_appcast" || ! -x "$TOOLS/sign_update" ]]; then mode_skip "Step 7 Sparkle CLI tools unavailable at $TOOLS"; return; fi
    local archives="$STAGE/appcast" args=() previous previous_build
    rm -rf "$archives"
    mkdir -p "$archives"
    cp "$DMG" "$archives/"
    # HTML is generated from the exact note text, escaped rather than interpreted
    # as arbitrary HTML. Sparkle embeds this fragment; no public notes URL is needed.
    python3 - "$REL/release-notes.md" "$archives/Open-$VERSION.html" <<'PY'
import html,sys
from pathlib import Path
Path(sys.argv[2]).write_text('<pre>'+html.escape(Path(sys.argv[1]).read_text())+'</pre>\n')
PY
    if [[ -s "$STAGE/previous.txt" ]]; then
        previous_build=$(sed -n '1p' "$STAGE/previous.txt")
        previous=$(sed -n '2p' "$STAGE/previous.txt")
        cp "$previous" "$archives/"
        # Its item keeps its own immutable download URL; do not advertise the
        # predecessor under the new release's tag.
        if [[ -f "$(dirname "$previous")/$FEED" ]]; then cp "$(dirname "$previous")/$FEED" "$archives/$FEED"; fi
        log "Delta source: build $previous_build (same $CHANNEL channel)"
    else log 'No predecessor; full DMG only'; fi
    args=(--download-url-prefix "https://github.com/SergeSerb2/open/releases/download/$TAG/" --link https://sergeserb2.github.io/open/ --embed-release-notes --versions "$BUILD" -o "$archives/$FEED")
    [[ "$CHANNEL" != beta ]] || args+=(--channel beta)
    if [[ $DRY == 1 ]]; then
        KEY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/open-release-key.XXXXXX")
        chmod 700 "$KEY_DIR"
        # Upstream generate_keys always uses Keychain. A 32-byte Ed25519 seed
        # file is generate_appcast's supported no-Keychain input. Never print it.
        openssl rand -base64 32 > "$KEY_DIR/seed"
        chmod 600 "$KEY_DIR/seed"
        args+=(--ed-key-file "$KEY_DIR/seed")
    fi
    "$TOOLS/generate_appcast" "${args[@]}" "$archives"
    [[ -z "$KEY_DIR" ]] || { rm -rf "$KEY_DIR"; KEY_DIR=; }
    xmllint --noout "$archives/$FEED"
    python3 - "$archives/$FEED" "$BUILD" "$VERSION" "$CHANNEL" "$DMG" <<'PY'
import base64,sys,xml.etree.ElementTree as E
from pathlib import Path
feed,build,version,channel,dmg=sys.argv[1:];ns='{http://www.andymatuschak.org/xml-namespaces/sparkle}'
items=[i for i in E.parse(feed).iter('item') if i.findtext(ns+'version')==build]
if len(items)!=1:raise SystemExit('feed must contain exactly one current-build item')
i=items[0];e=i.find('enclosure')
if i.findtext(ns+'shortVersionString')!=version or i.findtext(ns+'minimumSystemVersion')!='26.0':raise SystemExit('feed version/system mismatch')
if (i.findtext(ns+'channel') or '')!=('beta' if channel=='beta' else ''):raise SystemExit('feed channel mismatch')
tag=f'v{version}-beta.{build}' if channel=='beta' else f'v{version}'
expected=f'https://github.com/SergeSerb2/open/releases/download/{tag}/Open-{version}.dmg'
if e is None or e.get('url')!=expected or e.get('length')!=str(Path(dmg).stat().st_size):raise SystemExit('feed enclosure URL/length mismatch')
for enclosure in i.iter('enclosure'):
 sig=enclosure.get(ns+'edSignature','')
 if len(base64.b64decode(sig,validate=True))!=64:raise SystemExit('missing/invalid EdDSA signature')
if not i.findtext('description') and not i.findtext(ns+'releaseNotesLink'):raise SystemExit('feed has no release notes')
print('Feed XML, build, marketing, minimum OS, channel, URL, length, signature fields and notes: PASS')
PY
    cp "$archives/$FEED" "$REL/$FEED"
    cp "$archives/Open-$VERSION.html" "$REL/Open-$VERSION.html"
    output "$REL/$FEED" "$REL/Open-$VERSION.html"
    local delta found=0
    for delta in "$archives/"*.delta; do
        [[ -f "$delta" ]] || continue
        cp "$delta" "$REL/"
        output "$REL/$(basename "$delta")"
        found=1
    done
    if [[ "$found" == 0 ]]; then log 'No delta generated; clients will use the full DMG'; fi
}
manifest() {
    python3 - "$REL" "$VERSION" "$BUILD" "$ENGINE_STAMP" "$MODE" "$CHANNEL" "$IDENTITY" "$TEAM" "$LOCALES" "$SPARKLE_PIN" "$STAMPS" <<'PY'
from pathlib import Path
import hashlib,json,sys
rel,version,build,engine,mode,channel,identity,team,locales,sparkle,stamps=sys.argv[1:];r=Path(rel)
lines=[f'marketing={version}',f'build={build}',f'engine={engine or "UNAVAILABLE (Step 6)"}',f'mode={mode}',f'channel={channel}',f'identity={"ad-hoc (dry run)" if mode=="dry-run" else identity}',f'team={team or "absent (ad-hoc)"}',f'locales={locales}',f'sparkle={sparkle or "UNAVAILABLE (Step 7)"}','notary_profile=open-notary','symbols=LOCAL ONLY - NEVER UPLOAD','dmg_background=Open-owned placeholder; Finder geometry/positions deferred']
if mode!='production':lines.append('notarization=SKIP: '+mode)
previous=r/'.staging/previous.txt';lines.append('previous_build='+((previous.read_text().splitlines() or ['no predecessor'])[0] if previous.exists() else 'unavailable'))
for p in sorted(Path(stamps).glob('*.result')):
 if p.stem!='12-summary':lines.append('phase_'+p.stem+'='+p.read_text().strip().replace('\t',': '))
for label in ['app','dmg']:
 p=r/('notary-'+label+'.json')
 if p.is_file():
  j=json.loads(p.read_text());lines.append('notary_'+label+'='+j.get('id','')+' '+j.get('status',''))
for pattern in ['Open-*.dmg','Open-*.dmg.sha256','*.delta','appcast*.xml','Acknowledgements.txt','CREDITS.html','release-notes.md','Open-*.html']:
 for p in sorted(r.glob(pattern)):
  h=hashlib.sha256()
  with p.open('rb') as f:
   for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
  lines.append(f'SHA256 {h.hexdigest()} {p.stat().st_size} {p.name}')
if (r/'Open.app').is_dir():
 # CodeDirectory hash binds code and resource seals; acceptance receipts must
 # additionally bind the DMG SHA, which represents the exact shipped bytes.
 import subprocess
 p=subprocess.run(['codesign','-dv',str(r/'Open.app')],capture_output=True,text=True)
 lines.extend('app_'+l for l in p.stderr.splitlines() if l.startswith(('CDHash=','TeamIdentifier=')))
(r/'RELEASE-MANIFEST.txt').write_text('\n'.join(lines)+'\n')
PY
    output "$REL/RELEASE-MANIFEST.txt"
}
# Exercise only the process launched here. CDP reads the real page; the saved
# BrowserModel snapshot proves the sidebar tab. Quit is an AppleEvent to its
# exact PID, with interaction forbidden, never a system UI action.
smoke() {
    local a=$1 evidence=$2
    if [[ ! -x "$STAGE/quit-pid" ]]; then
        cat > "$STAGE/quit-pid.m" <<'OBJC'
#import <Carbon/Carbon.h>
#include <stdlib.h>
int main(int argc,char **argv) {
 if(argc!=2)return 2;
 pid_t pid=(pid_t)strtol(argv[1],0,10);
 if(pid<=1)return 2;
 AEAddressDesc target={typeNull,NULL}; AppleEvent event={typeNull,NULL};
 OSStatus status=AECreateDesc(typeKernelProcessID,&pid,sizeof(pid),&target);
 if(!status)status=AECreateAppleEvent(kCoreEventClass,kAEQuitApplication,&target,kAutoGenerateReturnID,kAnyTransactionID,&event);
 if(!status)status=AESendMessage(&event,NULL,kAENoReply|kAENeverInteract,kAEDefaultTimeout);
 AEDisposeDesc(&event);AEDisposeDesc(&target);
 return status?1:0;
}
OBJC
        clang -framework Carbon "$STAGE/quit-pid.m" -o "$STAGE/quit-pid"
    fi
    python3 - "$a" "$evidence" "$STAGE/quit-pid" <<'PY'
from pathlib import Path
import json,os,socket,subprocess,sys,tempfile,time,urllib.request
app,evidence,quit_tool=sys.argv[1:];e=Path(evidence);e.parent.mkdir(parents=True,exist_ok=True)
data=Path(tempfile.mkdtemp(prefix='smoke-',dir=e.parent)).resolve()
with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
result={}
with e.with_suffix('.log').open('w') as log:
 proc=subprocess.Popen([str(Path(app)/'Contents/MacOS/Open'),'--user-data-dir='+str(data),'--open-remote-debugging-port='+str(port),'https://example.com'],env=dict(os.environ,OPEN_USER_DATA=str(data)),stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
 try:
  deadline=time.monotonic()+60
  while time.monotonic()<deadline:
   if proc.poll() is not None:raise RuntimeError('app exited during launch')
   try:
    with urllib.request.urlopen(f'http://127.0.0.1:{port}/json/list',timeout=2) as response:targets=json.load(response)
    if any(t.get('title')=='Example Domain' and t.get('url','').startswith('https://example.com') for t in targets):break
   except (OSError,ValueError):pass
   time.sleep(.25)
  else:raise RuntimeError('example.com title did not arrive')
  result['page_title']='Example Domain'
  lines=subprocess.check_output(['ps','-axo','pid=,ppid=,command='],text=True).splitlines();children=set([proc.pid]);commands=[]
  rows=[line.strip().split(None,2) for line in lines]
  for _ in range(8):
   for row in rows:
    if len(row)==3 and int(row[1]) in children:children.add(int(row[0]))
  commands=[row[2] for row in rows if len(row)==3 and int(row[0]) in children]
  result['renderer']=any('Open Helper' in c and '--type=renderer' in c for c in commands)
  result['gpu']=any('Open Helper' in c and '--type=gpu-process' in c for c in commands)
  if not result['renderer'] or not result['gpu']:raise RuntimeError('renderer/GPU descendants missing')
  subprocess.run([quit_tool,str(proc.pid)],check=True)
  if proc.wait(timeout=20)!=0:raise RuntimeError('app did not quit cleanly')
  state=json.loads((data/'State/browser.json').read_text())
  def tab(x):
   if isinstance(x,dict):
    if x.get('title')=='Example Domain' and str(x.get('url','')).startswith('https://example.com'):return True
    return any(tab(v) for v in x.values())
   return isinstance(x,list) and any(tab(v) for v in x)
  result['sidebar_tab']=tab(state)
  if not result['sidebar_tab']:raise RuntimeError('saved sidebar lacks the loaded Example Domain tab')
  result['clean_quit']=True
 finally:
  if proc.poll() is None:
   proc.terminate()
   try:proc.wait(timeout=10)
   except subprocess.TimeoutExpired:proc.kill();proc.wait()
e.write_text(json.dumps(result,indent=2)+'\n');print(e.read_text())
PY
}
summary() {
    : > "$STAGE/acceptance.tsv"
    if ready 02-engine; then row A-1 PASS 'official args, matching distrib binary/commits, engine-status --strict'; else row A-1 mode-SKIP "$(reason 02-engine)"; fi
    if ready 09-dmg; then
        # Always repeat runtime checks for a new final artifact, never infer them
        # from a build or a signature. Successful receipts are bound to the DMG.
        local artifact_hash runtime_hash=
        artifact_hash=$(shasum -a 256 "$DMG" | awk '{print $1}')
        [[ ! -f "$STAGE/runtime.sha256" ]] || runtime_hash=$(cat "$STAGE/runtime.sha256")
        if [[ "$runtime_hash" != "$artifact_hash" ]]; then
            smoke "$APP" "$STAGE/launch.json"
            MOUNT_DIR=$(mktemp -d "$STAGE/mount.XXXXXX")
            hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$DMG"
            smoke "$MOUNT_DIR/Open.app" "$STAGE/mounted-launch.json"
            hdiutil detach "$MOUNT_DIR"
            rmdir "$MOUNT_DIR"; MOUNT_DIR=
            printf '%s\n' "$artifact_hash" > "$STAGE/runtime.sha256"
        fi
        row A-2 PASS 'real page title + saved sidebar tab; PID-targeted clean quit'
        row A-3 PASS 'renderer and GPU descendants of this launched PID'
        codesign --verify --deep --strict "$APP"
        row A-4 PASS "inside-out signatures verified ($MODE)"
        if [[ $DRY == 1 || $SKIP_NOTARY == 1 ]]; then
            row A-5 mode-SKIP "$MODE: no Gatekeeper acceptance claimed"
            row A-6 mode-SKIP "$MODE: no notary ticket"
        else
            if spctl -a -vvv --type execute "$APP" && spctl -a -vvv --type open --context context:primary-signature "$DMG"; then row A-5 PASS 'app + DMG accepted'; else row A-5 FAIL 'Gatekeeper rejected app or DMG'; fi
            if xcrun stapler validate "$APP" && xcrun stapler validate "$DMG"; then row A-6 PASS 'app + DMG tickets validated'; else row A-6 FAIL 'staple validation failed'; fi
        fi
        size_check "$APP" "$DMG"
        row A-7 PASS 'within hard size limit; warning/target lines recorded'
        bundle_check "$APP"
        row A-8 PASS "exact locale set: $LOCALES"
        row A-9 PASS 'no dSYMs in app'
        row A-10 PASS 'no automation socket string or compilation flag'
        row A-11 PASS 'read-only DMG mount; actual mounted app launched and quit; detached'
    else
        local id
        for id in A-2 A-3 A-4 A-7 A-8 A-9 A-10 A-11; do row "$id" mode-SKIP "$(reason 09-dmg)"; done
        row A-5 mode-SKIP "$MODE; no notarized app/DMG available"
        row A-6 mode-SKIP "$MODE; no notarized app/DMG available"
    fi
    if ready 10-appcast; then
        local feed_status=PASS feed_evidence='XML and current item fields verified; dry-run URLs are not publication evidence'
        if [[ $DRY == 0 && $SKIP_NOTARY == 0 ]]; then
            local url="https://github.com/SergeSerb2/open/releases/download/$TAG/Open-$VERSION.dmg"
            if ! curl -fsIL --connect-timeout 5 --max-time 20 "$url" >/dev/null; then
                feed_status=FAIL
                feed_evidence='post-publication enclosure URL is not yet reachable; assets must precede feed'
            fi
        fi
        replace_row A-12 "$feed_status" "$feed_evidence"
    else replace_row A-12 mode-SKIP "$(reason 10-appcast)"; fi
    if [[ $DRY == 1 || $SKIP_NOTARY == 1 ]]; then
        row A-13 mode-SKIP "$MODE; no real-update claim"
    else
        row A-13 FAIL 'real predecessor update needs a receipt bound to the final DMG'
    fi
    if ready 04-acknowledgements && ready 09-dmg; then
        # Native About UI and real update evidence cannot be inferred from text
        # files. The lead records manual/API verification, bound to these bits.
        local receipt="$REL/acceptance.json"
        if [[ -f "$receipt" ]] && python3 - "$receipt" "$DMG" about <<'PY'
import hashlib,json,sys
from pathlib import Path
p,dmg,kind=sys.argv[1:];j=json.loads(Path(p).read_text())
h=hashlib.sha256(Path(dmg).read_bytes()).hexdigest()
if j.get('dmg_sha256')!=h or j.get(kind) is not True or not j.get('evidence'):raise SystemExit(1)
PY
        then row A-14 PASS 'lead About-rendering receipt bound to final DMG'; else
            row A-14 FAIL "verify About version/build, stamp and Credits rows, then record {dmg_sha256, about:true, evidence:<path>} in $receipt"
        fi
        if [[ $DRY == 0 && $SKIP_NOTARY == 0 && -f "$receipt" ]]; then
            local update_result
            update_result=$(python3 - "$receipt" "$DMG" <<'PY'
import hashlib,json,sys
from pathlib import Path
j=json.loads(Path(sys.argv[1]).read_text());h=hashlib.sha256(Path(sys.argv[2]).read_bytes()).hexdigest()
if j.get('dmg_sha256')==h and j.get('evidence'):
 if j.get('real_update') is True:print('updated')
 elif j.get('no_predecessor') is True:print('first release')
PY
)
            if [[ -n "$update_result" ]]; then
                # Replace the pending row only after exact-artifact evidence.
                if [[ "$update_result" == updated ]]; then replace_row A-13 PASS 'lead real-update receipt bound to final DMG'; else replace_row A-13 mode-SKIP 'first release: lead recorded no shipped predecessor, with evidence bound to final DMG'; fi
            fi
        fi
    else row A-14 mode-SKIP "$(reason 04-acknowledgements); app unavailable pending Steps 2/4–8/10"; fi
    python3 - "$REL" <<'PY'
from pathlib import Path
import re,subprocess,sys
r=Path(sys.argv[1])
tracked=subprocess.check_output(['git','ls-files','--',str(r)],text=True)
if tracked.strip():raise SystemExit('release artifacts must remain ignored')
for p in r.rglob('*'):
 if not p.is_file() or p.is_symlink():continue
 if p.suffix in ('.key','.p12','.p8') or p.name in ('seed','private-key','private-key.txt'):raise SystemExit('unexpected private-key file in outputs: '+str(p))
 if p.stat().st_size<2_000_000 and re.search(rb'-----BEGIN (?:ENCRYPTED |EC |RSA |OPENSSH )?PRIVATE KEY-----',p.read_bytes()):raise SystemExit('private key in outputs: '+str(p))
print('Ignored outputs; no private key files or PEM private keys: PASS')
PY
    row A-15 PASS 'outputs ignored; no private-key files/PEM; no temporary seed retained'
    print_acceptance_table
    if [[ $DRY == 0 && $SKIP_NOTARY == 0 && -f "$DMG" && -f "$REL/$FEED" ]]; then
        log 'PREPARED ONLY. Publish needs explicit user approval. Assets first; feed last. Never upload symbols/. Replace tag for beta as shown.'
        local tag="v$VERSION" asset
        [[ "$CHANNEL" != beta ]] || tag="v$VERSION-beta.$BUILD"
        printf 'git tag -a %q -m %q\n' "$tag" "Open $VERSION ($BUILD) · $ENGINE_STAMP"
        printf 'git push origin %q\n' "$tag"
        printf 'gh release create %q --verify-tag --title %q --notes-file %q' "$tag" "Open $VERSION" "$REL/release-body.md"
        [[ "$CHANNEL" != beta ]] || printf ' --prerelease'
        for asset in "$DMG" "$DMG.sha256" "$REL/"*.delta "$REL/Acknowledgements.txt" "$REL/CREDITS.html"; do [[ ! -f "$asset" ]] || printf ' %q' "$asset"; done
        printf '\n'
        log 'After the approved asset upload, publish the feed last. U-8 must first confirm the public hosting target for origin and these URLs.'
        local pages="$REL/gh-pages-publish"
        printf 'git -C %q fetch origin\n' "$ROOT"
        printf 'if git -C %q show-ref --verify --quiet refs/remotes/origin/gh-pages; then\n' "$ROOT"
        printf '  git -C %q worktree add --detach %q origin/gh-pages\n' "$ROOT" "$pages"
        printf 'else\n'
        printf '  git -C %q worktree add --detach %q HEAD\n' "$ROOT" "$pages"
        printf '  git -C %q switch --orphan %q\n' "$pages" "open-feed-$VERSION-$BUILD"
        printf 'fi\n'
        printf 'cp %q %q\n' "$REL/$FEED" "$pages/$FEED"
        printf 'mkdir -p %q\n' "$pages/release-notes"
        printf 'cp %q %q\n' "$REL/Open-$VERSION.html" "$pages/release-notes/$VERSION.html"
        printf 'git -C %q add -- %q %q\n' "$pages" "$FEED" "release-notes/$VERSION.html"
        printf 'git -C %q commit -m %q\n' "$pages" "Publish Open $VERSION ($BUILD) $CHANNEL feed"
        printf 'git -C %q push origin HEAD:gh-pages\n' "$pages"
        printf 'git -C %q worktree remove %q\n' "$ROOT" "$pages"
        printf 'curl -fsI %q\n' "https://sergeserb2.github.io/open/$FEED"
        log 'Verify enclosure URLs and the real update before announcing. No upload, worktree, commit or tag is run here.'
        log 'release-body.md includes the post-stapling DMG SHA-256; review it before the approved upload.'
    else log "$MODE: local preparation only; no publish commands or trust-root operations"; fi
    if grep -q $'\tFAIL\t' "$STAGE/acceptance.tsv"; then
        result FAIL 'acceptance incomplete; inspect table and provide real evidence before release'
    else result PASS 'all applicable checks pass; mode-SKIP rows are explicitly bounded'; fi
    output "$STAGE/acceptance.tsv"
}
run_phase 01-preflight preflight
run_phase 02-engine engine
prepare_notes_inputs
run_phase 03-version-notes notes "$(digest "$STAGE/notes-live-inputs.json")"
run_phase 04-acknowledgements acknowledgements
run_phase 05-app-build app_build
run_phase 06-hygiene hygiene
run_phase 07-sign sign_app
run_phase 08-notarize-app notarize_app
run_phase 09-dmg dmg
run_phase 10-appcast appcast
run_phase 11-manifest manifest
# Receipts and external publication can change after staging. Production always
# refreshes acceptance; dry runs can reuse its artifact- and receipt-bound stamp.
if [[ $DRY == 0 ]]; then rm -f "$STAMPS/12-summary.stamp"; fi
CHAIN=$(printf '%s\n%s\n' "$CHAIN" "$(digest "$REL/acceptance.json")" | shasum -a 256 | awk '{print $1}')
run_phase 12-summary summary
if [[ $(cut -f1 "$STAMPS/12-summary.result") == FAIL ]]; then die 'acceptance table has FAIL rows; no release acceptance claimed'; fi
if [[ $DRY == 1 && -f "$STAGE/acceptance.tsv" ]]; then
    log 'Dry-run result does not establish official-engine, notarization, production signing, publication or update acceptance for skipped rows.'
fi
