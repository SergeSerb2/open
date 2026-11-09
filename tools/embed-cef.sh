#!/usr/bin/env bash
# Xcode "Run Script" phase of the Open target. Copies the CEF framework and the
# five helper apps into Open.app/Contents/Frameworks and ad-hoc signs what it copied.
#
# OPEN_KEEP_LOCALES="en en_GB" keeps only those CEF .lproj folders (bundle-size
# experiment, see docs/engine-spike.md). Default: keep all locales.
set -euo pipefail

CEF_FW_SRC="$CEF_ROOT/Release/Chromium Embedded Framework.framework"
DEST="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
SIGN_ID="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[[ -z "$SIGN_ID" ]] && SIGN_ID="-"
mkdir -p "$DEST"

if [[ ! -d "$CEF_FW_SRC" ]]; then
  echo "error: CEF not found at $CEF_FW_SRC. Run tools/fetch-cef.sh first." >&2
  exit 1
fi

rsync_args=(-a --delete)
if [[ -n "${OPEN_KEEP_LOCALES:-}" ]]; then
  for l in $OPEN_KEEP_LOCALES; do rsync_args+=(--include "Resources/$l.lproj/***"); done
  rsync_args+=(--exclude "Resources/*.lproj")
  # Excluded paths survive --delete; remove locales an earlier untrimmed build left.
  rsync_args+=(--delete-excluded)
fi

# rsync -i prints one line per changed file; re-sign only when something changed.
changed="$(rsync "${rsync_args[@]}" -i "$CEF_FW_SRC/" "$DEST/Chromium Embedded Framework.framework/")"
if [[ -n "$changed" ]] || ! codesign -v "$DEST/Chromium Embedded Framework.framework" 2>/dev/null; then
  echo "Signing Chromium Embedded Framework.framework"
  for lib in "$DEST/Chromium Embedded Framework.framework/Libraries/"*.dylib; do
    codesign --force --sign "$SIGN_ID" --timestamp=none "$lib"
  done
  codesign --force --sign "$SIGN_ID" --timestamp=none "$DEST/Chromium Embedded Framework.framework"
fi

for suffix in "" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)"; do
  name="Open Helper$suffix.app"
  rsync -a --delete "$BUILT_PRODUCTS_DIR/$name/" "$DEST/$name/"
done
