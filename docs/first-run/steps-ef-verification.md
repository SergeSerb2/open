# Section 7 Steps E/F verification

M5, 2026-11-06. Engine `af4b3cc3ad1b42439b229d79c8f7a869b13b0d3165733fba6c023e202340d1a5`; runtime fingerprint code `49529fd0…`. All builds use `OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main` and `heavy.sh`. Screen runs use `lockf -k`; timing uses quiet → heavy → screen. No M1 on-screen run was made during the hold.

## Retained attempts

Earlier failures remain in the ignored `.re/c3` receipts. A later pass does not erase them. Loads are one/five/fifteen-minute averages at command entry and exit; suite row loads also remain in the raw JSON.

| Check / receipt | Result | Entry load | Exit load |
|---|---|---|---|
| `firstrun-1` | FAIL (exit 1) | 12.18 / 14.44 / 14.51 | 9.29 / 11.06 / 12.94 |
| `build-debug-2` | PASS | 9.15 / 10.89 / 12.81 | 8.74 / 10.71 / 12.72 |
| `build-main-release` | PASS | 8.74 / 10.71 / 12.72 | 11.21 / 11.45 / 12.75 |
| `build-branch-release` | PASS | 8.85 / 10.67 / 12.68 | 11.19 / 11.44 / 12.74 |
| `firstrun-2` | FAIL (exit 1) | 9.46 / 11.05 / 12.58 | 5.22 / 9.43 / 11.84 |
| `build-debug-final` | PASS | 5.78 / 8.91 / 11.50 | 7.42 / 9.01 / 11.45 |
| `build-main-release-2` | PASS | 5.78 / 8.91 / 11.50 | 10.72 / 9.66 / 11.46 |
| `build-release-final` | PASS | 9.78 / 9.37 / 11.44 | 8.29 / 9.15 / 11.13 |
| `firstrun-3` | PASS | 17.56 / 11.22 / 11.79 | 15.70 / 12.65 / 12.31 |
| `firstrun-4` | PASS | 14.57 / 12.55 / 12.28 | 13.47 / 11.99 / 12.04 |
| `firstrun-5` | PASS | 15.85 / 12.73 / 12.31 | 16.87 / 13.92 / 12.81 |
| `build-openkit` | PASS | 10.99 / 12.77 / 12.44 | 17.53 / 14.88 / 13.33 |
| `secrets-fixture` | PASS | 9.21 / 12.94 / 12.74 | 9.21 / 12.94 / 12.74 |
| `build-release-cache-bound` | PASS | 9.06 / 12.77 / 12.68 | 9.83 / 12.31 / 12.51 |
| `real-dry-run` | FAIL (exit 1) | 17.47 / 14.26 / 13.24 | 16.10 / 14.66 / 13.49 |
| `timing` | INTERRUPTED (queued; no measurement) | 10.27 / 12.28 / 12.50 | 5.92 / 10.56 / 12.02 |
| `real-archive-diagnostic` | FAIL (exit 1) | 7.29 / 11.74 / 12.51 | 10.66 / 9.82 / 11.39 |
| `build-debug-archive` | PASS | 9.32 / 9.84 / 11.15 | 10.13 / 10.02 / 11.17 |
| `build-release-archive` | PASS | 8.17 / 9.41 / 10.87 | 11.47 / 9.89 / 10.86 |
| `firstrun-6` | FAIL (exit 1) | 13.19 / 10.37 / 11.01 | 28.36 / 16.32 / 13.25 |
| `real-dry-run-final` | PASS | 15.85 / 11.02 / 11.23 | 28.36 / 16.32 / 13.25 |
| `commandbar-1` | FAIL (exit 1) | 16.40 / 15.04 / 12.97 | 13.31 / 14.45 / 12.83 |
| `firstrun-7` | PASS | 16.40 / 15.04 / 12.97 | 8.84 / 12.42 / 12.20 |
| `timing-2` | INTERRUPTED (queued; no measurement) | 10.94 / 13.84 / 12.64 | 4.05 / 7.63 / 10.03 |
| `build-debug-ruling` | FAIL (exit 65) | 5.76 / 7.29 / 9.67 | 8.54 / 7.49 / 9.45 |
| `build-debug-ruling-2` | FAIL (exit 65) | 16.62 / 9.58 / 10.11 | 17.21 / 13.63 / 11.76 |
| `build-debug-ruling-3` | FAIL (exit 65) | 15.52 / 13.47 / 11.75 | 14.78 / 13.38 / 11.74 |
| `build-debug-ruling-4` | PASS | 13.00 / 13.20 / 11.77 | 13.19 / 13.22 / 11.81 |
| `build-release-ruling` | PASS | 11.31 / 12.80 / 11.68 | 8.69 / 11.49 / 11.30 |
| `icon-prepare` | INTERRUPTED (queued; no measurement) | 9.61 / 11.37 / 11.26 | 14.99 / 13.35 / 12.09 |
| `build-debug-history-proof` | PASS | 14.99 / 13.35 / 12.09 | 13.82 / 13.20 / 12.08 |
| `build-release-history-proof` | PASS | 15.83 / 13.79 / 12.33 | 11.81 / 13.26 / 12.31 |
| `fingerprint-debug-head` | PASS | 12.95 / 12.31 / 12.01 | 12.95 / 12.31 / 12.01 |
| `fingerprint-release-head` | PASS | 12.95 / 12.31 / 12.01 | 13.67 / 12.47 / 12.07 |
| `build-main-current-release` | PASS | 7.82 / 11.68 / 11.79 | 14.86 / 12.84 / 12.21 |
| `fingerprint-main-current` | PASS | 16.75 / 13.41 / 12.43 | 17.15 / 13.60 / 12.51 |
| `verify-offscreen` | PASS | 16.75 / 13.41 / 12.43 | 13.78 / 15.99 / 13.88 |
| `real-cli-head` | PASS | 7.98 / 13.51 / 13.13 | 7.98 / 13.51 / 13.13 |
| `preview-offscreen` | PASS | 7.98 / 13.51 / 13.13 | 7.20 / 12.59 / 12.81 |
| `secrets-fixture-head` | PASS | 5.78 / 11.42 / 12.36 | 5.78 / 11.42 / 12.36 |

