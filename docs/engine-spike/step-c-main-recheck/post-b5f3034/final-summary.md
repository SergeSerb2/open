# Repeated main-merge verification

Source: `cd78cef`; default **fork**, production **Chrome** hosting. Both builds embed `4C4C4432-5555-3144-A144-B678285BC5F4` (distribution stamp suffix `1793036548`). Each cell links its full receipt. Interrupted attempts are separate from accepted passes.

| Config | Suite | Run 1 | Run 2 | Run 3 |
|---|---|---|---|---|
| Debug | window | [45/45 PASS](debug-window-1.json) | [28 PASS / 1 FAIL](debug-window-2.json) | [45/45 PASS](debug-window-3.json) |
| Debug | sidebar | [18/18 PASS](debug-sidebar-1.json) | [18/18 PASS](debug-sidebar-2.json) | [18/18 PASS](debug-sidebar-3.json) |
| Debug | shell | [6/6 PASS](debug-shell-1.json) | [6/6 PASS](debug-shell-2.json) | [6/6 PASS](debug-shell-3.json) |
| Debug | features | [18 PASS / 1 FAIL](debug-features-1.json) | [18 PASS / 1 FAIL](debug-features-2.json) | [19/19 PASS](debug-features-3.json) |
| Debug | actions | [45/45 PASS](debug-actions-1.json) | [44 PASS / 1 FAIL](debug-actions-2.json) | [45/45 PASS; 1 interrupted attempt](debug-actions-3.json) |
| Release | window | [45 PASS / 2 FAIL](release-window-1.json) | [45 PASS / 2 FAIL](release-window-2.json) | [45 PASS / 2 FAIL; 1 interrupted attempt](release-window-3.json) |
| Release | sidebar | [18/18 PASS](release-sidebar-1.json) | [18/18 PASS](release-sidebar-2.json) | [18/18 PASS](release-sidebar-3.json) |
| Release | shell | [6/6 PASS](release-shell-1.json) | [6/6 PASS](release-shell-2.json) | [6/6 PASS](release-shell-3.json) |
| Release | features | [19/19 PASS](release-features-1.json) | [19/19 PASS](release-features-2.json) | [19/19 PASS](release-features-3.json) |
| Release | actions | [45/45 PASS](release-actions-1.json) | [45/45 PASS](release-actions-2.json) | [44 PASS / 1 FAIL](release-actions-3.json) |

Debug window runs have two named Release-only timing SKIPs each. Sidebar runs retain the durable per-profile engine-storage BLOCKED row (`root_cache_path`, docs/followups.md). Those rows are not passes.

## Native-focus interruptions

Up to three fresh workflow attempts are allowed. Original assertions and the frontmost app trace remain in each receipt. A dispatched key is never retried against partially changed state. The lead will repeat focus-dependent acceptance without competing on-screen tests before merge.

| Run | Attempt | Interrupted step/reason | Frontmost app(s) |
|---|---:|---|---|
| debug-actions-3 | 1 | foreground lost during settings_persist_relaunch | cmux |
| release-window-3 | 1 | window-focus: key focus not ready: active=false target=92456 key=0 | T3 Pretty Internal (Nightly) |

## Ordinary failures

| Run | Failed checks |
|---|---|
| debug-window-2 | suite |
| debug-features-1 | widevine |
| debug-features-2 | widevine |
| debug-actions-2 | first_open_results_budget |
| release-window-1 | cold_fresh_profile, warm_existing_profile |
| release-window-2 | cold_fresh_profile, warm_existing_profile |
| release-window-3 | cold_fresh_profile, warm_existing_profile |
| release-actions-3 | first_open_results_budget |

## Command-bar result timing (ms)

The first measurement includes construction. Repeat measurements use the same real bar. The 50 ms assertions remain unchanged.

| Config | Repeat | First open | First query phase | Repeat open | Budget |
|---|---:|---:|---:|---:|---|
| Debug | 1 | 25.23 | 20.95 | 19.01 | PASS |
| Debug | 2 | 87.42 | 80.58 | 27.28 | FAIL |
| Debug | 3 | 25.63 | 21.4 | 16.07 | PASS |
| Release | 1 | 34.48 | 30.83 | 11.65 | PASS |
| Release | 2 | 42.53 | 37.99 | 24.13 | PASS |
| Release | 3 | 66.28 | 61.46 | 20.38 | FAIL |

## Release launch medians (ms)

Each row has five launches. Every attempted workflow that reached timing evaluation is shown, including interrupted workflows; no timing miss is discarded. Budgets remain sidebar ≤250 ms / first contentful paint ≤700 ms. These loaded-machine results do not replace Step I on an idle machine.

| Repeat / attempt | Profile | Sidebar | First contentful paint | Budget | Load average at start |
|---|---|---:|---:|---|---|
| 1 / 1 | cold_fresh_profile | 319 | 576 | FAIL | [9.0322265625, 10.51220703125, 11.12939453125] |
| 1 / 1 | warm_existing_profile | 336 | 597 | FAIL | [9.0322265625, 10.51220703125, 11.12939453125] |
| 2 / 1 | cold_fresh_profile | 318 | 597 | FAIL | [8.71826171875, 9.9560546875, 10.80078125] |
| 2 / 1 | warm_existing_profile | 294 | 535 | FAIL | [8.71826171875, 9.9560546875, 10.80078125] |
| 3 / 1 (interrupted) | cold_fresh_profile | 338 | 631 | FAIL | [12.01123046875, 10.37158203125, 10.7861328125] |
| 3 / 1 (interrupted) | warm_existing_profile | 376 | 658 | FAIL | [12.01123046875, 10.37158203125, 10.7861328125] |
| 3 / 2 | cold_fresh_profile | 406 | 713 | FAIL | [9.8359375, 10.0322265625, 10.6357421875] |
| 3 / 2 | warm_existing_profile | 440 | 754 | FAIL | [9.8359375, 10.0322265625, 10.6357421875] |

## Static comparison

| Config | Suite | Completed comparisons | Worst position (pt) | Worst ΔE00 |
|---|---|---:|---:|---:|
| Debug | window | 2/2 (one run failed before comparison) | 1.0 | 1.61 |
| Debug | sidebar | 3/3 | 1.0 | 1.61 |
| Release | window | 3/3 | 1.0 | 1.61 |
| Release | sidebar | 3/3 | 1.0 | 1.61 |

## Rule 10 / render checks

Merged main through `b5f3034`; normal merge, no rebase or force-push. Full verify-all:

| Check | Result | Seconds |
|---|---|---:|
| build | PASS | 91 |
| commands-demo | PASS | 2 |
| roundtrip | PASS | 0 |
| suggest-check | PASS | 14 |
| commands-dump | PASS | 0 |
| route | PASS | 3 |
| favicons | PASS | 1 |
| media-demo | PASS | 1 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 0 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 3 |
| settings-preview | PASS | 85 |
| sidebar-render | PASS | 22 |
| commandbar-render | PASS | 19 |
| features-render | PASS | 10 |
| boosts | PASS | 3 |

`features-render check`: 151/151 PASS. `sidebar-render check`: 147/147 PASS. Debug and Release automation builds PASS. No unit tests or desktop input. Screenshots contain only Open windows; reference data and pixels remain private in .re.
