#!/usr/bin/env bash
# Copyright 2026 The Open Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Packages a built Open Unified macOS arm64 .app bundle into a signed,
# notarized .dmg and optionally publishes it as a GitHub Pre-Release.
#
# Usage:
#   Unified/scripts/package-mac-dmg.sh [options]
#
# Options:
#   --app PATH                  Built .app bundle (default: auto-detect Open.app or
#                               Chromium.app in <src>/<out>)
#   --root DIR                  Unified checkout root (default: ~/<UNIFIED_ROOT_DEFAULT>)
#   --src DIR                   Chromium src dir (default: <root>/src)
#   --out DIR                   Build output dir relative to src (default: out/OpenMacArm64)
#   --out-dir DIR               Output directory for .dmg, .sha256, and receipts
#                               (default: <repo>/build/unified-dmg)
#   --version VER               Version for DMG filename and CFBundleShortVersionString
#                               (default: 0.2.0-unified.<short-git-sha>)
#   --identity ID               Developer ID Application codesign identity
#                               (default: $OPEN_SIGN_IDENTITY, else auto-detect single
#                               installed Developer ID Application cert)
#   --adhoc                     Ad-hoc sign (-) for local dev/testing (implies
#                               --skip-notarize and suffixes output with -adhoc)
#   --notary-profile PROFILE    Apple notarization keychain profile
#                               (default: ${OPEN_NOTARY_PROFILE:-open-notary})
#   --skip-notarize             Sign without submitting to Apple notarization
#   --publish-repo OWNER/REPO   Create or update a GitHub Pre-Release (NEVER --latest)
#                               with the .dmg and .dmg.sha256 assets
#   --tag TAG                   GitHub release tag (default: unified-v<version>)
#   --dry-run                   Validate inputs, tools, entitlements, and staging layout
#                               without signing, notarizing, or publishing
#   -h, --help                  Show this help text
#
# Environment:
#   OPEN_SIGN_IDENTITY          Default Developer ID Application signing identity
#   OPEN_NOTARY_PROFILE         Default notarytool keychain profile (default: open-notary)
#
# Bash 3.2 compatible (stock macOS /bin/bash): guard empty arrays under set -u.
set -euo pipefail
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIFIED_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${UNIFIED_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${UNIFIED_DIR}/VERSIONS"

export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

APP_PATH=""
ROOT="${HOME}/${UNIFIED_ROOT_DEFAULT}"
SRC=""
OUT="out/OpenMacArm64"
OUT_DIR="${REPO_ROOT}/build/unified-dmg"
VERSION=""
IDENTITY="${OPEN_SIGN_IDENTITY:-}"
ADHOC=0
NOTARY_PROFILE="${OPEN_NOTARY_PROFILE:-open-notary}"
SKIP_NOTARIZE=0
PUBLISH_REPO=""
TAG=""
DRY_RUN=0

WORK_DIR=""
MOUNT_DIR=""

usage() {
  sed -n '9,39p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

log() {
  printf '[package-mac-dmg] %s\n' "$*"
}

warn() {
  printf '[package-mac-dmg] WARN: %s\n' "$*" >&2
}

die() {
  printf '[package-mac-dmg] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local rc=$?
  if [[ -n "${MOUNT_DIR}" ]]; then
    hdiutil detach "${MOUNT_DIR}" >/dev/null 2>&1 ||
      hdiutil detach -force "${MOUNT_DIR}" >/dev/null 2>&1 || true
    rmdir "${MOUNT_DIR}" 2>/dev/null || true
    MOUNT_DIR=""
  fi
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    rm -rf "${WORK_DIR}"
    WORK_DIR=""
  fi
  exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

require_arg() {
  local flag="$1"
  local remaining="$2"
  local value="${3:-}"
  if [[ "${remaining}" -lt 2 || -z "${value}" ]]; then
    die "${flag} requires a non-empty argument"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      require_arg "$1" "$#" "${2:-}"
      APP_PATH="$2"
      shift 2
      ;;
    --root)
      require_arg "$1" "$#" "${2:-}"
      ROOT="$2"
      shift 2
      ;;
    --src)
      require_arg "$1" "$#" "${2:-}"
      SRC="$2"
      shift 2
      ;;
    --out)
      require_arg "$1" "$#" "${2:-}"
      OUT="$2"
      shift 2
      ;;
    --out-dir)
      require_arg "$1" "$#" "${2:-}"
      OUT_DIR="$2"
      shift 2
      ;;
    --version)
      require_arg "$1" "$#" "${2:-}"
      VERSION="$2"
      shift 2
      ;;
    --identity)
      require_arg "$1" "$#" "${2:-}"
      IDENTITY="$2"
      shift 2
      ;;
    --adhoc)
      ADHOC=1
      shift
      ;;
    --notary-profile)
      require_arg "$1" "$#" "${2:-}"
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    --skip-notarize)
      SKIP_NOTARIZE=1
      shift
      ;;
    --publish-repo)
      require_arg "$1" "$#" "${2:-}"
      PUBLISH_REPO="$2"
      shift 2
      ;;
    --tag)
      require_arg "$1" "$#" "${2:-}"
      TAG="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage 0
      ;;
    *)
      die "unknown option: $1 (use --help for usage)"
      ;;
  esac
done

# --- Resolve defaults & validate arguments -----------------------------------

HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"

GIT_SHA="$(git -C "${REPO_ROOT}" rev-parse --short=7 HEAD 2>/dev/null || printf 'dev')"
if [[ -z "${VERSION}" ]]; then
  VERSION="0.2.0-unified.${GIT_SHA}"
fi

if [[ ! "${VERSION}" =~ ^[A-Za-z0-9._+-]+$ ]]; then
  die "invalid --version '${VERSION}' (allowed characters: A-Za-z0-9._+-)"
fi

if [[ -z "${TAG}" ]]; then
  TAG="unified-v${VERSION}"
fi

if [[ ! "${TAG}" =~ ^[A-Za-z0-9._+-]+$ ]]; then
  die "invalid --tag '${TAG}' (allowed characters: A-Za-z0-9._+-)"
fi

