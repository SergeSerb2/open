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
Full `tools/verify-all.sh --with-arc-data` ran **once** on the M5: **23 PASS / 2 FAIL from prelaunch priority deferrals**. No target skipped. Verification head `7509e3b663e0e3b8b57510007bda59a9d9e88063` adds only the published receipt documents to App-qualified `c42ba0a4a61638676824e6a95e4738437e1b7ccd`. Framework context SHA-256 `2ecaeadab71b3da3e5bc65a3f5b77d80c7958e9d0faa8cd305a0fa29496ebb10`.

| Check | Raw result | Seconds | Load 1/5/15, start / guards → finish |
|---|---|---|---|
| build | PASS | 93 | 11.89/14.90/20.38 → 15.16/14.89/19.80 |
| commands-demo | PASS | 4 | 15.16/14.89/19.80 → 14.26/14.71/19.71 |
| roundtrip | PASS | 1 | 14.26/14.71/19.71 → 14.26/14.71/19.71 |
| space-legacy | PASS | 1 | 14.26/14.71/19.71 → 13.84/14.61/19.65 |
| space-editor | FAIL | 0 | 13.84/14.61/19.65 → 13.84/14.61/19.65 |
| space-pad-compare | PASS | 2 | 13.84/14.61/19.65 → 13.84/14.61/19.65 |
| suggest-check | PASS | 22 | 13.84/14.61/19.65 → 12.34/14.20/19.38 |
| commands-dump | PASS | 0 | 12.34/14.20/19.38 → 12.34/14.20/19.38 |
| route | PASS | 21 | 12.34/14.20/19.38 → 19.52/15.69/19.77 |
| favicons | PASS | 3 | 19.52/15.69/19.77 → 19.52/15.69/19.77 |
| media-demo | PASS | 1 | 19.52/15.69/19.77 → 19.52/15.69/19.77 |
| sleep-demo | PASS | 1 | 19.52/15.69/19.77 → 18.35/15.51/19.68 |
| adblock-perf | PASS | 1 | 18.35/15.51/19.68 → 18.35/15.51/19.68 |
| adblock-catalog | PASS | 0 | 18.35/15.51/19.68 → 18.35/15.51/19.68 |
| profiles | PASS | 4 | 18.35/15.51/19.68 → 18.41/15.57/19.67 |
| settings-preview | PASS | 87 | 18.41/15.57/19.67 → 10.26/13.93/18.67 |
| sidebar-render | PASS | 109 | 10.26/13.93/18.67 → 5.80/11.21/17.02 |
| sidebar-compare | PASS | 108 | 5.80/11.21/17.02 → 8.99/10.79/16.18 |
| commandbar-render | PASS | 36 | 8.99/10.79/16.18 → 8.14/10.36/15.77 |
| features-render | PASS | 91 | 8.14/10.36/15.77 → 9.07/9.97/15.07 |
| extensions-render | PASS | 8 | 9.07/9.97/15.07 → 9.23/9.99/15.05 |
| sitecontrol-render | FAIL | 0 | 9.23/9.99/15.05 → 9.23/9.99/15.05 |
| boosts | PASS | 4 | 9.23/9.99/15.05 → 9.13/9.95/15.01 |
| import-arc | PASS | 3 | 9.13/9.95/15.01 → 9.20/9.95/14.98 |
| verify-secrets-fixture | PASS | 9 | 9.20/9.95/14.98 → 9.02/9.89/14.90 |

The raw FAIL entries above are exit 75 from the private priority guard; no target assertion or native launch ran. After the full run ended, only those deferred targets were resumed with `tools/verify-all.sh --only space-editor,sitecontrol-render`. The native runner retained its normal priority wait and screen lock. No product code or assertion changed. Scoped head `18a4c27e4ffbc53f275a6981da7572458a5cb341` differs from the full-run head only in receipt documentation. The scoped run and its required build all passed:

