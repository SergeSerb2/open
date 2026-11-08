# Section 14 C5: import local CRX completion

2026-11-07, M5. Branch `s14/crx-completion`. Main through `1714a22e` was merged before the final Debug build and verifier. No engine source changed.

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
