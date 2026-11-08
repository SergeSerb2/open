#!/usr/bin/env bash
# Xcode runs this before signing the App. Direct Xcode builds verify pins too.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/tools/fetch-adblock-lists.sh"
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/AdBlock"
mkdir -p "$DEST"
for name in easylist.txt easyprivacy.txt; do
  cp "$ROOT/Vendor/adblock/$name" "$DEST/$name"
done
