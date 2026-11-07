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

Physical deletion after Undo is not accepted yet. Main's Settings delete path
requires typed confirmation and defers loaded Chromium data until restart.
Import Undo removes the model entries but does not bypass that boundary or
claim that orphaned Archive/History/engine directories were erased.

Verification receipts and the counts-only real-data audit will be recorded
here after the required App and CLI runs.