The first Debug attempt (`build-debug-1.log`) succeeded against the expected engine root, but its loads were not recorded. The final wrapped Debug and Release builds supersede it. The empty `build-baseline.log` contains no completed check.

The original first-run failures were harness import resolution, a Settings Choose/probe race, then a transient Vision `CRImageReaderError` code 1. The socket-timeout report from the #195 merge is retained in the task handoff. Only inspect gets 180 seconds; OCR gets one 250 ms retry for the named decoder error.

The first icon run applied matching 1024 px pixels but failed the old total-main <5 ms assertion: worker 0.595 ms, main 21.586 ms, load 13.86 / 14.58 / 12.86. The lead changed acceptance to main decode/preparation <5 ms with setter cost reported, after one off-main TIFF preparation attempt.

The first real-data repeat failed: it added one tab. A diagnostic then proved one startup-archived Today tab and one removed live ID already in ArchiveStore. The repeat reported one added tab, but none of the removed Today IDs was live in the subsequent snapshot. The diagnostic assertion failed on that post-repeat live count; it is retained as a failure. The source has only one Today tab. The final real-data repeat adds zero.

Two queued timing attempts were canceled. The second exposed a priority/slot cycle: its flag blocked screen checks that held all four heavy slots while it waited for a slot. Only this child's queued process group and flag were removed. The runner now creates priority only after it owns its heavy slot.

## Real-data dry run (counts only)

Private copies only; every temporary source and Open root was deleted. Sidebar: 60/60 accounted, 6 Spaces, 31 pinned tabs, 1 Today tab, 11 Favorites, 2 folders, 1 split. Archive: 23/23 accounted, 21 inserted, 1 easel skipped, 1 unknown source skipped. History: 51 + 24 = 75 inserted, then 0 on repeat; 75 duplicates. Secret dry run: 0 login rows, 38 + 20 cookie rows, 30 + 27 address rows, 0 stored; Keychain not requested. App: 43 tabs/Favorites, 21 archive records, 75 visits, no failures. Repeat: 0 Spaces/tabs/Favorites/folders/archive/history added. `importAll` took 3.279 ms on main at load 28.36 / 16.32 / 13.25. No large-graph main-thread hitch was observed.

## Final checks under the screen hold

