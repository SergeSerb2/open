# Section 15 final regression, soak and speed

M5 Pro; started 2026-11-08. Tested App source is detached main `50028c98`, including #264, #265 and #269. Product source is unchanged. Raw receipts and local drivers are retained in `.re/s15-j/`. Results below keep raw failures, blocked rows, deferred probes and cleanup separate.

The main engine distribution is `619324d328e529295a01a56c9e596d21eb216d6ab1cebe22c5a20d6862815399`. The pre-Section-15 App is `eb49e472`, built in its own detached worktree against the recorded `open-engine-s8` distribution `47af3007153a883fac2acd10e491451de0abcac030c4fbebb14f15f1052115d9`. The main-view README records that old distribution at `cdd147ca`; `git diff --stat cdd147ca eb49e472 -- Engine/fork` changes only the two ad-block resource metadata files. Both Release Apps passed `--engine-fingerprint-only` with their required distribution SHA and matching embedded code hash. No engine tree or root was changed.

Every shell exported `OPEN_E2E_NO_CRASH_PROBES=1`. Main builds and verification used `OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main`; the baseline build used the old recorded `open-engine-s8` root. Builds and verifiers used `/usr/bin/lockf -k /tmp/open-s15-heavy-a.lock $HOME/Library/Caches/OpenRE/scripts/heavy.sh`. Each App suite had its own `/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock` call, priority checks before and after acquisition, a 120 s row cap, and a 1200 s suite cap. All targeted runs used `--style chrome --stop-on-app-death --continue-on-timing-failure` and the required engine SHA. Window used Release; other targeted suites used Debug. Waiting for locks did not count as execution. M1 was not used.

Only synthetic fixtures and the mock Keychain were used. No field values or cookie values are included here. Each suite restored the shared defaults it used and verified owned-process cleanup.

All owned build, verifier and on-screen work finished by 23:26 local time on 2026-11-08, before the 23:40 no-start cutoff and 23:45–01:15 quiet window. No quiet-window pause was needed. The product stayed at the `origin/main` pin selected at the start; unrelated main movement during receipt collection was not chased under TANDEM §4, rule 5a.

**Builds and focused verifier**

| Target | Command after heavy wrapper | Result | Load start (1/5/15) | Load end (1/5/15) |
| --- | --- | --- | --- | --- |
| main Debug | `tools/build.sh Debug` | PASS | not sampled | not sampled |
| main automation Release | `OPEN_AUTOMATION=1 tools/build.sh Release` | PASS | not sampled | not sampled |
| baseline automation Release | `OPEN_AUTOMATION=1 tools/build.sh Release` | PASS | 8.60/11.10/11.13 | 8.55/11.89/11.67 |
| baseline typing CLI | `swift build -c release --package-path Packages/OpenKit --product commandbar-render -j 6` | PASS | 8.55/11.89/11.67 | 9.68/11.75/11.64 |
| main settings-preview | `tools/verify-all.sh --only settings-preview` | PASS: build + 47 checks, render, persistence | 9.33/10.02/10.34 | 8.60/11.10/11.13 |

Main App build loads were not sampled. They are build receipts, not timing measurements. The focused verifier summary is `build PASS 129 s; settings-preview PASS 366 s`; the native preview helper serializes its render/check calls through its own screen-lock worker.

**Final targeted regression**

Command in each separate screen-lock call: `tools/e2e/engine_e2e.py --style chrome --only NAME --config CONFIG --stop-on-app-death --continue-on-timing-failure --row-timeout 120 --suite-timeout 1200 --engine-sha256 619324d328e529295a01a56c9e596d21eb216d6ab1cebe22c5a20d6862815399`. `CONFIG=Release` for window; `Debug` for the other suites.

| Suite | Raw rows | Exit | Cleanup | Load start (1/5/15) | Load end (1/5/15) |
| --- | --- | --- | --- | --- | --- |
| `--only passwords` | 77 PASS, 2 BLOCKED | 0 | PASS | 10.46/10.80/10.80 | 9.17/10.03/10.48 |
| `--only secrets-import` | 8 PASS, 1 FAIL, 2 DEFERRED | 1 | PASS | 7.69/9.23/10.02 | 7.62/9.06/9.93 |
| `--only features` | 26 PASS, 1 DEFERRED | 0 | PASS | 5.72/8.19/9.52 | 5.15/7.29/9.02 |
| `--only page` | 85 PASS, 4 BLOCKED, 1 DEFERRED | 0 | PASS | 6.25/6.69/8.27 | 5.37/6.31/7.96 |
| `--only window` | 41 PASS, 4 FAIL | 1 | PASS | 7.27/6.51/7.71 | 7.16/6.63/7.68 |
| `--only extensions-ui` | 71 PASS, 1 BLOCKED | 0 | PASS | 5.86/6.19/7.09 | 6.20/6.15/6.96 |
| `--only firstrun` | 97 PASS | 0 | PASS | 13.87/10.87/8.84 | 10.95/10.74/9.21 |
| `--only littleopen` | 41 PASS | 0 | PASS | 9.94/10.49/9.24 | 8.39/10.08/9.14 |

