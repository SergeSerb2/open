# First run: Steps A and B

Implements [first-run.md §11 A/B](plans/first-run.md#11-implementation-order-small-prs-each-step-files-then-acceptance). The user requested the designer review before Step C. No App/ file changes, window controller, startup trigger, completion save, model swap, engine import adapter, background-history landing, automation socket command, or real default-browser call is included. Steps C–F remain pending.

`FirstRunViewModel` and `FirstRunView` live in OpenSettings. The single size is `FirstRunWindow.size` (560×460), backed by Settings tokens. Colors, grouped rows, borders, button style, and typography use the Settings controls or system defaults. Step transitions use `Motion.selectionFade` and cut when Reduce Motion is on. The preview uses Open's own drawn icon; no reference artwork is copied.

## App seam for Step C

Retain the app's action object with the model. It implements `FirstRunActions` and `SettingsActions`; both inherit the same `ImportActions` requirement. Forward `runImport`, `setAsDefaultBrowser`, and `isDefaultBrowser` to the same implementation used by Settings.

```swift
let firstRun = FirstRunViewModel(
    settings: sharedSettings, actions: firstRunActions, directory: resolvedImportFolder)
let content = FirstRunView(model: firstRun)
```

Pass the existing Settings owner and its injected shared SnapshotStore. First run creates no writer. The model retains that owner because the shared wizard borrows it. The app fills `arcIsRunning`; OpenImport imports no AppKit. Progress assignments (`phaseText`, `progress`, `browserHasLanded`) are event-driven seams for the later action adapter. The flow calls `finishFirstRun(imported:)`; the App must save successfully before recording completion or closing the window. This step never writes `open.firstRun.completed` or saves a first-run snapshot.

First run owns one `ImportWizardViewModel`. It builds the existing `ImportPlan` and uses the wizard's consent/skip execution. `PasswordsImportCopy` is the only source of both capability-dependent texts and button labels. The capability stays OFF in this build. Unknown counts have an honest shared fallback. Cancel keeps the choices. Only the existing explicit allow method can set consent, and it is disabled by the capability gate.

Counting and importing have separate state. A pending estimate does not gate Start fresh, Not now, or Continue. A late result updates counts without changing the current step. Closing the view cancels its task; the probe cancels its utility worker and the history reader checks cancellation between batches.

## Shared count probe

`ArcProbe(arcDirectory:).run()` returns Sendable count values. It owns a utility task and never constructs a BrowserModel. The Settings wizard's `refreshCounts` and first run's `refreshProbe` use that same result. The former independent wizard counter and main-actor import-for-counts were removed. Space names are loaded separately, only for the Settings Review UI, on a utility worker; they never enter a probe result or CLI receipt.

The probe uses the importer's immutable sidebar parse and estimates non-container entries. These estimates can include folders and unsupported items, so Welcome says “about”. Archive is the raw alternating-entry count. History uses the existing streaming reader's `keptVisits`, matching plan F2: the six-row fixture keeps three. This resolves the earlier raw COUNT instruction in §2.2. It shares schema, scheme, transition and date filtering with import. Login/cookie counts use `ArcSecretsReader.countOnly`; `savedItems` also includes addresses/cards for the shared Passwords copy. Missing data stays nil; a failed kind does not erase other estimates.

Both readers use the existing `ArcSQLiteCopy`: private 0700 directory, exclusive 0600 files, DB plus WAL or journal, no SHM copy, quick_check, one 200 ms fresh-copy retry, and cleanup. The probe never opens a source SQLite connection. Profile basenames come from named metadata files, with no scan of unrelated files. Results contain no URLs, titles, usernames, or secret values.

A counts-only caller is available because Settings also needs this API:

```sh
Packages/OpenKit/.build/release/settings-preview probe --arc-dir /tmp/synthetic-source
Packages/OpenKit/.build/release/settings-preview render --first-run-only --out /tmp/first-run --scale both
```

The probe command requires an explicit source folder and emits counts/flags/timing JSON only. It never asks for consent or calls Keychain.

## Verification

No unit tests or desktop automation. `settings-preview check` exercises the real view-model entry points, settings files, SQLite readers, WAL copy path and action boundaries. The intentional first-run preview action is a logger with a canned outcome derived from a small synthetic import report. It is not a browser adapter or native launch acceptance.

`first-run-flows` covers fresh/skip/cancel, capability rejection, success/failure/retry states, default-browser failure/decline/success, and absence of completion/snapshot writes. `first-run-probe` covers the shared wizard/first-run result, empty state, a failing slow probe with live first-run buttons, a WAL writer with committed and uncommitted rows, and unchanged source hashes. All 30 checks pass ([receipt](first-run/checks.txt)). Existing settings checks also run. The PR contains the final verify-all table.

The skip render logs `ACTION runImport spaces=true archive=true history=false secrets=false`. Its adapter reports zero consent-bearing plans and zero **simulated** Keychain requests. This proves the wizard gate at that adapter, not interception of arbitrary Keychain APIs. No real Keychain API, real user import, engine build, or system-default change ran.

The [manual probe receipt](first-run/probe-checks.json) came from a hand-built private /tmp source with plan §10.1 JSON and SQLite shapes. Only the temporary driver and fixtures existed under /tmp; fixtures were deleted. Counts were exact: 2 Spaces, 9 non-container items, 3 Archive entries, 3 kept visits, 3 login/cookie rows. The WAL case kept 4 committed visits while an eighth row was uncommitted. The empty source returned sidebarFound=false. The malformed sidebar kept other counts. The 10,000-item/100,000-visit fixture completed in about 64 ms; the small source in about 31 ms. All O(n) count work runs on the utility task. These are probe measurements, not cold-launch, graph-install, or real-window performance results.

## Six screens for design review

All 12 synthetic PNGs were inspected. The found counts are estimates; the fake report uses the actual small fixture's import report, so its three Archive entries become two imported Archive entries and one skipped easel. A second skipped easel comes from the sidebar. Passwords show zero imported. [PNG hashes](first-run/sha256.txt) bind these images.

| Screen | 1x | 2x |
|---|---|---|
| Welcome | [PNG](first-run/first-run-welcome@1x.png) | [PNG](first-run/first-run-welcome@2x.png) |
| Import | [PNG](first-run/first-run-import@1x.png) | [PNG](first-run/first-run-import@2x.png) |
| Passwords | [PNG](first-run/first-run-secrets@1x.png) | [PNG](first-run/first-run-secrets@2x.png) |
| Progress | [PNG](first-run/first-run-progress@1x.png) | [PNG](first-run/first-run-progress@2x.png) |
| Report | [PNG](first-run/first-run-report@1x.png) | [PNG](first-run/first-run-report@2x.png) |
| Default browser | [PNG](first-run/first-run-default-browser@1x.png) | [PNG](first-run/first-run-default-browser@2x.png) |

The source-browser name is absent from Welcome status text and appears only on the allowed import button and inside the import flow. The plan's copy registry records these user-requested changes. The designer's review is pending before Step C.
