#!/bin/bash
# Private inputs remain in .re; all outputs default to a private temp directory.
set -euo pipefail
exec python3 "$(dirname "$0")/sidebar-compare-states.py" "$@"
