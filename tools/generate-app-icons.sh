#!/usr/bin/env bash
# Regenerate the committed runtime App Icon images from their Icon Composer sources.
#
#   tools/generate-app-icons.sh
#
# For each assets/app-icons/<option>.icon: actool compiles it (as Xcode does for the bundle icon), a throwaway
# bundle in .re/ carries the result, and macOS renders that bundle's icon (NSWorkspace) at 1024 px. So each
# image has the system's own squircle, rim, glass and shadow, and the same transparent margin as the bundle
# icon. Open shows these files as is (Dock, Cmd-Tab, the Dock tile plug-in).
# The Dock draws a runtime image about 1.5 % smaller and lower than a bundle icon of the same art: on the M1 Dock
# (2x, default tile size), a system render shown as NSApp.applicationIconImage measured a 72.9 px wide plate with its
# top 0.6 px low, against Mail's 73.7 px; scaled 1.015 and lifted 5 px it measured 73.8 px, top within 0.4 px
# (.re/docksize sweep; tools/e2e/app_icons.py rows dock_size_* and dock_corner_* keep it there).
# Output: App/Resources/AppIcons/<option>.png. Run on macOS 26+ with the default (Light) icon style.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.re/app-icon-render"
OUT="$ROOT/App/Resources/AppIcons"
DOCK_SCALE=1.015 DOCK_LIFT=5
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
style="$(defaults read -g AppleIconAppearanceTheme 2>/dev/null || true)"
if [[ -n "$style" && "$style" != *Light* ]]; then
  echo "The system icon style is '$style'. Set it to Default (Light) first." >&2; exit 1
fi
rm -rf "$WORK"; mkdir -p "$WORK" "$OUT"
xcrun swiftc -O "$ROOT/tools/render-app-icon.swift" -o "$WORK/render-app-icon"
apps=()
cleanup() { for app in "${apps[@]+"${apps[@]}"}"; do "$LSREGISTER" -u "$app" 2>/dev/null || true; done; rm -rf "$WORK"; }
trap cleanup EXIT
for source in "$ROOT"/assets/app-icons/*.icon; do
  option="$(basename "$source" .icon)"
  app="$WORK/$option-$$.app"; apps+=("$app")
  mkdir -p "$app/Contents/Resources" "$app/Contents/MacOS"
  xcrun actool --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 \
    --app-icon "$option" --target-device mac --output-partial-info-plist "$WORK/$option.plist" \
    --errors --warnings "$source" >"$WORK/$option-actool.log"
  cp /usr/bin/true "$app/Contents/MacOS/icon"
  # A unique identifier per run, so LaunchServices never serves an earlier render from its icon cache.
  /usr/libexec/PlistBuddy -c "Add CFBundleIdentifier string io.github.sergeserb2.open.icon-render.$option.$$" \
    -c "Add CFBundleIconName string $option" -c "Add CFBundleIconFile string $option" \
    -c "Add CFBundlePackageType string APPL" -c "Add CFBundleExecutable string icon" \
    -c "Add LSMinimumSystemVersion string 26.0" "$app/Contents/Info.plist" >/dev/null
  "$LSREGISTER" -f "$app"
  "$WORK/render-app-icon" "$app" "$OUT/$option.png" "$DOCK_SCALE" "$DOCK_LIFT"
done
ls -l "$OUT"
