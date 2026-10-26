#!/usr/bin/env bash
# Puts a CEF binary distribution at Vendor/cef/current and builds
# libcef_dll_wrapper (Release, arm64) inside it. Idempotent: a second run
# only checks the stamp files and exits.
#
#   tools/fetch-cef.sh              # use $CEF_SOURCE (default: cdn)
#   CEF_SOURCE=fork tools/fetch-cef.sh
#   tools/fetch-cef.sh --force      # redo the copy/extract and the wrapper
#
# CEF_SOURCE is the one switch between engines:
#   cdn   Stock CEF from cef-builds.spotifycdn.com. Same CEF commit (4fa4ab5)
#         and Chromium (156.0.8078.48) as our fork's base, so the API matches.
#   fork  The binary distribution that our own Chromium fork produces with
#         make_distrib (automate-git.py --minimal-distrib). It is read from
#         $CEF_FORK_DISTRIB and copied into Vendor/cef/, never built in place.
#
# Downloads are cached in $OPEN_CEF_CACHE (default ~/Library/Caches/Open/cef),
# so a clean clone does not download the 300 MB archive again.
#
# To move the CDN pin: pick a "standard" macosarm64 entry from
# https://cef-builds.spotifycdn.com/index.json, update CEF_VERSION and CEF_SHA1,
# run once with CEF_SHA256= (empty), then pin the printed sha256.
set -euo pipefail

CEF_SOURCE="${CEF_SOURCE:-cdn}"

# Pinned engine versions (keep in sync with docs/engine-patches.md).
CHROMIUM_VERSION="156.0.8078.48"
CEF_COMMIT="4fa4ab516"
CEF_VERSION="156.0.14+g4fa4ab5+chromium-${CHROMIUM_VERSION}"
CEF_PLATFORM="macosarm64"
CEF_SHA1="dd97a0bf9f25686b135858ea809780dfb9b57006"
CEF_SHA256="${CEF_SHA256-e238aca81208407ddc210f9633577e5f059fc990678fb355b90d2625faea8625}"

# Where the fork's make_distrib output appears.
CEF_FORK_DISTRIB="${CEF_FORK_DISTRIB:-$HOME/Developer/open-engine/chromium_git/chromium/src/cef/binary_distrib}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor/cef"
CACHE="${OPEN_CEF_CACHE:-$HOME/Library/Caches/Open/cef}"
JOBS="${OPEN_BUILD_JOBS:-6}"
export PATH="/opt/homebrew/bin:$PATH"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1
mkdir -p "$VENDOR" "$CACHE"

case "$CEF_SOURCE" in
  cdn)
    DIST="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}"
    ARCHIVE="$CACHE/$DIST.tar.bz2"
    # Older checkouts kept the archive in Vendor/cef; move it to the cache.
    if [[ ! -f "$ARCHIVE" && -f "$VENDOR/$DIST.tar.bz2" ]]; then
      mv "$VENDOR/$DIST.tar.bz2" "$ARCHIVE"
    fi
    if [[ ! -f "$ARCHIVE" ]]; then
      echo "==> Downloading $DIST"
      curl -fL --retry 3 -o "$ARCHIVE.part" "https://cef-builds.spotifycdn.com/${DIST//+/%2B}.tar.bz2"
      mv "$ARCHIVE.part" "$ARCHIVE"
    fi
    STAMP="$VENDOR/$DIST/.open-extracted"
    if [[ $FORCE -eq 1 || ! -f "$STAMP" ]]; then
      echo "==> Verifying checksums"
      got_sha1="$(shasum -a 1 "$ARCHIVE" | awk '{print $1}')"
      if [[ "$got_sha1" != "$CEF_SHA1" ]]; then
        echo "sha1 mismatch: got $got_sha1, want $CEF_SHA1" >&2
        exit 1
      fi
      got_sha256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
      if [[ -z "$CEF_SHA256" ]]; then
        echo "sha256 (pin this in CEF_SHA256): $got_sha256"
      elif [[ "$got_sha256" != "$CEF_SHA256" ]]; then
        echo "sha256 mismatch: got $got_sha256, want $CEF_SHA256" >&2
        exit 1
      fi
      echo "==> Extracting"
      rm -rf "$VENDOR/$DIST"
      tar -xjf "$ARCHIVE" -C "$VENDOR"
      echo "$got_sha256" >"$STAMP"
    fi
    ;;
  fork)
    # make_distrib writes cef_binary_<version>_macosarm64[_minimal] as a
    # folder and/or a .tar.bz2. Take the newest one for our CEF version.
    SRC="$(ls -1dt "$CEF_FORK_DISTRIB"/cef_binary_*"_${CEF_PLATFORM}"* 2>/dev/null | grep -v '\.sha1$' | head -1 || true)"
    if [[ -z "$SRC" ]]; then
      echo "error: no fork distribution in $CEF_FORK_DISTRIB (run the fork build + make_distrib first)" >&2
      exit 1
    fi
    DIST="fork-$(basename "${SRC%.tar.bz2}")"
    STAMP="$VENDOR/$DIST/.open-extracted"
    src_id="$(stat -f '%m %z' "$SRC")"
    if [[ $FORCE -eq 1 || ! -f "$STAMP" || "$(cat "$STAMP")" != "$src_id" ]]; then
      echo "==> Copying fork distribution $(basename "$SRC")"
      rm -rf "$VENDOR/$DIST"
      if [[ "$SRC" == *.tar.bz2 ]]; then
        mkdir -p "$VENDOR/$DIST.tmp"
        tar -xjf "$SRC" -C "$VENDOR/$DIST.tmp"
        mv "$VENDOR/$DIST.tmp"/* "$VENDOR/$DIST"
        rmdir "$VENDOR/$DIST.tmp"
      else
        rsync -a --exclude build/ "$SRC/" "$VENDOR/$DIST/"
      fi
      echo "$src_id" >"$STAMP"
    fi
    ;;
  *)
    echo "error: CEF_SOURCE must be cdn or fork (got $CEF_SOURCE)" >&2
    exit 1
    ;;
esac

ln -sfn "$DIST" "$VENDOR/current"
echo "$CEF_SOURCE $DIST" >"$VENDOR/current.txt"

WRAPPER="$VENDOR/$DIST/build/libcef_dll_wrapper/libcef_dll_wrapper.a"
if [[ $FORCE -eq 1 || ! -f "$WRAPPER" ]]; then
  echo "==> Building libcef_dll_wrapper (Release, arm64, -j $JOBS)"
  nice -n 10 cmake -S "$VENDOR/$DIST" -B "$VENDOR/$DIST/build" \
    -G "Unix Makefiles" \
    -DPROJECT_ARCH=arm64 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DUSE_SANDBOX=ON >/dev/null
  nice -n 10 cmake --build "$VENDOR/$DIST/build" --target libcef_dll_wrapper -j "$JOBS"
fi

echo "==> CEF ready ($CEF_SOURCE): $VENDOR/current -> $DIST"
