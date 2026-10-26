#!/bin/bash
# Target shell: /bin/bash 3.2 (macOS). Guard empty arrays under set -u.
set -euo pipefail
# Standalone: tools/ does not source the fork scripts' common library.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)
usage() {
    cat <<'EOF'
fetch-engine.sh [--dry-run] [--run]
Copy the recorded CEF distribution into Vendor/cef/.
Env: OPEN_ENGINE_ROOT (default from Engine/fork/VERSIONS).
No arguments: show help. Use --run to copy.
tools/fetch-engine.sh --run
EOF
}
log() { printf 'fetch-engine: %s\n' "$*"; }
die() { log "$*" >&2; exit 1; }
[[ $# -gt 0 ]] || { usage; exit 0; }
dry=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --run) shift ;;
        --dry-run) dry=1; shift ;;
        *) die "unknown option: $1" ;;
    esac
done
set -a
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../Engine/fork/VERSIONS
. "$REPO_ROOT/Engine/fork/VERSIONS"
set +a
for key in CHROMIUM_TAG CHROMIUM_COMMIT CEF_BRANCH CEF_COMMIT DEPOT_TOOLS_COMMIT \
    RUST_TOOLCHAIN_REV RUST_TOOLCHAIN_VERSION ADBLOCK_CRATE_VERSION RMP_CRATE_VERSION \
    ENGINE_ROOT_DEFAULT CHROMIUM_SRC_SUBDIR OUT_DIR_DEV OUT_DIR_RELEASE BUILD_JOBS_DEFAULT TARGET_CPU; do
    [[ -n "${!key:-}" ]] || die "VERSIONS: missing key $key"
done
ENGINE_ROOT=${OPEN_ENGINE_ROOT:-$HOME/$ENGINE_ROOT_DEFAULT}
STATE_FILE="$ENGINE_ROOT/.open-engine-state/distrib.txt"
DEST="$REPO_ROOT/Vendor/cef"
[[ -f "$STATE_FILE" ]] || die 'no distrib recorded; run Engine/fork/scripts/engine-distrib first'
SRC=$(cat "$STATE_FILE")
SRC=$(python3 - "$ENGINE_ROOT/$CHROMIUM_SRC_SUBDIR/cef/binary_distrib" "$SRC" <<'PY'
import pathlib, sys
base = pathlib.Path(sys.argv[1]).resolve(strict=True)
source = pathlib.Path(sys.argv[2]).resolve(strict=True)
if source == base or not source.is_relative_to(base):
    raise SystemExit('recorded distrib must resolve under ' + str(base) + ': ' + str(source))
print(source)
PY
)
[[ -d "$SRC" || -f "$SRC" && "$SRC" == *.tar.bz2 ]] || die "recorded distrib $SRC does not exist or is not a directory/.tar.bz2"
require_framework() {
    python3 - "$1" <<'PY'
import pathlib, sys
base = pathlib.Path(sys.argv[1]).resolve(strict=True)
frameworks = base.rglob('Chromium Embedded Framework.framework/Chromium Embedded Framework')
if not any(p.is_file() and p.resolve().is_relative_to(base) for p in frameworks):
    raise SystemExit('distribution has no expected framework binary: ' + str(base))
PY
}
if [[ -d "$SRC" ]]; then
    require_framework "$SRC"
else
    # Check archive shape and framework presence even in read-only dry-run.
    python3 - "$SRC" <<'PY'
import pathlib, sys, tarfile
with tarfile.open(sys.argv[1], 'r:bz2') as archive:
    roots = set()
    framework = False
    for member in archive.getmembers():
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or '..' in path.parts or not (member.isdir() or member.isfile() or member.issym() or member.islnk()):
            raise SystemExit('unsafe archive member: ' + member.name)
        if path.parts:
            roots.add(path.parts[0])
        if member.isfile() and path.name == 'Chromium Embedded Framework' and 'Chromium Embedded Framework.framework' in path.parts[:-1]:
            framework = True
    if len(roots) != 1:
        raise SystemExit('archive needs a single top-level directory')
    if not framework:
        raise SystemExit('archive has no expected framework binary')
PY
fi
if [[ $dry == 1 ]]; then
    [[ ! -f "$SRC" ]] || log "dry-run: would extract $SRC into a temporary directory (single top-level directory required)"
    if [[ -f "$SRC" ]]; then
        while IFS= read -r member; do log "dry-run: archive member $member -> $DEST/${member#*/}"; done < <(tar -tjf "$SRC")
    fi
    log "dry-run: would mkdir -p $DEST"
    # rsync's itemized dry run shows actual file copies/deletions for directory input.
    if [[ -d "$SRC" && -d "$DEST" ]]; then rsync -ani --delete "$SRC/" "$DEST/"; fi
    if [[ -d "$SRC" ]]; then
        while IFS= read -r -d '' file; do log "dry-run: would copy $file -> $DEST/${file#"$SRC/"}"; done < <(find "$SRC" -type f -print0)
    fi
    log "dry-run: would rsync -a --delete $SRC/ $DEST/"
    exit 0
fi
if [[ -f "$SRC" ]]; then
    temp=$(mktemp -d)
    trap 'rm -rf "$temp"' EXIT
    # Validate members and links before extraction; never allow archive traversal.
    python3 - "$SRC" "$temp" <<'PY'
import pathlib, sys, tarfile
with tarfile.open(sys.argv[1], 'r:bz2') as archive:
    names = set()
    members = archive.getmembers()
    root = pathlib.Path(sys.argv[2]).resolve()
    for m in members:
        p = pathlib.PurePosixPath(m.name)
        if p.is_absolute() or '..' in p.parts or not (m.isdir() or m.isfile() or m.issym() or m.islnk()):
            raise SystemExit('unsafe archive member: ' + m.name)
        if p.parts:
            names.add(p.parts[0])
    if len(names) != 1:
        raise SystemExit('archive needs a single top-level directory')
    base = root / next(iter(names))
    # Check each member after prior links exist. This also works on Apple's
    # Python, whose tarfile has no extraction-filter argument.
    for m in members:
        destination = root / m.name
        if not destination.resolve().is_relative_to(base):
            raise SystemExit('archive path escapes distribution: ' + m.name)
        if m.issym() or m.islnk():
            target = pathlib.PurePosixPath(m.linkname)
            resolved = ((destination.parent if m.issym() else root) / target).resolve()
            if target.is_absolute() or not resolved.is_relative_to(base):
                raise SystemExit('unsafe archive link: ' + m.name)
            if m.islnk() and not resolved.is_file():
                raise SystemExit('archive hard link needs an earlier regular file: ' + m.name)
        archive.extract(m, sys.argv[2])
PY
    entries=("$temp"/*)
    [[ ${#entries[@]} == 1 && -d "${entries[0]}" ]] || die 'archive needs a single top-level directory'
    SRC=${entries[0]}
    require_framework "$SRC"
fi
mkdir -p "$DEST"
rsync -a --delete "$SRC/" "$DEST/"
log "$SRC -> $DEST (already up to date if rsync made no changes)"