if [[ -n "${PUBLISH_REPO}" && ! "${PUBLISH_REPO}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  die "invalid --publish-repo '${PUBLISH_REPO}' (expected OWNER/REPO)"
fi

if [[ "${ADHOC}" == 1 ]]; then
  SKIP_NOTARIZE=1
  if [[ -n "${IDENTITY}" && "${IDENTITY}" != "-" ]]; then
    warn "--adhoc overrides --identity '${IDENTITY}' with ad-hoc signing (-)"
  fi
  IDENTITY="-"
fi

SRC="${SRC:-${ROOT}/src}"
if [[ -z "${APP_PATH}" ]]; then
  if [[ "${OUT}" == /* ]]; then
    OUT_ABS="${OUT}"
  else
    OUT_ABS="${SRC}/${OUT}"
  fi
  if [[ -d "${OUT_ABS}/Open.app" ]]; then
    APP_PATH="${OUT_ABS}/Open.app"
  elif [[ -d "${OUT_ABS}/Chromium.app" ]]; then
    APP_PATH="${OUT_ABS}/Chromium.app"
  elif [[ -d "${OUT_ABS}" ]]; then
    APP_PATH="$(find "${OUT_ABS}" -maxdepth 1 -type d -name '*.app' | LC_ALL=C sort | head -n 1 || true)"
  fi
  [[ -n "${APP_PATH}" ]] ||
    die "no Open.app or Chromium.app found in '${OUT_ABS}'; pass --app PATH (or --root/--src/--out)"
fi

[[ -d "${APP_PATH}" ]] || die "--app path does not exist or is not a directory: ${APP_PATH}"
[[ "${APP_PATH}" == *.app ]] || die "--app path must end with .app: ${APP_PATH}"
[[ -f "${APP_PATH}/Contents/Info.plist" ]] || die "missing Contents/Info.plist in ${APP_PATH}"
[[ -d "${APP_PATH}/Contents/MacOS" ]] || die "missing Contents/MacOS directory in ${APP_PATH}"

APP_PATH="$(cd "$(dirname "${APP_PATH}")" && pwd)/$(basename "${APP_PATH}")"

DMG_SUFFIX=""
if [[ "${ADHOC}" == 1 ]]; then
  DMG_SUFFIX="-adhoc"
fi
DMG_BASENAME="Open-Unified-${VERSION}-arm64${DMG_SUFFIX}.dmg"
DMG_PATH="${OUT_DIR}/${DMG_BASENAME}"
SHA_PATH="${DMG_PATH}.sha256"
RECEIPT_PATH="${OUT_DIR}/${DMG_BASENAME%.dmg}.receipt.json"
NOTARY_RECEIPT_PATH="${OUT_DIR}/${DMG_BASENAME%.dmg}.notary.json"
NOTARY_LOG_PATH="${OUT_DIR}/${DMG_BASENAME%.dmg}.notary-log.json"
RELEASE_NOTES_PATH="${OUT_DIR}/release-notes-${TAG}.md"

# --- Platform & toolchain preflight ------------------------------------------

command -v python3 >/dev/null || die "python3 is required"

if [[ "${HOST_OS}" != "Darwin" ]]; then
  if [[ "${DRY_RUN}" == 1 ]]; then
    warn "running --dry-run on ${HOST_OS}/${HOST_ARCH}; macOS packaging/signing tools will be validated as skipped"
  else
    die "macOS (Darwin) is required to sign and package a .dmg (current host: ${HOST_OS}/${HOST_ARCH})"
  fi
else
  if [[ "${HOST_ARCH}" != "arm64" ]]; then
    warn "expected arm64 macOS host for arm64 DMG packaging (current arch: ${HOST_ARCH})"
  fi
  for tool in ditto hdiutil codesign xcrun shasum xattr security spctl; do
    command -v "${tool}" >/dev/null || die "required macOS tool not found on PATH: ${tool}"
  done
fi

if [[ -n "${PUBLISH_REPO}" ]]; then
  command -v gh >/dev/null || die "gh CLI is required for --publish-repo ${PUBLISH_REPO}"
  if [[ "${DRY_RUN}" == 0 ]]; then
    gh auth status >/dev/null 2>&1 || die "gh CLI is not authenticated (run 'gh auth login')"
  fi
fi

# --- Resolve signing identity & notarization profile -------------------------

TEAM_ID=""
SIGN_MODE="developer-id"
if [[ "${ADHOC}" == 1 ]]; then
  SIGN_MODE="adhoc"
elif [[ "${HOST_OS}" == "Darwin" ]]; then
  if [[ -z "${IDENTITY}" ]]; then
    dev_ids=()
    while IFS= read -r line; do
      [[ -n "${line}" ]] && dev_ids+=("${line}")
    done < <(
      security find-identity -v -p codesigning |
        sed -n 's/^[[:space:]]*[0-9]*)[[:space:]]*[A-Fa-f0-9]*[[:space:]]*"\(Developer ID Application: [^"]*\)".*/\1/p' |
        LC_ALL=C sort -u
    )
    if [[ ${#dev_ids[@]} -eq 0 ]]; then
      die "no 'Developer ID Application' certificate found in Keychain; install one, pass --identity / OPEN_SIGN_IDENTITY, or use --adhoc for local dev"
    elif [[ ${#dev_ids[@]} -gt 1 ]]; then
      printf '[package-mac-dmg] ERROR: multiple Developer ID Application certificates found; select one with --identity or OPEN_SIGN_IDENTITY:\n' >&2
      for cand in "${dev_ids[@]}"; do
        printf '  - %s\n' "${cand}" >&2
      done
      exit 1
    fi
    IDENTITY="${dev_ids[0]}"
    log "auto-detected signing identity: ${IDENTITY}"
  fi

  if ! security find-identity -v -p codesigning | grep -Fq "\"${IDENTITY}\""; then
    die "signing identity is not installed or valid in Keychain: ${IDENTITY}"
  fi

  TEAM_ID="$(printf '%s\n' "${IDENTITY}" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')"
  if [[ "${IDENTITY}" != 'Developer ID Application: '* || -z "${TEAM_ID}" ]]; then
    if [[ "${SKIP_NOTARIZE}" == 0 ]]; then
      die "notarization requires a 'Developer ID Application: <Name> (<TeamID>)' identity (got: ${IDENTITY})"
    fi
    warn "identity does not look like a Developer ID Application certificate: ${IDENTITY}"
  fi

  if [[ "${SKIP_NOTARIZE}" == 0 && "${DRY_RUN}" == 0 ]]; then
    if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
      die "notarytool keychain profile '${NOTARY_PROFILE}' is unavailable or invalid (configure with 'xcrun notarytool store-credentials ${NOTARY_PROFILE}' or pass --skip-notarize)"
    fi
  fi
else
  # Non-macOS --dry-run only
  if [[ -z "${IDENTITY}" ]]; then
    IDENTITY="<auto-detect single Developer ID Application cert on macOS>"
  else
    TEAM_ID="$(printf '%s\n' "${IDENTITY}" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')"
  fi
fi

# --- Create temp workspace & entitlements ------------------------------------

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/open-unified-dmg.XXXXXX")"
ENT_DIR="${WORK_DIR}/entitlements"
mkdir -p "${ENT_DIR}"

# Entitlements match Open's release policy (App/Open.entitlements,
# Helper/Entitlements/*.entitlements, tools/release.sh, and Chromium's
# chrome/app/app-entitlements.plist):
# - Never include com.apple.security.get-task-allow (notarization rejects it).
# - Never include com.apple.security.cs.allow-dyld-environment-variables.
# - Main app carries device/privacy entitlements only (same-Team Chromium
#   Framework passes Hardened Runtime Library Validation without CS exceptions).
# - Helpers carry only the role-specific CS entitlements required for V8/GPU/CDM.

ENT_APP="${ENT_DIR}/app.entitlements"
ENT_HELPER="${ENT_DIR}/helper.entitlements"
ENT_HELPER_GPU="${ENT_DIR}/helper.gpu.entitlements"
ENT_HELPER_RENDERER="${ENT_DIR}/helper.renderer.entitlements"
ENT_HELPER_PLUGIN="${ENT_DIR}/helper.plugin.entitlements"
ENT_HELPER_ALERTS="${ENT_DIR}/helper.alerts.entitlements"

cat > "${ENT_APP}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.device.audio-input</key>
	<true/>
	<key>com.apple.security.device.bluetooth</key>
	<true/>
	<key>com.apple.security.device.camera</key>
	<true/>
	<key>com.apple.security.device.print</key>
	<true/>
	<key>com.apple.security.device.usb</key>
	<true/>
	<key>com.apple.security.personal-information.calendars</key>
	<true/>
	<key>com.apple.security.personal-information.location</key>
	<true/>
	<key>com.apple.security.personal-information.photos-library</key>
	<true/>
</dict>
</plist>
PLIST

cat > "${ENT_HELPER}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
</dict>
</plist>
PLIST

cat > "${ENT_HELPER_GPU}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
</dict>
</plist>
PLIST

cat > "${ENT_HELPER_RENDERER}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
	<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
	<true/>
</dict>
</plist>
PLIST

cat > "${ENT_HELPER_PLUGIN}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
	<true/>
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
</dict>
</plist>
PLIST

cat > "${ENT_HELPER_ALERTS}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
PLIST

# Validate generated entitlements XML and assert banned keys are never present.
python3 - "${ENT_APP}" "${ENT_HELPER}" "${ENT_HELPER_GPU}" "${ENT_HELPER_RENDERER}" "${ENT_HELPER_PLUGIN}" "${ENT_HELPER_ALERTS}" <<'PY'
import plistlib
import sys
from pathlib import Path

banned = {
    "com.apple.security.get-task-allow",
    "com.apple.security.cs.allow-dyld-environment-variables",
}
for raw in sys.argv[1:]:
    path = Path(raw)
    data = plistlib.loads(path.read_bytes())
    if not isinstance(data, dict):
        raise SystemExit(f"entitlements plist is not a dict: {path}")
    bad = banned.intersection(data.keys())
    if bad:
        raise SystemExit(f"banned entitlement(s) {sorted(bad)} in {path}")
PY

# --- Helpers for icon resolution & signing inventory -------------------------

detect_icon_source() {
  if [[ -d "${REPO_ROOT}/App/Resources/AppIcon.icon" ]]; then
    printf 'actool:%s\n' "${REPO_ROOT}/App/Resources/AppIcon.icon"
  elif [[ -f "${REPO_ROOT}/App/Resources/AppIcon.icns" ]]; then
    printf 'icns:%s\n' "${REPO_ROOT}/App/Resources/AppIcon.icns"
  elif [[ -f "${REPO_ROOT}/App/Resources/AppIcons/openLight.png" ]]; then
    printf 'png:%s\n' "${REPO_ROOT}/App/Resources/AppIcons/openLight.png"
  else
    printf 'existing:\n'
  fi
}

# Emits NUL-delimited records: "<pass>\t<role>\t<path>\0" in strict inside-out order.
collect_signing_targets() {
  local app_root="$1"
  python3 - "${app_root}" <<'PY'
import os
import plistlib
import sys
from pathlib import Path

app = Path(sys.argv[1])
contents = app / "Contents"
if not contents.is_dir():
    raise SystemExit(f"missing Contents/ in {app}")

MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
}

BUNDLE_SUFFIXES = (
    ".app",
    ".framework",
    ".xpc",
    ".appex",
    ".plugin",
    ".docktileplugin",
)


def is_macho(path: Path) -> bool:
    try:
        with path.open("rb") as fh:
            return fh.read(4) in MACHO_MAGICS
    except OSError:
        return False


def bundle_main_executables(root: Path) -> set[Path]:
    """Return real paths of main executables owned by bundles so they are
    signed as part of their enclosing bundle rather than separately."""
    owned: set[Path] = set()

    def record_plist(bundle_dir: Path, plist_path: Path, exec_dir: Path) -> None:
        if not plist_path.is_file() or plist_path.is_symlink():
            return
        try:
            info = plistlib.loads(plist_path.read_bytes())
        except Exception:
            return
        exe = info.get("CFBundleExecutable")
        if isinstance(exe, str) and exe:
            candidate = exec_dir / exe
            if candidate.is_file() and not candidate.is_symlink():
                owned.add(candidate)

    # Top-level app executable
    record_plist(root, root / "Contents/Info.plist", root / "Contents/MacOS")

    for dirpath, dirnames, _ in os.walk(root / "Contents", followlinks=False):
        dp = Path(dirpath)
        for d in dirnames:
            p = dp / d
            if p.is_symlink():
                continue
            low = d.lower()
            if low.endswith((".app", ".xpc", ".appex", ".plugin", ".docktileplugin")):
                record_plist(p, p / "Contents/Info.plist", p / "Contents/MacOS")
            elif low.endswith(".framework"):
                # Flat framework layout
                record_plist(p, p / "Resources/Info.plist", p)
                # Versioned framework layout (Chromium Framework.framework/Versions/<ver>)
                versions = p / "Versions"
                if versions.is_dir() and not versions.is_symlink():
                    for ver in versions.iterdir():
                        if ver.is_dir() and not ver.is_symlink():
                            record_plist(ver, ver / "Resources/Info.plist", ver)
                            record_plist(ver, ver / "Info.plist", ver)
                            # Fallback if Info.plist lacks CFBundleExecutable
                            fw_bin = ver / p.stem
                            if fw_bin.is_file() and not fw_bin.is_symlink():
                                owned.add(fw_bin)
                fw_flat = p / p.stem
                if fw_flat.is_file() and not fw_flat.is_symlink():
                    owned.add(fw_flat)
    return owned


def helper_role(bundle_name: str) -> str:
    if bundle_name.endswith(("(Renderer).app", " Renderer).app")):
        return "renderer"
    if bundle_name.endswith(("(GPU).app", " GPU).app")):
        return "gpu"
    if bundle_name.endswith(("(Plugin).app", " Plugin).app")):
        return "plugin"
    if bundle_name.endswith(("(Alerts).app", " Alerts).app")):
        return "alerts"
    if "Helper" in bundle_name:
        return "generic"
    return "none"


def depth_key(path: Path) -> tuple[int, str]:
    return (-len(path.parts), str(path))


owned_execs = bundle_main_executables(app)

standalone: list[Path] = []
nested_bundles: list[Path] = []
helper_apps: list[Path] = []
frameworks: list[Path] = []

for dirpath, dirnames, filenames in os.walk(contents, followlinks=False):
    dp = Path(dirpath)
    # Check subdirectories for nested bundles (do not skip descending; we need
    # deepest-first inside-out ordering).
    for d in sorted(dirnames):
        p = dp / d
        if p.is_symlink():
            continue
        low = d.lower()
        if low.endswith(".app"):
            helper_apps.append(p)
        elif low.endswith(".framework"):
            frameworks.append(p)
        elif low.endswith((".xpc", ".appex", ".plugin", ".docktileplugin")):
            nested_bundles.append(p)

    for f in sorted(filenames):
        p = dp / f
        if p.is_symlink() or not p.is_file():
            continue
        if p in owned_execs:
            continue
        low = f.lower()
        if low.endswith((".dylib", ".so")):
            standalone.append(p)
        elif os.access(p, os.X_OK) and is_macho(p):
            standalone.append(p)

# Pass 1: dylibs, .so, and standalone Mach-O executables (e.g. crashpad handler)
for p in sorted(set(standalone), key=depth_key):
    sys.stdout.write(f"standalone\tnone\t{p}\0")

# Pass 2: nested XPC / AppEx / PlugIn bundles
for p in sorted(set(nested_bundles), key=depth_key):
    sys.stdout.write(f"nested_bundle\tnone\t{p}\0")

# Pass 3: nested Helper .app bundles with role-specific entitlements
for p in sorted(set(helper_apps), key=depth_key):
    sys.stdout.write(f"helper_app\t{helper_role(p.name)}\t{p}\0")

# Pass 4: frameworks (sign non-Current concrete versions first if multiple exist)
for p in sorted(set(frameworks), key=depth_key):
    versions = p / "Versions"
    if versions.is_dir() and not versions.is_symlink():
        current_target = None
        cur = versions / "Current"
        if cur.is_symlink():
            try:
                current_target = cur.resolve()
            except OSError:
                current_target = None
        real_vers = sorted(
            [v for v in versions.iterdir() if v.is_dir() and not v.is_symlink()],
            key=lambda v: v.name,
        )
        if len(real_vers) > 1:
            for v in real_vers:
                if current_target is None or v.resolve() != current_target:
                    sys.stdout.write(f"framework_version\tnone\t{v}\0")
    sys.stdout.write(f"framework\tnone\t{p}\0")

# Pass 5: top-level Open.app
sys.stdout.write(f"app\tapp\t{app}\0")
PY
}

entitlement_for_role() {
  case "$1" in
    app) printf '%s\n' "${ENT_APP}" ;;
    generic) printf '%s\n' "${ENT_HELPER}" ;;
    gpu) printf '%s\n' "${ENT_HELPER_GPU}" ;;
    renderer) printf '%s\n' "${ENT_HELPER_RENDERER}" ;;
    plugin) printf '%s\n' "${ENT_HELPER_PLUGIN}" ;;
    alerts) printf '%s\n' "${ENT_HELPER_ALERTS}" ;;
    none) printf '' ;;
    *) die "unknown entitlement role: $1" ;;
  esac
}

