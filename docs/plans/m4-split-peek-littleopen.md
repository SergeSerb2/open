# M4 — Split View, Peek, and Little Open — implementation plan for Open

Status: plan for implementation. Implementers have no other context: every file,
type, signature, metric, animation, key, and check you need is in this file.
If a signature here conflicts with a real file in the repo, stop and report the
conflict; do not silently redesign.

Milestone: M4 in [plan.md](../plan.md) — Split View, Peek, Little Open, plus
default-browser handling for Little Open. Branch: one feature branch off
`main` (after the M2 design/sidebar work is merged; see §0.4), one PR against
`main`. Follow [AGENTS.md](../../AGENTS.md): user-visible text never uses the
Arc brand (exception: "Import from Arc"); Little Arc is "Little Open" in Open;
no unit tests — verify end to end on the real app and through the offscreen
render harness in §9; do not copy Arc assets or code — recreate every asset;
cite evidence, mark guesses as guesses.

Read these first (all on `main` unless noted):

- [architecture.md](../architecture.md) — module borders, performance budgets.
- [model.md](../model.md) — `Split`, `BrowserModel` commands, snapshot DTOs.
- [routing.md](../routing.md) and [plans/routing-little-open.md](routing-little-open.md)
  — Phase A is done (`OpenRouting`, rename to `littleOpen`). Phase B (§8–§9 of
  that plan: intake, default browser, Little Open coordinator/window) is
  **reused by this plan, not duplicated**. This plan builds the App-target
  pieces that plan defers to "when the App target exists".
- [commands.md](../commands.md) — command ids and shortcuts are already
  registered in `OpenCommands`. Do not rename a shipped id.
- [re/features-advanced.md](../re/features-advanced.md) §1 (SV-1…SV-14),
  §2 (PK-1…PK-10), §3 (LA-1…LA-13) — behavior rules. This plan cites them.
- [re/interaction-states.md](../re/interaction-states.md) §7 (split row),
  §11 (Split View, MEASURED), §12 (Peek, MEASURED), §15 (context menus),
  §18 (Settings Links rows).
- [re/menus-and-hotkeys.md](../re/menus-and-hotkeys.md) — `Ctrl+Shift+=` /
  `Ctrl+Shift+-` and the code-only split-pane keys.
- [sleep.md](../sleep.md) and [memory-design.md](../memory-design.md) —
  `SleepVisibilityProviding`, sleep phases, placeholder rendering.
- [re/runtime-observations.md](../re/runtime-observations.md) §1.2 — web
  panel insets, radius, shadow.
- `docs/design.md` on branch `origin/m2/design-sidebar` (targets
  `OpenDesign`, `OpenSidebar`, executable `sidebar-render`). On `main` today
  those targets do not exist yet (see `Packages/OpenKit/Package.swift` on
  `main`). §0.4 resolves the dependency. Token names below (`OpenDesign`,
  `Metrics`, `SpaceThemeStyle`) refer to that branch's design system.

---

## 0. Scope, non-scope, locked decisions

### 0.1 In scope

| Area | Deliverable |
|---|---|
| Web content container (§5) | One shared AppKit container that hosts 1–4 web views with the Arc panel look, animated single↔split transitions, sleeping/placeholder rendering. Every other area in this plan sits on it. |
| Split View (§3) | Creation (shortcut, drag, context menu, command bar), horizontal/vertical layout for 2–4 panes, divider drag persisted to `Split.fractions`, per-pane 32 pt top bar, 2 pt focus ring, focus switching, close/separate/expand, sidebar split-row reflection. |
| Peek (§4) | Trigger rules (pinned/favorite cross-host click; Shift-click), in-window overlay (80 % width, dimmed backdrop, three 33 pt buttons), Esc/click-outside, expand-to-tab animation, nesting, history. |
| Little Open (§6) | 720×540 window, toolbar, tab list/auto-archive via the routing plan's coordinator, "Move to Space", global hotkey, no-main-window behavior. |
| Visibility (§7) | `SleepVisibilityProviding` implementation feeding split panes, Peek tab, and Little Open tabs to `OpenSleep`. |
| Verification (§9) | Offscreen render checks vs. captured frames (Split F0081, Peek F0090) in the `sidebar-render` style; scripted interaction checks with a fake `WebContentHost` (colored `NSView`s); app-phase checks via the automation channel once the engine lands. |

### 0.2 Out of scope (do not build)

- Easels, Notes, Arc Max AI, accounts, sync (AGENTS.md v1 scope).
- Peek email (`peek-email`, Cmd+Shift+E) beyond reserving its command id;
  email Peek needs the mail preview surface, which is not in v1.
- Little Open downloads tray contents (LA-10): show the button disabled,
  as the routing plan §0.2 already decides. Wire it with the downloads
  milestone.
- Persisting Little Open sessions across quit (routing plan §0.2, §9.7).
- Split "Share" as an account link (SV-13): implement "Copy link" as a copy
  of the pane URLs only.
- Live Folders, Boosts, Zap, Site Control Center popover contents. The
  per-pane top bar in §3.5 reserves the Site Control Center button slot;
  its popover is the M6 milestone.
- AppleScript creation of Little Open tabs (LA-5): note
  `LittleOpenCoordinator.open(url:profileID:)` as the future caller; do not
  build the scripting surface here (M7).

### 0.3 Locked decisions (do not re-derive)

1. **Model is already built.** `Split { id, orientation, fractions, panes:
   [Tab] (2–4), focusedPaneID }`, `SplitOrientation.horizontal/.vertical`
   (`Packages/OpenKit/Sources/OpenModel/LiveNodes.swift`), persisted as
   `SplitDTO` (`OpenStore/SnapshotDTOs.swift`, `schemaVersion` stays 1).
   Commands already exist: `makeSplit(tabIDs:orientation:)`, `unsplit(splitID:)`,
   `removePane(splitID:tabID:archive:)`, `focusSplitPane(splitID:tabID:)`,
   `selectNode(windowID:spaceID:nodeID:)`, `newTab`, `closeTab`. Placement
   rules (model.md): a split lives in a Space's pinned or Today section or in
   a folder, never in Favorites; `makeSplit` puts the split in the first
   tab's slot and refuses favorites, split panes, duplicates, and counts
   outside 2–4; panes move only through split commands. Build UI on these
   commands. The only new model commands this plan adds are in §2.2.
