#!/bin/bash
# Run the real release CLIs. Requires macOS, Swift, and Python 3.
set -u
set -o pipefail
umask 077

ROOT=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
python3 "$ROOT/tools/verification/gate.py" --require-heavy || { echo "CLI worker requires host heavy.sh" >&2; exit 2; }
PACKAGE="$ROOT/Packages/OpenKit"
BIN="$PACKAGE/.build/release"
HELPER="$ROOT/tools/verification/check.py"
QUICK=0
ONLY=
ARC=0
KEEP=0
NAMES='commands-demo roundtrip space-legacy space-pad-compare suggest-check commands-dump route favicons media-demo sleep-demo adblock-perf adblock-catalog profiles sidebar-render sidebar-theme-roles sidebar-compare commandbar-render extensions-render onboarding-render boosts import-arc verify-secrets-fixture'

usage() {
    cat <<EOF
Usage: tools/verify-all.sh [--quick] [--only NAME[,NAME]] [--with-arc-data] [--keep-logs]
Checks (in order; build always runs):
  build $NAMES
--quick          Build, commands-demo, suggest-check, commands-dump only.
--with-arc-data  Opt in to a read-only copy/import of Arc's top-level JSON files.
--keep-logs      Also retain synthetic scratch files. Logs always remain.
Environment: VERIFY_JOBS (default 6), VERIFY_LOG_DIR (new log directory).
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --quick) QUICK=1 ;;
        --with-arc-data) ARC=1 ;;
        --keep-logs) KEEP=1 ;;
        --only)
            [ "$#" -ge 2 ] && [ -n "$2" ] && [ -z "$ONLY" ] || { usage >&2; exit 2; }
            ONLY=$2
            shift
            ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

case "${VERIFY_JOBS:-6}" in ''|*[!0-9]*|0) echo 'VERIFY_JOBS must be a positive integer' >&2; exit 2 ;; esac
case "$ONLY" in ,*|*,|*,,*) echo 'Empty --only name' >&2; exit 2 ;; esac
if [ -n "$ONLY" ]; then
    old_ifs=$IFS
    IFS=,
    read -r -a requested <<< "$ONLY"
    IFS=$old_ifs
    for name in "${requested[@]}"; do
        case " build $NAMES " in
            *" $name "*) ;;
            *) printf 'Unknown check: %s\n' "$name" >&2; exit 2 ;;
        esac
        if [ "$name" = import-arc ] && [ "$ARC" -ne 1 ]; then
            echo '--only import-arc also requires --with-arc-data' >&2
            exit 2
        fi
        if [ "$QUICK" -eq 1 ]; then
            case "$name" in build|commands-demo|suggest-check|commands-dump) ;;
                *) echo '--only check is outside --quick selection' >&2; exit 2 ;;
            esac
        fi
    done
fi

TEMP_BASE=${TMPDIR:-/tmp}
if [ -n "${VERIFY_LOG_DIR:-}" ]; then
    mkdir -m 700 "$VERIFY_LOG_DIR" || exit 1
    LOG_DIR=$(cd "$VERIFY_LOG_DIR" && pwd) || exit 1
else
    LOG_DIR=$(mktemp -d "${TEMP_BASE%/}/open-verify-$(date +%Y%m%d-%H%M%S).XXXXXX") || exit 1
fi
SCRATCH=$(mktemp -d "${TEMP_BASE%/}/open-verify-work.XXXXXX") || exit 1
SEED="$SCRATCH/seed"
mkdir "$SEED" || exit 1
FAILURES=0
INTERRUPTIONS=0
ACTIVE=
RESULTS="$LOG_DIR/results.tsv"
: > "$RESULTS"

cleanup() {
    if [ "$KEEP" -eq 1 ]; then
        mv "$SCRATCH" "$LOG_DIR/artifacts"
    else
        rm -rf "$SCRATCH"
    fi
}
summary() {
    {
        printf '\n%-22s %-6s %s\n' NAME RESULT SECONDS
        awk -F '\t' '{printf "%-22s %-6s %s\n", $1, $2, $3}' "$RESULTS"
        printf '\nLogs: %s/\n' "$LOG_DIR"
    } | tee "$LOG_DIR/summary.txt"
}
interrupted() {
    if [ -n "$ACTIVE" ]; then
        printf '%s\tFAIL\t0\n' "$ACTIVE" >> "$RESULTS"
    fi
    summary
    exit 130
}
trap cleanup EXIT
trap interrupted INT TERM

selected() {
    if [ "$1" = import-arc ] && [ "$ARC" -ne 1 ]; then return 1; fi
    if [ "$QUICK" -eq 1 ]; then
        case "$1" in commands-demo|suggest-check|commands-dump) ;; *) return 1 ;; esac
    fi
    [ -z "$ONLY" ] || case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}
