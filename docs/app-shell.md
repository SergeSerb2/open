# App shell acceptance

## Step A — window before engine

The original evidence below used **CDN CEF**. Current fork evidence is recorded
in the fork refresh table at the end of this document.

The real `OpenSidebar.SidebarView` draws from the snapshot before Chromium
starts. The theme field is prepared before display. After the window transaction
is flushed, a display-link callback must report a screen refresh later than
submission. Only then is `sidebarDrawn` marked. A three-second timeout continues
startup with `firstFrameConfirmed=false` and `firstFrameWaitTimedOut`, without
a `sidebarDrawn` mark. Off-screen, sleeping or locked displays must not prevent
launch. The temporary AppKit runloop
returns before `OEEngine.start`, so Chromium's observers first run in its own
message loop. The same sidebar remains attached after engine readiness.

Only selected restored tabs create web content. Launch URLs enter the model
before window composition. Background rows, including never-loaded pinned rows,
stay lazy. Close and unload act on the requested ID without selecting it; only
closing the selected row changes selection. Pinned entries remain in the model.
Today entries use `model.closeTab` and the archive sink.

### Review fixes

- Quit through `OEApplication.terminate` during the first-frame wait flushes the
  snapshot and exits 0 before engine startup. `OEEngine.terminate` null-guards
  its client. That guard is the lead-approved minimal Engine/ exception.
- Engine startup errors show an `NSAlert` with a plain message and a Quit button
  before exit 1. The real missing-library failure is exercised end to end.
- A forced missing-display-link launch waits for the real three-second timer,
  starts the engine, and shows the requested page. The first-frame wait is a
  timing aid; only a termination request prevents engine startup on that path.
- Address entry before readiness queues the URL in the model; direct page and
  context creation paths enforce readiness. Only the selected queued URL loads.
- All launch marks use `mach_continuous_time`. The kernel process-start ticks
  (`ri_proc_start_abstime`) are translated once to that clock. Renderer paint
  timing uses `performance.now()` / paint start time, mapped to host monotonic
  uptime at the CDP round-trip midpoint; the report includes its uncertainty.
  No wall-clock time participates in launch-duration calculations.

### Release timing after review

Command: `python3 tools/e2e/engine_e2e.py --config Release --only window`.
Build: `OPEN_AUTOMATION=1 nice -n 10 tools/build.sh Release`.
CEF 156.0.14, Chromium 156.0.8078.48, arm64, macOS 27.2, Apple M5 Pro.
Local visible HTML in a data URL removes external-network variance.
All values are ms from kernel process start, with the presented-frame mark.

| Case | Sidebar median (≤250) | First paint median (≤700) | Slowest first paint | Verdict |
|---|---:|---:|---:|---|
| Fresh profile (5 launches) | 224 | 461 | 1798 | PASS |
| Warm relaunch (5 launches) | 242 | 452 | 485 | PASS |

Fresh means a new data root/profile, with OS caches left intact. Warm means a
new process restoring the same profile and two-row snapshot. All 10 runs have a
kernel process-start timestamp. The paint-clock uncertainty is at most 0.11 ms
in the ten benchmark launches. The first fresh launch took 1,798 ms to first paint; it remains in
the five-sample median. The plan's intermediate `main` and `modelLoaded` targets
are still missed (113/135 ms and 115/137 ms respectively).

This was a loaded host (load averages 6.61/7.14/7.54), not a controlled idle
benchmark. An earlier review build measured 269/270 ms to the presented sidebar
and 482/476 ms to paint; its sidebar budget misses are retained in
[results-window-release-review-load.json](engine-spike/results-window-release-review-load.json).
The original pre-presentation, wall-clock numbers are superseded by this table;
[results-window-release-build-load.json](engine-spike/results-window-release-build-load.json)
is historical evidence only.

Current raw samples, host counters, and lifecycle results:
[results-window-release.json](engine-spike/results-window-step-a-cdn-release.json).
Open's own window: [window-startup.png](engine-spike/window-startup.png).

Merged `origin/main` through M4 visual finish `39fb0ed` before final builds,
startup/shell checks and repository verification.

### End-to-end checks

