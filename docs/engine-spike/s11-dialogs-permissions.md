# S11 dialogs and permissions: real App evidence

2026-11-05. App source `a7e73498c3e68336217d8db40fbebe6ce6b89773` includes main `e4d40ce0` (#177 Extensions P3, #178 context menus, #182 runner lifetime, #181 Downloads, #179 extension commands, #176 Peek). Debug, Chrome style. Every native suite requires framework SHA-256 `7b49090502568f8189aa0e94f7cf23344beec5bed537136eff5f7fce573ad35a`; embedded/distribution code SHA-256 is `7979934c0d84f4d9fedb3859826d0c7c65919834fc904ec2aee00a0b4e4dd8f2`. Main NSScreen before/after is `AW2726DM`, 1x. No unit tests, computer use, Arc launch, or engine-tree edits.

## Current engine regression

**316 PASS counted across complete suites.** No suite ended INTERRUPTED. No complete suite failed. All receipts identify the same App source and required engine pin.

| Suite | Result | PASS counted | Other status | Interrupted attempts | Cleanup | Receipt |
|---|---|---:|---|---:|---|---|
| page-chrome | PASS | 41 | none | 0 | PASS | [results-page-chrome-debug.json](results-page-chrome-debug.json) |
| features | PASS | 19 | none | 0 | PASS | [results-features-chrome.json](results-features-chrome.json) |
| shell | PASS | 7 | none | 0 | PASS | [results-shell-debug.json](results-shell-debug.json) |
| window | PASS | 76 | DEFERRED: 1, SKIP: 2 | 0 | PASS | [results-window-debug.json](results-window-debug.json) |
| page | PASS | 85 | BLOCKED: 4, DEFERRED: 1 | 0 | PASS | [results-page-chrome.json](results-page-chrome.json) |
| sleep | PASS | 20 | BLOCKED: 1 | 0 | PASS | [results-sleep-debug.json](results-sleep-debug.json) |
| downloads | PASS | 34 | none | 1 | PASS | [results-downloads-debug.json](results-downloads-debug.json) |
| context-menus | PASS | 34 | none | 0 | PASS | [results-context-menus-chrome.json](results-context-menus-chrome.json) |

An accepted retry alone contributes passing rows. Window’s two launch-budget rows are SKIP because this is Debug; no Release launch-budget acceptance is claimed. Its card-material row is DEFERRED. Page/Sleep blocks retain their explicit status. All four native Window pixel/color rows are recorded in its current receipt.

## Integration and owner lifetime

The merges retain both page-chrome and context-menu cleanup, P3 and page-chrome automation commands/suites, and all status/docs changes. Downloads quit preflight still precedes page-beforeunload. Debug build PASS with no new warnings.

The [runner-lifetime receipt](results-page-chrome-owner-debug.json) records all four real-App cases PASS: owner death, missing-owner-environment negative control, active download, and beforeunload. The last first observes/cancels a normal kind-3 beforeunload request. After owner death it sees no new pending request, exits in **0.202 s**, and leaves zero owned processes. The automation-only guard leaves normal quit’s page preflight in place.

Negative proof on `9789d3d5`: owner death re-enters held beforeunload; the new assertion FAILS. Pending state was seen in 33 observations (not 33 callbacks), and shutdown used the five-second fallback (5.462 s). Cleanup passed. Raw observations are in `.re/page-chrome-owner-negative/` and `.re/main177-owner/`.

## Full verification and targeted timing rerun

`heavy.sh tools/verify-all.sh --with-arc-data --keep-logs` on `a7e73498`: **22 PASS, 1 timing FAIL, 0 SKIP**. Full-run load start **18.66 / 15.48 / 13.49**, finish **30.72 / 21.87 / 17.73**. All restored-display gates pass. Command-bar CPU p95 fails at **9.98 ms** (8 ms budget), at load1 **26.4**; inline delta **+0.088 ms** passes. The original summary is retained:

| Check | Result | Seconds |
|---|---|---:|
| build | PASS | 3 |
| commands-demo | PASS | 1 |
| roundtrip | PASS | 1 |
| space-legacy | PASS | 0 |
| space-editor | PASS | 3 |
| space-pad-compare | PASS | 2 |
| suggest-check | PASS | 22 |
| commands-dump | PASS | 1 |
| route | PASS | 3 |
| favicons | PASS | 1 |
| media-demo | PASS | 0 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 0 |
| adblock-catalog | PASS | 1 |
| profiles | PASS | 1 |
| settings-preview | PASS | 90 |
| sidebar-render | PASS | 112 |
| sidebar-compare | PASS | 156 |
| commandbar-render | FAIL | 48 |
| features-render | PASS | 92 |
| sitecontrol-render | PASS | 98 |
| boosts | PASS | 11 |
| import-arc | PASS | 1 |

Only `commandbar-render` was rerun under the quiet lock, after waiting at load1 ≤ 12 while holding only that lock, then using `heavy.sh`. **Both selected verifier rows PASS**: CPU p95 **4.29 ms**, inline delta **+0.179 ms**, at measured load1 **5.5**. No threshold or benchmark code changed. The combined gate is **23/23 PASS** after this strict single rerun; no interim rule 4b exception is needed.

| Check | Result | Seconds |
|---|---|---:|
| build | PASS | 3 |
| commandbar-render | PASS | 34 |

Quiet-rerun start/end load readings:

- `22:46  up 13:30, 7 users, load averages: 6.94 8.70 11.19`
- `22:47  up 13:31, 7 users, load averages: 5.66 8.13 10.87`

## Earlier checkpoints

App source `6eb7dcdf` with engine `f34400e7` completed all eight suites (316 PASS), owner lifetime 4/4, and full verification 23/23. All four native Window display rows passed. These pre-#177 results are frozen at [checkpoint 924f9619](https://github.com/SergeSerb2/open/blob/924f9619/docs/engine-spike/s11-dialogs-permissions.md); they are separate from the current engine table. That checkpoint also preserves the older `7cddbb14`/`deeec4c3` results and foreground-interrupted batches. No partial interrupted rows count toward acceptance.

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
Generated Open window/PDF PNGs are archived locally in `.re/final-native-pngs/` and `.re/main178-native-pngs/` and `.re/main177-native-pngs/`. Existing illustrative PNGs are restored; no comparison baseline changed.

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
| Post-#177 a7e73498 full | FAIL | 9.98 ms / +0.088 ms | 26.4 |
| Post-#177 a7e73498 quiet 1 | PASS | 4.29 ms / +0.179 ms | 5.5 |

The [source-identity receipt](s11-commandbar-source-identity.json) describes the historical pre-#181/#179 heads named inside it. Main #179 later changed the command bar target; this feature changes none of that target's sources or dependencies.
