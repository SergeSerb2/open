#!/usr/bin/env bash
# Copyright 2026 The Open Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# boat.dev NativeLink farm for Siso remote builds of Open Unified
# (Unified/PLAN.md §2). Reuses Engine/fork/remote/ (NativeLink 1.8.3,
# Chromium's pinned Linux clang, worker tunnels, round-robin proxy).
#
#   boat-farm.sh up [--workers N] [--type large] [--ttl SECONDS]
#   boat-farm.sh tunnel [--streams N]   # local 127.0.0.1:50051 -> scheduler
#   boat-farm.sh status
#   boat-farm.sh down                   # deletes every farm sandbox
#
# Every sandbox is created with --no-env --no-monitoring --no-snapshots
# (no account secrets on build machines; boat.dev's monitoring agents cost
# about one core). Nothing listens publicly: workers reach the scheduler
# through SSH tunnels restricted to the two NativeLink ports, and this
# machine reaches it through `boat forward`.
#
# Options (any command):
#   --prefix NAME   sandbox name prefix (default: open-unified-farm)
#   --dry-run       print the boat commands instead of running them
#
# State (sandbox ids, worker key): ${XDG_STATE_HOME:-~/.local/state}/
# open-unified/boat-farm/. Run `down` when a compile wave ends: workers
# bill by the hour.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REMOTE_DIR="${REPO_ROOT}/Engine/fork/remote"
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/open-unified/boat-farm"
STATE_FILE="${STATE_DIR}/farm.env"

PREFIX="open-unified-farm"
WORKERS=8
TYPE="large"
TTL=$((6 * 3600))
STREAMS=6
SLOTS=8
DRY_RUN=0

