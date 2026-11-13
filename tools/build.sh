#!/usr/bin/env bash
# Generate the Xcode project and build Open.app.
#
#   tools/build.sh                 # Debug (automation socket compiled in)
#   tools/build.sh Release         # Release
#   OPEN_AUTOMATION=1 tools/build.sh Release        # Release + automation socket
#   OPEN_KEEP_LOCALES="en" tools/build.sh Release   # ship only these CEF locales
#   CEF_SOURCE=cdn tools/build.sh Release           # stock CEF instead of our fork (comparisons)
#   OPEN_BUILD_DIR=build/shipping tools/build.sh Release   # separate output and DerivedData
#
# Output: build/<Config>/Open.app (or $OPEN_BUILD_DIR/<Config>/Open.app). Builds run at low priority with at most
# $OPEN_BUILD_JOBS (default 6) parallel jobs, so the machine stays responsive.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-Debug}"
JOBS="${OPEN_BUILD_JOBS:-6}"
OUT="${OPEN_BUILD_DIR:-$ROOT/build}"
[[ "$OUT" == /* ]] || OUT="$ROOT/$OUT"
export PATH="/opt/homebrew/bin:$PATH"

# Idempotent: exits at once when Vendor/cef/ holds the selected engine.
"$ROOT/tools/fetch-cef.sh"
"$ROOT/tools/fetch-adblock-lists.sh"

cd "$ROOT"
xcodegen generate --quiet --spec project.yml

extra=()
conditions=()
if [[ "$CONFIG" == "Debug" ]]; then
  conditions+=(DEBUG OPEN_AUTOMATION)
elif [[ "${OPEN_AUTOMATION:-}" == "1" ]]; then
  conditions+=(OPEN_AUTOMATION)
fi
# The shell compiles the new API only with its public marker and a matching
# adopted distribution. A newer repository header alone is not sufficient.
transfer=$(python3 - "$ROOT" <<'PY'
import hashlib, json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
public = root / 'Engine/OpenEngine/include/OpenEngine/OEBrowser.h'
vendor = root / 'Vendor/cef'
header = vendor / 'include/cef_tab_strip.h'
enabled = re.search(r'^\s*#define\s+OE_HAS_WEB_CONTENT_TRANSFER\s+1\s*$', public.read_text(), re.M)
if enabled and header.is_file() and 'virtual bool TransferTab(' in header.read_text():
    binary = vendor / 'Release/Chromium Embedded Framework.framework/Chromium Embedded Framework'
    expected = json.loads((root / 'Engine/fork/official-distrib.json').read_text())['framework_sha256']
    digest = hashlib.sha256()
    with binary.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    enabled = digest.hexdigest() == expected
else:
    enabled = False
print('1' if enabled else '0')
PY
)
if [[ "$transfer" == "1" ]]; then
  conditions+=(OPEN_ENGINE_WEB_CONTENT_TRANSFER)
fi
if [[ ${#conditions[@]} -gt 0 ]]; then
  extra+=("SWIFT_ACTIVE_COMPILATION_CONDITIONS=${conditions[*]}")
fi

LOG="$OUT/xcodebuild-$CONFIG.log"
mkdir -p "$OUT"
status=0
nice -n 10 xcodebuild \
  -project Open.xcodeproj \
  -scheme Open \
  -configuration "$CONFIG" \
  -derivedDataPath "$OUT/DerivedData" \
  -destination "platform=macOS,arch=arm64" \
  -jobs "$JOBS" \
  -skipPackagePluginValidation \
  SYMROOT="$OUT" \
  OPEN_KEEP_LOCALES="${OPEN_KEEP_LOCALES:-}" \
  ${extra[@]+"${extra[@]}"} \
  build >"$LOG" 2>&1 || status=$?

grep -E "error:|warning: .*(OpenEngine|App/)|\*\* BUILD" "$LOG" | sort -u | head -60 || true
if [[ $status -ne 0 ]]; then
  echo "Build failed (exit $status). Full log: $LOG" >&2
  exit $status
fi
echo "Built: $OUT/$CONFIG/Open.app"
