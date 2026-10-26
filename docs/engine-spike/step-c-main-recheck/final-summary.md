# Repeated main-merge verification

Source: `6e9d1a4`; default **fork**, production **Chrome** hosting. Both builds embed `4C4C4432-5555-3144-A144-B678285BC5F4` (distribution stamp suffix `1793036548`). Each cell links its full receipt. Interrupted attempts are separate from accepted passes.

| Config | Suite | Run 1 | Run 2 | Run 3 |
|---|---|---|---|---|
| Debug | window | [46/46 PASS](debug-window-1.json) | [46/46 PASS](debug-window-2.json) | [46/46 PASS](debug-window-3.json) |
| Debug | sidebar | [18/18 PASS](debug-sidebar-1.json) | [18/18 PASS](debug-sidebar-2.json) | [18/18 PASS](debug-sidebar-3.json) |
| Debug | shell | [6/6 PASS](debug-shell-1.json) | [6/6 PASS](debug-shell-2.json) | [6/6 PASS](debug-shell-3.json) |
| Debug | features | [19/19 PASS](debug-features-1.json) | [19/19 PASS](debug-features-2.json) | [19/19 PASS](debug-features-3.json) |
| Debug | actions | [45/45 PASS](debug-actions-1.json) | [45/45 PASS](debug-actions-2.json) | [45/45 PASS](debug-actions-3.json) |
| Release | window | [46 PASS / 2 FAIL](release-window-1.json) | [46 PASS / 2 FAIL](release-window-2.json) | [46 PASS / 2 FAIL](release-window-3.json) |
| Release | sidebar | [18/18 PASS](release-sidebar-1.json) | [18/18 PASS](release-sidebar-2.json) | [18/18 PASS](release-sidebar-3.json) |
| Release | shell | [5 PASS / 1 FAIL](release-shell-1.json) | [6/6 PASS](release-shell-2.json) | [6/6 PASS](release-shell-3.json) |
| Release | features | [19/19 PASS](release-features-1.json) | [19/19 PASS](release-features-2.json) | [19/19 PASS](release-features-3.json) |
| Release | actions | [45/45 PASS](release-actions-1.json) | [45/45 PASS](release-actions-2.json) | [45/45 PASS](release-actions-3.json) |

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
| release-shell-1 | suite |

## Confirmed engine startup failure

Release shell repetition 1 passed five checks, then its persistence relaunch
aborted before automation. The launch log contains a fatal
`allocator_shim_apple.cc(61): No zone found` check, with CEF,
CoreFoundation and RunningBoardServices frames. This remains **FAIL**, not
INTERRUPTED or a timing load exception. See the [stack](engine-startup-crash.txt)
and [provenance](engine-startup-crash.json). Why the pointer lacked a malloc zone
is unconfirmed; the engine lead owns that investigation (docs/followups.md).
Later passing shell runs do not clear this failure.

## Readiness controls and prior failures

All six final window runs pass `launch_waiter_early_exit`: a real non-blocking
LaunchServices launch ends before the three-second first-frame-timeout fixture
starts its engine, then the actual socket PID and page become ready. The old
launcher-waiter failure remains in `post-8f3379a-before-launch-waiter-fix/`.
The harness keeps the same 60-second readiness deadline and never relaunches a
failed app as an assertion retry.

The separate native-focus negative control forced three owned-peer handoffs.
All three native attempts were INTERRUPTED (expected exit 2); none contributes an
accepted keyboard pass. See [the control summary](native-focus-negative-control-summary.json).
The ordinary final matrix above has zero interrupted attempts.

An earlier Release actions readiness failure remains unconfirmed in
[post-a962f39](post-a962f39/focus-readiness-unresolved.json). Its error reported
active=true and matching target/key numbers, but omitted target.isKeyWindow.
Eighty separate real-app diagnostic cycles did not reproduce it. Current native
errors capture the actual predicate values, key identity and foreground metadata;
conditions and deadlines are unchanged. All six current actions runs pass, but
that does not establish the historical failure's cause. The lead's exclusive
focus-dependent verification remains required before merge.