# --- Dry-run summary & validation --------------------------------------------

if [[ "${DRY_RUN}" == 1 ]]; then
  ICON_PLAN="$(detect_icon_source)"
  log "DRY RUN — validating inputs, bundle layout, entitlements, and release plan"
  log "  Host:             ${HOST_OS} (${HOST_ARCH})"
  log "  Input .app:       ${APP_PATH}"
  log "  Staged .app:      Open.app (copied with ditto to temp dir)"
  log "  Version:          ${VERSION}"
  log "  Chromium pin:     ${CHROMIUM_TAG}"
  log "  Output DMG:       ${DMG_PATH}"
  log "  SHA-256 file:     ${SHA_PATH}"
  log "  Receipt file:     ${RECEIPT_PATH}"
  log "  Signing mode:     ${SIGN_MODE}"
  log "  Identity:         ${IDENTITY}"
  if [[ -n "${TEAM_ID}" ]]; then
    log "  Team ID:          ${TEAM_ID}"
  fi
  if [[ "${ADHOC}" == 1 ]]; then
    log "  Notarization:     SKIP (--adhoc local dev mode)"
  elif [[ "${SKIP_NOTARIZE}" == 1 ]]; then
    log "  Notarization:     SKIP (--skip-notarize)"
  else
    log "  Notarization:     enabled (profile: ${NOTARY_PROFILE})"
  fi
  log "  Icon source:      ${ICON_PLAN}"
  if [[ -n "${PUBLISH_REPO}" ]]; then
    log "  Publish repo:     ${PUBLISH_REPO} (GitHub Pre-Release, NEVER --latest)"
    log "  Publish tag:      ${TAG}"
    log "  Download URL:     https://github.com/${PUBLISH_REPO}/releases/download/${TAG}/${DMG_BASENAME}"
  else
    log "  Publish repo:     none (local artifact only)"
  fi

  # Validate input Info.plist & executable without mutating input bundle.
  python3 - "${APP_PATH}" "${VERSION}" <<'PY'
