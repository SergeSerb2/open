# Open: rules for agents

Open is a macOS browser that replicates Arc (The Browser Company) as close to 1:1 as possible in design, sidebar features, and hotkeys. Arc is being sunset. Open has no Arc account, login, or sync. The internal architecture is our own, and the top engineering goal is a lightweight, fast, snappy app.

Reference build: Arc 1.170.0 (build 89123) at `/Applications/Arc.app`. Its engine, `ArcCore.framework`, is a Chromium 156.0.8078.48 fork.

## Locked decisions

- Naming: user-visible text never uses the Arc brand. Arc's "Little Arc" is "Little Open" in Open. Exception: "Import from Arc". Search aliases may include Arc's old names.
- Engine: our own Chromium fork. Base: Chromium 156.0.8078.48 (the same version as Arc) with CEF branch 8078's embedding layer inside the fork, plus our own patches. The repo stores pinned versions and patch files, not a Chromium mirror. Local source tree: `~/Developer/open-engine/chromium_git` (shared; never run `gclient sync` or a build there unless your task says so).
- The Swift shell talks only to the `OpenEngine` layer, never to Chromium or CEF directly.
- Chrome Web Store extensions must work in v1 at Arc level: our own toolbar actions and popups, and `chrome.tabs` that sees our sidebar tabs.
- Platform: macOS 26+ only. Native Swift 6 + AppKit. SwiftUI only where it is cheap and does not hurt performance. Keep Arc's look, not Liquid Glass.
- v1 scope: sidebar, Spaces, pinned and today tabs, favorites, folders, auto-archive, command bar, all Arc hotkeys, Split View, Peek, Little Open, Profiles, Air Traffic Control, Boosts, Zap, Site Control Center, ad blocking, Import from Arc, extensions. Out of scope: Easels, Notes, Arc Max AI, Arc accounts, sync.

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
10. Before you open a PR, and again when you report it ready to merge: merge `origin/main` into your branch, then run the full `tools/verify-all.sh` (all checks PASS; SKIP only for targets that do not exist yet). Paste its summary table into the PR. For intermediate pushes (review fixes, work in progress), run only the checks for the code you touched (`tools/verify-all.sh --only NAME[,NAME]` and the e2e suites you touched), and list them with their results in the PR. For `Package.swift` merge conflicts, keep both sides (each PR adds targets); never leave two definitions of one target.
11. Shared machine resources. Run every `tools/verify-all.sh`, `tools/build.sh`, and `swift build` as `~/Library/Caches/OpenRE/scripts/heavy.sh <command>`. It waits for one of the machine's heavy slots. Run every command that opens Open windows on screen (e2e suites, real-window snapshots, real-window benches) as `/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock <command>`, one suite per invocation, never while you build. Never end your turn while a check you depend on is still running: wait for it in the foreground.

## Working process

- Before you open a PR, run [docs/review-checklist.md](docs/review-checklist.md) on your change and put the result table in the PR body. A PR gets at most two review rounds; after that, the lead handles small leftovers.
- The engine agent owns the Chromium tree at `~/Developer/open-engine/chromium_git`. Only it edits, patches, or builds that tree. Other agents may work on engine PR branches for Swift, e2e, and docs changes that do not need a tree build.
- Report a PR ready as soon as it is green. The lead merges green PRs at once, bottom-up for stacked PRs, with merge commits.

### Machines

| Machine | Use it for | Do not use it for |
|---|---|---|
| M5 Pro (18 cores, 48 GB), the main machine | Engine builds (the only Chromium tree), reverse engineering (Arc.app and the shared Ghidra snapshots), everything else | — |
| M1 Pro (8 cores, 16 GB, built-in 2x display), the second machine | App and OpenKit work, `tools/verify-all.sh`, on-screen e2e suites, real-window snapshots at 2x | Chromium builds or patches, reverse engineering of Arc |

The M1 builds the App against a copy of the M5's recorded engine distribution (the lead copies it after each engine distribution change). Each machine has its own heavy slots and its own on-screen lock. Both machines push to the same GitHub repo; never work on one branch from both machines at once. Until the verify gates are portable (`docs/followups.md`, "Verification (portability)"), four checks fail on the M1 for machine reasons only: `space-legacy`, `space-editor` (P1 byte-identical PNGs), `sidebar-compare` (3 color gates), and `suggest-check` #31 (real-time budget). On the M1, report those four as "M1 baseline" and run the full gate that counts for merge on the M5.

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
