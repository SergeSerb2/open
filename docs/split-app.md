# Split View in the App

Base audit: `main` at `7254c0a3`, 2026-11-05. The table distinguishes source wiring from real-App acceptance. The base had the offscreen S1–S6 checks and a two-page `shell` smoke check; it had no `split` suite. Source references below refer to that exact base.

| Item | Real-App status on main | Base evidence |
|---|---|---|
| C1 Ctrl+Shift+= | Wired to an empty pane; no dedicated App acceptance row | `App/MainMenu.swift:39`; `OpenFeatures/SplitViewController.swift:55,89`; `BrowserWindowController.swift:904` |
| C2 sidebar tab → page edge | Live container is a dragging destination; only handler-level offscreen proof | `OpenFeatures/WebContentContainer.swift:371,376`; `SplitViewController.swift:128` |
| C3 tab → pane to combine | Live destination computes an insertion index; no native-session proof | `WebContentContainer.swift:376`; `SplitViewController.swift:128` |
| C4 sidebar context menu | Wired to OpenFeatures; no dedicated split suite | `SplitViewController.swift:64`; `BrowserWindowController.swift:985` |
| C5 command bar / plus menu | Command registry and sidebar intent exist; plus menu incorrectly remains enabled for no tab, Favorites and four panes | `OpenCommands/CommandRegistry.swift` `add-split-view`; `OpenSidebar/SidebarMenus.swift:288`; `BrowserWindowController.swift:980` |
| Focus panes 1–4 | OpenFeatures owns dispatch; only keys 1–2 were available in the automation key map | `BrowserWindowController.swift:904`; `SplitViewController.swift:89`; `App/Automation/AutomationController.swift` `sendKey` |
| Next / previous pane | Wired, wraps; brace keys missing from the automation key map | `SplitViewController.swift:99`; `OpenCommands/CommandRegistry.swift:412` |
| Close focused pane | Wired; minus key missing from automation | `SplitViewController.swift:75,94` |
| Expand, restore, Esc | Transient maximized state exists, Esc handled before key routing; no App split receipt | `SplitViewController.swift:96`; `BrowserWindowController.swift:856` |
| Separate focused pane | Wired; collapsed split retains the model's surviving selection | `SplitViewController.swift:75–86,95`; `OpenModel/BrowserModel.swift:2039` |
| Separate All | Pane and sidebar menus both call unsplit | `SplitViewController.swift:117`; `OpenSidebar/SidebarMenus.swift:187` |
| Flip orientation | Both menus call the model; keeps focus/fractions | `SplitViewController.swift:109`; `OpenSidebar/SidebarMenus.swift:180`; `BrowserModel.swift:1991` |
| Add Tab… through four panes | Sidebar and pane menus exist and disable at four | `OpenSidebar/SidebarMenus.swift:188`; `SplitViewController.swift:54,108` |
| Divider drag + fraction save | Native mouse methods update live frames; commit fractions on release | `SplitDividerView.swift:17–25`; `WebContentContainer.swift:322,365`; `BrowserModel.swift:1981` |
| Pane ring + sidebar focus reflection | Ring and URL follow focus. Sidebar retains one selected row; cells intentionally have equal fills | `WebContentContainer.swift:310,313`; `OpenSidebar/SidebarRows.swift:850–854`; measured `re/interaction-states.md` §7, F0081 |
| Focused close / 2→1 collapse | Model retargets selection to survivor; App code preserves it | `SplitViewController.swift:75–86`; `BrowserModel.swift:2039` |
| Relaunch: orientation, fractions, focus, ≥3 | Persisted in SplitDTO; no dedicated real-App ≥3-pane proof | `OpenStore/SnapshotDTOs.swift:134`; `features-render` S6 |
| Four horizontal / vertical panes | Shared layout handles 1–4; offscreen evidence only | `SplitLayout.swift:8–43`; `WebContentContainer.swift:336` |
| Narrow content below 800 pt | Equal below-minimum sizing already exists; no real-window resize proof | `SplitLayout.swift:19–20` |
| Two and four real pages | `shell` proves two live pages; four unproved | `tools/e2e/engine_e2e.py:1038–1044`; `WebContentContainer.swift:177–184` |
| Idle / switch / sidebar speed | No split-specific App gates | `architecture.md` ≤16 ms live-tab budget; `s8-speed-gates.md` observer precedent |

Paths without a prefix in the evidence column are under `Packages/OpenKit/Sources/` beside their named module. These findings use Open source only; they add no reverse-engineering claims.

The measured sidebar specification supersedes the old plan's focus-cell guess. F0081 has equal cell fills and no separate focused-cell mark (`docs/re/interaction-states.md` §7). The suite checks the selected split row, focused pane ring and sidebar URL. No visual or metric change is part of this work.

