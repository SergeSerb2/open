# Review checklist

Reviewers use this list. Implementers run it on their own change **before** they open the PR, and put the result in the PR body as a table: item, PASS or N/A, and the evidence (a command, a log line, or a file:line). The items come from real defects that reviews found in Open PRs (round 2 and round 3 findings, 2026-10-25 and 2026-10-26).

A PR gets at most two review rounds. After round 2, the lead fixes or verifies any small leftover finding, or files it in `docs/followups.md`. A third round happens only for a new crash, data-loss, or security finding.

## 1. Input and memory limits

- [ ] Every size, count, depth, and length that comes from outside the process (files, lists, network, extension or page data) has a hard limit, and the code refuses input over the limit with a clear failure. Bound the decoded result, not only the raw bytes: one input byte can become a 24-byte object.
- [ ] The worst allowed input stays under every allocator ceiling (PartitionAlloc refuses one request over 2^31 − 2 MiB and aborts). State the measured worst single allocation in a comment.
- [ ] A test input just over each limit is refused, and one at the limit is accepted (boundary cases in the self-test or harness).
- [ ] Trailing or unknown data after a parsed value is refused, not ignored.

## 2. Lifetimes and callbacks

- [ ] A delegate callback can close, free, or replace the object that called it. Defer that work to the next run-loop turn, or prove it is safe. Document the rule in the delegate header.
- [ ] Every object freed on close is freed once. Close, then close again, then close during an animation: no double delete, no use after free.
- [ ] IDs (menu items, popups, requests) stay unique for the life of the process. An ID from an older generation (for example, before the hidden Browser came back) is refused.
- [ ] State the shell holds back (pending tab-switch sync, debounced saves) is flushed before an action that depends on it runs.

## 3. Real event paths

- [ ] Keys go through the real path: `OEApplication.sendEvent` → key routers → menus. A check that injects a key at a later layer (for example `route="window"`) does not prove the real key works. Check Cmd+W, Cmd+T, Cmd+L, Esc, and Return in every new focus context (popups, panels, sheets, the command bar).
- [ ] After a merge with `main`, re-check who owns each key and focus path. Two PRs that each handle the same key must not both act.
- [ ] Flags that hide an item (for example `visible: false`) hide it everywhere, and the item cannot run.

## 4. Checks that prove the change

- [ ] Each new check fails on the old code. Show it: break the fix (or run on the parent commit), record the FAIL line, and restore (break-and-revert proof).
- [ ] Image checks compare pixels (or a perceptual difference with a stated limit), not file sizes or PNG lengths.
- [ ] A check that says "dialog X appears" checks for that specific window, not any window.
- [ ] Timing checks assert the configured delay or deadline (the scheduled value), not the wall clock. At most one real-time check per behavior, with up to 3 attempts, and it prints the lateness and the load average. Never widen a logic tolerance to make a check pass.
- [ ] Each run uses its own data root, cache, profile, preferences domain, and port (`mktemp -d`, an ephemeral port). Two runs at the same time both pass.

## 5. UI and motion

- [ ] Reduce Motion has its own path (no slide, no spring), and it does not fade in from 0 on every hover.
- [ ] An interrupted animation starts from the presentation layer, not from the model value (no snap).
- [ ] Width changes, sidebar hide, and window resize do not animate content that should only move with the frame.
- [ ] Real-window `snapshot` PNGs at rest and hovered are compared with the Arc capture (offscreen renders alone are not enough).

## 6. Docs and comments

- [ ] Comments and docs state what the code does now. Numbers in comments (byte counts, limits, sizes) match the code.
- [ ] The plan, `docs/followups.md`, and the PR body agree on what is done and what is left.
