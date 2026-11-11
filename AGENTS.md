# Open: rules for agents

Open is a macOS browser that replicates Arc (The Browser Company) as close to 1:1 as possible in design, sidebar features, and hotkeys. Arc is being sunset. Open has no Arc account, login, or sync. The internal architecture is our own, and the top engineering goal is a lightweight, fast, snappy app.

Installed Arc: 1.172.2 (build 90755) at `/Applications/Arc.app`. The unmodified Arc 1.170.0 (build 89123) static reference is at `~/Library/Caches/OpenRE/arc-reference/`; its engine, `ArcCore.framework`, is a Chromium 156.0.8078.48 fork.

## Locked decisions

- Naming: user-visible text never uses the Arc brand. Arc's "Little Arc" is "Little Open" in Open. Exception: "Import from Arc". Search aliases may include Arc's old names.
- Engine: our own Chromium fork. Base: Chromium 156.0.8078.48 (the same version as Arc) with CEF branch 8078's embedding layer inside the fork, plus our own patches. The repo stores pinned versions and patch files, not a Chromium mirror. Local source tree: `~/Developer/open-engine/chromium_git` (shared; never run `gclient sync` or a build there unless your task says so).
- The Swift shell talks only to the `OpenEngine` layer, never to Chromium or CEF directly.
- Chrome Web Store extensions must work in v1 at Arc level: our own toolbar actions and popups, and `chrome.tabs` that sees our sidebar tabs.
- Platform: macOS 26+ only. Native Swift 6 + AppKit. SwiftUI only where it is cheap and does not hurt performance. Keep Arc's look, not Liquid Glass.
- Scope (user decision, 2026-11-10): every Arc feature. This includes the sidebar, Spaces, pinned and today tabs, favorites, folders, auto-archive, the Library overlay (Downloads, Archive, History, Media, Spaces, Boosts), command bar, all Arc hotkeys, Split View, Peek, Little Open, Profiles, Air Traffic Control, Boosts, Zap, Site Control Center, ad blocking, Import from Arc, extensions, Easels, Notes, Live Folders, Calendar preview and Join Meeting, live-data hover previews, Library folder sources, import from Safari, Chrome, and Firefox, and Widevine (if licensing allows). Out of scope for good: Arc Max AI, Arc accounts, sync.
- Safe Browsing: off (user decision, 2026-11-10).
- Settings uses Open’s original navigation, cards, and controls (user decision, 2026-11-10). It is an explicit exception to the Arc-parity design rule; existing settings, actions, stores, and guards remain.
- Onboarding and the Welcome page keep Open's own identity (the doorway-and-sun mark). They must reach Arc's level of visual quality, not copy Arc's look.

## Hard rules

1. Never copy Arc's assets or code into this repo. This includes icons, images, sounds, Lottie animations, fonts, nib files, and decompiled code. We recreate every asset ourselves. Facts are fine: names, sizes, spacing, colors, corner radii, durations, curves, behaviors, settings keys, file schemas, and shortcuts.
2. Put raw reverse-engineering output (dumps, decoded nibs, decompiler output, extracted files) in `.re/`. It is git-ignored. Write committed findings in `docs/re/` in your own words.
3. Never modify or re-sign the Arc bundle, and never copy it into the repo. You may install an unmodified copy on the M1 for capture sessions.
4. Arc capture sessions are allowed and encouraged (user decision, 2026-11-10). An agent may launch Arc and drive it with scripted mouse and keyboard events (`uidrive`, `capture-loop.sh`, `axframes` in `~/Library/Caches/OpenRE/scripts/`) to record screenshots, accessibility trees, and timings. Conditions:
   - Only the agent that the lead assigns to capture runs a session. One session per machine at a time.
   - A session holds that machine's on-screen lock (`/tmp/open-onscreen-e2e.lock`) from start to end.
   - Prefer the M1 (nobody uses its screen). On the M5, run a session only when the user is away or agrees, because it takes over the mouse and keyboard.
   - Drive only Arc and Open windows. Do not touch other apps, System Settings, or Keychain dialogs. If a system permission or sign-in dialog appears, stop and tell the lead.
   - Find controls from the accessibility tree, not from fixed coordinates. Quit Arc when the session ends.
   - This rule covers capture of Arc only. Tests of Open still use the automation socket, never the system mouse or keyboard.
