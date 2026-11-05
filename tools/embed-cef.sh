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
fi

# Re-signing changes the framework binary, so rsync sees it as changed on the
# next App-only build. Keep the validated embedded copy when the complete
# source tree, signing identity and locale selection are unchanged. The stamp
# lives in DerivedData, outside the app. Its CDHash binds it to the exact signed
# destination; signature verification also checks resources and nested code.
stamp="$TARGET_TEMP_DIR/open-cef-embed.stamp"
fingerprint="$(python3 - "$CEF_FW_SRC" "$SIGN_ID" "${OPEN_KEEP_LOCALES:-}" <<'PYTHON'
import hashlib, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
h = hashlib.sha256()
for setting in sys.argv[2:]:
    h.update(setting.encode() + b'\0')
for path in sorted(root.rglob('*')):
    h.update(str(path.relative_to(root)).encode() + b'\0')
    if path.is_symlink():
        h.update(b'L' + os.readlink(path).encode() + b'\0')
    elif path.is_file():
        content = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b''):
                content.update(chunk)
        h.update(b'F' + content.digest())
    else:
        h.update(b'D')
print(h.hexdigest())
PYTHON
)"
framework="$DEST/Chromium Embedded Framework.framework"
cdhash() { codesign -d --verbose=4 "$framework" 2>&1 | sed -n 's/^CDHash=//p'; }
previous_fingerprint="$(sed -n '1p' "$stamp" 2>/dev/null || true)"
previous_cdhash="$(sed -n '2p' "$stamp" 2>/dev/null || true)"
if [[ "$previous_fingerprint" == "$fingerprint" && -n "$previous_cdhash" ]] \
    && codesign --verify --deep --strict "$framework" 2>/dev/null \
    && [[ "$(cdhash)" == "$previous_cdhash" ]]; then
  echo "Keeping unchanged signed Chromium Embedded Framework.framework"
else
  rsync "${rsync_args[@]}" "$CEF_FW_SRC/" "$framework/"
  echo "Signing Chromium Embedded Framework.framework"
  for lib in "$framework/Libraries/"*.dylib; do
    codesign --force --sign "$SIGN_ID" --timestamp=none "$lib"
  done
  codesign --force --sign "$SIGN_ID" --timestamp=none "$framework"
  codesign --verify --deep --strict "$framework"
  mkdir -p "$TARGET_TEMP_DIR"
  temporary_stamp="$(mktemp "$stamp.XXXXXX")"
  printf '%s\n%s\n' "$fingerprint" "$(cdhash)" > "$temporary_stamp"
  mv "$temporary_stamp" "$stamp"
fi

for suffix in "" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)"; do
  name="Open Helper$suffix.app"
  rsync -a --delete "$BUILT_PRODUCTS_DIR/$name/" "$DEST/$name/"
done
