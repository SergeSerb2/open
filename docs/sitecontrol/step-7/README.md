# Boost code mode (package)

Step 7 adds a native, always-light code editor to `OpenSiteControl`. The App host
and real-page B5 flow are separate work. The package adds the host requirement
`loadedJS(boostID:tabID:)`, plus `BoostEditorController.boundPageDidCommit(tabID:)`.
The App must report the JS used by the bound document and call the commit hook
after a bound-tab commit. A reload request does not itself mark the document clean.

CSS edits save after 150 ms and refresh the Profile. JS edits save after 500 ms
without a live refresh. Focus loss, Back, close, and Refresh to Run flush pending
text. Each language keeps its own native text undo stack. Code edits count as a
change when deciding whether to delete an untouched new Boost.

The panel grows left to 480 by 588 points. Back restores the simple size. Left
and bottom tracking strips save the final size as `open.boosts.codeEditorSize`;
the minimum is 360 by 420. The existing screen margin still clamps the frame.
The first JS notice uses `open.boosts.hasDismissedJSNotice`. Pick Selector stays
disabled until Step 8. Developer Tools uses the host's existing visibility hook.

## Verification procedure

Build with `heavy.sh swift build --package-path Packages/OpenKit --product
sitecontrol-render -c release -j 6`. Run `code-flows`, `native-key-check`, and
`compare --state editor-code-css` under the on-screen lock. `check` includes
F17/F18, both new scenes at 1x/2x, and the code keystroke gate. The full verifier
owns its existing on-screen wrapper; do not wrap the whole verifier in that lock.

`code-bench` loads a 2,000-line synthetic CSS document into the real text view,
discards ten native key events, and measures 100 more through `NSApp.sendEvent`.
The gate requires main-thread CPU p95 below 2 ms. It also requires incremental
highlighting to touch fewer than 2,000 characters per key. The document has about
81,000 characters. CPU p95 and all three load averages are printed. This uses
the existing in-process CPU timing method; no new instruction baseline is added.
A dedicated timing run takes the quiet lock before the on-screen lock.

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

Final receipts and negative proofs are recorded below after the final gate.
