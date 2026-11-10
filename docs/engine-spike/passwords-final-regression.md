# Section 15 final regression, soak and speed

Current continuation, 2026-11-09. Fixes draft: https://github.com/SergeSerb2/open/pull/294. The current App receipts and their limits are below. The original child J report is retained at the end.

The full secrets-import order could ask for the Passwords copy reference while the wizard's newer count request was still busy. This change exposes read-only wizard state, waits for the real readable/idle gate with exact counts, and proves Return reaches Review through the Import sheet. The window regression now asserts that the early-launcher fixture uses LaunchServices.

Tested source: `c995f709cc7c71d6aa89224cbc7f711fafdfed00`; main parent: `3b45f509bd8f9ec4d1cfc85934dc8d349b94b85f`. Designated main-view engine SHA-256: `346199271164fc90ceff0535f171be279635645e94093ec870e0cb704f2dc5dd`. Baseline source: `eb49e47257b8f6f32fef07bc5dc1d37b6a32af77`; baseline engine SHA-256: `47af3007153a883fac2acd10e491451de0abcac030c4fbebb14f15f1052115d9`.

Acceptance remains PARTIAL. The earlier I-9-in-progress failure and the later password P-5 update-autofill failure below remain unexplained. Passing diagnostic replays do not erase either failure. Also, main #292 requires its new cosmetic-filtering engine; the designated main view still contains the older #266 distribution above. The lead recorded that refresh as pending. These receipts qualify only the stated App/engine combination and do not qualify #292's new engine behavior. Neither the passing reruns nor a passing full verifier close these gaps.

The fixed choose-to-idle bound is 10 seconds, including the choose call and polling calls. The maximum across all six final soak measurements is 0.657 seconds. The six-App overlap proof uses actual 128 MiB synthetic SQLite work and requires the latest source's exact counts after a superseded request, bounded idle, real Next, and cleanup. No product delay or count logic changed.

All App runs used synthetic fixtures and the mock Keychain. M1-only crash rows and user-present Keychain/hardware rows remain deferred. Each App run had its own screen-lock call, priority checks before and after acquisition, a bounded run, first-death stop, and owned-process cleanup. The lead's 09:18 ruling records foreign crash reports without stopping; owned crashes or a visible crash dialog stop the run. No real Keychain or desktop input was used.

Builds and verifiers used `OPEN_ENGINE_ROOT=$HOME/Developer/open-engine-s8-main`, `OPEN_E2E_NO_CRASH_PROBES=1`, and `/usr/bin/lockf -k /tmp/open-s15-heavy-a.lock $HOME/Library/Caches/OpenRE/scripts/heavy.sh`. Baseline App builds read only the recorded `open-engine-s8` distribution. No engine root was built or changed. The baseline source export and temporary control App were removed after the speed runs.

Commands after the wrappers: `tools/build.sh Debug`; `OPEN_AUTOMATION=1 tools/build.sh Release`; `tools/e2e/engine_e2e.py --config CONFIG --engine-fingerprint-only --engine-sha256 SHA`; `python3 .re/s15-k/queue_probe.py wizard-overlap`; and one separate `/usr/bin/lockf -k /tmp/open-onscreen-e2e.lock python3 .re/s15-k/guarded_suite.py --style chrome --only SUITE --config CONFIG --engine-sha256 SHA --stop-on-app-death --continue-on-timing-failure --suite-timeout 1200 --row-timeout 120` per strict suite. Plain window uses `.re/s15-k/plain.py` to preserve the normal LaunchServices path, with the same first-death gate and a 1200-second cap. Window uses Release; other functional suites use Debug. The private drivers add PID-scoped crash observation without changing suite assertions.

The speed driver uses the real Release App, four launches per receipt, local fixture navigation, and native App key input through confirmed DOM length. Each pair runs before then current. Timing waits at load1 <=12 without locks, then takes quiet -> heavy a -> screen, with nonblocking screen acquisition. Page/form measurements include automation round trips. Original J pairs1-3 use current source50028c98/engine619324d3; K pairs4-9 use current source0d7c7cfe/engine34619927. All nine pairs completed before the required main292 shared-harness merge. The all-nine median is a mixed-source, mixed-engine historical summary; the two groups are shown separately. It does not measure the later main292 App changes. The baseline source export was removed after those speed runs. Functional gates and the final full verifier were refreshed on the final merged head above.

The six added pairs show mixed results: restored paint, navigation load and navigation FCP medians fell, while form-key-to-DOM p95 rose by 9.79%. Across all nine historical pairs, form-key p95 rose by 1.57%. These short fixture comparisons do not establish unchanged performance or isolate a Section 15 cause. Every accepted receipt stayed at sampled load1 <=12; the load-rejected current8 attempt is retained separately.

Final commands: `tools/verify-all.sh --only settings-preview`, then full `tools/verify-all.sh` LAST on the same head. The final full run passed all 25 checks, with zero FAIL and zero SKIP, in 781.1 seconds including queue. Its sampled load interval was 67.94/46.90/34.24 to 19.86/30.12/35.19, peak sampled load1 110.29. These are loaded functional receipts. All local verification jobs were complete before this report was assembled at 2026-11-09T16:18:21 local.


**Cause and source evidence**

The full secrets-import order reproduced an I-8 refusal after both I-9 rows (`.re/s15-k/secrets-import__diagnosis.log:780`): the capability-OFF copy guard (`AutomationFirstRun.swift:48`) saw a busy wizard. Showing the Import sheet starts its SwiftUI `.task` (`ImportWizard.swift:186`), which can supersede the count request awaited by `choose(directory:)` (`AutomationFirstRun.swift:30`). The older await can finish while the newer count is still active. The product Next button already requires readable, idle state (`ImportWizard.swift:41`). The suite now follows that gate before requesting the copy reference.

The change exposes four read-only automation fields (`AutomationFirstRun.swift:166`): busy, readable, canContinue and aggregate category counts. I-8 starts one monotonic 10-second deadline before choose, includes choose and every state request within it, requires the exact synthetic counts, and sends Return through the actual Import sheet and App key path to Review (`secrets_import.py:364–403`). Consent and zero-Keychain assertions remain. It adds no product delay or readiness bypass.

The existing product uses a request UUID and guards after both awaits (`ImportWizard.swift:44,48,50`); a stale request cannot publish counts or clear a newer request. The selected request clears counting on its normal path at `ImportWizard.swift:53`; cancellation clears it only if that request still owns the current generation. `ArcProbe.swift:39–43` drains/cancels its worker. The real overlap proof starts a 128 MiB synthetic A source and selects a distinct B while A is still active. It requires B's exact counts in the old reply and final state, bounded idle, and actual Return to Review. A sequential ordering is reported as inconclusive, not a pass.

