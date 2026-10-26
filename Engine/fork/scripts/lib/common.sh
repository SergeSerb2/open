#!/bin/bash
set -euo pipefail

FORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="$(git -C "$FORK_DIR" rev-parse --show-toplevel)"
export REPO_ROOT
export LC_ALL=C GIT_OPTIONAL_LOCKS=0
# Help and check paths must not create logs, locks, or directories.
OPEN_ENGINE_READ_ONLY=${OPEN_ENGINE_READ_ONLY:-0}
for _open_arg in "$@"; do
    case "$_open_arg" in --help|-h|--dry-run|--check) OPEN_ENGINE_READ_ONLY=1 ;; esac
done

log() {
    printf '[%s] %s\n' "$(basename "$0")" "$*"
    if [[ "$OPEN_ENGINE_READ_ONLY" != 1 && -n "${LOG_DIR:-}" ]]; then
        mkdir -p "$LOG_DIR"
        printf '[%s] [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$0")" "$*" >> "$LOG_DIR/$(basename "$0").log"
    fi
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

load_versions() {
    # The override is only for engine-rebase's scratch pin file.
    local pin_file=${OPEN_ENGINE_VERSIONS:-$FORK_DIR/VERSIONS} key
    [[ -f "$pin_file" ]] || die "VERSIONS: missing file $pin_file"
    for key in CHROMIUM_TAG CHROMIUM_COMMIT CEF_BRANCH CEF_COMMIT DEPOT_TOOLS_COMMIT \
        RUST_TOOLCHAIN_REV RUST_TOOLCHAIN_VERSION ADBLOCK_CRATE_VERSION RMP_CRATE_VERSION \
        ENGINE_ROOT_DEFAULT CHROMIUM_SRC_SUBDIR OUT_DIR_DEV OUT_DIR_RELEASE BUILD_JOBS_DEFAULT TARGET_CPU; do
        unset "$key"
    done
    set -a
    # shellcheck disable=SC1090
    . "$pin_file"
    set +a
    for key in CHROMIUM_TAG CHROMIUM_COMMIT CEF_BRANCH CEF_COMMIT DEPOT_TOOLS_COMMIT \
        RUST_TOOLCHAIN_REV RUST_TOOLCHAIN_VERSION ADBLOCK_CRATE_VERSION RMP_CRATE_VERSION \
        ENGINE_ROOT_DEFAULT CHROMIUM_SRC_SUBDIR OUT_DIR_DEV OUT_DIR_RELEASE BUILD_JOBS_DEFAULT TARGET_CPU; do
        [[ -n "${!key:-}" ]] || die "VERSIONS: missing key $key"
    done
}

require_macos_arm64() {
    [[ "$(uname -s)" == Darwin ]] || die "requires Darwin; got $(uname -s)"
    [[ "$(uname -m)" == arm64 ]] || die "requires arm64; got $(uname -m)"
}

require_no_build_running() {
    local running pid command cwd
    running=$(pgrep -fl 'autoninja.*Release_GN|autoninja.*Release_Official|siso.*out/Release|ninja.*out/Release' || true)
    [[ -n "$running" ]] || return 0
    while read -r pid command; do
        [[ -n "$pid" ]] || continue
        # Ignore shell -c monitor commands whose text mentions build tools.
        case "$command" in /bin/zsh\ -c\ *|/bin/bash\ -c\ *|/bin/sh\ -c\ *) continue ;; esac
        # The guard protects this tree. An unrelated build must not prevent a
        # patch rehearsal in a disposable OPEN_ENGINE_ROOT.
        cwd=$(lsof -a -p "$pid" -d cwd -Fn -w 2>/dev/null | sed -n 's/^n//p' || true)
        if [[ "$cwd" == "$SRC_DIR" || "$cwd" == "$SRC_DIR/"* || "$command" == *"$SRC_DIR/"* ]]; then
            die "a build is running in $SRC_DIR/out/Release; wait for it to finish (see build log): $pid $command"
        fi
        # If inspection fails, reject the operation rather than assume safety.
        if [[ -z "$cwd" ]] && kill -0 "$pid" 2>/dev/null; then
            die "cannot inspect build $pid; wait for it to finish (see build log)"
        fi
    done <<< "$running"
}

acquire_lock() {
    local name=$1 lock="$STATE_DIR/lock-writer"
    [[ "$OPEN_ENGINE_READ_ONLY" != 1 ]] || die "read-only mode cannot acquire a writer lock"
    # Child bootstrap/apply commands in a rebase share the parent's lock.
    if [[ -n "${OPEN_ENGINE_LOCK_OWNER:-}" && -f "$lock/owner" ]] &&
        [[ "$(cat "$lock/owner")" == "$OPEN_ENGINE_LOCK_OWNER" ]]; then
        return
    fi
    mkdir -p "$STATE_DIR"
    mkdir "$lock" 2>/dev/null || die "another $name operation holds the lock (if stale, remove $lock by hand)"
    export OPEN_ENGINE_LOCK_OWNER="$$:$name"
    printf '%s\n' "$OPEN_ENGINE_LOCK_OWNER" > "$lock/owner"
    if ! mkdir "$STATE_DIR/lock-$name" 2>/dev/null; then
        rm "$lock/owner"
        rmdir "$lock"
        die "another $name operation holds the lock (if stale, remove $STATE_DIR/lock-$name by hand)"
    fi
    # Paths are evaluated at exit, rather than interpolated into shell code.
    OPEN_ENGINE_LOCK_NAME=$name
    trap 'rm -f "$STATE_DIR/lock-writer/owner"; rmdir "$STATE_DIR/lock-$OPEN_ENGINE_LOCK_NAME" "$STATE_DIR/lock-writer"' EXIT
}

export_engine_env() {
    export PATH="$ENGINE_ROOT/depot_tools:/opt/homebrew/bin:$PATH"
    export GIT_CACHE_PATH="$ENGINE_ROOT/git_cache" DEPOT_TOOLS_UPDATE=0 CEF_ARCHIVE_FORMAT=tar.bz2
}

load_versions
ENGINE_ROOT=${OPEN_ENGINE_ROOT:-$HOME/$ENGINE_ROOT_DEFAULT}
export SRC_DIR="$ENGINE_ROOT/$CHROMIUM_SRC_SUBDIR"
STATE_DIR="$ENGINE_ROOT/.open-engine-state"
LOG_DIR="$ENGINE_ROOT/logs"
