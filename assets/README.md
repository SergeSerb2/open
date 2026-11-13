`icon.svg` is Open's own doorway-and-sun mark, based on the existing App Icon
picker artwork. The transparent margin is part of the macOS bundle icon.

The ten macOS AppIcon PNGs (16–1024 pixels) and `App/Resources/Open.icns` are
committed, so builds do not need a renderer or network access. Regenerate on macOS:

```sh
npm install --prefix .re/icon-renderer --no-save --package-lock=false @resvg/resvg-js@2.6.2
NODE_PATH="$PWD/.re/icon-renderer/node_modules" node tools/generate-app-icon.cjs
```

Xcode compiles the catalog into `Assets.car`. `project.yml` selects `AppIcon`
for all configurations. The plist also declares the standalone ICNS fallback.