5. The user's Arc data on these machines is old test data. Capture sessions may use and change it (open tabs, start downloads, create Spaces). Outside a capture session, read `~/Library/Application Support/Arc` read-only. Deleting Arc's data to record a fresh first launch is allowed on the M1 only. Never commit the user's personal data (URLs, titles, profile files, captured frames). Commit schemas and redacted examples only.
6. Do not write unit tests. Verify work end to end: build the real app, run it, and exercise the real flow.
7. Cite evidence in every reverse-engineering finding: the rea command, symbol, string, file, or capture frame that proves it. Mark guesses as guesses. Do not build a user-visible surface from a guess when a capture session can settle it: capture first.
8. Only the lead spawns subagents. The lead gives each one a detailed written plan and sets its model explicitly (default: GPT-6.1-sol, xhigh). A subagent never spawns subagents.
9. Start long-running jobs (engine builds, syncs) in their own session (for example `python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' <cmd>`), so an app restart does not kill them.
10. Before you open a PR, and again when you report it ready to merge: merge `origin/main` into your branch. Run one full gate on the final functional head. After a later clean merge whose main changes are disjoint from your PR files, retain that receipt and run `--only build` plus your area checks on the merged head; overlapping files or a conflict require the full gate. Iterate with touched suites in Debug; use Release for timing and final artifacts. Record final-artifact hashes/manifests once, and run the five-launch timing set once per PR unless a timing change requires it again. Run the full `heavy.sh tools/verify-all.sh` merge lane, including every real-App suite and exact-head M1 receipts. All required checks must PASS; only exact BLOCKED/DEFERRED entries in `tools/verification/gate-exceptions.json` are allowed, with their original status and reason printed. Missing receipts, stale exceptions, FAIL, INTERRUPTED, and NOT_RUN fail the gate. SKIP is allowed only for targets that do not exist yet. Paste its summary and exception tables into the PR. Run the separate M1 `--lane observers` when the PR touches Site Control or an injected idle observer. `--no-e2e` is for intermediate pushes only and is never a PR-ready receipt. For intermediate pushes (review fixes, work in progress), run only the checks for the code you touched (`tools/verify-all.sh --only NAME[,NAME]` and the e2e suites you touched), and list them with their results in the PR. For `Package.swift` merge conflicts, keep both sides (each PR adds targets); never leave two definitions of one target.
11. Shared machine resources (user decision, 2026-11-10 23:30). The M5 has three FIFO build slots; the M1 has one. A normal `~/Library/Caches/OpenRE/scripts/heavy.sh <command>` takes one slot. Run all compilers and gates through it: `tools/verify-all.sh`, `tools/build.sh`, `swift build`, `xcodebuild`, engine/OpenKit builds, and scripts that call them. Nested calls use the existing slot. The M5 merge coordinator holds no outer ticket: each native/real-App stage (and its acceptance dependencies) re-queues through a fresh `heavy.sh` ticket, so FIFO waiters interleave. No A ticket may run longer than about 15 minutes while another agent waits; the dispatcher cancels an overrun through owned cleanup and retains the interrupted stage as unqualified (LEAD 08:00). Never add a private build lock. Timing and measurement jobs take every slot with `OPEN_HEAVY_EXCLUSIVE=1 heavy.sh <command>`; the strict-timing form `heavy.sh /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock <command>` and jobs from the performance worktree are exclusive automatically. Keep one screen slot per machine: `/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock <command>`, one suite per invocation and at most one waiting screen job per agent. A normal build and a screen job may overlap. Check `~/Library/Caches/OpenRE/scripts/queue.sh` before a long job and record waits over 10 minutes. `/tmp/open-heavy-holder` lists all holders, one tab-separated line per PID, with an optional fifth field for `build` or `exclusive`; never assume the first holder is yours. Per-holder records live in `/tmp/open-heavy-holders/<pid>`. Judge latency/CPU budgets on the M1 Release timing lane with both heavy and screen slots: two load1 readings ≤3.5 ten seconds apart before the sample (six-minute preflight cap); record other CPU for information, with no after-run load condition. While any timing job holds both M1 slots, nobody else runs builds, decodes, analyses or SSH polling loops there. M5 timing samples that miss the validity rule are INFO with the raw assertion and load ledger; valid M5 misses still fail. The exact M5 `onboarding/strict_120hz` display row retains its separate unchanged display rule (LEAD 08:43). Do not hold a slot while thinking, stop or adopt another agent's job, or bypass the queue. Keep M1 compilation at 6 of its 8 cores. Installed-script copies live in `tools/machine/`. Before any installed-script change, record the diff in A-questions.md and ask the lead; install only after the answer (LEAD 09:00). The lead's engine-release background job uses its separate background lock and reduces M5 normal slots to two during that build; A gates never use background mode. Never end your turn while a check you depend on is running; wait for it in the foreground.

## Working process

- Before you open a PR, run [docs/review-checklist.md](docs/review-checklist.md) on your change and put the result table in the PR body. A PR gets at most two review rounds; after that, the lead handles small leftovers.
- The engine agent owns the Chromium tree at `~/Developer/open-engine/chromium_git`. Only it edits, patches, or builds that tree. Other agents may work on engine PR branches for Swift, e2e, and docs changes that do not need a tree build.
- Report a PR ready as soon as it is green. The lead merges green PRs at once, bottom-up for stacked PRs, with merge commits.

### Machines

| Machine | Use it for | Do not use it for |
|---|---|---|
| M5 Pro (18 cores, 48 GB), the main machine, also the user's laptop | Engine builds (the only Chromium tree), static reverse engineering (Arc.app and the shared Ghidra snapshots), the merge gate, everything else | Arc capture sessions while the user works on it |
| M1 Pro (8 cores, 16 GB, built-in 2x display), an always-on machine that nobody uses at the screen | Arc capture sessions (first choice), App and OpenKit work, `tools/verify-all.sh`, on-screen e2e suites, real-window snapshots at 2x | Chromium builds or patches, Ghidra analysis |

The M1 builds the App against a copy of the M5's recorded engine distribution (the lead copies it after each engine distribution change). The M5 has three FIFO build slots and the M1 has one; each machine has one on-screen lock. Both machines push to the same GitHub repo; never work on one branch from both machines at once.

Display references (user decision, 2026-11-10 16:19): the M5 uses the external AW2726DM; the M1 uses its built-in 2x panel. The AW2726DM references are not retired: keep each reference whose display key still matches exactly, and record replacements for other keys. The M5's current mode is 2560×1440, 1x, 240 Hz. Check and record the mode before each M5 on-screen run. Visual references use the actual window screen's backing scale and ICC profile, with the mode recorded in the display key; unknown keys fail without fallback. The full gate that counts for merge runs on the M5. Display and strict-performance deferrals expired when the lead declared M5 panel ready; see `docs/verification.md`.

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
