#!/bin/bash
# One measured run. Lock order: quiet -> heavy -> on-screen. No builds here.
set -euo pipefail
export OPEN_ENGINE_ROOT="$HOME/Developer/open-engine-s8-main"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
priority_is_fresh() {
  [[ -f /tmp/open-onscreen-priority ]] && \
    [[ $(( $(date +%s) - $(stat -f %m /tmp/open-onscreen-priority) )) -lt 1800 ]]
}
if [[ "${1:-}" == --screen ]]; then
  shift
  # A new priority request may arrive while lockf waits. Release immediately;
  # never wait for the marker while holding the screen lock.
  if priority_is_fresh; then
    echo 'Priority marker arrived while waiting for screen; no App launched.' >&2
    exit 76
  fi
  exec python3 "$ROOT/tools/verification/window-material-perf.py" "$@"
fi
if [[ "${1:-}" != --locked ]]; then
  exec /usr/bin/lockf -k /tmp/open-m5-quiet.lock \
    "$HOME/Library/Caches/OpenRE/scripts/heavy.sh" /bin/bash "$0" --locked "$@"
fi
shift
# Wait outside the screen lock. The preference for load <=12 is bounded; busy
# receipts are still useful but cannot establish a quiet-machine acceptance.
for attempt in $(seq 1 24); do
  if python3 -c 'import os,sys;sys.exit(os.getloadavg()[0]>12)'; then break; fi
  sleep 5
done
while priority_is_fresh; do
  sleep 5
done
exec /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock \
  /bin/bash "$0" --screen "$@"