| Check | Result |
|---|---|
| Presented real sidebar before engine; zero pages and contexts | 5/5 PASS |
| Relaunch restores two rows and loads only the selected page | 5/5 PASS |
| Fresh/warm timing medians | 2/2 PASS |
| Never-loaded pinned close and unload: cumulative host count unchanged | PASS (1 → 1 → 1) |
| Pre-engine native quit: snapshot flushed, no engine start, exit 0 | PASS |
| Pre-engine address action: queued page shown, one host | PASS |
| Real missing CEF library: native Quit alert, exit 1 | PASS |
| Display link suppressed: timeout marked unconfirmed, engine and page start | PASS |
| Debug shell regression suite | 6/6 PASS |
| Debug and Release app builds | PASS; no Swift warnings |
| `tools/verify-all.sh` after merging origin/main | 14 PASS, no SKIP |

The Release window suite passes all 18 assertions. The forced timeout records
3,215 ms to the unconfirmed timeout, 3,216 ms to engine start, and 3,380 ms to
first paint; it creates one host and loads the requested page.

A test copy of Open.app has
its CEF library removed to exercise startup failure. The automation-only flags
call Open's real terminate and address actions, and its own alert button; they
are compiled out of ordinary Release builds.

### Comparison and scope

| Scope | Position | ΔE00 | Result |
|---|---|---|---|
| Step A startup screenshot | Not measured | Not measured | Step B owns static comparison |

Step A temporarily keeps the M1 engine wiring behind the real sidebar. Its URL
editor appears only on request; Step C replaces it. This follows the lead task's
real-sidebar requirement over the old “still the M1 window” plan table wording.
No unit tests, Arc launch, desktop input, other-app screenshots, copied Arc
assets, or committed personal browser data were used. Test apps close after each
run. Engine changes are limited to the approved client null guard.

## Step B — real window

In progress on top of Step A. Review fixes will be carried forward.


## Step A fork refresh — 2026-10-25

