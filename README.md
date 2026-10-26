<img src="assets/icon.svg" width="64" height="64" alt="">

# Open

Created in [T3 Code](https://t3.codes).

## Build and run

Requires macOS 26+, Xcode, and `brew install xcodegen cmake`.

```sh
tools/build.sh            # Debug: fetches CEF once, generates Open.xcodeproj, builds build/Debug/Open.app
tools/run.sh              # runs it (profile: ~/Library/Application Support/Open-Dev)
tools/build.sh Release    # OPEN_KEEP_LOCALES="en" ships only English Chromium locales
```

`tools/build.sh` builds against our Chromium fork's distribution ([engine fork guide](docs/engine-fork.md)); `CEF_SOURCE=cdn tools/build.sh` uses the pinned stock CDN build for comparisons. Docs: [architecture](docs/architecture.md), [engine API](docs/engine-api.md), [engine spike and verdict](docs/engine-spike.md), [fork patch plan](docs/engine-patches.md), [automation](docs/automation.md).
