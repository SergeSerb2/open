# Open: rules for agents

Open is a macOS browser that replicates Arc (The Browser Company) as close to 1:1 as possible in design, sidebar features, and hotkeys. Arc is being sunset. Open has no Arc account, login, or sync. The internal architecture is our own, and the top engineering goal is a lightweight, fast, snappy app.

Reference build: Arc 1.170.0 (build 89123) at `/Applications/Arc.app`. Its engine, `ArcCore.framework`, is a Chromium 156.0.8078.48 fork.

## Locked decisions

- Engine: our own Chromium fork. Base: Chromium 156.0.8078.48 (the same version as Arc) with CEF branch 8078's embedding layer inside the fork, plus our own patches. The repo stores pinned versions and patch files, not a Chromium mirror. Local source tree: `~/Developer/open-engine/chromium_git` (shared; never run `gclient sync` or a build there unless your task says so).
- The Swift shell talks only to the `OpenEngine` layer, never to Chromium or CEF directly.
- Chrome Web Store extensions must work in v1 at Arc level: our own toolbar actions and popups, and `chrome.tabs` that sees our sidebar tabs.
- Platform: macOS 26+ only. Native Swift 6 + AppKit. SwiftUI only where it is cheap and does not hurt performance. Keep Arc's look, not Liquid Glass.
- v1 scope: sidebar, Spaces, pinned and today tabs, favorites, folders, auto-archive, command bar, all Arc hotkeys, Split View, Peek, Little Arc, Profiles, Air Traffic Control, Boosts, Zap, Site Control Center, ad blocking, Import from Arc, extensions. Out of scope: Easels, Notes, Arc Max AI, Arc accounts, sync.

## Hard rules

1. Never copy Arc's assets or code into this repo. This includes icons, images, sounds, Lottie animations, fonts, nib files, and decompiled code. We recreate every asset ourselves. Facts are fine: names, sizes, spacing, colors, corner radii, durations, curves, behaviors, settings keys, file schemas, and shortcuts.
2. Put raw reverse-engineering output (dumps, decoded nibs, decompiler output, extracted files) in `.re/`. It is git-ignored. Write committed findings in `docs/re/` in your own words.
3. Treat `/Applications/Arc.app` as read-only. Do not modify, re-sign, or copy the bundle into the repo.
4. Do not launch Arc.app. Do not drive the user's mouse, keyboard, or desktop (no computer use). The user signs in to Arc and uses it themselves.
5. Read Arc user data only from `~/Library/Application Support/Arc` and only read-only. Never commit the user's personal data (URLs, titles, profile files). Commit schemas and redacted examples only.
6. Do not write unit tests. Verify work end to end: build the real app, run it, and exercise the real flow.
7. Cite evidence in every reverse-engineering finding: the rea command, symbol, string, or file that proves it. Mark guesses as guesses.
8. Do not spawn subagents or delegate tasks yourself. The lead agent controls how many agents run at once.
9. Start long-running jobs (engine builds, syncs) in their own session (for example `python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' <cmd>`), so an app restart does not kill them.

## Reverse-engineering tools

Run `source tools/rea-env.sh` before you use `rea`. It sets the Node, Ghidra, and Java paths.

- Prefer fast metadata tools first: `rea inspect-macho`, `rea inspect-native-dispatch-metadata`, `rea decode-interface-builder`, `rea inspect-asset-catalog`, `rea inspect-plist`, `rea demangle-swift`, plus `nm`, `strings`, `otool`, `xcrun swift-demangle`, `xcrun assetutil`, `plutil`.
- Deep analysis (`rea search`, `rea decompile`, `rea function`, `rea xrefs`) uses Ghidra. Never start your own Ghidra analysis of the Arc main binary or ArcCore. Use the shared snapshots listed in `docs/re/README.md`.
- Output can be huge. Use `--token-limit`, `--filter-output`, and `--format json` piped to files in `.re/`, then read only what you need.

## Code conventions

- Swift 6 with strict concurrency. AppKit views for the sidebar, tab rows, and the window chrome.
- Minimal third-party dependencies. Each one needs a written reason in the PR.
- Performance budgets matter: cold launch, tab switch latency, sidebar scroll at 120 Hz, and idle CPU near zero.
- Work on feature branches. Open one PR per milestone against `main`.
