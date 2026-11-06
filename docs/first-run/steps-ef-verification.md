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
| `timing-final` | FAIL first content; PASS paint and no regression | 5.29 / 4.55 / 4.71 | 6.98 / 4.99 / 4.87 |
| `icon-final` | PASS | 7.06 / 5.08 / 4.90 | 7.46 / 5.19 / 4.94 |
| `firstrun-final-1` | PASS | 6.33 / 5.10 / 4.91 | 5.93 / 5.28 / 5.00 |
| `firstrun-final-2` | PASS | 5.93 / 5.28 / 5.00 | 6.56 / 5.67 / 5.18 |
| `firstrun-final-3` | PASS | 6.56 / 5.67 / 5.18 | 6.78 / 5.85 / 5.29 |
| `shell-final` | PASS | 6.78 / 5.85 / 5.29 | 6.04 / 5.77 / 5.28 |
| `fingerprint-old-control` | PASS | 6.30 / 5.83 / 5.33 | 6.30 / 5.83 / 5.33 |
| `features-final` | PASS | 6.04 / 5.77 / 5.28 | 6.18 / 5.82 / 5.33 |
| `routing-final` | PASS | 6.18 / 5.82 / 5.33 | 7.46 / 6.15 / 5.47 |
| `commandbar-final` | PASS | 7.46 / 6.15 / 5.47 | 7.49 / 6.27 / 5.54 |
| `old-code-proof` | FAIL (exit 1) | 7.05 / 6.20 / 5.52 | 6.03 / 6.04 / 5.48 |
| `old-code-proof-2` | PASS | 5.46 / 5.90 / 5.44 | 5.46 / 5.90 / 5.44 |
| `real-dry-run-head` | PASS | 5.98 / 5.99 / 5.48 | 6.30 / 6.06 / 5.50 |
| `verify-final` | PASS | 9.46 / 6.81 / 5.79 | 9.21 / 8.78 / 7.42 |

The first Debug attempt (`build-debug-1.log`) succeeded against the expected engine root, but its loads were not recorded. The final wrapped Debug and Release builds supersede it. The empty `build-baseline.log` contains no completed check.

The original first-run failures were harness import resolution, a Settings Choose/probe race, then a transient Vision `CRImageReaderError` code 1. The socket-timeout report from the #195 merge is retained in the task handoff. Only inspect gets 180 seconds; OCR gets one 250 ms retry for the named decoder error.

The first icon run applied matching 1024 px pixels but failed the old total-main <5 ms assertion: worker 0.595 ms, main 21.586 ms, load 13.86 / 14.58 / 12.86. The lead changed acceptance to main decode/preparation <5 ms with setter cost reported, after one off-main TIFF preparation attempt.

The first real-data repeat failed: it added one tab. A diagnostic then proved one startup-archived Today tab and one removed live ID already in ArchiveStore. The repeat reported one added tab, but none of the removed Today IDs was live in the subsequent snapshot. The diagnostic assertion failed on that post-repeat live count; it is retained as a failure. The source has only one Today tab. The final real-data repeat adds zero.

Two queued timing attempts were canceled. The second exposed a priority/slot cycle: its flag blocked screen checks that held all four heavy slots while it waited for a slot. Only this child's queued process group and flag were removed. The runner now creates priority only after it owns its heavy slot.

## Earlier real-data dry run (counts only)

Private copies only; every temporary source and Open root was deleted. Sidebar: 60/60 accounted, 6 Spaces, 31 pinned tabs, 1 Today tab, 11 Favorites, 2 folders, 1 split. Archive: 23/23 accounted, 21 inserted, 1 easel skipped, 1 unknown source skipped. History: 51 + 24 = 75 inserted, then 0 on repeat; 75 duplicates. Secret dry run: 0 login rows, 38 + 20 cookie rows, 30 + 27 address rows, 0 stored; Keychain not requested. App: 43 tabs/Favorites, 21 archive records, 75 visits, no failures. Repeat: 0 Spaces/tabs/Favorites/folders/archive/history added. `importAll` took 3.279 ms on main at load 28.36 / 16.32 / 13.25. No large-graph main-thread hitch was observed.

## Earlier offscreen checks during the screen hold

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

## Final M5 App checks