Merged `origin/main` through `c95be65` (including fork #46, Settings #51, and Settings polish #56).
Both Debug and Release builds passed with the default **fork** distribution.
The Release socket build uses `OPEN_AUTOMATION=1`. The embedded and vendor
Mach-O UUIDs match `4C4C44FE-5555-3144-A175-7398C5A1D4B4`; each new JSON records
that proof and the fork source stamp. No engine build or source sync was run.

| Suite / engine | Result | Evidence |
|---|---|---|
| Release window / fork | 16 functional PASS; 2 sidebar timing FAIL (16/18) | [JSON](engine-spike/results-window-step-a-fork-release.json) |
| Debug shell / fork | 6/6 PASS | [JSON](engine-spike/results-shell-step-a-fork-debug.json) |
| Release shell / fork | 6/6 PASS | [JSON](engine-spike/results-shell-step-a-fork-release.json) |

| Release median, 5 samples each / fork | Sidebar drawn (≤250 ms) | First paint (≤700 ms) |
|---|---:|---:|
| Cold, fresh profile | 252 — FAIL | 502 — PASS |
| Warm, existing profile | 252 — FAIL | 460 — PASS |

The sidebar misses by 2 ms are kept as failures. Host load was [11.0986328125, 9.64599609375, 11.220703125]
on 18 CPUs; these are not controlled idle measurements. The forced
no-display-link launch still waits for the real three-second timeout, reports
`firstFrameConfirmed=false`, starts the engine, and loads the requested page.
Quit during that wait still saves and exits without starting the engine.

Rule 10: full verification after merging `c95be65`; 15 PASS, no SKIP.

| Check | Result | Seconds |
|---|---|---:|
| build | PASS | 19 |
| commands-demo | PASS | 1 |
| roundtrip | PASS | 0 |
| suggest-check | PASS | 12 |
| commands-dump | PASS | 0 |
| route | PASS | 2 |
| favicons | PASS | 1 |
| sleep-demo | PASS | 0 |
| adblock-perf | PASS | 1 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 1 |
| settings-preview | PASS | 48 |
| sidebar-render | PASS | 18 |
| commandbar-render | PASS | 14 |
| boosts | PASS | 2 |


## Step B — real window

Uses `OpenFeatures.BrowserWindowController` as the sole standard window
controller. `App/BrowserWindowController.swift` is deleted. App engine wiring
lives in `EngineWebContentHost`, `EngineWebContentHostFactory`, and
`TabStripMirror`; OpenKit does not import OpenEngine. Step A review fixes are
inherited, including the monotonic presented-frame mark, early Quit, the real
failure alert, guarded/queued navigation, and close without loading.

### Window and engine behavior

- Standard titled system window, transparent hidden titlebar, system traffic
  lights at centers (12,16), (35,16), (58,16), 640×480 minimum.
- One production sidebar per window. Resize is 228–500 pt, with a rubber-band
  region below 228 and hide below 180. Width commits once on drag end. Cmd+S
  animates hide/show over 0.22 s, with Reduce Motion support.
- Hidden sidebar reveals the same view as a floating card after 0.35 s in the
  left 8 pt. Leaving for 0.25 s or selecting dismisses it. It works in full
  screen. An existing Peek suppresses reveal.
- WebContentContainer uses PanelMetrics insets, radius 6, continuous clipping,
  shadow, and the 10% white empty panel. Hosts are created only on selection
  or an explicit engine request. Hidden hosts throttle; at most eight hidden
  hosts stay cached. Closing removes a host immediately. Empty selection
  hides and detaches old visible slots.
- Each window has its own factory, sidebar context, host cache and engine
  strips. The model and stores are shared. New/closed window states are named
  model commands. Closing a window keeps its tabs. Closing the final window
  retains its state for reopen and relaunch; lifecycle automation remains
  available with no visible windows. Normal frames, sidebar
  width/mode, focused Space, and selections persist in the model snapshot.
  Full-screen transitions do not overwrite the normal frame.
- HTML fullscreen hides the sidebar and removes the panel inset without
  changing the saved sidebar mode. Exiting keeps an existing native full-screen
  window full screen; it restores the normal frame if the page initiated it.
- The sidebar delegates selection, new tabs, archive/unload, pin/unpin,
  structure moves, folders, Clear Today, and Space/profile changes to the
  model and the live engine. URL/title/loading/favicon events update model
  slices. Closed host generations reject callbacks.

### M1 port inventory

| Existing behavior | Step B owner/status |
|---|---|
| ensureContent / makeContent / dropContent | Factory + EngineWebContentHost + container cache |
| syncTabStrips | TabStripMirror, per window/profile, sidebar order and pin state |
| showSelection / select / focus Space | Factory + OpenFeatures selection/container |
| openNewTab / adoptUnownedRequest | Factory; background model rows stay lazy |
| Extension actions and popup panels | Factory; basic toolbar and existing native popup lifecycle retained |
| Auxiliary window.open pages | Factory; sized panels, opener flow, close cleanup |
| close / restore / neighbor selection | Factory; pinned unload, Today archive, shared archive sink |
| togglePin / addSplitView | Model commands and OpenFeatures split controller |
| Print / reload / stop / back / forward / zoom / DevTools | Factory menu actions and engine delegate routing |
| Find | Lazy native search field, engine results, panel-relative layout |
| Address entry | Temporary lazy URL editor retained until Step C; early input queues safely |
| Full screen | Standard window and page callback; page fills the screen; normal frame and prior native full-screen mode preserved |
| Status text | Dropped: no measured status area exists in the real panel |
| content(forAutomationHandle), event record/drain, pending dialogs | Factory; automation remains inside Open |
| JS dialogs, permissions, context menus, downloads | Existing delegate bodies ported; downloads route to their owning window |
| Peek/toast | Library ownership retained; Peek stays lazy; transient hosts survive unrelated model edits |

### Review round 1

A's timeout fix is inherited from `f11822bc240139d5b2052e43967ec23e909374a1`.
Main's M4 visual finish (`39fb0ed`) is merged with both sides' behavior kept.

| Finding | Fix | Real-interface evidence |
|---|---|---|
| 1. Peek identity | `rebind(tabID:)` plus factory adopt hook re-keys hosts and modelHostIDs before container binding | Same engine identifier and JS state through promotion; strip contains the new tab; sidebar close returns retained/engine counts to baseline |
| 2. Two live-state writers | Host emits callbacks only; container applies live state behind generation and cache-identity checks | Evicted row stays unloaded in six later samples; another window's remaining host keeps its model row live |
| 3. Profile changes / background opener | Explicit Space-profile teardown, full runtime reset, owning-Space/request-context creation, no profile force unwraps | Old page replaced, inactive row fully reset, background Space window.open creates its child in the correct Space/context |
| 4. Frame-save cost | Dirty scheduling defers folder preparation and DTO capture to the debounce; saveNow stays synchronous; frame notifications skip factory/mirror work | Twelve moves produce zero immediate captures, one debounced capture, correct saved frame, and no tree/mirror counter change |
| 5. Active strip / order | Active page is the selected model tab and must belong to its browser strip | Peek does not become active in the strip; a second window's Space changes preserve the first window's order |
| 6. Sidebar event interception | Removed SidebarView.mouseDown drag override; background drag remains in the root's empty top strip | Sidebar native flow passes; sidebar-render check 125/125 |
| 7. Honest harness rows | Wrapper-specific name, explicit durable-storage BLOCKED row, independent kernel timestamp row, named Debug timing SKIPs | Both configurations print their exact pass/fail/blocked/skip status |
| Early host safety | Optional factory/context/content returns refuse before readiness and queue navigation | Startup probe calls all three paths before readiness, confirms refusal, and then loads one queued page |
| M4 page color | Guarded post-load renderer color query emits the new host callback | A real split pane changes its bar from lavender to blue after navigation; no engine color-change event exists yet |
| M4 selection / binding | Model owns collapse selection; all visible split panes bind on refresh; one-pane duplicate refresh stays removed | features-render check 147/147 |
| Lazy Peek | Passive key and navigation checks use existing Peek storage | Escape with no Peek keeps it unconstructed; native startup check passes |

The all-Spaces strip order is intentional (locked engine decision, 2026-10-25):
favorites first, then Spaces in model order, each in sidebar order (pinned then
Today, folders and split panes flattened). Each window/profile strip contains
its own loaded subset. Space focus does not change that order. Peek hosts stay
outside the strip until promotion.

The initial Step B review evidence below used **CDN CEF**. The current fork
refresh is recorded separately below.

### End-to-end evidence

| Suite / build | Result | Evidence |
|---|---|---|
| Release `--only window` | 38 functional PASS; 2 sidebar timing FAIL (38/40) | [Raw results](engine-spike/results-window-step-b-cdn-release.json) |
| Release `--only sidebar` | 18/18 PASS; durable engine storage BLOCKED | [Raw results](engine-spike/results-sidebar-step-b-cdn-release.json) |
| Release `--only peek` | 6/6 PASS | [Raw results](engine-spike/results-peek-step-b-cdn-release.json) |
| Release `--only shell` | 6/6 PASS | [Raw results](engine-spike/results-shell-step-b-cdn-release.json) |
| Debug `--only window` | 38/38 PASS; 2 named Release-only SKIPs | [Raw results](engine-spike/results-window-step-b-cdn-debug.json) |
| Debug `--only sidebar` | 18/18 PASS; durable engine storage BLOCKED | [Raw results](engine-spike/results-sidebar-step-b-cdn-debug.json) |
| Debug `--only peek` | 6/6 PASS | [Raw results](engine-spike/results-peek-step-b-cdn-debug.json) |
| Debug `--only shell` | 6/6 PASS | [Raw results](engine-spike/results-shell-step-b-cdn-debug.json) |
| Debug / Release builds | PASS; no Swift warnings | `nice -n 10 tools/build.sh Debug/Release` |
| sidebar-render / features-render | 125/125 and 147/147 PASS | Real library executables |
| tools/verify-all.sh | 14 PASS; no SKIP | Summary below |

The window suite checks native chrome, drag resize to 300 pt, the 228/500 pt
limits, drag-to-hide, hover reveal and dismissal, Cmd+S, Cmd+N, two independent
windows, native and HTML fullscreen, and exact restore of both normal frames,
sidebar states, Spaces and selections. Closing a window preserves its tabs.
Closing the final window preserves its own state through reopen and relaunch,
with the correct page shown. Only the two restored selected tabs get hosts.
The Step A lifecycle, early-navigation and host-counter regressions also pass.

The sidebar suite checks selection against the live DOM, visible host and
engine active page; new background tabs without hosts; pin/unpin against the
engine pin flag; Today archive against the real archive store; pinned unload
and wake; production reorder intent against model and engine order; folder
collapse, Clear Today, Space/profile selection, a refused invalid move, and the
eight-hidden-host cache limit. No unit tests or mocked engines are used.

### Release timing with the real window

Five fresh and five warm launches use the same monotonic kernel clock and
presented-frame method as A. OS caches stay intact. Values are milliseconds.

| Case | Sidebar median (≤250) | First paint median (≤700) | Slowest first paint | Verdict |
|---|---:|---:|---:|---|
| Fresh profile (5 launches) | 261 | 521 | 2237 | Sidebar FAIL; paint PASS |
| Warm relaunch (5 launches) | 253 | 493 | 659 | Sidebar FAIL; paint PASS |

**The current Release sidebar budgets fail.** All 38 functional window checks
pass. The main marks are 152/146 ms; modelLoaded is 154/148 ms. Those intermediate
50/120 ms targets also miss. A large part of the elapsed time is already present
at the main mark (which includes OEApplication initialization); this observation
does not establish a cause. The first fresh paint outlier of 2,237 ms stays in
the median. Maximum paint-clock mapping uncertainty is 0.17 ms. Load averages
were 8.61/7.85/7.12 on 18 CPUs. This is not controlled idle-machine acceptance.

The prior review attempt measured sidebar medians 258/244 ms and also found an
eager Peek from passive key routing. That failure remains in
[results-window-step-b-review-before-lazy-peek-fix.json](engine-spike/results-window-step-b-review-before-lazy-peek-fix.json).
The passive getter bug is fixed and a new key-path check verifies it. The later
261/253 ms result remains a timing failure; it is not relabeled as a pass.

An earlier real-window run missed the warm sidebar budget at 252 ms. Removing
redundant single-pane placeholder updates and repeated host-view reattachment
improved that path. Its original measurements remain in
[results-window-step-b-before-single-pane-optimization.json](engine-spike/results-window-step-b-before-single-pane-optimization.json).
A later run passed 33/34 checks but intermittently missed full-screen hover.
Automation now queues mouse motion through AppKit's native event dequeue path,
and fullscreen checks wait for native completion notifications. The earlier
failure remains in
[results-window-step-b-before-native-event-queue.json](engine-spike/results-window-step-b-before-native-event-queue.json).
The final Debug and Release suites above both pass that functional check.

Own synthetic screenshots: [sidebar](engine-spike/sidebar-window.png),
[window](engine-spike/window-startup.png), [second window](engine-spike/window-multiple.png), [Peek](engine-spike/peek-window.png).
All test windows close after each run.

### Repository verification

`origin/main` merged through `39fb0edc8cece28f5a443925b9dc4746b9b47070` before final builds and verification. The full default suite reports no SKIP rows.

| Check | Result | Seconds |
|---|---|---:|
| build | PASS | 1 |
| commands-demo | PASS | 0 |
| roundtrip | PASS | 1 |
| suggest-check | PASS | 11 |
| commands-dump | PASS | 0 |
| route | PASS | 1 |
| favicons | PASS | 1 |
| sleep-demo | PASS | 0 |
| adblock-perf | PASS | 1 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 1 |
| sidebar-render | PASS | 17 |
| commandbar-render | PASS | 13 |
| boosts | PASS | 3 |

### Static window comparison

The suite launches the real app with the capture-time snapshot, no selected
page, 2216×1394 pt window, 228 pt sidebar, and the F0001 Today-state edit. It
captures only Open's window, converts the live image to 1×, and runs the exact
`sidebar-render compare` method from design.md §7. Captures, imported private
state, Open's matching private screenshot, and side-by-side/diff images stay in
`.re/app-shell-comparison-*`. No browser titles, URLs, icons, or Arc pixels are
committed; the table contains element names and measurements only.

| Comparison | Elements | Worst position | Worst ΔE00 | Result |
|---|---:|---:|---:|---|
| Live static sidebar + empty panel vs F0001 | 31 | 1.0 pt | 1.61 | PASS |
| Empty web panel fill | 11 sample points | — | mean 0.42; max 1.05 | PASS |
| System traffic-light centers | 3 | 0 pt | System drawn; color masked | PASS |

[Sidebar comparison table](engine-spike/comparison-sidebar.md).
[Window comparison table](engine-spike/comparison-window.md).

### Limits and later steps

The temporary URL editor and the small existing menu set remain until Step C.
Full command-bar/registry integration is not part of A/B. Site Control,
Library/settings and Space/theme/icon/profile editor surfaces, sharing/export,
Boost customization, duplicate/folder-conversion/move-to-new-Space entries are
explicitly refused (`false`) until their owning later step supplies them. No
silent successful no-op is used for those App intents. Existing model-only
intents keep the library's implementation.

Reorder verification sends the production SidebarDelegate move intent and
checks model order, engine strip order, and the page still shown. It does not
synthesize the macOS drag session; native resize does use own-window drag
NSEvents. Functional screenshots use synthetic titles. Static comparison is
one measured static state; animated states and two-window page transfers are
not claimed here. Full M1 page-feature acceptance remains Step D; these A/B
suites cover window/sidebar flows, Peek promotion/cleanup and live pane color.

Stock CEF reports “Cannot create profile at path …/Profiles/Profile-<id>/Engine”
for a non-default profile. The sidebar suite proves switching to the correct
live page and wrapper context, not durable non-default engine storage. That
engine-owned follow-up is recorded in docs/followups.md. No Engine/ changes are
added in B beyond inheriting A's approved null guard.
