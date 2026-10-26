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


## Step B fork refresh — 2026-10-25

Merged #45 head `78d4ddbc252fa27c2ef4ae87407c5c3bd58f626a` and `origin/main`
through `f41955c` (fork bring-up, real Settings target, polish, release notes).
The real Settings presenters are integrated in Step C, on top of this layer.
The split controller retains model-owned selection after a two-pane collapse;
separating from a larger split still selects the detached sibling.

Engine: **fork**. Debug and Release builds are clean under Swift 6. Embedded
and vendor UUIDs match `4C4C44FE-5555-3144-A175-7398C5A1D4B4`; each phase-named
JSON records the source and UUIDs. No engine build or source sync was run.

| Suite / engine | Debug / fork | Release / fork | Evidence |
|---|---|---|---|
| window | 38/38 PASS; 2 named timing SKIPs | 40/40 PASS | [Debug](engine-spike/results-window-step-b-fork-debug.json), [Release](engine-spike/results-window-step-b-fork-release.json) |
| sidebar | 18/18 PASS; durable profile storage BLOCKED | 18/18 PASS; durable profile storage BLOCKED | [Debug](engine-spike/results-sidebar-step-b-fork-debug.json), [Release](engine-spike/results-sidebar-step-b-fork-release.json) |
| peek | 6/6 PASS | 6/6 PASS | [Debug](engine-spike/results-peek-step-b-fork-debug.json), [Release](engine-spike/results-peek-step-b-fork-release.json) |
| shell | 6/6 PASS | 6/6 PASS | [Debug](engine-spike/results-shell-step-b-fork-debug.json), [Release](engine-spike/results-shell-step-b-fork-release.json) |

| Release median, n=5 each / fork | Sidebar drawn (≤250 ms) | First paint (≤700 ms) |
|---|---:|---:|
| Cold, fresh profile | 218 PASS | 473 PASS |
| Warm, existing profile | 232 PASS | 490 PASS |

Load average [10.58203125, 9.14892578125, 10.0693359375] on 18 CPUs: shared-machine observations,
not controlled idle acceptance. The older CDN 261/253 ms sidebar misses remain
recorded above and in their immutable CDN JSON; this fork run does not erase them.

| Static live comparison / fork | Count | Worst position | Worst ΔE00 | Result |
|---|---:|---:|---:|---|
| F0001 sidebar + window | 31 | 1 pt | 1.61 | PASS |
| Empty panel fill | 11 samples | native geometry passes | max 1.05 | PASS |
| Native traffic-light centers | 3 | 0 pt | — | PASS |

Method and privacy limits remain those above (docs/design.md §7). Only Open's
own windows were captured. `sidebar-render check` passed 125/125;
`features-render check` passed 147/147. Durable per-profile engine storage stays
BLOCKED on the CEF `root_cache_path` follow-up. No unit tests or desktop input.

### Review round 1 — current fork verification

| Finding | Final behavior | End-to-end proof |
|---|---|---|
| 1 Peek identity | Adopt rebinds ID and rekeys both factory sets | Expand preserves live content; mirror contains new ID; sidebar close returns host counts |
| 2 Live-state writers | Host emits callbacks; guarded container is the writer | Evicted row stays unloaded; shared-host close preserves the other window |
| 3 Profile ownership | Explicit Space profile teardown; source Space/context determines requests | Profile switch closes old hosts; background page opens in its own Space/profile |
| 4 Frame save work | DTO capture deferred to debounce; frame events skip tree/mirror | Burst capture counters and tree/mirror counters |
| 5 Mirror active/order | Selected model host only, live all-Spaces sidebar order | Peek excluded; second-window Space switch leaves order stable |
| 6 Sidebar drag | No whole-sidebar mouseDown drag override | Sidebar flows plus 125/125 render and live comparison |
| 7 Harness honesty | Wrapper row, durable storage BLOCKED, kernel row, named Debug SKIPs | Both JSONs retain their actual statuses |

Rule 10: merged origin/main, then full tools/verify-all.sh, 15 PASS, no SKIP.

| Check | Result | Seconds |
|---|---|---:|
| build | PASS | 70 |
| commands-demo | PASS | 0 |
| roundtrip | PASS | 0 |
| suggest-check | PASS | 12 |
| commands-dump | PASS | 1 |
| route | PASS | 1 |
| favicons | PASS | 1 |
| sleep-demo | PASS | 0 |
| adblock-perf | PASS | 1 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 1 |
| settings-preview | PASS | 45 |
| sidebar-render | PASS | 17 |
| commandbar-render | PASS | 15 |
| boosts | PASS | 3 |


## Step C initial integration — before audit P0

