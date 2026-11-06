# Boost code mode (package)

Step 7 adds a native, always-light code editor to `OpenSiteControl`. The App host
and real-page B5 flow are separate work. The package adds the host requirement
`loadedJS(boostID:tabID:)`, plus `BoostEditorController.boundPageDidCommit(tabID:)`.
The App must report the JS used by the bound document and call the commit hook
after a bound-tab commit. A reload request does not itself mark the document clean.

CSS edits save after 150 ms and refresh the Profile. JS edits save after 500 ms
without a live refresh. Focus loss, Back, close, and Refresh to Run flush pending
text. Each language keeps its own native text undo stack; focus loss records one
whole-Boost checkpoint for the simple editor Undo button (§4.9). Code edits count as a
change when deciding whether to delete an untouched new Boost.

The panel grows left to 480 by 588 points. Back restores the simple size. Left
and bottom tracking strips save the final size as `open.boosts.codeEditorSize`;
the minimum is 360 by 420. The existing screen margin still clamps the frame.
The first JS notice uses `open.boosts.hasDismissedJSNotice`. Per the lead’s
2026-11-06 ruling, it is 28 pt tall with #F2F2F4 fill and a one-physical-pixel
black 0.08 top hairline. Its 11 pt Regular black 0.60 label uses a 12 pt leading
inset, one line and tail truncation. The `xmark` is 9 pt Semibold, black 0.45,
inside a 20 × 20 pt hit area, centered vertically, 6 pt from the trailing edge,
with AX label “Dismiss”. All values are marked Open choice in the tokens. Pick Selector stays
disabled until Step 8. Developer Tools uses the host's existing visibility hook.

## Verification procedure

Build with `heavy.sh swift build --package-path Packages/OpenKit --product
sitecontrol-render -c release -j 6`. `code-flows` and `compare --state
editor-code-css` use only offscreen windows and an in-scroll-view find bar. Run
`native-key-check` under the on-screen lock. `check` includes
F17/F18, both new scenes at 1x/2x, and the code keystroke gate. The full verifier
owns its existing on-screen wrapper; do not wrap the whole verifier in that lock.

`code-bench` loads a 2,000-line synthetic CSS document into the real text view,
discards ten native key events, and measures 100 more through `NSApp.sendEvent`.
The gate requires main-thread CPU p95 below 2 ms. It also requires incremental
highlighting to touch fewer than 2,000 characters per key. The document has about
81,000 characters. CPU p95 and all three load averages are printed. This uses
the existing in-process CPU timing method; no new instruction baseline is added.
A dedicated offscreen timing run takes the quiet lock. Native timing runs take
the quiet lock before the on-screen lock.

The native focus extension clicks the actual empty code view in a registered
harness app, while its browser parent is key. It checks that the editor becomes
key and that its first responder is the code text view. No desktop input is used.
The harness uses its own preferences domain, data root and windows.

The S2 10/0071 comparison covers the header and bottom bar only. It uses the
existing 1-point ink-box and delta-E 2 limits. The body was an unavailable internal
page in the capture; Open's native editor body is specified by the plan. The Pick
Selector glyph is excluded while disabled. Its button fill is still compared.

The code-header segment fill tokens are measured facts from that private capture:
`Image.open('.re/scb-design/10-0071-code.png').getpixel((193,20))` gives neutral
RGB 200; `(250,13)` gives 228. The Back arrow's opaque core is RGB 38. These
probes use Python PIL; raw captures and comparison images stay in `.re/`.

## Performance diagnosis

The first 2,000-line run measured 13.365 ms p95 at load 22.17/24.65/19.54. Targeted
in-process phase timings showed about 9 ms in the session callback and about
4 ms in highlighting. Repeated full-view refreshes re-compared the entire text,
and the highlighter rewrote attributes for unchanged visible paragraphs. Code
edits now use the native change notification directly, update notice state only
when it changes, and color only edited or uncolored visible paragraphs. A second
full-document equality check was also removed from the keystroke callback.

The first native click check failed because loading an empty text view before
its viewport existed left the document outside the visible clip. Code mode now
establishes the native viewport before its initial caret scroll.

The native focus run passed 11/11 at load1 46.34. The optimized keystroke run
passed at CPU p95 1.139 ms, load 46.34/36.75/27.35, with at most 191 highlighted
characters per key. This is a loaded-machine CPU receipt, not a quiet wall-time
claim. Final-head receipts follow below.

The production break-and-restore run made every new functional/render gate fail:
**0/22 passed**. It broke code sizing, indentation, comments, undo, syntax colors,
substitution flags, configured save delays, live-refresh policy, loaded-JS state,
notice visibility, reload, Developer Tools, disabled picker state, tab switching,
resize persistence/minimum, Escape, and untouched-new-Boost handling. The source
was restored in `finally`. Load was 45.08/47.53/39.24 at build start and
26.56/41.99/37.70 at completion. The final break-and-restore run also breaks
the focus-loss Boost undo checkpoint and rejects all 22 gates; load was
16.17/24.38/30.52 at start and 14.13/16.38/23.85 at completion. The resize
flow includes valid 64-byte and refused 65-byte size preferences, trailing
fields and non-finite numbers. The pre-fix 13.365 ms timing run is the budget
negative proof. The pre-fix native code click failure is the focus negative proof.
The bar comparator rejected the earlier arrow and hammer at unchanged limits;
the final recreated glyphs pass **11/11** (maximum non-text delta-E 1.15).

## Committed scene receipts and full regression

The four `editor-code-*-light@1x/@2x.png` files are synthetic Open renders.
`SHA256SUMS` records their integrity. These are new Step 7 receipts; no Step 4
baseline or comparison threshold was changed. The receipt checker keeps the
simple-editor set in Step 4 and checks the code-editor set here.

After the notice ruling, `code-flows` passes **22/22**, including the notice’s
font, color, single-line truncation, hit area, position and AX label, plus fill
and one-pixel hairline probes at 1x/2x. The scene receipts and SHA checks pass
**146/146**; load was 32.15/18.67/16.98 at entry and 41.64/21.19/17.89 at exit.
Receipt negative proofs reject all four corrupted hashes and a missing manifest
entry, then restore the original manifest; load was 53.33/24.84/19.26 at entry
and 55.95/25.85/19.65 at exit. The initial notice-style assertion compared
sRGB and generic-gray objects for equality; it now checks sRGB components
without changing its numeric limits.

The first full regression on `2e94108e` passed 23 of 24 suites. Site Control
reported 1513/1518: four new code scenes still used the simple editor’s AX
expectation, and the old receipt-set check expected the new scenes in Step 4.
Those five harness failures were corrected by checking native CSS/JS text areas
and using this separate Step 7 receipt set. The native focus check passed 11/11;
code keystroke CPU p95 was 1.748 ms at load 12.39/14.88/16.81, with at most
191 highlighted characters. The full run entered at 17.93/17.15/22.32 and
finished at 12.36/14.83/16.78. This run predates the lead’s JS notice ruling
and is not final acceptance.

The production notice/AX negative run rejects **22/22** code gates, then restores
all source files. It deliberately changes the notice font/fill and code AX labels
in addition to the earlier functional faults. Entry load was 55.95/25.85/19.65;
completion load was 13.50/20.77/23.40. `receipt-check` verifies all committed
manifests offscreen.

The final-head full summary, loads and review checklist are in the linked PR.
