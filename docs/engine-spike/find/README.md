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
No new Find warnings were emitted. The first `--only find --style chrome`
run ended **INTERRUPTED**, three attempts, with owned-process cleanup PASS.
`window-focus` reported `frontmost=SecurityAgent`, `frontmostPID=63922`,
`active=false`, and `targetIsKey=false`. No Find acceptance row ran.
The lead's 2026-11-05 14:26 hold now forbids every on-screen suite until
explicitly lifted. No debugger/authorization workaround was attempted.

The draft is **not accepted**. These gates remain BLOCKED by that hold:

| Required evidence | State |
|---|---|
| Find positive flow, per-pane/tab/Peek state, selection, menu actions | BLOCKED; suite implemented, not accepted |
| Own-window light/dark ΔE00 ≤ 2, corner pixels, frame checks | BLOCKED; gates implemented, no accepted PNG |
| Cmd+F within one 120 Hz frame; coalescing; idle work | BLOCKED; instrumentation/gates implemented, no runtime speed claim |
| Negative proof for every new gate; forced early-Peek-failure cleanup | BLOCKED; break-and-revert plan prepared locally, not run |
| e2e features, shell, window, commandbar, page | BLOCKED; none started after the hold |

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

Native Find and Replace / Jump to Selection behavior on the old App could
not be exercised before the foreground hold. The design's fallback is
implemented: Find and Replace opens Find, and Jump to Selection calls the
existing main-world JavaScript evaluation path. No isolated-world API is
available here, so page script can affect that operation. Their real menu
and shortcut behavior remains an open runtime gate, not an evidence claim.

The query is capped at 1,000 UTF-8 bytes by Unicode scalar before each engine
request. The page-selection bridge slices to 4,001 UTF-16 code units before
returning to Swift (at most 16,004 UTF-8 bytes); the normalized result uses
the same query cap. Async reads check page identity, tab identity, query
revision, dismissal/navigation state, and shutdown before applying results.
Find uses no timers, polling, display links, disk I/O, or launch work. The
one queued edit is flushed by Return/Next and discarded on close.

Additional routing hook: `BrowserWindowController.shouldDeferKeyToFirstResponder`
keeps Return, Shift+Return, Up, Down, and Esc with the native Find field editor.
It preserves ownership if AppKit re-offers the same event after dismissal.
This follows the old checkpoint's `f973aca6` lesson. The dedicated editor
follows `f08025f2`; page identity/teardown follows `db56a120`.
