# Import robustness and Undo

C4 is implementation draft [#224](https://github.com/SergeSerb2/open/pull/224)
on `s14/robustness`, stacked on Section 14
PR #221 (`s14/audit-multiprofile`). The base was refreshed to `42ff5a08`.
`origin/main` at `7b3ab45f` is already an ancestor. This document records
implementation and CLI evidence. It does not accept the real-App flows.

## Behavior

The shared App runner captures the model import inverse and committed store
receipts in one native Undo action. Archive receipts contain only inserted
stable IDs. History receipts contain the import keys, exact destination visit
IDs, newly created URL IDs and changed titles. Undo removes those visits and
keys, recomputes URL aggregates, removes newly created empty URLs, and restores
an old title only while the imported title still owns that value. Unrelated
visits remain, even when URL, time and transition equal an imported visit.
Redo keeps its replacement receipts for the next Undo.

Undo permanently stops later import batches. Store Undo/Redo waits for the
active import's last receipt and runs in order on the stores' own queues.
A new import waits for pending store work. Quit drains it before saving and
shutting down. No UndoManager group spans an `await`.

First-run replacement restores model contents in place, retaining the installed
model's observers. The only OpenModel hook is
`BrowserModel.registerImportedReplacementUndo(restoring:)`. Physical Profile
directories and loaded engine contexts remain Section 10's boundary. Undo
removes logical Archive/History rows; it does not erase those directories.

Missing sidebar/History files report `Not found`. Malformed or unreadable
files report `Could not be read`. Partial failures retain the successful parts
and their Undo receipts. The first-run failure screen adds a `Spaces:` value
under its existing heading. Settings and first run preserve the actual failure
value instead of replacing every failure with the same text.

The utility worker prepares optional JSON and Archive value records/payloads.
The main actor still constructs and merges the live sidebar model. Automation
builds alone run a 5 ms background main-queue watchdog, with one outstanding
ping. The watchdog stops on every exit. No debugger or external process probe
is used.

## Checks run on the M5

All App builds and verifiers used engine root `open-engine-s8-main`, recorded
framework SHA-256
`af4b3cc3ad1b42439b229d79c8f7a869b13b0d3165733fba6c023e202340d1a5`.
They ran under Section 14 token B, then `heavy.sh`. CLI timing took the quiet
lock outside any heavy slot. Private logs are in `.re/c4/`.

| Check | Result | Load 1/5/15, start → finish |
|---|---|---|
| Instrumented baseline Debug build | PASS; retained at `.re/c4/baseline/Open.app` | 41.01/20.95/10.72 → 61.52/37.34/18.99 |
| Initial implementation Debug build | PASS | 22.84/24.18/20.01 → 31.89/26.64/21.12 |
| Quit-drain Debug build | PASS | 9.80/14.68/17.78 → 9.61/14.40/17.63 |
| Initial scoped verifier, `roundtrip,import-arc --with-arc-data` | 3/3 PASS, before the final receipt review | 10.50/17.33/19.05 → 8.21/16.00/18.49 |
| Full verifier | INTERRUPTED; not an acceptance receipt | 24.29/25.95/21.35 → 10.93/18.79/19.65 at interruption |
| Release `openkit` build | PASS | 5.00/9.19/14.41 → 4.71/8.99/14.27 |
| Initial large synthetic CLI import + roundtrip + two-Profile History repeat/failures | 13/13 assertions PASS | 4.40/8.64/14.02 → 4.29/8.54/13.96 |
| Final Debug build after receipt review and base refresh | PASS | 4.34/6.64/12.20 → 4.33/6.52/12.06 |
| Final scoped verifier, `roundtrip,import-arc --with-arc-data` | 3/3 PASS; build 64 s, roundtrip 1 s, import-arc 1 s | 4.33/6.52/12.06 → 6.27/6.62/11.68 |
| Final large CLI flow after receipt review | 13/13 assertions PASS; 100k visits 0.891 s | 3.75/5.77/10.93 → 4.01/5.79/10.90 |
| Final Python compilation, fixture generation, whitespace and engine fingerprint | PASS; embedded/distribution code hashes match | 4.35/5.22/10.02 → 4.35/5.22/10.02 |

The first full verifier was stopped after discovering that it included native
screen checks while UserNotificationCenter was in front. Its `space-editor`
result is discarded. The trap printed `sidebar-render FAIL 0`; that line is a
manual interruption, not an assertion failure. Other completed rows were
build, commands-demo, roundtrip, space-legacy, space-pad-compare, suggest-check,
commands-dump, route, favicons, media-demo, sleep-demo, adblock-perf,
adblock-catalog, profiles and settings-preview. Later targets did not run.
This incomplete run does not replace the required final full gate.
Interim Python/fixture/whitespace checks also passed; their loads were not
captured consistently. The final recorded repeat above supersedes them. The
initial engine fingerprint also passed; its load was not separately captured.

The CLI fixture has 6 source Spaces, 1,231 sidebar items, 2,000 Archive rows,
2 Profiles, 5,000 URLs and 100,000 visits. Both History stores had 50,000 visits
and keys, correct aggregate visit/typed counts, and `PRAGMA quick_check=ok`.
The repeat inserted zero visits and reported 100,000 duplicates. The first
100,000 visits took 0.793 s initially and 0.891 s after the final review
through the CLI, including process launch.
These are CLI results only; they do not establish the App's 1.4 s target.

A writer held an uncommitted transaction on a synthetic WAL database. Import
read the committed private snapshot and left source DB/WAL hashes unchanged.
An unreadable WAL, schema version 99, and missing History each returned the
expected CLI error and exit 4. Source locks never touched the user's Arc files.

## Remaining App acceptance

UserNotificationCenter remains the foreground app. No C4 App suite has run.
Do not launch Open or touch the dialog while it remains. Poll once per minute
without holding locks. The M1 remains on HOLD.

`tools/e2e/import_robust.py`, registered as `--only import-robust`, covers:

- Settings twice and first run → Settings, with all category counts.
- First-run and all-parts Undo/Redo; re-import after Undo; quit during pending
  store Undo; Undo/Redo during a pending History batch; existing-row and title
  retention.
- Missing folder/sidebar, unreadable folder, truncated/invalid sidebar, missing
  History, unsupported schema, corrupt Archive, missing Profile, unreadable
  WAL, and a readable WAL under a writer lock.
- Partial Archive/History failure with successful sidebar and other-Profile
  History, followed by Undo.
- The large fixture, App History ≤1,400 ms (plan hard limit 3,000 ms), maximum
  main lag <50 ms, and stable stores/snapshot counters plus CPU <1% after
  ten seconds of idle time.

Each row retains its original assertion in negative mode. The fixture, input,
App actions or automation delay breaks that condition. Negative proofs and the
forced early-sheet failure cleanup proof have not run. The suite resets its
used defaults at launch and restores them in `finally`; each launch has a
synthetic source and a temporary Open data root.

Once the foreground and priority checks permit screen use, run each suite in
its own on-screen lock invocation:

```sh
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --only import-robust
OPEN_E2E_IMPORT_ROBUST_NEGATIVE=1 /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --only import-robust
OPEN_E2E_IMPORT_ROBUST_EARLY_FAILURE=1 /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --only import-robust
/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --only firstrun
OPEN_E2E_FIRSTRUN_MULTIPROFILE_ONLY=1 /usr/bin/lockf -k /tmp/open-onscreen-e2e.lock tools/e2e/engine_e2e.py --only firstrun
```

The negative and cleanup commands must fail for their deliberate conditions;
inspect their rows and cleanup result. Timing misses under load need a bounded
quiet rerun with load averages. Baseline/fixed App timing is still unmeasured.
`OPEN_E2E_IMPORT_ROBUST_ONLY=timing` selects the large fixture.
`OPEN_E2E_APP_BUNDLE` is forwarded through the harness's bundle override.
Use an automation Release build for the final speed qualification. Complete the
full verifier when its native gates can run under the screen rules.

## Decisions for the lead

- A writer lock with a readable committed WAL succeeds through a private copy.
  The unreadable-WAL case reports failure. Treating every writer lock as an
  error would discard an available consistent snapshot.
- Approve the first-run failure line `Spaces: Not found` / `Spaces: Could not
  be read` under the existing heading, and the existing save-error copy reused
  for store Undo failure.
- Accept the small first-run model Undo hook and quit-drain hook; review the new
  receipt APIs. Physical Profile teardown stays with Section 10.
- Parser decoded-memory/directory boundary qualification remains the existing
  multi-profile follow-up. This draft does not claim that those limits or
  App responsiveness are accepted.
