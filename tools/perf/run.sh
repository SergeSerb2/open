#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# S-real primary runs use pair-matched imports and the frozen private replay
# states. The older worker remains useful for fresh Open and fault controls.
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[i]}" == --phase ]]; then
    [[ "${args[i+1]:-}" == 2 && "${args[0]:-}" == open ]] || {
      echo 'Only open --phase 2 is supported; omit --phase for Phase 1.' >&2; exit 2;
    }
    unset 'args[i]' 'args[i+1]'
    exec python3 "$ROOT/tools/perf/phase2_replay.py" "${args[@]}"
  fi
done
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[i]}" in
    --mode|--groups) exec python3 "$ROOT/tools/perf/run.py" "$@" ;;
    --state)
      if [[ "${args[i+1]:-}" == S-empty ]]; then
        exec python3 "$ROOT/tools/perf/run.py" "$@"
      fi ;;
  esac
done
exec python3 "$ROOT/tools/perf/campaign.py" "$@"