The lead cleared the M5 at 15:35. The M1 stayed on hold and was not used.
The final App source is `ec58d9fe` (implementation `d2e94efc`), with main
`c6e05c94` already merged. No implementation changed after the lead accepted it.
Each suite below ran separately under the screen lock. Every engine fingerprint
passed for `af4b3cc3…`; code fingerprint was `49529fd0…`. Cleanup left no owned
App windows or processes. No unit test or desktop input was used.

| Suite | Result | Entry load | Exit load |
|---|---|---|---|
| `firstrun-final-1` | PASS (52/52 rows) | 6.33 / 5.10 / 4.91 | 5.93 / 5.28 / 5.00 |
| `firstrun-final-2` | PASS (52/52 rows) | 5.93 / 5.28 / 5.00 | 6.56 / 5.67 / 5.18 |
| `firstrun-final-3` | PASS (52/52 rows) | 6.56 / 5.67 / 5.18 | 6.78 / 5.85 / 5.29 |
| `shell-final` | PASS (7/7 rows) | 6.78 / 5.85 / 5.29 | 6.04 / 5.77 / 5.28 |
| `features-final` | PASS (19/19 rows) | 6.04 / 5.77 / 5.28 | 6.18 / 5.82 / 5.33 |
| `routing-final` | PASS (9/9 rows) | 6.18 / 5.82 / 5.33 | 7.46 / 6.15 / 5.47 |
| `commandbar-final` | PASS (77/77 rows) | 7.46 / 6.15 / 5.47 | 7.49 / 6.27 / 5.54 |

All three consecutive first-run runs passed 52 functional rows. They include
the live WAL writer, a 5,000-visit pending transaction while a real page opens
and saves, progress-window close, exact-once History, E-2, normal twelve-hour
auto-archive with a 48-hour-old source Today tab, zero-tab re-import, manual
archive of a tab and former Favorite, and a Settings-added Today tab surviving
relaunch. Source timestamps/files stay unchanged. The unrelated Never-policy
regression row does not set the Today fixture to Never.

The inspect-only deadline remains 180 seconds, and Vision's named decoder
failure gets one 250 ms retry. The earlier raw Vision failure remains above.
The three final runs each inspected six screens and used zero OCR retries;
they prove consecutive successful flows, not forced reproduction of the
transient Vision error. Password capability stays OFF. F10 proves zero secret
API/consent construction by the App code path, without Keychain interception.

## Release timing

Quiet → heavy → screen, load1 ≤ 12 throughout. Five interleaved normal-launch
pairs compare unchanged main `c6e05c94` with the branch. Five fresh first-run
roots measure `sidebarDrawn`; first-run `sidebarDrawn` marks the native Welcome
content. Selected imported-tab paint is measured from `firstRunLandingStarted`
to `firstContentfulPaint`, using a local synthetic page.

| Timing | Median | Target / result |
|---|---|---|
| First-run first content | 371 ms | 250 ms: **FAIL, target not met** |
| Selected imported-tab paint | 205 ms | 700 ms: PASS |
| Normal launch, unchanged main | 382 ms | comparison |
| Normal launch, branch | 382 ms | 0.0% regression: PASS |

F12: first-run first content 371 ms vs 250 ms budget: NOT MET; normal launch 382 ms on main and branch, so first run adds no cost; the 250 ms cold-launch budget is the open Section 8 item 13 / Section 16 launch budget.
Functional F12 rows do not close that budget.
The normal-launch medians match main and remain within TANDEM §4 item 4a's
400 ms known-main allowance. No threshold or baseline was changed.