The command bar uses the merged `OpenCommandBar` delegate API. Its one lazy
controller per window shares the app's profile-scoped Suggest/History backend.
Typed opens, current-page edits, cross-Space switches, calculator copy, and
registry actions reach the model and real engine. Command-Return creates a
background host without selecting it. Both key layers reuse the controller's
one router; native menu validation and command-bar actions share enabled state.
Key overrides are validated before menus and the Carbon registration change.
Invalid files fall back to defaults with a plain diagnostic.

Duplicate creates a tab immediately after its source, a whole split, or a folder
subtree, with new IDs and no web hosts. One model undo removes the entire copy.
The container remains the guarded writer of live tab state.

`OpenSettings` from main (`dc62e65`) replaces the placeholder. Cmd+, uses the
shared Settings presenter. Cmd+Shift+L, Downloads, Archive, and History use the
shared Library presenter and select its section. Both receive the app's one
`SnapshotStore`. Archive/History stores are shared, including when profiles are
added. Library owns restore/delete transactions; the App callbacks do not
repeat those writes. Downloads come from the real engine contexts and Captures
use the shared file index. History opens into `library.historyProfileID`.
Custom search engines resolve through `SearchEngines.resolve`. The pure remote
query notice gate never opens a Settings window or changes its selected profile.

### Engine and end-to-end evidence

Engine: **fork**, Chromium 156.0.8078.48 / CEF 156.0.14. The fork distribution
was fetched with `tools/fetch-engine.sh --run`; no engine build or source sync
was run. Embedded and vendor Mach-O UUIDs match:
`4C4C44FE-5555-3144-A175-7398C5A1D4B4`. Every phase-named JSON below records the
source stamp and both UUIDs. The earlier A/B CDN receipts remain separate.

| Suite | Debug / fork | Release / fork | Evidence |
|---|---|---|---|
| `commandbar` | 35/35 PASS | 35/35 PASS | [Debug](engine-spike/results-commandbar-step-c-pre-p0-fork-debug.json), [Release](engine-spike/results-commandbar-step-c-pre-p0-fork-release.json) |
| `window` | 38/38 PASS; 2 named timing SKIPs | 40/40 PASS | [Debug](engine-spike/results-window-step-c-pre-p0-fork-debug.json), [Release](engine-spike/results-window-step-c-pre-p0-fork-release.json) |
| `sidebar` | 18/18 PASS; durable engine profile storage BLOCKED | 18/18 PASS; durable engine profile storage BLOCKED | [Debug](engine-spike/results-sidebar-step-c-pre-p0-fork-debug.json), [Release](engine-spike/results-sidebar-step-c-pre-p0-fork-release.json) |
| `peek` | 6/6 PASS | 6/6 PASS | [Debug](engine-spike/results-peek-step-c-pre-p0-fork-debug.json), [Release](engine-spike/results-peek-step-c-pre-p0-fork-release.json) |
| `shell` | 6/6 PASS | 6/6 PASS | [Debug](engine-spike/results-shell-step-c-pre-p0-fork-debug.json), [Release](engine-spike/results-shell-step-c-pre-p0-fork-release.json) |

The command-bar suite uses a real loopback HTTP page that prevents default keys,
the actual field editor and native menu targets. It checks Cmd+T/L/W/S through
the app/window paths, profile isolation, Pin/Unpin actions, lazy duplicate trees,
Archive restore, custom-engine navigation, and Settings persistence. Global
Carbon registration and disable/re-register are checked; no OS-wide key is sent.
All app windows close after each run. No unit tests or mocked engines were added.

### Timing (milliseconds, fork)

| Mark | Debug | Release | Budget |
|---|---:|---:|---|
| First command-bar open, including construction | 33.97 | 31.55 | ≤50; PASS |
| Repeat command-bar open | 22.58 | 18.50 | ≤50; PASS |
| Cold profile; median of 5: confirmed sidebar drawn | — | 245 | ≤250; PASS |
| Cold profile; median of 5: first contentful paint | — | 482 | ≤700; PASS |
| Warm profile; median of 5: confirmed sidebar drawn | — | 245 | ≤250; PASS |
| Warm profile; median of 5: first contentful paint | — | 491 | ≤700; PASS |

Host load average was [6.72705078125, 10.06103515625, 13.02001953125] on 18 CPUs. These are
observed timings under shared-machine load, not controlled idle measurements.
Kernel process-start marks are confirmed in all ten Release launches. Debug
launch-budget rows are explicit SKIPs. The forced no-display-link path still
starts the engine and loads the page after the real three-second timeout.

### Live static comparison