2. **Commands are already registered.** `OpenCommands/CommandRegistry.swift`
   holds `add-split-view` (Ctrl+Shift+=), `close-split-pane` (Ctrl+Shift+-),
   `expand-current-split`, `separate-from-split-view`, `focus-split-pane-1…4`
   (Ctrl+Shift+1…4), `next-split-pane` (Ctrl+Shift+}), `previous-split-pane`
   (Ctrl+Shift+{), `new-little-open-window` (Cmd+Opt+N), `little-open-global`
   (Cmd+Opt+N, global scope), `open-in-current-space` (Cmd+O, "Move Little
   Open or Peek to Space…"). Wire handlers to these ids. Never rename an id
   (commands.md). Display titles use "Little Open"; "Little Arc" may remain
   only as a search alias.
3. **Little Open reuses the routing plan.** Types, signatures, dedupe,
   auto-archive, and the no-main-window table in routing-little-open.md
   §9.1–§9.7 are normative. This plan references them as R-§9.x and adds
   only the M4 deltas (container hosting, visibility, render checks). If
   this plan and that plan disagree on a Little Open signature, that plan
   wins; fix this plan.
4. **Visibility contract is already built.** `OpenSleep` reads one
   `SleepVisibilitySnapshot` per pass (`OpenSleep/SleepEngine.swift`):
   `windows: [WindowID: WindowState]`, `peek`, `littleOpen`, `splitPanes`,
   `pictureInPicture: Set<ItemID>`, and `visibleTabIDs(in:)` already unions
   the extra sets and expands a selected split to every pane. The App
   supplies the snapshot (§7). Do not change `OpenSleep`.
5. **Naming.** "Little Open" in every user-visible string, menu, tooltip,
   and log line a user can see. Swift identifiers use `LittleOpen` /
   `littleOpen`. Persisted JSON key is `littleOpen`; legacy `littleArc`
   decode stays (model.md one-way migration).
6. **Engine boundary.** The Swift shell talks only to the `OpenEngine`
   layer / `OpenWeb` protocols, never to Chromium or CEF directly
   (AGENTS.md, architecture.md). All engine access in this milestone goes
   through the assumed `WebContentHost` in §1. Packages never import
   `OpenEngine`.

### 0.4 Branch dependency (resolve before Step 1)

`main` today has no App target and no `OpenDesign`/`OpenSidebar` targets;
they land with the M2 branch (`origin/m2/design-sidebar`: `docs/design.md`,
`sidebar-render`). This milestone needs the design tokens (`OpenDesign`),
the sidebar split row, and the offscreen harness pattern.

- If M2 is merged to `main` when you start: branch `m4/split-peek-littleopen`
  off `main`.
- If M2 is not merged: branch off `origin/m2/design-sidebar`, note the base
  in the PR description, and rebase onto `main` after M2 merges. Do not copy
  `OpenDesign` files into this branch.
- The App target's bundle id: use the id the App target already defines.
  The routing plan writes `app.open` as a placeholder; substitute the real
  id everywhere (Info.plist `CFBundleURLName`, `lsregister`, checks).

---

## 1. Assumed engine API — `WebContentHost`

`docs/engine-api.md` does not exist yet. Design against exactly this
minimal interface. When the real `OpenEngine` API lands, write one adapter
file per surface (see §8) that conforms the real object to these protocols.
Do not redesign controllers to fit a draft engine API.

### 1.1 Protocol (define in `App/WebContent/WebContentHost.swift`)

```swift
import AppKit

/// One live web page. The App target owns the concrete type; every M4
/// controller sees only this protocol. [NEEDS ENGINE] for the real type.
@MainActor
public protocol WebContentHost: AnyObject {
    /// The view to embed. Stable for the host's lifetime.
    var view: NSView { get }
    var tabID: ItemID { get }
    var currentURL: URL? { get }
    var title: String { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var isLoading: Bool { get }

    func load(_ url: URL)
    func reload()
    func stop()
    func goBack()
    func goForward()
    /// Make the web view first responder and give the page keyboard focus.
    func focus()
    /// Release the renderer/view. After close, no callback fires.
    func close()

    // Callbacks (single-subscriber closures; the container sets them).
    var onURLChange: ((URL) -> Void)? { get set }
    var onTitleChange: ((String) -> Void)? { get set }
    var onLoadingChange: ((Bool) -> Void)? { get set }
    var onFaviconChange: ((Data?) -> Void)? { get set }
    /// Navigation decision hook. Return false to cancel the navigation.
    /// `modifiers` are the click's flags. Needed only for Peek trigger B/C
    /// and Opt+Cmd-click → Little Open; may be nil (then those triggers
    /// that need it stay disabled — see §4.2, §6.5).
    var shouldNavigate: ((URL, NSEvent.ModifierFlags) -> Bool)? { get set }
}

/// Factory the App injects everywhere. One host per (tab, profile).
@MainActor
public protocol WebContentHostFactory: AnyObject {
    func makeHost(tabID: ItemID, profileID: ProfileID, url: URL?) -> any WebContentHost
}
```

`ItemID`, `ProfileID` are `OpenModel` types. The factory maps `profileID`
to the profile's CEF request context inside the adapter; no M4 code names a
request context.

### 1.2 Assumptions (each is a gate; verify when the engine lands)

| # | Assumption | If false |
|---|---|---|
| A1 | A host can be created without loading (`url: nil`), then loaded later. Needed for lazy/placeholder tabs and Peek pre-warm. | Create with the tab URL and immediately `stop()`; placeholder rendering (§5.5) still works, but first-paint cost returns. Log the deviation. |
| A2 | `view` can be removed from one container and added to another without reload (reparenting). Needed for split add/remove, Peek expand, Little Open → Space move. | Destroy and recreate the host on every move; preserve scroll/form state only via the sleep-history envelope (`OpenSleep.SleepHistoryEnvelope`). Mark expand/move as [NEEDS ENGINE] until state survives. |
| A3 | `shouldNavigate` fires before a click navigation commits and can cancel it. | Shift-click Peek (§4.2 trigger B) and Opt+Cmd-click → Little Open (R-§9.5) cannot intercept; ship trigger A (pinned/favorite) only if the engine reports the click target some other way, else disable all three and note it in the PR. Peek opened from the context menu (§4.2 trigger D) still works. |
| A4 | Back/forward history is per host and survives reparenting. `goBack`/`goForward` inside a Peek walk the Peek's own history (§4.6). | Peek gets single-page history: Back closes the Peek. Note it; do not fake a history stack in Swift. |
| A5 | A host reports `currentURL` after redirects, synchronously readable. Needed for "Move to Space" dedupe (R-§9.4 step 2). | Fall back to the last `onURLChange` value (keep it in the controller). Dedupe may miss a redirect-only duplicate; acceptable, log it. |
| A6 | Creating 4 hosts for a 4-pane split and keeping hidden tabs host-less is cheap enough for the budgets in architecture.md (tab switch ≤ 16 ms). | The container already creates hosts lazily (§5.4); if creation is slow, pre-warm only the focused pane and show placeholders in the others until first focus. |
| A7 | The engine delivers no callbacks after `close()`. | Guard every callback with a weak host reference and a generation counter in `WebContentContainer` (§5.3); a stale callback is dropped. Implement the guard regardless — it is cheap. |

### 1.3 Fake host for all pre-engine work (build in Step 1)

`App/WebContent/FakeWebContentHost.swift` (also compiled into the
`features-render` harness, §9): an `NSView` filled with a per-tab solid
color, a centered host/title label, and a click counter. It implements
every `WebContentHost` method in memory: `load` sets `currentURL`, fires
`onURLChange`/`onTitleChange`, toggles `isLoading` for 0.3 s; `goBack`/
`goForward` walk an in-memory URL stack; `shouldNavigate` is stored and
invoked by a "simulate link click" test hook. No network, no engine.
Every layout/behavior check in §9 runs against this fake. The real adapter
(`App/WebContent/EngineWebContentHost.swift`) is the only [NEEDS ENGINE]
file in this milestone.

---

## 2. Files, targets, and model changes

### 2.1 File inventory (create exactly these; edit only what is listed)

New library target (the only `Package.swift` edit in this milestone):

```text
Packages/OpenKit/Package.swift            EDIT: add OpenFeatures (below)
Packages/OpenKit/Sources/OpenFeatures/
  SplitLayout.swift                       §3.3 pure layout math (no AppKit views)
  PeekPolicy.swift                        §4.2 trigger decision (pure)
  Features.docc                           skip — no doc catalog in v1
```

`OpenFeatures` depends on `OpenModel` only. It holds decisions and math
that the `features-render` harness and the `openkit` CLI can exercise
without AppKit windows. It imports Foundation only (plus `CoreGraphics`
for `CGRect` math). Do not add AppKit, `OpenStore`, or `OpenCommands`
dependencies.

```swift
// Package.swift — in products:
.library(name: "OpenFeatures", targets: ["OpenFeatures"]),
// in targets:
.target(name: "OpenFeatures", dependencies: ["OpenModel"]),
// in the openkit executable target: add "OpenFeatures" to dependencies.
// in the features-render executable target (new, §9.1): see §9.1.
```

App target files (create when the App target exists; if it does not exist
yet, Step 2 creates the groups and the harness in §9 still builds):

```text
App/WebContent/
  WebContentHost.swift                    §1.1 protocols
  FakeWebContentHost.swift                §1.3 fake (app + harness)
  EngineWebContentHost.swift              §8 adapter [NEEDS ENGINE]
  WebContentContainer.swift               §5 container view + controller
  PaneChromeView.swift                    §3.5 per-pane 32 pt top bar
  PlaceholderContentView.swift            §5.5 sleeping/placeholder view
App/Split/
  SplitViewController.swift               §3 pane lifecycle, focus, menus
  SplitDividerView.swift                  §3.4 divider hit/drag view
  SplitDropOverlayView.swift              §3.2 drag-to-split zones
App/Peek/
  PeekController.swift                    §4 overlay state machine
  PeekOverlayView.swift                   §4.3 scrim + panel + 3 buttons
App/LittleOpen/                           (routing plan §2.2 — same files)
  LittleOpenSession.swift                 R-§9.1
  LittleOpenCoordinator.swift             R-§9.2 (+ §6 deltas)
  LittleOpenWindowController.swift        R-§9.3 (+ §6 deltas)
App/Windows/
  BrowserWindowController.swift           EDIT or CREATE: owns sidebar +
                                          WebContentContainer + PeekController;
                                          implements SleepVisibilityProviding (§7)
  AppDelegate.swift                       EDIT in place: URL intake (R-§8.3),
                                          global hotkey (R-§9.5), command
                                          dispatch for §3/§4/§6 command ids
App/ExternalLink/                         (routing plan §2.2 — same files)
  ExternalLinkIntake.swift                R-§8.5
  DefaultBrowserService.swift             R-§8.4
  SourceAppResolver.swift                 R-§8.6
App/Info.plist                            EDIT: CFBundleURLTypes (R-§8.2)
```

Never create a second `NSApplication` delegate. If `AppDelegate` already
exists, edit it in place.

### 2.2 Model changes (the only `OpenModel` edits allowed)

`Split.fractions`, `orientation`, and `focusedPaneID` already persist.
Three gaps remain. Add exactly these to
`Packages/OpenKit/Sources/OpenModel/BrowserModel.swift`, following the
existing command style (main-actor, one undo step per command, precise
`TreeChange` events, refused command changes nothing and emits no event):

```swift
/// Appends or inserts a tab as a pane. Refuses (false, no change) when:
/// the split is missing, already has 4 panes, the tab is missing, is a
/// favorite, or is already a split pane. On success the tab takes pane
/// index `at` (clamped), fractions reset to equal (see §3.3), focus moves
/// to the new pane, one `.reload` per changed parent.
@discardableResult
public func addPane(splitID: ItemID, tabID: ItemID, at: Int? = nil) -> Bool

/// Writes divider results. `fractions` must match panes.count and sum
/// to 1 (±0.001); otherwise refuse. No undo step per drag tick — the
/// divider controller calls this once on drag end (§3.4); live drag
/// updates only the view. Marks the snapshot dirty via the split's
/// @Observable fractions (no TreeChange: property change, per model.md).
public func setSplitFractions(splitID: ItemID, fractions: [Double])

/// Flips orientation, keeps pane order and focus. One undo step.
public func setSplitOrientation(splitID: ItemID, orientation: SplitOrientation)
```

Do not add a Peek type to `OpenModel`. Peek is transient UI state (§4.1)
and never enters the sidebar tree or the snapshot. Do not add Little Open
tabs to `BrowserModel` (R-§9.1: the coordinator owns sessions; a Little
Open `Tab` has no `parentByID` entry and must never be passed to model
commands).

### 2.3 Types owned by this milestone

```swift
// OpenFeatures/SplitLayout.swift — pure math, unit-testable via CLI (§9.2)
public enum SplitLayout {
    /// Pane frames inside `content` (already inset per §5.2).
    /// Horizontal: panes side by side, divider gaps of `gap` between them.
    /// Vertical: panes stacked. `fractions` nil/empty/mismatched → equal.
    /// Each pane is clamped to at least `minPane` on the split axis; the
    /// remaining space is redistributed in order (see §3.3 algorithm).
    public static func frames(content: CGRect, orientation: SplitOrientation,
                              fractions: [Double]?, gap: CGFloat,
                              minPane: CGFloat) -> [CGRect]
    /// Normalized fractions for pane widths/heights (sums to 1).
    public static func fractions(forSizes sizes: [CGFloat]) -> [Double]
}

// OpenFeatures/PeekPolicy.swift — pure trigger decision (§4.2)
public enum PeekPolicy {
    public struct Click: Sendable {
        public var sourceIsPinnedOrFavorite: Bool
        public var sourceHost: String?   // canonical host, lowercased
        public var targetHost: String?   // canonical host, lowercased
        public var shiftHeld: Bool
        public var peekOtherSitesEnabled: Bool
        public var peekShiftEnabled: Bool
    }
    public enum Decision: Sendable { case navigate, peek }
    public static func decision(for click: Click) -> Decision
}
```

Host canonicalization reuses `OpenRouting.HostNormalizer` if it is
visible to `OpenFeatures` through `OpenModel`; if not, compare
`URL.host()?.lowercased()` with one leading `www.` stripped on both
sides. "Other site" means canonical hosts differ (PK-2 guess boundary —
exact-host comparison; registrable-domain grouping is a follow-up if
runtime checks demand it, §10 Q1).

---

## 3. Split View

Evidence: SV-1…SV-14; MEASURED geometry in interaction-states §11;
commands in commands.md. The sidebar split row already exists (M2,
interaction-states §7); this section covers the web-area side and the
focus reflection.

### 3.1 View hierarchy (per browser window)

```text
BrowserWindowController (NSWindowController)
└── contentView
    ├── ThemeBackgroundView            (M2, behind everything)
    ├── SidebarView                    (M2)
    └── WebContentContainer            (§5, App/WebContent/)
        ├── PaneSlotView × 1…4         (one per visible pane)
        │   ├── PaneChromeView         (§3.5, 32 pt top bar)
        │   └── host.view  OR  PlaceholderContentView (§5.5)
        ├── SplitDividerView × 0…3     (§3.4, in the 10 pt gaps)
        ├── SplitDropOverlayView       (§3.2, only during a tab drag)
        └── PeekOverlayView            (§4.3, only while a Peek is open;
                                        sibling above all PaneSlotViews)
```

`SplitViewController` (App/Split/) is a child view controller of the
window controller. It owns the pane-slot lifecycle for the selected node:
given `BrowserModel` + `windowID`, it reads the selected node for the
focused Space, builds 1 slot (tab) or 2–4 slots (split), and keeps
`Split.focusedPaneID` and the container (§5) in sync. It never writes the
model except through the commands in §2.2/§3.7.

### 3.2 Creation paths (all five; SV-5)

| # | Path | Exact behavior |
|---|---|---|
| C1 | Shortcut `add-split-view` (Ctrl+Shift+=) | If the selected node is a tab: create a split from that tab plus a new empty pane (§3.2.1) with `.horizontal`, focus the new pane. If already a split with < 4 panes: add one empty pane at the end. At 4 panes: beep, no change. |
| C2 | Drag a sidebar tab onto the web-area edge | During a sidebar tab drag (`com.open.sidebar.node`, M2 §5.5), `WebContentContainer` shows `SplitDropOverlayView` with four edge zones (left/right for `.horizontal`, top/bottom for `.vertical`; each zone is the outer 25 % of the content area on that side, min 80 pt). Drop on a zone: if the selected node is a tab, `makeSplit([selectedTab, draggedTab])` with the orientation implied by the zone and the dragged tab placed on the dropped side; if already a split, `addPane` at the edge index. Drop in the center 50 %: plain tab switch (select the dragged tab), no split. Esc during drag hides the overlay. |
| C3 | Drag a tab onto another pane / combine | Drop a dragged tab onto an existing pane slot: `addPane` at that pane's index (insert before it). Onto the sidebar split row itself: retarget to C2's center behavior (select the split). Dragging a pane's own tab is refused (model rule). |
| C4 | Context menu | Tab row menu (interaction-states §15 order): "Open in Split View" → `makeSplit([tab, currentTab])` (`.horizontal`, focus the opened tab) or, if the current node is a split, `addPane`. Link context menu in web content ("Open Link in Split View" — needs the engine's link menu hook; until then the menu item exists disabled) → same with a new tab for the link URL. Split-row menu: "Add Pane" (disabled at 4), "Convert to Horizontal/Vertical Split View" (§3.7), "Separate All Tabs" (`unsplit`), "Copy Link" (SV-13: copies pane URLs, one per line). |
| C5 | Command bar action + sidebar plus menu | The command registry already exposes `add-split-view` to the command bar via `makeSuggestRegistry()` (commands.md); no new action id. Sidebar plus button menu (M2 owns the menu; add one item if missing): "New Split View" → C1 with the current tab. |

#### 3.2.1 The empty pane

C1/C5 need a second tab that does not exist yet. Create it first:
`model.newTab(in: spaceID, url: about:blank equivalent, title: "")` —
use the model's new-tab default URL (the same one Cmd+T creates before
the command bar commits; if the model requires a URL, use the Space
profile's new-tab URL, never a hardcoded search URL). Then
`makeSplit([current, new])`. If `makeSplit` refuses (current tab is a
favorite — model rule), beep and delete the just-created tab via
`closeTab` with archive suppressed? No: `closeTab` archives. Instead,
check `model.isPinned(tabID:)`/favorite membership **before** creating
the new tab; if the current tab cannot split, disable C1/C5 up front
(`enabledKey` pattern in commands.md: add `currentTabCanSplit`). Do not
create-then-delete.

### 3.3 Layout (fractions, gaps, minimums)

All geometry is in the container's coordinate space (flipped = false;
AppKit default, origin bottom-left — be consistent; the harness in §9
renders the same space).

- Content area: §5.2 insets. For the captured reference window
  (2216×1394, sidebar 228): panes `[228, 10, 984, 1374]` and
  `[1222, 10, 984, 1374]`, gap 10, width = (contentWidth − 10) / 2
  (MEASURED, F0081). Generalize: with `n` panes there are `n − 1` gaps
  of 10 pt on the split axis; the cross axis fills the content area.
- Fractions: `Split.fractions` holds one Double per pane, sum 1; empty
  means equal. `SplitLayout.frames` algorithm:
  1. `axis = content width (horizontal) or height (vertical)`;
     `usable = axis − gap × (n − 1)`.
  2. `sizes[i] = fractions[i] × usable` (equal fractions if the array
     is empty, mismatched, or sums to ≤ 0).
  3. Clamp: minimum pane size on the split axis is **200 pt** (SV-7
     guess — Arc's value is not in strings; verify at runtime, §10 Q2).
     If `usable < 200 × n`, scale all panes equally below the minimum
     (a narrow window must not produce negative sizes).
  4. Redistribute: after clamping any pane up to 200, subtract the
     deficit from the largest pane(s) in order; repeat at most `n`
     times. Round to whole points; give the rounding remainder to the
     last pane so frames tile exactly with no 1 pt seam.
- Cross-axis minimum: none (panes always fill the content height/width).
- Orientation flip (`setSplitOrientation`) keeps pane order, focus, and
  fractions (fractions now apply to the other axis).

### 3.4 Divider drag

- One `SplitDividerView` per gap, frame = the 10 pt gap strip (full
  cross-axis length), `NSCursor.resizeLeftRight` (horizontal split) or
  `resizeUpDown` (vertical). Hit testing: the view itself is the hit
  target; no extra slop (the gap is already 10 pt).
- Drag: `mouseDown` records the two adjacent pane frames and the start
  fractions; `mouseDragged` live-updates only the two adjacent
  `PaneSlotView` frames (and their hosts' views) — no model write, no
  layout of other panes; clamp each dragged pane to ≥ 200 pt (or the
  §3.3 narrow-window rule). `mouseUp` calls
  `model.setSplitFractions(splitID:fractions:)` once with
  `SplitLayout.fractions(forSizes:)` for **all** panes, then
  `SnapshotStore.scheduleSave` via the App's normal save path (the same
  call every other command makes; if the App saves on any model change,
  no explicit call is needed — match the existing pattern, do not invent
  a second save path).
- Keyboard: with a divider focused (Tab reaches it only when the split
  is selected and the pane chrome is in the key-view loop — v1: dividers
  are **not** in the Tab loop; arrow-key resizing is a follow-up),
  Left/Right (or Up/Down) nudges by 8 pt, Shift+arrow by 32 pt. Skip in
  v1 unless the M2 key-loop makes it free; note it in the PR if skipped.
- During drag, set `window.hasShadow` unchanged; do not disable the
  focus ring (§3.6) — the ring follows the focused pane's live frame.

### 3.5 Per-pane top bar (32 pt; MEASURED F0081)

Each `PaneSlotView` has a `PaneChromeView` at its top: frame
`[x, paneTop, paneWidth, 32]`, web area below it:
`[x, paneTop + 32, paneWidth, paneHeight − 32]` (F0081: bar
`[x, 10, 984, 32]`, web `[x, 42, 984, 1342]` — note the capture's y
origin is top-left in AX; convert once in the harness, §9.3).

Contents (left to right; frames relative to the bar, 32 pt tall):

| Control | Frame | Behavior |
|---|---|---|
| Back | `[5, 4, 32, 24]` (pitch 37) | `host.goBack()`; disabled when `!canGoBack`. |
| Forward | `[42, 4, 32, 24]` | `host.goForward()`; disabled when `!canGoForward`. |
| Reload / Stop | `[79, 4, 32, 24]` | `host.reload()` / `host.stop()` while loading. |
| Copy-link | 24×24, immediately left of the centered host label | Copies `host.currentURL`; toast "Copied Current URL" (M2 toast style, interaction-states §16). |
| Host label | centered, 13 pt Regular (M2 URL-host style) | The page host; click selects all in a mini URL field? No — v1: click focuses the sidebar URL field with this pane's URL (the sidebar field always shows the focused pane, §3.6). |
| Site Control Center | `[w − 105, 2, 32, 28]` | Opens the M6 popover; in v1 show the button, popover disabled with tooltip "Site Control Center". |
| Split View Menu | `[w − 69, 4, 32, 24]` (`square.split.2x1`) | Menu: Add Pane (disabled at 4) · Convert to Horizontal/Vertical · Expand Current Pane (§3.7) · Separate This Pane · Separate All Tabs · Close This Pane. Titles must match the command registry where an id exists. |
| Close pane | `[w − 37, 4, 32, 24]` (`xmark`) | `close-split-pane` for the focused pane; for an unfocused pane, closes that pane (§3.7). |

Visibility rule (MEASURED): the **focused** pane shows all controls;
an **unfocused** pane shows only its Close button at the right. Bar
background: the page's own background color (F0081 lavender → `#DEDEFA`,
white page → white; guess: page theme-color sampling). Until the engine
exposes a page color, use the Space theme's content background token
from `OpenDesign`; add a `// TODO(engine): page theme color` comment.
Single-pane (non-split) layout has **no** pane bar: the sidebar URL
field and toolbar serve the tab, exactly as in M1/M2. The bar appears
only when the selected node is a split.

### 3.6 Focus

- Exactly one pane is focused: `Split.focusedPaneID` (model). The
  focused pane draws a **2 pt ring inside its outer edge**, following
  the 6 pt corner, in the Space accent color (MEASURED F0081: `#3139FF`
  in the unthemed Space; use `SpaceThemeStyle.accent` / the theme's
  `primaryColorPalette.shaded` per design.md §3.1; fallback
  `Core.brandBlue` #3139FB). Implement as a `CAShapeLayer` border on
  the `PaneSlotView` (width 2, inset 1 pt so it sits fully inside),
  updated in `layout()`. Unfocused panes draw no ring.
- Focus actions: click anywhere in a pane (the container's
  `mouseDown` hit-tests the slot first; a click that lands on the web
  view still focuses the pane — install a local `NSEvent` monitor or
  make `PaneSlotView` the first responder proxy; do not rely on the
  web view forwarding clicks), `focus-split-pane-1…4`,
  `next-split-pane` / `previous-split-pane` (wrap around). Each calls
  `model.focusSplitPane(splitID:tabID:)`, which already stamps every
  pane's `lastActiveAt` (model.md) — required by OpenSleep (§7).
- On focus change: `host.focus()` on the newly focused host; the
  sidebar URL field shows the focused pane's host; the window title
  becomes the focused pane's title; `selectNode` is **not** called
  (selection is the split, focus is inside it).
- Sidebar reflection: the split row (M2) renders one cell per pane in
  pane order with favicons; the focused pane's cell uses the
  `TabCellBackgroundContentVisible` token (design-tokens §1.3: white
  0.70 light / 0.15 dark — "the tab whose page is on screen", guess
  confirmed by this use), other cells use `TabCellChildBackground`.
  Selecting the row selects the split with its remembered focus
  (SV-9). If M2's row does not yet distinguish the focused cell, add
  the fill switch in `OpenSidebar` keyed on `split.focusedPaneID`;
  that is the only `OpenSidebar` edit in this milestone.

### 3.7 Pane lifecycle commands (wire to existing ids)

| Command id | Model call | Notes |
|---|---|---|
| `add-split-view` (Ctrl+Shift+=) | §3.2 C1 | Disabled at 4 panes (`currentTabInSplit` + count enabled keys; follow the `CommandDispatcher.isCommandEnabled` pattern in commands.md). |
| `close-split-pane` (Ctrl+Shift+-) | `model.removePane(splitID:tabID:archive: true)` for the **focused** pane | Model collapses a 1-pane remainder automatically. Focus moves per model `takePane` (first remaining pane). |
| Pane-bar Close (unfocused pane) | `removePane(..., archive: true)` with that pane's id | Same collapse rule. |
| `separate-from-split-view` | `removePane(splitID:tabID:archive: false)` for the focused pane | Pane becomes its own row right after the split (model `separatePane`). Then select that tab. |
| `expand-current-split` | No model change. Container-only "maximized pane" state on `SplitViewController`: the focused pane fills the content area, other slots hidden (hosts stay alive, views hidden). Press again (or Esc, or focus another pane via §3.6 keys) to restore fractions layout. SV-11. Do not persist maximized state. |
| Convert (menu only, no id) | `model.setSplitOrientation` (§2.2) | Menu titles "Convert to Horizontal Split View" / "Convert to Vertical Split View" (SV-4 strings). |
| Add Pane (menu only) | `model.addPane` (§2.2) with a new tab created as in §3.2.1 | Disabled at 4 panes. |

Closing the split itself: archiving every pane (sidebar Close on the
split row) is M2/model behavior (`closeTab` on a split archives each
pane, model.md). This milestone adds nothing there.

Undo: every model command above registers its own undo (model.md).
Container-only state (maximized pane) is not undoable.

### 3.8 Keyboard and mouse summary (Split)

| Input | Result |
|---|---|
| Ctrl+Shift+= / Ctrl+Shift+- | Add pane / close focused pane (§3.7). |
| Ctrl+Shift+1…4 | Focus pane 1…4 (no-op beyond pane count). |
| Ctrl+Shift+} / Ctrl+Shift+{ | Next / previous pane (wraps). |
| Click pane | Focus it (§3.6). |
| Drag divider | §3.4. Cursor: resize arrows. |
| Drag tab onto web edge / pane | §3.2 C2/C3. Esc cancels the drag overlay. |
| Double-click divider | Reset the two adjacent panes to equal fractions (live + `setSplitFractions` on mouse-up equivalent). Guess-level nicety; implement, it is 5 lines. |
| Option-click pane Close | Unsplits: `model.unsplit(splitID:)` instead of archiving the pane (SV-10 flag, ship on). |

---

## 4. Peek

Evidence: PK-1…PK-10; MEASURED geometry in interaction-states §12;
Settings labels in interaction-states §18 ("Note: This only affects
Favorites and Pinned tabs").

### 4.1 State (transient, never persisted)

```swift
// App/Peek/PeekController.swift
@MainActor
@Observable
public final class PeekController {
    /// One open Peek. `host` is created for the Peek and destroyed on
    /// dismiss (or handed to the new tab on expand, §4.5).
    public struct PeekItem {
        public let id: UUID
        public var url: URL
        public let sourceTabID: ItemID   // tab the Peek belongs to
        public var host: (any WebContentHost)?  // nil in the harness's model-only mode
    }
    /// Stack for nesting (§4.6). Last element is visible.
    public private(set) var stack: [PeekItem] = []
    public var isOpen: Bool { !stack.isEmpty }

    public func open(url: URL, sourceTabID: ItemID)
    public func dismissTop()          // Esc / close / click-outside
    public func dismissAll()
    public func expandTop()           // §4.5 → returns the new Tab id
    public func openInSplitTop()      // §4.4 third button
}
```

One `PeekController` per browser window, owned by
`BrowserWindowController`. A Peek belongs to its source tab (MEASURED:
selecting another tab hides the Peek; selecting the source tab again
shows it — interaction-states §12). Implement by keeping the controller
alive across selection changes and showing/hiding `PeekOverlayView`
based on `selectedNode == sourceTabID` (for a split source, the split
node id; the Peek's source pane is the focused pane at open time).
Peeks do not survive quit (PK-9) and have no sidebar row. The sidebar
shows a small square badge at the right end of the source row while
its Peek is open (MEASURED F0090 crop): the window controller sets a
transient flag the row reads; if M2 has no such hook, add a
`peekBadgeTabIDs: Set<ItemID>` on the window controller and have the
row's `updateLayer` check it — do not store it in `OpenModel`.

### 4.2 Which clicks open a Peek (trigger rules)

Evaluate in this order for every link click reported by
`WebContentHost.shouldNavigate` (assumption A3). The pure decision
lives in `PeekPolicy.decision` (§2.3) so the CLI can check it (§9.2).

| Trigger | Rule | Setting (Links pane, labels verbatim from §18) |
|---|---|---|
| A — pinned/favorite cross-host (PK-2) | Source tab `isPinned(tabID:)` **or** is a favorite, target canonical host ≠ source canonical host → **Peek**. Same host → navigate in place (the pinned tab's URL protection is per-site, guess boundary §2.3). | "Open a Peek window when clicking on links to other sites" — default **on** (guess; fresh-profile check §10 Q3). |
| B — Shift-click (PK-3) | Shift held, any source tab → **Peek** (even same-host). | "Open a Peek window when clicking on links with Shift held" — default **on** (guess). |
| C — inside a Peek | A click inside the top Peek: same-host → navigate the Peek host; cross-host → push a nested Peek (§4.6). Shift-click inside a Peek → nested Peek regardless of host. | Same two toggles. |
| D — explicit | Link context menu "Open Link in Peek" (add this menu item; no command id, menu-only) and tab context-menu "Peek" on a link? No — D is link-only. Always Peeks, ignores both toggles. | — |
| Never Peek | Opt+Cmd-click (goes to Little Open, R-§9.5 — check it **before** Peek), Cmd-click / middle-click (new tab, existing behavior), clicks with a `download` attribute, `javascript:` / non-http(s) URLs, same-page fragment links (`#…` with identical base URL). | — |

Settings storage: two booleans in `UserDefaults`,
`open.peek.otherSites` (default true) and `open.peek.shiftClick`
(default true), registered at launch like the routing plan's
`open.links.*` keys (R-§10.4 pattern). The Links settings pane binds
them later (designer-owned visuals); this milestone only reads them.

If `shouldNavigate` is unavailable (A3 false): triggers A–C cannot
fire. Ship D only, plus Peek opened programmatically from the command
bar? No — do not invent a command-bar Peek. Note the limitation in the
PR and keep the policy code (it is checked headlessly in §9.2).

### 4.3 The overlay (MEASURED, interaction-states §12)

`PeekOverlayView` is a child of `WebContentContainer`, above all pane
slots, below nothing else. It has three parts:

```text
PeekOverlayView (fills the container)
├── ScrimView        (fills the container; the dim)
├── PeekPanelView    (the page panel; hosts the Peek host.view)
│   └── (Peek host view fills the panel; no pane chrome, no top bar)
└── PeekButtonView × 3 (outside the panel's right edge)
```

Metrics (window 2216×1394, sidebar 228 — generalize exactly as written):

| Part | Value |
|---|---|
| Panel frame | Width = **80 % of (window width − sidebar width)** = 0.8 × 1988 = **1590 pt**; height = content height − 4 (2 pt inside the content panel top and bottom, MEASURED: panel `[427, 12, 1590, 1370]` against content `[228, 10, 1988, 1374]`). Centered horizontally in the content area (center x = content center). When the sidebar is hidden, use (window width − 20) as the base (content = full inset width, §5.2). |
| Panel corner | Radius ≈ 6–7 pt (MEASURED). Use 6, matching the web panel (§5.2). Shadow: light, ≈ 16 pt wide (MEASURED row profile). `shadowColor` black, `shadowOpacity` 0.18, `shadowRadius` 8, offset (0, 2) — fitted guess; the harness (§9.3) compares it. |
| Scrim | The whole window behind the Peek (sidebar, margins, page) dims to ≈ 70 % of a dark, theme-tinted color (MEASURED fit ≈ `#0E0019` in Space 4; guess: from the Space theme). Implement as a view covering the **window content view** (not just the container — the sidebar dims too), fill = theme dark background (`dark.background` semantic color) at alpha 0.70. If the theme has no dark palette, use black at 0.55. Scrim receives clicks (§4.4). |
| Buttons | Three round buttons, diameter **33 pt** (MEASURED `[2030, 21, 35, 33]` — draw 33, hit frame 35). Placed **13 pt right of the panel's right edge**, tops at panel top + 9, + 52, + 95 (43 pt pitch). Dark circle fill (theme `light.title` at full strength, like tooltips), white glyph centered. Order top→bottom: **Close** (`xmark`, AX id `confirmCloseModal`, "Close"), **Expand** (`arrow.up.left.and.arrow.down.right` — "Enter Full Screen", AX `openInSpaceExpander`), **Split** (`square.split.2x1`, AX `openInSplit`). The `peeked-modal-controls-alternate-order-enabled` flag (PK-5) may swap Expand/Close; ship the measured order, flag off. Buttons stay visible while the page loads (MEASURED: black panel + buttons before first paint, F0089). |
| Loading state | Panel fill black (or theme dark background) until the Peek host's first `onLoadingChange(false)`; then the host view fades in over 0.12 s. |

Open animation: panel + buttons fade in and scale from 0.98 → 1.0
centered on the panel center, 0.18 s ease-out; scrim fades 0 → 0.70
over the same duration. These values are guesses (no timing capture
exists, interaction-states §19 item 1); put them in `OpenDesign`
motion tokens (`Motion.peekOpen`) so a future capture changes one
place. Dismiss is the reverse at 0.14 s. Respect
`NSWorkspace.shared.accessibilityDisplayOptions.reduceMotion`: no
scale, scrim fade only.

### 4.4 Dismiss, expand, open-in-split

| Action | Behavior |
|---|---|
| Close button / Esc / click scrim | `dismissTop()`: animate out (§4.3), destroy the Peek host (`host.close()`), pop the stack. If the stack empties, hide the overlay and return focus to the source tab's host. No tab is created (PK-7). Show the close-undo toast (PK-7: "Undo prompt for re-opening a closed Peek" — string-proven, behavior guessed): toast "Peek closed" with an "Undo" button for 5 s (M2 toast style); Undo reopens the same URL as a Peek on the same source tab. One undo slot; a second dismiss replaces it. |
| Expand button | §4.5. |
| Split button (`openInSplit`) | Promote the Peek into a split with its source tab: if the source is a plain tab, `model.makeSplit([sourceTab, peekTab])` where `peekTab` is a new Today tab created with the Peek's current URL (then reparent the Peek host onto it per A2, or load fresh if A2 false); focus the new pane. If the source is already in a split with < 4 panes, `addPane` instead. If the split is at 4 panes, beep and keep the Peek open. Then dismiss the Peek chrome (the page now lives in the pane). This button's exact Arc semantics are unverified (§10 Q4) — the above is the only reading consistent with its name and glyph; mark it `// Guess: PK split semantics` in code. |
| `open-in-current-space` (Cmd+O) while a Peek is topmost | "Move Little Open or Peek to Space…" opens the Space menu; choosing a Space expands the Peek into that Space's Today (top) instead of the current Space (§4.5 with an explicit target). R-§9.5 wires the same command for Little Open; the App delegate dispatches by key window / topmost surface. |

Esc handling: `PeekController` installs a local key monitor while the
stack is non-empty; Esc dismisses the top Peek and is consumed. When
a Peek is maximized-split or mid-expand animation, Esc is ignored
until the animation completes (0.18 s window).

### 4.5 Expand into a real tab (PK-6)

1. Create the tab: `model.newTab(in: targetSpaceID, url: peekCurrentURL,
   title: peekTitle, at: 0)` — Today, top (PK-6). `targetSpaceID` is
   the window's focused Space (or the Cmd+O-chosen Space, §4.4).
2. Hand over the page (guess PK-6, verify §10 Q5): if A2 holds,
   reparent the Peek host's view into the new tab's pane slot and
   rebind the container's host map to the new tab id — no reload,
   scroll/form state survive. If A2 fails, `host.close()` the Peek
   host and create a fresh host for the tab with its current URL
   (a reload; note it in the PR).
3. Select the new tab (`selectNode`), focus its host.
4. Animate: the Peek panel's frame interpolates to the target pane
   slot's frame in the container (0.22 s ease-in-out, panel corner
   6 → 6, scrim fades out in the first 0.12 s, buttons fade out
   immediately). Implement by animating a snapshot/clone container?
   No — animate the actual `PeekPanelView` frame inside the overlay,
   then on completion remove the overlay and reveal the real pane
   slot (which already holds the reparented host). The two views hold
   the same host view only at the handoff instant; during the
   animation the overlay owns it, the slot shows a placeholder
   (§5.5) painted with the tab's title. Keep the animation
   interruptible: a second Esc during expand cancels back to the
   Peek state (host stays in the overlay).
5. The source (pinned/favorite) tab never navigates (PK-6).

History after expand: the tab's host keeps the Peek's history stack
(A4). `canGoBack` reflects pages visited inside the Peek.

### 4.6 Nesting and history inside a Peek

- Following a cross-host link inside a Peek pushes a new `PeekItem`
  (stack depth + 1, PK-8 guess). Only the top item's panel is shown;
  the panel cross-fades to the new page (0.12 s). Depth cap: **5**.
  At the cap, cross-host clicks navigate the top Peek in place
  (no deeper stack) — a v1 guard against unbounded nesting; log it.
- Back/Forward inside a Peek: the Peek host's own history (A4).
  Cmd+[ / Cmd+] route to the top Peek host while a Peek is open
  (before the sidebar tab's host). At the start of the Peek's
  history, Back does nothing (it does not dismiss the Peek).
- Each stack item keeps its own host alive (hidden) so Back across a
  nest boundary restores the earlier page without reload. Memory:
  at most 5 hidden hosts per window; acceptable for v1.
- Dismiss pops one level (revealing the previous Peek); Esc at
  depth 1 closes the Peek entirely. The close-undo toast (§4.4)
  reopens at depth 1 with the popped URL.

---

## 5. Web content container (shared)

The single container every surface in this milestone renders into.
Build it before Split and Peek (Step 2); Little Open reuses its
single-pane mode (§6.3).

### 5.1 Type and ownership

```swift
// App/WebContent/WebContentContainer.swift
@MainActor
public final class WebContentContainer: NSView {
    public init(factory: any WebContentHostFactory)
    /// Show these tabs as panes (1 = single, 2–4 = split).
    /// `focusedTabID` must be in `tabIDs`. Hosts are created lazily
    /// (§5.4) and cached by tab id across calls.
    public func show(tabIDs: [ItemID], focusedTabID: ItemID,
                     orientation: SplitOrientation, fractions: [Double],
                     spaceID: SpaceID, profileID: ProfileID)
    /// Live divider drag (§3.4): update two adjacent slots only.
    public func setLivePaneFrames(_ frames: [CGRect])
    public func host(for tabID: ItemID) -> (any WebContentHost)?
    public func focus(tabID: ItemID)
    public var onPaneClicked: ((ItemID) -> Void)?   // → §3.6 focus
    public var onLinkClicked: ((ItemID, URL, NSEvent.ModifierFlags) -> Bool)? // → §4.2/§6.5
}
```

`PaneSlotView` (private to the file or its own file — implementer's
choice, one type): `NSView` with `paneChrome: PaneChromeView?` (nil in
single mode), `contentHostView: NSView?`, `placeholderView:
PlaceholderContentView?`, and the focus-ring layer (§3.6). Exactly one
of `contentHostView` / `placeholderView` is visible at a time (§5.5).

The container owns a host cache: `[ItemID: any WebContentHost]`. It
creates a host only through the injected factory, never directly.
`BrowserWindowController` owns one container per window;
`LittleOpenWindowController` owns one in single-pane mode (§6.3).

### 5.2 Panel look (MEASURED, runtime-observations §1.2)

| Property | Value |
|---|---|
| Content area | `x = sidebarWidth` (or 10 when the sidebar is hidden), `y = 10`, `width = windowWidth − x − 10`, `height = windowHeight − 20`. Top/right/bottom insets are 10 pt; the left edge abuts the sidebar (8 pt gap to sidebar items, derived). |
| Pane corner | Radius **6 pt** (measured fit; circular vs. continuous is indistinguishable at 1x — use a circular `cornerRadius = 6` with `masksToBounds` on the slot's clip layer). |
| Shadow | Black, opacity **0.25**, `shadowRadius` 3, offset (0, +1 down) — `0 1px 6px rgba(0,0,0,.25)` (measured least-squares fit, runtime-observations §1.2). In AppKit (non-flipped): `shadowOffset = (0, -1)`. Apply on the slot's outer layer, never on the host view itself (the engine view must not be masked twice). |
| Border | None (measured: no 1 px line at 1x). |
| Empty state | White at ≈ 10 % over the window gradient (measured). The placeholder (§5.5) paints this; a loaded page is opaque. |
| Divider gap | 10 pt of window background shows between panes (the `ThemeBackgroundView` gradient). Do not paint dividers; the gap **is** the divider (§3.4 views are transparent hit areas). |

Use `OpenDesign` tokens where they exist (`Metrics` web panel row in
design.md §2.2: `[W, 10, winW − W − 10, winH − 20]`, radius 6, shadow
black 0.25 radius 3 offset 1). If a token is missing, add it to
`OpenDesign` — do not hardcode a second copy in the container.

### 5.3 Host lifecycle and callback wiring

- `show(...)` diffs the requested tab list against the current slots:
  removed tabs → remove their slot views (hosts stay in the cache,
  views detached — reparenting per A2); added tabs → create slots.
  Reorder without recreating slots (pane order is model order).
- Each host's callbacks are set once at creation, capturing the tab id
  and a generation counter (A7 guard). `onURLChange` → update the
  `Tab.url` through the App's existing engine-to-model bridge (the
  same path M1 uses for the sidebar URL field; if no bridge exists
  yet, write `tab.url` directly and note it). `onTitleChange` →
  `tab.title` + window title if focused. `onLoadingChange` /
  `onFaviconChange` → `tab.live` fields (never persisted, model.md).
- `shouldNavigate` → `onLinkClicked` (§4.2 Peek policy first, then
  Opt+Cmd-click → Little Open, §6.5; return the policy result).
- Visibility: a host whose slot is not in the current `show(...)` set
  is hidden. The container does not sleep tabs — it only reports
  visibility (§7); `OpenSleep` decides freeze/discard via its engine
  adapter (separate from `WebContentHost`; do not merge the two
  protocols).

### 5.4 Lazy creation (performance budgets, architecture.md)

- Create a host the first time its tab becomes visible (single-pane
  selection, any pane of a selected split, a Peek, a Little Open
  page). Never create hosts for unselected sidebar tabs.
- On `show(...)` for a split, create the **focused** pane's host
  first (same run-loop turn), then the remaining panes' hosts in pane
  order on the next run-loop turn (placeholders until then, §5.5).
  This keeps tab switch ≤ 16 ms for the focused pane (A6).
- Keep at most the visible hosts plus the most recently hidden **8**
  hosts alive (LRU by last-visible time); `close()` the rest. 8 is a
  v1 constant (`WebContentContainer.maxCachedHiddenHosts`); tune only
  with a measured reason. Split panes of a background Space count as
  hidden.

### 5.5 Sleeping and placeholder rendering

`Tab.live.sleepPhase` (`OpenModel.TabLiveState`, S0): `.placeholder`
(never loaded), `.live`, `.frozen`, `.sleeping`. The container renders
per phase — it does not drive transitions (OpenSleep does):

| Phase | Slot content |
|---|---|
| `.placeholder` | `PlaceholderContentView`: panel fill (white 10 % over gradient in the empty state; for a tab with a URL, the theme content background), centered favicon (from `tab.live.faviconPNG`; letter tile per design.md §4 if absent), title (14 pt Regular, theme title color), host (13 pt, secondary). No spinner. |
| `.live` | The host view. |
| `.frozen` | The host view, untouched (frozen pages still paint their last frame). If the engine cannot paint a frozen view (verify with the real adapter), fall back to a snapshot: capture `host.view` into an `NSImage` at freeze time (the SleepEngine adapter notifies the container — add a `freezeSnapshotProvider` closure only if the real engine needs it; the fake host always paints, so the harness cannot prove this path — mark it [NEEDS ENGINE]). |
| `.sleeping` (discarded) | `PlaceholderContentView` as above, plus a small "Sleeping" caption? No — Arc shows title/favicon only. Keep the placeholder identical; the sidebar already conveys state. On the tab becoming visible, OpenSleep wakes it (`SleepEngine.createContent` with the stored history envelope); the container swaps placeholder → host view when the App reports the phase back to `.live`. The swap happens in `show(...)` by re-reading `tab.live.sleepPhase` — poll-free: the App calls `container.refreshPlaceholders()` from its sleep-phase observer. Add that one public method. |

Inside a split, each pane independently follows this table (a split
can show two live panes, one frozen, one placeholder). In a Peek, a
sleeping source tab is irrelevant — the Peek host is always `.live`
while visible (§7 keeps it awake).

### 5.6 Animated transitions (single ↔ split)

All layout changes go through one method,
`layoutPanes(animated:)`, using `NSAnimationContext` (duration in
`OpenDesign.Motion`):

| Transition | Animation |
|---|---|
| Single → split (C1–C4) | New pane slots slide/scale in from the split edge: existing pane's frame interpolates to its fraction frame, new pane fades in at its fraction frame. 0.22 s ease-in-out (`Motion.splitExpand`). |
| Split → single (collapse, unsplit, close-to-one) | Leaving slots fade out (0.14 s) while the survivor's frame interpolates to the full content area (0.22 s). |
| Add/remove pane | Same interpolation for all affected slots; unaffected slots do not move. |
| Orientation flip | Frames interpolate (no rotation — panes swap axes linearly). 0.22 s. |
| Divider drag | No animation (direct frame sets, §3.4). |
| Focus change | No layout animation; only the ring (§3.6) moves (layer frame update, 0.08 s fade of the ring opacity). |
| Window resize | No animation; `layout()` recomputes from fractions. |

Implementation rule: animate `PaneSlotView` frames (and their hosted
views follow via autoresizing). Never animate a host view's own frame
directly — CEF/native views resize on their slot's bounds. During any
animated transition, disable divider hit-testing and pane clicks;
re-enable on completion. `reduceMotion`: all durations become 0
(instant layout, no fades).

---

## 6. Little Open window

Normative source: routing-little-open.md §9 (R-§9). This section lists
the M4 deltas only. Read R-§9.1–§9.7 before writing any Little Open
code; do not respecify its types.

### 6.1 What already applies (do not rebuild)

- `LittleOpenSession` (one page, one `Tab` outside any Space,
  `profileID`, `lastActiveAt`), `LittleOpenCoordinator`
  (`open(url:profileHint:)`, `openBlank(focusURLField:)`,
  `moveToSpace(sessionID:spaceID:)`, `close(sessionID:archiveReason:)`,
  `showAll()`, `closeAll()`, `archiveExpired(now:)`) — R-§9.1/§9.2,
  including URL dedupe/resurface, the blank-reuse rule, and the
  profile-switch confirmation (LA-7).
- Window: content size **720×540** default (guess — LA open Q1;
  `LittleBrowserWindow_size` value unknown), minimum 360×240, centered
  on the mouse display first time, cascade 24 pt after, shared
  autosave frame `LittleOpenWindow`, 40 pt toolbar (back/forward/
  reload, URL field, profile indicator, downloads disabled, Open in
  Space) — R-§9.3 table. Title = page title, or "Little Open" when
  blank.
- Move to Space: R-§9.4's 7-step algorithm (current-URL dedupe walk,
  Today-top placement via `model.newTab(in:url:title:at: 0)`, focus or
  create the main window, select, then close Little Open). User-visible
  verb: **"Open in Space"** (menu title "Open in Space"; the command
  title stays "Move Little Open or Peek to Space…", §0.3 item 2).
- Entry points: external-link routing (R-§8.7), global hotkey
  (`GlobalHotkeyService`, Cmd+Opt+N, only while
  `open.links.littleOpenHotkeyEnabled`), File-menu twin
  (`new-little-open-window`), Opt+Cmd-click (gated by
  `open.links.optionCommandClickLittleOpen` + engine hook A3),
  Dock/Window Show/Close All — R-§9.5 table, including the
  double-fire guard via blank-reuse.
- Auto-archive: 60 s sweeper, per-profile
  `settings.littleOpenAutoArchiveAfter` (default 6 h), archive reason
  `.autoArchived`, `originalLocation: "littleOpen:<id>"` — R-§9.6.
  Manual close does **not** archive in v1 (R-§9.3).
- No-main-window table: R-§9.7 is normative (Little Open alone never
  creates a main window; Open in Space does; quitting archives
  nothing).

### 6.2 M4 delta — its tab list

Little Open has no tab strip (LA-1). The "tab list" for this milestone
is the coordinator's session list (R-§9.1: most-recently-active
first), surfaced in exactly two places:

1. Window menu section "Little Open Windows": one item per live
   session (page title, or "Little Open" when blank), choosing it
   resurfaces that window (`makeKeyAndOrderFront` + `lastActiveAt`
   stamp). Rebuild the section on every session create/close/retitle
   (observe the coordinator; no polling).
2. `showAll()` / `closeAll()` (R-§9.2) act on the same list.

Do not add a list UI inside the Little Open window.

### 6.3 M4 delta — web content hosting

`LittleOpenWindowController` hosts its page with a
`WebContentContainer` in single-pane mode (§5), created with the
session's profile factory. The container's `show(tabIDs: [sessionTab],
...)` gives Little Open the panel look for free: content insets 10,
radius 6, shadow (§5.2) inside the 720×540 window below the 40 pt
toolbar. Placeholder rendering (§5.5) applies while the first page
loads. On profile switch (R-§9.2), close the old host and call
`show` again with the new profile's host — the container's cache key
is the tab id, so add a `profileID` parameter change path: simplest
correct approach is a fresh container per profile switch (containers
are cheap; hosts are not shared across profiles). Document the choice
in the controller comment.

### 6.4 M4 delta — global hotkey and first-run

- Register `little-open-global` exactly as R-§9.5 (Carbon signature
  `'OPEN'`, id 1, already in `GlobalHotkeyService`). Re-register on
  shortcut change or toggle; `unregister()` when off. While Open is
  frontmost the window-scope twin (same keys) may also fire — the
  coordinator's blank-reuse makes the second call harmless; do not
  add a second guard.
- First-run intro (LA-9, R-§9.3): dismissible one-line banner in the
  first Little Open window, our own words, gate
  `open.links.littleOpenNUXSeen`. Show once per install.

### 6.5 M4 delta — intake and default browser

Phase B intake (R-§8.2–§8.7) is part of this milestone's App work
because Little Open is its main destination: Info.plist URL types,
`applicationWillFinishLaunching` AppleEvent handler, the
`kAEGetURL` + `application(_:open:)` funnel into
`ExternalLinkIntake`, `DefaultBrowserService.makeDefault()` wired to
`set-default-browser`, `SourceAppResolver` (PID → bundle id),
2-second dedupe, cold-launch queue, per-link `RoutingSnapshot` from
`NSApp.windows` front-to-back. Implement from R-§8 verbatim; this
plan adds nothing except: the intake's `LinkDestinationExecutor`
`openInLittleOpen` calls `LittleOpenCoordinator.open(url:profileHint:)`,
and `openInSpace` focuses-or-creates the main window exactly as
R-§9.4 step 5. If the App target + engine are not ready when the rest
of M4 lands, this delta is the [NEEDS ENGINE]/App-target tail (Step 8)
and must not block Steps 1–7.

---

## 7. Visibility reporting to OpenSleep

Contract: `OpenSleep/SleepEngine.swift` —
`SleepVisibilityProviding.sleepVisibility() -> SleepVisibilitySnapshot`
(read once per 5-second controller pass; sleep.md: "The app calls
visibility hooks immediately after selection/window/surface changes").
`visibleTabIDs(in:)` already: unions `peek ∪ littleOpen ∪ splitPanes ∪
pictureInPicture`, then for each `.visible` window adds its selected
node (expanding a selected split to **every** pane). Missing/closed
windows contribute nothing. PiP protects a tab even when its parent
window is minimized.

### 7.1 Implementer (in `BrowserWindowController` / App coordinator)

The App owns one provider object (e.g. `AppVisibilityProvider`) that
the `SleepController` is initialized with. It aggregates every window
controller + the `LittleOpenCoordinator` + every `PeekController`:

```swift
@MainActor
final class AppVisibilityProvider: SleepVisibilityProviding {
    func sleepVisibility() -> SleepVisibilitySnapshot {
        var windows: [WindowID: SleepVisibilitySnapshot.WindowState] = [:]
        var peek: Set<ItemID> = []
        var littleOpen: Set<ItemID> = []
        var splitPanes: Set<ItemID> = []
        for controller in browserWindowControllers {
            windows[controller.windowID] = controller.sleepWindowState
                // .visible if window.isVisible && !isMiniaturized && !occluded;
                // .minimized if miniaturized; .occluded if visible but fully
                // covered (NSWindow.occlusionState); .closed if no window.
            if let topPeek = controller.peekController.stack.last {
                peek.insert(topPeek.hostTabID)  // see below
            }
            // splitPanes is filled by visibleTabIDs(in:) from the selection;
            // leave empty here unless a split is shown in a surface the
            // selection does not cover (none in v1 — keep the set empty and
            // rely on the selection expansion; filling it twice is harmless
            // because the snapshot unions sets).
        }
        for session in littleOpenCoordinator.sessions where session.windowIsVisible {
            littleOpen.insert(session.tab.id)
        }
        return SleepVisibilitySnapshot(windows: windows, peek: peek,
                                       littleOpen: littleOpen,
                                       splitPanes: splitPanes,
                                       pictureInPicture: pipTabIDs)
    }
}
```

Rules:

- **Peek tab id.** A Peek page is not a sidebar `Tab`, so it has no
  `ItemID` in the model. Give each `PeekItem` a stable `hostTabID:
  ItemID` (a fresh UUID at open, never inserted into the model) and
  use it both as the `WebContentHost`'s `tabID` and in the `peek`
  set. `OpenSleep` only compares ids against model tabs for its
  freeze/discard decisions; an id with no model tab is inert there,
  but the snapshot contract ("Extra surface sets contain only
  actually shown tabs", sleep.md) is honored and a future sleep phase
  for Peek hosts can key on it. The **source** tab of a visible Peek
  needs no extra entry: it is the selected node of a visible window,
  already counted. If the source window is minimized while its Peek
  is open, the Peek is hidden with it (§4.1) — do not report it.
- **Split panes.** Rely on `visibleTabIDs(in:)`'s selection expansion
  (a selected split in a visible window → all panes visible). Do not
  also enumerate panes into `splitPanes` — duplicate union entries
  are harmless but obscure the contract. The one exception: while a
  split is in the "maximized pane" state (§3.7), the hidden panes are
  still reported visible (they are one keystroke away and their hosts
  stay alive). That matches "every pane in a selected split of a
  visible window counts as visible" (sleep.md). Do not optimize it.
- **Little Open.** Only sessions whose window is visible and not
  minimized contribute. A Little Open page is always live while its
  window is visible (it is the window's only page).
- **Hooks.** Call the sleep controller's visibility hooks (the
  `tabBecameVisible`/`tabBecameHidden` equivalents on
  `SleepController` — read its public API; S0 names them visibility
  hooks) immediately after: selection change, split focus change
  (focus stamps all panes, model.md — visibility itself does not
  change, but the activity stamp does), Peek open/dismiss/expand,
  Little Open create/close/miniaturize, window minimize/occlusion
  change. Also rebuild on `NSWindow` occlusion/miniaturize
  notifications. No timer in the provider; the controller's own
  5-second pass re-reads the snapshot (sleep.md).
- **Quit.** `captureAllForQuit()` includes all live split panes
  (sleep.md hard contract). The container's host cache (§5.4) must
  not `close()` a pane host before that capture runs — order the App
  quit path: sleep quit-capture first, container teardown second.

### 7.2 What this milestone does not change

`OpenSleep` policy, phases, timers, and the OPNH history container are
S0-complete. This milestone supplies inputs only. If
`SleepController` is not yet instantiated in the App when M4 lands,
implement the provider anyway and unit-check it through the harness
(§9.2 check V1); wiring the controller is a one-line App-delegate
change whenever S6 lands.

---

## 8. Engine adapter [NEEDS ENGINE]

One file: `App/WebContent/EngineWebContentHost.swift`. It conforms
the real `OpenEngine` object to `WebContentHost` (§1.1), exactly as
the routing plan's adapter rule (R-§7): adapt at the adapter, never
redesign controllers. Contents:

- Factory: map `ProfileID` → the profile's request context / data
  directory (`Profile.dataDirectoryName`), create the engine view,
  return the host wrapper. Cache one engine browser per host.
- Forward `load/reload/stop/goBack/goForward/focus/close` 1:1.
- Translate engine delegate callbacks into the closure properties;
  enforce A7 (no callbacks after `close()`) with a `closed` flag.
- `shouldNavigate`: wire the engine's navigation-decision hook if it
  exists; otherwise leave nil (A3 fallback, §4.2).
- Sleep bridge: the same engine object separately conforms to
  `OpenSleep.SleepEngine` (S0 protocol) in
  `App/WebContent/EngineSleepAdapter.swift` — a second file, also
  [NEEDS ENGINE]. Do not merge it into `WebContentHost`.

Until this file exists, the App and harness run on
`FakeWebContentHost` (§1.3). Every step before Step 9 is verifiable
without the engine.

---

## 9. Acceptance (no unit tests — AGENTS.md rule 6)

Three layers. A step in §10 is done only when its layer's checks pass.

### 9.1 Harness: `features-render` (new executable, sidebar-render style)

Mirror `sidebar-render` (design.md §6): an offscreen borderless window
that is never shown, composed scene rendered through a deep copy of
the layer tree by `CARenderer` into a Metal texture, PNG out. Add to
`Package.swift`:

```swift
.executable(name: "features-render", targets: ["features-render"]),
.executableTarget(name: "features-render",
    dependencies: ["OpenModel", "OpenStore", "OpenFeatures", "OpenDesign", "OpenSidebar"]),
```

The target also compiles `App/WebContent/FakeWebContentHost.swift`,
`WebContentContainer.swift`, `PaneChromeView.swift`,
`PlaceholderContentView.swift`, `App/Split/*`, `App/Peek/*` as
sources (link the files, do not copy them — use target `sources` or a
shared `AppShared` library target if the App target already factored
one; if neither exists, create the files under
`Packages/OpenKit/Sources/features-render/Scene/` and have the App
target link that library instead. Pick whichever keeps exactly one
copy of each file; state the choice in the PR.)

Commands:

```text
features-render split   --snapshot DIR --out FILE.png [--size WxH] [--scale 1|2]
                        [--space N] [--select-node ID] [--fractions "0.5,0.5"]
                        [--orientation horizontal|vertical] [--focus-pane N]
features-render peek    --snapshot DIR --out FILE.png [--size WxH]
                        [--source-tab ID] [--peek-url URL] [--depth N]
features-render little  --out FILE.png [--size 720x540] [--url URL]
features-render compare --arc CAPTURE.png --ours RENDER.png --out DIR
features-render check   # scripted interaction checks (§9.2), exit ≠ 0 on failure
features-render bench   # layout pass over 4 panes, 200 iterations
```

Rendering defaults: window 2216×1394 (the capture size), sidebar 228,
scale 1. Fake hosts paint distinct solid colors per tab with the host
string centered, so pane assignment errors are visible by eye and by
pixel sampling.

### 9.2 Scripted interaction checks (`features-render check`)

Drive the real views with the fake host (colored `NSView`s) in the
offscreen window. No engine. Each check prints PASS/FAIL and the
command exits non-zero on any failure. Implement at least:

| ID | Check |
|---|---|
| S1 | `SplitLayout.frames` for 2/3/4 panes, both orientations, equal + custom fractions, narrow container (< 200×n): frames tile exactly, gaps 10, no negative sizes. |
| S2 | Create split via C1 on a fake model (2 tabs): model has one split, 2 panes, focus = new pane; container shows 2 slots with the right fake-host colors in the right slots. |
| S3 | Divider drag (synthesized `NSEvent`s or direct `setLivePaneFrames` + `setSplitFractions`): fractions persist to the model and sum to 1; reload the snapshot (`openkit roundtrip`) and confirm fractions survive. |
| S4 | Focus: click pane 2 (synthesized mouse event at its center) → `focusedPaneID` = pane 2, ring layer on slot 2 only, sidebar URL-field host = pane 2's host. Keys `focus-split-pane-1`, next/previous wrap correctly. |
| S5 | Close focused pane → split collapses per model rule; container shows 1 slot, no pane bar. Separate pane → new sidebar row after the split, selected. Expand (maximize) → focused slot fills the content area; Esc restores fraction frames. |
| S6 | Cap: add panes to 4; the 5th add (menu + `addPane`) refuses, no model change, no 5th slot. Orientation flip keeps order/focus/fractions sum. |
| P1 | `PeekPolicy.decision` table: pinned+cross-host→peek, pinned+same-host→navigate, today+shift→peek, today+plain→navigate, toggles off→navigate, Opt+Cmd→not-peek (Little Open wins). |
| P2 | Open Peek on a pinned source: overlay visible, panel width = 0.8×(W−sidebar) ±1 pt, buttons at the §4.3 offsets, scrim present. Esc dismisses; host closed; source tab URL unchanged. |
| P3 | Expand: new Today tab at index 0 with the Peek URL, selected; Peek host reparented (same fake-host instance, click counter preserved); overlay gone. |
| P4 | Nesting: cross-host click inside Peek pushes depth 2; Esc pops to depth 1 (first Peek page visible again). Depth cap 5 enforced. Undo toast reopens the dismissed URL as a Peek. |
| P5 | Source-tab persistence: open Peek, select another tab (overlay hides), reselect source (overlay shows, same host instance). |
| L1 | Little Open: `open(url:)` creates one 720×540 window controller; opening the same canonical URL again resurfaces it (session count unchanged). `openBlank` twice reuses the blank session. |
| L2 | Move to Space: `moveToSpace` creates a Today-top tab with the current URL, selects it, closes the session; with the URL already in the Space, selects the existing tab instead (no duplicate). With no main window, one is created (model window count + 1) — model-level assertion only in the harness. |
| L3 | Auto-archive: a session with `lastActiveAt` older than its profile threshold archives via `archiveExpired` (fake `ArchiveSink` records one entry, `originalLocation` has the `littleOpen:` prefix); a fresh session does not. |
| V1 | Visibility: with a split selected in a visible window, a Peek open, and one Little Open session visible, `sleepVisibility().visibleTabIDs(in: model)` contains every split pane + the Peek source tab; minimize the window (set state directly) → split panes drop out, Peek drops out. |
| C1 | Container: `show` with 1 tab → 1 slot, no pane bar, insets §5.2; `show` with 4 tabs → 4 slots; hidden-host LRU closes the 9th hidden host. Placeholder: a `.sleeping` tab shows `PlaceholderContentView` (no host created); flipping its phase to `.live` + `refreshPlaceholders()` swaps in the host view. |

### 9.3 Offscreen render checks vs. captured frames

Captured frames are in the session index
(`.re/runtime/sessions/index-20261024.json`, interaction-states §0):
Split View = full-session frames **F0081–F0082** (also F0079 for the
sidebar split row), Peek = **F0089** (loading), **F0090–F0097** (open),
**F0102** (Peek restored with its source tab), **F0108–F0114** (pointer
over Peek buttons). Raw frames live in `.re/` (git-ignored) — never
commit them; commit only the comparison report numbers.

Method (same as design.md §7, reuse `sidebar-render compare`'s
plane-fit/ink/ΔE approach inside `features-render compare`):

1. Build the same state from the capture-time snapshot copies
   (`openkit import-arc` on the `.re` copies, as in design.md §7
   step 1): Space 4, the seeded split of two tabs selected (F0081);
   the folder tab with its Peek open (F0090).
2. Render at 2216×1394, sidebar 228, scale 1 with fake hosts. Mask
   the web page contents (the pages differ by construction — fake
   colors vs. real pages), the traffic lights, and window corners,
   exactly as design.md §7 masks the web panel.
3. Compare the unmasked chrome: pane frames (±1 pt), the 32 pt bars,
   button frames, the 2 pt focus ring presence/color (ΔE00 ≤ 2 on
   the ring's core pixels), Peek panel frame (±1 pt), button circle
   positions (±1 pt), scrim dimming (sample the sidebar area: our
   scrim composite vs. the captured ≈ 70 % fit, ±5 %).
4. Targets (design.md §8): layout error ≤ 1 pt, fill/text ΔE00 ≤ 2.
   Report a `table.md` + side-by-side PNG per state, in the PR
   description (not committed, except the numbers in §11's log).

The AX frames in the captures use a top-left y origin; our AppKit
frames are bottom-left. Convert once (`y' = H − y − h`) in the
compare tool and assert the F0081 pane pair
(`[228, 10, 984, 1374]` / `[1222, 10, 984, 1374]` top-left) matches
our two slots before comparing pixels.

### 9.4 App-phase checks [NEEDS ENGINE + automation channel]

Once `EngineWebContentHost` (§8) and the automation channel
(architecture.md Testing: open URLs, read tab/sidebar state, run JS,
capture PNGs — never drive the user's desktop) exist:

| ID | Check |
|---|---|
| E1 | Real pages in a 2-pane split: both render, focused pane accepts typing, Back/Forward act per pane. |
| E2 | Real cross-host click in a pinned tab opens a Peek with the real page; Expand keeps scroll position (A2/A4 verification). |
| E3 | Opt+Cmd-click opens Little Open (A3 verification); the global hotkey opens a blank Little Open while another app is frontmost. |
| E4 | `open https://example.com` from Terminal with Open as default browser routes per R-§8.7 (Little Open vs. Space). |
| E5 | Sleep integration: leave a split unselected past the freeze/discard delays; panes show placeholders, reselecting wakes them with history intact. |

These checks gate the M4 PR's "engine" follow-up, not Steps 1–8. If
the engine is not ready when Steps 1–8 pass, merge M4 on the fake-host
checks and track E1–E5 in the PR as follow-ups — do not hold the
layout/behavior work hostage to the engine schedule.

---

## 10. Step-by-step order (files + acceptance per step)

Work in order. A step is done only when its acceptance passes.
`swift build` for the package is always:
`nice -n 10 swift build -c release -j 6` in `Packages/OpenKit`
(the repo's established command; keep zero warnings/errors).

| Step | Work | Acceptance |
|---|---|---|
| 1 | `OpenFeatures` target + `SplitLayout` + `PeekPolicy` (§2.1, §2.3); model commands `addPane`/`setSplitFractions`/`setSplitOrientation` (§2.2). No AppKit. | Package builds clean. `openkit commands-demo` still passes (66/66 baseline); add split-command coverage to the demo's synthetic flow if it has a natural home — otherwise verify via a `/tmp` probe binary against the release modules (never commit probes). |
| 2 | `WebContentHost` + `FakeWebContentHost` (§1) and `WebContentContainer` + `PaneChromeView` + `PlaceholderContentView` (§5) in single-pane mode, hosted by `features-render`. | `features-render split --fractions "1"` renders one pane with §5.2 insets/radius/shadow; check C1 (single-pane half) passes. |
| 3 | Split layout in the container: `show` with 2–4 panes, `SplitLayout` frames, divider views + drag (§3.3–§3.4), focus ring (§3.6). | Checks S1, S3, S4 pass; render check §9.3 for F0081 pane geometry passes (frames ±1 pt). |
| 4 | Split lifecycle: `SplitViewController`, creation paths C1/C4/C5, pane commands (§3.7), sidebar focus reflection (§3.6). | Checks S2, S5, S6 pass. C2/C3 drag paths: implement the overlay + drop; verify with synthesized dragging events in the harness if supported, else by calling the drop handler directly with a dragged tab id (state which in the PR). |
| 5 | Peek: `PeekController` + `PeekOverlayView` (§4), policy wiring, expand/nesting, undo toast. | Checks P1–P5 pass; render check §9.3 for F0090 (panel/buttons/scrim) passes. |
| 6 | Little Open: R-§9.1–§9.3 session/coordinator/window on the §5 container, Window-menu session list (§6.2), sweeper (§6.1). | Checks L1–L3 pass. No intake yet (Step 8). |
| 7 | Visibility: `AppVisibilityProvider` (§7) + hooks. | Check V1 passes. `openkit sleep-demo` still passes (105 checks baseline). |
| 8 | Intake + default browser [App target]: R-§8.2–§8.7, global hotkey wiring (R-§9.5), Opt+Cmd-click (if A3). | Routing checks A1–A17 (`openkit route`, routing.md) still pass. Manual: quit, relaunch, `open https://example.com` from a terminal routes as decided; global hotkey opens a blank Little Open from another app. State the bundle id used. |
| 9 | Engine adapter [NEEDS ENGINE]: `EngineWebContentHost` + `EngineSleepAdapter` (§8); verify assumptions A1–A7, record each verdict in §11. | App-phase checks E1–E5 (§9.4) through the automation channel. Any failed assumption gets its §1.2 fallback; update this plan's §11 and the PR. |
| 10 | Polish: motion tokens vs. a future timing capture (interaction-states §19 item 1), `reduceMotion`, narrow-window split (< 800 pt content: panes below 200 pt scale equally per §3.3), sidebar-hidden Peek width (§4.3). | Full pass: package build, `commands-dump` (exit 0), `openkit roundtrip`, `features-render check` all-pass, both render comparisons within targets. No regression in `sidebar-render check` if that harness exists on the branch. |

### 10.1 Open questions (verify; do not block Steps 1–7)

| # | Question | Current default in this plan |
|---|---|---|
| Q1 | PK-2 "other sites": exact host vs. registrable domain? (features-advanced PK open Q1) | Exact canonical host (§2.3). |
| Q2 | Minimum pane size (SV open Q2)? | 200 pt (§3.3). |
| Q3 | Peek toggle defaults (PK §2.2)? | Both on (§4.2). |
| Q4 | Peek Split-button semantics (glyph-proven only)? | §4.4 guess; marked in code. |
| Q5 | Expand keeps page state (PK open Q4)? | Yes via reparenting (A2); reload fallback noted. |
| Q6 | Focus after closing the focused pane: model `takePane` picks the first remaining pane — left/top neighbor? | Model behavior as built; verify against Arc (SV open Q5) later. |
| Q7 | Little Open default size/position (LA open Q1)? | 720×540 centered/cascade (R-§9.3 guess). |
| Q8 | Divider keyboard resizing? | Skipped in v1 (§3.4). |

---

## 11. Verification log (fill in as steps land)

Record: date, builder (model), build command + result, each check id
with PASS/FAIL, render-comparison worst position/ΔE per state, and
the A1–A7 verdicts from Step 9. Keep raw harness output and fixture
snapshot copies outside the repo (`.re/` or `/tmp`), counts and
numbers only here — the same discipline as routing.md and sleep.md.

| Step | Date | Result |
|---|---|---|
| 1 | | |
| 2 | | |
| 3 | | |
| 4 | | |
| 5 | | |
| 6 | | |
| 7 | | |
| 8 | | |
| 9 | | |
| 10 | | |






## Appendix — Lead decisions (2026-10-25)

- Q1: Peek triggers for a different registrable domain (eTLD+1 via the Public Suffix List in OpenSuggest), not a different exact host: `docs.github.com` from a `github.com` pinned tab stays in the tab.
- Q2: 200 pt pane minimum accepted.
- Q3: Peek enabled by default for pinned tabs and favorites.
- Q4: Peek's Split button opens the peeked page as a split pane next to the current tab (the peek closes).
- Q5: Expand moves the same live web content into the new tab (no reload; page state preserved). If the engine cannot reparent, reload with restored history (fallback).
- Q6–Q7: stated defaults accepted (720×540 Little Open).
- Sequencing: Steps 1–7 start after PR #33 (OpenDesign/OpenSidebar) merges; Steps 8–9 after the App target + engine.
