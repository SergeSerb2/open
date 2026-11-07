# Import from Arc: multiple Profiles

The source resolver reads the observed nested custom Profile reference in both
Spaces and Favorites. It uses Local State for Profile names. Optional Storable
Profile metadata files remain guesses because they are absent in the real
sample.

The App creates live Profiles through the normal model command. Stable import
IDs make re-import idempotent. Open allocates named destination directories;
`sourceProfileDirectories` retains the Arc source directories for History.
An existing Profile with the same display name stays separate. Settings adds
a numeric display-name suffix to the imported Profile.

Archive records follow the destination Space's live Profile. History uses the
source-directory map and writes to that live Profile's existing HistoryStore.
Profile-scoped routing uses Section 10's existing destination resolver. No
secret, consent, engine, or extension-install code changes here.

The synthetic `firstrun` rows `MP_*` exercise both first run and Settings with
2 Profiles, 2 Favorites, separate Archive and History stores, 3 routing targets,
an occupied `Profile 1` folder, a same-name existing Profile, re-import, and
one model Undo. The focused command is:

```sh
OPEN_E2E_FIRSTRUN_MULTIPROFILE_ONLY=1 tools/e2e/engine_e2e.py --only firstrun
```

Run it under the shared on-screen lock. `OPEN_E2E_IMPORT_NEGATIVE=1` deliberately
misroutes the synthetic data, corrupts one saved Profile reference, and adds
an intervening command before Undo. Each unchanged `MP_*` condition must fail.
The next normal run restores the source and destination with fresh roots.
`OPEN_E2E_IMPORT_EARLY_FAILURE=1` stops inside the open import dialog to verify
that the suite’s `finally` path restores defaults and closes its owned App.

Physical deletion after Undo is not accepted yet. Main's Settings delete path
requires typed confirmation and defers loaded Chromium data until restart.
Import Undo removes the model entries but does not bypass that boundary or
claim that orphaned Archive/History/engine directories were erased.

Verification on 2026-11-06 is partial. The initial implementation passed the
full `firstrun` suite (62/62), its 10 multi-profile positives, and all 10
negative proofs. A real-App audit of that revision imported 6 Spaces, 11
Favorites, 21 Archive rows and 75 History visits with 0 missing-Profile
repairs through both first run and Settings. Archive split 9/12 and History
split 24/51 across the two imported Profiles.

Later changes fix session ownership, recover source directories without
Local State, and keep an existing Default separate in Settings. Debug and
Release builds passed. The latest copied-data CLI audit passed twice:
2 exact Profile names, 6 Spaces split 4/2, Favorites split 6/5, 46/46 nodes
owned by the correct Profile, 31 pinned tabs, 1 Today tab, 2 folders, 1 split,
4 icons and 5 exact raw theme JSON values. All 21 Archive rows carry their
owner Profile ID; repeat inserts 0 and reports 21 duplicates. Profile IDs
and destination directories stay stable, and roundtrip exits 0. Eight
mapped session pairs produce one source selection in the correct Profile.
The CLI audit does not prove the latest App History installation or repair
notice path.

Latest App acceptance is **UNVERIFIED**. Repeated multi-profile runs were
interrupted when the unowned UserNotificationCenter took the foreground.
The final read-only foreground check still found it in front. All owned
Apps exited and cleanup passed; no desktop interaction was attempted.
The latest 11 positive and negative rows (including `MP_session`), forced
early-dialog cleanup, full `firstrun`, real-App data audit, `routing`, and
`sidebar` must run after that blocker is gone. Earlier passes do not accept
the later changes.

An old Settings import may have merged Arc Default into an arbitrary live
Default ID. This change has no provenance migration for that earlier
behavior. Existing sidebar IDs remain authoritative; same-name Profiles
stay separate. The lead must decide whether to add a migration.

Every build/verify used the recorded main engine `af4b3cc3…`, the Section A
lock and `heavy.sh`. App runs also used the screen lock and priority check.
Loads below are 1/5/15-minute averages, start → finish, rounded to 2 decimals.
Older wrappers record loads before queuing; rows with an actual-start
receipt use that value. The latest Debug build waited 1,215 seconds for its
slot. These are functional receipts, not quiet-machine timing acceptance.