The window FAIL count includes three failed rows plus the suite wrapper that stops after `launch_waiter_early_exit`. The imported-secrets suite FAIL is a wrapper error; neither I-8 wizard row completed. All other reported PASS counts are successful assertions, including first-run checks that correctly expect an invalid CRX or missing fixture to be rejected.

| Rows | Disposition |
| --- | --- |
| C-2; I-5; I-6; features crash_recovery | M1-only by rule; not run. |
| PW-KC1 | User hand check; no real Keychain access. |
| page N1_macos_delivered; N6_click_opens_tab; X1_apple_backend; capture_c7_incognito | Existing harness BLOCKED rows. |
| page Z3_smart_zoom | Existing user hand check, DEFERRED. |
| extensions-ui X13_picker | Existing harness BLOCKED row. |
| secrets-import suite | Unexpected sanitized RuntimeError after I-9 completed/in-progress, before I-8 wizard rows. Raw failure retained. |
| window launch_waiter_early_exit | Unexpected strict-harness failure. Source-based hypothesis: strict mode starts Open directly, while this fixture expects an early LaunchServices waiter exit. No product cause is established. |

**Window cold-launch rows**

| Row | Samples | Sidebar median ms | Paint median ms | Raw result | TANDEM §4a |
| --- | --- | --- | --- | --- | --- |
| cold_fresh_profile | 5 | 399 | 634 | FAIL (250/700 ms budgets) | inside known-main ceiling |
| warm_existing_profile | 5 | 402 | 655 | FAIL (250/700 ms budgets) | above known-main ceiling; controls required |

Quiet interleaved controls are recorded below. Both control labels use the unchanged pinned-main product because this receipt branch changes docs only; source and artifact identity must remain explicit.

| Control order | Cold sidebar / paint ms | Warm sidebar / paint ms | Timing-block load (1/5/15) | Load start (1/5/15) | Load end (1/5/15) |
| --- | --- | --- | --- | --- | --- |
| window-main1 | 436 / 672 | 427 / 689 | 5.97/7.37/8.27 | 5.55/7.49/8.35 | 5.63/7.20/8.18 |
| window-branch1 | 445 / 703 | 449 / 697 | 6.15/6.88/7.94 | 5.52/6.89/7.99 | 5.93/6.75/7.86 |
| window-main2 | 424 / 658 | 426 / 698 | 4.92/6.39/7.67 | 5.93/6.75/7.86 | 4.94/6.30/7.61 |
| window-branch2 | 439 / 726 | 445 / 695 | 5.71/6.29/7.54 | 5.02/6.29/7.60 | 6.00/6.31/7.51 |

| Row | Endpoint | Main-label median ms | Docs-branch-label median ms | Change % |
| --- | --- | --- | --- | --- |
| cold_fresh_profile | sidebarDrawn | 430.0 | 442.0 | 2.79 |
| cold_fresh_profile | firstContentfulPaint | 665.0 | 714.5 | 7.44 |
| warm_existing_profile | sidebarDrawn | 426.5 | 447.0 | 4.81 |
| warm_existing_profile | firstContentfulPaint | 693.5 | 696.0 | 0.36 |

Both labels used the same unmodified Release App (source `50028c98`, executable SHA-256 `809d83ed8fde6a15a70f1b5e55a10a53d5c1be34644ce413f04b6645c7f36d7a`). The branch-label medians are higher, so the numerical no-slower condition in TANDEM §4a is not met by these controls. Because the binary is identical, these runs demonstrate session variation and do not identify a product change as the cause. Keep launch-budget acceptance open. All four controls also retain the launch-waiter harness failure and pass cleanup; no new real Open crash report appeared.

**Full verifier**

Command: heavy wrapper + `tools/verify-all.sh`. Load start 7.48/9.80/9.05; end 9.70/8.48/9.02; exit 1.

| NAME | RESULT | SECONDS |
| --- | --- | --- |
| build | PASS | 2 |
| commands-demo | PASS | 4 |
| roundtrip | PASS | 1 |
| space-legacy | PASS | 2 |
| space-editor | PASS | 86 |
| space-pad-compare | PASS | 2 |
| suggest-check | PASS | 24 |
| commands-dump | PASS | 1 |
| route | PASS | 11 |
| favicons | PASS | 2 |
| media-demo | PASS | 1 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 0 |
| adblock-catalog | PASS | 3 |
| profiles | PASS | 2 |
| settings-preview | PASS | 292 |
| sidebar-render | PASS | 114 |
| sidebar-compare | PASS | 132 |
| commandbar-render | PASS | 34 |
| features-render | PASS | 91 |
| extensions-render | PASS | 7 |
| sitecontrol-render | FAIL | 195 |
| onboarding-render | PASS | 27 |
| boosts | PASS | 3 |
| verify-secrets-fixture | PASS | 7 |

