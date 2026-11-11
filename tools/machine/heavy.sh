#!/bin/bash
# heavy.sh CMD [ARGS...] — this machine's single BUILD slot, first come first served.
# Use it for tools/verify-all.sh, tools/build.sh, swift build, xcodebuild, and for any strict
# performance measurement that needs a quiet machine. Exactly one such job runs per machine.
# Waits its turn, runs CMD, exits with CMD's exit code. See the queue with queue.sh.
# Nested calls (CMD itself calls heavy.sh) run at once inside the outer slot.
PFX="${OPEN_HEAVY_PREFIX:-/tmp/open-heavy}"
QUIET="${OPEN_QUIET_LOCK:-/tmp/open-m5-quiet.lock}"
[ $# -gt 0 ] || { echo "usage: heavy.sh CMD [ARGS...]" >&2; exit 64; }

# Already inside a slot (new or old heavy.sh), or inside a job that holds the quiet lock?
inside=0; have_quiet=0
p=$PPID
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null || break
  c=$(ps -o command= -p "$p" 2>/dev/null)
  # Match the executed script, not a launcher argument mentioning heavy.sh.
  read -r executable script remainder <<< "$c"
  case "${executable##*/}:${script##*/}" in
    heavy.sh:*|bash:heavy.sh|sh:heavy.sh|zsh:heavy.sh) inside=1 ;;
  esac
  case "$c" in *"$QUIET"*) have_quiet=1 ;; esac
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
done
[ "$inside" = 1 ] && exec "$@"

Q="$PFX-queue"; mkdir -p "$Q"
T="$Q/$(date +%s)-$(printf '%07d' $$)"
printf '%s\t%s\t%s\t%s\n' "$$" "$(date '+%H:%M:%S')" "$PWD" "$*" > "$T"
H="$PFX-holder"
mine=0
cleanup() { rm -f "$T"; [ "$mine" = 1 ] && rm -f "$H"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
waited=0
while :; do
  for f in "$Q"/*; do
    [ -e "$f" ] || continue
    fp=$(cut -f1 "$f" 2>/dev/null)
    { [ -n "$fp" ] && kill -0 "$fp" 2>/dev/null; } || rm -f "$f"
  done
  first=$(ls "$Q" 2>/dev/null | sort | head -1)
  if [ "$Q/$first" = "$T" ]; then
    # Locks 2 and 3 are the old script's extra slots; holding all keeps old and new callers exclusive.
    exec 9>>"$PFX-1.lock" 8>>"$PFX-2.lock" 7>>"$PFX-3.lock"
    ok=0
    if /usr/bin/lockf -s -t 0 9 2>/dev/null && /usr/bin/lockf -s -t 0 8 2>/dev/null && /usr/bin/lockf -s -t 0 7 2>/dev/null; then
      ok=1
      if [ "$have_quiet" = 0 ]; then
        exec 6>>"$QUIET"
        /usr/bin/lockf -s -t 0 6 2>/dev/null || { ok=0; exec 6>&-; }
      fi
    fi
    if [ "$ok" = 1 ]; then
      mine=1
      printf '%s\t%s\t%s\t%s\n' "$$" "$(date '+%H:%M:%S')" "$PWD" "$*" > "$H"
      rm -f "$T"
      [ "$waited" -gt 0 ] && echo "heavy.sh: got the build slot after ${waited}s" >&2
      OPEN_HEAVY_HELD=1 "$@" 9>&- 8>&- 7>&- 6>&-
      exit $?
    fi
    exec 9>&- 8>&- 7>&-
  fi
  sleep 3; waited=$((waited + 3))
done
