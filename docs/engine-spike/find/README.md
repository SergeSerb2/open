# Find in page verification

Spec: Section 11 lead design, 2026-11-05; static facts are in
`docs/re/page-chrome.md` §1 on `origin/s11/re-page-chrome`. The new UI uses
Open-owned AppKit code and SF Symbols. It includes no reference assets.

Implementation: `App/PageChrome/FindBarView.swift` and `FindController.swift`.
The factory forwards lifecycle, menu, result, layout, and focus events.
Placement follows the lead ruling at 22:59: always inset 10 pt inside the actual page viewport, converted into the pane/Peek overlay parent. Toolbar height is excluded through that viewport; no fixed toolbar offset is used. Frame/bounds notifications follow live resizes.
Section 9 hook: `PeekController.onPageEscape` lets Find consume Esc before
Peek's existing key monitor dismisses Peek. No engine source or distribution
changes are part of this change.

Final Debug and automation Release builds include main `ffcf4649` (extension windows, omnibox and pin safety; includes Little Open App wiring) and `27be851f` (dialogs/permissions). Engine framework SHA-256:
`3f45b07b885e03b6aecc461c6b6bff7612814a2ad23b6cf37b2b142d828f0738`.
The measured implementation head is `5ba947d15d7f9475b5759093d3420bf20cae4f54`; the final evidence commit changes documentation only. No new Find warnings were emitted. Foreground-loss INTERRUPTED attempts do not count.

The final Release run passes all 58 Find checks. Full verification passes all 24 checks.

| Required evidence | Final result |
|---|---|
| Native behavior and focus | Field/page keys, tab state, navigation, selection boundaries, Split View and Peek pass |
| Viewport and native close clicks | 10 pt top/right inside actual `contentHostView`; 300×32 preferred, left ≥10, narrow panes and live resizes; no intersection with visible pane chrome/toolbar/extension strip; clicks close Find and focus the page |
| Own-window light/dark pixels | Background ΔE00 0.498/0.384 (limit 2), radius and frames pass on AW2726DM, scale 1 |
| First/repeat Cmd+F | First p50/p95 3.374 / 3.832 ms; repeat 0.662 / 0.949 ms; twenty samples each; both p95 values pass 8.333 ms at 120 Hz; load1 6.05–8.22 |
| Idle/lifetime | All ten observer counters zero; one post-paint warm-up; temporary bar/editor released |
| Negative proof | Original fifty-gate fault coverage plus the updated viewport proof: legacy parent-top placement fails all eight new gates and updated F26; 25 ms delay fails both p95 gates; retention fails the lifetime condition |

Final receipts are in `.re/find/final-ffcf4649/`. Every accepted suite cleans up its owned processes.

| Suite | PASS | Other results | Receipt |
|---|---:|---|---|
| find | 58 | None | `find-1.json` |
| features | 19 | None | `features-2.json` |
| shell | 7 | None | `shell-1.json` |
| window | 76 | 2 known-main launch FAIL; 1 existing card-material DEFERRED | `window-1.json` |
| commandbar | 63 | None | `commandbar-1.json` |
| page | 85 | 4 existing BLOCKED; 1 DEFERRED | `page-1.json` |
| page-chrome | 41 | None | `page-chrome-1.json` |

Window cold sidebar/FCP medians: 343/575 ms; warm: 348/585 ms. They meet the lead's known-main exception ≤400/700 ms. The window run records load averages 7.124 / 8.981 / 10.259. Card material remains the existing Part B deferral. Page's blocked checks remain macOS notification delivery, service-worker `clients.openWindow`, the uninstalled Apple French translation model, and incognito capture; smart zoom is deferred.

Full `heavy.sh tools/verify-all.sh --with-arc-data` runs without the quiet lock. Its original table follows; any focused timing rerun is recorded separately.

```text
NAME                   RESULT SECONDS
build                  PASS   37
commands-demo          PASS   1
roundtrip              PASS   1
space-legacy           PASS   0
space-editor           PASS   3
space-pad-compare      PASS   1
suggest-check          PASS   20
commands-dump          PASS   0
route                  PASS   2
favicons               PASS   1
media-demo             PASS   0
sleep-demo             PASS   1
adblock-perf           PASS   0
adblock-catalog        PASS   0
profiles               PASS   0
settings-preview       PASS   84
sidebar-render         PASS   112
sidebar-compare        PASS   88
commandbar-render      PASS   33
features-render        PASS   87
extensions-render      PASS   6
sitecontrol-render     PASS   212
boosts                 PASS   2
import-arc             PASS   1
```