## Command-bar result timing (ms)

The first measurement includes construction. Repeat measurements use the same real bar. The 50 ms assertions remain unchanged.

| Config | Repeat | First open | First query phase | Repeat open | Budget |
|---|---:|---:|---:|---:|---|
| Debug | 1 | 23.33 | 19.47 | 21.73 | PASS |
| Debug | 2 | 37.54 | 34.04 | 12.15 | PASS |
| Debug | 3 | 42.46 | 37.87 | 31.42 | PASS |
| Release | 1 | 27.44 | 22.52 | 43.31 | PASS |
| Release | 2 | 22.09 | 18.39 | 18.88 | PASS |
| Release | 3 | 34.33 | 30.82 | 11.34 | PASS |

## Release launch medians (ms)

Each row has five launches. Every attempted workflow that reached timing evaluation is shown, including interrupted workflows; no timing miss is discarded. Budgets remain sidebar ≤250 ms / first contentful paint ≤700 ms. Misses under concurrent machine load remain recorded load exceptions, not passes. Step I must repeat on an idle machine.

| Repeat / attempt | Profile | Sidebar | First contentful paint | Budget | Load average at start |
|---|---|---:|---:|---|---|
| 1 / 1 | cold_fresh_profile | 379 | 643 | FAIL | [46.03, 45.88, 31.9] |
| 1 / 1 | warm_existing_profile | 404 | 675 | FAIL | [46.03, 45.88, 31.9] |
| 2 / 1 | cold_fresh_profile | 380 | 656 | FAIL | [10.75, 26.73, 26.73] |
| 2 / 1 | warm_existing_profile | 386 | 649 | FAIL | [10.75, 26.73, 26.73] |
| 3 / 1 | cold_fresh_profile | 322 | 547 | FAIL | [13.08, 21.12, 24.4] |
| 3 / 1 | warm_existing_profile | 313 | 540 | FAIL | [13.08, 21.12, 24.4] |

## Static comparison

| Config | Suite | Completed comparisons | Worst position (pt) | Worst ΔE00 |
|---|---|---:|---:|---:|
| Debug | window | 3/3 | 1.0 | 1.61 |
| Debug | sidebar | 3/3 | 1.0 | 1.61 |
| Release | window | 3/3 | 1.0 | 1.61 |
| Release | sidebar | 3/3 | 1.0 | 1.61 |

## Rule 10 / render checks

Merged main through `8f3379a`; normal merge, no rebase or force-push. Both app builds and the full verifier use the machine-wide heavy.sh slot wrapper. App binaries were built at 4a6fe77; every tracked App/Engine/Packages/build input is identical at harness revision 6e9d1a4. The Python launcher fix is exercised by this fresh matrix. Every on-screen invocation uses the separate per-suite lock. Full verify-all:

| Check | Result | Seconds |
|---|---|---:|
| build | PASS | 2 |
| commands-demo | PASS | 2 |
| roundtrip | PASS | 0 |
| space-legacy | PASS | 1 |
| suggest-check | PASS | 20 |
| commands-dump | PASS | 0 |
| route | PASS | 2 |
| favicons | PASS | 2 |
| media-demo | PASS | 0 |
| sleep-demo | PASS | 2 |
| adblock-perf | PASS | 1 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 2 |
| settings-preview | PASS | 78 |
| sidebar-render | PASS | 58 |
| sidebar-compare | PASS | 110 |
| commandbar-render | PASS | 16 |
| features-render | PASS | 25 |
| boosts | PASS | 3 |

`features-render check`: 258/258 PASS. `sidebar-render check`: 429/429 PASS. Debug and Release automation builds PASS. No unit tests or desktop input. Screenshots contain only Open windows; reference data and pixels remain private in .re.
