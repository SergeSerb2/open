`icon.svg` is Open's own doorway-and-sun mark, flat, for the README. The App
icon is built from the same shapes as macOS 26 Icon Composer documents, so the
system draws the squircle, rim, glass and shadow, as it does for Apple's icons.

- `App/Resources/AppIcon.icon` is the bundle icon: a vertical blue gradient
  fill, a white doorway layer and an orange sun layer, with a navy fill and
  white doorway in the Dark appearance. Xcode's `actool` compiles it into
  `Assets.car` and `AppIcon.icns`; `project.yml` selects `AppIcon`.
- `assets/app-icons/<option>.icon` are the five alternates of the App Icon
  picker (Midnight, Daylight, Graphite, Spectrum, Notebook). Open sets them at
  run time, and macOS shows a runtime icon as is, so each is committed as the
  system's own 1024 px render, `App/Resources/AppIcons/<option>.png`.

Edit the documents in Xcode's Icon Composer, or as JSON and SVG. Then
regenerate the alternate renders (macOS 26+, Default icon style):

```sh
tools/generate-app-icons.sh
```

Check every appearance of a document with Xcode's `ictool`, for example:

```sh
"$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool" \
  App/Resources/AppIcon.icon --export-image --output-file /tmp/dark.png \
  --platform macOS --rendition Dark --width 512 --height 512 --scale 2
```