import plistlib
import sys
from pathlib import Path

app = Path(sys.argv[1])
version = sys.argv[2]
plist_path = app / "Contents/Info.plist"
info = plistlib.loads(plist_path.read_bytes())
exe = info.get("CFBundleExecutable", "")
if not exe or not (app / "Contents/MacOS" / exe).is_file():
    raise SystemExit(f"CFBundleExecutable '{exe}' missing in {app}/Contents/MacOS")
cur_min = str(info.get("LSMinimumSystemVersion", ""))
def parse_ver(s: str) -> tuple[int, ...]:
    parts = []
    for tok in s.split("."):
        if tok.isdigit():
            parts.append(int(tok))
        else:
            break
    return tuple(parts) if parts else (0,)
target_min = cur_min if parse_ver(cur_min) >= (15, 0) else "15.0"
print(f"[package-mac-dmg]   Input Info.plist: CFBundleExecutable={exe}, CFBundleIdentifier={info.get('CFBundleIdentifier', '')}, LSMinimumSystemVersion={cur_min or '<unset>'} -> {target_min}")
print(f"[package-mac-dmg]   Staged branding:  CFBundleDisplayName=Open, CFBundleName=Open, CFBundleShortVersionString={version}")
PY

  log "  Planned inside-out signing order:"
  count=0
  while IFS=$'\t' read -r -d '' pass role item; do
    rel="${item#"${APP_PATH}"/}"
    [[ "${item}" != "${APP_PATH}" ]] || rel="Open.app"
    printf '    %2d. [%-17s role=%-8s] %s\n' "$((count + 1))" "${pass}" "${role}" "${rel}"
    count=$((count + 1))
  done < <(collect_signing_targets "${APP_PATH}")

  log "DRY RUN PASSED (${count} signable targets discovered; no artifacts modified, notarized, or published)"
  exit 0
