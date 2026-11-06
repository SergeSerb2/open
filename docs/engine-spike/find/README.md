# Find in page verification

Spec: Section 11 lead design, 2026-11-05; static facts are in
`docs/re/page-chrome.md` §1 on `origin/s11/re-page-chrome`. The new UI uses
Open-owned AppKit code and SF Symbols. It includes no reference assets.

Implementation: `App/PageChrome/FindBarView.swift` and `FindController.swift`.
The factory forwards lifecycle, menu, result, layout, and focus events.
Section 9 hook: `PeekController.onPageEscape` lets Find consume Esc before
Peek's existing key monitor dismisses Peek. No engine source or distribution
changes are part of this change.

Debug and automation Release builds use the main engine distribution, SHA-256
`f34400e71412d87a0b268fcd5658a8563cca34f600c8dd17b534a63e76aa7939`.
No new Find warnings were emitted. SecurityAgent and foreground-loss
**INTERRUPTED** attempts do not count. No debugger or authorization workaround
was attempted.

Final verification after the latest main merge is in progress. The initial
step-4 Release run passes all 50 Find checks. Interrupted attempts do not count.

| Required evidence | State |
|---|---|
| Real-App behavior and native hit testing | 50/50 in the initial step-4 run: native field keys, page shortcuts, close click/focus, selection boundaries, tab state, navigation/reload, Split View and Peek |
| Own-window light/dark pixels | WindowServer snapshots: background ΔE00 0.4977 light / 0.3836 dark (limit 2); radius, 300×32 frame, right 10, top 10/50 and narrow-pane checks pass |
| First and repeat Cmd+F | Both p95 values pass the fixed 120 Hz budget in the initial step-4 run; final-head run pending |
| Coalescing and idle work | One typed request, at most one engine activation, and all ten Find-scoped observer counters zero over two seconds with Find open and the page focused |
| Negative proof | Fifty original gates rejected across the fault-App and strengthened Jump receipts; twenty-sample 25 ms fault rejects first/repeat p95 at 33.828/28.147 ms; retained-control fault rejects the lifetime condition with all idle counters zero |
| Required regressions and full verify-all | Final-head runs pending |

## Performance measurements

The gate is **p95 ≤ 8.333 ms for both first and repeat opens**, nearest rank,
with twenty fresh App windows per mode. Medians are information only. The
240 Hz display interval (4.167 ms) is also information only. Measurement runs
take the quiet lock first, wait for low load holding only that lock, then take
the screen lock. The measured interval is the native Cmd+F event timestamp to
the flushed visible layer; field focus also finishes in the same action.

The rounded shadow path already existed in the baseline and is updated during
layout before attachment. Fonts (13 pt query, 12 pt small caps), four sized SF
Symbols and colors are now static process resources. The existing confirmed
first-paint hook queues one process-wide offscreen bar/editor warm-up on the
next main turn. It adds no timer, polling or recurring task. Open drops the
temporary references inside an autorelease pool. AppKit can defer native
editor teardown to its next event-loop drain; a separate real-App probe found
both controls released within 0.5 seconds without opening Find. The idle gate
requires one warm-up run and no retained temporary controls after settling.

Step 4 gives the background a direct layer update and each native control its
own backing layer. No layer mask clips the rounded bar. The shadow color,
opacity, radius and offset are unchanged. The small-caps font descriptor is
built once, and native image caches are primed after paint.

Values below are p50 / p95 milliseconds. Step 2 and step 3 alternate in the
same forty-window session with an automation-only prewarm-disable flag.

| Step | First open | Repeat open | Load1 range |
|---|---|---|---|
| Shadow-path baseline | 9.901 / 11.395 | 1.056 / 1.360 | 9.87–10.99 |
| Shared cache; prewarm disabled | 10.561 / 14.050 | 1.158 / 1.654 | 10.30–15.17 |
| Shared cache + post-paint prewarm | 7.101 / 9.148 | 1.168 / 1.774 | 10.30–15.17 |
| Native backing layers + prewarm | 4.130 / 5.589 | 0.840 / 1.593 | 8.15–9.27 |

First-open phase breakdown (p50 / p95 ms):

