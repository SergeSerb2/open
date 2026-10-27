# Step C code review round 1 verification

Main merged through `931a777`. Both app builds and the real on-screen workflows
use app source `8e345dc`; window/actions harness `5d57c96`, shell harness `8a71e1b` (completed-shutdown observation and quit diagnostics only). All app/package/build inputs are identical at those harness revisions. Default fork / Chrome hosting, embedded and distribution
UUID `4C4C4432-5555-3144-A144-B678285BC5F4`, stamp suffix `1793036548`. Builds and the full verifier use heavy.sh;
each on-screen invocation holds lockf for that suite only. All commands finished.

| Finding | Root cause | Fix and evidence |
|---|---|---|
| F1 | Async focus restore ignored current responder and app activation; dismissal and Save callbacks could also reclaim focus. | One guard requires active Open, key window, same selected page, no bar/sheet, and page/window first responder. Sidebar, Find and inactive-load/dismiss regressions pass; old red observations are in focus-red-baseline.json. |
| F2 | Internal bar timing excluded preceding key/socket/frame work; interruption checks only had native-input bounds. | The exact internal scope is labeled in every 50 ms row and bar state. All timed poll/capture intervals have native trace bounds. Three real socket-only controls with zero key input must store INTERRUPTED, never PASS. |
| F3 | Rename used runModal on the CEF main loop. | Existing inline sidebar editor; async sheet only for a pane with no row. Actual commit/cancel and a live page timer are checked. |
| F4 | Unowned Save/background tasks and live hosts could outlast engine shutdown. | Owned cancellable tasks, readiness fences, and host close before shutdown. The real quit flow requires queued Save/background work at prepare and zero owned work/hosts at the actual shutdown boundary. |

## Affected suites

| Config | Suite | PASS | FAIL | INTERRUPTED attempts | Named non-pass rows |
|---|---|---:|---|---:|---|
| Debug | [actions](debug-actions.json) | 47 | 0 | 0 | — |
| Debug | [shell](debug-shell.json) | 7 | 0 | 0 | — |
| Debug | [window](debug-window.json) | 53 | 0 | 0 | cold_fresh_profile: SKIP, warm_existing_profile: SKIP |
| Release | [actions](release-actions.json) | 47 | 0 | 0 | — |
| Release | [shell](release-shell.json) | 7 | 0 | 0 | — |
| Release | [window](release-window.json) | 53 | cold_fresh_profile, warm_existing_profile | 0 | — |

All ordinary failures and interrupted attempts remain in their receipts. Release
launch-budget misses under load remain FAIL load exceptions for Step I idle
measurement. Debug timing rows remain named SKIP. Expected negative-control
interruptions are separate from accepted functional results.

## Command-bar internal timing

Scope: showCommandBar entry to first snapshot applied. Preceding key routing,
socket transport and frame presentation are excluded. This is not end-to-end
key-to-visible latency. First open includes construction; limit stays 50 ms.

| Config | First open (ms) | Repeat open (ms) | Outcome |
|---|---:|---:|---|
| Debug | 32.50 | 13.59 | PASS |
| Release | 32.47 | 10.62 | PASS |

## Release launch medians

Each row uses five real launches. Budgets remain 250 ms / 700 ms.

| Profile | Sidebar (ms) | First paint (ms) | Result | Load average |
|---|---:|---:|---|---|
| cold_fresh_profile | 307 | 526 | FAIL load exception | [11.14, 12.07, 16.28] |
| warm_existing_profile | 264 | 474 | FAIL load exception | [11.14, 12.07, 16.28] |

## Live static comparison

| Config | Worst position (pt) | Worst delta E00 | Result |
|---|---:|---:|---|
| Debug | 1.0 | 1.55 | PASS |
| Release | 1.0 | 1.55 | PASS |

## Full verifier

| Check | Result | Seconds |
|---|---|---:|
| build | PASS | 61 |
| commands-demo | PASS | 2 |
| roundtrip | PASS | 0 |
| space-legacy | PASS | 1 |
| space-editor | PASS | 3 |
| suggest-check | PASS | 12 |
| commands-dump | PASS | 0 |
| route | PASS | 2 |
| favicons | PASS | 2 |
| media-demo | PASS | 0 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 0 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 2 |
| settings-preview | PASS | 83 |
| sidebar-render | PASS | 57 |
| sidebar-compare | PASS | 116 |
| commandbar-render | PASS | 14 |
| features-render | PASS | 26 |
| boosts | PASS | 3 |

The verifier includes sidebar-render 429/429, commandbar-render 78/78 and
features-render 258/258. No unit tests or desktop input.

## Retained failed attempts and prior acceptance

The initial merge's duplicate appActive dictionary key caused a Swift trap in
window-state. Those six ordinary FAIL attempts remain in
[pre-window-state-merge-fix](pre-window-state-merge-fix/README.md). The Save harness bring-up failures remain in [pre-native-save-route](pre-native-save-route/README.md), [pre-presenter-reply](pre-presenter-reply/README.md), and [pre-sheet-cancel-method](pre-sheet-cancel-method/README.md).
NSSavePanel.ok throws here, and in-process native confirmation did not start
capture within the deadline. Those controls remain in pre-presenter-reply. The
final harness replies to the actual pending Save presenter through the socket
and runs its same production capture completion, with the real engine and file
write. The remote system Save/Cancel buttons and their key delivery remain unverified. The final cancel uses AppKit endSheet and asserts that the pending sheet cleared. A separate Save action establishes its own
browser key context after Cancel. The Release shutdown-record observation failure is retained in [pre-shutdown-record-wait](pre-shutdown-record-wait/README.md). The final check waits for engineShutdownEnd and rejects forced cleanup; both exact-executable observations match and every original ordering assertion remains. No product check or deadline was weakened.

The lead accepted the previous three Debug and three Release locked matrix with
zero foreground interruptions as the required focus acceptance. No additional
exclusive lead run is pending. The historical allocator startup crash remains
FAIL, has no Open frames, is not attributed to this PR, and is nonblocking per
the lead. It is owned by the
[separate allocator debug task](t3-thread://v1/thread:delegated-task:command%3Amcp%3A113d67cd-becd-4e78-a257-e72ea2a8568f%3Adelegate-task%3Adebug-1027-release-relaunch-zone-crash-v1).
The earlier rare native-readiness failure remains unconfirmed after 80 controls;
passing later runs do not establish its cause. Historical tables and raw receipts
remain in step-c-main-recheck. Scope is unchanged; nonblocking review nits F5–F7
remain follow-ups except cancelled-menu-task cleanup, which is covered by F4.