Main already has the strict launch selector fix in `5a867149` (#251): `launch_without_wait` excludes the early LaunchServices waiter fixture from direct-child launch (`engine_e2e.py:302–315`). This PR adds the explicit `not direct_child` assertion and receipt to `launch_waiter_early_exit` (`engine_e2e.py:4733–4739`). Both plain and strict controls exercise the unchanged real suite.

All runs use synthetic fixtures and the mock Keychain. Current engine SHA-256 is `346199271164fc90ceff0535f171be279635645e94093ec870e0cb704f2dc5dd`; the speed baseline is source `eb49e472` with recorded engine `47af3007153a883fac2acd10e491451de0abcac030c4fbebb14f15f1052115d9`. No engine root was built or changed. M1 remains held. Intentional crash rows stay M1-only; user Keychain and hardware checks remain separate.

Each App run takes a separate `lockf -k` screen lock with priority checks before and after acquisition, bounded execution, first-death stop, and cleanup. The 09:18 lead ruling cleared the foreign Section 13 renderer report and the nonfatal ExcUserFault diagnostics; the recorded baseline was reset after that ruling. New foreign reports are recorded. Owned Open crashes or a visible crash dialog stop the run. No desktop input or dialog dismissal is used.


**Retained post-merge retirement failure and diagnostics**

| Earlier c995 secrets run | Raw result | Cleanup | Start load 1/5/15 | End load 1/5/15 | Peak load1 |
| --- | --- | --- | --- | --- | --- |
| 1 | 12 PASS, 2 DEFERRED | PASS | 43.27/27.13/20.64 | 50.29/31.03/22.37 | 51.27 |
| 2 | 12 PASS, 2 DEFERRED | PASS | 50.29/31.03/22.37 | 52.13/33.61/23.66 | 53.61 |
| 3 | 7 PASS, 2 FAIL | PASS | 52.13/33.61/23.66 | 50.51/34.94/24.48 | 52.13 |
| standalone diagnostic | 12 PASS, 2 DEFERRED | PASS | 59.01/41.33/27.91 | 64.67/44.25/29.42 | 64.67 |

The earlier third run failed I-9-in-progress and its wrapper. Its receipt confirms folders absent after relaunch, unchanged ledger, refused retired destination and expected Default counts after relaunch, but did not capture the other row predicates. The cause remains unresolved. Later diagnostic runs passed; they do not explain or erase this raw FAIL. The I-9 row precedes the changed I-8 setup. No product retirement or ad-block code was changed by this branch.

| Observed at local time | Retirement row | Result | Delete/stop | Folders/context | Counts/ledger/refusal | Retired/sinks | Consent/Keychain calls | Load 1/5/15 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 15:09:50.651665 | I-9-completed | PASS | True | True | True | 1/1 | 0/0/0 | 59.92/42.69/28.71 |
| 15:09:54.907961 | I-9-in-progress | PASS | True | True | True | 1/1 | 0/0/0 | 60.72/43.14/28.95 |
| 15:13:06.616106 | I-9-completed | PASS | True | True | True | 1/1 | 0/0/0 | 20.79/34.27/28.32 |
| 15:13:10.353983 | I-9-in-progress | PASS | True | True | True | 1/1 | 0/0/0 | 20.33/33.95/28.24 |
| 15:13:33.522302 | I-9-completed | PASS | True | True | True | 1/1 | 0/0/0 | 18.64/32.45/27.86 |
| 15:13:37.167237 | I-9-in-progress | PASS | True | True | True | 1/1 | 0/0/0 | 18.64/32.45/27.86 |
| 15:16:49.625483 | I-9-completed | PASS | True | True | True | 1/1 | 0/0/0 | 11.53/22.23/24.42 |
| 15:16:53.945544 | I-9-in-progress | PASS | True | True | True | 1/1 | 0/0/0 | 10.93/21.93/24.30 |

All rows in this observation table use source c995f709 and engine34619927. The private observer copies existing predicate values before the unchanged row assertion; it makes no App call and changes no decision.


**Retained earlier password attempts**

| Attempt | Source | Engine | Failed/interrupted rows | Cleanup | Start load 1/5/15 | End load 1/5/15 | Peak load1 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| passwords__adblock | e154ff6c | 8e8a461c | PW-POLICY-never: FAIL; suite: FAIL | PASS | 17.74/12.42/11.20 | 12.27/12.81/11.60 | 19.08 |
| passwords__diagnostic | e154ff6c | 8e8a461c | PW-SW3: FAIL; suite: FAIL | PASS | 19.72/17.63/15.04 | 10.24/15.29/14.55 | 20.03 |
| passwords__without282 | 7a2b8838 | 8e8a461c | PW-POLICY-record: FAIL; suite: FAIL | PASS | 16.23/16.88/15.03 | 14.92/16.98/15.43 | 24.29 |
| passwords__with282 | e154ff6c | 8e8a461c | PW-POLICY-record: FAIL; suite: FAIL | PASS | 13.26/14.89/14.87 | 8.29/12.51/13.91 | 13.26 |
| passwords__refreshed | b25619f1 | 34619927 | PW-CARD-HTTP: INTERRUPTED; suite: INTERRUPTED | PASS | 14.27/13.18/12.09 | 12.68/12.95/12.05 | 14.27 |


Both local #282 comparison builds failed at PW-POLICY-record before applying the policy. The selected model URL was correct while the real document stayed about:blank and complete; explicit navigation recovered the reduced real-App probe. This comparison did not establish #282 as the cause. The later b256 run was interrupted by foreground loss before those rows. These attempts do not count as final acceptance. Raw logs remain private under `.re/s15-k/passwords__without282.log`, `passwords__with282.log`, and `premerge-b256-engine346/passwords__refreshed.log`.


**Retained interrupted and stopped attempts**

| Earlier final-head attempt | Raw result | Seconds | Start load 1/5/15 | End load 1/5/15 | Peak load1 | Cleanup |
| --- | --- | --- | --- | --- | --- | --- |
| overlap first attempt | STOP: AppDied gate; count settled and Review observed; successful cleanup replies; cause unresolved | 7.30 | 13.96/12.67/12.10 | 16.04/13.15/12.28 | 16.04 | PASS |
| strict first attempt | INTERRUPTED: foreground lost at focus_preserves_inactive_load | 82.37 | 13.22/13.88/13.33 | 12.34/13.31/13.15 | 13.57 | PASS |

These attempts do not count as completed acceptance. They used source0d7c7cfe and engine34619927. The overlap replay kept the original death guard and passed six Apps. The strict retry follows the shared-machine foreground-interruption rule. Raw receipts are retained in `.re/s15-k/overlap-appdied-0d/` and `.re/s15-k/window-strict-interrupted-0d/`.

An earlier full verifier was cancelled at 02:35 after a foreign crash: 21 checks passed, Site Control was cancelled by SIGTERM, and the later checks did not run. It is not full acceptance; its receipts remain under `.re/s15-k/full-interrupted-crash1*`. A later baseline fingerprint stopped before any App because its deleted build was absent; the baseline was then rebuilt and fingerprinted.

Before the required main #292 merge, source `0d7c7cfed9384a3d217606295dfc15b15e25ae82` completed all functional gates, the six added speed pairs, settings preview, and a full verifier with 25 PASS/0 FAIL/0 SKIP. That full run used engine `34619927`, load 16.27/14.71/13.01 to 20.56/17.67/15.48, peak sampled load1 22.72. Its complete receipts and prior final report remain in `.re/s15-k/verified-0d/`. The final main merge changed the shared launcher harness, so the App builds, overlap proof, three soaks, window modes, passwords/page, settings preview and full verifier were refreshed. The completed speed pairs retain their original tested source identity.

| Post-merge stopped attempt | Source | Raw result | Seconds | Start load 1/5/15 | End load 1/5/15 | Peak load1 | Cleanup |
| --- | --- | --- | --- | --- | --- | --- | --- |
| overlap first c995 attempt | c995f709 | AppDied guard after counts settled in 0.092 s and Review appeared; immediate path matched, PID live, ping replied; no crash report | 8.35 | 19.75/16.80/16.06 | 19.09/16.76/16.05 | 19.75 | PASS |

This guard stop does not count as completed acceptance. The exact stopping input was not captured in that attempt, so its cause remains unresolved. Raw receipts remain in `.re/s15-k/overlap-appdied-c995/`. The replay retains the original guard and observes its path/crash inputs without changing their values or its decision.

| Other post-merge incomplete attempts | Source | Result | Start load 1/5/15 | End load 1/5/15 | Peak load1 | Cleanup |
| --- | --- | --- | --- | --- | --- | --- |
| 32 MiB overlap observed replay | c995f709 | Four qualified Apps; fifth old reply did not prove the required selected-source ordering; full six-App proof incomplete | 20.02/18.61/16.93 | 17.78/18.19/16.81 | 20.02 | PASS |
| first secrets soak1 | c995f709 | 2 PASS then INTERRUPTED: T3 Pretty became foreground during autofill; not acceptance | 24.35/20.28/17.82 | 24.25/20.44/17.91 | 24.35 | PASS |

The final overlap proof uses 128 MiB of real synthetic SQLite work to retain the six-App overlapping ordering under variable scheduling. The deadline, exact selected counts, real Next and original death guard are unchanged. All six qualified Apps pass; the earlier 32 MiB incomplete attempt remains private in `.re/s15-k/overlap-order-inconclusive-c995/`. The foreground-interrupted soak remains in `.re/s15-k/secrets-soak1-interrupted-c995/` and is rerun from fresh fixtures under TANDEM 3.8.


| Additional c995 stopped attempts | Result | Start load 1/5/15 | End load 1/5/15 | Peak load1 | Cleanup |
| --- | --- | --- | --- | --- | --- |
| plain first attempt: AppDied guard; cause unresolved, no crash report | Not acceptance | 12.27/20.71/23.73 | 11.86/20.35/23.56 | 12.27 | PASS |
| strict first attempt: INTERRUPTED, T3 Pretty foreground during engine_close_host_activation | Not acceptance | 8.85/14.24/19.21 | 9.26/14.24/19.18 | 9.26 | PASS |

Raw receipts remain in `.re/s15-k/window-plain-appdied-c995/` and `.re/s15-k/window-strict-interrupted-c995/`. The plain replay kept the original guard and completed all functional rows. The strict interruption follows TANDEM 3.8 and requires a fresh run. The private observer records the original guard inputs and reraises the same stop.


| Additional c995 password failure | Raw result | Seconds | Start load 1/5/15 | End load 1/5/15 | Peak load1 | Cleanup |
| --- | --- | --- | --- | --- | --- | --- |
| P-5 update autofill | 36 PASS, 2 FAIL; fields did not match updated credential within existing 5 s check | 51.80 | 9.36/10.80/15.33 | 15.81/12.16/15.56 | 15.81 | PASS |

This is a real raw failure with no recorded foreground interruption or crash. Cause is unresolved. It remains in `.re/s15-k/passwords-p5-failed-c995/`; a later replay cannot erase it. The assertion is at `tools/e2e/passwords.py:692` and precedes the changed secrets I-8 setup.

The value-free P-5 observation in the fresh replay matched the updated credential on its first comparison at 15:37:46 (load40.26/22.45/19.02, sourcec995f709, engine34619927). This did not reproduce the earlier failure and does not identify its cause. The observer preserves the original return value, assertion and 5-second wait; raw observation is `.re/s15-k/p5-diagnostics.jsonl`.

Settings preview completed its CLI checks with build PASS104s and settings-preview PASS92s, but an intentional tool-turn interruption removed the wrapper monitor before it could write a complete receipt. No K process remained on the recovery inventory at 15:50. Its logs and last load sample19.30/23.37/20.92 are retained in `.re/s15-k/settings-preview-completed-turn-interrupted-c995/`; that sample is not an end-of-check load. The focused verifier is repeated before full LAST to obtain a complete monitored receipt.

Full c995 verifier attempt: INTERRUPTED after17PASS when the private crash monitor's process enumeration exceeded its unchanged5s timeout. The exception handler sent SIGTERM; sidebar-compare wrote rawFAIL0s, and seven later checks were NOT RUN. This is not a sidebar comparison product verdict. First/last sampled load 19.92/25.60/23.67→53.37/36.16/29.25, peak55.00. Raw logs/loads/summary are retained in `.re/s15-k/full-interrupted-ps-timeout-c995/`. Gate recheck at16:02 found no owned new crash report or visible dialog. The full verifier is repeated with the same guard; no timeout or gate was loosened.


**Builds**

| Run | Source head | Engine | Result | Seconds including queue | Start load 1/5/15 | End load 1/5/15 | Peak load1 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| debug-main292 | c995f709 | 34619927 | PASS | 38.9 | 16.01/17.17/15.73 | 19.38/18.00/16.10 | 20.30 |
| release-main292 | c995f709 | 34619927 | PASS | 111.3 | 19.38/18.00/16.10 | 20.12/18.98/16.74 | 24.07 |
| baseline-release-k2 | eb49e472 | 47af3007 | PASS | 144.1 | 7.35/6.37/6.84 | 9.28/7.40/7.17 | 10.72 |
| before-repair | eb49e472 | 47af3007 | PASS | 170.9 | 10.17/10.77/11.33 | 17.85/13.29/12.18 | 20.09 |

**Engine fingerprints**

| App | Result | Required engine | Start load 1/5/15 | End load 1/5/15 |
| --- | --- | --- | --- | --- |
| current-debug | PASS | 34619927 | 20.12/18.98/16.74 | 19.39/18.84/16.70 |
| current | PASS | 34619927 | 19.39/18.84/16.70 | 19.39/18.84/16.70 |
| before | PASS | 47af3007 | 16.22/13.10/12.22 | 16.68/13.25/12.28 |

**Tested App identities**

| App | Source head | Engine | Executable SHA-256 |
| --- | --- | --- | --- |
| current-debug | c995f709cc7c71d6aa89224cbc7f711fafdfed00 | 34619927 | b94425b0a10589808e0bd1ecf6191f4f17eb9dfdeef1e9e2a77e90b274fa556a |
| current-release | c995f709cc7c71d6aa89224cbc7f711fafdfed00 | 34619927 | 077eb6bdc75ce7688fcd75c93858239a9de98c7ab34e6f5540c0f9346937b7f4 |
| speed-current-release | 0d7c7cfed9384a3d217606295dfc15b15e25ae82 | 34619927 | 4cf670a44afc2bebb8e1e52da424fd5fe514e7a3e19236d9952a0199f1a4fdb2 |
| before-release | eb49e47257b8f6f32fef07bc5dc1d37b6a32af77 | 47af3007 | 1cc109d70b7f700e1e15e4a2d7c63661a836872eebbed855a33909d25a8182c4 |

**Real-App suites (earlier heads are retained diagnostics)**

| Run | Source head | Engine | Raw rows | Exit | Cleanup | Start load 1/5/15 | End load 1/5/15 | Peak load1 | Seconds |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| secrets-import__soak1 | c995f709 | 34619927 | 12 PASS, 2 DEFERRED | 0 | PASS | 23.36/35.64/28.65 | 19.98/33.65/28.17 | 23.36 | 26.9 |
| secrets-import__soak2 | c995f709 | 34619927 | 12 PASS, 2 DEFERRED | 0 | PASS | 19.98/33.65/28.17 | 18.11/32.11/27.77 | 19.98 | 26.9 |
| secrets-import__soak3 | c995f709 | 34619927 | 12 PASS, 2 DEFERRED | 0 | PASS | 12.41/23.32/24.85 | 11.25/21.81/24.24 | 12.41 | 32.8 |
| window__plain | c995f709 | 34619927 | 83 PASS, 2 FAIL | 1 | PASS | 22.96/19.54/22.40 | 16.78/18.68/21.65 | 24.43 | 134.1 |
| window__strict | c995f709 | 34619927 | 84 PASS, 1 FAIL | 1 | PASS | 10.06/13.90/18.84 | 10.55/13.16/17.91 | 14.23 | 123.9 |
| passwords__adblock | e154ff6c | 8e8a461c | 61 PASS, 2 FAIL | 1 | PASS | 17.74/12.42/11.20 | 12.27/12.81/11.60 | 19.08 | 150.6 |
| passwords__diagnostic | e154ff6c | 8e8a461c | 58 PASS, 2 FAIL | 1 | PASS | 19.72/17.63/15.04 | 10.24/15.29/14.55 | 20.03 | 146.4 |
| passwords__without282 | 7a2b8838 | 8e8a461c | 59 PASS, 2 FAIL | 1 | PASS | 16.23/16.88/15.03 | 14.92/16.98/15.43 | 24.29 | 150.3 |
| passwords__with282 | e154ff6c | 8e8a461c | 59 PASS, 2 FAIL | 1 | PASS | 13.26/14.89/14.87 | 8.29/12.51/13.91 | 13.26 | 139.7 |
| passwords__refreshed | c995f709 | 34619927 | 77 PASS, 2 BLOCKED | 0 | PASS | 32.14/18.21/17.41 | 30.97/23.96/19.98 | 42.66 | 152.0 |
| page__adblock | c995f709 | 34619927 | 105 PASS, 4 BLOCKED, 1 DEFERRED | 0 | PASS | 30.97/24.08/20.04 | 26.12/24.52/20.65 | 31.83 | 96.5 |

**Remaining scoped acceptance items**

| Rows | Disposition |
| --- | --- |
| passwords C-2; secrets-import I-5/I-6 | M1-only by rule; M1 remains held. |
| passwords PW-KC1 | User hand check; no real Keychain was read. |
| page N1_macos_delivered | User confirmation of macOS banner delivery remains open. |
| page N6_click_opens_tab | Existing service-worker clients.openWindow harness block. |
| page X1_apple_backend | Required translation language is not installed. |
| page capture_c7_incognito | No incognito window in the App; ephemeral context has separate offscreen coverage. |
| page Z3_smart_zoom | User hand check; no synthetic smart-zoom path. |

**Window launch medians and suite load intervals**

| Mode | Row | Sidebar ms | Paint ms | Raw result | Start load 1/5/15 | End load 1/5/15 |
| --- | --- | --- | --- | --- | --- | --- |
| plain | cold_fresh_profile | 316 | 570 | FAIL (known main) | 22.96/19.54/22.40 | 16.78/18.68/21.65 |
| plain | warm_existing_profile | 319 | 600 | FAIL (known main) | 22.96/19.54/22.40 | 16.78/18.68/21.65 |
| strict | cold_fresh_profile | 255 | 552 | FAIL (known main) | 10.06/13.90/18.84 | 10.55/13.16/17.91 |
| strict | warm_existing_profile | 245 | 546 | PASS | 10.06/13.90/18.84 | 10.55/13.16/17.91 |

**Busy-clears proof, measured from the start of choose(directory:)**

| Soak | Variant | Busy at choose return | Choose to idle s | Choose call s | Wait after choose s | Fixed upper bound s | Exact counts / real Next | Load 1/5/15 | Engine |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | no-switch | True | 0.464 | 0.448 | 0.016 | 10 | PASS | 20.33/33.95/28.24 | 34619927 |
| 1 | allow-switch | True | 0.481 | 0.447 | 0.034 | 10 | PASS | 19.98/33.65/28.17 | 34619927 |
| 2 | no-switch | True | 0.487 | 0.479 | 0.008 | 10 | PASS | 18.11/32.11/27.77 | 34619927 |
| 2 | allow-switch | True | 0.476 | 0.44 | 0.036 | 10 | PASS | 18.11/32.11/27.77 | 34619927 |
| 3 | no-switch | True | 0.657 | 0.559 | 0.099 | 10 | PASS | 10.93/21.93/24.30 | 34619927 |
| 3 | allow-switch | True | 0.628 | 0.555 | 0.073 | 10 | PASS | 10.93/21.93/24.30 | 34619927 |

**Focused verifier**

| Run | Result | Seconds including queue | Start load 1/5/15 | End load 1/5/15 |
| --- | --- | --- | --- | --- |
| settings-preview | PASS | 93.9 | 33.17/29.48/24.70 | 19.92/25.60/23.67 |

**Overlapping real count requests, fixed 10-second bound**

| App | A active before B | B settled seconds | Selected counts | Real Next | Cleanup | Start load 1/5/15 | End load 1/5/15 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | True | 0.088 | True | True | True | 27.90/20.73/17.93 | 26.22/20.50/17.86 |
| 2 | True | 0.09 | True | True | True | 26.22/20.50/17.86 | 26.22/20.50/17.86 |
| 3 | True | 0.092 | True | True | True | 26.22/20.50/17.86 | 25.16/20.37/17.83 |
| 4 | True | 0.089 | True | True | True | 25.16/20.37/17.83 | 25.16/20.37/17.83 |
| 5 | True | 0.099 | True | True | True | 25.16/20.37/17.83 | 25.16/20.37/17.83 |
| 6 | True | 0.181 | True | True | True | 24.35/20.28/17.82 | 24.35/20.28/17.82 |

**Full verifier**

| Check | Result | Seconds including queue | First sampled load 1/5/15 | Last sampled load 1/5/15 | Peak sampled load1 |
| --- | --- | --- | --- | --- | --- |
| build | PASS | 4 | 67.94/46.90/34.24 | 67.46/47.15/34.40 | 67.94 |
| commands-demo | PASS | 5 | 67.46/47.15/34.40 | 66.71/47.33/34.54 | 67.46 |
| roundtrip | PASS | 1 | 66.71/47.33/34.54 | 66.71/47.33/34.54 | 66.71 |
| space-legacy | PASS | 2 | 66.71/47.33/34.54 | 65.45/47.39/34.63 | 66.71 |
| space-editor | PASS | 6 | 65.45/47.39/34.63 | 65.01/47.60/34.78 | 65.45 |
| space-pad-compare | PASS | 3 | 65.01/47.60/34.78 | 65.01/47.60/34.78 | 65.01 |
| suggest-check | PASS | 25 | 65.01/47.60/34.78 | 76.57/51.49/36.54 | 76.57 |
| commands-dump | PASS | 0 | 76.57/51.49/36.54 | 76.57/51.49/36.54 | 76.57 |
| route | PASS | 15 | 76.57/51.49/36.54 | 81.64/53.90/37.67 | 81.69 |
| favicons | PASS | 10 | 81.64/53.90/37.67 | 79.68/54.41/38.04 | 81.83 |
| media-demo | PASS | 0 | 79.68/54.41/38.04 | 76.10/54.09/38.02 | 79.68 |
| sleep-demo | PASS | 1 | 76.10/54.09/38.02 | 76.10/54.09/38.02 | 76.10 |
| adblock-perf | PASS | 1 | 76.10/54.09/38.02 | 76.10/54.09/38.02 | 76.10 |
| adblock-catalog | PASS | 4 | 76.10/54.09/38.02 | 75.37/54.30/38.19 | 76.10 |
| profiles | PASS | 4 | 75.37/54.30/38.19 | 75.37/54.30/38.19 | 75.37 |
| settings-preview | PASS | 178 | 75.37/54.30/38.19 | 41.03/58.26/43.87 | 110.29 |
| sidebar-render | PASS | 112 | 41.03/58.26/43.87 | 28.50/47.89/41.49 | 41.03 |
| sidebar-compare | PASS | 144 | 28.50/47.89/41.49 | 28.43/40.92/39.68 | 32.71 |
| commandbar-render | PASS | 39 | 28.43/40.92/39.68 | 27.39/39.03/39.04 | 28.79 |
| features-render | PASS | 95 | 27.39/39.03/39.04 | 23.35/34.64/37.34 | 27.60 |
| extensions-render | PASS | 9 | 23.35/34.64/37.34 | 21.95/33.97/37.08 | 23.35 |
| sitecontrol-render | PASS | 77 | 21.95/33.97/37.08 | 26.36/32.68/36.32 | 26.39 |
| onboarding-render | PASS | 26 | 26.36/32.68/36.32 | 22.45/31.27/35.71 | 26.36 |
| boosts | PASS | 6 | 22.45/31.27/35.71 | 21.29/30.73/35.47 | 22.45 |
| verify-secrets-fixture | PASS | 12 | 21.29/30.73/35.47 | 19.86/30.12/35.19 | 21.29 |

Loads are sampled once per second. A short check can use the first observed completion sample; those samples are recorded as completion observations in the raw receipt.

**Page and form speed**

| Pair | App | Source | Engine | Restored paint ms | Navigation load ms | Navigation FCP ms | Form typing p95 ms | Start load 1/5/15 | End load 1/5/15 | Peak sampled load1 | Qualified |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | before | eb49e472 | 47af3007 | 775.000 | 125.800 | 152.000 | 29.459 | 6.00/6.31/7.51 | 5.78/6.25/7.48 | 6.00 | PASS |
| 1 | current | 50028c98 | 619324d3 | 713.000 | 120.900 | 148.000 | 30.571 | 9.43/14.54/13.20 | 8.51/14.18/13.08 | 9.43 | PASS |
| 2 | before | eb49e472 | 47af3007 | 675.000 | 108.400 | 156.000 | 29.094 | 8.51/14.18/13.08 | 8.79/14.14/13.08 | 8.79 | PASS |
| 2 | current | 50028c98 | 619324d3 | 705.000 | 124.900 | 176.000 | 33.352 | 8.81/14.06/13.05 | 9.62/14.14/13.09 | 9.62 | PASS |
| 3 | before | eb49e472 | 47af3007 | 719.000 | 123.200 | 156.000 | 29.066 | 9.41/14.02/13.05 | 9.54/13.97/13.04 | 9.54 | PASS |
| 3 | current | 50028c98 | 619324d3 | 708.000 | 114.300 | 172.000 | 28.327 | 9.09/13.80/12.99 | 8.53/13.61/12.92 | 9.09 | PASS |
| 4 | before | eb49e472 | 47af3007 | 721.000 | 116.600 | 140.000 | 44.221 | 11.19/10.14/10.91 | 10.86/10.10/10.89 | 11.19 | PASS |
| 4 | current | 0d7c7cfe | 34619927 | 537.000 | 108.400 | 120.000 | 52.257 | 10.31/10.00/10.85 | 10.29/10.00/10.85 | 10.31 | PASS |
| 5 | before | eb49e472 | 47af3007 | 663.000 | 105.600 | 132.000 | 38.912 | 9.94/9.93/10.82 | 9.71/9.89/10.79 | 9.94 | PASS |
| 5 | current | 0d7c7cfe | 34619927 | 522.000 | 106.300 | 116.000 | 32.322 | 7.60/8.95/10.32 | 7.66/8.92/10.29 | 7.66 | PASS |
| 6 | before | eb49e472 | 47af3007 | 719.000 | 119.700 | 148.000 | 43.312 | 11.05/8.87/9.94 | 11.67/9.08/9.99 | 11.67 | PASS |
| 6 | current | 0d7c7cfe | 34619927 | 756.000 | 137.000 | 164.000 | 72.001 | 8.21/9.48/9.41 | 8.67/9.53/9.43 | 8.77 | PASS |
| 7 | before | eb49e472 | 47af3007 | 652.000 | 111.900 | 124.000 | 32.710 | 10.02/10.89/10.18 | 10.10/10.89/10.19 | 10.10 | PASS |
| 7 | current | 0d7c7cfe | 34619927 | 724.000 | 212.700 | 236.000 | 51.230 | 9.85/10.83/10.17 | 10.74/10.99/10.23 | 11.32 | PASS |
| 8 | before | eb49e472 | 47af3007 | 840.000 | 136.000 | 160.000 | 38.564 | 11.32/11.11/10.28 | 11.87/11.22/10.32 | 11.87 | PASS |
| 8 | current | 0d7c7cfe | 34619927 | 462.000 | 103.300 | 132.000 | 32.171 | 10.55/12.90/12.06 | 10.56/12.82/12.05 | 10.56 | PASS |
| 9 | before | eb49e472 | 47af3007 | 654.000 | 98.200 | 108.000 | 32.837 | 11.24/12.92/12.09 | 11.86/13.02/12.13 | 11.86 | PASS |
| 9 | current | 0d7c7cfe | 34619927 | 478.000 | 106.400 | 124.000 | 33.833 | 11.39/12.91/12.09 | 11.68/12.94/12.11 | 11.68 | PASS |

| Endpoint | Before median | Current median | Change % | Median paired change % | Pairs |
| --- | --- | --- | --- | --- | --- |
| Restored process-start to paint ms | 719.000 | 705.000 | -1.95 | -8.00 | 9 |
| Navigation load ms | 116.600 | 114.300 | -1.97 | +0.66 | 9 |
| Navigation FCP ms | 148.000 | 148.000 | +0.00 | +10.26 | 9 |
| Form key to DOM p95 ms | 32.837 | 33.352 | +1.57 | +3.78 | 9 |

**J original three**

| Endpoint | Before median | Current median | Change % | Pairs |
| --- | --- | --- | --- | --- |
| Restored process-start to paint ms | 719.000 | 708.000 | -1.53 | 3 |
| Navigation load ms | 123.200 | 120.900 | -1.87 | 3 |
| Navigation FCP ms | 156.000 | 172.000 | +10.26 | 3 |
| Form key to DOM p95 ms | 29.094 | 30.571 | +5.08 | 3 |

**K additional six**

| Endpoint | Before median | Current median | Change % | Pairs |
| --- | --- | --- | --- | --- |
| Restored process-start to paint ms | 691.000 | 529.500 | -23.37 | 6 |
| Navigation load ms | 114.250 | 107.400 | -6.00 | 6 |
| Navigation FCP ms | 136.000 | 128.000 | -5.88 | 6 |
| Form key to DOM p95 ms | 38.738 | 42.531 | +9.79 | 6 |

**Unqualified attempts retained separately**

| Attempt | Runtime result | Cleanup | Start load 1/5/15 | End load 1/5/15 | Peak load1 |
| --- | --- | --- | --- | --- | --- |
| current8 | load1 exceeded 12 before page sample | True | 11.73/13.51/11.90 | 12.63/13.67/11.96 | 13.62158203125 |



The final window launch medians fit TANDEM 4a known-main ceilings (sidebar <=400 ms and paint <=700 ms). Raw budget failures remain in the row table. Extra unchanged-main controls were not required on this head.

**Every final functional row and its load**

**Secrets-import soak, Debug**

| Row | soak1 result | soak1 load 1/5/15 | soak2 result | soak2 load 1/5/15 | soak3 result | soak3 load 1/5/15 |
| --- | --- | --- | --- | --- | --- | --- |
| I-1 | PASS | 22.13/35.18/28.53 | PASS | 19.34/33.29/28.07 | PASS | 11.80/22.83/24.66 |
| I-2 | PASS | 22.44/35.03/28.51 | PASS | 18.59/32.90/27.97 | PASS | 11.98/22.68/24.60 |
| I-3 | PASS | 22.44/35.03/28.51 | PASS | 18.59/32.90/27.97 | PASS | 11.98/22.68/24.60 |
| I-4 | PASS | 22.08/34.75/28.45 | PASS | 18.87/32.72/27.93 | PASS | 11.58/22.42/24.50 |
| I-5 | DEFERRED | 20.33/33.95/28.24 | DEFERRED | 18.64/32.45/27.86 | DEFERRED | 10.93/21.93/24.30 |
| I-6 | DEFERRED | 20.33/33.95/28.24 | DEFERRED | 18.64/32.45/27.86 | DEFERRED | 10.93/21.93/24.30 |
| I-7 | PASS | 22.08/34.75/28.45 | PASS | 18.87/32.72/27.93 | PASS | 11.58/22.42/24.50 |
| I-8-allow-switch | PASS | 19.98/33.65/28.17 | PASS | 18.11/32.11/27.77 | PASS | 11.25/21.81/24.24 |
| I-8-no-switch | PASS | 20.33/33.95/28.24 | PASS | 18.11/32.11/27.77 | PASS | 10.93/21.93/24.30 |
| I-8-readiness-allow-switch | PASS | 19.98/33.65/28.17 | PASS | 18.11/32.11/27.77 | PASS | 10.93/21.93/24.30 |
| I-8-readiness-no-switch | PASS | 20.33/33.95/28.24 | PASS | 18.11/32.11/27.77 | PASS | 10.93/21.93/24.30 |
| I-9-completed | PASS | 20.79/34.27/28.32 | PASS | 18.64/32.45/27.86 | PASS | 11.53/22.23/24.42 |
| I-9-in-progress | PASS | 20.33/33.95/28.24 | PASS | 18.64/32.45/27.86 | PASS | 10.93/21.93/24.30 |
| I-negative-mock-key | PASS | 22.13/35.18/28.53 | PASS | 19.34/33.29/28.07 | PASS | 12.22/23.10/24.77 |

Rows without a row load use the stated suite interval: soak1: 23.36/35.64/28.65 to 19.98/33.65/28.17; soak2: 19.98/33.65/28.17 to 18.11/32.11/27.77; soak3: 12.41/23.32/24.85 to 11.25/21.81/24.24.

**Window, Release**

| Row | plain result | plain load 1/5/15 | strict result | strict load 1/5/15 |
| --- | --- | --- | --- | --- |
| all_spaces_strip_order | PASS | 23.65/20.13/22.35 | PASS | 12.16/13.76/18.42 |
| background_lazy | PASS | 24.05/20.15/22.37 | PASS | 12.52/13.86/18.48 |
| background_tagged_pointer | PASS | 23.65/20.13/22.35 | PASS | 12.16/13.76/18.42 |
| card_edges_1x | PASS | 15.90/18.63/21.69 | PASS | 11.18/13.42/18.08 |
| card_edges_appearance | PASS | 16.46/18.70/21.70 | PASS | 10.69/13.28/18.01 |
| card_edges_themed | PASS | 15.63/18.49/21.61 | PASS | 10.55/13.16/17.91 |
| chrome_capture_compare | PASS | 18.15/18.67/22.02 | PASS | 10.72/13.90/18.75 |
| chrome_card_material | PASS | 18.55/18.71/22.00 | PASS | 10.35/13.72/18.63 |
| chrome_dark_rings | PASS | 18.15/18.67/22.02 | PASS | 10.72/13.90/18.75 |
| chrome_inactive_material | PASS | 21.59/19.35/22.19 | PASS | 10.88/13.72/18.57 |
| close_unloaded_pinned | PASS | 22.29/19.60/22.22 | PASS | 11.57/13.74/18.49 |
| close_window_keeps_tabs | PASS | 22.96/20.04/22.31 | PASS | 13.81/14.08/18.48 |
| cold_fresh_profile | FAIL | suite interval | FAIL | suite interval |
| comparison | PASS | 16.78/18.68/21.65 | PASS | 10.55/13.16/17.91 |
| drag_undo_same_mode | PASS | 20.28/19.08/22.21 | PASS | 12.14/14.27/18.94 |
| drag_undo_single | PASS | 20.28/19.08/22.21 | PASS | 12.14/14.27/18.94 |
| engine_close_host_activation | PASS | 21.52/19.30/22.30 | PASS | 10.06/13.90/18.84 |
| engine_failure_alert | PASS | 24.23/20.12/22.38 | PASS | 12.52/13.86/18.48 |
| first_frame_timeout_continues | PASS | 24.23/20.12/22.38 | PASS | 11.61/13.71/18.46 |
| focus_preserves_find | PASS | 20.87/19.69/22.16 | PASS | 13.18/13.95/18.41 |
| focus_preserves_inactive_dismiss | PASS | 20.24/19.58/22.11 | PASS | 12.69/13.83/18.34 |
| focus_preserves_inactive_load | PASS | 20.87/19.69/22.16 | PASS | 13.18/13.95/18.41 |
| focus_preserves_sidebar | PASS | 22.08/19.91/22.25 | PASS | 13.81/14.08/18.48 |
| frame_save_debounced | PASS | 24.05/20.15/22.37 | PASS | 12.52/13.86/18.48 |
| fullscreen | PASS | 23.65/20.13/22.35 | PASS | 14.23/14.17/18.53 |
| fullscreen_hover_reveal | PASS | 23.65/20.13/22.35 | PASS | 14.23/14.17/18.53 |
| fullscreen_key_readiness | PASS | 19.42/19.42/22.04 | PASS | 12.15/13.70/18.27 |
| fullscreen_key_readiness_negative | PASS | 19.42/19.42/22.04 | PASS | 12.69/13.83/18.34 |
| hide_reveal | PASS | 24.05/20.15/22.37 | PASS | 12.16/13.76/18.42 |
| html_fullscreen_from_window | PASS | 22.96/20.04/22.31 | PASS | 14.23/14.17/18.53 |
| html_fullscreen_in_native | PASS | 23.65/20.13/22.35 | PASS | 14.23/14.17/18.53 |
| kernel_process_start | PASS | 22.29/19.60/22.22 | PASS | 11.57/13.74/18.49 |
| keys_keep_peek_lazy | PASS | 24.05/20.15/22.37 | PASS | 12.52/13.86/18.48 |
| last_window_relaunch | PASS | 22.08/19.91/22.25 | PASS | 13.81/14.08/18.48 |
| last_window_reopen | PASS | 22.96/20.04/22.31 | PASS | 13.81/14.08/18.48 |
| launch_waiter_early_exit | PASS | 24.23/20.12/22.38 | PASS | 11.61/13.71/18.46 |
| malloc_zones_early | PASS | 24.05/20.15/22.37 | PASS | 12.52/13.86/18.48 |
| motion_card_in_token | PASS | 19.21/18.88/22.12 | PASS | 11.48/14.10/18.85 |
| motion_card_out_token | PASS | 19.21/18.88/22.12 | PASS | 11.48/14.10/18.85 |
| motion_card_real_peak | PASS | 19.21/18.88/22.12 | PASS | 11.48/14.10/18.85 |
| motion_delay_negative_control | PASS | 19.21/18.88/22.12 | PASS | 11.48/14.10/18.85 |
| motion_end_frame_curves | PASS | 19.21/18.88/22.12 | PASS | 11.48/14.10/18.85 |
| motion_hide_release_continues | PASS | 19.21/18.88/22.12 | PASS | 11.48/14.10/18.85 |
| motion_reduce_motion | PASS | 19.21/18.88/22.12 | PASS | 10.72/13.90/18.75 |
| motion_show_panel_right_edge | PASS | 20.28/19.08/22.21 | PASS | 11.48/14.10/18.85 |
| motion_sidebar_toggle | PASS | 20.28/19.08/22.21 | PASS | 11.48/14.10/18.85 |
| motion_space_switch | PASS | 19.21/18.88/22.12 | PASS | 11.48/14.10/18.85 |
| multiple_window_png | PASS | 22.96/20.04/22.31 | PASS | 14.23/14.17/18.53 |
| multiple_windows | PASS | 23.65/20.13/22.35 | PASS | 12.16/13.76/18.42 |
| native_window | PASS | 24.05/20.15/22.37 | PASS | 12.52/13.86/18.48 |
| navigation_before_engine | PASS | 24.23/20.12/22.38 | PASS | 12.52/13.86/18.48 |
| quit_before_engine | PASS | 24.23/20.12/22.38 | PASS | 11.61/13.71/18.46 |
| resize_300 | PASS | 24.05/20.15/22.37 | PASS | 12.52/13.86/18.48 |
| resize_limits | PASS | 24.05/20.15/22.37 | PASS | 12.52/13.86/18.48 |
| resize_lost_up_key | PASS | 21.52/19.30/22.30 | PASS | 12.14/14.27/18.94 |
| resize_lost_up_sheet_hides | PASS | 20.28/19.08/22.21 | PASS | 12.14/14.27/18.94 |
| reveal_timing | PASS | 15.90/18.63/21.69 | PASS | 11.18/13.42/18.08 |
| selected_only_0 | PASS | 20.58/19.18/22.11 | PASS | 11.45/13.80/18.57 |
| selected_only_1 | PASS | 20.58/19.18/22.11 | PASS | 11.45/13.80/18.57 |
| selected_only_2 | PASS | 22.05/19.51/22.21 | PASS | 11.01/13.67/18.50 |
| selected_only_3 | PASS | 22.05/19.51/22.21 | PASS | 11.01/13.67/18.50 |
| selected_only_4 | PASS | 22.29/19.60/22.22 | PASS | 11.57/13.74/18.49 |
| space_header_url_field | PASS | 17.02/18.90/21.80 | PASS | 11.18/13.42/18.08 |
| toggle_sidebar | PASS | 23.65/20.13/22.35 | PASS | 12.16/13.76/18.42 |
| traffic_light_actions | PASS | 17.98/19.11/21.89 | PASS | 12.14/13.67/18.23 |
| traffic_light_look | PASS | 18.59/19.25/21.96 | PASS | 12.14/13.67/18.23 |
| traffic_light_stale_hover | PASS | 17.02/18.90/21.80 | PASS | 11.18/13.42/18.08 |
| traffic_lights | PASS | 19.42/19.42/22.04 | PASS | 12.15/13.70/18.27 |
| warm_existing_profile | FAIL | suite interval | PASS | suite interval |
| width_cmd_s_restores_start | PASS | 20.28/19.08/22.21 | PASS | 11.48/14.10/18.85 |
| width_double_click_reset | PASS | 20.28/19.08/22.21 | PASS | 11.48/14.10/18.85 |
| width_hidden_commit | PASS | 20.28/19.08/22.21 | PASS | 11.48/14.10/18.85 |
| width_hide_while_pressed | PASS | 20.28/19.08/22.21 | PASS | 12.14/14.27/18.94 |
| width_live_limits | PASS | 20.28/19.08/22.21 | PASS | 12.14/14.27/18.94 |
| width_show_before_release | PASS | 20.28/19.08/22.21 | PASS | 12.14/14.27/18.94 |
| width_toolbar_floor | PASS | 20.28/19.08/22.21 | PASS | 12.14/14.27/18.94 |
| width_visible_commit_once | PASS | 20.28/19.08/22.21 | PASS | 12.14/14.27/18.94 |
| window_before_engine_0 | PASS | 21.59/19.35/22.19 | PASS | 11.45/13.80/18.57 |
| window_before_engine_1 | PASS | 20.58/19.18/22.11 | PASS | 11.45/13.80/18.57 |
| window_before_engine_2 | PASS | 22.05/19.51/22.21 | PASS | 11.01/13.67/18.50 |
| window_before_engine_3 | PASS | 22.05/19.51/22.21 | PASS | 11.01/13.67/18.50 |
| window_before_engine_4 | PASS | 22.29/19.60/22.22 | PASS | 11.57/13.74/18.49 |
| window_close_preserves_other_host | PASS | 22.96/20.04/22.31 | PASS | 13.81/14.08/18.48 |
| window_persistence | PASS | 22.96/20.04/22.31 | PASS | 14.23/14.17/18.53 |
| window_png | PASS | 20.58/19.18/22.11 | PASS | 11.45/13.80/18.57 |

Rows without a row load use the stated suite interval: plain: 22.96/19.54/22.40 to 16.78/18.68/21.65; strict: 10.06/13.90/18.84 to 10.55/13.16/17.91.

**Passwords with native ad blocking, Debug**

| Row | refreshed result | refreshed load 1/5/15 |
| --- | --- | --- |
| C-1 | PASS | 31.80/23.53/19.71 |
| C-2 | BLOCKED | 31.80/23.53/19.71 |
| C-3 | PASS | 31.80/23.53/19.71 |
| M-1-address | PASS | 32.36/18.92/17.68 |
| M-1-addressUpdate | PASS | 32.36/18.92/17.68 |
| M-1-card | PASS | 31.87/18.60/17.56 |
| M-1-empty-long-host | PASS | 32.36/18.92/17.68 |
| M-1-input-limits | PASS | 42.55/21.92/18.78 |
| M-1-password | PASS | 31.87/18.60/17.56 |
| M-1-passwordUpdate | PASS | 31.87/18.60/17.56 |
| M-2-dismiss | PASS | 32.36/18.92/17.68 |
| M-2-never | PASS | 32.36/18.92/17.68 |
| M-2-save | PASS | 32.36/18.92/17.68 |
| M-3-capacity-and-focus | PASS | 41.38/21.34/18.56 |
| M-3-page-close-ignored | PASS | 41.38/21.34/18.56 |
| M-3-same-page-replacement | PASS | 41.06/20.94/18.40 |
| M-3-withdraw | PASS | 41.06/20.94/18.40 |
| M-4-browser-shortcuts-blocked | PASS | 42.55/21.92/18.78 |
| M-4-cmd-period | PASS | 42.55/21.92/18.78 |
| M-4-enter | PASS | 41.38/21.34/18.56 |
| M-4-escape | PASS | 41.38/21.34/18.56 |
| M-4-return | PASS | 41.38/21.34/18.56 |
| M-5-window-close-ignored | PASS | 42.55/21.92/18.78 |
| M-6-early-exit-cleanup | PASS | 42.55/21.92/18.78 |
| M-6-no-crash | PASS | 42.55/21.92/18.78 |
| MP-1-commandbar | PASS | 42.55/21.92/18.78 |
| MP-2-commandbar-singleton | PASS | 42.66/22.28/18.92 |
| MP-3-settings-passwords-singleton | PASS | 42.66/22.28/18.92 |
| MP-4-settings-credit-cards | PASS | 42.66/22.28/18.92 |
| MP-5-second-profile | PASS | 42.66/22.28/18.92 |
| MP-6-incognito-unavailable | PASS | 42.66/22.28/18.92 |
| MP-7-no-crash | PASS | 42.66/22.28/18.92 |
| P-1 | PASS | 42.37/22.56/19.04 |
| P-10 | PASS | 36.38/22.21/18.98 |
| P-11 | PASS | 36.38/22.21/18.98 |
| P-12 | PASS | 34.11/21.97/18.91 |
| P-13 | PASS | 31.75/22.51/19.21 |
| P-14 | PASS | 31.75/22.51/19.21 |
| P-15 | PASS | 30.97/23.96/19.98 |
| P-16 | PASS | 31.77/22.67/19.28 |
| P-17 | PASS | 31.77/22.67/19.28 |
| P-18 | PASS | 31.77/22.67/19.28 |
| P-19 | PASS | 31.77/22.67/19.28 |
| P-2 | PASS | 42.37/22.56/19.04 |
| P-20 | PASS | 31.15/22.69/19.31 |
| P-21 | PASS | 31.15/22.69/19.31 |
| P-22 | PASS | 32.05/23.44/19.66 |
| P-23 | PASS | 31.15/22.69/19.31 |
| P-24-post-login-redirect | PASS | 32.49/23.38/19.61 |
| P-3 | PASS | 42.37/22.56/19.04 |
| P-4 | PASS | 42.37/22.56/19.04 |
| P-4-mouse | PASS | 40.26/22.45/19.02 |
| P-5 | PASS | 40.26/22.45/19.02 |
| P-6 | PASS | 38.15/22.31/18.99 |
| P-7 | PASS | 38.15/22.31/18.99 |
| P-8 | PASS | 38.15/22.31/18.99 |
| P-9 | PASS | 38.15/22.31/18.99 |
| PW-CARD-HTTP | PASS | 36.38/22.21/18.98 |
| PW-CARD-HTTPS | PASS | 36.38/22.21/18.98 |
| PW-HF1 | PASS | 30.38/23.37/19.68 |
| PW-HF2-escape | PASS | 30.35/23.60/19.80 |
| PW-HF2-return | PASS | 30.91/23.60/19.78 |
| PW-HF3-tab-close | PASS | 30.35/23.60/19.80 |
| PW-HF4-window-close | PASS | 30.97/23.84/19.91 |
| PW-HF5-navigate | PASS | 30.97/23.84/19.91 |
| PW-HF6-space | PASS | 30.97/23.96/19.98 |
| PW-HF7-quit | PASS | 30.97/23.96/19.98 |
| PW-KC1 | BLOCKED | 31.80/23.53/19.71 |
| PW-MOCK-offers | PASS | 31.80/23.53/19.71 |
| PW-POLICY-dismiss | PASS | 32.49/23.38/19.61 |
| PW-POLICY-never | PASS | 31.57/23.05/19.48 |
| PW-POLICY-record | PASS | 31.57/23.05/19.48 |
| PW-POLICY-save | PASS | 31.57/23.05/19.48 |
| PW-PREFS-input | PASS | 42.66/22.28/18.92 |
| PW-REAUTH-default | PASS | 42.66/22.28/18.92 |
| PW-REAUTH-request | PASS | 31.75/22.51/19.21 |
| PW-SW1 | PASS | 31.15/22.69/19.31 |
| PW-SW2 | PASS | 30.58/22.71/19.34 |
| PW-SW3 | PASS | 31.57/23.05/19.48 |

Rows without a row load use the stated suite interval: refreshed: 32.14/18.21/17.41 to 30.97/23.96/19.98.

**Page with native ad blocking, Debug**

| Row | adblock result | adblock load 1/5/15 |
| --- | --- | --- |
| A1_appearance_checkmarks_chrome | PASS | 30.49/24.09/20.07 |
| A1_appearance_light_dark_chrome | PASS | 30.49/24.09/20.07 |
| A1_appearance_stored_chrome | PASS | 30.49/24.09/20.07 |
| A2_appearance_automatic_follows_app_chrome | PASS | 30.49/24.09/20.07 |
| CL_clipboard_restored | PASS | 31.83/24.90/20.49 |
| CL_copy_url_plain_toast_unchanged | PASS | 31.73/24.76/20.42 |
| CL_folder_markdown | PASS | 31.73/24.76/20.42 |
| CL_folder_mixed_trackers | PASS | 31.73/24.76/20.42 |
| CL_folder_plain | PASS | 31.73/24.76/20.42 |
| CL_folder_without_trackers | PASS | 31.73/24.76/20.42 |
| CL_manager_folder_without_browser | PASS | 31.73/24.76/20.42 |
| CL_manager_without_browser | PASS | 31.73/24.76/20.42 |
| CL_navigation_unchanged | PASS | 31.73/24.76/20.42 |
| CL_page_share | PASS | 31.73/24.76/20.42 |
| CL_row_plain | PASS | 31.73/24.76/20.42 |
| CL_row_share | PASS | 31.73/24.76/20.42 |
| CL_row_without_trackers | PASS | 31.73/24.76/20.42 |
| CL_selection_contains_both_tabs | PASS | 31.73/24.76/20.42 |
| CL_selection_markdown | PASS | 31.73/24.76/20.42 |
| CL_selection_plain | PASS | 31.73/24.76/20.42 |
| CL_split_contains_both_tabs | PASS | 31.73/24.76/20.42 |
| CL_split_menu_plain | PASS | 31.83/24.90/20.49 |
| CL_split_pane_markdown | PASS | 31.83/24.90/20.49 |
| CL_toast_share | PASS | 31.73/24.76/20.42 |
| D1_javascript_console_panel_chrome | PASS | 30.49/24.09/20.07 |
| D1_key_cmd_opt_j_chrome | PASS | 30.49/24.09/20.07 |
| D1_quit_with_devtools_open | PASS | 28.54/23.88/20.04 |
| D2_network_inspector_panel_chrome | PASS | 28.93/23.88/20.02 |
| D3_developer_mode | PASS | 28.93/23.88/20.02 |
| D4_allow_js_apple_events_checkmark | PASS | 30.49/24.09/20.07 |
| D4_allow_js_apple_events_osascript | PASS | 30.49/24.09/20.07 |
| D4_allow_js_apple_events_setting | PASS | 30.49/24.09/20.07 |
| EP3_selection_change_bit | PASS | 30.15/24.77/20.50 |
| H1_task_manager_window | PASS | 28.93/23.88/20.02 |
| H2_cancel_trace | PASS | 28.93/23.88/20.02 |
| H2_record_trace_stop | PASS | 28.93/23.88/20.02 |
| H3_copy_open_info | PASS | 28.93/23.88/20.02 |
| H4_cast_menu_hidden | PASS | 28.93/23.88/20.02 |
| H4_media_router_off | PASS | 28.93/23.88/20.02 |
| H_reveal_open_data | PASS | 28.93/23.88/20.02 |
| K1_clear_cookies_and_refresh_chrome | PASS | 30.49/24.09/20.07 |
| K2_clear_cache_disabled_before_E2_chrome | PASS | 30.49/24.09/20.07 |
| N1_allow_asks_macos | PASS | 30.15/24.77/20.50 |
| N1_engine_display | PASS | 30.15/24.77/20.50 |
| N1_engine_list | PASS | 29.07/24.71/20.52 |
| N1_macos_delivered | BLOCKED | 29.07/24.71/20.52 |
| N2_alerts_helper | PASS | 29.07/24.71/20.52 |
| N2_bundles | PASS | 29.07/24.71/20.52 |
| N2_listed | PASS | 29.07/24.71/20.52 |
| N3_activation | PASS | 29.07/24.71/20.52 |
| N3_notification_click | PASS | 28.98/24.77/20.57 |
| N4_click_fallback_selects_tab | PASS | 28.98/24.77/20.57 |
| N6_click_opens_tab | BLOCKED | 26.40/24.47/20.56 |
| N6_engine_display | PASS | 28.98/24.77/20.57 |
| Q1_quote_link_scrolls | PASS | 31.83/24.90/20.49 |
| Q2_quote_context | PASS | 31.83/24.90/20.49 |
| Q2_selection_and_link | PASS | 30.15/24.77/20.50 |
| Q3_quote_without_selection | PASS | 31.83/24.90/20.49 |
| Q4_copy_url_offers_quote | PASS | 31.83/24.90/20.49 |
| Q5_share_quote_button | PASS | 31.83/24.90/20.49 |
| SW1_indicator_hides_after_completion | PASS | 31.12/24.87/20.50 |
| SW1_swipe_back_forward | PASS | 31.12/24.87/20.50 |
| SW2_partial_swipe_cancels | PASS | 31.12/24.87/20.50 |
| SW3_split_pane_swipe | PASS | 30.15/24.77/20.50 |
| SW4_capture_overlay_pauses_swipes | PASS | 31.12/24.87/20.50 |
| SW4_swipe_disabled | PASS | 31.12/24.87/20.50 |
| T-E1_copy_url_clean | PASS | 28.40/24.00/20.12 |
| T-E2_copy_url_share | PASS | 31.73/24.76/20.42 |
| X1_apple_backend | BLOCKED | 26.12/24.52/20.65 |
| X1_context_menu_item | PASS | 26.40/24.47/20.56 |
| X1_marker_fallback | PASS | 26.40/24.47/20.56 |
| X1_offer | PASS | 26.40/24.47/20.56 |
| X1_popover_offer_and_escape | PASS | 26.40/24.47/20.56 |
| X1_translate | PASS | 26.40/24.47/20.56 |
| X2_revert | PASS | 26.40/24.47/20.56 |
| X2_revert_keeps_page_structure | PASS | 27.40/24.71/20.67 |
| X3_same_document | PASS | 27.40/24.71/20.67 |
| X3_same_host_auto_translate | PASS | 27.40/24.71/20.67 |
| X4_never_and_reset | PASS | 27.40/24.71/20.67 |
| X5_no_network | PASS | 26.40/24.47/20.56 |
| X6_redo | PASS | 26.40/24.47/20.56 |
| X6_undo | PASS | 26.40/24.47/20.56 |
| X_idle_no_polling | PASS | 26.12/24.52/20.65 |
| X_offer_after_minimized_load | PASS | 26.65/24.60/20.65 |
| X_root_notranslate | PASS | 27.40/24.71/20.67 |
| X_stale_result_dropped | PASS | 27.40/24.71/20.67 |
| Z1_zoom_toasts | PASS | 31.83/24.90/20.49 |
| Z2_peek_pinch_then_actual_size | PASS | 31.83/24.90/20.49 |
| Z2_pinch_then_actual_size | PASS | 31.83/24.90/20.49 |
| Z3_smart_zoom | DEFERRED | 31.83/24.90/20.49 |
| Z4_no_chromium_zoom_bubble | PASS | 31.83/24.90/20.49 |
| capture_2x_c1_area | PASS | 28.17/23.88/20.06 |
| capture_2x_c2_full_page | PASS | 28.17/23.88/20.06 |
| capture_2x_c3_portrait | PASS | 28.40/24.00/20.12 |
| capture_2x_full_page_cap | PASS | 28.40/24.00/20.12 |
| capture_c1_area | PASS | 28.54/23.88/20.04 |
| capture_c2_full_page | PASS | 28.54/23.88/20.04 |
| capture_c3_portrait | PASS | 28.54/23.88/20.04 |
| capture_c4_escape | PASS | 28.54/23.88/20.04 |
| capture_c5_drag | PASS | 28.17/23.88/20.06 |
| capture_c6_click_replay | PASS | 28.17/23.88/20.06 |
| capture_c7_incognito | BLOCKED | 28.40/24.00/20.12 |
| capture_card_anchor | PASS | 28.54/23.88/20.04 |
| capture_card_copy_save_escape | PASS | 28.54/23.88/20.04 |
| capture_card_lifetime | PASS | 28.54/23.88/20.04 |
| capture_context_menu | PASS | 28.17/23.88/20.06 |
| capture_delete | PASS | 28.54/23.88/20.04 |
| capture_menu_enabled | PASS | 28.54/23.88/20.04 |
| capture_shortcut_hint | PASS | 28.54/23.88/20.04 |
| capture_shortcut_hint_once | PASS | 28.40/24.00/20.12 |

Rows without a row load use the stated suite interval: adblock: 30.97/24.08/20.04 to 26.12/24.52/20.65.


**Review checklist**

| Review checklist item | Result | Evidence |
| --- | --- | --- |
| External sizes/counts/depth/length | N/A | No input parser or input limit changed; automation adds three booleans and the existing fixed-category count map. |
| Allocator ceiling | N/A | No new allocation-sized input. The private overlap fixture uses a 128 MiB SQLite payload, copied through the existing reader. |
| Limit boundary cases | N/A | No limits changed. |
| Unknown/trailing parsed input | N/A | No parser changed. |
| Delegate reentry | N/A | No delegate or callback change. Automation reads MainActor state. |
| Close/free once | N/A | No product ownership change; real-App cleanup is recorded separately for every run. |
| Stale IDs/generations | PASS | Existing request UUID and both stale guards at ImportWizard.swift:44,48,50; six overlapping real-App source switches retain B counts. |
| Pending state before dependent action | PASS | secrets_import.py:364 starts one shared 10 s deadline before choose; :380 waits for readable and idle; :384 requires exact counts. |
| Real keys | PASS | secrets_import.py:389 identifies the named Import sheet after layout; :393 sends Return through route=app and :394 requires Review. No new product focus context. |
| Key ownership after main merge | PASS | sendKey defaults to the browser; the new proof supplies the Import sheet ID. Existing launch selector remains owned by main #251. |
| Hidden flags/actions | N/A | No user-visible flag or hidden-action behavior changed. Existing mock-key consent and zero-Keychain assertions remain. |
| Pre-fix failure | PASS | Retained full-order secrets diagnosis fails at I-8 after both I-9 rows; safe error maps the capability-OFF guard rejected by busy. J retained the strict early-launcher failure. New readiness fields are observational. |
| Pixel comparison | N/A | No image comparator, baseline or threshold changed; existing window image rows run unchanged. |
| Specific dialog | PASS | secrets_import.py:389-393 requires the visible Import sheet with its expected title, then targets that sheet's actual window ID. |
| Timing/deadlines | PASS | One monotonic 10 s liveness deadline includes choose and polling calls. Receipts retain choose call, wait, total, exact counts and loads. No scheduled timing tolerance changed. |
| Isolation | PASS | Each suite owns synthetic data roots, cache roots and ephemeral fixture ports; no real Keychain. Shared defaults are saved, reset and restored in finally. Screen runs serialize. |
| Dialog failure cleanup | PASS | The reproduced original failure and both private Next diagnostic failures verified cleanup; completed acceptance runs also require owned-process cleanup. |
| Reduce Motion | N/A | No UI/motion code changed. |
| Interrupted animation | N/A | No animation code changed. |
| Resize/layout motion | N/A | No product layout change. The probe waits for existing SwiftUI layout before input. |
| Arc visual parity | N/A | No visual assets or drawing change. Existing real-window checks remain unmodified; Arc is not launched. |
| Comments match behavior | PASS | Suite comment explains the independent SwiftUI count task and explicit sheet input target. |
| Plan/report/follow-ups agree | PASS | Final report marks acceptance PARTIAL; it retains unresolved I-9 and P-5 failures, the pending main292 engine refresh, historical interruptions, M1-only rows, user checks and existing blocks. |


## Historical child J report, 2026-11-08

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
