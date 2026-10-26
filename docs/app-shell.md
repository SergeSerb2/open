# App shell acceptance

## Step A — window before engine

The snapshot loads before engine startup. The real `OpenSidebar.SidebarView`
then draws in the first window. AppKit finishes a runloop turn before
`OEEngine.start` loads and initializes Chromium. The same sidebar remains
attached when the engine becomes ready. No web content or engine context exists
at the pre-engine mark. Only the selected restored tab gets web content.

`App/BrowserWindowController.swift` temporarily hosts the production sidebar
while it keeps the M1 engine wiring. Its old URL editor appears only on request;
Step C replaces that editor with OpenCommandBar. Step B moves composition to
OpenFeatures and deletes the M1 controller. This follows the task's real-sidebar
requirement over the older Step A table's “still the M1 window” wording.

### Release timing

Command: `python3 tools/e2e/engine_e2e.py --config Release --only window`.
Build: `OPEN_AUTOMATION=1 nice -n 10 tools/build.sh Release`.
CEF 156.0.14, Chromium 156.0.8078.48, arm64, macOS 27.2, Apple M5 Pro.
The fixture is local HTML in a data URL, with visible text and no network.
Times are ms from the kernel process-start timestamp. Sidebar timing ends after
AppKit layout/display and `CATransaction.flush`, before the engine-start mark.
First contentful paint comes from the real selected renderer's Performance API.

| Case | Sidebar median (≤250) | First paint median (≤700) | Slowest first paint | Verdict |
|---|---:|---:|---:|---|
| Fresh profile (5 launches) | 194 | 372 | 539 | PASS |
| Warm relaunch (5 launches) | 196 | 371 | 430 | PASS |

“Fresh” means a new data root and engine profile, not a purged OS disk cache.
“Warm” means a new process restoring the same profile and snapshot. An earlier build
first launch painted at 1,759 ms. That is consistent with the plan's first-profile/signature-cost warning, but that cause
was not isolated. A separate run during our Debug build missed the sidebar budget (312/304 ms
medians); [all samples](engine-spike/results-window-release-build-load.json)
remain recorded. After that build and the Debug suite finished, the final run
above passed. The machine still had other concurrent work; these are loaded-machine
observations, not controlled idle-machine acceptance. `main` medians (112/113
ms) also miss the plan's 50 ms intermediate target.

Raw samples and pre-engine object counts:
[results-window-release.json](engine-spike/results-window-release.json).
Open's own window: [window-startup.png](engine-spike/window-startup.png).

### End-to-end checks

| Check | Result |
|---|---|
| Pre-engine real sidebar, visible window, zero pages and contexts | 5/5 PASS |
| Relaunch restores two rows and creates only the selected page | 5/5 PASS |
| Fresh and warm median timing budgets | PASS |
| Debug shell regression suite | 6/6 PASS |
| Debug and Release app builds | PASS; no Swift warnings |
| Repository verification | 13 PASS; commandbar-render SKIP (target absent) |

### Comparison

| Scope | Position | ΔE00 | Result |
|---|---|---|---|
| Step A startup screenshot | Not measured | Not measured | Step B owns static comparison |

No Arc assets or personal data are committed. No desktop input or screenshots
of other applications were used. All launched test processes quit after each
run. Engine source and engine project settings are unchanged.

## Step B — real window

Pending Step A PR and checks.
