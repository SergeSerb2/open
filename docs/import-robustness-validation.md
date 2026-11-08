# Import robustness qualification

App code qualified at `c42ba0a4a61638676824e6a95e4738437e1b7ccd`, merged main `7f405f3b3e5ccf5716d2664b1f6e91e36b219df3`. Later receipt commits change documentation only.

## Final App checks

Final source head `c42ba0a4a61638676824e6a95e4738437e1b7ccd` includes
main `7f405f3b` (#219, #226, #222 and #227). This gate keeps that main snapshot.
All runs use the M5 and the frozen main-engine distribution, framework SHA-256
`2ecaeadab71b3da3e5bc65a3f5b77d80c7958e9d0faa8cd305a0fa29496ebb10`. Embedded and distribution code fingerprints match.
Builds use token B → heavy. Each App suite takes its own screen lock.
Release timing takes quiet → B → heavy → screen. Foreground and priority
guards run before screen acquisition. All sources and Open roots are synthetic.

| Check | Exact result | Load 1/5/15, queue / acquired → finish |
|---|---|---|
| Debug build + engine fingerprint | PASS | 10.27/16.75/20.27 → 7.69/14.95/19.38 → 11.95/15.05/19.17 |
| Automation Release build + engine fingerprint | PASS | 11.95/15.05/19.17 → 12.76/14.32/18.33 |
| `import-robust` | 27 PASS | 27.99/18.17/19.28 → 12.99/18.22/19.30 → 16.04/17.90/19.09 |
| Negative proofs | 27/27 original assertions FAIL as intended; cleanup PASS | 37.54/21.81/20.07 → 36.62/25.65/21.89 → 17.78/22.35/20.93 |
| Forced Settings-sheet failure | Intended failure; graceful cleanup PASS | 12.01/19.45/19.96 → 8.58/11.00/13.94 → 8.03/10.81/13.83 |
| Full `firstrun` | 86 PASS, 7 BLOCKED | 8.03/10.81/13.83 → 14.38/10.11/11.34 → 13.35/11.51/11.69 |
| Focused multiprofile | 17 PASS, 6 BLOCKED | 13.49/11.69/11.75 → 19.57/22.17/18.09 → 17.78/21.58/17.97 |
| Release timing/idle | 3/3 PASS | 12.77/13.49/16.69 → 11.54/20.01/24.89 → 14.61/16.09/21.34 → 14.06/15.87/21.14 |

Negative and deliberate-failure exits are expected proof, not acceptance failures.
Accepted attempts clean their owned processes/windows. Discarded interrupted
attempts, if any, remain in the receipts. First-run keeps inherited Boosts and
extension-engine completion BLOCKED rows explicit. Local CRX fixtures exercise installs.
Installs use their separate queue and remain outside import Undo. Boosts store no App data.

## Release responsiveness and idle work

The fixed fixture has 6 Spaces × 200 tabs, 2,000 Archive rows, 2 Profiles,
5,000 URLs and 100,000 visits. Before batching, Release lag reproduced at
low load. Per-item changes caused 1,217 structural callbacks and 1,218 engine
mirror syncs. One reload per changed parent reduces these to 15 and 16.
The final 2eca engine includes upstream Profile changes. Earlier before-fix Release receipts use d945, so these are distinct engine receipts.

| Release receipt | History ms | Main lag ms | Timing load 1/5/15 | Idle CPU % | Idle load 1/5/15 | Changed stores |
|---|---|---|---|---|---|---|
| Before, loaded | 778.80 | 96.85 | 14.80/12.90/15.59 | 0.399 | 13.18/12.62/15.45 | 0 |
| Before, low load | 657.04 | 80.25 | 6.72/9.05/12.96 | 0.200 | 6.63/8.92/12.85 | 0 |
| After, final | 916.76 | 9.81 | 14.24/15.99/21.27 | 0.200 | 14.06/15.87/21.14 | 0 |

Phase values below use the low-load before and final after loads above.

| Phase | Before max lag ms | Final max lag ms | Final elapsed ms |
|---|---|---|---|
| progress | 5.35 | 4.44 | 4.63 |
| readSidebar | 0.03 | 0.02 | 6.29 |
| buildSidebar | 3.13 | 7.08 | 7.21 |
| readArchive | 0.21 | 0.07 | 29.19 |
| landSidebar | 77.09 | 7.96 | 16.35 |
| writeArchive | 3.17 | 1.85 | 22.07 |
| browserReady | 0.00 | 0.00 | 0.41 |
| writeHistory | 1.61 | 0.91 | 917.20 |

Final History meets 1,400 ms, every phase stays below 50 ms, and idle CPU
stays below 1%. Ten seconds after import, the watchdog is inactive, store files
do not change, and save/snapshot/mirror counters stay fixed. The watchdog is
compiled only for automation and stops on each exit. No debugger was attached.

Earlier d945 Release receipts establish the before-fix stall. Final Release qualification uses 2eca.
The crashing build and historical old-engine baseline were not launched again.
Private receipts, all attempts and loads: `.re/c4b/`. The final full verifier
summary is in draft [#224](https://github.com/SergeSerb2/open/pull/224).


## Full verifier

<!-- FULL_QUALIFICATION_START -->
**RUNNING**: `tools/verify-all.sh --with-arc-data` on the M5. The complete summary will be added after the one full run.
<!-- FULL_QUALIFICATION_END -->

## Integration and limits

The lead ruled at 17:21 that this gate stays on the recorded 2eca engine after main advanced to #223 / ca56dff3. Remaining fetches use a private APFS copy of the retained distribution, verified against its full framework SHA-256. No engine source changed or engine was rebuilt. The lead owns the later main merge and Debug build on the new engine; App, timing and full-gate repeats are waived by that ruling.

Decoded-parser memory/directory limits remain PARTIAL/UNVERIFIED. Physical Profile teardown stays outside logical import Undo. Six Boosts persistence rows and the extension-engine completion row are inherited BLOCKED in these 2eca receipts; #223 integration belongs to the lead. The before-fix Undo crash evidence and approved copy/hooks are recorded in [import-robustness.md](import-robustness.md).