usage() {
  sed -n '6,27p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

log() { printf '\033[1m[boat-farm]\033[0m %s\n' "$*" >&2; }
die() { printf '[boat-farm] error: %s\n' "$*" >&2; exit 1; }

boat_cmd() {
  if [[ "${DRY_RUN}" == 1 ]]; then
    {
      printf '[dry-run] boat'
      printf ' %q' "$@"
      printf '\n'
    } >&2
    # Fake ids so the rest of the flow prints too.
    if [[ "${1:-}" == "new" ]]; then
      printf '{"id":"dry-run-%s"}\n' "${RANDOM}"
    fi
    return 0
  fi
  BOAT_NO_UPDATE=1 boat "$@"
}

json_id() {
  python3 -I -c '
import json, sys
text = sys.stdin.read()
for line in text.splitlines():
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except ValueError:
        continue
    for key in ("id", "sandboxId", "sandbox_id"):
        if isinstance(obj.get(key), str):
            print(obj[key]); sys.exit(0)
    sb = obj.get("sandbox")
    if isinstance(sb, dict) and isinstance(sb.get("id"), str):
        print(sb["id"]); sys.exit(0)
sys.exit("no sandbox id in boat output")
'
}

save_state() {
  mkdir -p "${STATE_DIR}"
  chmod 700 "${STATE_DIR}"
  {
    printf 'SCHED_ID=%q\n' "${SCHED_ID:-}"
    printf 'WORKER_IDS=(%s)\n' "${WORKER_IDS[*]:-}"
  } > "${STATE_FILE}"
}

load_state() {
  SCHED_ID=""
  WORKER_IDS=()
  # shellcheck source=/dev/null
  [[ -f "${STATE_FILE}" ]] && source "${STATE_FILE}"
  return 0
}

# The Engine worker config bind-mounts the macOS SDK for Mac builds. Linux
# and Windows cross builds read their sysroots as ordinary inputs, so the
# farm uses the same config without those Mac-only mounts.
worker_config() {
  python3 -I - "${REMOTE_DIR}/nativelink-worker.json5" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
start = text.find('experimental_readonly_input_mounts')
if start >= 0:
    line_start = text.rfind('\n', 0, start) + 1
    depth, i = 0, text.index('[', start)
    while True:
        if text[i] == '[':
            depth += 1
        elif text[i] == ']':
            depth -= 1
            if depth == 0:
                break
        i += 1
    end = text.find('\n', i) + 1
    text = text[:line_start] + text[end:]
sys.stdout.write(text)
PY
}

cmd_up() {
  command -v boat >/dev/null || [[ "${DRY_RUN}" == 1 ]] ||
    die "the boat CLI is not installed (https://docs.boat.dev)"
  for f in nativelink-scheduler.json5 nativelink-worker.json5 setup-node.sh \
           worker-up.sh; do
    [[ -f "${REMOTE_DIR}/${f}" ]] || die "missing Engine/fork/remote/${f}"
  done
  load_state
  [[ -z "${SCHED_ID}" ]] || die "a farm exists (${SCHED_ID}); run down first"
  mkdir -p "${STATE_DIR}"
  chmod 700 "${STATE_DIR}"

  # Worker -> scheduler tunnel key (port forwarding only).
  local key="${STATE_DIR}/worker_ed25519"
  [[ -f "${key}" ]] || ssh-keygen -q -t ed25519 -N '' -C open-unified-farm \
    -f "${key}"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  worker_config > "${tmp}/nativelink-worker.json5"

  log "scheduler (${TYPE})"
  SCHED_ID="$(boat_cmd new --json --type "${TYPE}" --no-env --no-monitoring \
    --no-snapshots --ttl "${TTL}" --name "${PREFIX}-sched" \
    --file "e3/nativelink-scheduler.json5=${REMOTE_DIR}/nativelink-scheduler.json5" \
    --file "e3/setup-node.sh=${REMOTE_DIR}/setup-node.sh" | json_id)"
  WORKER_IDS=()
  save_state
  local restrict='restrict,port-forwarding,command="/bin/false",permitopen="127.0.0.1:50051",permitopen="127.0.0.1:50061"'
  boat_cmd ssh "${SCHED_ID}" "set -e
    sudo mkdir -p /opt/e3 && sudo chown user:user /opt/e3
    cp ~/e3/* /opt/e3/ && bash /opt/e3/setup-node.sh >/dev/null
    mkdir -p /opt/e3/data /opt/e3/log ~/.ssh
    echo '${restrict} $(cat "${key}.pub")' >> ~/.ssh/authorized_keys
    setsid nohup /opt/e3/nativelink /opt/e3/nativelink-scheduler.json5 \
      > /opt/e3/log/scheduler.log 2>&1 < /dev/null &
    sleep 2; (echo > /dev/tcp/127.0.0.1/50051) && echo scheduler-up"

  # Workers dial the scheduler's IPv6 address with a pinned host key.
  local sched_addr sched_hostkey
  if [[ "${DRY_RUN}" == 1 ]]; then
    sched_addr="2001:db8::1"
    sched_hostkey="ssh-ed25519 AAAA-dry-run"
  else
    sched_addr="$(boat_cmd ssh "${SCHED_ID}" \
      "ip -6 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -1")"
    sched_hostkey="$(boat_cmd ssh "${SCHED_ID}" \
      "cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub")"
    [[ -n "${sched_addr}" && -n "${sched_hostkey}" ]] ||
      die "cannot read the scheduler's address or host key"
  fi

  log "${WORKERS} workers (${TYPE}, ${SLOTS} slots each)"
  local i id
  for ((i = 1; i <= WORKERS; i++)); do
    id="$(boat_cmd new --json --type "${TYPE}" --no-env --no-monitoring \
      --no-snapshots --ttl "${TTL}" --name "${PREFIX}-w${i}" \
      --file "e3/nativelink-worker.json5=${tmp}/nativelink-worker.json5" \
      --file "e3/setup-node.sh=${REMOTE_DIR}/setup-node.sh" \
      --file "e3/worker-up.sh=${REMOTE_DIR}/worker-up.sh" \
      --file ".ssh/e3_worker=${key}" | json_id)"
    WORKER_IDS+=("${id}")
    save_state
    boat_cmd ssh "${id}" "set -e
      chmod 600 ~/.ssh/e3_worker
      sudo mkdir -p /opt/e3 && sudo chown user:user /opt/e3 && cp ~/e3/* /opt/e3/
      bash /opt/e3/worker-up.sh '${sched_addr}' '${sched_hostkey}' \
        '${PREFIX}-w${i}' '${SLOTS}'" &
  done
  wait
  log "farm up: scheduler ${SCHED_ID}, ${#WORKER_IDS[@]} workers"
  log "next: boat-farm.sh tunnel, then unified-build --remote"
}

cmd_tunnel() {
  load_state
  [[ -n "${SCHED_ID}" ]] || die "no farm; run up first"
  # Several forwarded streams + Engine's round-robin proxy on 50051: one
  # SSH stream moves ~6 MB/s at 150 ms RTT (Engine/fork/remote/README.md).
  local ports=() i port
  for ((i = 0; i < STREAMS; i++)); do
    port=$((50101 + i))
    ports+=("${port}")
    if [[ "${DRY_RUN}" == 1 ]]; then
      boat_cmd forward "${SCHED_ID}" --remote 50051 --local "${port}"
    else
      BOAT_NO_UPDATE=1 boat forward "${SCHED_ID}" --remote 50051 \
        --local "${port}" > "${STATE_DIR}/forward-${port}.log" 2>&1 &
    fi
  done
  [[ "${DRY_RUN}" == 1 ]] && return 0
  log "proxy 127.0.0.1:50051 -> ${ports[*]} (Ctrl-C stops the tunnels)"
  trap 'kill $(jobs -p) 2>/dev/null' EXIT INT TERM
  python3 -I "${REMOTE_DIR}/rr-proxy.py" 50051 "${ports[@]}"
}

cmd_status() {
  load_state
  log "state: ${STATE_FILE}"
  log "scheduler: ${SCHED_ID:-none}; workers: ${WORKER_IDS[*]:-none}"
  boat_cmd list --json | python3 -I -c '
import json, sys
prefix = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line.startswith(("{", "[")):
        continue
    data = json.loads(line)
    rows = data if isinstance(data, list) else data.get("sandboxes", [data])
    for row in rows:
        name = row.get("name") or ""
        if name.startswith(prefix):
            print(f"{row.get(\"id\", \"?\")}  {name}  {row.get(\"state\", row.get(\"status\", \"?\"))}")
' "${PREFIX}" || true
}

cmd_down() {
  load_state
  local ids=("${WORKER_IDS[@]}")
  [[ -n "${SCHED_ID}" ]] && ids+=("${SCHED_ID}")
  # Also sweep sandboxes of an interrupted `up` that never reached state.
  if [[ "${DRY_RUN}" == 0 ]] && command -v boat >/dev/null; then
    while read -r id; do
      [[ -n "${id}" ]] && ids+=("${id}")
    done < <(BOAT_NO_UPDATE=1 boat list --all --json 2>/dev/null | python3 -I -c '
import json, sys
prefix = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line.startswith(("{", "[")):
        continue
    data = json.loads(line)
    rows = data if isinstance(data, list) else data.get("sandboxes", [data])
    for row in rows:
        if (row.get("name") or "").startswith(prefix) and row.get("id"):
            print(row["id"])
' "${PREFIX}")
  fi
  local seen=" " id
  for id in "${ids[@]}"; do
    [[ "${seen}" == *" ${id} "* ]] && continue
    seen+="${id} "
    log "delete ${id}"
    boat_cmd delete --yes "${id}" || log "delete ${id} failed (check boat list)"
  done
  if [[ "${DRY_RUN}" == 0 ]]; then
    rm -f "${STATE_FILE}" "${STATE_DIR}"/forward-*.log
  fi
  log "farm down"
}

[[ $# -ge 1 ]] || usage 2
COMMAND="$1"; shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workers) WORKERS="$2"; shift 2 ;;
    --type) TYPE="$2"; shift 2 ;;
    --ttl) TTL="$2"; shift 2 ;;
    --streams) STREAMS="$2"; shift 2 ;;
    --slots) SLOTS="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown option $1" ;;
  esac
done
[[ "${WORKERS}" =~ ^[0-9]+$ && "${WORKERS}" -ge 1 && "${WORKERS}" -le 32 ]] ||
  die "--workers must be 1..32"

case "${COMMAND}" in
  up) cmd_up ;;
  tunnel) cmd_tunnel ;;
  status) cmd_status ;;
  down) cmd_down ;;
  -h|--help|help) usage 0 ;;
  *) die "unknown command ${COMMAND}" ;;
esac