| Capture / scope | Elements | Worst position | Worst ΔE00 | Result |
|---|---:|---:|---:|---|
| F0001 real sidebar/window, Debug + Release / fork | 31 | 1 pt | 1.61 | PASS |
| Empty panel, same live capture | 11 fill samples | native frame assertions pass | max 1.05 | PASS |
| Command bar / Settings / Library | real app images below | reviewed visually | no new live Arc metric claimed | library render checks below |

Method: docs/design.md §7, existing color-space conversion, element masks, and
same frozen private capture. Raw personal inputs stay in `.re/`; no reference
assets or private URLs/titles enter the repo. The command-bar library's existing
comparison limits (Cmd+L selection and split-row presentation) remain documented
in docs/commandbar.md; this PR does not relabel them as a new pixel match.

Own-window screenshots: [command bar](engine-spike/commandbar-live-release.png),
[Settings](engine-spike/settings-live-release.png),
[Library](engine-spike/library-live-release.png),
[standard window](engine-spike/step-c-window-startup.png).

### Limits

- Little Open remains the required Step C stub until Step E. Incognito and
  Peek Email remain disabled. Unsupported later-step actions stay disabled.
- Save Page uses OpenEngine's `Page.captureSnapshot` MHTML plus a native Save
  panel: today's public API cannot initiate an OEDownload for saving a page.
- Settings protocols are wired to the real UI. Durable import, ad-block engine
  filtering, sleep lifecycle binding, and application icon switching remain
  later integration work. Their adapters report that state; they do not claim
  those operations completed. Update checks report the missing update feed.
- Data clearing supports all-time cookies/cache together. Other ranges, History,
  and Downloads clearing return a plain error before mutation. Profile deletion
  refuses an open engine context. Translation prompt reset has no engine API.
- Continuous page-theme events are still missing; the host color callback uses
  the guarded post-load renderer query. Durable non-default engine storage stays
  BLOCKED on the `root_cache_path` follow-up in docs/followups.md.
- Drag reorder exercises the production SidebarDelegate intent; it does not
  automate a native cross-window mouse drag. No desktop input was sent.

### Step C repository verification

Merged `origin/main` through `dc62e65`. Both app builds are clean under Swift 6.
The fork Release socket build uses `OPEN_AUTOMATION=1`; normal Release keeps it off.

| Check | Result | Seconds |
|---|---|---:|
| build | PASS | 10 |
| commands-demo | PASS | 0 |
| roundtrip | PASS | 1 |
| suggest-check | PASS | 14 |
| commands-dump | PASS | 0 |
| route | PASS | 2 |
| favicons | PASS | 2 |
| sleep-demo | PASS | 0 |
| adblock-perf | PASS | 1 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 2 |
| settings-preview | PASS | 42 |
| sidebar-render | PASS | 19 |
| commandbar-render | PASS | 14 |
| boosts | PASS | 2 |

`features-render check`: 147/147 PASS after preserving sibling selection only
when a larger split remains. The first pass exposed this case (146/147); the
failed log is retained under `.re/c-final-features-render-before-split-guard.log`.
`sidebar-render check`: 125/125 PASS. No reference app was launched.


### Step C audit P0 — native responder chain

Standard system commands are now registry metadata (`SystemCommandActions`) in
OpenCommands. Menu items carry AppKit selectors with `target=nil`, including
native find tags and Bold/Italic font traits. Services, Window, and Font menus
remain registered with AppKit. The App no longer maintains a selector map.

Page Copy, Cut, Paste, Select All, and Undo are exercised through the actual
window key route and native responders. Command-bar text undo uses the editor's
own manager; it cannot undo a model tab action. Sidebar model undo is checked
after Reveal Tab focuses the actual outline. Native Find gets first refusal in
text fields; only the window's fallback opens browser Find.

Tabs > Reveal Tab in Sidebar is registered and included in expected-menu.json.
It has no default shortcut, as recorded in docs/re/menus-and-hotkeys.md §Tabs.
View > Reveal Current Tab retains Ctrl+Space.

A P0 development run passed the functional checks but missed the Debug first-open
budget at 62.92 ms under load. Its [receipt](engine-spike/results-commandbar-step-c-before-focus-optimization-debug.json)
is preserved. Opening the bar now avoids a redundant menu rebuild when its
window is already active. Final measurements below supersede no earlier miss.

The lead's independent fork verification of merged #52 reported a 253 ms cold
sidebar median while seven agents built; its first run was 207 ms. Those are
separate observations from the 218/232 ms measurements above. Step I must
remeasure launch and command-bar budgets on an idle machine.