| Scoped check | Result | Seconds | Load 1/5/15, start / guards → finish |
|---|---|---|---|
| build | PASS | 4 | 46.90/28.17/21.03 → 43.70/27.82/20.95 |
| space-editor | PASS | 143 | 43.70/27.82/20.95 → 43.70/27.82/20.95 → 45.63/38.16/26.40 |
| sitecontrol-render | PASS | 296 | 45.63/38.16/26.40 → 45.63/38.16/26.40 → 24.90/31.50/26.90 |

**Qualification: all 25 targets have passing receipts across the single full run and the scoped completion of its prelaunch deferrals.** The raw full-run FAIL entries remain preserved; this is not a claim that its original table was all PASS.

Full-run logs remain under `.re/c4b/verify-all-final/`; scoped completion logs remain under `.re/c4b/verify-deferred-final/`. Real Arc data is read through private copies and reports counts only. The earlier interrupted verifier is historical and is not used as this gate.

Inherited renderer timing details remain explicit. `sitecontrol-render` passed 1,549 assertions with four INFO entries; those INFO entries provide no acceptance result.

| Receipt | Observed timing | Recorded load | Status |
|---|---|---|---|
| Suggest remote stream | 391 ms; +11 ms past configured 380 ms; below 600 ms gate | 13.1/14.5/19.6 | PASS |
| Sidebar hover preview | 0.502 s; +2 ms lateness | load1 6.04 | PASS |
| Command bar rows | main CPU p95 7.49 ms; wall p95 7.93 ms; inline cycles p95 +0.208 ms | 8.99/10.79/16.18 → 8.14/10.36/15.77 (check context) | PASS |
| Site Control cold open | CPU p95 12.615 ms vs 8 ms; +4.615 ms; wall 12.739 ms | load1 27.04 | Diagnostic |
| Site Control skeleton | CPU p95 9.080 ms vs 8 ms; +1.080 ms; wall 16.175 ms | load1 24.53 | Diagnostic |
| Editor open | CPU p95 20.597 ms vs 12 ms; +8.597 ms; wall 38.995 ms | load1 24.81 | INFO, no acceptance |
| Editor native code keys | main CPU p95 1.792 ms vs 2 ms; -0.208 ms | 24.81/31.60/26.91 | PASS |
| Editor pad / hue | pad CPU p95 0.087 ms; hue 8.988 ms off-main | load1 24.81 (editor context) | PASS |
| Editor drag / idle / page refresh | frame p95 1.518 ms, max 4.360 ms; idle 0.231 ms CPU in 2 s; refresh max 0.110 ms | 45.63/38.16/26.40 → 24.90/31.50/26.90 (check context; separate sample load not recorded) | Diagnostic / PASS assertions |

Sidebar SM6 retains diagnostic wall/main-CPU pairs in ms: initial 29.838/29.163; discarded warm-up 66.228/53.193; five measured processes 57.381/52.289, 59.079/51.167, 58.697/54.138, 52.087/48.551, 53.361/49.321. All record load1 6.04. The main-thread instruction median was 670,611,826, with no accepted machine/build cost baseline. Site Control also lacks accepted cold-open/editor instruction baselines (medians 92,650,635 and 134,523,266). These inherited cost diagnostics remain unqualified. High-load timing misses above are reported under the lead's load policy; no tolerance changed.

<!-- FULL_QUALIFICATION_END -->

## Integration and limits

The lead ruled at 17:21 that this gate stays on the recorded 2eca engine after main advanced to #223 / ca56dff3. Remaining fetches use a private APFS copy of the retained distribution, verified against its full framework SHA-256. No engine source changed or engine was rebuilt. The lead owns the later main merge and Debug build on the new engine; App, timing and full-gate repeats are waived by that ruling.

Decoded-parser memory/directory limits remain PARTIAL/UNVERIFIED. Physical Profile teardown stays outside logical import Undo. Six Boosts persistence rows and the extension-engine completion row are inherited BLOCKED in these 2eca receipts; #223 integration belongs to the lead. The before-fix Undo crash evidence and approved copy/hooks are recorded in [import-robustness.md](import-robustness.md).
