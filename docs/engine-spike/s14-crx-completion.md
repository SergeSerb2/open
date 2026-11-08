# Section 14 C5: import local CRX completion

2026-11-07, M5. Branch `s14/crx-completion`. The full verifier ran on `043588d2` with main through `1714a22e`. The earlier shared-file merge `a7b3a221` includes main `7f7feb26`; Debug and the affected first-run/extension suites were rerun after it. No engine source changed in this PR.

The automation-only import path now uses `installLocalCRX(_:completion:)`. Installed requires the exact candidate ID. Cancelled skips. Failed preserves Chromium's error text. The hidden browser/page and delegate-event matching are removed. The production Web Store call is unchanged. Consent and readiness have no failure deadline. Undo Import keeps independent extension installations.

Engine distribution SHA-256: `c03a5109fc0d815770743a6c25a92d24bd1632eba6e658e00eb6e46314440c91`. Each completed screen suite checks the embedded engine; normalized signed code fingerprint: `1ce1e076a1c3788b29946651b0a37379b4df4355022b36ab7b6337ee2a7425d7`.

## Failure gate and negative proof

The real damaged-signature CRX reports `Failed: Package is invalid: 'CRX_SIGNATURE_VERIFICATION_FAILED'.` The rendered report contains that error. Its result is `Installed 1 · Skipped 1 · Failed 1`; the next candidate installs and the queue ends. All 18 EI rows pass in the final full first-run suite.

For the negative proof, the engine failed mapping was temporarily changed to skipped. `EI_failure_reported_engine` and `EI_result_counts` both failed: the rendered row was `Skipped (Package is invalid: 'CRX_SIGNATURE_VERIFICATION_FAILED'.)` and the count was `Installed 1 · Skipped 2 · Failed 0`. The next install and cleanup still passed. The correct mapping was then restored byte for byte and rebuilt.

Two harness defects were found and fixed without weakening the gate: Settings inspection must capture its attached report sheet, and re-import must wait until that exact native sheet is no longer visible. A forced early suite failure with the consent sheet open also passed owned-process/window cleanup.

The read-only real-data receipt contains counts only: 2 Profiles, 6 extension records, 6 internal, 0 reinstall candidates. No extension section appears.

## All check runs

Loads are `(1, 5, 15)` minutes, before → after, rounded to two decimals. Private raw receipts retain full precision. The table includes failed diagnostics and deliberate negative runs.

