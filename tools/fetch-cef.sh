#!/usr/bin/env bash
# Puts a CEF binary distribution at Vendor/cef/ (the CEF root the Xcode
# project builds against) and builds libcef_dll_wrapper (Release, arm64) in
# Vendor/cef/build/. Idempotent: a second run checks a stamp and exits.
#
#   tools/fetch-cef.sh              # $CEF_SOURCE, default fork
#   CEF_SOURCE=cdn tools/fetch-cef.sh
#   tools/fetch-cef.sh --force      # copy again and rebuild the wrapper
#
# CEF_SOURCE is the one switch between engines:
#   fork  (default) Our fork's distribution, recorded by
#         Engine/fork/scripts/engine-distrib and copied by
#         tools/fetch-engine.sh --run (docs/engine-fork.md).
#   cdn   Stock CEF from cef-builds.spotifycdn.com, built from the same CEF
#         commit and Chromium tag as our fork (checked against
#         Engine/fork/VERSIONS). The archive and its extraction are cached in
#         $OPEN_CEF_CACHE (default ~/Library/Caches/Open/cef), so a clean
#         clone does not download 300 MB again. Use it only to compare
#         against the fork (docs/engine-spike.md, Measurements).
#
# To move the CDN pin: pick a "standard" macosarm64 entry from
# https://cef-builds.spotifycdn.com/index.json, update CEF_VERSION and CEF_SHA1,
# run once with CEF_SHA256= (empty), then pin the printed sha256.
set -euo pipefail

CEF_SOURCE="${CEF_SOURCE:-fork}"
CEF_VERSION="156.0.14+g4fa4ab5+chromium-156.0.8078.48"
CEF_PLATFORM="macosarm64"
CEF_SHA1="dd97a0bf9f25686b135858ea809780dfb9b57006"
CEF_SHA256="${CEF_SHA256-e238aca81208407ddc210f9633577e5f059fc990678fb355b90d2625faea8625}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor/cef"
STAMP="$VENDOR/.open-source"
CACHE="${OPEN_CEF_CACHE:-$HOME/Library/Caches/Open/cef}"
JOBS="${OPEN_BUILD_JOBS:-6}"
export PATH="/opt/homebrew/bin:$PATH"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

# The CDN build must match the fork's pins, so switching engines never
# changes the CEF API under OpenEngine.
VERSIONS="$ROOT/Engine/fork/VERSIONS"
if [[ -f "$VERSIONS" ]]; then
  pins="$(
    set -a
    # shellcheck disable=SC1090
    . "$VERSIONS"
    echo "$CHROMIUM_TAG ${CEF_COMMIT:0:7}"
  )"
  read -r pin_chromium pin_cef <<<"$pins"
  if [[ "$CEF_VERSION" != *"+g${pin_cef}+chromium-${pin_chromium}" ]]; then
    echo "error: CEF_VERSION $CEF_VERSION does not match Engine/fork/VERSIONS ($pin_cef, $pin_chromium)" >&2
    exit 1
  fi
fi

current="$(cat "$STAMP" 2>/dev/null || true)"

case "$CEF_SOURCE" in
  cdn)
    DIST="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}"
    want="cdn $DIST"
    if [[ $FORCE -eq 1 || "$current" != "$want" ]]; then
      mkdir -p "$CACHE"
      ARCHIVE="$CACHE/$DIST.tar.bz2"
      EXTRACTED="$CACHE/$DIST"
      if [[ ! -f "$EXTRACTED/.open-verified" ]]; then
        if [[ ! -f "$ARCHIVE" ]]; then
          echo "==> Downloading $DIST"
          curl -fL --retry 3 -o "$ARCHIVE.part" "https://cef-builds.spotifycdn.com/${DIST//+/%2B}.tar.bz2"
          mv "$ARCHIVE.part" "$ARCHIVE"
        fi
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
        echo "==> Extracting to the cache"
        rm -rf "$EXTRACTED"
        tar -xjf "$ARCHIVE" -C "$CACHE"
        echo "$got_sha256" >"$EXTRACTED/.open-verified"
      fi
      echo "==> Copying $DIST to Vendor/cef"
      mkdir -p "$VENDOR"
      rsync -a --delete --exclude .open-verified "$EXTRACTED/" "$VENDOR/"
      echo "$want" >"$STAMP"
    fi
    ;;
  fork)
    # tools/fetch-engine.sh validates the recorded distribution and rsyncs
    # it over Vendor/cef/ (deleting our stamp and wrapper build).
    ENGINE_ROOT="${OPEN_ENGINE_ROOT:-$HOME/Developer/open-engine}"
    recorded="$(cat "$ENGINE_ROOT/.open-engine-state/distrib.txt" 2>/dev/null || true)"
    if [[ -z "$recorded" ]]; then
      echo "error: no fork distribution recorded; run Engine/fork/scripts/engine-distrib first (docs/engine-fork.md)" >&2
      exit 1
    fi
    want="fork $recorded $(stat -f %m "$recorded")"
    if [[ $FORCE -eq 1 || "$current" != "$want" ]]; then
      "$ROOT/tools/fetch-engine.sh" --run
      echo "$want" >"$STAMP"
    fi
    ;;
  *)
    echo "error: CEF_SOURCE must be cdn or fork (got $CEF_SOURCE)" >&2
    exit 1
    ;;
esac

WRAPPER="$VENDOR/build/libcef_dll_wrapper/libcef_dll_wrapper.a"
if [[ $FORCE -eq 1 || ! -f "$WRAPPER" ]]; then
  echo "==> Building libcef_dll_wrapper (Release, arm64, -j $JOBS)"
  nice -n 10 cmake -S "$VENDOR" -B "$VENDOR/build" \
    -G "Unix Makefiles" \
    -DPROJECT_ARCH=arm64 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DUSE_SANDBOX=ON >/dev/null
  nice -n 10 cmake --build "$VENDOR/build" --target libcef_dll_wrapper -j "$JOBS"
fi

echo "==> CEF ready: $(cat "$STAMP")"