P1 port boundary: this step changes no TabStripMirror, ExtensionTabRequests, or
factory OEBrowserDelegate section. Factory changes are UI composition, command
bar/navigation intents, native text/find responders, and the Library download
notification. Engine code and engine project settings remain with the lead.


## Step C audit P0 complete suite run — 2026-10-26

The PR targets main directly, after #45 and #52 merged. The tested main base is
`b62935e96fd8a5ff062b525a1eeda32dafd3ecd8`; it includes the bundle-ID and entitlement
updates. Both app builds pass under Swift 6. The Release socket build uses
`OPEN_AUTOMATION=1`. The default **fork** distribution was refreshed with
`tools/fetch-engine.sh --run`; no Chromium build, sync, or CDN fallback was used.

The last complete suite run below, before the final model-only main merge, used
matching embedded/vendor UUID
`4C4C44B8-5555-3144-A161-028377002F35`. The exact source stamp and both UUIDs are in every
receipt. Earlier receipts retain their different fork UUIDs and measurements.

| Suite / fork | Debug | Release | Evidence |
|---|---|---|---|
| commandbar | 45/45 PASS | 45/45 PASS | [Debug](engine-spike/results-commandbar-step-c-fork-debug.json), [Release](engine-spike/results-commandbar-step-c-fork-release.json) |
| window | 37/38 PASS; FAIL: fullscreen_hover_reveal; 2 named launch-timing SKIPs | 40/40 PASS | [Debug](engine-spike/results-window-step-c-fork-debug.json), [Release](engine-spike/results-window-step-c-fork-release.json) |
| sidebar | 18/18 PASS; durable profile storage BLOCKED | 18/18 PASS; durable profile storage BLOCKED | [Debug](engine-spike/results-sidebar-step-c-fork-debug.json), [Release](engine-spike/results-sidebar-step-c-fork-release.json) |
| peek | 6/6 PASS | 6/6 PASS | [Debug](engine-spike/results-peek-step-c-fork-debug.json), [Release](engine-spike/results-peek-step-c-fork-release.json) |
| shell | 6/6 PASS | 6/6 PASS | [Debug](engine-spike/results-shell-step-c-fork-debug.json), [Release](engine-spike/results-shell-step-c-fork-release.json) |

| Step C acceptance | Debug / fork | Release / fork |
|---|---|---|
| Registry-native menu selectors, target nil | PASS | PASS |
| Real page Copy, Cut, Paste, Undo, Select All via window keys | PASS | PASS |
| Native text-field undo leaves model intact | PASS | PASS |
| Sidebar model undo after outline focus | PASS | PASS |
| Native Services / Font / Window menus and font trait tags | PASS | PASS |
| Tabs Reveal Tab in Sidebar, no shortcut; View Ctrl+Space retained | PASS | PASS |
| Cmd+T/L/W/S with a page that prevents default keys | PASS | PASS |
| New/current/background navigation; cross-Space row; calculator copy | PASS | PASS |
| Pin/Unpin actions; duplicate tab/folder/split stays lazy; one undo | PASS | PASS |
| Real Settings/Library, shared SnapshotStore; section commands | PASS | PASS |
| Archive restore, profile-scoped History open, custom engine | PASS | PASS |
| Override reload/conflict fallback; shared-router double press | PASS | PASS |
| Carbon registration/toggle and Settings persistence | PASS | PASS |
| commands-dump exact expected-menu comparison | exit 0 | exit 0 |


| Measurement / fork | Debug ms | Release ms | Budget |
|---|---:|---:|---|
| First command-bar results, including construction | 42.05 | 28.75 | ≤50; PASS |
| Repeat command-bar results | 25.97 | 19.31 | ≤50; PASS |
| Cold, fresh profile, median of 5: confirmed sidebar | — | 219 | ≤250; PASS |
| Cold, fresh profile, median of 5: first contentful paint | — | 445 | ≤700; PASS |
| Warm, existing profile, median of 5: confirmed sidebar | — | 237 | ≤250; PASS |
| Warm, existing profile, median of 5: first contentful paint | — | 471 | ≤700; PASS |

Host load was [10.59375, 10.75146484375, 10.736328125] on 18 CPUs. These are shared-machine
observations, not idle acceptance. Keep the earlier 62.92 ms Debug bar miss and
252 ms warm-sidebar miss in their frozen receipts. An intermediate run also
reported 255 ms warm sidebar; its value was captured in the work log before the
final run. The lead separately reported #52 at 253 ms cold (and an earlier
207 ms run) while seven agents built. Step I must remeasure on an idle machine.