| Sample | First content | Entry load | Exit load |
|---|---|---|---|
| `normal-main #1` | 4134 ms | 5.29 / 4.55 / 4.71 | 5.35 / 4.58 / 4.72 |
| `normal-branch #1` | 413 ms | 5.35 / 4.58 / 4.72 | 5.56 / 4.63 / 4.74 |
| `firstRun-branch #1` | 371 ms | 5.56 / 4.63 / 4.74 | 5.56 / 4.63 / 4.74 |
| `normal-main #2` | 372 ms | 5.56 / 4.63 / 4.74 | 5.92 / 4.72 / 4.77 |
| `normal-branch #2` | 382 ms | 5.92 / 4.72 / 4.77 | 5.92 / 4.72 / 4.77 |
| `firstRun-branch #2` | 430 ms | 5.92 / 4.72 / 4.77 | 5.92 / 4.72 / 4.77 |
| `normal-main #3` | 386 ms | 5.92 / 4.72 / 4.77 | 5.92 / 4.72 / 4.77 |
| `normal-branch #3` | 376 ms | 5.92 / 4.72 / 4.77 | 5.92 / 4.72 / 4.77 |
| `firstRun-branch #3` | 392 ms | 6.80 / 4.93 / 4.84 | 6.80 / 4.93 / 4.84 |
| `normal-main #4` | 258 ms | 6.80 / 4.93 / 4.84 | 6.80 / 4.93 / 4.84 |
| `normal-branch #4` | 387 ms | 6.80 / 4.93 / 4.84 | 6.80 / 4.93 / 4.84 |
| `firstRun-branch #4` | 365 ms | 6.80 / 4.93 / 4.84 | 6.80 / 4.93 / 4.84 |
| `normal-main #5` | 382 ms | 6.80 / 4.93 / 4.84 | 6.98 / 4.99 / 4.87 |
| `normal-branch #5` | 381 ms | 6.98 / 4.99 / 4.87 | 6.98 / 4.99 / 4.87 |
| `firstRun-branch #5` | 297 ms | 6.98 / 4.99 / 4.87 | 6.98 / 4.99 / 4.87 |

Imported paint samples: 216, 213, 205, 198, 197 ms.

## Alternate-icon restore split

The one off-main TIFF/representation preparation attempt is complete. The
remaining main cost is the `NSApp.applicationIconImage` setter. Per the lead's
ruling, that cost is accepted and reported. Every sample applied a prepared
1024×1024 image more than one second after first paint. Main preparation passed
the revised <5 ms target. The commandbar Settings rows also prove pixel equality,
missing and oversized-cache errors, and zero task/decode/setter for default.

| Sample | Worker decode/prepare | Main preparation | Main setter | After paint | Entry load | Exit load |
|---|---|---|---|---|---|---|
| 1 | 8.556 ms | 0.000042 ms | 24.757 ms | 1117.5 ms | 7.06 / 5.08 / 4.90 | 7.06 / 5.08 / 4.90 |
| 2 | 9.096 ms | 0.000125 ms | 25.298 ms | 1117.8 ms | 7.06 / 5.08 / 4.90 | 7.46 / 5.19 / 4.94 |
| 3 | 8.882 ms | 0.000083 ms | 24.163 ms | 1116.8 ms | 7.46 / 5.19 / 4.94 | 7.46 / 5.19 / 4.94 |

## Negative controls and final real-data dry run

The saved unchanged `31792280` App supplies the old-code control. Its expected
History, source-age and archived-duplicate failures remain in the receipt;
the control runner succeeds only when those old behaviors fail the new rules.
The earlier real-data one-tab repeat failure and diagnostic are retained above.
The first old-code control also reached an unrelated optional icon read-back
with no restore timing and raised a Python TypeError. That failed runner is
retained as `old-code-proof`; the corrected `old-code-proof-2` keeps all three
History/Today/archive assertions and removes only that optional old-icon probe.
The final dry run uses private copies and a temporary Open root; it deletes
all source/output roots in `finally` and reports counts only. No Keychain or
default-browser setter runs.

Old-code load: 5.46 / 5.90 / 5.44. History rule passed on old code: `False`; old Today persisted: `False`; archive-aware zero-tab repeat passed: `False`. Old repeat added 2 tabs.

Final real App: 6 Spaces, 43 tabs/Favorites, 21 archive records and 75 History visits; zero failures. Sidebar accounted 60/60; archive accounted 23/23. Startup archived 0 imported Today tabs. Repeat added zero Spaces/tabs/Favorites/folders/archive/History. `importAll` took 2.701 ms on main; load 6.30 / 6.06 / 5.50. All temporary roots were removed.

| Final real-data CLI | Result | Duration | Load |
|---|---|---|---|
| `import-arc #1` | PASS | 214.133 ms | 5.98 / 5.99 / 5.48 |
| `import-arc-history #2` | PASS | 191.336 ms | 5.98 / 5.99 / 5.48 |
| `import-arc-history #3` | PASS | 168.318 ms | 5.98 / 5.99 / 5.48 |
| `import-arc-secrets #4` | PASS | 182.822 ms | 5.98 / 5.99 / 5.48 |
| `import-arc-history #5` | PASS | 164.771 ms | 5.98 / 5.99 / 5.48 |
| `import-arc-history #6` | PASS | 157.401 ms | 5.98 / 5.99 / 5.48 |
| `import-arc-secrets #7` | PASS | 179.401 ms | 6.30 / 6.06 / 5.50 |