fi

# --- Step 1: Prepare Open.app bundle -----------------------------------------

mkdir -p "${OUT_DIR}"
STAGED_APP="${WORK_DIR}/app/Open.app"
mkdir -p "$(dirname "${STAGED_APP}")"

log "staging ${APP_PATH} -> ${STAGED_APP}"
ditto "${APP_PATH}" "${STAGED_APP}"

# Ensure no bundle symlink escapes Open.app.
python3 - "${STAGED_APP}" <<'PY'
import sys
from pathlib import Path

app = Path(sys.argv[1]).resolve()
for p in app.rglob("*"):
    if p.is_symlink():
        target = p.resolve()
        try:
            target.relative_to(app)
        except ValueError as exc:
            raise SystemExit(f"bundle symlink escapes Open.app: {p} -> {target}") from exc
PY

# Install Open's doorway-and-sun icon (never Arc assets).
ICON_INSTALLED=0
ASSETS_CAR_INSTALLED=0
ICON_SOURCE_DESC="$(detect_icon_source)"
ICON_KIND="${ICON_SOURCE_DESC%%:*}"
ICON_SRC_PATH="${ICON_SOURCE_DESC#*:}"
ICON_WORK="${WORK_DIR}/icon"
mkdir -p "${ICON_WORK}" "${STAGED_APP}/Contents/Resources"

if [[ "${ICON_KIND}" == "actool" ]]; then
  if xcrun --find actool >/dev/null 2>&1; then
    log "compiling Open AppIcon.icon via actool"
    if xcrun actool --compile "${ICON_WORK}" \
      --platform macosx \
      --minimum-deployment-target 26.0 \
      --app-icon AppIcon \
      --target-device mac \
      --output-partial-info-plist "${ICON_WORK}/AppIcon-partial.plist" \
      --errors --warnings \
      "${ICON_SRC_PATH}" >"${ICON_WORK}/actool.log" 2>&1; then
      if [[ -f "${ICON_WORK}/AppIcon.icns" ]]; then
        install -m 0644 "${ICON_WORK}/AppIcon.icns" "${STAGED_APP}/Contents/Resources/AppIcon.icns"
        ICON_INSTALLED=1
      fi
      if [[ -f "${ICON_WORK}/Assets.car" && ! -f "${STAGED_APP}/Contents/Resources/Assets.car" ]]; then
        install -m 0644 "${ICON_WORK}/Assets.car" "${STAGED_APP}/Contents/Resources/Assets.car"
        ASSETS_CAR_INSTALLED=1
      fi
    else
      warn "actool failed compiling ${ICON_SRC_PATH}; falling back to PNG/existing icon"
    fi
  else
    warn "xcrun actool not found; falling back to PNG/existing icon"
  fi
fi

if [[ "${ICON_INSTALLED}" == 0 && -f "${REPO_ROOT}/App/Resources/AppIcon.icns" ]]; then
  install -m 0644 "${REPO_ROOT}/App/Resources/AppIcon.icns" "${STAGED_APP}/Contents/Resources/AppIcon.icns"
  ICON_INSTALLED=1