The final Debug `fullscreen_hover_reveal` failure remains a failure: the floating
card did not appear in native fullscreen. Earlier Release key-response and sidebar-width failures
are retained in the before-key-settle receipt. Intermediate hover failures were
also observed before the final run. No hover, frame, traffic-light,
sidebar layout, or metrics code changed in Step C; that work is owned separately.
The static F0001 sidebar comparison remains a legacy narrow check, not proof that
the reported live-chrome defects are closed.

The automation key response now waits one short native event-loop turn before
reading responder state. The first Release command-bar attempt queried a host
before creation; the fixture now waits through the existing `wait` interface.
Neither change invents a UI result. Native page editing, text undo and sidebar
undo are still dispatched through the real AppKit/engine interfaces.

The factory OEBrowserDelegate section, TabStripMirror, ExtensionTabRequests,
window setup and sidebar chrome remain untouched relative to the merged base.
Existing Step C limits above remain: Little Open stub, disabled Incognito/Peek
Email, later-step import/filter/sleep/icon/update adapters, the all-time combined
cookie/cache API restriction, post-load color fallback, and durable non-default
profile storage BLOCKED on root_cache_path. Native OS-wide services and Hide
Others are not invoked by automation; their nil-target wiring is checked.

### Final rule 10 and rendering checks

Merged origin/main, then full tools/verify-all.sh: **16 PASS, no SKIP**. The added
media-demo row comes from main. `features-render check`: **147/147 PASS**, including
Escape through the real window handler restoring a maximized split. Sidebar
render passes 125/125. commands-dump exits 0 with the new Tabs entry. No unit tests,
reference assets, Arc launch, or desktop input were used.

| Check | Result | Seconds |
|---|---|---:|
| build | PASS | 31 |
| commands-demo | PASS | 0 |
| roundtrip | PASS | 0 |
| suggest-check | PASS | 11 |
| commands-dump | PASS | 0 |
| route | PASS | 1 |
| favicons | PASS | 1 |
| media-demo | PASS | 1 |
| sleep-demo | PASS | 0 |
| adblock-perf | PASS | 1 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 1 |
| settings-preview | PASS | 43 |
| sidebar-render | PASS | 17 |
| commandbar-render | PASS | 15 |
| boosts | PASS | 3 |


### Post-merge repeat on main 005e065

Main subsequently added Sidebar M1 model commands (`005e065afa77bf188ab6fd820e6d0b0db8b8ae03`).
That merge is included in this PR. Debug and Release rebuilds passed on the refreshed
fork UUID `4C4C4479-5555-3144-A13D-8D658E72FFF9`, stamp suffix `1793001051`.
The last complete run above remains separate evidence; the repeat did not reproduce
all of its passes:

| Latest repeat / fork | Debug | Release | Evidence |
|---|---|---|---|
| commandbar | 1 PASS, suite FAIL before opening the bar | 1 PASS, suite FAIL before opening the bar | [Debug](engine-spike/results-commandbar-step-c-post-main-fork-debug.json), [Release](engine-spike/results-commandbar-step-c-post-main-fork-release.json) |
| sidebar | 17 PASS, suite FAIL at comparison setup; durable storage BLOCKED | 17 PASS, suite FAIL at comparison setup; durable storage BLOCKED | [Debug](engine-spike/results-sidebar-step-c-post-main-fork-debug.json), [Release](engine-spike/results-sidebar-step-c-post-main-fork-release.json) |

The command-bar check could not obtain a key window (`keyWindow=0`) after activating
its own Open window. The sidebar comparison could not obtain the required
2216×1394 pt frame: AppKit clamped it to 2216×1050. A read-only `NSScreen.screens`
query reported a single 1920×1080 screen during this attempt. The cause of the key
window failure is not confirmed. No window setup, activation policy, hover or
layout code was changed to bypass these failures. All apps launched by the suites
were closed. These latest rows are failures, not replaced with the earlier passes.

Post-merge `tools/verify-all.sh`: **16 PASS, no SKIP**. Both app builds pass.
`features-render check`: **147/147 PASS**; sidebar-render: **125/125 PASS**.

| Check | Result | Seconds |
|---|---|---:|
| build | PASS | 58 |
| commands-demo | PASS | 0 |
| roundtrip | PASS | 0 |
| suggest-check | PASS | 14 |
| commands-dump | PASS | 0 |
| route | PASS | 2 |
| favicons | PASS | 1 |
| media-demo | PASS | 0 |
| sleep-demo | PASS | 1 |
| adblock-perf | PASS | 0 |
| adblock-catalog | PASS | 0 |
| profiles | PASS | 2 |
| settings-preview | PASS | 53 |
| sidebar-render | PASS | 17 |
| commandbar-render | PASS | 16 |
| boosts | PASS | 4 |