| Run | Exact result | Load before → after |
|---|---|---|
| `build-positive` | PASS — initial Debug build | (117.56, 45.42, 31.31) → (142.86, 127.79, 74.88) |
| `ei-positive` | 17 PASS, 1 FAIL — inspection captured Settings parent | (135.67, 126.55, 74.75) → (13.03, 39.33, 51.95) |
| `openkit-prerequisite` | PASS — Release openkit prerequisite | (14.31, 36.01, 50.08) → (16.78, 29.26, 45.51) |
| `ei-render-diagnostic` | 17 PASS, 1 FAIL — confirmed wrong capture target | (22.39, 21.60, 37.24) → (26.93, 24.13, 36.86) |
| `build-inspection-fix` | PASS — Debug report-capture fix | (22.97, 23.49, 36.19) → (19.96, 22.80, 35.72) |
| `ei-inspection-fixed` | 18/18 PASS — focused EI, engine and cleanup PASS | (17.01, 21.87, 35.01) → (10.77, 16.49, 29.07) |
| `build-negative` | PASS — Debug with deliberate failed-to-skipped mutation | (10.28, 16.19, 28.81) → (9.71, 15.87, 28.55) |
| `ei-negative-mapping` | 16 PASS, 2 expected FAIL — engine and count gates; cleanup PASS | (8.53, 15.31, 28.13) → (14.73, 13.13, 22.72) |
| `build-restored` | PASS — correct mapping restored byte for byte; main merged | (14.34, 13.12, 22.55) → (13.61, 13.02, 22.35) |
| `ei-abort-cleanup` | Expected suite FAIL with consent sheet open; owned-process/window cleanup PASS | (12.18, 12.77, 21.83) → (15.46, 13.84, 20.69) |
| `firstrun-final` | 86 PASS, 1 FAIL, 6 BLOCKED — old missing-file report remained visible | (11.68, 12.88, 19.59) → (9.84, 13.62, 17.14) |
| `firstrun-render-diagnostic` | 86 PASS, 1 FAIL, 6 BLOCKED — confirmed sheet dismissal race | (11.20, 13.33, 16.76) → (8.64, 11.70, 15.35) |
| `firstrun-sheet-fixed` | 87 PASS, 0 FAIL, 6 existing Boost BLOCKED; all 18 EI, engine and cleanup PASS | (11.01, 11.71, 15.00) → (16.11, 39.64, 30.92) |
| `extensions-ui-final` | INTERRUPTED — monitor misclassified non-fatal simulated fault; no actual App crash | (14.49, 38.51, 30.63) → (26.52, 34.43, 30.62) |
| `verify-scoped` | PASS — build 67s, roundtrip 2s, import-arc 2s | (23.95, 26.91, 28.04) → (25.49, 28.99, 28.91) |
| `extensions-ui-resumed` | 71 PASS, 0 FAIL, 1 existing X13_picker BLOCKED; engine and cleanup PASS | (21.73, 27.92, 28.53) → (9.18, 17.74, 23.68) |
| `build-main-final` | PASS — Debug after current main merge | (9.72, 17.57, 23.55) → (11.96, 17.54, 23.36) |
| `extensions-p3-final` | 19 PASS, 0 FAIL; engine and cleanup PASS | (14.61, 16.09, 21.34) → (12.99, 15.41, 20.75) |
| `verify-full-final` | 24 PASS, 1 timing FAIL — FV10 22.624 ms p95 > 8.33 ms; 688 other feature rows PASS | (12.22, 15.17, 20.60) → (19.91, 28.17, 26.36) |
| `features-quiet-final` | CANCELLED while queued for quiet lock; no check executed | (19.33, 27.78, 26.24) → (36.19, 46.48, 36.47) |
| `build-overlap-final` | PASS — Debug after final shared-file overlap merge | (39.76, 47.68, 36.70) → (46.74, 47.83, 37.78) |
| `firstrun-overlap-final` | 87 PASS, 0 FAIL, 6 existing Boost BLOCKED; all 18 EI, engine and cleanup PASS after final merge | (39.76, 46.19, 37.43) → (30.87, 43.30, 38.33) |
| `extensions-ui-overlap-final` | 70 PASS, popup timing row FAIL (19/20 samples; p95 11.431 ms <= 16.7 ms), 1 existing picker BLOCKED; cleanup PASS | (27.10, 35.72, 36.03) → (33.07, 33.45, 34.98) |
| `extensions-p3-overlap-final` | 19 PASS, 0 FAIL; engine and cleanup PASS | (33.07, 33.45, 34.98) → (72.49, 77.49, 55.65) |
| `extensions-ui-quiet-final` | 71 PASS, 0 FAIL, 1 existing picker BLOCKED; 20/20 popup samples; cleanup PASS. First attempt discarded for foreground loss | (60.82, 74.66, 55.02) → (34.05, 49.73, 51.50) |
| `static-cleanup-final` | PASS — Python syntax, whitespace, byte-identical restored mapping, 0 owned App/Helper processes | (41.71, 49.09, 51.14) → (41.71, 49.09, 51.14) |

## Full verifier summary

Command: `tools/verify-all.sh --with-arc-data`, through section token A and `heavy.sh`. All 25 checks ran; no SKIP. Durations include any screen-lock queue time. The aggregate loads are in the run table above.