The 480a5237 run was stopped and its owned processes cleaned up when main advanced to Little Open wiring. Earlier, superseded-head receipts remain under `.re/find/final-viewport-27be851f/` and `final-e4d40ce0/`. On the first ffcf4649 features run, audio was not reported audible after the fixed one-second wait; a full unchanged rerun is recorded separately. On the prior head, one commandbar run hit an archive-restore lookup error after an internal foreground retry; its complete unchanged rerun passed 63 checks. These initial failures are retained, not relabelled PASS. The stale full verification was stopped for the main merge and is not counted.

Earlier 7b490905 engine timings are historical and do not qualify this final engine gate.

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

Final mode measurements alternate twenty cache-only and twenty prewarmed launches in one session (load1 6.05–8.22). Values are p50 / p95 ms. The disabled mode is diagnostic; production uses the enabled mode.

| Mode | First open | Repeat open | Launch sidebar / FCP medians |
|---|---|---|---|
| Cache + native layers; prewarm disabled | 5.465 / 5.996 | 0.65 / 0.8 | 324 / 530 ms |
| Cache + native layers + prewarm | 3.374 / 3.832 | 0.662 / 0.949 | 324.5 / 531 ms |

Every enabled warm-up starts after its measured first paint. The matched launch medians show no prewarm regression. The 240 Hz display interval is 4.167 ms for information only.

First-open phases, p50 / p95 ms:

| Mode | Create | Attach | Draw | Flush | Focus after commit |
|---|---|---|---|---|---|
| Disabled | 2.162 / 2.291 | 1.197 / 1.297 | 0.471 / 0.557 | 1.587 / 1.739 | 8.327 / 10.158 |
| Enabled | 0.92 / 1.043 | 0.629 / 0.696 | 0.425 / 0.534 | 1.273 / 1.441 | 8.699 / 9.851 |

The final-engine fault proof on `5ba947d1` reports first p50/p95 30.409/30.61 ms and repeat 27.733/27.857 ms, twenty samples each, load1 4.93–5.26. Legacy parent-top/8 pt placement fails all eight viewport/close/resize gates and updated F26. Retained temporary controls fail the lifetime condition while all ten idle-work counters stay zero. The compound fault produces 43 PASS/15 expected FAIL and clean owned-process shutdown. Exact source hashes are restored and both normal builds pass. The restoration receipt records exact source hashes on this final head. Full receipts: `.re/find/final-ffcf4649/final-negative-*` and `negative.log`.

The following optimization history uses the **old engine `f34400e7`**. It
shows the effect after each requested step; it is not a final-engine baseline.
Values are p50 / p95 ms. Step 2 and step 3 alternate in one forty-window session
with the automation-only prewarm-disable flag.

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

The historical launch baseline medians were sidebar 379.5 ms / FCP 643 ms. The step-4 paired
run reports prewarm enabled at 346.5 / 614.5 ms and disabled at 347 / 622.5 ms;
these show no launch regression. Every enabled sample starts prewarm after
its measured first paint. The heavier step-3 run reports 383.5 / 697.5 ms
enabled and 392.5 / 709.5 ms disabled as load rises to 15.17; it is not the
quiet-machine launch comparison.

The historical 25 ms fault reports first p50/p95 31.997/33.828 ms and repeat
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
The extensions view is neither moved nor restyled. This bridge remains while
main has the legacy root extension bar, per the lead's 23:02 ruling. Whichever
PR merges second (Find or Section 6 app wiring) removes these legacy hooks,
keeps only Find's viewport placement, and reruns the native close-click gates.
The gates use the real AppKit hit test and native mouse events, with no forced
control action. They require the bar and close button to avoid every visible
pane bar, toolbar and extension strip; hidden legacy chrome is reported
explicitly. The 58-check suite covers toolbar off/on, both split panes, a narrow
pane, Peek, and live Split/Peek resizes. The automation reports viewport and
chrome frames independently of the Find frame.

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
returning to Swift (at most 16,004 UTF-8 bytes). The Use Selection to Find menu action preserves raw selected
text, uses the same query cap, and searches without opening the bar. It has no
default shortcut; Cmd+E stays assigned to Open Extensions (`CommandRegistry.swift`,
Find and Extensions entries). Async reads check page identity, tab identity, query
revision, dismissal/navigation state, and shutdown before applying results.
Find uses no timers, polling, display links, disk I/O, or pre-paint work. The
one queued edit is flushed by Return/Next and discarded on close.

Additional routing hook: `BrowserWindowController.shouldDeferKeyToFirstResponder`
keeps Return, Shift+Return, Up, Down, and Esc with the native Find field editor.
It preserves ownership if AppKit re-offers the same event after dismissal.
This follows the old checkpoint's `f973aca6` lesson. The dedicated editor
follows `f08025f2`; page identity/teardown follows `db56a120`.
