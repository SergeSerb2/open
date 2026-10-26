#!/usr/bin/env bash
# Download the pinned CEF binary distribution into Vendor/cef/ and build
# libcef_dll_wrapper (Release, arm64). Idempotent: re-running skips finished steps.
#
#   tools/fetch-cef.sh            # fetch + verify + extract + build wrapper
#   tools/fetch-cef.sh --force    # wipe Vendor/cef/<dist> and redo everything
#
# To move to a new CEF: pick a "standard" macosarm64 entry from
# https://cef-builds.spotifycdn.com/index.json, update CEF_VERSION and CEF_SHA1
# from the index, run with CEF_SHA256= (empty) once, then pin the printed sha256.
set -euo pipefail

CEF_VERSION="156.0.14+g4fa4ab5+chromium-156.0.8078.48"
CEF_PLATFORM="macosarm64"
CEF_SHA1="dd97a0bf9f25686b135858ea809780dfb9b57006"
CEF_SHA256="${CEF_SHA256-e238aca81208407ddc210f9633577e5f059fc990678fb355b90d2625faea8625}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor/cef"
DIST="cef_binary_${CEF_VERSION}_${CEF_PLATFORM}"
ARCHIVE="$VENDOR/$DIST.tar.bz2"
URL="https://cef-builds.spotifycdn.com/${DIST//+/%2B}.tar.bz2"
export PATH="/opt/homebrew/bin:$PATH"

if [[ "${1:-}" == "--force" ]]; then
  rm -rf "$VENDOR/$DIST" "$VENDOR/current"
fi

mkdir -p "$VENDOR"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "==> Downloading $DIST"
  curl -fL --retry 3 -o "$ARCHIVE.part" "$URL"
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

if [[ ! -d "$VENDOR/$DIST" ]]; then
  echo "==> Extracting"
  tar -xjf "$ARCHIVE" -C "$VENDOR"
fi
ln -sfn "$DIST" "$VENDOR/current"

WRAPPER="$VENDOR/$DIST/build/libcef_dll_wrapper/libcef_dll_wrapper.a"
if [[ ! -f "$WRAPPER" ]]; then
  echo "==> Building libcef_dll_wrapper (Release, arm64)"
  cmake -S "$VENDOR/$DIST" -B "$VENDOR/$DIST/build" \
    -G "Unix Makefiles" \
    -DPROJECT_ARCH=arm64 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DUSE_SANDBOX=ON
  cmake --build "$VENDOR/$DIST/build" --target libcef_dll_wrapper -j "$(sysctl -n hw.ncpu)"
fi

echo "==> CEF ready: $VENDOR/current"
echo "    framework: $VENDOR/current/Release/Chromium Embedded Framework.framework"
echo "    wrapper:   $WRAPPER"
