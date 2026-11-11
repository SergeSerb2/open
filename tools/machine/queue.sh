#!/bin/bash
# queue.sh — show this machine's build slot, build queue, screen lock holder and waiters, and load.
PFX="${OPEN_HEAVY_PREFIX:-/tmp/open-heavy}"
echo "machine: $(scutil --get ComputerName 2>/dev/null)   load: $(sysctl -n vm.loadavg)   cores: $(sysctl -n hw.ncpu)"
echo "BUILD slot (heavy.sh):"
if [ -s "$PFX-holder" ] && kill -0 "$(cut -f1 "$PFX-holder")" 2>/dev/null; then
  awk -F'\t' '{printf "  running since %s  pid %s  %s\n    %s\n", $2, $1, $3, substr($4,1,150)}' "$PFX-holder"
else echo "  free (or held by an old-style caller: $(pgrep -f 'heavy.sh ' | wc -l | tr -d ' ') heavy.sh processes alive)"; fi
n=0; for f in $(ls "$PFX-queue" 2>/dev/null | sort); do n=$((n+1)); awk -F'\t' -v n=$n '{printf "  %d. waiting since %s  pid %s  %s\n     %s\n", n, $2, $1, $3, substr($4,1,150)}' "$PFX-queue/$f"; done
[ "$n" = 0 ] && echo "  queue: empty"
echo "SCREEN lock (/tmp/open-onscreen-e2e.lock), holder first is not guaranteed; all holders/waiters:"
pgrep -fl 'lockf .*open-onscreen-e2e.lock' | cut -c1-190 | sed 's/^/  /'
[ -z "$(pgrep -f 'lockf .*open-onscreen-e2e.lock')" ] && echo "  free"
