#!/usr/bin/env bash
# Generate the Xcode project and build Open.app.
#
#   tools/build.sh                 # Debug (automation socket compiled in)
#   tools/build.sh Release         # Release
#   OPEN_AUTOMATION=1 tools/build.sh Release   # Release + automation socket
#   OPEN_KEEP_LOCALES="en" tools/build.sh Release   # strip CEF locales
#
# Output: build/<Config>/Open.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-Debug}"
export PATH="/opt/homebrew/bin:$PATH"

if [[ ! -e "$ROOT/Vendor/cef/current/build/libcef_dll_wrapper/libcef_dll_wrapper.a" ]]; then
  "$ROOT/tools/fetch-cef.sh"
fi

cd "$ROOT"
xcodegen generate --quiet --spec project.yml

extra=()
if [[ "${OPEN_AUTOMATION:-}" == "1" && "$CONFIG" != "Debug" ]]; then
  extra+=("SWIFT_ACTIVE_COMPILATION_CONDITIONS=OPEN_AUTOMATION")
fi

LOG="$ROOT/build/xcodebuild-$CONFIG.log"
mkdir -p "$ROOT/build"
status=0
xcodebuild \
  -project Open.xcodeproj \
  -scheme Open \
  -configuration "$CONFIG" \
  -derivedDataPath "$ROOT/build/DerivedData" \
  -destination "platform=macOS,arch=arm64" \
  SYMROOT="$ROOT/build" \
  OPEN_KEEP_LOCALES="${OPEN_KEEP_LOCALES:-}" \
  ${extra[@]+"${extra[@]}"} \
  build >"$LOG" 2>&1 || status=$?

grep -E "error:|\*\* BUILD" "$LOG" | sort -u | head -50 || true
if [[ $status -ne 0 ]]; then
  echo "Build failed (exit $status). Full log: $LOG" >&2
  exit $status
fi
echo "Built: $ROOT/build/$CONFIG/Open.app"