Per-check load samples are retained in `full.loads.jsonl`; timing CLIs also print their measured load. Any quiet timing rerun retains its own receipt and does not replace this raw table.

| Verifier timing check | First sampled load (1/5/15) | Last sampled load (1/5/15) | Peak sampled load1 |
| --- | --- | --- | --- |
| suggest-check | 6.77/8.91/8.79 | 6.49/8.67/8.70 | 6.94 |
| adblock-perf | not sampled | not sampled | — |
| sidebar-render | 16.13/11.92/10.00 | 12.71/11.89/10.21 | 16.13 |
| sidebar-compare | 12.34/11.83/10.19 | 10.47/11.49/10.28 | 13.11 |
| commandbar-render | 10.03/11.38/10.25 | 7.56/10.66/10.03 | 10.03 |
| sitecontrol-render | 5.22/8.95/9.43 | 8.24/8.06/8.91 | 8.44 |


**One quiet verifier rerun**

| Run | Highlight main CPU p95 ms (<2) | Measured load (1/5/15) | Start load | End load | Result |
| --- | --- | --- | --- | --- | --- |
| original full | 2.150 | 8.46/8.10/8.92 | 7.48/9.80/9.05 | 9.70/8.48/9.02 | 1550/1551; timing FAIL |
| single quiet rerun | 1.278 | 11.48/9.45/9.30 | 9.27/8.48/8.99 | 11.48/9.45/9.30 | 1551/1551 PASS |

The one rerun held the quiet lock outside heavy lock a and the heavy slot. The existing native verifier serialized its own on-screen helper. The original raw full-verifier FAIL remains above; the isolated timing rerun PASS qualifies that timing miss under TANDEM §3.4.

**Soak**

| Suite | Run | Raw rows | Exit | Cleanup | Load start (1/5/15) | Load end (1/5/15) |
| --- | --- | --- | --- | --- | --- | --- |
| passwords | 1 | 77 PASS, 2 BLOCKED | 0 | PASS | 11.04/9.39/9.28 | 8.08/8.60/8.96 |
| passwords | 2 | 77 PASS, 2 BLOCKED | 0 | PASS | 8.69/8.69/8.98 | 6.56/7.98/8.67 |
| passwords | 3 | 77 PASS, 2 BLOCKED | 0 | PASS | 11.14/9.06/9.03 | 9.63/10.06/9.50 |
| secrets-import | 1 | 8 PASS, 1 FAIL, 2 DEFERRED | 1 | PASS | 8.08/8.60/8.96 | 8.84/8.72/8.99 |
| secrets-import | 2 | 10 PASS, 2 DEFERRED | 0 | PASS | 6.33/7.88/8.62 | 11.14/9.06/9.03 |
| secrets-import | 3 | 8 PASS, 1 FAIL, 2 DEFERRED | 1 | PASS | 6.90/9.34/9.25 | 7.04/9.11/9.17 |

Each soak run is a separate full-suite App invocation. Imported-secrets soak uses the harness's built-in command-name-only trace; arguments and replies are not traced.

**Page load and form typing: three interleaved pairs**

The page receipt reuses `engine_e2e.measure`'s one fresh plus three restored-launch timing method with the deterministic login fixture. Warm medians use three launches per receipt. Page FCP and load are browser Performance API endpoints, also used by the existing Little Open bench. Form typing uses the existing native `click`/`key route=app`/`eval` path: 5 warm-up keys, then 30 measured keys. Its endpoint runs from native-key automation request to confirmed DOM length and includes automation round trips. The existing native command-bar bench below provides a separate main-thread CPU measurement. All dedicated measurements require quiet lock, then screen lock, at load1 ≤12; invalid or interrupted measurements remain unqualified.

| Pair | App | Restored process-start → paint ms | Page load ms | Page FCP ms | Form typing p95 ms | Load start (1/5/15) | Load end (1/5/15) | Receipt |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | before | 775 | 125.8 | 152 | 29.459 | 6.00/6.31/7.51 | 5.78/6.25/7.48 | PASS |
| 1 | current | 713 | 120.9 | 148 | 30.571 | 9.43/14.54/13.20 | 8.51/14.18/13.08 | PASS |
| 2 | before | 675 | 108.4 | 156 | 29.094 | 8.51/14.18/13.08 | 8.79/14.14/13.08 | PASS |
| 2 | current | 705 | 124.9 | 176 | 33.352 | 8.81/14.06/13.05 | 9.62/14.14/13.09 | PASS |
| 3 | before | 719 | 123.2 | 156 | 29.066 | 9.41/14.02/13.05 | 9.54/13.97/13.04 | PASS |
| 3 | current | 708 | 114.3 | 172 | 28.327 | 9.09/13.80/12.99 | 8.53/13.61/12.92 | PASS |