| Step | Create | Attach | Draw | Flush | Focus (after commit) |
|---|---|---|---|---|---|
| Shadow-path baseline | 3.038 / 3.443 | 1.806 / 2.034 | 2.201 / 3.022 | 2.583 / 3.219 | 10.973 / 15.365 |
| Shared cache; prewarm disabled | 3.099 / 4.315 | 1.833 / 2.712 | 2.464 / 3.430 | 2.760 / 3.703 | 11.892 / 15.073 |
| Shared cache + post-paint prewarm | 1.427 / 2.345 | 0.846 / 1.360 | 1.696 / 2.285 | 2.519 / 4.164 | 8.782 / 11.255 |
| Native backing layers + prewarm | 1.036 / 1.878 | 0.638 / 1.049 | 0.462 / 0.801 | 1.629 / 2.514 | 7.225 / 9.652 |

Launch baseline medians were sidebar 379.5 ms / FCP 643 ms. The step-4 paired
run reports prewarm enabled at 346.5 / 614.5 ms and disabled at 347 / 622.5 ms;
these show no launch regression. Every enabled sample starts prewarm after
its measured first paint. The heavier step-3 run reports 383.5 / 697.5 ms
enabled and 392.5 / 709.5 ms disabled as load rises to 15.17; it is not the
quiet-machine launch comparison.

The 25 ms fault reports first p50/p95 31.997/33.828 ms and repeat
27.083/28.147 ms over twenty windows (load1 10.13–11.80). The retained-bar
fault fails only the lifetime condition in the idle row: its ten work counters
remain zero, while the weak temporary-view references remain live. Both fault
conditions fail, the other 48 checks pass, and owned-process cleanup passes.
The script restores exact source hashes and rebuilds Debug and Release.

Receipts: `.re/find/step1-shadow-path-20.json`, `step3-paired-20.json`,
`step4-paired-20.json`, and `phase-comparison.json`. Final receipts stay under
`.re/find/` in the implementation checkout. The suite also writes
`docs/engine-spike/results-find-release.json` (not committed).

Section 6 temporary hook: until its root `extensionBar` is replaced, Find hides
that existing view only while its rectangle intersects a visible Find bar.
It restores the saved visibility on close, tab/layout changes and teardown.
The extensions view is neither moved nor restyled. The close gate uses the
real AppKit hit test and native mouse events, with no forced control action.

## Capture requests for the user

The user must operate Arc. See page-chrome §7, “Find appearance” and “Find
state/focus”: light/dark, toolbar off/on, narrow panes, empty/`1/5`/Not Found,
a sharp 2x still and show/hide video; per-tab query/open lifetime, close and
reopen, navigation/reload, both Split View panes, focus after Esc/close,
Return/Shift+Return/Cmd+G/Cmd+Shift+G, and selected-text seed. Use a synthetic
page and include the page top, sidebar/toolbar, and AX snapshot if possible.

The lead's unconfirmed choices are per-tab in-memory state; keeping the match
on close; closed-bar Cmd+G reopening; and Find and Replace opening Find.
The final display checks run on the main AW2726DM at 1x. The earlier
built-in-display exceptions do not apply.


## Scope and source review

The old App factory implemented Find tags 1/2/3/7; it did not implement
`performTextFinderAction:` or `centerSelectionInVisibleArea:`. The native
menu registry maps Find and Replace and Jump to Selection to those selectors
(`MenuBuilder.swift`, `SystemCommandActions`). The design's fallback is
implemented: Find and Replace opens Find, and Jump to Selection scrolls
the current selection. Real menu and keyboard checks passed in the earlier
full flow. The existing `evaluateJavaScript` path runs in the page's main
world, so page script can affect these selection operations. This PR adds
no isolated-world engine API.

The query is capped at 1,000 UTF-8 bytes by Unicode scalar before each engine
request. The page-selection bridge normalizes and counts grapheme clusters in the
renderer for opening Find, then slices to 4,001 UTF-16 code units before
returning to Swift (at most 16,004 UTF-8 bytes). Cmd+E preserves raw selected
text, uses the same query cap, and searches without opening the bar. Async reads check page identity, tab identity, query
revision, dismissal/navigation state, and shutdown before applying results.
Find uses no timers, polling, display links, disk I/O, or pre-paint work. The
one queued edit is flushed by Return/Next and discarded on close.

Additional routing hook: `BrowserWindowController.shouldDeferKeyToFirstResponder`
keeps Return, Shift+Return, Up, Down, and Esc with the native Find field editor.
It preserves ownership if AppKit re-offers the same event after dismissal.
This follows the old checkpoint's `f973aca6` lesson. The dedicated editor
follows `f08025f2`; page identity/teardown follows `db56a120`.
