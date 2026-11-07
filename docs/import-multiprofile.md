# Import from Arc: multiple Profiles

The source resolver reads the observed nested custom Profile reference in both
Spaces and Favorites. It uses Local State for Profile names. Optional Storable
Profile metadata files remain guesses because they are absent in the real
sample.

The App creates live Profiles through the normal model command. Stable import
IDs make re-import idempotent. Open allocates named destination directories;
`sourceProfileDirectories` retains the Arc source directories for History.
Settings and every path that merges into a live model map Arc's DEFAULT key
`{default:true}` to `app.model.defaultProfile`. The importer exposes its
`defaultID` as `sourceDefaultProfileID`, so this match uses the role, independent
of names, IDs or directory strings. Default keeps its existing engine context
and logins. Spaces, Favorites, routing destinations, History and Archive share
that one `profileMapping`. A second Settings import adds no Profiles, Spaces
or tabs. Named Arc Profiles match only their stable import ID; a same-name
live Profile without that ID stays separate and the new name gets a suffix.

Archive records follow the destination Space's live Profile. History uses the
source-directory map and writes to that live Profile's existing HistoryStore.
Profile-scoped routing uses Section 10's existing destination resolver. No
secret, consent, engine, or extension-install code changes here.

The synthetic `firstrun` rows `MP_*` exercise both first run and Settings with
2 Profiles, 2 Favorites, separate Archive and History stores, 5 routing targets,
an occupied `Profile 1` folder, a same-name existing Profile, re-import, and
one model Undo. Settings starts with a live Default with its own random ID;
`MP_defaultRole` requires that Arc Default Spaces use it, that no new
"Default…" Profile appears, and that only the named Arc Profile is created.
The same rows check Default Favorites, routing and per-Profile stores.
The focused command is:

```sh
OPEN_E2E_FIRSTRUN_MULTIPROFILE_ONLY=1 tools/e2e/engine_e2e.py --only firstrun
```

Run it under the shared on-screen lock. `OPEN_E2E_IMPORT_NEGATIVE=1` deliberately
misroutes the synthetic data, corrupts one saved Profile reference, and adds
an intervening command before Undo. The original 11 unchanged `MP_*` conditions must fail. `MP_defaultRole` gets
a separate code-break proof: remove the role mapping, build the real App,
observe that row fail, then restore the fix.
The next normal run restores the source and destination with fresh roots.
`OPEN_E2E_IMPORT_EARLY_FAILURE=1` stops inside the open import dialog to verify
that the suite’s `finally` path restores defaults and closes its owned App.

Physical deletion after Undo is not accepted yet. Main's Settings delete path
requires typed confirmation and defers loaded Chromium data until restart.
Import Undo removes the model entries but does not bypass that boundary or
claim that orphaned Archive/History/engine directories were erased.
C4 adds logical removal of newly inserted Archive rows and History visits
as part of the same Undo; its App verification is tracked separately in
[robustness verification](import-robustness.md).

The lead accepted the inactive-Profile Favorite's first-Space selection as a
marked guess. Settings preserves the live window layout. Older Settings
imports get no provenance migration because only pre-release development
builds made them. Physical Undo waits on Section 10's in-session Profile delete
(0702). Directory-limit boundary flows and parser decoded-memory bounds remain
follow-ups in `docs/followups.md`.

Review-fix verification is pending. The earlier revision passed an initial
62/62 first-run run and 10 negative proofs, but later session changes were
blocked by the macOS UserNotificationCenter crash dialog. Those older results
do not accept the review fix. Fresh receipts will be recorded below.

Review-fix build and CLI checks passed with engine `af4b3cc3…`. The temporary
App with the role mapping removed also built, and the fixed Debug App was
rebuilt afterward. It will be used only for the negative proof.

| Review-fix check | Result | Load 1/5/15, start → finish |
|---|---|---|
| Debug build | PASS | 16.90/16.96/22.89 → 20.65/18.76/22.80 |
| Focused verifier, `roundtrip,import-arc --with-arc-data` | 3/3 targets PASS | 18.01/18.32/22.48 → 24.45/21.45/23.09 |
| Copied-data CLI audit, twice + roundtrip | PASS; stable IDs/directories; 46/46 nodes owned; Archive repeat 0 inserted/21 duplicates | 19.92/20.63/22.73 → 19.92/20.63/22.73 |
| Temporary broken-mapping Debug build | PASS, negative App prepared | 19.53/20.54/22.69 → 18.36/20.23/22.54 |
| Restored fixed Debug build | PASS | 18.36/20.23/22.54 → 17.88/20.03/22.43 |
| Archive checker negative proof | expected FAIL, 20 stored ≠ 21 expected | 16.53/19.57/22.21 → 16.53/19.57/22.21 |

Child C1c resumed the same source head (`1189743a`) on 2026-11-07 in its own
worktree. GitHub reports the draft PR mergeable, so main was not merged again.
The fresh off-screen receipts are:

| C1c check | Result | Load 1/5/15, start → finish |
|---|---|---|
| Debug build | PASS | 12.48/6.54/4.49 → 41.01/20.95/10.72 |
| Engine fingerprint, no App launch | PASS, required distribution `af4b3cc3…` | 62.70/32.60/16.28 at receipt |
| Focused verifier, `roundtrip,import-arc --with-arc-data` | build/roundtrip/import-arc: 3/3 PASS | 41.89/21.47/10.96 → 53.37/37.80/19.80 |
| Fresh copied-data CLI audit, twice + roundtrip | PASS; 46/46 nodes owned; 6 Spaces split 4/2; Favorites 6/5; Archive 9/12; stable IDs/directories; repeat 0 inserted/21 duplicates | 45.52/37.19/20.10 → 45.52/37.19/20.10 |
| Archive checker negative proof | expected FAIL, 20 stored ≠ 21 expected | 44.34/37.20/20.31 → 44.34/37.20/20.31 |
| Off-screen `commandbar-render check`, quiet lock | 151/151 PASS; CPU p95 3.49 ms, wall p95 3.58 ms; inline-completion p95 −0.167 ms, paired median +0.004 ms | 4.37/7.29/12.89 → 4.00/6.86/12.51 |

The positive App suite waits for the foreground check to stop reporting
UserNotificationCenter. The wait polls once per minute with no section,
heavy, or screen lock held. No latest App acceptance is claimed yet.