| Check | Result | Seconds |
|---|---|---|
| build | PASS | 17 |
| commands-demo | PASS | 5 |
| roundtrip | PASS | 0 |
| space-legacy | PASS | 2 |
| space-editor | PASS | 689 |
| space-pad-compare | PASS | 2 |
| suggest-check | PASS | 33 |
| commands-dump | PASS | 1 |
| route | PASS | 21 |
| favicons | PASS | 3 |
| media-demo | PASS | 1 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 1 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 4 |
| settings-preview | PASS | 94 |
| sidebar-render | PASS | 113 |
| sidebar-compare | PASS | 154 |
| commandbar-render | PASS | 36 |
| features-render | FAIL | 74 |
| extensions-render | PASS | 8 |
| sitecontrol-render | PASS | 255 |
| boosts | PASS | 5 |
| import-arc | PASS | 1 |
| verify-secrets-fixture | PASS | 8 |

## Remaining boundaries

The full first-run suite retains six existing Section 12 AppBoosts BLOCKED rows. `extensions-ui` retains the existing `X13_picker` Site Control presenter BLOCKED row. No production Web Store network acceptance was added. M1 was not used because no M1 screen clearance was received. No intentional crash probe ran.

The first UI run was interrupted by a monitor that treated `ExcUserFault_*` as a crash. The lead confirmed `bug_type: 309`, `isSimulated: 1`, no App crash and no crash dialog. The resumed suite passed. The monitor now stops only on real Open/Open Helper crash reports. The Chromium icon-writer fault is recorded in `docs/followups.md`; an icon size/format mismatch remains a guess.

The final UI wrapper was interrupted by an instruction update while its detached suite continued. Its complete JSON and cleanup result were recovered. That table row uses the suite execution-start load instead of the lost wrapper queue-start load; its exit classification is inferred from the complete result JSON. No real Open/Open Helper crash report appeared during the interruption.

The full verifier retains its original `FV10` timing miss (22.624 ms versus 8.33 ms). That run is not relabelled PASS. The lead required a main/head comparison before accepting it; the comparison below passes on both revisions. No limit or baseline was changed.

The final quiet-lock UI rerun passed all 71 functional/timing rows with one existing picker BLOCKED row. Popup ready-to-visible p95 was 8.087 ms (limit 16.7 ms), with 20/20 samples, at row load (55.89, 55.72, 53.6). One foreground-loss attempt was discarded and automatically repeated; only the completed replacement is accepted.

## Required FV10 main/head comparison (2026-11-07)

Built unchanged main at the merge base `7f7feb2669e823aa8d12b9263e5cb2067c355761` in a separate detached worktree, then rebuilt head `73b9c67ed50c8f94d69a29968ebb8da5ff6dcca0`. Both builds used `swift build -c release -j 6 --package-path Packages/OpenKit --product features-render`, section token A and `heavy.sh`, with the pinned engine environment. The main worktree stayed clean.

Ran the existing `features-render favicon-check` command once on main, then immediately once on head. This executes the identical `FaviconChecks.scroll` FV10 implementation: 1,000 stored icons, real sidebar rendering, 335 scroll steps, and the unchanged 8.33 ms budget. Both commands ran inside one comparison suite with the same section token, heavy slot and continuously held screen lock. The quiet lock was unavailable after five seconds, so the lead-authorized recorded-load fallback was used. Each command had a separate temporary data root.

| Check | Result | Load (1,5,15), before → after |
|---|---|---|
| Release build: unchanged main | PASS | (39.00, 44.27, 48.24) → (26.53, 37.01, 44.38) |
| Release build: head | PASS | (26.53, 37.01, 44.38) → (15.03, 28.49, 39.89) |
| Main favicon check | 33 PASS, 0 FAIL; FV10 **4.719 ms p95**, PASS (335 steps) | (17.48, 25.69, 37.55) → (25.30, 27.05, 37.77) |
| Head favicon check | 33 PASS, 0 FAIL; FV10 **4.076 ms p95**, PASS (335 steps) | (25.30, 27.05, 37.77) → (25.05, 26.88, 37.46) |
| Pair wrapper and cleanup | PASS | (14.43, 27.91, 39.56) → (25.05, 26.88, 37.46) |

