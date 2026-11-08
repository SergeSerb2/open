#!/bin/bash
# Bash 3.2 wrapper. Builds and the caller's quiet lock belong outside this script.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT/tools/verification/budgets.py" "$@"