Implementation source is `d2e94efc`, with `c6e05c94` main merged. Later changes are documentation and the suite header only. Debug, automation Release and the unchanged-main Release comparison App build successfully. All three engine fingerprint checks pass for `af4b3cc3…`. No on-screen job or App launch ran after the lead's hold at 14:29:40; the queued icon job never acquired the quiet lock or launched a process.

The selected M5 verification is **15 PASS, 0 FAIL, 0 SKIP**, including the package build. It is not the required full gate. Only commands that open no windows were selected. Each row below records entry and exit one/five/fifteen-minute load averages.

| Offscreen gate | Result | Entry load | Exit load |
|---|---|---|---|
| `build` | PASS | 16.75 / 13.41 / 12.43 | 27.65 / 17.87 / 14.26 |
| `commands-demo` | PASS | 27.65 / 17.87 / 14.26 | 26.24 / 17.74 / 14.24 |
| `roundtrip` | PASS | 26.24 / 17.74 / 14.24 | 26.24 / 17.74 / 14.24 |
| `suggest-check` | PASS | 26.24 / 17.74 / 14.24 | 22.43 / 17.55 / 14.27 |
| `commands-dump` | PASS | 22.43 / 17.55 / 14.27 | 22.43 / 17.55 / 14.27 |
| `route` | PASS | 22.43 / 17.55 / 14.27 | 21.04 / 17.35 / 14.22 |
| `favicons` | PASS | 21.04 / 17.35 / 14.22 | 21.04 / 17.35 / 14.22 |
| `media-demo` | PASS | 21.04 / 17.35 / 14.22 | 20.23 / 17.24 / 14.20 |
| `sleep-demo` | PASS | 20.23 / 17.24 / 14.20 | 20.23 / 17.24 / 14.20 |
| `adblock-perf` | PASS | 20.23 / 17.24 / 14.20 | 20.23 / 17.24 / 14.20 |
| `adblock-catalog` | PASS | 20.23 / 17.24 / 14.20 | 20.23 / 17.24 / 14.20 |
| `profiles` | PASS | 20.23 / 17.24 / 14.20 | 20.23 / 17.24 / 14.20 |
| `commandbar-render` | PASS | 20.23 / 17.24 / 14.20 | 14.55 / 16.18 / 13.94 |
| `boosts` | PASS | 14.55 / 16.18 / 13.94 | 13.78 / 15.99 / 13.88 |
| `import-arc` | PASS | 13.78 / 15.99 / 13.88 | 13.78 / 15.99 / 13.88 |

The full `settings-preview check` opens the Essential Shortcuts window, so it was not run during the hold. The filtered checks below use the existing preview interface. They do not replace real-App proof. The offscreen renderer produced all **226 PNGs**. Its consent-bearing-plan and simulated-Keychain counters are both zero (preview adapter only).

| Preview command | Result | Entry load | Exit load |
|---|---|---|---|
| `check --only first-run-actions-and-adapter-gate` | PASS | 7.98 / 13.51 / 13.13 | 7.98 / 13.51 / 13.13 |
| `check --only first-run-probe` | PASS | 7.98 / 13.51 / 13.13 | 7.98 / 13.51 / 13.13 |
| `check --only first-run-count-parity` | PASS | 7.98 / 13.51 / 13.13 | 7.98 / 13.51 / 13.13 |
| `check --only import-counts` | PASS | 7.98 / 13.51 / 13.13 | 7.98 / 13.51 / 13.13 |
| `check --only app-icon` | PASS | 7.98 / 13.51 / 13.13 | 7.98 / 13.51 / 13.13 |
| `render (226 PNGs)` | PASS | 7.98 / 13.51 / 13.13 | 7.20 / 12.59 / 12.81 |

The current release `openkit` real-data CLI run passed every command below. Each uses a private source copy and private output. Both History repeat imports inserted zero. Both secret commands were dry runs and reported Keychain not requested; stored count was zero. Source and output copies were removed, including on failure. Load is recorded at each command's completion.

