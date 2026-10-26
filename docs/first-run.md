# First run: Steps A and B

Implements [first-run.md §11 A/B](plans/first-run.md#11-implementation-order-small-prs-each-step-files-then-acceptance), including review round 1. Steps C–F remain pending. This PR adds no App wiring, startup trigger, completion save, model swap, engine import adapter, real default-browser call or launch-timing claim.

`FirstRunViewModel` and `FirstRunView` live in OpenSettings. `FirstRunWindow.size` is 560 × 520 pt. OpenDesign Settings tokens supply the insets, grouped rows, typography and colors. `SettingsButtonStyle` supplies the prominent default button: accent/white while key, normal gray while inactive. Welcome uses a 28 pt semibold wordmark and 28 pt buttons. Import and Report pin the heading/footer around a scrolling middle with automatic indicators. Sparse screens center a visual and text above the footer. Step transitions use `Motion.selectionFade` and cut with Reduce Motion.

## App seam for Step C

```swift
let firstRun = FirstRunViewModel(
    settings: sharedSettings, actions: firstRunActions, directory: resolvedImportFolder)
let content = FirstRunView(model: firstRun)
```

The model strongly retains its action object and the Settings owner. `FirstRunActions` and `SettingsActions` inherit one `ImportActions` requirement. Forward import and default-browser operations to the same implementation. Pass the existing Settings owner with its injected shared SnapshotStore. First run creates no writer.

The app fills `arcIsRunning`. Progress assignments (`phaseText`, `progress`, `browserHasLanded`) are seams for the later adapter. `finishFirstRun(imported:)` uses the shared `ImportOutcome.didImportAnything` key set; canonical adapter keys and display aliases are handled once. The App must save successfully before recording completion or closing. Call `reportSaveFailure(imported:)` on failure: the fresh path has its own centered message. This step never writes `open.firstRun.completed` or saves a first-run snapshot.

Step C must verify the 36 pt inset beneath a real transparent title bar, keyboard order, key/inactive button styling, and the 80 pt application-icon frame (about 64 pt ink). The preview draws Open’s own icon; no reference artwork is copied.

One `ImportWizardViewModel` owns the plan and consent gate. `PasswordsImportCopy` supplies the shared body, later note, help variants and buttons. The capability stays OFF: both flows disable the checkbox and exclude it from selection. Capability-ON renders stop before Allow. Cancel/Back keep choices. The Failed footer returns to Import without changing them. Default-browser entry makes no system call; error and decline messages are exclusive, and an already-default browser offers only Start Browsing.

Counting and importing have separate state. Pending counts never gate first-run Start Fresh, Not Now or Continue. A late result updates counts without changing the step. Closing cancels the utility count task. Settings loads Space labels on that worker before enabling Review. `FirstRunView(startsProbe:false)` is used only by the CLI to hold deliberate counting/error render states; normal callers keep the default automatic probe.

## Shared count probe

`ArcProbe(arcDirectory:).run()` returns Sendable counts/flags, never URLs, titles, usernames, secrets or BrowserModel objects. Settings `refreshCounts` and first-run `refreshProbe` consume it. There is no second counter.

Archive selection and the full profile metadata merge are shared value helpers used by the probe and `ArcImporter.importAll`. Archive counts apply the same kind/reason/source/duplicate/live-ID/URL filters. `rawArchiveItems` is diagnostic only. Profile and engine counts include unused `StorableProfiles.json` metadata and preserve a named Default profile. Sidebar tab estimates still include unsupported entries, so Welcome says “about”.

History uses the existing reader’s filtered `keptVisits`. Saved-item counts use `ArcSecretsReader.countOnly`, including addresses/cards for the shared copy. Results retain counts per opaque profile ID, sum successful reads and append “(partial)” if another profile failed. All-failed counts remain unknown. A missing source stays absent.

SQLite reads copy first through `ArcSQLiteCopy`: private 0700 directory, exclusive 0600 files, DB plus WAL or journal, no SHM, quick_check, one 200 ms fresh-copy retry, then cleanup. Cancellation is checked between copy chunks and history batches. JSON/profile resolution and counting run on the utility worker. The later import model build remains main-actor work and is outside the probe; Step D must measure it on a large graph before app integration. No source SQLite connection is opened by the probe.

```sh
Packages/OpenKit/.build/release/settings-preview probe --arc-dir /tmp/synthetic-source
Packages/OpenKit/.build/release/settings-preview check
Packages/OpenKit/.build/release/settings-preview render --out /tmp/settings-panes --scale both
```

## Verification

No unit tests or desktop automation. All 32 `settings-preview check` flows pass ([receipt](first-run/checks.txt)). They exercise the real view-model entry points, files, importer, SQLite readers and action boundaries. The first-run logger is intentionally a preview adapter, with a canned outcome derived from an actual synthetic import report; this is not app launch acceptance.

| Check | Proof |
|---|---|
| first-run-actions-and-adapter-gate | Fresh/skip/cancel, unavailable checkbox, capability rejection, canonical adapter outcome keys, imported finish flag, retry, default-browser states, no completion or snapshot writes |
| first-run-probe | Shared consumer result, ready mapping labels, empty source, late failing probe, named Default through real CLI import, History WAL committed/uncommitted rows and unchanged source bytes |
| first-run-count-parity | Probe vs actual ArcImporter report/records; all Archive filters; unused named Default metadata; readable counts survive a bad second profile and show partial |
| probe-cancel-mid-copy | Cancels the actual utility task after the first 256 KiB of an owned 8 MiB fixture copy; verifies 0700/0600, partial copy removal and unchanged source |

The cancellation audit is internal and task-local. Its public verification entry point constructs only its own synthetic /tmp source; it accepts no user path. It cancels a real file copy instead of replacing the reader. The adapter-gate check counts **simulated** requests in that adapter only; it does not intercept arbitrary Keychain APIs. No real Keychain API, consent token, user-data import, engine build or system-default change ran.

The refreshed [manual receipt](first-run/probe-checks.json) uses a hand-built private /tmp fixture: 2 Spaces, 9 sidebar items, 3 raw Archive entries / 2 importable tabs, 3 kept visits, 3 login/cookie rows. The WAL case keeps 4 committed visits and ignores an uncommitted row. Empty and malformed sources retain honest absent/failed counts. The 10,000-item/100,000-visit probe completes under 1 second; see the receipt for measured times. Fixtures were deleted. This measures the probe, not launch or graph installation.

## Permanent render inventory

All 186 PNGs were rendered and visually inspected: 100 first-run images below and 86 Settings/Library images in [settings.md](settings.md). Each first-run state uses one explicit appearance, at both 1x and 2x. The offscreen renderer supplies key/inactive control state to the same button style; Step C verifies the native window transition. [SHA-256 receipts](first-run/sha256.txt) bind every first-run PNG. The unavailable Passwords screen is an unreachable copy reference; capability-ON images do not execute consent. Import hints, partial counts and worst-case reports are permanent renderer states.

| State | Dark 1x | Dark 2x | Light 1x | Light 2x |
|---|---|---|---|---|
| welcome | [PNG](first-run/first-run-welcome@1x.png) | [PNG](first-run/first-run-welcome@2x.png) | [PNG](first-run/first-run-welcome-light@1x.png) | [PNG](first-run/first-run-welcome-light@2x.png) |
| welcome-inactive | [PNG](first-run/first-run-welcome-inactive@1x.png) | [PNG](first-run/first-run-welcome-inactive@2x.png) | [PNG](first-run/first-run-welcome-inactive-light@1x.png) | [PNG](first-run/first-run-welcome-inactive-light@2x.png) |
| welcome-counting | [PNG](first-run/first-run-welcome-counting@1x.png) | [PNG](first-run/first-run-welcome-counting@2x.png) | [PNG](first-run/first-run-welcome-counting-light@1x.png) | [PNG](first-run/first-run-welcome-counting-light@2x.png) |
| welcome-nodata | [PNG](first-run/first-run-welcome-nodata@1x.png) | [PNG](first-run/first-run-welcome-nodata@2x.png) | [PNG](first-run/first-run-welcome-nodata-light@1x.png) | [PNG](first-run/first-run-welcome-nodata-light@2x.png) |
| welcome-saveerror | [PNG](first-run/first-run-welcome-saveerror@1x.png) | [PNG](first-run/first-run-welcome-saveerror@2x.png) | [PNG](first-run/first-run-welcome-saveerror-light@1x.png) | [PNG](first-run/first-run-welcome-saveerror-light@2x.png) |
| import | [PNG](first-run/first-run-import@1x.png) | [PNG](first-run/first-run-import@2x.png) | [PNG](first-run/first-run-import-light@1x.png) | [PNG](first-run/first-run-import-light@2x.png) |
| import-arcrunning | [PNG](first-run/first-run-import-arcrunning@1x.png) | [PNG](first-run/first-run-import-arcrunning@2x.png) | [PNG](first-run/first-run-import-arcrunning-light@1x.png) | [PNG](first-run/first-run-import-arcrunning-light@2x.png) |
| import-counting | [PNG](first-run/first-run-import-counting@1x.png) | [PNG](first-run/first-run-import-counting@2x.png) | [PNG](first-run/first-run-import-counting-light@1x.png) | [PNG](first-run/first-run-import-counting-light@2x.png) |
| import-nodata | [PNG](first-run/first-run-import-nodata@1x.png) | [PNG](first-run/first-run-import-nodata@2x.png) | [PNG](first-run/first-run-import-nodata-light@1x.png) | [PNG](first-run/first-run-import-nodata-light@2x.png) |
| import-parsehint | [PNG](first-run/first-run-import-parsehint@1x.png) | [PNG](first-run/first-run-import-parsehint@2x.png) | [PNG](first-run/first-run-import-parsehint-light@1x.png) | [PNG](first-run/first-run-import-parsehint-light@2x.png) |
| import-parsehint-running | [PNG](first-run/first-run-import-parsehint-running@1x.png) | [PNG](first-run/first-run-import-parsehint-running@2x.png) | [PNG](first-run/first-run-import-parsehint-running-light@1x.png) | [PNG](first-run/first-run-import-parsehint-running-light@2x.png) |
| import-partial | [PNG](first-run/first-run-import-partial@1x.png) | [PNG](first-run/first-run-import-partial@2x.png) | [PNG](first-run/first-run-import-partial-light@1x.png) | [PNG](first-run/first-run-import-partial-light@2x.png) |
| import-capability-on | [PNG](first-run/first-run-import-capability-on@1x.png) | [PNG](first-run/first-run-import-capability-on@2x.png) | [PNG](first-run/first-run-import-capability-on-light@1x.png) | [PNG](first-run/first-run-import-capability-on-light@2x.png) |
| secrets | [PNG](first-run/first-run-secrets@1x.png) | [PNG](first-run/first-run-secrets@2x.png) | [PNG](first-run/first-run-secrets-light@1x.png) | [PNG](first-run/first-run-secrets-light@2x.png) |
| secrets-on | [PNG](first-run/first-run-secrets-on@1x.png) | [PNG](first-run/first-run-secrets-on@2x.png) | [PNG](first-run/first-run-secrets-on-light@1x.png) | [PNG](first-run/first-run-secrets-on-light@2x.png) |
| progress | [PNG](first-run/first-run-progress@1x.png) | [PNG](first-run/first-run-progress@2x.png) | [PNG](first-run/first-run-progress-light@1x.png) | [PNG](first-run/first-run-progress-light@2x.png) |
| progress-history-landed | [PNG](first-run/first-run-progress-history-landed@1x.png) | [PNG](first-run/first-run-progress-history-landed@2x.png) | [PNG](first-run/first-run-progress-history-landed-light@1x.png) | [PNG](first-run/first-run-progress-history-landed-light@2x.png) |
| report | [PNG](first-run/first-run-report@1x.png) | [PNG](first-run/first-run-report@2x.png) | [PNG](first-run/first-run-report-light@1x.png) | [PNG](first-run/first-run-report-light@2x.png) |
| report-worst | [PNG](first-run/first-run-report-worst@1x.png) | [PNG](first-run/first-run-report-worst@2x.png) | [PNG](first-run/first-run-report-worst-light@1x.png) | [PNG](first-run/first-run-report-worst-light@2x.png) |
| report-saveerror | [PNG](first-run/first-run-report-saveerror@1x.png) | [PNG](first-run/first-run-report-saveerror@2x.png) | [PNG](first-run/first-run-report-saveerror-light@1x.png) | [PNG](first-run/first-run-report-saveerror-light@2x.png) |
| failed | [PNG](first-run/first-run-failed@1x.png) | [PNG](first-run/first-run-failed@2x.png) | [PNG](first-run/first-run-failed-light@1x.png) | [PNG](first-run/first-run-failed-light@2x.png) |
| default-browser | [PNG](first-run/first-run-default-browser@1x.png) | [PNG](first-run/first-run-default-browser@2x.png) | [PNG](first-run/first-run-default-browser-light@1x.png) | [PNG](first-run/first-run-default-browser-light@2x.png) |
| default-declined | [PNG](first-run/first-run-default-declined@1x.png) | [PNG](first-run/first-run-default-declined@2x.png) | [PNG](first-run/first-run-default-declined-light@1x.png) | [PNG](first-run/first-run-default-declined-light@2x.png) |
| default-error | [PNG](first-run/first-run-default-error@1x.png) | [PNG](first-run/first-run-default-error@2x.png) | [PNG](first-run/first-run-default-error-light@1x.png) | [PNG](first-run/first-run-default-error-light@2x.png) |
| default-already | [PNG](first-run/first-run-default-already@1x.png) | [PNG](first-run/first-run-default-already@2x.png) | [PNG](first-run/first-run-default-already-light@1x.png) | [PNG](first-run/first-run-default-already-light@2x.png) |

The Report uses red “Could not be read” count cells, “Not selected” for unrequested History, and one error or skipped-kind summary. No internal accounted/copy counters appear. The plan’s §4 records the shipped copy. Opus re-review remains pending before Step C.