| Endpoint | Before median | Current median | Change % | Median paired change % |
| --- | --- | --- | --- | --- |
| Restored process-start to paint ms | 719 | 708 | -1.53 | -1.53 |
| Navigation load ms | 123.2 | 120.9 | -1.87 | -3.9 |
| Navigation FCP ms | 156 | 172 | 10.26 | 10.26 |
| Form key to DOM p95 ms | 29.094 | 30.571 | 5.08 | 3.78 |

Negative change is faster. Three short pairs describe this session; these numbers do not establish equality outside the measured fixture and endpoints.

**Existing native typing bench: three interleaved pairs**

Command from each worktree's own release directory: `Packages/OpenKit/.build/release/commandbar-render bench --tabs 5000 --history 100000 --scale 2 --completion`. Resource bundles remain beside their original binary. This measures the native command bar, with real field-editor insertion, suggestion query, snapshot application and drawing.

| Pair | App | Main CPU p95 ms | Wall p95 ms | Measured load (1/5/15) |
| --- | --- | --- | --- | --- |
| 1 | before | 5.48 | 6.68 | 7.8/13.2/12.8 |
| 1 | current | 5.67 | 7.08 | 7.1/12.7/12.6 |
| 2 | before | 5.77 | 7.44 | 7.3/12.5/12.5 |
| 2 | current | 5.69 | 7.52 | 6.5/12.0/12.3 |
| 3 | before | 5.45 | 7.45 | 6.5/11.7/12.2 |
| 3 | current | 3.95 | 5.42 | 5.8/11.3/12.1 |

Native command-bar CPU p95: median before 5.480 ms, current 5.670 ms, change +3.47%; median paired change -1.39%.

**Saved-login idle CPU and memory**

One real synthetic login was saved through the App sheet, then the fixture login page was reopened. After 30 s to settle, `engine_e2e.process_cpu_window` read OS CPU-time deltas over 60 s without automation traffic in the sample interval. Chromium task-manager metrics were enabled only after CPU sampling, for the memory receipt. CPU percentages use one core =100%. Physical footprint uses MiB (1,048,576 bytes).

| Process type | CPU % of one core |
| --- | --- |
| browser | 0.8787 |
| gpu | 0.0066 |
| network | 0.1776 |
| utility | 0.0028 |
| renderer | 0.0194 |
| TOTAL | 1.085 |

CPU load start { 6.51 10.82 11.89 }; end { 5.93 9.86 11.45 }. Complete stable process set: True.

| Process type | Physical footprint MiB |
| --- | --- |
| browser | 112.88 |
| renderer | 66.67 |
| utility | 20.31 |
| network | 25.53 |
| gpu | 38.94 |
| TOTAL | 264.34 |

Saved login count 1; live pages 1; load start 5.47/11.11/12.03; end 5.61/9.73/11.40. Cleanup True.

Speed disposition: the session does not prove unchanged performance. Median restored process-start-to-paint changed by -1.53%, navigation load by -1.87%, navigation FCP by +10.26%, and form-key p95 by +5.08%. Native command-bar CPU p95 changed by +3.47% by the median of each side, while the median paired change was -1.39%; every native run stayed within its existing 8 ms CPU and wall p95 budgets. These are short fixture comparisons with visible variation, not a cause analysis. The idle sample is low but nonzero at 1.085% of one core; no numeric Section 15 near-zero threshold was supplied, so the report records the measured value without asserting no idle work.

**Open acceptance items**

Regression acceptance is PARTIAL: imported-secrets completed 1/3 soak runs; the original and two soak runs stopped before the I-8 wizard rows. Passwords completed all three soak runs with the same two accepted blocks. The strict window launch-waiter row failed in the original and all four controls; its suspected direct-child/LaunchServices mismatch is a source-based hypothesis (`tools/e2e/engine_e2e.py`, `Open.__init__` and `launch_waiter_early_exit`), not runtime proof of a product cause. The window controls did not meet the no-slower numerical condition; source and executable identity are stated above. No threshold or baseline was changed.

The raw full verifier had 24 PASS and one timing FAIL. Its single quiet rerun passed that timing check. C-2, I-5, I-6 and crash_recovery remain M1-only by rule; PW-KC1 and smart zoom need the user; the existing page and extensions blocks remain open. Speed and idle qualification must be read from their own receipts above. This report does not grant merge or release approval.
