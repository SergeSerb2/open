# S11 dialogs and permissions: real App evidence

2026-11-05, NSScreen main AW2726DM at 1x (confirmed before/after each final suite). Each JSON receipt records its App-source head, clean source tree, and engine fingerprint.
Debug, Chrome style, recorded main engine `f34400e71412d87a0b268fcd5658a8563cca34f600c8dd17b534a63e76aa7939`.
Each suite uses the real App automation socket and a separate on-screen lock invocation. No unit tests, desktop input, Arc launch, or engine source changes.

| Suite | PASS | FAIL | Other status | Interrupted attempts excluded | Owned cleanup | Source head | Receipt |
|---|---:|---:|---|---:|---|---|---|
| page-chrome | 41 | 0 | none | 0 | PASS | `deeec4c3` | [results-page-chrome-debug.json](results-page-chrome-debug.json) |
| features | 19 | 0 | none | 0 | PASS | `deeec4c3` | [results-features-chrome.json](results-features-chrome.json) |
| shell | 7 | 0 | none | 0 | PASS | `deeec4c3` | [results-shell-debug.json](results-shell-debug.json) |
| window | 76 | 0 | DEFERRED: 1, SKIP: 2 | 0 | PASS | `deeec4c3` | [results-window-debug.json](results-window-debug.json) |
| page | 85 | 0 | BLOCKED: 4, DEFERRED: 1 | 0 | PASS | `deeec4c3` | [results-page-chrome.json](results-page-chrome.json) |
| sleep | 20 | 0 | BLOCKED: 1 | 0 | PASS | `deeec4c3` | [results-sleep-debug.json](results-sleep-debug.json) |

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

## Final full verification

Source `deeec4c34f7f6ad2a8355c9ba0599cbe64358996`, including main `ebcf08d2` (Peek #176).
`heavy.sh tools/verify-all.sh --with-arc-data --keep-logs`: **23 PASS, 0 FAIL, 0 SKIP**.
NSScreen before and after: `AW2726DM`, scale `1`.
Load averages: start **6.21 / 6.95 / 9.13**, finish **27.62 / 17.47 / 13.26**.
The named low-load `--only sidebar-render` rerun also passes (build 41 s, check 113 s).

| Check | Result | Seconds |
|---|---|---:|
| build | PASS | 2 |
| commands-demo | PASS | 2 |
| roundtrip | PASS | 0 |
| space-legacy | PASS | 1 |
| space-editor | PASS | 2 |
| space-pad-compare | PASS | 2 |
| suggest-check | PASS | 15 |
| commands-dump | PASS | 0 |
| route | PASS | 2 |
| favicons | PASS | 1 |
| media-demo | PASS | 0 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 1 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 0 |
| settings-preview | PASS | 86 |
| sidebar-render | PASS | 114 |
| sidebar-compare | PASS | 125 |
| commandbar-render | PASS | 36 |
| features-render | PASS | 90 |
| sitecontrol-render | PASS | 133 |
| boosts | PASS | 9 |
| import-arc | PASS | 1 |

## Retained timing history

The command bar benchmark renders at 2x even though the main screen is 1x. Its unchanged limits are CPU p95 <8 ms and inline-completion delta ≤0.3 ms. The final full invocation passes both. Earlier failures are retained below; no threshold or benchmark code changed, and no performance improvement is attributed to this feature.

| Invocation | Result | Main-thread CPU p95 / inline delta | Load1 |
|---|---|---|---:|
| Historical 5bf513fd full | FAIL | 24.00 ms / +0.842 ms | 130.9 |
| f7fcac75 full | FAIL | inline +0.356 ms | 13.8 |
| f7fcac75 quiet 1 | FAIL | CPU 8.10 ms | 10.5 |
| f7fcac75 quiet 2 | FAIL | CPU 6.54 ms; inline +0.381 ms | 10.9 |
| Unchanged main 8db4ac86, quiet control | PASS | 7.37 ms / +0.148 ms | 13.6 |
| Final deeec4c3 full | PASS | 5.61 ms / +0.244 ms | 18.2 |

The [source-identity receipt](s11-commandbar-source-identity.json) records identical commandbar-render source/dependency trees and Package.swift on the control, current main and this branch. The feature adds only a geometry getter in OpenFeatures, outside that target's dependency graph.