| Check | Exact result | Load start → finish |
|---|---|---|
| Baseline Debug build | PASS | 21.74/19.36/13.94 → 58.56/40.26/24.35 |
| Implementation Debug build | PASS | 18.90/31.68/26.40 → 75.90/56.59/38.64 |
| Baseline copied-data real-App audit | exit 0; exposed collapsed ownership and Settings merge gaps | 47.76/54.21/41.55 → 45.53/53.64/41.42 |
| Initial corrected real-App audit | PASS counts/ownership in both paths; normal cleanup | 38.48/50.85/40.89 → 42.53/51.31/41.17 |
| Initial MP positives | 10/10 PASS; cleanup PASS | 48.17/52.33/41.59 → 47.85/52.12/41.64 |
| Initial MP negative proof | 10/10 FAIL as intended; cleanup PASS | 50.34/52.57/41.86 → 52.96/52.88/42.21 |
| Initial full `firstrun` | 62/62 PASS; cleanup PASS | 56.41/53.54/42.69 → 52.89/51.77/43.25 |
| Session Debug build | PASS | 48.82/50.70/43.19 → 43.87/49.23/42.95 |
| Latest source-map Debug build | PASS | 75.19/77.77/64.41 → 54.77/50.77/53.20 |
| First latest MP run | INTERRUPTED, then fixture retry error; fixture reset fixed | 70.06/54.22/53.96 → 70.75/55.35/54.37 |
| Latest MP retry | all 3 attempts INTERRUPTED; cleanup PASS | 40.33/45.37/50.21 → 36.63/43.77/49.35 |
| First focused verifier | Release build/roundtrip PASS; old default-only Archive checker FAIL | 35.84/46.17/49.66 → 41.62/47.50/49.84 |
| Corrected Archive checker negative proof | expected FAIL after deleting 1 row in a private Profile-2 output store (20 ≠ 21) | 19.66/31.96/42.44 → 19.66/31.96/42.44 |
| Corrected focused verifier (`roundtrip,import-arc --with-arc-data`, includes build) | 3/3 targets PASS | 19.66/31.96/42.44 → 24.26/32.52/42.52 |
| Full verifier | 22 PASS, 2 FAIL targets; details below | 24.26/32.52/42.52 → 17.19/29.01/37.23 |
| Copied-data CLI audit | PASS twice + roundtrip | 17.19/29.01/37.23 → 17.19/29.01/37.23 |
| Enhanced copied-data CLI audit | PASS stable names/IDs/directories, content and Archive ownership | 15.04/22.84/33.03 → 15.04/22.84/33.03 |
| Final `git diff --check` and Python compile (3 changed Python files) | PASS | 17.06/17.67/25.03 |

The full gate summary follows. `commandbar-render` passed 149/151 rows. CPU
p95 was 11.42 ms against 8 ms and extra completion p95 was 0.523 ms against
0.3 ms, at load 34.7/42.3/43.2. `sitecontrol-render` passed 1536/1539 rows
with 4 INFO rows. F25 attempts 1/2/3 were interrupted at load1
18.36/18.25/18.47 by the same foreground process. Its highlight p95 <2 ms
row failed; that row does not emit a numeric highlight p95. The nearby
editor CPU diagnostic was 20.523 ms against 12 ms at load1 17.29.
No threshold or baseline changed. TANDEM 4l treats timing misses under
load as reported misses, not PR blockers; foreground interruptions still
leave App acceptance open.

| Target | Result | Seconds |
|---|---|---|
| build | PASS | 4 |
| commands-demo | PASS | 5 |
| roundtrip | PASS | 1 |
| space-legacy | PASS | 2 |
| space-editor | PASS | 10 |
| space-pad-compare | PASS | 4 |
| suggest-check | PASS | 36 |
| commands-dump | PASS | 0 |
| route | PASS | 11 |
| favicons | PASS | 2 |
| media-demo | PASS | 0 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 1 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 3 |
| settings-preview | PASS | 92 |
| sidebar-render | PASS | 116 |
| sidebar-compare | PASS | 198 |
| commandbar-render | FAIL | 48 |
| features-render | PASS | 106 |
| extensions-render | PASS | 10 |
| sitecontrol-render | FAIL | 98 |
| boosts | PASS | 5 |
| import-arc | PASS | 1 |

Receipts are private counts-only files under `.re/s14/c1/`; the audit table is
`.re/s14/c1-audit.md`. Do not commit source copies, private names, IDs, URLs
or titles. Final source checks passed. Owned real-data copies, App output roots
and their caches were removed. The final process check found 0 owned Open
processes.