| Real-data CLI | Result | Load |
|---|---|---|
| `import-arc #1` | PASS | 7.98 / 13.51 / 13.13 |
| `import-arc-history #2` | PASS | 7.98 / 13.51 / 13.13 |
| `import-arc-history #3` | PASS | 7.98 / 13.51 / 13.13 |
| `import-arc-secrets #4` | PASS | 7.98 / 13.51 / 13.13 |
| `import-arc-history #5` | PASS | 7.98 / 13.51 / 13.13 |
| `import-arc-history #6` | PASS | 7.98 / 13.51 / 13.13 |
| `import-arc-secrets #7` | PASS | 7.98 / 13.51 / 13.13 |

The synthetic secrets CLI also passed with no Keychain request. Its 13 login, 12 cookie, 4 card and 4 address fixture rows exercise the existing consent-free known-key validation path; nothing is stored.

| Static check | Result | Entry load | Exit load |
|---|---|---|---|
| `static-checks: python3 -m py_compile` | PASS | 12.86 / 13.16 / 11.78 | 12.86 / 13.16 / 11.78 |
| `static-checks: git diff --check` | PASS | 12.86 / 13.16 / 11.78 | 12.86 / 13.16 / 11.78 |
| `static-final: python3 -m py_compile` | PASS | 4.43 / 9.84 / 11.69 | 4.43 / 9.84 / 11.69 |
| `static-final: git diff --check` | PASS | 4.43 / 9.84 / 11.69 | 4.43 / 9.84 / 11.69 |

Earlier real-App evidence remains qualified by its source revision: first-run runs 3, 4 and 5 passed 48 rows each; run 7 passed 52 rows, including old Today persistence, zero-tab repeat, manually archived tab/Favorite exclusion and Settings-added Today age. These passes predate the final OCR retry and delayed icon setter. They are not final-head acceptance. The old Today fixture now also asserts `autoArchiveAfter == twelveHours` and clears the unrelated Never sleep preference. The stronger F9 fixture pauses before the real History transaction and requires zero imported visits and incomplete progress while browsing.

## Open work before the PR

- Wait for an explicit screen-clear signal; do not dismiss either machine's crash dialog.
- Run three consecutive `firstrun` suites on the final App, plus `shell`, `features`, `routing`, and `commandbar` (Settings icon rows).
- Measure the final icon worker preparation and main setter separately. Main decode/preparation target is below 5 ms; report setter cost and accept it per the lead's ruling. Default icon must do zero restore work.
- Run the five-sample quiet Release F12 receipt and interleaved unchanged-main normal launch comparison; report the 250 ms and 700 ms targets honestly.
- Run the saved unchanged-main negative controls and final real-data App dry run on a temporary root. Keep the raw earlier failure.
- Run the full `settings-preview` and M5 `tools/verify-all.sh`; the 15-row selected pass is not the full gate.
- Complete the review checklist, add the PR links to status, then open the requested PR. Do not merge.

## Review checklist checkpoint

| Item | State | Evidence / remaining proof |
|---|---|---|
| External input and decoded allocation bounds | PASS (source; final runtime pending) | Source directory 255 UTF-8 bytes; cached PNG 16 MiB and exactly 1024×1024; at most 8 MiB decoded pixels; existing reader bounds and one 5,000-row batch. Missing/oversized cache rows passed before the last icon change. |
| Lifetimes and callbacks | PASS (source; final runtime pending) | Runner retains flow after panel close; selection generation and shutdown guards cancel stale icon application; archive lookups await the sink queue. Earlier F9 close/merge Undo rows pass. |
| Real event and focus paths | PENDING | No new key route. Required App regressions and native pixel equality await the screen clear. |
| Checks prove the change and clean up | PENDING | Raw real-data failure retained; earlier positive old-Today/manual-archive rows pass. Saved old-code negative controls and final-head reruns remain blocked. Every suite owns a temporary root and restores changed shared defaults in `finally`. |
| UI and motion | N/A | No new design or motion. One delayed utility-priority icon setter is one-shot; default icon creates no task. |
| Docs and comments | PASS | Current limits, icon cost ruling, source-age rule and screen-hold gaps are recorded. |

## Decisions for the lead

- An unreadable archive-ID lookup keeps the current live model and uses the existing import failure path; it does not risk restoring archived items.
- A missing or invalid alternate-icon cache asks for reselection instead of rendering SwiftUI artwork at launch.
- Unknown failed History source counts report only the visits known from the probe; no count is invented. Unmapped source Profiles are counted and are not merged into Default.