The new drag checks exercise the real `WebContentContainer` destination callbacks with an `NSDraggingInfo` object and a unique pasteboard containing `com.open.sidebar.node`. `SplitDropOverlayView` is the drawing child, not the registered destination. The virtual pointer does not supply the WindowServer drag loop consumed synchronously by `NSOutlineView.mouseDown`. This is the permitted destination-callback fallback; it does not prove a real `NSDraggingSession` or an external drag.

Runtime receipts and final results are added below after verification. Raw data and PNGs stay in `.re/s9-split/`.

## Verification scope

The live suite uses fresh data and cache roots, local HTTP pages and the App's socket. It saves and resets `open.advanced.showFullURLWithToolbar`, then restores the original value in `finally`, including after relaunch. Keys use `key route=app`. Divider events use the existing in-App pointer. Option-click uses native event dequeue so `NSApp.currentEvent` carries the click's flags. No system mouse or keyboard input is sent.

The idle observer is loaded only into the suite-owned App. It starts before pane creation, attributes scheduler calls to split/container code, and watches the live container's views and layers after the divider drag. The five-second interval requires zero layout/draw/invalidation/scheduling events, live timers, display links and CA animation keys. The polling socket issues no requests during that interval. This is a split-owned work gate, not a whole-App CPU claim.

The tab-switch gate alternates 40 single→single and 40 single→two-pane transitions with warm real pages. It measures production sidebar selection through native layout, CA submission and an acknowledgement that the focused renderer is visible. Both p95 values must remain ≤16 ms (`architecture.md`). It excludes socket transport and physical frame presentation. The existing `measure` suite has launch/memory/idle checks; it does not contain a live-tab switch gate.

The sidebar gate runs the same `sidebar-render bench --rows 1000` workload from base and branch binaries, in AB/BA/AB order under the quiet lock. It compares the median of each revision's three p95 values with the requested ±10% limit. It keeps every sample. `tools/verification/split-speed.py` saves the full output and 1/5/15-minute load averages before and after each run.

Initial paired receipt: base p95 4.12/5.20/3.01 ms; branch 4.32/3.34/5.89 ms. Median p95 4.12→4.32 ms, +4.85%, PASS. Loads were 10.96–11.59 / 11.72–11.86 / 11.28–11.33. Raw receipt: `.re/s9-split/sidebar-speed.json`.

Existing motion differences are reported to the lead, with no redesign: `layoutPanes(animated:)` animates only changes to the pane ID list, so an orientation-only flip has no explicit 0.22-second animation. Removed slots leave the hierarchy before the surviving frames animate, without the old plan's separate 0.14-second fade. This work changes neither behavior nor tokens. A fresh capture remains the authority for any visual finish.

No new product guess was needed. Existing accepted choices remain: four panes, 200 pt minimum, and first-surviving-pane focus on close. Divider keyboard resizing remains skipped in v1 as plan §3.4 permits. The measured sidebar equal-cell fill remains unchanged.

An early instrumented Release renderer-acknowledged switch receipt failed: single median/p95 8.482/14.703 ms; split 17.376/20.777 ms (load 6.11/9.18/10.22). That receipt remains `.re/s9-split/split-release-queued.json`; it is not a valid uninstrumented baseline. The suite mistakenly injected a new, startup-armed idle observer on relaunch and left its backtrace attribution active during latency measurement. The corrected suite injects the observer only into its first process, then measures the relaunched App without it. Inspection also found a second `refreshPlaceholders()` immediately after `show()` in window refresh, which repeated pane configuration and defeated §5.4's deferred nonfocused-host work. The fix removes that duplicate and avoids invalidating layout when `maximizedTabID` is assigned its unchanged value. Geometry, motion tokens and host cache limits stay unchanged. Final receipts below must prove the budget after this change.

The uninstrumented profiling loop reproduced the remaining cost. Its later single/split p95 values were 11.74/22.05 ms (native work 6.96/13.40 ms; load 6.46/6.53/7.73). The first loop overlapped the native sampler and is diagnostic only. `sample PID 5` shows `WebContentContainer.updateSlots` → `PaneChromeView.init` → `ActionButton.init` → AppKit `NSButton` setup (`.re/s9-split/switch-sample.txt`, lines 40–55). Detached pane views now stay with cached hosts, with a separate fixed cap of eight parked views even for protected hosts. Host close/profile teardown removes the matching parked view. This reuses pane chrome across live tab switches without changing its drawing or metrics. The suite also exercises twelve real selections and checks the retained-view bound.