fi

if [[ "${ICON_INSTALLED}" == 0 && -f "${REPO_ROOT}/App/Resources/AppIcons/openLight.png" ]]; then
  if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
    log "building AppIcon.icns from App/Resources/AppIcons/openLight.png via sips + iconutil"
    ICONSET="${ICON_WORK}/AppIcon.iconset"
    mkdir -p "${ICONSET}"
    PNG_SRC="${REPO_ROOT}/App/Resources/AppIcons/openLight.png"
    for spec in \
      "16:icon_16x16.png" \
      "32:icon_16x16@2x.png" \
      "32:icon_32x32.png" \
      "64:icon_32x32@2x.png" \
      "128:icon_128x128.png" \
      "256:icon_128x128@2x.png" \
      "256:icon_256x256.png" \
      "512:icon_256x256@2x.png" \
      "512:icon_512x512.png" \
      "1024:icon_512x512@2x.png"; do
      px="${spec%%:*}"
      name="${spec#*:}"
      sips -z "${px}" "${px}" "${PNG_SRC}" --out "${ICONSET}/${name}" >/dev/null
    done
    iconutil -c icns "${ICONSET}" -o "${STAGED_APP}/Contents/Resources/AppIcon.icns"
    ICON_INSTALLED=1
  else
    warn "sips/iconutil unavailable; keeping existing bundle icon"
  fi
fi

if [[ "${ICON_INSTALLED}" == 0 ]]; then
  warn "Open AppIcon.icns was not installed; preserving bundle's existing CFBundleIconFile"
fi

# Update Open.app/Contents/Info.plist with Open branding & version.
python3 - "${STAGED_APP}/Contents/Info.plist" "${VERSION}" "${CHROMIUM_TAG}" "${ICON_INSTALLED}" "${ASSETS_CAR_INSTALLED}" <<'PY'
import plistlib
import sys
from pathlib import Path

plist_path = Path(sys.argv[1])
version = sys.argv[2]
chromium_tag = sys.argv[3]
icon_installed = sys.argv[4] == "1"
assets_car_installed = sys.argv[5] == "1"

info = plistlib.loads(plist_path.read_bytes())

exe = info.get("CFBundleExecutable", "")
exe_path = plist_path.parent / "MacOS" / exe
if not exe or not exe_path.is_file():
    raise SystemExit(f"CFBundleExecutable '{exe}' missing in {plist_path.parent / 'MacOS'}")

info["CFBundleDisplayName"] = "Open"
info["CFBundleName"] = "Open"
info["CFBundleShortVersionString"] = version
info["OpenChromiumVersion"] = chromium_tag

cur_min = str(info.get("LSMinimumSystemVersion", ""))
def parse_ver(s: str) -> tuple[int, ...]:
    parts = []
    for tok in s.split("."):
        if tok.isdigit():
            parts.append(int(tok))
        else:
            break
    return tuple(parts) if parts else (0,)

if parse_ver(cur_min) < (15, 0):
    info["LSMinimumSystemVersion"] = "15.0"

if icon_installed:
    info["CFBundleIconFile"] = "AppIcon"
if assets_car_installed:
    info["CFBundleIconName"] = "AppIcon"

tmp_path = plist_path.with_suffix(".plist.tmp")
tmp_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=True))
tmp_path.replace(plist_path)
print(
    f"[package-mac-dmg] updated Info.plist: CFBundleDisplayName=Open, "
    f"CFBundleShortVersionString={version}, "
    f"LSMinimumSystemVersion={info['LSMinimumSystemVersion']}, "
    f"CFBundleIconFile={info.get('CFBundleIconFile', '')}"
)
PY

# Strip quarantine/extended attributes and Finder detritus before signing.
find "${STAGED_APP}" -name '.DS_Store' -delete
xattr -cr "${STAGED_APP}"

# --- Step 2: Inside-out Chromium code signing --------------------------------

sign_item() {
  local target="$1"
  local entitlements="${2:-}"
  local args=()
  if [[ "${ADHOC}" == 1 ]]; then
    args=(--force --sign -)
  else
    args=(--force --timestamp --options runtime --sign "${IDENTITY}")
  fi
  if [[ -n "${entitlements}" ]]; then
    args+=(--entitlements "${entitlements}")
  fi
  codesign "${args[@]}" "${target}"
}

log "signing Open.app inside-out (mode=${SIGN_MODE})"
signed_count=0
while IFS=$'\t' read -r -d '' pass role item; do
  ent_file="$(entitlement_for_role "${role}")"
  sign_item "${item}" "${ent_file}"
  signed_count=$((signed_count + 1))
done < <(collect_signing_targets "${STAGED_APP}")
log "signed ${signed_count} code item(s) inside-out"

log "verifying Open.app signature"
codesign --verify --deep --strict --verbose=2 "${STAGED_APP}"

if [[ "${ADHOC}" == 0 ]]; then
  APP_SIG_INFO="$(codesign -dvv "${STAGED_APP}" 2>&1)"
  grep -q 'runtime' <<< "${APP_SIG_INFO}" || die "Open.app signature lacks Hardened Runtime"
  if [[ -n "${TEAM_ID}" ]]; then
    grep -q "TeamIdentifier=${TEAM_ID}" <<< "${APP_SIG_INFO}" ||
      die "Open.app signature TeamIdentifier mismatch (expected ${TEAM_ID})"

    # Verify every signed nested binary, library, helper, and framework carries
    # the same Team ID and Hardened Runtime flag.
    bad_nested=0
    while IFS=$'\t' read -r -d '' _pass _role nested; do
      [[ "${nested}" != "${STAGED_APP}" ]] || continue
      info="$(codesign -dvv "${nested}" 2>&1)" || {
        warn "unsigned nested code: ${nested#"${STAGED_APP}"/}"
        bad_nested=1
        continue
      }
      if ! grep -q "TeamIdentifier=${TEAM_ID}" <<< "${info}" || ! grep -q 'runtime' <<< "${info}"; then
        warn "nested code missing TeamIdentifier=${TEAM_ID} or runtime: ${nested#"${STAGED_APP}"/}"
        bad_nested=1
      fi
    done < <(collect_signing_targets "${STAGED_APP}")
    [[ "${bad_nested}" == 0 ]] || die "nested code signature verification failed"
    log "verified all nested code carries TeamIdentifier=${TEAM_ID} and Hardened Runtime"
  fi
