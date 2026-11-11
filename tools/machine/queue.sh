#!/bin/bash
# queue.sh — show this machine's build slots, build queue, screen lock holder and waiters, and load.
PFX="${OPEN_HEAVY_PREFIX:-/tmp/open-heavy}"
N=$(cat "$HOME/Library/Caches/OpenRE/heavy-slots" 2>/dev/null); case "$N" in 1|2|3|4|5|6) ;; *) N=1 ;; esac
echo "machine: $(scutil --get ComputerName 2>/dev/null)   load: $(sysctl -n vm.loadavg)   cores: $(sysctl -n hw.ncpu)"
echo "BUILD slots (heavy.sh): $N. A normal job takes one; an exclusive job (measurement, strict timing) takes all."
h=0
for f in "$PFX-holders"/*; do
  [ -e "$f" ] || continue
  kill -0 "${f##*/}" 2>/dev/null || continue
  h=$((h+1)); awk -F'\t' '{printf "  running since %s  pid %s  [%s]  %s\n    %s\n", $2, $1, $NF, $3, substr($4,1,150)}' "$f"
done
if [ "$h" = 0 ] && [ -s "$PFX-holder" ] && kill -0 "$(head -1 "$PFX-holder" | cut -f1)" 2>/dev/null; then
  h=1; awk -F'\t' '{printf "  running since %s  pid %s  [old script: all slots]  %s\n    %s\n", $2, $1, $3, substr($4,1,150)}' "$PFX-holder"
fi
[ "$h" = 0 ] && echo "  free"
n=0; for f in $(ls "$PFX-queue" 2>/dev/null | sort); do n=$((n+1)); awk -F'\t' -v n=$n '{printf "  %d. waiting since %s  pid %s  %s\n     %s\n", n, $2, $1, $3, substr($4,1,150)}' "$PFX-queue/$f"; done
[ "$n" = 0 ] && echo "  queue: empty"
echo "SCREEN lock (/tmp/open-onscreen-e2e.lock): one job at a time; all holders/waiters:"
pgrep -fl 'lockf .*open-onscreen-e2e.lock' | cut -c1-190 | sed 's/^/  /'
[ -z "$(pgrep -f 'lockf .*open-onscreen-e2e.lock')" ] && echo "  free"