Main measured **4.719 ms** and head measured **4.076 ms**. Both meet 8.33 ms. The original 22.624 ms miss did not reproduce, and this pair shows no head regression. This is one comparison, not a new performance improvement claim.

The entire OpenKit source tree is identical on main and head: git tree `524797eead8d19c6211883f1fed42f2a8d016c35`. The Swift diff audit found no production Web Store logic change. The import-attempt class changes outside the install branch remove fields and a helper already guarded by `OPEN_AUTOMATION`; the report inspection file is fully guarded. No scroll, favicon, OpenKit or engine implementation changed in this PR.

Post-comparison whitespace and cleanup checks PASS. The clean temporary main worktree was removed; no owned App, Helper or features-render process remains. Loads: (65.46, 40.10, 41.46) → (65.46, 40.10, 41.46).

## Final conflict-resolved comparison

GitHub reported a conflict after main #224 landed. The branch merged main `43ee7fb89a2917872e6b21490a7bf8301945bbce` as `7768e9a4149a631827ee795edd9734d6cfbc9460`. The only textual conflict was in `docs/followups.md`: the C5 completion/icon items and main's newer Undo text were both preserved. The first-run harness also kept main's isolated-mode module-loading fix.

Debug was rebuilt and the affected full first-run suite rerun. The main engine view had advanced to framework SHA-256 `7a90e70e40bf33984473b0997f03c5c89f2b6701d18483b7149a4e32c223aee5` (0704 plus Document PiP); that exact current README pin was used for this App rerun. The earlier C5 App receipts retain their original `c03a5109…` pin.

The unchanged new merge base was built in a clean detached worktree, and head was rebuilt separately with the same Release command as above. The FV10 pair was then repeated once on these resolved revisions, main first and head immediately after, with one continuously held screen lock and the same section/heavy slot. Each favicon suite uses its own temporary root.

| Check | Result | Load (1,5,15), before → after |
|---|---|---|
| Post-merge Debug | PASS | (27.65, 35.35, 39.34) → (27.60, 33.55, 38.24) |
| Release: main 43ee7fb8 | PASS | (24.23, 32.51, 37.78) → (17.99, 27.88, 35.31) |
| Release: head 7768e9a4 | PASS | (17.99, 27.88, 35.31) → (19.78, 25.39, 33.46) |
| Post-merge full first-run | 87 PASS, 0 FAIL, 6 existing Boost BLOCKED; 18/18 EI PASS; engine/cleanup PASS | (20.27, 25.40, 33.41) → (114.53, 53.89, 41.35) |
| Final main favicon check | 33 PASS, 0 FAIL; FV10 **1.062 ms p95**, PASS (335 steps) | (11.81, 26.42, 33.61) → (10.54, 25.66, 33.25) |
| Final head favicon check | 33 PASS, 0 FAIL; FV10 **1.043 ms p95**, PASS (335 steps) | (10.54, 25.66, 33.25) → (9.85, 25.27, 33.07) |
| Final comparison wrapper/cleanup | PASS | (104.40, 62.75, 45.52) → (9.85, 25.27, 33.07) |

Quiet lock acquired for the final pair: **yes**. Main measured **1.062 ms**, head **1.043 ms**, both below 8.33 ms. The original large miss does not reproduce, and head shows no regression in this pair. Both revisions have the same entire OpenKit tree, `e84af8902fa0b62b1ae60deeffc7f46b94a8bbee`; no production or scroll implementation fix was needed. The original full-verifier FAIL remains preserved above.

Final whitespace, byte-identical completion-mapping restoration and native-process cleanup checks PASS. The second clean comparison worktree was removed; no owned check, App, Helper or features-render process remains. Loads: (9.43, 23.67, 32.22) → (9.43, 23.67, 32.22).
