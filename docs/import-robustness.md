# Import robustness and Undo

C4 is draft [#224](https://github.com/SergeSerb2/open/pull/224) on
`s14/robustness`. It includes main through `7f405f3b` (#221, #216/#217, #220, #204, #225,
#219, #226, #222 and #227). The App Boosts seam stores no data. Extension
installs keep their separate queue. Neither is part of import Undo.

## Behavior

The shared App runner captures the model import inverse and committed store
receipts in one native Undo action. Archive receipts contain only inserted
stable IDs. History receipts contain the import keys, exact destination visit
IDs, newly created URL IDs and changed titles. Undo removes those visits and
keys, recomputes URL aggregates, removes newly created empty URLs, and restores
an old title only while the imported title still owns that value. Unrelated
visits remain, even when URL, time and transition equal an imported visit.
Redo keeps its replacement receipts for the next Undo. Native Undo/Redo
handlers retain each receipt until its action leaves the stack. A no-op repeat
adds no action and cannot release the earlier import's target.

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

Settings merge, rollback and native Undo/Redo publish one structural reload
per changed parent after the synchronous edit. Sidebar and engine observers
read the final graph once per parent. The model still uses each item's stable
ID and keeps the same one-step Undo.

The utility worker prepares optional JSON and Archive value records/payloads.
The main actor still constructs and merges the live sidebar model. Automation
builds alone run a 5 ms background main-queue watchdog, with one outstanding
ping. It records the overall maximum and each import phase's maximum and duration.
The watchdog stops on every exit. No debugger or external process probe
is used.

## Earlier CLI receipts (historical engine)

The earlier child's builds and verifiers used engine root `open-engine-s8-main`, recorded
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

## Real-App verification

Before-fix crash evidence is
`/Users/serge/Library/Logs/DiagnosticReports/Open-2026-11-07-120053.ips`:
EXC_BAD_ACCESS after a no-op Settings re-import and native Cmd+Z.
The stack is `ZombieObjectCrash` → `CrZombie forwardingTargetForSelector:` →
`swift_getObjectType` → `_NSUndoStack popAndInvoke` →
`NSUndoManager undoNestedGroup`. The Undo manager did not retain its target.
Each action now retains its receipt. The crashing build was not rerun.

`tools/e2e/import_robust.py` runs through the real App. It covers:

- Settings twice and first run → Settings, with all category counts.
- Import → no-op repeat → Cmd+Z → Cmd+Z → Cmd+Shift+Z, plus two real
  imports undone in order. Each row checks state and continued App replies.
- First-run and all-parts Undo/Redo, repeat after Undo, pending-batch Undo/Redo,
  quit during store Undo, exact visit identity, and newer title retention.
- Missing folder/sidebar/History/Profile, unreadable sources, truncated or
  invalid JSON, unsupported History schema, corrupt Archive, unreadable WAL,
  and a readable committed WAL under a held writer.
- Partial failure with successful parts followed by Undo.
- Six Spaces × 200 tabs, 2,000 Archive rows, 2 Profiles, 5,000 URLs and
  100,000 visits. History target is 1,400 ms (plan hard limit 3,000 ms),
  observed main-thread lag stays below 50 ms, and idle CPU stays below 1%.
  Ten seconds after import, store files and save/snapshot/mirror counters
  must stay fixed and the automation watchdog must be inactive.

On engine `d94583ef`, after notification batching, all 27 positive rows and
all 27 negative proofs completed. Negative mode breaks the fixture or action
and retains each original assertion. A forced failure with the actual Settings
sheet open proved graceful cleanup and zero owned windows/processes.
The full first-run suite passed 86 rows and focused multi-profile passed 17.
Six inherited Boosts persistence gates and the extension-engine completion
remain BLOCKED; the latter belongs to the full extension flow.
All successful receipts had zero interrupted attempts and clean shutdown.

The first negative attempt had a launch-readiness failure after five intended
failures. Its complete retry produced all 27 intended failures. The first
merged extension run reached 50 passing rows, then hit a sibling-module import
error under Python's isolated mode. The helper now loads its owned sibling by
exact path; the complete 86-row rerun passed. Both original receipts remain.

Release on `d94583ef` established the real sidebar stall before batching:
80.25 ms overall and 77.09 ms in sidebar landing at load 6.72/9.05/12.96.
There were 1,217 structural callbacks and 1,218 engine mirror syncs. Batching
reduces these to 15 and 16. The batched Debug App on the same engine measured
25.50 ms overall and 15.26 ms in sidebar landing at load 5.60/7.03/7.28;
100,000 visits took 713.67 ms. Idle CPU was 0.200%, with zero changed stores
and stable counters at load 5.24/6.88/7.22.

The final gate uses current main through `7f405f3b`, including Profile engine
#222, and `open-engine-s8-main` framework SHA-256
`2ecaeadab71b3da3e5bc65a3f5b77d80c7958e9d0faa8cd305a0fa29496ebb10`.
Its exact source head, Debug/Release fingerprints, App results, Release phase
lags and loads, idle evidence and full `verify-all --with-arc-data` table are
recorded in draft [#224](https://github.com/SergeSerb2/open/pull/224).
Earlier `d94583ef` results remain historical receipts. Each run names its engine.

Builds and the full verifier take Section 14 token B → `heavy.sh`. Each App
suite owns one screen-lock call; dedicated timing takes quiet → B → heavy →
screen. Priority and foreground guards run before screen use. Every source
and Open data root is synthetic and temporary. Used defaults are reset at
launch and restored in `finally`. Real Arc verification copies files first
and reports counts only. Private receipts: `.re/c4/` and `.re/c4b/`.

## Lead decisions and remaining boundaries

- A writer lock with a readable committed WAL succeeds through a private copy.
  The unreadable-WAL case reports failure. Treating every writer lock as an
  error would discard an available consistent snapshot.
- The lead approved the first-run failure line `Spaces: Not found` / `Spaces: Could not
  be read` under the existing heading, and the existing save-error copy reused
  for store Undo failure.
- The lead approved the small first-run model Undo hook, quit-drain hook and
  receipt APIs. Physical Profile teardown stays with Section 10.
- Parser decoded-memory/directory boundary qualification remains the existing
  multi-profile follow-up. This draft does not claim those parser limits are accepted. Final-engine
  receipts and loads are recorded in the PR.
