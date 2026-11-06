# First run

Implements [first-run.md §11 A/B](plans/first-run.md#11-implementation-order-small-prs-each-step-files-then-acceptance), including review round 1. Steps C/D now add the App window, startup detection, guarded completion save, shared import runner, model landing and Settings merge. Background History uses the same runner and Profile stores for first run and Settings. Passwords and cookies remain capability OFF. The default-browser offer uses the existing App service only on its button click.

`FirstRunViewModel` and `FirstRunView` live in OpenSettings. `FirstRunWindow.size` is 560 × 520 pt. OpenDesign Settings tokens supply the insets, grouped rows, typography and colors. `SettingsButtonStyle` supplies the prominent default button: accent/white while key, normal gray while inactive. Welcome uses a 28 pt semibold wordmark and 28 pt buttons. Import and Report pin the heading/footer around a scrolling middle with automatic indicators. Sparse screens center a visual and text above the footer. Step transitions use `Motion.selectionFade` and cut with Reduce Motion.

## App seam for Step C

```swift
let firstRun = FirstRunViewModel(
    settings: sharedSettings, actions: firstRunActions, directory: resolvedImportFolder)
let content = FirstRunView(model: firstRun)
```

The model strongly retains its action object and the Settings owner. `FirstRunActions` and `SettingsActions` inherit one `ImportActions` requirement. Forward import and default-browser operations to the same implementation. Pass the existing Settings owner with its injected shared SnapshotStore. First run creates no writer.

The app fills `arcIsRunning`. Progress assignments (`phaseText`, `progress`, `browserHasLanded`) are seams for the later adapter. `finishFirstRun(imported:)` uses the shared `ImportOutcome.didImportAnything` key set; canonical adapter keys and display aliases are handled once. The App must save successfully before recording completion or closing. Call `reportSaveFailure(imported:)` on failure: the fresh path has its own centered message. The App writes `open.firstRun.completed` only after `saveNow` succeeds.

Step C entry criteria:

- **N4:** Give report-saveerror a Try Again action that retries saving the pending imported model. The message must say the imported items are in the browser window behind this panel. Do not mark completion or close the panel until the save succeeds. Update §4 E-5 with that shipped text when Step C implements it.
- **N9:** Check the determinate progress fill uses the accent and the indeterminate bar animates in the real window. A still offscreen PNG does not prove native animation or activation.
- **#12:** Capture the real window and check that the 36 pt top inset clears the traffic lights.
- Check keyboard order, key/inactive button styling, and the 80 pt application-icon frame (about 64 pt ink). The preview draws Open’s own icon; no reference artwork is copied.

One `ImportWizardViewModel` owns the plan and consent gate. `PasswordsImportCopy` supplies the shared body, later note, help variants and buttons. The capability stays OFF: both flows disable the checkbox and exclude it from selection. Capability-ON renders stop before Allow. Cancel/Back keep choices. The Failed footer returns to Import without changing them. Default-browser entry makes no system call; error and decline messages are exclusive, and an already-default browser offers only Start Browsing.

Counting and importing have separate state. Pending counts never gate first-run Start Fresh, Not Now or Continue. A late result updates counts without changing the step. Closing cancels the utility count task. Settings loads Space labels on that worker before enabling Review. `FirstRunView(startsProbe:false)` is used by the App to start the utility probe after the first display, and by the CLI to hold deliberate counting/error render states.

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

No unit tests or desktop automation. All 37 `settings-preview check` flows pass ([receipt](first-run/checks.txt), regenerated from the same S5b acceptance command as `settings/checks.txt`, with no preview-delay default). They exercise the real view-model entry points, files, importer, SQLite readers and action boundaries. The first-run logger is intentionally a preview adapter, with a canned outcome derived from an actual synthetic import report; this is not app launch acceptance.

| Check | Proof |
|---|---|
| first-run-actions-and-adapter-gate | Fresh/skip/cancel, unavailable checkbox, capability rejection, canonical adapter outcome keys, imported finish flag, retry, default-browser states, no completion or snapshot writes |
| first-run-probe | Shared consumer result, ready mapping labels, empty source, late failing probe, named Default through real CLI import, History WAL committed/uncommitted rows and unchanged source bytes |
| first-run-count-parity | Probe vs actual ArcImporter report/records; all Archive filters; unused named Default metadata; readable counts survive a bad second profile and show partial |
| probe-cancel-mid-copy | Cancels the actual utility task after the first 256 KiB of an owned 8 MiB fixture copy; verifies 0700/0600, partial copy removal and unchanged source |

The cancellation audit is internal and task-local. Its public verification entry point constructs only its own synthetic /tmp source; it accepts no user path. It cancels a real file copy instead of replacing the reader. The adapter-gate check counts **simulated** requests in that adapter only; it does not intercept arbitrary Keychain APIs. No real Keychain API, consent token, user-data import, engine build or system-default change ran.

The refreshed [manual receipt](first-run/probe-checks.json) uses a hand-built private /tmp fixture: 2 Spaces, 9 sidebar items, 3 raw Archive entries / 2 importable tabs, 3 kept visits, 3 login/cookie rows. The WAL case keeps 4 committed visits and ignores an uncommitted row. Empty and malformed sources retain honest absent/failed counts. The 10,000-item/100,000-visit probe completes under 1 second; see the receipt for measured times. Fixtures were deleted. This measures the probe, not launch or graph installation.

## Permanent render inventory

All 214 PNGs were rendered and visually inspected: 128 first-run images below and 86 Settings/Library images in [settings.md](settings.md). Each first-run state uses one explicit appearance, at both 1x and 2x. The offscreen renderer supplies key/inactive control state to the same button style; Step C verifies the native window transition. [SHA-256 receipts](first-run/sha256.txt) bind every first-run PNG. The unavailable Passwords screen is an unreachable copy reference; capability-ON images do not execute consent. Import hints, partial counts, worst-case reports, single-item copy and large formatted counts are permanent renderer states. Import rows have minimum heights with vertical padding and grow for wrapped help. Default-browser status reserves the same 36 pt slot before and after the action. No-data Welcome and the fresh save error make Start Fresh the accent/default action.

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
| welcome-singular | [PNG](first-run/first-run-welcome-singular@1x.png) | [PNG](first-run/first-run-welcome-singular@2x.png) | [PNG](first-run/first-run-welcome-singular-light@1x.png) | [PNG](first-run/first-run-welcome-singular-light@2x.png) |
| import-singular | [PNG](first-run/first-run-import-singular@1x.png) | [PNG](first-run/first-run-import-singular@2x.png) | [PNG](first-run/first-run-import-singular-light@1x.png) | [PNG](first-run/first-run-import-singular-light@2x.png) |
| secrets-singular | [PNG](first-run/first-run-secrets-singular@1x.png) | [PNG](first-run/first-run-secrets-singular@2x.png) | [PNG](first-run/first-run-secrets-singular-light@1x.png) | [PNG](first-run/first-run-secrets-singular-light@2x.png) |
| report-singular | [PNG](first-run/first-run-report-singular@1x.png) | [PNG](first-run/first-run-report-singular@2x.png) | [PNG](first-run/first-run-report-singular-light@1x.png) | [PNG](first-run/first-run-report-singular-light@2x.png) |
| welcome-large | [PNG](first-run/first-run-welcome-large@1x.png) | [PNG](first-run/first-run-welcome-large@2x.png) | [PNG](first-run/first-run-welcome-large-light@1x.png) | [PNG](first-run/first-run-welcome-large-light@2x.png) |
| import-large | [PNG](first-run/first-run-import-large@1x.png) | [PNG](first-run/first-run-import-large@2x.png) | [PNG](first-run/first-run-import-large-light@1x.png) | [PNG](first-run/first-run-import-large-light@2x.png) |
| secrets-large | [PNG](first-run/first-run-secrets-large@1x.png) | [PNG](first-run/first-run-secrets-large@2x.png) | [PNG](first-run/first-run-secrets-large-light@1x.png) | [PNG](first-run/first-run-secrets-large-light@2x.png) |

The Report uses red “Could not be read” count cells, “Not selected” for unrequested History, and one error or skipped-kind summary. The R-2 sentence omits failed kinds. Partial-success E-2 copy uses secondary text; red count cells identify the failure. All displayed counts use `.formatted()` and singular/plural wording. Both flows display “Search engine” while retaining the adapter’s existing dictionary key. No internal accounted/copy counters appear. The plan’s §4 records the shipped copy. Opus re-review remains pending before Step C.

## Round-2 polish

The seven remaining Settings default buttons use prominent SettingsButtonStyle. Standalone sheets in settings-preview explicitly inherit the same normal SettingsButtonStyle as the app; defaults override it. This avoids native default-button styling hiding a missing prominent style in renders. The existing action/adapter CLI flow also checks single-item and large-count copy, partial-success summaries, and the fresh-primary decision. No Step C implementation was added.

## Steps C/D App verification

`App/FirstRun` hosts the shared design-reviewed view. `AppImportRunner` runs
sidebar/archive import for both first run and Settings. Import save failure
keeps the landed browser behind the panel; Try Again saves that pending model.
Start Fresh, Not Now and all-failed Continue save the default model. Unfinished first run cannot
autosave it. Existing harness launches pass `--skip-first-run`.

The `firstrun` real-App suite builds its source in a private temporary folder.
It covers filtered counts, session focus, archive dedupe, Settings re-import
and merge Undo, corrupt input, save failure/retry, quitting before finish,
and relaunch. Regression rows cover a browser Space rename saved when quitting
during a Settings import, a zero-item sidebar finishing on the original default
model, Welcome counting after close and Dock reopen, and a Settings import
preserving Never for a newly imported Profile after the first-run model swap.
It captures Welcome, Import, Progress, Report and the default
browser offer, compares progress-bar pixels, and measures heading clearance
against native traffic-light frames. It never clicks the system-default setter.
Receipts and images stay in the ignored suite output folder. See
[automation.md](automation.md) for the command and launch overrides. Loaded
Debug first-content samples do not qualify the idle 250 ms Release budget.


## Steps E/F: background History

`AppImportRunner` saves and opens the browser at the sidebar/archive landing
gate. It then clears `importInProgress`; ordinary browser saves work while
History runs. A separate runner guard rejects overlapping imports. The import
task retains the flow when its window closes. It streams the existing
`ArcHistoryReader` into `AppStores.history(for:)`, one batch of at most 5,000
visits per transaction. The existing `history_import_keys` makes a repeat
insert zero visits. No parallel history store or engine change is added.

The importer returns the original source directory per Profile. Destination
collision suffixes do not change the source or visit key. Existing Profile IDs
and the Default mapping are authoritative on Settings re-import. Unmapped
source Profiles are not merged into Default. Phase P-3 uses the probe estimate
for determinate progress, and P-5 appears after landing. Both reports show the
History count or E-2 after a failed read. When the source was uncountable, the
failed count includes only visits known from the probe; no source count is
invented.

Passwords stay disabled. Both App adapters return capability OFF, and the
runner contains no consent-token, crypto or secrets-reader call. The shared
Continue Without Passwords action clears the selection. `ArcProbe` remains
count-only. The F10 receipt states this code-path proof; it does not claim to
intercept system Keychain APIs.

The real-App suite adds a live WAL writer, a 5,000-visit import with browsing
and saving before completion, closing the progress window, a History-only
Settings repeat, and E-2 after a source becomes unreadable. OCR inspection runs
on a utility worker after snapshot capture. Only `inspect` gets a bounded
180-second client timeout. Vision `CRImageReaderError` code 1 gets one retry
after 250 ms; `ocrRetries` records it. Assertions keep their original limits.

Alternate application icons are rendered at selection time and saved below
`Cache/AppIcons/<ID>-v1.png` in the data root. Restore reads and decodes that PNG
off the main actor, including TIFF preparation. One utility-priority main-queue
turn sets the process icon at least about one second after content. Read-back
separates worker preparation, main preparation and the AppKit setter. Main
decode/preparation must stay below 5 ms; setter cost is reported separately.
Default selection performs no restore work. A missing or invalid cache reports
an Icon pane error and can be repaired by selecting the icon again. Encoded
images are limited to 16 MiB and decoded dimensions to exactly 1024 × 1024.


Import age starts when Open adds a Today tab. Pinned tabs and Favorites keep
the source times. A Settings merge treats IDs already in the target Profile's
archive as duplicates, after one off-main batch query per Profile. The real-App
fixture uses 48-hour-old Today tabs with the normal twelve-hour archive setting,
then finishes, relaunches and imports again. It also closes a tab and a former
Favorite through production commands before repeat import. Source files stay
unchanged. See [the Steps E/F receipt](first-run/steps-ef-verification.md).

Final M5 acceptance (2026-11-06): `firstrun` passes 52/52 rows in three
consecutive runs. Shell, features, routing, commandbar and the full M5 gate
pass. F12: first-run first content 371 ms vs 250 ms budget: NOT MET; normal launch 382 ms on main and branch, so first run adds no cost; the 250 ms cold-launch budget is the open Section 8 item 13 / Section 16 launch budget.
Selected imported-tab paint passes at 205 ms against 700 ms.
Icon worker preparation is 8.556–9.096 ms; main preparation is
below 0.001 ms and the accepted AppKit setter is 24.163–25.298 ms. The
[receipt](first-run/steps-ef-verification.md) keeps every attempt and load.
