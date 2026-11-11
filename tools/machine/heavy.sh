#!/bin/bash
# heavy.sh CMD [ARGS...] — this machine's BUILD slots, first come first served.
#
# Slots: the number in ~/Library/Caches/OpenRE/heavy-slots (1..6, default 1).
# A normal job (build, gate) takes ONE slot, so up to that many run together.
# An EXCLUSIVE job takes EVERY slot, so nothing else builds while it runs:
#   - OPEN_HEAVY_EXCLUSIVE=1 heavy.sh CMD          (measurements, timing rows)
#   - heavy.sh /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock CMD   (the strict-timing form)
#   - anything started from the performance worktree (perf-arc-vs-open, tools/perf)
# Order is strict FIFO: a waiting exclusive job is never overtaken.
# Nested calls run inside the outer slot. See the queue with queue.sh.
PFX="${OPEN_HEAVY_PREFIX:-/tmp/open-heavy}"
[ $# -gt 0 ] || { echo "usage: heavy.sh CMD [ARGS...]" >&2; exit 64; }

# The M5 gate dispatches bounded stage tickets itself. Do this before taking
# a slot: retaining an outer ticket would prevent FIFO waiters interleaving.
# The worker marker goes back through this script and takes a real slot.
if [ "${OPEN_VERIFY_CHUNK_WORKER:-}" != 1 ]; then
  case "$1" in tools/verify-all.sh|./tools/verify-all.sh|/*/tools/verify-all.sh)
    gate_root=$(cd "$(dirname "$1")/.." && pwd) || exit 1
    case "$(/usr/sbin/sysctl -n machdep.cpu.brand_string 2>/dev/null)" in
      'Apple M5'*)
        if [ -f "$gate_root/tools/verification/queue_gate.py" ]; then
          shift
          exec python3 "$gate_root/tools/verification/queue_gate.py" "$@"
        fi ;;
    esac ;;
  esac
fi

# Already inside a slot? Match an executed heavy.sh, not an argument that mentions it.
p=$PPID
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null || break
  c=$(ps -o command= -p "$p" 2>/dev/null)
  read -r executable script remainder <<< "$c"
  case "${executable##*/}:${script##*/}" in
    heavy.sh:*|bash:heavy.sh|sh:heavy.sh|zsh:heavy.sh) exec "$@" ;;
  esac
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
done

N="${OPEN_HEAVY_SLOTS:-$(cat "$HOME/Library/Caches/OpenRE/heavy-slots" 2>/dev/null)}"
case "$N" in 1|2|3|4|5|6) ;; *) N=1 ;; esac
want=1
[ "$OPEN_HEAVY_EXCLUSIVE" = 1 ] && want=$N
case "${1##*/}" in lockf)   # the strict-timing form, with any lockf options before the lock file
  i=0; for a in "$@"; do i=$((i + 1)); [ "$i" -gt 6 ] && break
    [ "$a" = /tmp/open-onscreen-e2e.lock ] && want=$N; done ;;
esac
case "$PWD $*" in *perf-arc-vs-open*|*tools/perf/*) want=$N ;; esac
kind=build; [ "$want" = "$N" ] && [ "$N" -gt 1 ] && kind=exclusive

Q="$PFX-queue"; HD="$PFX-holders"; mkdir -p "$Q" "$HD"
T="$Q/$(date +%s)-$(printf '%07d' $$)"
# Queue/holder records have exactly one line per PID. Preserve the actual
# argument vector below; flatten only the human-readable command and cwd.
# A literal newline in python -c must not make stale-ticket cleanup delete
# a live ticket after cut -f1 reads several lines as its PID.
display_command=$(printf '%s' "$*" | tr '\n\r\t' '   ')
display_directory=$(printf '%s' "$PWD" | tr '\n\r\t' '   ')
line=$(printf '%s\t%s\t%s\t%s' "$$" "$(date '+%H:%M:%S')" "$display_directory" "$display_command")
printf '%s\n' "$line" > "$T"

# The old single-holder file stays as "all holders, one per line" for tools that read it.
sync_legacy() {
  local tmp="$PFX-holder.tmp.$$" any=0 f fp
  : > "$tmp"
  for f in "$HD"/*; do
    [ -e "$f" ] || continue
    fp=${f##*/}
    if kill -0 "$fp" 2>/dev/null; then cat "$f" >> "$tmp"; any=1; else rm -f "$f"; fi
  done
  if [ "$any" = 1 ]; then mv -f "$tmp" "$PFX-holder"; else rm -f "$tmp" "$PFX-holder"; fi
}
cleanup() { rm -f "$T" "$HD/$$"; sync_legacy; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

held=""
release() { local fd; for fd in $held; do eval "exec $fd>&-"; done; held=""; }
try() {
  local k fd n=0
  held=""
  for k in $(seq 1 "$N"); do
    fd=$((2 + k))
    eval "exec $fd>>\"\$PFX-$k.lock\""
    if /usr/bin/lockf -s -t 0 "$fd" 2>/dev/null; then
      held="$held $fd"; n=$((n + 1)); [ "$n" -ge "$want" ] && return 0
    else
      eval "exec $fd>&-"
    fi
  done
  release; return 1
}

waited=0
while :; do
  for f in "$Q"/*; do
    [ -e "$f" ] || continue
    fp=$(cut -f1 "$f" 2>/dev/null)
    { [ -n "$fp" ] && kill -0 "$fp" 2>/dev/null; } || rm -f "$f"
  done
  first=$(ls "$Q" 2>/dev/null | sort | head -1)
  if [ "$Q/$first" = "$T" ] && try; then
    printf '%s\t%s\n' "$line" "$kind" > "$HD/$$"
    sync_legacy
    rm -f "$T"
    [ "$waited" -gt 0 ] && echo "heavy.sh: got ${want} of ${N} build slot(s) after ${waited}s" >&2
    close=""; for fd in $held; do close="$close $fd>&-"; done
    eval "OPEN_HEAVY_HELD=1 OPEN_HEAVY_KIND=$kind \"\$@\" $close"
    exit $?
  fi
  sleep 2; waited=$((waited + 2))
done
