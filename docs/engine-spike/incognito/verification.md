# Private-window verification

Full gate on M5, 2026-11-06, source `fee1d316d03884f2308fdbd4e07332b18425d9cf`, with `origin/main` through `ae0eb050`. `OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main` was exported. The Debug App and OpenKit Release builds passed before the real-App suites.

Command: `~/Library/Caches/OpenRE/scripts/heavy.sh tools/verify-all.sh --with-arc-data`. 23 PASS, 1 timing FAIL, 0 SKIP in the full run. The focused quiet rerun passes all 151 commandbar-render rows in ONE run; all 24 gate checks now pass overall. Full-run load before: [16.3212890625, 21.4970703125, 27.28955078125]; after: [25.30712890625, 21.8955078125, 24.078125]. `commands-dump`: missing=0 extra=0 different=0 allowedMissing=11. The allowlist is unchanged.

| Name | Result | Seconds |
|---|---|---:|
| build | PASS | 4 |
| commands-demo | PASS | 3 |
| roundtrip | PASS | 1 |
| space-legacy | PASS | 1 |
| space-editor | PASS | 45 |
| space-pad-compare | PASS | 2 |
| suggest-check | PASS | 32 |
| commands-dump | PASS | 1 |
| route | PASS | 4 |
| favicons | PASS | 2 |
| media-demo | PASS | 0 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 0 |
| adblock-catalog | PASS | 1 |
| profiles | PASS | 1 |
| settings-preview | PASS | 89 |
| sidebar-render | PASS | 116 |
| sidebar-compare | PASS | 140 |
| commandbar-render | FAIL | 45 |
| features-render | PASS | 100 |
| extensions-render | PASS | 8 |
| sitecontrol-render | PASS | 56 |
| boosts | PASS | 9 |
| import-arc | PASS | 2 |

## Focused quiet rerun

Command: `/usr/bin/lockf -k /tmp/open-m5-quiet.lock /Users/serge/.t3/projects/open/.re/s10/s10-heavy.sh tools/verify-all.sh --only commandbar-render`. This follows lead ruling 17:38; no multi-run or paired-main exception is used. Load after quiet-lock acquisition: [32.7255859375, 25.0009765625, 25.11279296875]; after completion: [42.119140625, 34.05615234375, 28.8740234375]. Benchmark load: 42.1 / 34.1 / 28.9.

Initial full run at benchmark load 20.9 / 22.2 / 24.8: CPU p95 10.96 ms (limit 8 ms), inline increment +0.633 ms (limit +0.3 ms), 149/151 PASS. Quiet rerun: 151/151 PASS, CPU p95 5.70 ms, inline increment +0.254 ms. All thresholds and allowlists are unchanged.

| Name | Result | Seconds |
|---|---|---:|
| build | PASS | 3 |
| commandbar-render | PASS | 39 |

## Real-App regressions

| Suite | Runtime | Result | Skipped/deferred | Interruptions | Cleanup |
|---|---|---|---:|---:|---|
| incognito | chrome | 25 PASS, 0 FAIL | 3 | 0 | PASS |
| sidebar | alloy | 19 PASS, 0 FAIL | 1 | 0 | PASS |
| features | alloy | 19 PASS, 0 FAIL | 0 | 0 | PASS |
| window | alloy | 76 PASS, 0 FAIL | 3 | 0 | PASS |
| littleopen | alloy | 39 PASS, 0 FAIL | 0 | 0 | PASS |
| profiles | chrome | 14 PASS, 0 FAIL | 0 | 0 | PASS |
| context-menus | chrome | 34 PASS, 0 FAIL | 0 | 0 | PASS |
| commandbar | chrome | 77 PASS, 0 FAIL | 0 | 0 | PASS |

The window suite has two existing Debug-only launch-budget skips and one pre-existing Part B card-material deferral; the sidebar durable-profile skip is covered by the passing Profiles suite. Incognito engine ancestry/extension rows wait for 0701; native 2x and Section 12 Boosts are deferred by lead. Every final run has zero focus interruptions and clean owned-process shutdown. Initial failed invocation receipts are retained separately.

## Review checklist

| Checklist item | Result | Evidence |
|---|---|---|
| External input limits | PASS | No new decoder. Private filenames refuse more than 255 UTF-8 bytes; destination resolution reuses bounded `DownloadFiles.unique` (10,000 candidates). Existing AX traversal is bounded to 16 levels/512 objects. |
| Allocator ceiling | N/A | No new bulk allocation or untrusted collection decoder. |
| New limit boundary cases | N/A | Filename and unique-name policy match existing Downloads flow; no new format or higher accepted input limit. |
| Trailing/unknown parsed data | N/A | No new serialized input format. |
| Callback reentrancy | PASS | Private destination choices answer once; asynchronous destination work checks `closed` before completion. Close cancels outstanding choices. Existing window close path owns factory shutdown. |
| Exactly-once close | PASS | `closeAll` and `IncognitoDownloads.close` are idempotent; unknown window-close IDs return. Acceptance closes two shared windows and proves final-session reset; cleanup closes remaining windows. |
| ID generations | PASS | Fresh model IDs and engine ephemeral-context IDs; native UInt32 download IDs are scoped to the window destination handler. No new process-wide ID allocator. |
| Deferred state before dependent action | PASS | Private save seam is a no-op; normal writes drain before/after privacy fingerprints. Quit awaits actual process exit before fingerprint comparison. |
| Real key event path | PASS | `incognito.py` uses `route=app` for Shift-Cmd-N, Cmd-N/T/L, Escape and Return. Existing window/commandbar regressions exercise their normal focus and close paths. |
| Key ownership after main merge | PASS | Regressions run after incorporating main; command registry stays unchanged and adds no second shortcut owner. Full commands-dump result recorded below. |
| Hidden/refused actions | PASS | Private header, bottom bar and row menus remove persistent actions; factory command validation and sidebar dispatch refuse them before selection dispatch. Native Chromium incognito item stays hidden. |
| Break-and-revert proofs | PASS | `negative-model.json`: no_snapshot_history_change FAIL. `negative-disk.json`: cookie_normal_absent_private FAIL. Both exit 1, zero interruptions, cleanup PASS; reverted production build passes 25 acceptance gates. |
| Pixel comparison | PASS | Native light/dark 1x snapshots inspect three empty-sidebar pixels, tolerance 2 RGB levels from #26232B. No PNG-size proxy. |
| Specific window checks | PASS | AX header/window checks use the created private window number and require Incognito plus eyeglasses. |
| Timing assertions | N/A | No new timing budget; existing regression deadlines unchanged. |
| Run isolation | PASS | Real-App harness creates separate roots/cache/ports; preferences are reset at start and restored in finally. |
| Dialog/process cleanup | PASS | Positive and both forced-failure runs report cleanup PASS and zero remaining owned processes/windows. The new acceptance flow opens no human-dependent dialog. |
| Reduce Motion | N/A | No new animation; existing sidebar and window motion paths retained. |
| Interrupted animation | N/A | No animation implementation changed. |
| Geometry during width/resize | PASS | Private appearance changes visibility/palette only; existing geometry and layout paths retained. |
| Reference and display captures | N/A | Native 1x light/dark evidence committed. Reference S10-P1–P5 and native 2x captures are deferred by lead; capture steps and exact 2x command are listed. |
| Comments match code | PASS | Provider documents Default OTR seam; read-only factory hook and engine-dependent limits are explicit. |
| Plan/followups/PR agree | PASS | app-shell §4.8, profiles D-P8, status §1.10, `docs/incognito.md`, P1–P5 followups and PR use the same scope and deferrals. |
