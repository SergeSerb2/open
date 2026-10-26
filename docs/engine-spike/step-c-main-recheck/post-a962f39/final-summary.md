# Repeated main-merge verification

Source: `342800c`; default **fork**, production **Chrome** hosting. Both builds embed `4C4C4432-5555-3144-A144-B678285BC5F4` (distribution stamp suffix `1793036548`). Each cell links its full receipt. Interrupted attempts are separate from accepted passes.

| Config | Suite | Run 1 | Run 2 | Run 3 |
|---|---|---|---|---|
| Debug | window | [45/45 PASS](debug-window-1.json) | [45/45 PASS](debug-window-2.json) | [45/45 PASS](debug-window-3.json) |
| Debug | sidebar | [18/18 PASS](debug-sidebar-1.json) | [18/18 PASS](debug-sidebar-2.json) | [18/18 PASS](debug-sidebar-3.json) |
| Debug | shell | [6/6 PASS](debug-shell-1.json) | [6/6 PASS](debug-shell-2.json) | [6/6 PASS](debug-shell-3.json) |
| Debug | features | [19/19 PASS](debug-features-1.json) | [19/19 PASS](debug-features-2.json) | [19/19 PASS](debug-features-3.json) |
| Debug | actions | [45/45 PASS](debug-actions-1.json) | [45/45 PASS](debug-actions-2.json) | [45/45 PASS](debug-actions-3.json) |
| Release | window | [45 PASS / 2 FAIL](release-window-1.json) | [45 PASS / 2 FAIL](release-window-2.json) | [45 PASS / 2 FAIL](release-window-3.json) |
| Release | sidebar | [18/18 PASS](release-sidebar-1.json) | [18/18 PASS](release-sidebar-2.json) | [18/18 PASS](release-sidebar-3.json) |
| Release | shell | [6/6 PASS](release-shell-1.json) | [6/6 PASS](release-shell-2.json) | [6/6 PASS](release-shell-3.json) |
| Release | features | [19/19 PASS](release-features-1.json) | [19/19 PASS](release-features-2.json) | [19/19 PASS](release-features-3.json) |
| Release | actions | [6 PASS / 1 FAIL](release-actions-1.json) | [45/45 PASS](release-actions-2.json) | [45/45 PASS](release-actions-3.json) |

Debug window runs have two named Release-only timing SKIPs each. Sidebar runs retain the durable per-profile engine-storage BLOCKED row (`root_cache_path`, docs/followups.md). Those rows are not passes.

## Native-focus interruptions

Up to three fresh workflow attempts are allowed. Original assertions and the frontmost app trace remain in each receipt. A dispatched key is never retried against partially changed state. The lead will repeat focus-dependent acceptance without competing on-screen tests before merge.

| Run | Attempt | Interrupted step/reason | Frontmost app(s) |
|---|---:|---|---|
| All | — | None | — |

## Failed assertions and recorded load exceptions

| Run | Failed checks |
|---|---|
| release-window-1 | cold_fresh_profile, warm_existing_profile |
| release-window-2 | cold_fresh_profile, warm_existing_profile |
| release-window-3 | cold_fresh_profile, warm_existing_profile |
| release-actions-1 | suite |

## Unresolved native-readiness failure

Release actions repetition 1 stopped before native Copy with
`key: key focus not ready: active=true target=104345 key=104345`.
It has no observed foreground-loss event and remains **FAIL**, not INTERRUPTED.
The error did not log `target.isKeyWindow`; its exact native readiness cause is
**unconfirmed**. Release repetitions 2 and 3 passed 45/45, but do not clear it.

Two separate locked real-app diagnostics passed 40 navigation/Copy cycles each.
The second repeated the exact new-tab → edit-current → native Copy → close
sequence and recorded 400 native input steps, all active/key at their before/after
boundaries. These diagnostics did not reproduce the failure and do not replace
its acceptance row. See [the diagnostic summary](focus-readiness-unresolved.json).
The lead's exclusive focus-dependent verification remains required before merge.

## Command-bar result timing (ms)

The first measurement includes construction. Repeat measurements use the same real bar. The 50 ms assertions remain unchanged.

| Config | Repeat | First open | First query phase | Repeat open | Budget |
|---|---:|---:|---:|---:|---|
| Debug | 1 | 31.94 | 27.75 | 27.07 | PASS |
| Debug | 2 | 27.36 | 23.07 | 23.21 | PASS |
| Debug | 3 | 32.01 | 26.31 | 34.53 | PASS |
| Release | 1 | 18.89 | 15.0 | unreached | unreached |
| Release | 2 | 40.95 | 35.87 | 41.84 | PASS |
| Release | 3 | 18.82 | 15 | 30.68 | PASS |

## Release launch medians (ms)

Each row has five launches. Every attempted workflow that reached timing evaluation is shown, including interrupted workflows; no timing miss is discarded. Budgets remain sidebar ≤250 ms / first contentful paint ≤700 ms. Misses under concurrent machine load remain recorded load exceptions, not passes. Step I must repeat on an idle machine.

| Repeat / attempt | Profile | Sidebar | First contentful paint | Budget | Load average at start |
|---|---|---:|---:|---|---|
| 1 / 1 | cold_fresh_profile | 378 | 637 | FAIL | [14.63, 14.88, 16.8] |
| 1 / 1 | warm_existing_profile | 382 | 648 | FAIL | [14.63, 14.88, 16.8] |
| 2 / 1 | cold_fresh_profile | 388 | 664 | FAIL | [10.15, 12.77, 15.59] |
| 2 / 1 | warm_existing_profile | 398 | 693 | FAIL | [10.15, 12.77, 15.59] |
| 3 / 1 | cold_fresh_profile | 330 | 556 | FAIL | [10.64, 11.61, 14.61] |
| 3 / 1 | warm_existing_profile | 313 | 544 | FAIL | [10.64, 11.61, 14.61] |

## Static comparison

| Config | Suite | Completed comparisons | Worst position (pt) | Worst ΔE00 |
|---|---|---:|---:|---:|
| Debug | window | 3/3 | 1.0 | 1.61 |
| Debug | sidebar | 3/3 | 1.0 | 1.61 |
| Release | window | 3/3 | 1.0 | 1.61 |
| Release | sidebar | 3/3 | 1.0 | 1.61 |

## Rule 10 / render checks

Merged main through `a962f39`; normal merge, no rebase or force-push. Builds and full verification completed before the heavy-job-slot rule arrived at 13:06 local time. All later build/verifier commands use heavy.sh; none were needed for the unchanged tested source. Every on-screen invocation uses the separate per-suite lock. Full verify-all:

| Check | Result | Seconds |
|---|---|---:|
| build | PASS | 53 |
| commands-demo | PASS | 4 |
| roundtrip | PASS | 2 |
| space-legacy | PASS | 3 |
| suggest-check | PASS | 16 |
| commands-dump | PASS | 0 |
| route | PASS | 3 |
| favicons | PASS | 2 |
| media-demo | PASS | 1 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 1 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 3 |
| settings-preview | PASS | 76 |
| sidebar-render | PASS | 35 |
| sidebar-compare | PASS | 109 |
| commandbar-render | PASS | 15 |
| features-render | PASS | 10 |
| boosts | PASS | 3 |

`features-render check`: 151/151 PASS. `sidebar-render check`: 368/368 PASS. Debug and Release automation builds PASS. No unit tests or desktop input. Screenshots contain only Open windows; reference data and pixels remain private in .re.
