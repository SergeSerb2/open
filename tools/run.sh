#!/usr/bin/env bash
# Run the built Open.app in the foreground with logs on stderr.
#
#   tools/run.sh [Debug|Release] [-- extra Open/Chromium switches]
#
# The profile lives in $OPEN_USER_DATA (default: ~/Library/Application Support/Open-Dev).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="Debug"
if [[ "${1:-}" == "Debug" || "${1:-}" == "Release" ]]; then CONFIG="$1"; shift; fi
[[ "${1:-}" == "--" ]] && shift
APP="$ROOT/build/$CONFIG/Open.app"
if [[ ! -d "$APP" ]]; then "$ROOT/tools/build.sh" "$CONFIG"; fi
exec "$APP/Contents/MacOS/Open" "$@"