has_command() {
    # Match a complete usage token, never a substring such as suggest in suggest-check.
    LC_ALL=C grep -Eq "(^|[<|[:space:]])$1([>|[:space:]]|$)" "$LOG_DIR/openkit-usage.log"
}
missing_target() {
    # A successful build with a missing product is a failure if the target
    # exists. Only a target not introduced in Package.swift yet permits SKIP.
    python3 - "$PACKAGE/Package.swift" "$1" <<'PY'
import pathlib,re,sys
text=pathlib.Path(sys.argv[1]).read_text()
exists=re.search(r'\.executableTarget\s*\(\s*name\s*:\s*"'+re.escape(sys.argv[2])+r'"',text)
print(('built product missing for existing target: ' if exists else 'target does not exist yet: ')+sys.argv[2])
sys.exit(1 if exists else 77)
PY
}
available() {
    if [ "$1" = route ]; then
        for runner in "$ROOT/tools/route-check.sh" "$ROOT/tools/verify-routing.sh" \
                      "$ROOT/tools/verify-route.sh" "$BIN/route-check"; do
            [ ! -f "$runner" ] || return 0
        done
        if [ -f "$BIN/openkit" ] && has_command route-check; then return 0; fi
    fi
    case "$1" in
        space-pad-compare|sidebar-compare)
            # These are scripts, not openkit usage tokens. Missing capture
            # inputs are a failed check; only an absent target permits SKIP.
            return 0
            ;;
        sidebar-theme-roles)
            [ -f "$BIN/sidebar-render" ] || { missing_target sidebar-render; return $?; }
            ;;
        space-legacy)
            [ -f "$BIN/openkit" ] || { missing_target openkit; return $?; }
            [ -f "$BIN/sidebar-render" ] || { missing_target sidebar-render; return $?; }
            ;;
        space-editor)
            [ -f "$BIN/space-editor-render" ] || { missing_target space-editor-render; return $?; }
            ;;
        commands-dump|sidebar-render|commandbar-render|features-render|extensions-render|sitecontrol-render|settings-preview|onboarding-render)
            [ -f "$BIN/$1" ] || { missing_target "$1"; return $?; }
            ;;
        boosts)
            [ -f "$PACKAGE/Sources/OpenBoosts/Harness/serve.py" ] || { echo 'Boosts harness does not exist'; return 1; }
            ;;
        *)
            [ -f "$BIN/openkit" ] || { missing_target openkit; return $?; }
            command_name=$1
            case "$1" in adblock-*) command_name=adblock ;; import-arc) command_name=import-arc ;; esac
            has_command "$command_name" || { echo "openkit $command_name does not exist in usage"; return 1; }
            case "$1" in roundtrip|route|favicons)
                has_command commands-demo || { echo 'commands-demo fixture producer does not exist'; return 1; }
                ;;
            esac
            ;;
    esac
}
run_check() {
    name=$1
    ACTIVE=$name
    work=$(mktemp -d "$SCRATCH/$name.XXXXXX") || exit 1
    mkdir "$work/tmp" || exit 1
    log="$LOG_DIR/$name.log"
    start=$SECONDS
    printf 'Running %s...\n' "$name"
    availability=0
    if [ "$name" != build ]; then available "$name" > "$log"; availability=$?; fi
    if [ "$availability" -eq 77 ]; then
        result=SKIP
    elif [ "$availability" -ne 0 ]; then
        result=FAIL; FAILURES=$((FAILURES + 1))
    else
        (
            cd "$work" || exit 1
            export TMPDIR="$work/tmp/"
            python3 "$HELPER" "$name" "$ROOT" "$SEED"
        ) > "$log" 2>&1
        status=$?
        # Keep the browser evidence even when ordinary scratch files are removed.
        for screenshot in "$work"/*.png; do
            [ -f "$screenshot" ] || continue
            cp "$screenshot" "$LOG_DIR/$name-$(basename "$screenshot")" || status=1
        done
        if [ "$status" -eq 0 ]; then result=PASS
        else result=FAIL; FAILURES=$((FAILURES + 1)); fi
    fi
    elapsed=$((SECONDS - start))
    printf '%s\t%s\t%s\n' "$name" "$result" "$elapsed" >> "$RESULTS"
    printf '  %s (%ss)\n' "$result" "$elapsed"
    if [ "$result" = SKIP ]; then cat "$log"; fi
    ACTIVE=
    [ "$result" != FAIL ]
}

# Build failures stop the entire run. Other checks continue to expose all failures.
if ! run_check build; then summary; exit 1; fi
if [ -f "$BIN/openkit" ]; then
    # No arguments intentionally prints usage and exits 2. Other exits are failures.
    (cd "$SCRATCH" && TMPDIR="$SCRATCH/" "$BIN/openkit") > "$LOG_DIR/openkit-usage.log" 2>&1
    usage_status=$?
    if [ "$usage_status" -ne 0 ] && [ "$usage_status" -ne 2 ]; then
        printf 'openkit-usage\tFAIL\t0\n' >> "$RESULTS"
        FAILURES=$((FAILURES + 1))
    elif ! grep -q 'usage: openkit ' "$LOG_DIR/openkit-usage.log"; then
        printf 'openkit-usage\tFAIL\t0\n' >> "$RESULTS"
        FAILURES=$((FAILURES + 1))
    fi
else
    : > "$LOG_DIR/openkit-usage.log"
fi
for name in $NAMES; do
    if selected "$name"; then run_check "$name" || :; fi
done
summary
[ "$FAILURES" -eq 0 ] || exit 1
[ "$INTERRUPTIONS" -eq 0 ] || exit 2
exit 0