else
  log "Signing mode: ad-hoc (LOCAL DEV ONLY — not notarized)"
fi

# --- Step 3: Create DMG ------------------------------------------------------

DMG_STAGING="${WORK_DIR}/dmg-staging"
mkdir -p "${DMG_STAGING}"
ditto "${STAGED_APP}" "${DMG_STAGING}/Open.app"
ln -s /Applications "${DMG_STAGING}/Applications"

VOL_NAME="Open Unified ${VERSION}"
ICON_FILE="${STAGED_APP}/Contents/Resources/AppIcon.icns"
if [[ -f "${ICON_FILE}" ]]; then
  install -m 0644 "${ICON_FILE}" "${DMG_STAGING}/.VolumeIcon.icns"
fi

rm -f "${DMG_PATH}" "${SHA_PATH}"

if [[ -f "${DMG_STAGING}/.VolumeIcon.icns" ]] && xcrun --find SetFile >/dev/null 2>&1; then
  WRITABLE_DMG="${WORK_DIR}/Open-Unified-writable.dmg"
  log "creating writable UDRW image to apply custom volume icon"
  hdiutil create -volname "${VOL_NAME}" -srcfolder "${DMG_STAGING}" -ov -format UDRW "${WRITABLE_DMG}"
  MOUNT_DIR="$(mktemp -d "${WORK_DIR}/mount.XXXXXX")"
  hdiutil attach -nobrowse -mountpoint "${MOUNT_DIR}" "${WRITABLE_DMG}"
  xcrun SetFile -a C "${MOUNT_DIR}"
  hdiutil detach "${MOUNT_DIR}"
  rmdir "${MOUNT_DIR}"
  MOUNT_DIR=""
  log "converting to compressed UDZO DMG -> ${DMG_PATH}"
  hdiutil convert "${WRITABLE_DMG}" -format UDZO -imagekey zlib-level=9 -o "${DMG_PATH}" -ov
  rm -f "${WRITABLE_DMG}"
else
  log "creating compressed UDZO DMG -> ${DMG_PATH}"
  hdiutil create -volname "${VOL_NAME}" -srcfolder "${DMG_STAGING}" -ov -format UDZO -imagekey zlib-level=9 "${DMG_PATH}"
fi

# Best-effort Finder file icon on the .dmg itself (volume icon above survives transfers).
if [[ -f "${ICON_FILE}" && -f "${REPO_ROOT}/tools/release-icon.swift" ]] && xcrun --find swiftc >/dev/null 2>&1; then
  if xcrun swiftc "${REPO_ROOT}/tools/release-icon.swift" -o "${WORK_DIR}/release-icon" >/dev/null 2>&1; then
    "${WORK_DIR}/release-icon" set "${DMG_PATH}" "${ICON_FILE}" >/dev/null 2>&1 ||
      warn "could not set Finder file icon on ${DMG_PATH} (volume icon is still embedded)"
  fi
fi

# --- Step 4: Sign, Notarize, Staple & Verify DMG -----------------------------

NOTARIZED=0
NOTARY_SUBMISSION_ID=""
NOTARY_STATUS="skipped"

if [[ "${ADHOC}" == 0 ]]; then
  log "signing DMG with ${IDENTITY}"
  codesign --force --timestamp --sign "${IDENTITY}" "${DMG_PATH}"
  codesign --verify --strict --verbose=2 "${DMG_PATH}"

  if [[ "${SKIP_NOTARIZE}" == 0 ]]; then
    log "submitting DMG to Apple notarization (profile=${NOTARY_PROFILE})"
    submit_exit=0
    xcrun notarytool submit "${DMG_PATH}" \
      --keychain-profile "${NOTARY_PROFILE}" \
      --wait \
      --output-format json > "${NOTARY_RECEIPT_PATH}" || submit_exit=$?

    notary_parsed="$(python3 - "${NOTARY_RECEIPT_PATH}" <<'PY'
import json
import sys
from pathlib import Path

raw = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").strip()
try:
    data = json.loads(raw) if raw else {}
except json.JSONDecodeError:
    data = {}
print(data.get("id", ""))
print(data.get("status", ""))
PY
)"
    NOTARY_SUBMISSION_ID="$(printf '%s\n' "${notary_parsed}" | sed -n '1p')"
    NOTARY_STATUS="$(printf '%s\n' "${notary_parsed}" | sed -n '2p')"

    if [[ "${NOTARY_STATUS}" != "Accepted" || "${submit_exit}" -ne 0 ]]; then
      if [[ -n "${NOTARY_SUBMISSION_ID}" ]]; then
        log "fetching notarytool log for submission ${NOTARY_SUBMISSION_ID}"
        if xcrun notarytool log "${NOTARY_SUBMISSION_ID}" \
          --keychain-profile "${NOTARY_PROFILE}" > "${NOTARY_LOG_PATH}" 2>&1; then
          cat "${NOTARY_LOG_PATH}" >&2
        else
          warn "failed to download notarytool log for ${NOTARY_SUBMISSION_ID}"
        fi
      fi
      die "notarization failed (status=${NOTARY_STATUS:-unknown}, exit=${submit_exit}); receipt saved at ${NOTARY_RECEIPT_PATH}"
    fi

    log "notarization Accepted (submission=${NOTARY_SUBMISSION_ID}); stapling ticket"
    xcrun stapler staple "${DMG_PATH}"
    xcrun stapler validate "${DMG_PATH}"
    NOTARIZED=1

    log "checking Gatekeeper assessment (spctl)"
    spctl -a -vv -t open --context context:primary-signature "${DMG_PATH}"
  else
    log "SKIP notarization (--skip-notarize); running non-fatal Gatekeeper check"
    if ! spctl -a -vv -t open --context context:primary-signature "${DMG_PATH}"; then
      warn "Gatekeeper rejected unnotarized DMG (expected with --skip-notarize)"
    fi
  fi
