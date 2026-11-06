# S11 dialogs and permissions: real App evidence

2026-11-05. Clean App source `7cddbb141e4324370acd17e57509b443739024cf` includes main `e79b0d53` (Downloads #181, extension commands #179, and Peek #176). Debug, Chrome style, main engine `f34400e7` (code `1bc8b604`), main NSScreen `AW2726DM` at 1x. Every suite uses the real App automation socket and a separate screen-lock invocation. No unit tests, desktop input, Arc launch, or engine source changes.

**199 PASS, 0 FAIL across five complete suites; two suites INTERRUPTED.** The accepted Page invocation excludes one earlier interrupted attempt. Page-chrome has no interrupted attempt. All owned teardown checks pass.

**Remaining integration gate:** Shell and Window are INTERRUPTED on the merged head. Each had two invocations of three bounded attempts. The latest attempts could not obtain key focus: `active=false`, `frontmost=OpenTodos`. Cleanup passed. No partial rows from those invocations count toward acceptance. They need a quiet foreground interval; the App and harness were not changed to bypass that requirement. This PR remains a draft.

| Suite | Result | PASS counted | Other status | Interrupted attempts in this invocation | Cleanup | App source | Receipt |
|---|---|---:|---|---:|---|---|---|
| page-chrome | PASS | 41 | none | 0 | PASS | `7cddbb14` | [results-page-chrome-debug.json](results-page-chrome-debug.json) |
| features | PASS | 19 | none | 0 | PASS | `7cddbb14` | [results-features-chrome.json](results-features-chrome.json) |
| shell | INTERRUPTED | 0 | INTERRUPTED: 1 | 3 | PASS | `7cddbb14` | [results-shell-debug.json](results-shell-debug.json) |
| window | INTERRUPTED | 0 | INTERRUPTED: 1 | 3 | PASS | `7cddbb14` | [results-window-debug.json](results-window-debug.json) |
| page | PASS | 85 | BLOCKED: 4, DEFERRED: 1 | 1 | PASS | `7cddbb14` | [results-page-chrome.json](results-page-chrome.json) |
| sleep | PASS | 20 | BLOCKED: 1 | 0 | PASS | `7cddbb14` | [results-sleep-debug.json](results-sleep-debug.json) |
| downloads | PASS | 34 | none | 0 | PASS | `7cddbb14` | [results-downloads-debug.json](results-downloads-debug.json) |

Before the latest main merge, all six required suites completed on clean App source `deeec4c3`: **248 PASS, 0 FAIL**, with all four native Window display rows passing. Those are historical receipts, not merged-head acceptance: [Shell 7/7](https://github.com/SergeSerb2/open/blob/b9f8cbcd31e980b3fc78b44a91655a4b0999b7c8/docs/engine-spike/results-shell-debug.json), [Window 76/76](https://github.com/SergeSerb2/open/blob/b9f8cbcd31e980b3fc78b44a91655a4b0999b7c8/docs/engine-spike/results-window-debug.json). The earlier complete raw receipts remain in `.re/pre-main181/`. The first post-merge page-chrome, shell, and window batches each ended INTERRUPTED after three foreground-loss attempts; raw batches remain in `.re/rerun-*/`.

## Negative proof and failure cleanup

The temporary broken variant disabled normal dialog presentation and permission presentation, inverted accept/dismiss policy answers, showed held dialogs, removed text-limit refusal, accepted host-close cancellation, and used an incorrect beforeunload title. All 41 new gates failed, with no interrupted attempt and clean owned-process/window teardown. Production source was restored before the final build.
Mutation source patch SHA-256: `d2e39be557be5008faff3cc97e11213da2949315c21c226b7c8736384e3fe75c`.
The [negative receipt](results-page-chrome-negative.json) records the same 41 gate names, each with an expected FAIL. The raw mutation is `.re/page-chrome-negative-source.patch`.
An [intentional failure while the real alert sheet was visible](results-page-chrome-cleanup-failure.json) also left zero owned windows and processes, without forced termination.

## Boundaries and Section 12 hooks

- `PermissionPromptPresenter.anchorProvider` supplies the later Site Control button anchor. `PaneChromeView.urlAreaFrame` is the small package geometry hook.
- `SitePermissionStore.forContext(_:)` supplies `state(origin:kind:)`, `set(origin:kind:state:)`, `allDecisions()`, and `SitePermissionStore.didChange`. The engine stores decisions; the asynchronous origin index makes App-known origins enumerable across relaunch. Settings written outside this hook before this feature become enumerable after their origin is read.
- Real JS background queuing was observed (`pending:1`, `queued:true`, `visible:false`), then the selected tab showed its sheet. Chromium deferred the background notification callback until selection; that row proves presentation behavior, not independent exercise of the App permission queue.
- The per-page queue cap of eight and the origin-index safety bounds are enforced in source. Their at/over-limit runtime boundaries were not independently reached. Message 8192/8193-byte and prompt-default 4096/4097-byte boundaries were exercised through real page requests.
- Notifications and MIDI used real engine requests. Grouped camera/microphone and macOS location/camera/notification authorization prompts were not exercised under the credential/TCC ban. Native macOS delivery and real device rows retain their explicit BLOCKED status.
- The design says both truncation and checkpoint refusal. This implementation keeps checkpoint refusal. The engine exposes no protocol-handler kind/metadata, so the mail-app question cannot be selected from this API.

## User captures

The user operates Arc for the remaining page-chrome §7 captures: light/dark sheets, default prompt selection, repeat suppression, close/reload beforeunload, background tabs, and permission popovers with sidebar/toolbar on/off. On fresh synthetic origins capture Allow/Not Now, revisit/relaunch, combined camera/microphone, clipboard/MIDI, Site Control values, and any separate macOS alert. The 320 pt permission width and final popover edge remain the lead’s stated visual guesses. No Arc pixel acceptance is claimed.

The PR body contains the full `verify-all` summary and review-checklist table. Historical results from before the monitor restoration remain separate; the former built-in-display failure exceptions do not apply to these final runs.

Committed JSON receipts redact machine paths as `$WORKTREE`, `$HOME`, and `$TMPDIR`. Raw receipts remain in `.re/*-final.json`.
Earlier page-chrome batches ended INTERRUPTED after three foreground-loss attempts each. None of their partial rows contribute to the final 41 PASS.
Generated Open window/PDF PNGs are archived locally in `.re/final-native-pngs/`. Existing illustrative PNGs are restored; no comparison baseline changed.

## Final integration and full verification

The main merge preserves Downloads quit preflight before page-beforeunload, both e2e suites, and both documentation sections. Debug build PASS. The compiler reports eight Swift warning sites on unchanged main source lines; the new page-chrome code adds none.

`heavy.sh tools/verify-all.sh --with-arc-data --keep-logs`: **23 PASS, 0 FAIL, 0 SKIP** on `7cddbb14`. NSScreen before/after is `AW2726DM`, scale `1`. Load start **15.79 / 12.10 / 12.06**, finish **7.88 / 9.71 / 10.75**. No quiet rerun was needed. All restored-display verifier gates PASS. These do not replace the interrupted real-App Window suite.

| Check | Result | Seconds |
|---|---|---:|
| build | PASS | 91 |
| commands-demo | PASS | 1 |
| roundtrip | PASS | 1 |
| space-legacy | PASS | 0 |
| space-editor | PASS | 3 |
| space-pad-compare | PASS | 2 |
| suggest-check | PASS | 25 |
| commands-dump | PASS | 0 |
| route | PASS | 3 |
| favicons | PASS | 1 |
| media-demo | PASS | 0 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 0 |
| adblock-catalog | PASS | 1 |
| profiles | PASS | 1 |
| settings-preview | PASS | 84 |
| sidebar-render | PASS | 113 |
| sidebar-compare | PASS | 124 |
| commandbar-render | PASS | 39 |
| features-render | PASS | 93 |
| sitecontrol-render | PASS | 120 |
| boosts | PASS | 4 |
| import-arc | PASS | 0 |

## Retained timing history

The final command bar check passes in one full invocation with the original thresholds. No performance improvement is attributed to this feature. Earlier measurements were considered under lead interim rule 4b; the final full run needs no timing exception.

| Invocation | Result | Main-thread CPU p95 / inline delta | Load1 |
|---|---|---|---:|
| Historical 5bf513fd full | FAIL | 24.00 ms / +0.842 ms | 130.9 |
| f7fcac75 full | FAIL | inline +0.356 ms | 13.8 |
| f7fcac75 quiet 1 | FAIL | CPU 8.10 ms | 10.5 |
| f7fcac75 quiet 2 | FAIL | CPU 6.54 ms; inline +0.381 ms | 10.9 |
| Unchanged main 8db4ac86, quiet control | PASS | 7.37 ms / +0.148 ms | 13.6 |
| Pre-#181 deeec4c3 full | PASS | 5.61 ms / +0.244 ms | 18.2 |
| Post-#181/#179 7cddbb14 full | PASS | 6.02 ms / +0.098 ms | 11.6 |

The [source-identity receipt](s11-commandbar-source-identity.json) describes the historical pre-#181/#179 heads named inside it. Main #179 later changed the command bar target; this feature changes none of that target's sources or dependencies.
