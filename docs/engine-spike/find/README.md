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

The draft is **not accepted**. Current evidence before the final-head run:

| Required evidence | State |
|---|---|
| Real-App behavior and native hit testing | 49/50 Release checks pass after merging main through #176; native field keys, page Cmd+G, close click, selection boundaries, tab memory, document navigation/reload, Split View and Peek pass |
| Own-window light/dark pixels | WindowServer snapshots pass: blank-middle background ΔE00 0.4977 light / 0.3836 dark, limit 2; radius, 300×32 frame, right 10, top 10/50 and narrow-pane checks pass |
| First Cmd+F within one frame | FAIL: 7.3319 ms at load 8.85/10.28/12.05, against 4.1667 ms on AW2726DM, 1x, maximum 240 Hz; it is within the 120 Hz reference interval of 8.3333 ms |
| Coalescing and idle work | PASS: one typed request and at most one engine activation; all ten Find-scoped idle observer counters zero over two seconds with the bar open and page focused |
| Negative proof for every new gate; forced early-Peek-failure cleanup | Pending; interrupted negative attempts are excluded |
| e2e features, shell, window, commandbar, page; full verify-all | features 19/19 PASS; remaining final-head runs pending |

The complete normal receipt is `.re/find/find-batched-quiet.json`, with
load and phase timings in `.re/find/find-batched-quiet.log`. Earlier receipts
precede the root extensions collision fix and are not current acceptance.
Receipts stay under `.re/find/` in the implementation checkout. The harness
also writes `docs/engine-spike/results-find-release.json` (not committed).

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
Find uses no timers, polling, display links, disk I/O, or launch work. The
one queued edit is flushed by Return/Next and discarded on close.

Additional routing hook: `BrowserWindowController.shouldDeferKeyToFirstResponder`
keeps Return, Shift+Return, Up, Down, and Esc with the native Find field editor.
It preserves ownership if AppKit re-offers the same event after dismissal.
This follows the old checkpoint's `f973aca6` lesson. The dedicated editor
follows `f08025f2`; page identity/teardown follows `db56a120`.
