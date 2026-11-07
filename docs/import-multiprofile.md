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

The lead accepted the inactive-Profile Favorite's first-Space selection as a
marked guess. Settings preserves the live window layout. Older Settings
imports get no provenance migration because only pre-release development
builds made them. Physical Undo waits on Section 10's in-session Profile delete
(0702). Directory-limit boundary flows and parser decoded-memory bounds remain
follow-ups in `docs/followups.md`.

C1c completed the App validation on 2026-11-07. The fixed source is from
`1189743a`; later commits record documentation and receipts only. GitHub
reported the draft PR mergeable, so main was not merged again.

The first completed positive engine run passed but lost its outer wrapper
receipt when the turn was interrupted. The accepted positive receipt below
is its clean rerun. Every accepted App suite has zero foreground interruptions
and passes owned-process cleanup. The temporary RoleBroken App came from
C1b's recorded build with only the Default-role mapping removed; the fixed
Debug App was built in C1c's checkout. Both use main engine `af4b3cc3…`.

| Check | Result | Load 1/5/15, start → finish |
|---|---|---|
| Debug build | PASS | 12.48/6.54/4.49 → 41.01/20.95/10.72 |
| Focused verifier `roundtrip,import-arc --with-arc-data` | 3/3 PASS | 41.89/21.47/10.96 → 53.37/37.80/19.80 |
| Fresh copied-data CLI audit, twice + roundtrip | PASS; 46/46 nodes owned; IDs/directories stable; Archive repeat 0 inserted/21 duplicates | 45.52/37.19/20.10 → 45.52/37.19/20.10 |
| Archive checker negative proof | expected FAIL: 20 stored versus 21 expected | 44.34/37.20/20.31 → 44.34/37.20/20.31 |
| Off-screen `commandbar-render check`, quiet lock | 151/151 PASS; CPU p95 3.49 ms; wall p95 3.58 ms; inline completion p95 -0.167 ms, paired median +0.004 ms | 4.37/7.29/12.89 → 4.00/6.86/12.51 |
| Multi-profile App positives | 12/12 PASS across first-run, missing Local State, and Settings; cleanup PASS | 5.60/4.39/5.68 → 5.36/4.38/5.66 |
| Default-role code-break proof | expected FAIL: `MP_defaultRole` and Profile count fail in RoleBroken; cleanup PASS | 4.77/4.28/5.61 → 6.34/4.63/5.71 |
| Fixture negative proofs | all 11 original conditions FAIL as expected; cleanup PASS | 6.34/4.63/5.71 → 5.68/4.57/5.67 |
| Forced early-dialog failure | expected FAIL; zero owned processes/windows remain; cleanup PASS | 5.47/4.56/5.65 → 5.67/4.62/5.66 |
| Full `firstrun` | 64/64 PASS; cleanup PASS | 5.62/4.63/5.66 → 6.88/5.28/5.80 |
| Counts-only real-App audit, first-run and Settings | PASS; 46/46 nodes owned; Spaces 4/2; Favorites 6/5; Archive 9/12; History 24/51; no repairs; cleanup PASS | 6.89/5.38/5.83 → 6.98/5.42/5.84 |
| `routing` | 13/13 PASS; cleanup PASS | 7.28/5.57/5.88 → 7.31/5.65/5.91 |
| `sidebar` | 20 PASS; existing durable-cookie row SKIP (covered by `profiles`); cleanup PASS | 7.36/5.69/5.92 → 8.89/6.10/6.06 |
| `settings-preview` dispatcher | 46/46 checks PASS; 236 renders and key/dimension checks PASS | 8.90/6.15/6.08 → 7.03/6.29/6.14 |
| Engine fingerprint, no App launch | PASS; distribution `af4b3cc3…` and normalized embedded code match | 62.70/32.60/16.28 at receipt |
| Python syntax and `git diff --check` | PASS | 37.68/18.39/9.49 at initial source check |

The final full `verify-all --with-arc-data` runs after this documentation
commit. Its result table is recorded in [draft PR #221](https://github.com/SergeSerb2/open/pull/221),
bound to that final head. The lead alone marks the PR ready and merges it.
Counts-only receipts and private scripts remain local under `.re/s14/c1/`.
