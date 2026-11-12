#!/usr/bin/env bash
# Generate the Xcode project and build Open.app.
#
#   tools/build.sh                 # Debug (automation socket compiled in)
#   tools/build.sh Release         # Release
#   OPEN_AUTOMATION=1 tools/build.sh Release        # Release + automation socket
#   OPEN_KEEP_LOCALES="en" tools/build.sh Release   # ship only these CEF locales
#   CEF_SOURCE=cdn tools/build.sh Release           # stock CEF instead of our fork (comparisons)
#   OPEN_BUILD_ROOT=build/shipping OPEN_AUTOMATION=0 tools/build.sh Release   # separate output (gate shipping check)
#
# Output: build/<Config>/Open.app. Builds run at low priority with at most
# $OPEN_BUILD_JOBS (default 6) parallel jobs, so the machine stays responsive.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-Debug}"
JOBS="${OPEN_BUILD_JOBS:-6}"
export PATH="/opt/homebrew/bin:$PATH"

# Idempotent: exits at once when Vendor/cef/ holds the selected engine.
"$ROOT/tools/fetch-cef.sh"
"$ROOT/tools/fetch-adblock-lists.sh"

cd "$ROOT"
xcodegen generate --quiet --spec project.yml

extra=()
if [[ "${OPEN_AUTOMATION:-}" == "1" && "$CONFIG" != "Debug" ]]; then
  extra+=("SWIFT_ACTIVE_COMPILATION_CONDITIONS=OPEN_AUTOMATION")
fi

# A separate root keeps a second configuration (for example the gate's shipping build) from
# overwriting build/<Config>/Open.app or flip-flopping the shared intermediates.
OUT="${OPEN_BUILD_ROOT:-$ROOT/build}"
[[ "$OUT" = /* ]] || OUT="$ROOT/$OUT"
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