## Full M5 verification

`export OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main` preceded
`heavy.sh tools/verify-all.sh --with-arc-data`. No own heavy job overlapped.
The full run took no quiet lock. The existing native-menu check takes its own
screen lock. The table records loads at each check's entry and exit.

| Check | Result | Entry load | Exit load |
|---|---|---|---|
| `build` | PASS | 9.46 / 6.81 / 5.79 | 9.46 / 6.81 / 5.79 |
| `commands-demo` | PASS | 10.47 / 7.06 / 5.88 | 11.07 / 7.24 / 5.95 |
| `roundtrip` | PASS | 11.07 / 7.24 / 5.95 | 11.07 / 7.24 / 5.95 |
| `space-legacy` | PASS | 11.07 / 7.24 / 5.95 | 11.07 / 7.24 / 5.95 |
| `space-editor` | PASS | 11.07 / 7.24 / 5.95 | 11.38 / 7.37 / 6.01 |
| `space-pad-compare` | PASS | 11.38 / 7.37 / 6.01 | 11.43 / 7.45 / 6.04 |
| `suggest-check` | PASS | 11.43 / 7.45 / 6.04 | 16.15 / 9.08 / 6.69 |
| `commands-dump` | PASS | 16.15 / 9.08 / 6.69 | 16.15 / 9.08 / 6.69 |
| `route` | PASS | 16.15 / 9.08 / 6.69 | 15.66 / 9.10 / 6.71 |
| `favicons` | PASS | 15.66 / 9.10 / 6.71 | 14.89 / 9.04 / 6.70 |
| `media-demo` | PASS | 14.89 / 9.04 / 6.70 | 14.89 / 9.04 / 6.70 |
| `sleep-demo` | PASS | 14.89 / 9.04 / 6.70 | 14.89 / 9.04 / 6.70 |
| `adblock-perf` | PASS | 14.89 / 9.04 / 6.70 | 14.89 / 9.04 / 6.70 |
| `adblock-catalog` | PASS | 14.89 / 9.04 / 6.70 | 14.89 / 9.04 / 6.70 |
| `profiles` | PASS | 14.89 / 9.04 / 6.70 | 14.89 / 9.04 / 6.70 |
| `settings-preview` | PASS | 14.89 / 9.04 / 6.70 | 9.25 / 8.59 / 6.74 |
| `sidebar-render` | PASS | 9.25 / 8.59 / 6.74 | 4.80 / 7.18 / 6.42 |
| `sidebar-compare` | PASS | 4.80 / 7.18 / 6.42 | 9.41 / 8.20 / 6.91 |
| `commandbar-render` | PASS | 9.41 / 8.20 / 6.91 | 8.09 / 8.00 / 6.89 |
| `features-render` | PASS | 8.09 / 8.00 / 6.89 | 9.95 / 8.71 / 7.28 |
| `extensions-render` | PASS | 9.95 / 8.71 / 7.28 | 9.79 / 8.71 / 7.30 |
| `sitecontrol-render` | PASS | 9.79 / 8.71 / 7.30 | 9.49 / 8.83 / 7.43 |
| `boosts` | PASS | 9.49 / 8.83 / 7.43 | 9.21 / 8.78 / 7.42 |
| `import-arc` | PASS | 9.21 / 8.78 / 7.42 | 9.21 / 8.78 / 7.42 |

Raw summary:

```text
NAME                   RESULT SECONDS
build                  PASS   4
commands-demo          PASS   5
roundtrip              PASS   0
space-legacy           PASS   2
space-editor           PASS   7
space-pad-compare      PASS   3
suggest-check          PASS   31
commands-dump          PASS   1
route                  PASS   5
favicons               PASS   1
media-demo             PASS   0
sleep-demo             PASS   1
adblock-perf           PASS   1
adblock-catalog        PASS   0
profiles               PASS   1
settings-preview       PASS   84
sidebar-render         PASS   112
sidebar-compare        PASS   108
commandbar-render      PASS   35
features-render        PASS   96
extensions-render      PASS   7
sitecontrol-render     PASS   54
boosts                 PASS   7
import-arc             PASS   1
```

