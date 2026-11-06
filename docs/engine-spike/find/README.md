# Find in page verification

Spec: Section 11 lead design, 2026-11-05; static facts are in
`docs/re/page-chrome.md` §1 on `origin/s11/re-page-chrome`. The new UI uses
Open-owned AppKit code and SF Symbols. It includes no reference assets.

Implementation: `App/PageChrome/FindBarView.swift` and `FindController.swift`.
The factory forwards lifecycle, menu, result, layout, and focus events.
Section 9 hook: `PeekController.onPageEscape` lets Find consume Esc before
Peek's existing key monitor dismisses Peek. No engine source or distribution
changes are part of this change.

Debug build passed on the main engine distribution, SHA-256
`f34400e71412d87a0b268fcd5658a8563cca34f600c8dd17b534a63e76aa7939`.
No new Find warnings were emitted. The first on-screen run was
**INTERRUPTED** by SecurityAgent and does not count. The lead lifted that
hold at 14:30. No debugger or authorization workaround was attempted.

The draft is **not accepted**. Current evidence before the final-head run:

| Required evidence | State |
|---|---|
| Find flow, per-pane/tab/Peek state, selection, menu actions | Closed-bar next/previous checks passed (4/5 then 3/5); the native close click is blocked by the legacy root extensions overlay; fix pending validation |
| Own-window light/dark ΔE00 ≤ 2, corner pixels, frame checks | 2x WindowServer edge samples ΔE00 0; stronger blank-middle samples FAIL at 3.95 light / 5.43 dark because of that overlay |
| Cmd+F within one 120 Hz frame | FAIL: Debug 8.735 ms at load 8.22; earlier Release 29.141 ms at load 73.81; deadline 8.333 ms; no current speed acceptance |
| Coalescing and idle work | Earlier full flow passed: one typed request and at most one engine activation; all ten idle observer counters zero over two seconds |
| Negative proof for every new gate; forced early-Peek-failure cleanup | Pending |
| e2e features, shell, window, commandbar, page | Pending |

Receipts stay under `.re/find/` in the implementation checkout. The raw
interrupted JSON is `find-interrupted-securityagent.json`; the full initial
log is `find-first.log`. The harness also writes its ordinary
`docs/engine-spike/results-find-debug.json` receipt (not committed).

## Capture requests for the user

The user must operate Arc. See page-chrome §7, “Find appearance” and “Find
state/focus”: light/dark, toolbar off/on, narrow panes, empty/`1/5`/Not Found,
a sharp 2x still and show/hide video; per-tab query/open lifetime, close and
reopen, navigation/reload, both Split View panes, focus after Esc/close,
Return/Shift+Return/Cmd+G/Cmd+Shift+G, and selected-text seed. Use a synthetic
page and include the page top, sidebar/toolbar, and AX snapshot if possible.

The lead's unconfirmed choices are per-tab in-memory state; keeping the match
on close; closed-bar Cmd+G reopening; and Find and Replace opening Find.
The monitor-away display rerun must include this PR's own-window color/radius
rows and the known built-in-display baseline rows from TANDEM-RULES §4.


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
