# S11 dialogs and permissions: real App evidence

2026-11-05. Completed checkpoint App source `6eb7dcdf874c3a4dfa8092937d2aeb3b01b07b94` includes main `890d4637` (context menus #178, runner lifetime #182, Downloads #181, extension commands #179, and Peek #176). Debug, Chrome style, main engine `f34400e7` (code `1bc8b604`), main NSScreen `AW2726DM` at 1x. Every suite uses the real App automation socket and a separate screen-lock invocation. No unit tests, desktop input, Arc launch, or engine source changes.

## Completed checkpoint before the engine update

Main has since moved to `e4d40ce0` (#177) and engine `7b490905`. The new engine merge, build, suites, and full verification remain pending. This PR stays a draft. Results below qualify the completed pre-update checkpoint only.

**316 PASS counted across complete suites.** No suite ended INTERRUPTED. No complete suite failed. All receipts below identify the same App source.

| Suite | Result | PASS counted | Other status | Interrupted attempts | Cleanup | Receipt |
|---|---|---:|---|---:|---|---|
| page-chrome | PASS | 41 | none | 0 | PASS | [results-page-chrome-debug.json](results-page-chrome-debug.json) |
| features | PASS | 19 | none | 1 | PASS | [results-features-chrome.json](results-features-chrome.json) |
| shell | PASS | 7 | none | 0 | PASS | [results-shell-debug.json](results-shell-debug.json) |
| window | PASS | 76 | DEFERRED: 1, SKIP: 2 | 0 | PASS | [results-window-debug.json](results-window-debug.json) |
| page | PASS | 85 | BLOCKED: 4, DEFERRED: 1 | 0 | PASS | [results-page-chrome.json](results-page-chrome.json) |
| sleep | PASS | 20 | BLOCKED: 1 | 0 | PASS | [results-sleep-debug.json](results-sleep-debug.json) |
| downloads | PASS | 34 | none | 0 | PASS | [results-downloads-debug.json](results-downloads-debug.json) |
| context-menus | PASS | 34 | none | 0 | PASS | [results-context-menus-chrome.json](results-context-menus-chrome.json) |

Interrupted attempts stay in the raw receipts; an accepted later attempt alone contributes passing rows. The new Page-chrome suite checks the same 41 names as its broken-variant proof. Page/Sleep blocks retain their explicit status. Debug Window timing rows do not claim Release budget acceptance.

## Owner shutdown and main integration

The merge retains both dialog/permission and context-menu host/window cleanup, both e2e suite branches, and both status updates. Downloads quit preflight remains before page-beforeunload. Debug build PASS with no new warnings.

The [runner-lifetime receipt](results-page-chrome-owner-debug.json) records all four real-App cases PASS: ordinary owner death, missing-owner-environment negative control, active download, and beforeunload. The last first observes kind 3 on normal quit and cancels it. After owner death it sees no new pending request, exits in **0.244 s**, and leaves zero owned processes. The guard is automation-only; normal quit retains the page preflight.

Negative proof on `9789d3d5`, before the fix: owner death re-enters held beforeunload. The new assertion FAILS as expected. The harness observes pending state 33 times (not 33 callbacks), then shutdown uses the five-second fallback (5.462 s). Cleanup passes. The first fixed proof on `43ba07a2` passed all four owner cases and Page-chrome 41/41; those receipts are preserved at [checkpoint 54642a85](https://github.com/SergeSerb2/open/blob/54642a85/docs/engine-spike/s11-dialogs-permissions.md). Raw observations remain in `.re/page-chrome-owner-{negative,positive}/`.

## Full verification on 6eb7dcdf

`heavy.sh tools/verify-all.sh --with-arc-data --keep-logs`: **23 PASS, 0 FAIL, 0 SKIP**. Main NSScreen before/after is `AW2726DM`, scale 1. Load start **14.48 / 11.97 / 11.50**, finish **8.77 / 9.97 / 10.82**. All restored-display gates pass. No quiet rerun or timing exception was needed. Command-bar CPU p95 is **6.43 ms**, inline delta **+0.210 ms**, at load1 **9.7**.

| Check | Result | Seconds |
|---|---|---:|
| build | PASS | 3 |
| commands-demo | PASS | 2 |
| roundtrip | PASS | 0 |
| space-legacy | PASS | 1 |
| space-editor | PASS | 3 |
| space-pad-compare | PASS | 3 |
| suggest-check | PASS | 30 |
| commands-dump | PASS | 1 |
| route | PASS | 2 |
| favicons | PASS | 1 |
| media-demo | PASS | 0 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 1 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 0 |
| settings-preview | PASS | 84 |
| sidebar-render | PASS | 110 |
| sidebar-compare | PASS | 129 |
| commandbar-render | PASS | 37 |
| features-render | PASS | 89 |
| sitecontrol-render | PASS | 165 |
| boosts | PASS | 6 |
| import-arc | PASS | 1 |

Previous full verification: `7cddbb14` passed 23/23. The later `43ba07a2` invocation passed 22/23; only the command-bar inline timing row failed (+0.375 ms at load1 11.6). No old-source rerun was started because the required #178 merge superseded that run. Both loads and all timing attempts remain below.

## Previous broad regression checkpoint

Clean App source `7cddbb141e4324370acd17e57509b443739024cf` includes main `e79b0d53`, before #182.

**199 PASS, 0 FAIL across five complete suites; two suites INTERRUPTED.** The accepted Page invocation excludes one earlier interrupted attempt. Page-chrome has no interrupted attempt. All owned teardown checks pass.

**Remaining integration gate at this checkpoint:** Shell and Window are INTERRUPTED on `7cddbb14`. Each had two invocations of three bounded attempts. The latest attempts could not obtain key focus: `active=false`, `frontmost=OpenTodos`. Cleanup passed. No partial rows from those invocations count toward acceptance. They needed a quiet foreground interval; the App and harness were not changed to bypass that requirement. That checkpoint remained a draft.

| Suite | Result | PASS counted | Other status | Interrupted attempts in this invocation | Cleanup | App source | Receipt |
|---|---|---:|---|---:|---|---|---|
| page-chrome | PASS | 41 | none | 0 | PASS | `7cddbb14` | [results-page-chrome-debug.json](https://github.com/SergeSerb2/open/blob/b34d8a714877d0c88e28885f9d934396dd8436e3/docs/engine-spike/results-page-chrome-debug.json) |
| features | PASS | 19 | none | 0 | PASS | `7cddbb14` | [results-features-chrome.json](https://github.com/SergeSerb2/open/blob/b34d8a714877d0c88e28885f9d934396dd8436e3/docs/engine-spike/results-features-chrome.json) |
| shell | INTERRUPTED | 0 | INTERRUPTED: 1 | 3 | PASS | `7cddbb14` | [results-shell-debug.json](https://github.com/SergeSerb2/open/blob/b34d8a714877d0c88e28885f9d934396dd8436e3/docs/engine-spike/results-shell-debug.json) |
| window | INTERRUPTED | 0 | INTERRUPTED: 1 | 3 | PASS | `7cddbb14` | [results-window-debug.json](https://github.com/SergeSerb2/open/blob/b34d8a714877d0c88e28885f9d934396dd8436e3/docs/engine-spike/results-window-debug.json) |
| page | PASS | 85 | BLOCKED: 4, DEFERRED: 1 | 1 | PASS | `7cddbb14` | [results-page-chrome.json](https://github.com/SergeSerb2/open/blob/b34d8a714877d0c88e28885f9d934396dd8436e3/docs/engine-spike/results-page-chrome.json) |
| sleep | PASS | 20 | BLOCKED: 1 | 0 | PASS | `7cddbb14` | [results-sleep-debug.json](https://github.com/SergeSerb2/open/blob/b34d8a714877d0c88e28885f9d934396dd8436e3/docs/engine-spike/results-sleep-debug.json) |
| downloads | PASS | 34 | none | 0 | PASS | `7cddbb14` | [results-downloads-debug.json](https://github.com/SergeSerb2/open/blob/b34d8a714877d0c88e28885f9d934396dd8436e3/docs/engine-spike/results-downloads-debug.json) |

Before the #181/#179 merge, all six required suites completed on clean App source `deeec4c3`: **248 PASS, 0 FAIL**, with all four native Window display rows passing. Those are historical receipts, not merged-head acceptance: [Shell 7/7](https://github.com/SergeSerb2/open/blob/b9f8cbcd31e980b3fc78b44a91655a4b0999b7c8/docs/engine-spike/results-shell-debug.json), [Window 76/76](https://github.com/SergeSerb2/open/blob/b9f8cbcd31e980b3fc78b44a91655a4b0999b7c8/docs/engine-spike/results-window-debug.json). The earlier complete raw receipts remain in `.re/pre-main181/`. The first post-merge page-chrome, shell, and window batches each ended INTERRUPTED after three foreground-loss attempts; raw batches remain in `.re/rerun-*/`.

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

The PR body contains the full `verify-all` summary and review-checklist table. Historical results from before the monitor restoration remain separate; the former built-in-display failure exceptions do not apply to these restored-display runs.

Committed JSON receipts redact machine paths as `$WORKTREE`, `$HOME`, and `$TMPDIR`. Raw receipts remain in `.re/*-final.json`.
Earlier page-chrome batches ended INTERRUPTED after three foreground-loss attempts each. None of their partial rows contribute to any accepted Page-chrome result.
Generated Open window/PDF PNGs are archived locally in `.re/final-native-pngs/` and `.re/main178-native-pngs/`. Existing illustrative PNGs are restored; no comparison baseline changed.

## Retained timing history

The `7cddbb14` command bar check passes in one full invocation with the original thresholds. No performance improvement is attributed to this feature. Earlier measurements were considered under lead interim rule 4b; that full run needs no timing exception.

| Invocation | Result | Main-thread CPU p95 / inline delta | Load1 |
|---|---|---|---:|
| Historical 5bf513fd full | FAIL | 24.00 ms / +0.842 ms | 130.9 |
| f7fcac75 full | FAIL | inline +0.356 ms | 13.8 |
| f7fcac75 quiet 1 | FAIL | CPU 8.10 ms | 10.5 |
| f7fcac75 quiet 2 | FAIL | CPU 6.54 ms; inline +0.381 ms | 10.9 |
| Unchanged main 8db4ac86, quiet control | PASS | 7.37 ms / +0.148 ms | 13.6 |
| Pre-#181 deeec4c3 full | PASS | 5.61 ms / +0.244 ms | 18.2 |
| Post-#181/#179 7cddbb14 full | PASS | 6.02 ms / +0.098 ms | 11.6 |
| Post-#182 43ba07a2 full | FAIL | 7.65 ms / +0.375 ms | 11.6 |
| Post-#178 6eb7dcdf full | PASS | 6.43 ms / +0.210 ms | 9.7 |

The [source-identity receipt](s11-commandbar-source-identity.json) describes the historical pre-#181/#179 heads named inside it. Main #179 later changed the command bar target; this feature changes none of that target's sources or dependencies.
