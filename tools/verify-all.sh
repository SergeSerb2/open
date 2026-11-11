#!/bin/bash
# The caller holds the machine's FIFO build slot; each screen stage takes its own lock.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec python3 "$ROOT/tools/verification/gate.py" "$@"