## Review checklist

| Item | Result | Evidence |
|---|---|---|
| Input/count/depth/length bounds | PASS | Existing Arc reader limits; source Profile directory ≤255 UTF-8 bytes; automation action/directory limits; PNG ≤16 MiB, one image, exactly 1024×1024. |
| Worst decoded allocation | PASS | Icon comment bounds decoded pixels to 8,388,608 bytes; History keeps one ≤5,000-row batch plus the existing URL map. |
| Boundary inputs | PASS | `automation_limits`; Settings missing/oversized icon cache rows; valid 1024 px cache and 5,000-visit batch pass. Existing importer boundaries remain in the CLI gate. |
| Unknown/trailing parsed input | N/A | No new wire/file parser; existing Arc schema handling and ImageIO own decoding. |
| Callback lifetime/reentrancy | PASS | Runner owns History after panel close; icon weak capture, generation and shutdown guards; F9 close and Settings quit/save rows. |
| Close twice / close during work | PASS | F9 close keeps History; all owned-process cleanup rows pass; no new manually freed object. |
| Stable/stale IDs | PASS | Existing stable sidebar IDs and history keys; archive duplicate lookup; icon selection generation blocks stale application. |
| Flush state before dependent action | PASS | Landing saves before History; archive query queues behind manual archive writes; merge save/rollback and one Undo pass. |
| Real key paths | PASS | Existing first-run and shell/commandbar/routing key regressions run through App automation; no new key router. |
| Key/focus ownership after main merge | PASS | `c6e05c94` merged; final shell, features, routing and commandbar pass. |
| Hidden/disabled actions | PASS | F10 disabled password selection; Continue Without Passwords adapter gate; no consent/decrypt API in App import paths. |
| Negative controls | PASS | Retained old-code History/Today/archive rule failures and raw one-tab real-data repeat failure; fixed branch positive rows pass. |
| Pixel comparison | PASS | Settings icon native image equality row; the cost probe also checks 1024×1024 representations. |
| Specific windows | PASS | `FirstRunNativeWindow` identity, 560×520 geometry and browser-window landing assertions. |
| Scheduled delay/deadline | PASS | One utility main-queue turn at +1 s; one bounded OCR retry; main preparation <5 ms, setter separately reported. Dedicated F12 budget miss remains explicit. |
| Isolated roots/defaults/ports | PASS | Temporary roots and fixtures; shared defaults reset at start and restored in `finally`; existing ephemeral socket/port harness. |
| No human / cleanup on failure | PASS | No new system dialog; existing save/read failures and progress-window close exercise cleanup. Every final suite reports no remaining owned windows/processes. |
| Reduce Motion / interrupted animation | N/A | No animation change. |
| Resize/sidebar motion | N/A | No layout/motion change. |
| New real-window visual parity | N/A | No new design; lead accepted the code. Existing copy/geometry and icon pixel checks pass. |
| Current comments/docs/numbers | PASS | Model, Settings, first-run plan, automation and this receipt match the source and measured cost split. |
| Plan/followups/PR agree | PASS | First-content 250 ms target stays open; imported paint and no-regression pass; secrets writer remains out of scope. |

## Decisions for the lead

Accepted by the Section 7 lead at 15:35:

- An unreadable archive-ID lookup stops the Settings merge and keeps the live model.
- A missing or damaged alternate-icon cache asks the user to select the icon again.
- An unknown failed History source count uses only the probe's known count.

No new design decision is requested. The remaining open performance item is
the 250 ms cold-launch target, owned by Section 8 item 13 / Section 16.
The OS default-browser prompt and secret
writer remain outside this task's automated acceptance.

## Documentation completion after the disk hold

The M5 disk hold was lifted at 16:02. This documentation-only update keeps
`ec58d9fe` as the code receipt: full M5 verification passed 24/24 at 15:55:31.
At 15:58 no owned build, verify, App or timing job was running. The first docs
commit failed with `No space left on device`; it was not retried during the
hold. After the lead lifted the hold, the seven completed docs files were
committed and pushed to PR [#206](https://github.com/SergeSerb2/open/pull/206).
No rebuild or new gate was run, per the lead's instruction. No file was deleted
to free space, and the M1 remained on hold.

Documentation whitespace check (`git diff --check`): PASS; entry and exit
load 12.32 / 8.39 / 7.36. No new build or runtime gate was run.
