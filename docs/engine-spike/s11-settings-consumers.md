# Settings consumers: real-App verification

Implementation: `a72c4602`, with `origin/main` merged at `eaa70c28`.
Engine framework SHA-256: `2ecaeadab71b3da3e5bc65a3f5b77d80c7958e9d0faa8cd305a0fa29496ebb10`.
All runs use the real Debug App and automation socket. No unit tests, desktop
input, debugger, Arc launch, engine rebuild, or baseline change was used.

Restore-on retains saved standard windows, frames, sidebar widths, Spaces and
selections. Restore-off replaces only window states before T2. It opens one
1280 × 800 window centered in the main screen's visible frame, with the most
recent standard window's Space and selection. Optional snapshot focus dates
supply recency without another store. The sidebar model stays intact. Little
Open sessions never restore. A fresh fallback keeps its existing intake tag
when its window state is replaced.

Clear Browsing Data invokes main's granular native API, then removes matching
terminal App rows after native success. The App list is session-only. Tests use
real completed, failed, cancelled, running and paused transfers, another
Profile, all five ranges, exact remaining row IDs, Library rows and file hashes.
The All time case combines history, cookies, cache and downloads. Invalid empty
selections leave both History and Downloads unchanged. Range fixtures age real
transfers through a bounded Debug automation command; they do not invent rows.

History opens with the front standard window's focused Space Profile, or the
default Profile without a standard window. The checks use two actual windows
and seed a stale picker value before each opening. Cmd+Y, menu and command-bar
Return use the real event paths. A manual picker choice remains while visible.
The Settings Profile page retains its five parity rows; it has no History row
or new hook.

The [read-only RE audit](../re/downloads-s11.md#quit-warning-setting-consumer-audit-2026-11-07)
is **INCONCLUSIVE** about a preference gate on Arc's download quit warning.
Both values therefore keep Open's specific Downloads alert. No generic quit
warning UI is implemented. The owner-death bypass is unchanged.

| Check | Machine | Result | Raw receipt under `.re/settings-consumers/` |
|---|---|---|---|
| Final Debug build | M5 | PASS | `build-final-m5.log` |
| Final Debug build | M1 | PASS; existing Xcode headermap/signing and simulator diagnostics | `m1-final/build-final-m1.log` |
| Full relaunch | M1 | 7/7 PASS; 20/20 real quit/relaunch soak | `m1-final/final-relaunch-m1.json` |
| Full Downloads | M1 | 46/46 PASS | `m1-final/final-downloads-m1.json` |
| Full History | M1 | 31/31 PASS | `m1-final/final-history-m1.json` |
| Full window / display | M5, AW2726DM 1× | 82 PASS; 2 Debug timing SKIP; 1 BLOCKED | `final-window.json` |
| Full verify-all | M5 | 22 PASS; 2 timing-only FAIL | `full-verify/summary.txt` |
| Negative controls | M5 | 23/23 intended assertions FAIL; cleanup PASS; zero interruptions | `negative-coverage.json` |

The window run has no interruptions and passes cleanup. Its existing
`cold_fresh_profile` and `warm_existing_profile` budget rows are skipped in
Debug. `engine_failure_alert` is BLOCKED: its deliberately missing framework
needs first qualification off screen or on the M1 under TANDEM 8b. The lead
blocked the M1 at 16:52. A local runner leaves only that check unrun; the
committed suite and all window/display gates are unchanged.

The full verifier's `commandbar-render` rows 150/151 miss timing limits at
load 35.1: CPU p95 10.86 ms and inline overhead +0.347 ms. Main fails the same
rows under load. The lead's 2026-11-07 17:08 ruling applies TANDEM 4l, treats
this as non-blocking, and explicitly skips the quiet retry because this change
does not touch command-bar code. The raw FAIL remains in the summary.

`sitecontrol-render` passes 1,548/1,549 checks, including every F24 display row
and native cleanup. Its sole failure is the code CSS highlight CPU p95:
2.387 ms against 2 ms at load 12.96 / 21.48 / 24.62. A focused quiet rerun is
pending. No foreground interruption occurred.

Negative controls invert the restore preference, remove a saved sidebar tab,
invert the Library visibility gate, disable App history/download clearing,
accept an invalid empty selection, and alter the specific quit-alert title.
The five restore rows, eleven clear rows, five History rows and two warning
value rows all detect those changes. The clear control reaches all eleven
assertions, then its long negative waits let the slow fixture finish before a
cleanup click; owned-process cleanup still passes. Quit has a separate control
receipt. Raw changes are in `negative-source.patch`; all changes were restored
before the final builds.

The suite runner is invoked as `python3 tools/e2e/engine_e2e.py` under each
machine's `lockf -k` screen lock. Its isolated shebang has existing sibling
import failures (`downloads`, and the known `engine_activation` main harness
bug covered by #202; first-run's known sibling import is covered by #224).
No harness-import fix is included. Each touched suite resets its defaults and
restores them in `finally`; the restore and Downloads suites also use cloned
bundles with private preference domains. Each run has private data/cache roots
and ephemeral fixture ports.

Hooks outside Section 11's local helpers are small: launch/focus in
`AppDelegate`, optional focus dates in `OpenModel`/`OpenStore`, window-state and
Downloads automation, and the App Settings adapter's Library-opening and
native-clear completion paths. **OpenSettings edits: none.**