else
  log "SKIP DMG signing and notarization (--adhoc local dev mode)"
fi

log "verifying DMG integrity (hdiutil verify)"
hdiutil verify "${DMG_PATH}"

log "writing SHA-256 checksum -> ${SHA_PATH}"
(
  cd "${OUT_DIR}"
  shasum -a 256 "${DMG_BASENAME}" > "${DMG_BASENAME}.sha256"
  shasum -a 256 -c "${DMG_BASENAME}.sha256"
)
DMG_SHA256="$(awk '{print $1}' "${SHA_PATH}")"

# Write packaging receipt JSON.
python3 - "${RECEIPT_PATH}" "${VERSION}" "${TAG}" "${CHROMIUM_TAG}" "${GIT_SHA}" \
  "${APP_PATH}" "${DMG_PATH}" "${DMG_SHA256}" "${SIGN_MODE}" "${IDENTITY}" \
  "${TEAM_ID}" "${NOTARIZED}" "${NOTARY_PROFILE}" "${NOTARY_SUBMISSION_ID}" \
  "${NOTARY_STATUS}" "${PUBLISH_REPO}" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

(
    receipt_path,
    version,
    tag,
    chromium_tag,
    git_sha,
    app_path,
    dmg_path,
    dmg_sha256,
    sign_mode,
    identity,
    team_id,
    notarized,
    notary_profile,
    notary_id,
    notary_status,
    publish_repo,
) = sys.argv[1:]

dmg = Path(dmg_path)
receipt = {
    "schema": 1,
    "created_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "version": version,
    "tag": tag,
    "chromium_version": chromium_tag,
    "git_commit": git_sha,
    "input_app": app_path,
    "dmg_path": str(dmg),
    "dmg_basename": dmg.name,
    "dmg_bytes": dmg.stat().st_size,
    "dmg_sha256": dmg_sha256,
    "signing": {
        "mode": sign_mode,
        "identity": identity,
        "team_id": team_id or None,
    },
    "notarization": {
        "notarized": notarized == "1",
        "profile": notary_profile if notarized == "1" else None,
        "submission_id": notary_id or None,
        "status": notary_status,
    },
    "publish_repo": publish_repo or None,
}
Path(receipt_path).write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
PY

# --- Step 5: Optional GitHub Pre-Release publishing --------------------------

DIRECT_DOWNLOAD_URL=""
if [[ -n "${PUBLISH_REPO}" ]]; then
  if [[ "${ADHOC}" == 1 ]]; then
    SIGN_SUMMARY="Ad-hoc signed (local dev/testing only — not notarized)"
  elif [[ "${NOTARIZED}" == 1 ]]; then
    SIGN_SUMMARY="Developer ID signed, Apple notarized, and stapled"
  else
    SIGN_SUMMARY="Developer ID signed (not notarized — --skip-notarize)"
  fi

  RELEASE_TITLE="Open Unified ${VERSION} (macOS arm64 Pre-Release)"
  cat > "${RELEASE_NOTES_PATH}" <<EOF
## Open Unified ${VERSION} (macOS arm64 Pre-Release)

> **Pre-release build** of the unified Chromium Views + Preact WebUI browser.
> The stable macOS Swift/CEF \`v0.1.x\` release and Sparkle \`appcast.xml\` are untouched.

- **Chromium base:** \`${CHROMIUM_TAG}\`
- **Git commit:** \`${GIT_SHA}\`
- **Signing & notarization:** ${SIGN_SUMMARY}
- **Artifact:** \`${DMG_BASENAME}\`

### SHA-256
\`\`\`
$(cat "${SHA_PATH}")
\`\`\`
EOF

  if gh release view "${TAG}" --repo "${PUBLISH_REPO}" >/dev/null 2>&1; then
    # Safety check: never overwrite or mutate a non-prerelease or Latest release!
    release_meta="$(gh release view "${TAG}" --repo "${PUBLISH_REPO}" --json isPrerelease,isLatest)"
    python3 - "${TAG}" "${PUBLISH_REPO}" "${release_meta}" <<'PY'
import json
import sys

tag, repo, raw = sys.argv[1:4]
meta = json.loads(raw)
if meta.get("isLatest") or not meta.get("isPrerelease"):
    raise SystemExit(
        f"refusing to modify existing release '{tag}' in {repo}: "
        f"isPrerelease={meta.get('isPrerelease')}, isLatest={meta.get('isLatest')} "
        "(only pre-releases may be updated by package-mac-dmg.sh)"
    )
PY
    log "updating existing GitHub Pre-Release ${PUBLISH_REPO}@${TAG}"
    gh release upload "${TAG}" --repo "${PUBLISH_REPO}" --clobber "${DMG_PATH}" "${SHA_PATH}"
    gh release edit "${TAG}" --repo "${PUBLISH_REPO}" \
      --prerelease --latest=false \
      --title "${RELEASE_TITLE}" \
      --notes-file "${RELEASE_NOTES_PATH}"
  else
    log "creating GitHub Pre-Release ${PUBLISH_REPO}@${TAG} (--prerelease --latest=false)"
    gh release create "${TAG}" --repo "${PUBLISH_REPO}" \
      --prerelease --latest=false \
      --title "${RELEASE_TITLE}" \
      --notes-file "${RELEASE_NOTES_PATH}" \
      "${DMG_PATH}" "${SHA_PATH}"
  fi

  DIRECT_DOWNLOAD_URL="https://github.com/${PUBLISH_REPO}/releases/download/${TAG}/${DMG_BASENAME}"
fi

# --- Final summary -----------------------------------------------------------

log "DONE"
log "  DMG:              ${DMG_PATH}"
log "  SHA-256:          ${DMG_SHA256}"
log "  Checksum file:    ${SHA_PATH}"
log "  Receipt:          ${RECEIPT_PATH}"
log "  Signing mode:     ${SIGN_MODE} (notarized=${NOTARIZED})"
if [[ -n "${DIRECT_DOWNLOAD_URL}" ]]; then
  printf '\nDirect download URL:\n  %s\n' "${DIRECT_DOWNLOAD_URL}"
fi
