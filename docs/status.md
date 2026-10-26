# Open v1 status inventory

Audit date: 2026-10-25 (America/Vancouver). Base: `origin/main` at `f41955c` (includes PR #46 fork bring-up, PR #50 M4 visual finish, and five PRs that merged during the audit: #51 Settings + Library, #54 release locales, #55 license inventory, #56 Settings polish, #59 media + PiP plan).
Open work read with `git` (not edited): PR #45 `f11822b`, PR #52 `6c4e7ee`, PR #53 `a03d2a5`, plus the title and file list of PR #57.

This file lists every v1 line item from the RE catalog (`docs/re/`), the AGENTS.md v1 scope, and the platform basics a browser needs. For each item it names the plan, the library code, the App wiring, and the evidence. It is an inventory. It changes no code.

## 0. How to read this file

### 0.1 Status values

| Status | Meaning |
|---|---|
| **done** | A user can use it in the app built from `main` today. On `main` the App is still the plain M1 shell (`App/BrowserWindowController.swift`: table-view tab list, address field). So "done" often means "works in the M1 shell, without Arc's look". |
| **in PR** | It works in the real app of an open PR (#45, #52, #53), or its code is in an open PR (#57). |
| **planned** | A plan names the missing part. Library code can already exist on `main` (for example all of `OpenSettings` from #51, which no App code shows yet). "Plan in progress" means a plan that another agent is writing now (§0.3). |
| **unplanned** | No plan covers the missing part. Library code can exist (the note says so). |
| **out of scope** | Excluded by AGENTS.md (accounts, sync, Easels, Notes, Arc Max) or by a lead decision. Listed only so nobody builds it by accident. |

"(partial)" after a status means part of the row works and the note says which part.

### 0.2 Short names

- RE docs: **FC** `re/features-core.md`, **FA** `re/features-advanced.md`, **MH** `re/menus-and-hotkeys.md`, **IS** `re/interaction-states.md`, **DM** `re/data-model.md`, **DT** `re/design-tokens.md`, **RO** `re/runtime-observations.md`. "r9" means rule 9 in that section.
- Plans (`docs/plans/`): `app-shell`, `media-pip`, `m4` (`m4-split-peek-littleopen`), `routing` (`routing-little-open`), `profiles`, `settings` (`settings-library`), `boosts-zap`, `adblock-fork`, `memory-fork`, `import2` (`import-phase2`), `applescript`, `first-run`, `release`, `fork-infra`. Step letters (Step C, Step E…) are app-shell §7 steps.
- Library paths are under `Packages/OpenKit/Sources/`.
- App wiring: **main** (M1 shell on `main`), **PR #45/#52/#53** (real app of that PR), **none**.
- Harness checks run in this audit (§6): `sidebar-render check` 125/125, `features-render check` 147/147, `commandbar-render check` 78/78, `commands-dump` OK, `settings-preview check`, and `tools/verify-all.sh`. Check IDs such as `features-render S3` come from the check output.
- e2e suites: `tools/e2e/engine_e2e.py --only <suite>`. On `main`: `shell`, `features`, `extensions`, `measure`. PR #52 adds `window`, `sidebar`, `peek`. PR #53 adds `tabstrip`. Results: `docs/engine-spike/results-*.json` on the named branch.

### 0.3 Work in flight that this file counts

| Work | Where | Counted as |
|---|---|---|
| App shell Step A (window before engine) | PR #45, branch `t3/app-shell-startup-window` | in PR |
| App shell Step B (real window, live sidebar) | PR #52, branch `t3/app-shell-real-window` (includes Step A) | in PR |
| App shell Step C (menus, keys, command bar) | uncommitted edits in worktree `t3-d8b5b30a`, branch `t3/app-shell-commands` (no commits beyond PR #52) | planned (in progress); not counted as wired |
| Settings + Library | PR #51, merged to `main` as `dc62e65` during this audit; changes no `App/` file | planned (library on `main`; App wiring in app-shell §4.11 and settings Step 8) |
| Settings polish | PR #56, merged to `main` as `c95be65` during this audit (`OpenSettings` only) | counted with Settings + Library |
| Release Steps 1/3 | PR #54, merged to `main` as `724e35d` during this audit (`tools/release-locales.txt`) | planned (partial) |
| Release Step 9 | PR #55, merged to `main` as `f41955c` during this audit (`docs/release/licenses.md`, `tools/generate-acknowledgements.py`) | planned (partial) |
| Release Step 11 | PR #57 (`tools/release.sh`) | in PR |
| Extensions P1 tab-strip bridge | PR #53, branch `m7/ext-p1-tabstrip` | in PR |
| Space creation + theme editor plan | branch `plan/space-theme-editor` | plan in progress |
| Site Control Center + Boost editor plan | branch `plans/site-control-boost-editor` | plan in progress |
| Media controls + Picture in Picture plan | PR #59, merged to `main` as `211a8bb` during this audit (`docs/plans/media-pip.md`) | planned (rows cite `media-pip`) |
| Extensions UI plan | branch `t3/extensions-ui-plan` | plan in progress |

I did not read the in-progress plans. Where a row says "plan in progress", the scope match comes from the plan's title, not its text. The media plan merged before this PR, so its rows cite its text (`media-pip` below).

### 0.4 Headline

- Almost every OpenKit library for v1 exists on `main` and passes its harness. The gap is App wiring. On `main` the App links only `OpenModel`, `OpenStore`, `OpenWeb`, and `OpenFeatures` (`project.yml`, target `Open`). PR #52 adds `OpenSidebar` and `OpenDesign`.
- No `App/` file on `main` or in PR #52 uses `MenuBuilder`, `CommandBarController`, `SuggestEngine`, `HistoryStore`, `FaviconStore`, `BoostStore`, `AdBlockStore`, `SleepController`, `ScriptHost`, `RoutingEvaluator`, or `GlobalHotkeyService` (`git grep` on both trees). These land in app-shell Steps C–H. PR #52 reaches `KeyboardRouter` only inside `OpenFeatures.BrowserWindowController`, for split, Peek, and back/forward keys.
- Biggest unplanned gaps: Open's own password manager, writing imported Arc passwords and cookies into Open, and the dispatch of system menu items (Cut, Copy, Paste, Quit…) once `MenuBuilder` replaces the M1 menu (§3).

Row count by status (282 rows in §1; a "(partial)" row counts under its base status):

| Area | done | in PR | planned | unplanned | out of scope |
|---|---:|---:|---:|---:|---:|
| 1.1 Sidebar | 0 | 17 | 4 | 7 | 0 |
| 1.2 Spaces | 2 | 7 | 4 | 3 | 2 |
| 1.3 Tabs | 7 | 5 | 11 | 6 | 0 |
| 1.4 Favorites | 1 | 4 | 0 | 0 | 0 |
| 1.5 Folders | 0 | 4 | 1 | 3 | 0 |
| 1.6 Archive | 1 | 0 | 3 | 1 | 0 |
| 1.7 Command bar | 0 | 0 | 11 | 5 | 0 |
| 1.8 Menus and hotkeys | 0 | 2 | 5 | 1 | 0 |
| 1.9 Split View, Peek, Little Open | 0 | 15 | 12 | 1 | 1 |
| 1.10 Profiles | 0 | 2 | 8 | 0 | 0 |
| 1.11 Air Traffic Control | 0 | 0 | 5 | 1 | 0 |
| 1.12 Boosts and Zap | 0 | 0 | 7 | 1 | 1 |
| 1.13 Site Control Center | 0 | 0 | 8 | 1 | 0 |
| 1.14 Ad blocking | 0 | 0 | 6 | 1 | 0 |
| 1.15 Import from Arc | 0 | 0 | 10 | 2 | 1 |
| 1.16 Extensions | 3 | 2 | 4 | 2 | 0 |
| 1.17 Engine and platform basics | 9 | 2 | 19 | 15 | 1 |
| 1.18 Settings and Library | 0 | 0 | 10 | 0 | 2 |
| 1.19 First run | 0 | 0 | 4 | 0 | 0 |
| 1.20 Release | 0 | 1 | 8 | 0 | 0 |
| **Total** | **23** | **61** | **140** | **50** | **8** |

## 1. Feature tables

Columns: feature · RE doc + section · plan · library code · App wiring · verified how · status · notes.

### 1.1 Sidebar: window chrome, rows, controls

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Arc window chrome: hidden title bar, system traffic lights, theme background, inset rounded web panel (10 pt, radius 6, shadow) | FC §8.2 r7; RO §1.1–1.2 | app-shell §3.1–3.2 | `OpenDesign/ThemeBackgroundView.swift`, `OpenDesign/Metrics.swift` (`WindowMetrics`, `PanelMetrics`) | PR #52 | e2e `window` (PR #52, 38 functional PASS); live static compare vs capture F0001: 31 elements, worst 1.0 pt, ΔE00 1.61 (`docs/app-shell.md`, PR #52) | in PR | `main` shows the M1 window. |
| Section order: Favorites, Pinned, divider, New Tab row, Today | FC §1.1 r1–5; IS §6 | `docs/design.md` §5 | `OpenSidebar/SpacePageView.swift`, `OpenSidebar/FavoritesView.swift` | PR #52 | `sidebar-render check`; e2e `sidebar` 18/18 (PR #52) | in PR | |
| Tab row states: hover fill, selected fill and shadow, close ×, "−" on loaded pinned rows | FC §1.2 r8, r11; IS §3 | design.md §5.3 | `OpenSidebar/SidebarRows.swift` | PR #52 | `sidebar-render check`; design.md §8 (ΔE ≤ 2.03) | in PR | |
| Engine favicon on loaded rows | FC §1.2 r8 | app-shell §4.13 | — | PR #52 | none named (`docs/app-shell.md` Step B: favicon events update model slices) | in PR | |
| Stored favicons for unloaded and imported rows | FC §1.2 r8 | app-shell §4.8 (Step H) | `OpenStore/FaviconStore.swift`, `OpenStore/FaviconFetcher.swift` | none | verify-all `favicons` | planned | |
| Per-tab audio icon and mute button | FC §1.2 r10 | app-shell §4.1; media-pip | `SidebarRows.swift`; model `setMuted` | PR #52 (`toggleMute` sets host `isMuted`) | e2e `features` "Audible state and mute" (`docs/engine-spike.md`) | in PR | Web Audio is missed until engine patch P6 (planned, `docs/engine-patches.md`). |
| Mute all tabs / Unmute all tabs | FC §1.2 r10, §4.4 | media-pip (command-bar actions) | `OpenCommands/CommandRegistry.swift` (`mute-all-tabs`, `unmute-all-tabs`, no menu) | none | `commands-dump` (registered) | planned | Not in the app-shell §4.3 table. |
| Recording indicator on rows (camera or microphone in use) | FC §1.2 r10 (2026-10-25 update); FA §8 | media-pip | none | none | none | planned | |
| Tidy titles for known sites (for example Gmail fragment → "Inbox") | FC §1.2 r9 | none | none | none | none | unplanned | Non-AI rule table. |
| Unread badge on rows added in the background | FC §1.2 r12 | none | model field `Tab.isUnread` (`OpenModel/LiveNodes.swift`), set by import; the sidebar does not draw it | none | none | unplanned (partial) | |
| Hover Previews of folder, pinned, and favorite rows | FC §1.2 r13; IS §18 General | settings §5.1 (switch and Previews sheet only) | `OpenSettings` switch | none | none | unplanned (behavior) | |
| Rename a row inline (double-click, "Rename…", Return, Esc) | FC §1.3 r15–16 | design.md §5.6 | `SpacePageView.swift` (`doubleAction` → `beginRename`); model `renameNode` | PR #52 (model intent) | `sidebar-render check` (menus); no e2e check | in PR | |
| Row context menus: Today tab, pinned tab, favorite, folder, split row, Space, plus | IS §15; MH "Context menus", "Split row menu" | design.md §5.6 | `OpenSidebar/SidebarMenus.swift` | PR #52 (partial) | `sidebar-render check` (order for 4 targets) | in PR (partial) | PR #52 returns `false` for 16 intents: Site Control, Library, Manage Spaces, Space icon, theme, New Profile, Share Space, Export into Folder, Edit Pinned URL, Share, Change Icon, Customize Page, Duplicate, Copy All Links, Turn Folder into Space, Move to New Space (`App/WebContent/EngineWebContentHostFactory.swift` `performSidebar`, PR #52). Favorite and plus menus are guesses (design.md §5.6). |
| Multi-select rows (Shift/Cmd click) and New Folder from Selection | FC §1.5 r24; MH "Gestures and mouse" | none | none: the outline uses single selection (`SpacePageView.swift`); model `createFolder(withNodes:)` already takes several nodes | none | none | unplanned | |
| Drag and drop: reorder, Today ↔ Pinned (pin/unpin), into folders, Favorites, URLs from other apps, Space icon hover-switch | FC §1.6 r28–32 | design.md §5.5 | `OpenSidebar/DragDrop.swift`; model `canMoveNode` | PR #52 | `sidebar-render check` (drop mapping, cross-Space drag, refusals); e2e `sidebar` (reorder through the production intent) | in PR | No test drives a real macOS drag session (`docs/app-shell.md`, PR #52). |
| Haptic feedback when reordering | FC §1.6 r33; IS §18 Advanced | settings (switch only) | `OpenSettings` switch | none | none | unplanned (behavior) | |
| Show/Hide Sidebar (Cmd+S) with 0.22 s animation | FC §1.7 r35–36; IS §13 | app-shell §3.3 | `OpenFeatures/BrowserWindowController.swift` | PR #52; main (M1 list toggle) | e2e `window` (PR #52) | in PR | |
| Hover-reveal card while hidden | IS §13 | app-shell §3.3 | `OpenFeatures/BrowserWindowController.swift`, `OpenFeatures/SidebarRevealController.swift` | PR #52, window-chrome PR | e2e `window` (`hide_reveal`, `fullscreen_hover_reveal`, `reveal_timing`, `card_edges_*`) | in PR | Zones and the 0.15 s dwell decoded (IS §13); exit delay and slide motion are guesses. |
| Resize 228–500 pt; drag past 180 pt hides | FC §1.7 r36; IS §13 | app-shell §3.3 (D4) | `OpenDesign` `WindowMetrics` | PR #52 | e2e `window` (drag to 300 pt, limits, hide) | in PR | 180 pt is a guess (app-shell Q3). |
| Hint toast on first hide ("You can use ⌘S…") | IS §13 | none | none | none | none | unplanned | |
| URL pill: host, Copy button, Site Control button; click opens Cmd+L | FC §4.1 r2; IS §3 | app-shell §3.5 (Step C) | `OpenSidebar/ChromeViews.swift` | PR #52 (click opens a temporary URL editor until Step C) | `sidebar-render check` (click reaches the delegate) | in PR (partial) | |
| Toolbar row: toggle, back, forward, reload; a split keeps only the toggle | IS §11; design.md §15 | design.md | `ChromeViews.swift` | PR #52 | `sidebar-render check` | in PR | |
| Bottom bar: Home (Library), Space switcher, plus menu | FC §1.1 r6, §1.8 r41; FA SP-1; IS §5 | design.md | `OpenSidebar/BottomBarView.swift` | PR #52 (Home is refused until Library is wired) | `sidebar-render check` | in PR (partial) | |
| Tooltips: capsule, keycaps, placement | IS §5 | design.md §5.6 | `OpenSidebar/Tooltip.swift` | PR #52 | `sidebar-render check` (one schedule per hover) | in PR | 0.6 s delay is a guess. |
| Inactive-window glyph tones | design.md §5.3 | app-shell §3.1 | `OpenSidebar` | PR #52 | `sidebar-render` inactive comparison (design.md §8) | in PR | |
| Row accessibility and keyboard navigation | — (Open requirement) | design.md §14 | `OpenSidebar` | PR #52 | `sidebar-render check` (AX dump, key events) | in PR | |
| Sidebar media controls (mini player stack above the bottom bar) | FA §8 (PP-6, PP-20) | media-pip (D-1, D-3) | none (new `OpenMedia` library planned, media-pip D-10) | none | none | planned | |
| Edge-swipe gesture to hide the sidebar | MH "Gestures" (`hideSidebarWithGesture`) | none | none | none | none | unplanned | |

### 1.2 Spaces

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Space model: name, icon, theme, one profile; at least one Space; "Space N" fallback | FC §2.1 r1–3 | `docs/model.md` | `OpenModel/Containers.swift`; `BrowserModel.displayTitle(for:)` | PR #52 | `openkit commands-demo` (verify-all) | in PR | |
| Switcher in the bottom bar (current in color, others gray 0.55) | FC §2.5 r14 | design.md §5.3 | `BottomBarView.swift` | PR #52 | `sidebar-render check` | in PR | |
| Switch by click: page slide, theme cross-fade, content swaps at once | FC §2.4 r12; IS §10 | design.md §5.4 | `OpenSidebar/SpacePagerView.swift` | PR #52 | `sidebar-render check` (pager and theme); e2e `sidebar` (Space switch) | in PR | Duration is a guess (IS §10). |
| Two-finger swipe between Spaces | MH "Gestures" | design.md §5.4 | `SpacePagerView.swift` | PR #52 | `sidebar-render check` (swipe; short swipe snaps back) | in PR | |
| Next/Previous Space (Cmd+Opt+→/←) | MH Spaces | app-shell §4.3 | — | main (M1 `cycleSpace`), PR #52 | none (code read: `App/MainMenu.swift`) | done | |
| Go to Space 1–9 (Ctrl+1…9) | MH "Shortcuts that live in code" (keys are a guess) | app-shell §4.3 (Step C) | registry `go-to-space-1…9` | none | `commands-dump` | planned | |
| Last active tab per Space | FC §2.4 r13 | — | model `selectedNodeBySpace` | main, PR #52 | e2e `window` (restores selections, PR #52) | done | |
| New Space flow: name, icon, theme, profile | FC §2.2 r4 | plan in progress: Space creation + theme editor | model `createSpace` | PR #52 creates a Space titled "Space" with no flow | none | planned | |
| Rename Space inline (header double-click, menu) | FC §2.2 r5 | design.md | `SpacePageView.swift` header `beginRename`; model `updateSpace` | PR #52 | none | in PR | Spaces ▸ Rename Space has no dispatch (§2). |
| Change Space icon (emoji and symbol picker) | FC §2.3 r9 | plan in progress (the Space creation flow includes an icon per FC §2.2 r4; scope not confirmed) | model `SpaceIcon`; `OpenModel/NamedSpaceIcons.swift` | PR #52 refuses `changeSpaceIcon` | none | planned | |
| Theme rendering: gradient, grain, light/dark content | FC §2.3 r10; DT §6; RO §3.3 | design.md §3 | `OpenDesign/ThemeField.swift`, `Grain.swift`, `SpaceThemeStyle.swift` | PR #52 | `sidebar-render check`; design.md §8 per-state ΔE | in PR | Light-mode default theme is a guess (design.md §9). |
| Theme editor popover: color pad, presets, intensity, grain, text mode | IS §14 | plan in progress: Space creation + theme editor | none | PR #52 refuses `editSpaceTheme` | none | planned | |
| Delete Space: archive its tabs, Undo | FC §2.2 r6 | model.md | model `deleteSpace(archiveTabs:)` with undo | PR #52 (model intent) | `openkit commands-demo` | in PR | |
| Delete Space confirmation alert | FC §2.2 r6 | none | none | none | none | unplanned | Today one menu click archives every tab of the Space. |
| Reorder Spaces; Space Manager (Manage Spaces…) | FC §2.2 r8 | none | model `moveSpace(id:to:)` and intent `moveSpace`; no view sends it | none | `openkit commands-demo` (model) | unplanned (partial) | |
| Turn Space into folder; Export Space into folder; Turn folder into Space | FC §2.2 r7; IS §15 | none | intents and menu items only; no model command | PR #52 refuses | none | unplanned | |
| Share Space | FC §2.2 r5 | — | menu item exists in `SidebarMenus.swift` | refused | — | out of scope | Account feature. The menu item is visible. |
| Live Folders | FC §1.5 r27 | — | — | — | — | out of scope | FC marks it not required for v1. |

### 1.3 Tabs: pinned and Today lifecycle

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| New Today tab at the top, under New Tab | IS §6, §9.3 | — | model `newTab` (index 0) | main, PR #52 | `openkit commands-demo` | done | |
| New Tab opens the command bar, not a blank page | FC §3.5 r18 | app-shell §3.5, §4.2 (Step C) | `OpenCommandBar` | main: address field; PR #52: temporary URL editor; Step C uncommitted | `commandbar-render check` | planned | |
| A new window opens with the command bar open | FC §3.5 r19; IS §17 | `docs/commandbar.md` §10 item 1; app-shell §3.5 | `OpenCommandBar` | none | none | planned | |
| Pin/unpin; the pinned URL is the URL at pin time | FC §3.2 r9 | model.md | model `pinTab`, `unpinTab` | main (Cmd+D), PR #52 | e2e `sidebar` (engine pin flag, PR #52) | done | |
| "/" mark when a pinned tab left its pinned URL | IS §3 | design.md §15 | `SidebarRows.swift` | PR #52 | `sidebar-render check` | in PR | |
| Reset tab to its pinned URL | FC §3.2 r3–4 | app-shell §4.1 | model `resetPinnedTab` | PR #52 | none | in PR | |
| Close and keep pinned (unload) | FC §3.2 r5 | app-shell §4.1 | — | main (M1 close unloads pinned tabs), PR #52 ("−" button) | e2e `sidebar` (pinned unload and wake) | done | |
| Replace pinned URL with current | FC §3.2 r6 | — | model `replacePinnedURL` | PR #52 | `openkit commands-demo` | in PR | |
| Edit pinned URL dialog | FC §3.2 r3 | app-shell §4.1 (command bar in edit mode) | intent `editPinnedURL` | PR #52 refuses | none | planned | |
| Separate From Pinned Tab | FC §3.2 r7 | none | none | none | none | unplanned | |
| Reset all tabs in this Space | FC §3.2 r8 | none | registry `reset-all-tabs-in-space`; the model resets one tab | none | none | unplanned | |
| Archive Tab (Cmd+W): Today archives; pinned and favorite unload | FC §1.2 r11, §3.3 r14 | — | model `closeTab`; `OpenStore/ProfileArchiveSink.swift` | main, PR #52 | e2e `shell` (main); e2e `sidebar` (PR #52) | done | |
| Restore Last Closed Tab (Cmd+Shift+T), same tab ID | MH File | — | `OpenStore/ArchiveStore.swift`; model `restoreArchivedTab` | main, PR #52 | e2e `shell` | done | |
| Today auto-archive after the threshold | FC §3.3 r10–13 | none for the App timer: app-shell §4.4 plans only the Little Open sweeper | model `archiveExpiredTabs(now:)` (`OpenModel/BrowserModel.swift`) | none: no caller in `App/` on `main` or PR #52 | `openkit commands-demo` ("archiveExpiredTabs with a fake clock"), `openkit bench` | unplanned (wiring) | See §3, gap 4. |
| Thresholds Never/1h/6h/12h/24h/7d/30d; per profile; default 12 h; Little Open 6 h | FC §3.3 r11–12; IS §18 | settings §5.2 | model `AutoArchiveInterval`, `ProfileSettings`; archive-scope sheet in `OpenSettings` | none | `settings-preview check` | planned | |
| Auto-archive education banner | FC §3.3 r15 | none | none | none | none | unplanned | |
| Clear Today (divider "Clear", Cmd+Shift+K) with Undo | FC §1.8 r40; IS §6 | app-shell §4.3 (key) | model `clearToday` with undo; Clear control in `SidebarRows.swift` | PR #52 (Clear control); key in Step C | `sidebar-render check` (clear and undo); e2e `sidebar` | in PR | |
| Clear unselected Today tabs | FC §1.8 r40 | none | none | none | none | unplanned | |
| Duplicate tab, folder, or split | FC §1.4 r18 | app-shell §4.3 lists `duplicate-tab` as a model command | intent and registry only; `BrowserModel` has no duplicate command | PR #52 refuses | none | planned (partial) | The model command is missing. |
| Next/Previous Tab (Cmd+Opt+↓/↑) | MH Tabs | app-shell §4.3 | — | main, PR #52 | none (code read) | done | |
| Cycle Tab Forward/Backward (Cmd+Ctrl+→/←) | MH Tabs | app-shell §4.3 | registry | none | `commands-dump` | planned | |
| Tab Switcher (Ctrl+Tab), most-recent order | MH Tabs (`cycleToNextRecentTab:`) | app-shell §4.3 (order not specified) | registry | main and PR #52 bind it to sidebar order | none | planned (partial) | Recent-order behavior is not specified in any plan. |
| Go to tab 1–9 and last (Cmd+1…9); "Include Favorites" option | MH code-only table; FC §7.2 Shortcuts | app-shell §4.3; settings Shortcuts | registry `go-to-tab-1…9`, `go-to-last-tab`; options UI in `OpenSettings/ShortcutsPane.swift` | none | `commands-dump` | planned | |
| Reveal Current Tab (Ctrl+Space) and Reveal Tab in Sidebar | MH View, Tabs | app-shell §4.3 (`reveal-current-tab`) | registry has `reveal-current-tab`; Tabs ▸ "Reveal Tab in Sidebar" is not registered | none | `commands-dump` cannot see the missing item (§2.3) | planned (partial) | |
| Lazy loading: only the selected tab loads at launch | `docs/architecture.md` tactics | app-shell §5 | `OpenFeatures/WebContentContainer.swift` | main, PR #52 | e2e `shell` (main); e2e `window` (PR #52) | done | |
| Placeholder for unloaded and sleeping tabs | `docs/memory-design.md` §2 | app-shell §3.4 | `OpenFeatures/PlaceholderContentView.swift` | PR #52 | `features-render check`; e2e `sidebar` | in PR | |
| Tab sleeping: freeze 30 s, discard by mode, never-sleep gates | FC §3.4 r16; memory-design §5 | app-shell §4.7 (Step G); memory-fork S1–S6 | `OpenSleep/SleepPolicy.swift`, `SleepController.swift` | none | verify-all `sleep-demo` (148/148) | planned | |
| Keep-alive sites never frozen or discarded (Gmail, Slack, Notion, Spotify, calendar, chat) | FC §3.4 r16 (`keepaliveAllowList`) | sleep.md; settings-library §2 | `OpenSleep/KeepAliveRules.swift`, `SleepPolicy.swift`, `SleepController.swift` | app-shell Step G | verify-all `sleep-demo` | done in this PR (library) | Built-in rules plus x.com and per-profile additions. Native notifications remain unverified. See §3, gap 5. |
| Battery Saver uses the aggressive discard time | FC §3.4 r17 | memory-design §5 | — | none | none | planned | |

### 1.4 Favorites

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Favorites grid per profile, shared by that profile's Spaces | FC §2.1 r1; IS §4 | design.md | `FavoritesView.swift`; model `Profile.favorites` | PR #52 | `sidebar-render check` (add, remove, 32 seeded permutations) | in PR | Column rule for counts other than 6 is a guess (design.md §9). |
| Add, remove, reorder by drag; "Remove from Favorites" | FC §1.4 r20, §1.6 r30 | design.md §5.5 | model `addFavorite`, `removeFavorite` (favorites move, never copy) | PR #52 | `sidebar-render check` | in PR | |
| Select a favorite; closing unloads it and keeps the tile | FC §1.2 r11 | app-shell §4.1 | — | main, PR #52 | e2e `sidebar` (PR #52) | done | |
| Favorite tile hover state and context menu | IS §4, §15 (not captured) | design.md §5.6 (guess) | `FavoritesView.swift`, `SidebarMenus.swift` | PR #52 | `sidebar-render check` | in PR (guess) | Needs a capture (§5.2). |
| Links in a favorite open Peek | FA PK-2 | m4 §4 | `OpenFeatures/PeekPolicy.swift` | PR #52 | `features-render P1`; e2e `peek` 6/6 (PR #52) | in PR | |

### 1.5 Folders

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Folders in Pinned or Today; nested; collapse state persists | FC §1.5 r21–23 | design.md | model `createFolder`, `setExpanded`; `SidebarRows.swift` | PR #52 | `sidebar-render check`; e2e `sidebar` (folder collapse) | in PR | |
| New Folder (menus; Cmd+Shift+N with the sidebar focused) and New Nested Folder | FC §1.5 r24; IS §15 | app-shell §4.3 (key) | intents `newFolder`, `newNestedFolder`; registry `new-folder` | PR #52 (menus); key in Step C | `sidebar-render check` | in PR (partial) | |
| Delete folder archives its tabs | FC §1.5 r25 | — | model `deleteFolder` (reason `folderDeleted`) | PR #52 | `openkit commands-demo` | in PR | FC asks for a confirmation ("Deleting this folder will archive the tabs inside it."); none is built or planned. |
| Expand and collapse animation | IS §7 | design.md §5.7 | `OpenSidebar` | PR #52 | `sidebar-render` forced-animation frames | in PR | Timing is provisional. |
| Expand All Folders / Collapse All Folders | FC §1.5 r23 | none | registry only | none | none | unplanned | |
| Copy All Links (plain, Markdown) | IS §15 | app-shell §4.1 | intent `copyAllLinks` | PR #52 refuses | none | planned | |
| Archive a whole folder; restore it as a folder | FC §1.5 r26 | none (settings §6.2 shows folder records as tab rows) | `ArchiveStore` stores tab records | none | none | unplanned | `docs/settings.md`: "Current archive folder deletions are individual tab records". |
| Change Icon… for folders and pinned tabs | IS §15; FC §1.5 r21 | none (PR #52 refuses `changeIcon`) | intent only | none | none | unplanned | The in-progress Space plan may cover icon picking; not confirmed. |

### 1.6 Archive

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Archive store per profile (SQLite); reasons closed, auto, cleared, folder deleted | FC §3.6; DM "Archive and session files" | model.md | `OpenStore/ArchiveStore.swift`, `ProfileArchiveSink.swift` | main (M1 close writes it) | verify-all `roundtrip`, `commands-demo` | done | |
| Library ▸ Archive: search, Space filter, restore with toast and View, delete, Clear Archive with confirmation | FC §3.6 r20–23 | settings §6.2 (App step = app-shell) | `OpenSettings/ArchiveSection.swift`, `LibraryViewModel.swift` | none (#51 changed no `App/` file) | `settings-preview check` | planned | Rows show reason and "Little Open"; a filter by close type or Little Open is not confirmed. |
| View Archive menu command | MH Archive | settings adapter table (`docs/settings.md`) | registry `view-archive` | none | — | planned | |
| Clear Archive menu command | MH Archive | none (the `OpenSettings` Library has the button, not the command) | registry `clear-archive` | none | — | unplanned (partial) | |
| Archive empty state | FC §3.6 r23 | settings | `OpenSettings` | none | `settings-preview` (empty-state renders) | planned | |

### 1.7 Command bar

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Panel UI: centered overlay, 50 pt rows, theme selection color | IS §9.1–9.2 | `docs/commandbar.md` | `OpenCommandBar/*`, `OpenDesign/CommandBarTokens.swift` | none (Step C uncommitted) | `commandbar-render check` 78/78; commandbar.md §8 comparisons | planned | |
| Cmd+T new-tab mode; Cmd+L edit-current-URL mode (URL selected) | FC §4.1 r1; IS §9.3 | app-shell §3.5, §4.2 | `CommandBarController.swift` | none | `commandbar-render check` (Cmd+T and Cmd+L flows) | planned | |
| Esc closes; click outside dismisses; focus returns to the page | FC §4.1 r3 | app-shell §3.5 | `CommandBarController.swift` | none | `commandbar-render check` | planned | |
| Sources: what you typed, open tabs of the profile, pinned and favorites, history, remote suggestions, calculator, actions, Site Search | FC §4.2 r4 | `docs/suggest.md` | `OpenSuggest/Providers.swift` and siblings | none | verify-all `suggest-check` (31/31) | planned | |
| Results stay inside the current profile | FC §4.2 r5 | suggest.md "Modes" | `OpenSuggest` | none | `suggest-check` | planned | |
| Ranking and dedupe hosts | FC §4.3 r6–7 | suggest.md "Ranking" | `OpenSuggest/Ranking.swift` | none | `suggest-check` | planned | Empty Cmd+T order differs from Arc (commandbar.md §10 gap 1). |
| Inline autocomplete in the field | IS §9.3 | none (commandbar.md §10 gap 3) | none | none | none | unplanned | |
| One row per Split View ("Switch to Split View") | FC §4.2 r4; suggest.md Q1 | none (commandbar.md §10 gap 2) | none | none | none | unplanned | |
| Browser actions by name (89 actions; 79 Arc seed ids) | FC §4.4 r9 | `docs/commands.md` | `OpenCommands/SuggestAdapter.swift`, `OpenSuggest/ActionRegistry.swift` | none | `commands-dump` (actions 89, seed coverage 79/79) | planned | |
| Search engines: Google default, built-in list, custom engines per profile | FC §4.5 r11–12 | settings §5.2 | `OpenModel/SearchEngine.swift` (moved by #51), `OpenSuggest/SearchEngine.swift`; custom-engine sheet in `OpenSettings` | main (the M1 address field searches with the profile engine) | `settings-preview` `profile-search` | planned (partial) | Since #51 a new profile defaults to Google (`OpenModel/Containers.swift`); before #51 it was DuckDuckGo. Custom engines need the Settings window in the App. |
| Search-suggestion privacy notice | FC §4.5 r13 | settings (review "Code 4") | `OpenSettings` `prepareForRemoteSuggestions` | none | `settings-preview` `suggestion-notice` | planned | |
| Site Search: Tab or Space trigger, pill, Backspace exits | FC §4.6 r15–16 | suggest.md §7 | `OpenSuggest/SiteSearch.swift`; input pill in `OpenCommandBar` | none | `suggest-check` | planned | Scoped look not captured (commandbar.md §11 q5). |
| Search-tabs scope | FC §4.6 r14 | suggest.md "Modes" (`searchTabs`) | `OpenSuggest` | none | `suggest-check` | planned | Entry gesture is a guess. |
| Browser-actions-only scope | FC §4.6 r14 | none | none | none | none | unplanned | |
| Toast after Copy URL ("Copied Current URL" with Share) | FC §4.7 r18; IS §16 | none for the Copy URL command (app-shell §4.2 plans a toast only for the command bar's `.copy`) | none | none | none | unplanned | |
| Keycaps and hold-Cmd shortcut hints | MH "Command Bar" | none | registry `show-shortcuts-overlay` (no key) | none | none | unplanned | |

### 1.8 Menus and hotkeys (summary; numbers in §2)

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| One command registry for menus, keys, and the command bar | MH | `docs/commands.md` | `OpenCommands/CommandRegistry.swift` | none (`main` uses the hand-built `App/MainMenu.swift`, which covers 37 of 147 Arc items) | `commands-dump` OK | planned (Step C) | |
| Arc-order menu bar built from the registry | MH "Full menu tree" | app-shell §4.3 | `OpenCommands/MenuBuilder.swift` | none | `commands-dump` (missing 0, extra 0, different 0) | planned | Every MenuBuilder item calls `performCommand(id)`; see §3, gap 3. |
| Keyboard routing: browser key vs page key; site-then-browser double press | MH "Custom shortcuts" | app-shell §4.3 | `OpenCommands/KeyboardRouter.swift` | main: reserved items only (`MainMenu.performReservedShortcut`); PR #52: also the OpenFeatures key monitor for split, Peek, and back/forward keys | `commands-dump` (router priority) | in PR (partial) | |
| Custom shortcuts: record, conflicts, reset, priority | MH "Custom shortcuts"; FC §7.2 Shortcuts | settings §5.4 | `OpenCommands/KeyBindings.swift`; `OpenSettings/ShortcutsPane.swift` | none | `commands-dump` (overrides); `settings-preview` `shortcuts-save` | planned | |
| Global Little Open hotkey (Cmd+Opt+N) | MH "Global hotkey and Little Arc" | app-shell §4.3 | `OpenCommands/GlobalHotkey.swift` | none | `commands-dump` (register, unregister) | planned | |
| Dynamic Spaces and Tabs menu sections | MH "Menu bar at a glance" | commands.md | `MenuBuilder.swift` | none | `commands-dump` | planned | |
| Essential Keyboard Shortcuts window | MH Help | app-shell §4.2 (placeholder: open the Help Center) | none | none | none | unplanned (window) | |
| Reference table complete | MH | — | `OpenCommands/Resources/expected-menu.json` | — | this audit (§2.3) | in PR (partial) | The table lacks Tabs ▸ "Reveal Tab in Sidebar". |

### 1.9 Split View, Peek, Little Open

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Split View as one sidebar item: up to 4 panes, horizontal or vertical | FA SV-1, SV-3, SV-4 | m4 | model `makeSplit`, `addPane`; `OpenFeatures/SplitViewController.swift` | PR #52; main (M1: 2-pane split with the next tab) | `features-render S1`, `S2`, `S6`; e2e `shell` split (main) | in PR | |
| Create a split: shortcut, drag a row onto the page, context menu, plus menu | FA SV-5 | m4 §3 | `OpenFeatures/SplitDropOverlayView.swift`; sidebar intents | PR #52 | `features-render S2` (C2 edge drop, C3 combine drop) | in PR | No real OS drag session is tested (m4.md). |
| Divider resize; 200 pt minimum; fractions persist | FA SV-7 | m4 (lead Q2) | `OpenFeatures/SplitDividerView.swift` | PR #52 | `features-render S3` | in PR | |
| Pane focus ring; Ctrl+Shift+1…4, next/previous pane | FA SV-8 | m4; app-shell §4.3 | OpenFeatures `handles(_:)` key path | PR #52 | `features-render S4` | in PR | |
| Maximize a pane (Expand Current Split) | FA SV-11 | m4 | `SplitViewController.swift` | PR #52 (no key, no menu item) | `features-render S5` | in PR (partial) | |
| Close pane, separate pane, Separate All, flip orientation | FA SV-10, SV-4 | m4 | model `removePane`, `unsplit`, `setSplitOrientation` | PR #52 | `features-render R1`, `S6`; `sidebar-render check` | in PR | |
| Pane top bar in the page's color | IS §11 | m4 visual finish; engine-api "Page background color" | `OpenFeatures/PaneChromeView.swift` | PR #52 (renderer color query after load) | `features-render RR3`; PR #52 "M4 page color" check | in PR | |
| Sidebar split row (one cell per pane) and split row menu | IS §7; MH "Split row menu" | design.md §15 | `SidebarRows.swift`, `SidebarMenus.swift` | PR #52 | `sidebar-render check` | in PR | |
| Share Split View | FA SV-13 | — | — | — | — | out of scope | Account link. |
| Peek for cross-site links in pinned tabs and favorites (eTLD+1) | FA PK-2 | m4 (lead Q1) | `OpenFeatures/PeekPolicy.swift` | PR #52 | `features-render P1`; e2e `peek` 6/6 (PR #52) | in PR | |
| Shift-click opens Peek in any tab | FA PK-3 | m4 | `PeekPolicy.swift` (`shiftHeld`) | PR #52 | `features-render P1` ("Today Shift opens Peek") | in PR | |
| Peek overlay: geometry, dim, three buttons | FA PK-1; IS §12 | m4 | `OpenFeatures/PeekOverlayView.swift` | PR #52 | `features-render P2`; F0090 compare worst 1 pt, ΔE00 1.86 (`docs/m4.md`) | in PR | Arc shows no dim while loading; Open always dims (m4.md "Limits"). |
| Expand Peek into a tab (same live page) | FA PK-6 | m4 (lead Q5) | `OpenFeatures/PeekController.swift` | PR #52 | `features-render P3`; e2e `peek` (same engine ID and JS state) | in PR | |
| Dismiss Peek with "Peek closed" undo toast; nested peeks (depth cap 5) | FA PK-7, PK-8 | m4 | `PeekController.swift` | PR #52 | `features-render P2`, `P4` | in PR | |
| Peek badge on the source row; Peek follows its source tab | IS §12 | design.md §15 | `OpenSidebar`, `OpenFeatures` | PR #52 | `features-render P5`; `sidebar-render check` | in PR | |
| Peek Split button | IS §12; m4 lead Q4 | m4 | `PeekController.swift` | PR #52 | `features-render P3` ("lead Q4 Split promotes same host beside source"), `R4` (favorite refusal) | in PR | |
| Peek Email (Cmd+Shift+E) | FA PK-4 | app-shell §4.3: disabled in v1 | — | — | — | planned (disabled) | |
| Peek settings switches | FA PK-5; IS §18 Links | settings §5.3 | `OpenSettings/LinksPane.swift` | none | `settings-preview` | planned | |
| Little Open window: 720×540, toolbar, one page, no sidebar | FA LA-1 | routing §9.3; m4 §6 | `OpenFeatures/LittleOpenWindowController.swift`, `LittleOpenSession.swift` | none | `features-render L1` | planned (Step E) | |
| Entry: links from other apps | FA LA-2 | routing §8 (Phase B); app-shell Step E | `OpenRouting` | none (`App/Info.plist` declares http/https, but the App has no open-URL handler) | verify-all `route` (A1–A17) | planned | |
| Entry: global hotkey Cmd+Opt+N | FA LA-3 | app-shell §4.3, §4.4 | `GlobalHotkey.swift` | none | `commands-dump` | planned | |
| Entry: Opt+Cmd-click a link | FA LA-4 | app-shell §4.4 (only if the engine hook exists, Q5) | — | none | none | planned (conditional) | |
| Entry: File ▸ New Little Open Window; AppleScript app-level `tab` | FA LA-5 | app-shell §4.3, §4.10 | `OpenScripting` `makeLittleTab` hook | none | — | planned | |
| Move to a Space (Cmd+O "Open Little Open or Peek in…") | FA LA-6 | m4; routing | `OpenFeatures/LittleOpenCoordinator.swift` | PR #52 (Peek half only) | `features-render L2` | planned | |
| One profile per Little Open window; switch with confirmation | FA LA-7 | routing §9.2 | `LittleOpenSession.swift` | none | none (no check name covers it) | planned | |
| Auto-archive stale Little Open windows (6 h) | FA LA-8 | routing §9.6 | `LittleOpenCoordinator` `archiveExpired` | none | `features-render L3` (real SQLite) | planned | |
| First-run intro (NUX) | FA LA-9 | routing §9.3 | `LittleOpenWindowController.swift` | none | none | planned | |
| Show/Close all Little Open windows (Dock menu) | FA LA-5 | routing §9 (`show-little-open-windows`, `close-little-open-windows`) | none | none | none | planned | |
| Downloads tray in Little Open | FA LA-10 | deferred by routing §0.2 (button shown disabled) | none | none | none | unplanned (deferred) | |

### 1.10 Profiles

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Create, rename, delete with guards; default profile cannot be deleted | FC §5.1 r1–3 | profiles §2 (D-P1) | `OpenModel/BrowserModel.swift` (`createProfile`, `deleteBlockReason`), `ProfilesSettingsModel.swift` | none | verify-all `profiles` | planned | UI in `OpenSettings/ProfilesPane.swift`, not shown by the App yet. |
| Profiles settings pane: list, search, auto-archive, downloads, clear data | IS §18 Profiles | settings §5.2 | `OpenSettings/ProfilesPane.swift` | none | `settings-preview check` | planned | |
| Engine context per profile: separate cookies, cache, extensions | FC §5.2 r4–6 | profiles §6 [NEEDS ENGINE]; engine-patches lead decision 4 | App profile → `OEBrowserContext` | main (M1), PR #52 | e2e `features` "Profiles" (no cookie or localStorage leak) | in PR | Engine data under `<root>/Engine/<dir>` (profile layout fix): a second profile's cookie survives a relaunch and each profile's extensions see only their own tabs (e2e `--only profiles`). |
| Assign a Space to a profile ("Set Profile"); hosts are torn down on change | FC §2.6, §5.4 | profiles D-P2; app-shell §4.8 | model `moveSpace(id:toProfile:)` | PR #52 (explicit teardown) | e2e `sidebar` (Space/profile selection) | in PR | |
| Confirmation before moving a Space to another profile ("don't show again") | FC §5.4 r9 | profiles §7.3 | data only | none | none | planned | |
| Profile indicator in the Space header and Little Open | FC §5.3 r7 | profiles §7 (data; designer visuals) | none | none | none | planned | |
| Missing-profile fallback to Default | FC §5.3 r8 | profiles | model `repairMissingProfileReferences` | none (only `openkit` calls it) | verify-all `profiles` | planned | |
| New Profile (File menu; Set Profile ▸ New Profile…) | FC §5.1 r2 | settings (create sheet) | `OpenSettings` sheet | PR #52 refuses `newProfile`; File ▸ New Profile has no dispatch | none | planned (partial) | |
| Incognito windows: ephemeral context, distinct look, no history | FC §3.1 r2, §8.1 r3 | app-shell §4.8 (Q8); profiles D-P8 | none | none | none | planned | The incognito sidebar look is not specified. |
| Download location per profile | FC §5.2 r4 | profiles lead Q2 (deferred to downloads); settings row | `OpenSettings` setting | none | `settings-preview` | planned (setting only) | |

### 1.11 Air Traffic Control (link routing)

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Rule model and evaluator: first match wins; host and URL matches; source app; destinations Space, most recent Space, Little Open | FC §6.1; FA LA-12, LA-13 | routing Phase A | `OpenRouting/RuleEvaluator.swift`, `RoutingTypes.swift` | none | verify-all `route` (A1–A17) | planned (App) | |
| Links pane: rules editor and Test | FC §6.3 | settings §5.3 | `OpenSettings/LinksPane.swift`; `OpenRouting/LinksSettingsModel.swift` | none | `settings-preview` (rules, order, invalid drafts; agrees with `openkit route`) | planned | |
| External link intake with a cold-launch queue | FC §6.2 r5; FA LA-13 | routing §8; app-shell Step E | — | none | none | planned | |
| Set as Default Browser | FC §7.2 General | routing §8.4; app-shell §4.4 | `OpenSettings` action | none | `settings-preview` (failure path) | planned | |
| Air Traffic Control command-bar action | FC §6.3 r8 | `docs/settings.md` adapter table | registry `air-traffic-control` | none | `commands-dump` | planned | |
| Meeting links (Meet) toast | FC §6.2 r7 | excluded by routing §0.2 ("Meet links route like any other link in v1") | — | — | — | unplanned (deferred) | |

### 1.12 Boosts and Zap

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Boost model, per-profile store, site matching | FA BO-1, BO-5 | boosts-zap | `OpenBoosts/Boost.swift`, `BoostStore.swift`, `BoostMatcher.swift` | none | verify-all `boosts` (26/26 harness checks, `docs/boosts.md`) | planned (Step F) | |
| Components: CSS, JS, color, font, text zoom and transform, Zaps | FA BO-2–4 | boosts-zap (lead Q8) | `OpenBoosts/InjectionPlan.swift`, `Resources/boost-applier.js` | none | `boosts` A1–A6, Appendix C checks | planned | |
| Document-start injection; SPA re-apply | FA BO-8–9 | app-shell §4.5 | `boost-applier.js` | none (the engine hook works: e2e `features` "User scripts (Boosts)") | `boosts` S-A1–S-A3 | planned | |
| Isolated world for the applier and the picker | `docs/followups.md`; engine-patches P7 | engine-patches P7 | — | — | `boosts` (Chrome isolated world) | planned | |
| Zap picker: hover, click, robust selector, related elements, undo | FA ZA-1–6 | boosts-zap §7 | `Resources/zap-picker.js`, `PickerMessages.swift` | none | `boosts` A7–A11, O1–O3, E1–E3 | planned | |
| Global switch "Enable Boosts on websites you visit" | FA BO-5; IS §18 Advanced | settings §5.5 | `OpenSettings/AdvancedPane.swift` | none | `settings-preview` | planned | |
| Boost editor (simple panel, full editor), gallery, New/Edit Boost, View Boosts | FA BO-11–13; MH File, Window | plan in progress: Site Control Center + Boost editor | none | none | none | planned | |
| Boost sharing and install from link | FA BO-6 | — | — | — | — | out of scope | |
| Import Arc Boosts | DM §2.6 | none (no `StorableBoostsData.json` sample on this Mac) | — | — | — | unplanned | Blocked on a sample (§5.2). |

### 1.13 Site Control Center

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Popover from the URL pill button | FA SC-1 | plan in progress: Site Control Center + Boost editor; interim `NSPopover` in app-shell §4.9 | sidebar sends `showSiteControls` | PR #52 refuses | none | planned | |
| Site permissions rows | FA SC-2 | same; app-shell §4.9 | engine `permission` / `setPermission` | none | e2e `features` "Permission prompts" (engine) | planned | |
| Boosts section | FA SC-3 | same | — | none | none | planned | |
| Extensions section (pin, site access) | FA SC-4 | same; extensions UI plan in progress | — | none | none | planned | |
| Footer: Copy URL, Share | FA SC-5 | same | — | none | none | planned | |
| Footer: Capture, Capture in Portrait Mode, Capture Full Page | FA SC-5, §9.1 | none | none | none | none | unplanned | See Capture in §1.17. |
| Ad-block per-site toggle with reload | FA SC-6, AD-7 | same; `docs/adblock-lists.md` | `OpenAdBlock/SiteRules.swift` (`setExcluded`) | none | `openkit adblock` | planned | |
| Security state (secure or not) | FA SC-7 | same | — | none | none | planned | |
| Clear cookies and cache for the site; zoom reset | app-shell §4.9 | app-shell §4.9 | engine `clearBrowsingData(origin:)` | none | none | planned | |

### 1.14 Ad blocking

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| 46-list catalog, upstream URLs, pins, ETag downloads, per-profile lists, global switch | FA AD-3, AD-4, AD-6 | adblock-fork (Swift slice) | `OpenAdBlock/*` | none | verify-all `adblock-perf`, `adblock-catalog` | planned (App) | |
| Network blocking (adblock-rust in the fork) | FA AD-2, AD-5; `docs/adblock-design.md` | adblock-fork Steps 1–8 | Step 1: crate vendored (`Engine/fork/patches/rust/0001-adblock-vendor.patch`, branch `m6/adblock-engine`) | none (engine request-filter hook exists: e2e `features` "Request filter") | Step 1: crate builds under Chromium's rustc 1.100; A/B match bench (docs/engine-patches.md P8 "Security review") | planned (Step 1 in PR) | Until the fork engine lands, the App bridge blocks nothing at rule level (app-shell Q6). |
| Cosmetic filtering and scriptlets | FA AD-5 | adblock-fork | — | none | none | planned | |
| Per-site exclusion | FA AD-7 | adblock-lists | `SiteRules.swift` | none | `openkit adblock` | planned | |
| Settings: lists by category, advanced, reset, debug info | FA AD-8 | settings §5.5 | `OpenSettings/AdBlockSettingsModel.swift` | none | `settings-preview` (loopback server) | planned | |
| Warning when an extension blocker also runs | FA AD-1 | settings (`hasOtherBlocker`) | `OpenSettings` | none | `settings-preview` | planned (partial) | Needs the extension list from the App. |
| Auto-disable an extension blocker on allow-listed sites (uBlock on YouTube) | FA AD-7 | none | none | none | none | unplanned | Arc's reason is unknown (FA §7.4 q6). |

### 1.15 Import from Arc

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Sidebar: Spaces, pinned, Today, folders, splits, favorites, icons, themes | DM §2, §5 | model.md "OpenImport" | `OpenImport/ArcImport.swift` | CLI `openkit import-arc` only; the `OpenSettings` wizard is not shown by the App | verify-all `roundtrip`; `import-arc` needs `--with-arc-data` (not run in this audit) | planned | |
| Windows and session selection | DM §2.4, "Archive and session files" | model.md | `ArcImport.swift` | CLI only | model.md (session1 snapshot: 2 applied selections) | planned | |
| Routing rules | DM | model.md | `ArcImport.swift` | CLI only | model.md | planned | |
| Archive | DM "Archive and session files" | model.md | `ArcImport.swift`; `ArchiveStore.importRecords` | CLI only | model.md | planned | |
| History | import2 §2 | model.md "phase 2" | `OpenImport/ArcHistoryImport.swift`, `OpenStore/HistoryImport.swift` | CLI `import-arc-history` only | model.md (F1, F2: 100,000 visits in 1.443 s; real History 24 visits) | planned | |
| Read and decrypt passwords, cookies, cards, addresses (consent-gated) | import2 §3 | import2 Part A | `OpenImport/ArcSecrets.swift`, `ChromiumCrypto.swift` | CLI (synthetic fixtures only) | `openkit verify-secrets-fixture`; model.md S1/S2 | planned (counts only) | The real Keychain path was never run (lead decision). |
| Write imported secrets into Open's profile | import2 §3.7 "Part B" | none: "waits for the engine"; no engine patch in `docs/engine-patches.md` | none | none | none | unplanned | See §3, gap 2. |
| Extensions: detect reinstall candidates | import2 §2 | model.md | `OpenImport/ArcExtensions.swift` | CLI | model.md (synthetic union) | planned (detect only) | Reinstall waits for engine patch P3. |
| Boosts | DM §2.6 | none | — | — | — | unplanned | Blocked on a sample. |
| Multi-profile Arc installs | DM §6 item 3; profiles Q1 | profiles Q1 (lenient parser) | `ArcImport.swift` | — | — | planned | Needs a sample (§5.2). |
| Import wizard (Settings ▸ General ▸ Import from Arc…) | — | settings §5.8 | `OpenSettings/ImportWizard.swift` | none | `settings-preview` `import-counts` | planned | |
| Import in the first-run flow | — | first-run | none | none | none | planned | |
| Top Sites, site engagement | — | import2 lead decision: skip | — | — | — | out of scope | |

### 1.16 Extensions

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Extension runtime: MV3 service workers, content scripts, declarativeNetRequest, options pages | AGENTS.md v1 | `docs/engine-spike.md` | `Engine/OpenEngine` | main | e2e `extensions` (uBO Lite, Dark Reader, 1Password, Bitwarden) | done | |
| Toolbar action buttons and popups (basic) | AGENTS.md; FA SC-4 | app-shell §4.12 | `App` extension bar | main; PR #52 (ported) | e2e `extensions` (popups render) | done (partial) | Bitwarden-class popups need P1 (next row). |
| `chrome.tabs` and `chrome.windows` see Open's tabs (P1 tab-strip bridge) | engine-patches P1 | engine-patches P1 | fork overlay `Engine/fork/src/open/browser/tab_strip/*`; Chromium patches 0301–0303, CEF 0302–0303; requests in `App/WebContent/EngineWebContentHostFactory.swift`, order in `App/TabStripMirror.swift` | PR #53 | e2e `--style chrome --only tabstrip` (PR #53 round 2) | in PR | |
| Live action state: badge, title, enabled | engine-patches P2 | engine-patches P2 | PR #53 (`browserDidUpdateExtensionActions`) | PR #53 (the toolbar does not draw the badge yet, `docs/followups.md`) | `tabstrip` | in PR (partial) | |
| Real popup host, `setIcon`, `onClicked` | engine-patches P2 | engine-patches P2 | — | — | — | planned | |
| Install, uninstall, enable from Open's UI; Open's consent prompts; Web Store install | engine-patches P3 | engine-patches P3 | — | main: `chrome://extensions` and the Web Store in a Chrome-style tab | e2e `extensions` (Chrome style installs; Alloy fails) | planned | |
| Extensions menu: Manage Extensions…, Add Extension… | MH Extensions | app-shell §4.3 | registry | main: one View ▸ "Extensions" item | — | done (partial) | |
| Extensions UI (toolbar placement, pinning, menus, management) | — | plan in progress: extensions UI | — | — | — | planned | |
| Folders as `chrome.tabGroups` | engine-patches lead decision 3 | needs a decision (PR #53 proposal) | — | — | — | planned (needs decision) | |
| Extension keyboard shortcuts (Settings "Extension Shortcuts") | MH "Custom shortcuts" | none known (may fall in the extensions UI plan) | none | none | none | unplanned | |
| Extension omnibox keywords and "run extension by name" in the command bar | FC §4.2 r4, §4.4 | none | none | none | none | unplanned | |

### 1.17 Engine and platform basics

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Own Chromium 156 fork with CEF embedding layer; default engine source | AGENTS.md | fork-infra; `docs/engine-fork.md` | `Engine/fork` | main (PR #46) | e2e on the fork (`results-shell-release-fork.json`, `results-features-alloy-fork.json`) | done | |
| Proprietary codecs (H.264, AAC, HEVC) | engine-patches P4 | P4 | GN args | main | `results-features-alloy-fork.json` (`codecs`) | done | Licensing is on the release checklist (U-6). |
| Widevine DRM | — | — | — | — | — | out of scope | Lead decision (fork-infra appendix). |
| Downloads: destination and progress | FA DL-1 | app-shell §4.9 (Step D) | engine `OEDownload` | main: saves to `~/Downloads` with no UI | e2e `features` "Downloads" | planned (UI) | |
| Downloads UI: popover, Cmd+Shift+J, Library section, quit warning | FA DL-1; FC §8.1 r4 | app-shell §4.9; settings G-2 | `OpenSettings/DownloadsSection.swift` | none | `settings-preview` (downloads) | planned | |
| Find in page: bar, count, next, previous, Esc | MH Find | app-shell §4.9 (Step D) | — | main: plain search field, Find Next only | e2e `features` "Find in page" | planned | |
| Page context menu: link, image, selection, spelling; Open in Peek, Little Open, Split | MH "Context menus" | app-shell §4.9 | — | main: Chromium items plus "Open Link in New Tab" | e2e `features` "Context menu hook" | planned | |
| Permission prompts (Arc style, remember) | FA SC-2 | app-shell §4.9; Site Control Center plan in progress | — | main: `NSAlert` sheet | e2e `features` "Permission prompts" | planned | |
| Web notifications delivered to macOS Notification Center | — | none | Helper "Alerts" app exists | — | not verified (only the permission grant is tested) | unplanned (verify) | |
| JavaScript dialogs: alert, confirm, prompt, beforeunload | — | app-shell §4.9 | — | main, PR #52 | e2e `features` "JS dialogs" | done | Plain `NSAlert` sheets. |
| History recording per profile (FTS) | FC §4.2 | app-shell §4.8 (Step H) | `OpenStore/HistoryStore.swift` | none (no `recordVisit` caller in `App/`) | `suggest-check`; `openkit bench` | planned | |
| History view (Cmd+Y) | MH Archive | settings Library History | `OpenSettings/HistorySection.swift` | none | `settings-preview` | planned | |
| Picture in Picture for video | FA §8 (PP-1, PP-2) | media-pip (D-8: phase 1 keeps Chromium's PiP window) | — | main (Chromium's own PiP window) | e2e `features` "Picture in Picture" | done (engine default) | Open's own PiP window chrome is planned (media-pip phase 2). |
| Auto-PiP on tab leave; Google Meet auto-PiP; Document PiP | FA §8 (PP-3–5) | media-pip (D-4, D-5) | — | — | — | planned | |
| Mini player controls: play/pause, tracks, mute, camera/microphone toggles | FA §8 (PP-6–9, PP-21) | media-pip | — | — | — | planned | |
| Print (Cmd+P), print to PDF | MH File | — | — | main | e2e `features` "Print to PDF" | done | |
| Save Page As (Cmd+Shift+S) | MH File | app-shell §4.3 | — | none | none | planned | |
| Zoom in, out, actual size | MH View | — | — | main | e2e `features` "Zoom" | done | |
| Zoom toast ("110%") | IS §16 | none | none | none | none | unplanned | |
| Toasts: Space-tinted, top-right of the page, stacking | IS §16 | app-shell §3.7 reuses the OpenFeatures toast (black 0.85, bottom center) | `OpenFeatures/BrowserWindowController.swift` toast | PR #52 | none | in PR (look differs) | The Arc toast look is unplanned. |
| Native and HTML full screen | FC §8.2 r5 | app-shell §3.8 | — | main, PR #52 | e2e `features` "HTML fullscreen"; e2e `window` | done | |
| Multiple windows (Cmd+N), per-window state | FC §8.1 r1 | app-shell §3.8 | model window commands (PR #52) | PR #52 | e2e `window` (two windows, restore) | in PR | |
| Close Window (Cmd+Shift+W), Blank Window, last-window behavior | FC §8.1 r2, r4; IS §17 | app-shell §3.8, §4.3 | — | none (menu) | — | planned | The Blank Window "This Window" sidebar is not specified. |
| Renderer crash recovery (Sad Tab) | FA ST-1 | app-shell §4.13 (placeholder offers reload) | model `tab.live.isCrashed` | main (crash state reaches the model) | e2e `features` "Renderer crash" | planned (page UI) | |
| Relaunch restores windows, tabs, selection | FC §3.7 r24–25 | app-shell §3.8 | `OpenStore/SnapshotStore.swift` | main, PR #52 | e2e `shell` persistence; e2e `window` restore | done | |
| "Restore windows from previous session" switch | FC §3.7 r24; IS §18 Advanced | settings | `OpenSettings` | none | `settings-preview` | planned (setting only) | |
| Warn before quitting; downloads in progress | FC §7.2 General, §8.1 r4 | settings G-2 | `OpenSettings` | none | `settings-preview` | planned (setting only) | |
| Updates (Sparkle, Check for Updates…) | FC §7.2 General | release §6 | none | none | none | planned | |
| Developer tools, JavaScript console, view source, inspect | MH Developer | app-shell §4.3 | — | main (Developer Tools on Cmd+Opt+I only) | none named | done (partial) | |
| Network Inspector, Toggle Developer Mode, Allow JavaScript from Apple Events | MH Developer | none (applescript Q5 decides "no gate" for `execute`) | registry | none | — | unplanned | |
| Page translation: offer, translate, revert, never translate a site, reset | FA §9.2 TR-1–3 | none | none | none | none | unplanned | |
| Capture: area, full page, portrait; Cmd+Shift+2; Cmd+Shift drag | FA §9.1 CA-1–4; MH Gestures | none for the tool (settings §6.4 only reads `State/captures.json`) | `OpenSettings/CapturesSection.swift` (reader) | none | `settings-preview` (index) | unplanned (tool) | |
| Sound effects | FA §9.7 | settings (switch, default OFF until sounds ship) | `OpenSettings` switch | none | — | unplanned (sounds) | |
| Share (File ▸ Share…, row Share ▸) | MH File; IS §15 | app-shell §4.1, §4.3 | — | none | — | planned | |
| Spelling, substitutions, transformations, speech, font menus | MH Edit | none for dispatch (§2.2) | registry | main: Undo, Redo, Cut, Copy, Paste, Select All only | — | unplanned (dispatch) | |
| Two-finger swipe back/forward on the page; pinch zoom | MH "Gestures" | none | — | — | not verified | unplanned | |
| Optional toolbar (Show/Hide Toolbar, full URL) | FC §8.2 r6 | none | registry | — | — | unplanned | |
| Website appearance: Automatic, Light, Dark | MH View ▸ Appearance | none | registry | — | — | unplanned | |
| Clear Cache and Refresh; Clear Cookies and Refresh | MH View | none (per-site clear is in app-shell §4.9) | registry | — | — | unplanned | |
| Cast | MH View | none | registry | — | — | unplanned | |
| Troubleshooting: Task Manager, Record/Cancel Trace, Copy Open Info, Reveal Open Data | MH Help | none | registry | — | — | unplanned | |
| Password manager: save and fill prompts, Manage Passwords | FC §4.4 table ("Manage Passwords"); IS §18 Profiles ("Passwords", "Credit Cards") | none | registry `manage-passwords` (command bar only) | — | not verified in OpenEngine | unplanned | See §3, gap 1. |
| AppleScript with Arc's terms | FA §10 | applescript Steps 1–4 done; Steps 5–7 and app-shell §4.10 (Step H) | `OpenScripting/*`; `App/Resources/Open.sdef` | none (`App/Info.plist` has no `OSAScriptingDefinition`) | `docs/scripting.md` Steps 1–4 verification | planned (App) | |
| Tab-sleep engine patches (P-MEM-01…07) | memory-design §6 | memory-fork | — | — | — | planned | |
| Trim the Chrome layer (P5) | engine-patches P5 | P5 | — | — | — | planned | |
| Join Meeting (Cmd+Ctrl+J) | FC §4.4; MH Tabs | none | registry | — | — | unplanned | Needs a calendar source; may be account-like. |

### 1.18 Settings and Library

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Settings window: 684×650, pane tabs, one reused window | IS §18 | settings | `OpenSettings/SettingsWindow.swift` | none | `settings-preview check` (verify-all); 86 committed renders (`docs/settings/`) | planned | |
| General pane | FC §7.2 General; IS §18 | settings §5.1 | `OpenSettings/GeneralPane.swift` | none | `settings-preview` | planned | |
| Profiles pane | FC §7.2 Profiles | settings §5.2 | `OpenSettings/ProfilesPane.swift` | none | `settings-preview` | planned | |
| Links pane | FC §7.2 Links | settings §5.3 | `OpenSettings/LinksPane.swift` | none | `settings-preview` | planned | |
| Shortcuts pane | FC §7.2 Shortcuts | settings §5.4 | `OpenSettings/ShortcutsPane.swift` | none | `settings-preview` | planned | |
| Icon pane (Open's own icons) | FC §7.1 App Icon | settings | `OpenSettings/AppIconPane.swift` | none | `settings-preview` | planned | |
| Advanced pane plus Ad Blocking and Tab Sleeping groups | FC §7.2 Advanced | settings §5.5 | `OpenSettings/AdvancedPane.swift` | none | `settings-preview` | planned | |
| Clear Browsing Data per profile with time range | FC §7.2 Profiles | settings | `OpenSettings` sheet and action | none | `settings-preview` | planned | |
| Cmd+, opens Settings in the app | MH Arc menu | app-shell §4.11 (placeholder); settings adapter table (`docs/settings.md`) | — | none | none | planned | |
| Library window: Archive, Downloads, Captures, Media, History | FA §9.6 LB-1 | settings §6 (D-9) | `OpenSettings/LibraryWindow.swift` | none | `settings-preview` | planned | |
| Library folder sources (Documents, Desktop, Downloads folders, Screenshots) | FA LB-1 | deferred to v1.1 (settings D-9) | — | — | — | out of scope (lead decision) | |
| Account, Max, Staff panes | FC §7.1 | — | — | — | — | out of scope | |

### 1.19 First run

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| First-run window: Welcome → Import → Default browser | FC §3.7 r25 | first-run | none | none | none | planned | Its lead decision waits for #51 (merged) and app-shell A+B (open). |
| Import step with live counts and a separate consent step for secrets | — | first-run §5.4 | reuses the `OpenSettings` wizard | none | none | planned | |
| Default browser step | — | first-run §3.5 | — | none | none | planned | |
| Re-running import adds no duplicates | — | first-run (criterion 7) | stable import IDs (`ArcImport.swift`) | — | verify-all `roundtrip`; model.md (idempotent archive re-import) | planned | |

### 1.20 Release

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Official engine build (ThinLTO, PGO) | — | fork-infra Step 10; release §2 | `Engine/fork/gn/release.args.gn` | — | — | planned | `engine-distrib --config release` is gated: CEF's `make_distrib.py` reads only `out/Release_GN_arm64` (`docs/followups.md`). |
| Bundle IDs `io.github.sergeserb2.open*` | — | release §4.1 (C-3) | `project.yml` still uses `app.open.*` | — | — | planned | |
| Developer ID signing, hardened runtime, entitlements | — | release §4 | `project.yml` is ad-hoc | — | — | planned | Needs U-1, U-2 (§5.1). |
| Notarization and DMG | — | release §3 | — | — | — | planned | Needs U-3. |
| Sparkle updates with an appcast on GitHub Pages | — | release §6 | — | — | — | planned | Needs U-4, U-5. |
| English-only locales | engine-patches P5 | release §2.7 | `tools/embed-cef.sh` (`OPEN_KEEP_LOCALES`); `tools/release-locales.txt` (#54, merged) | — | — | planned (partial) | The list is on `main`; the release pipeline that applies it is PR #57. |
| License inventory and acknowledgements | `docs/followups.md` | release §7, Step 9 | `docs/release/licenses.md`, `tools/generate-acknowledgements.py` (#55, merged) | — | — | planned (partial) | The inventory is on `main`; the review itself needs U-6. |
| Crash symbol archive (dSYMs kept on this Mac) | — | release §2.5 | — | — | — | planned | |
| `tools/release.sh --dry-run` | — | release §11, Step 11 | PR #57 (`tools/release.sh`) | — | — | in PR | |

## 2. Menu and hotkey coverage

### 2.1 Method

1. Arc's in-scope menu items come from the menu tables in `docs/re/menus-and-hotkeys.md` ("Full menu tree"). Out-of-scope rows are the 11 rows that `expected-menu.json` marks `inScope: false` (account, Notes, Easels, Arc Max, Dia, Privacy Policy, Restore Data).
2. "Registered" means a `CommandRegistry` command exists. `.build/release/commands-dump` passes on `42bba0b` and `dc62e65`: `missing=0 extra=0 different=0 allowedMissing=11`, `suggest actions=89 (OpenSuggest seed=79)`, `seed coverage=79/79`.
3. "Wired" means the Arc menu item or Arc key reaches a real action in the app. Sources: `App/MainMenu.swift` on `main` and on PR #52, plus the OpenFeatures key monitor that PR #52's real window installs (`handles(_:)` in `OpenFeatures/BrowserWindowController.swift`). "Partial" means it works but differs from Arc (for example Cmd+T opens an address field, Ctrl+Tab uses sidebar order).
4. "Planned" means the id is in the app-shell §4.3 command table, the OpenFeatures `handles(_:)` list, or the settings adapter table in `docs/settings.md`. "System" means a standard AppKit text or window item; on `main` some work through the responder chain, but app-shell §4.3 names no handler for them (§3, gap 3).
5. A scratch script joined these sources with `expected-menu.json` and the `commands-dump --markdown` table. Appendix A lists every row.

### 2.2 Numbers

Menu items (Arc in scope: 147 items, counting New Tab in File and in Tabs separately; 5 more rows are duplicate key carriers):

| Measure | Count | Notes |
|---|---:|---|
| Arc items in scope | 147 | |
| Registered | 146 | Missing: Tabs ▸ "Reveal Tab in Sidebar" (§2.3). The registry adds 2 standard macOS items (Emoji & Symbols, Show Fonts). |
| Wired on `main` | 37 | 28 like Arc, 9 partial |
| Wired in PR #52 | 40 | 30 like Arc, 10 partial (adds New Window, Close this Split Pane by key, Cmd+O for Peek) |
| Not wired, planned | 42 | Mostly app-shell Step C |
| Not wired, system item with no dispatch spec | 29 | Spelling (5), Substitutions (7), Transformations (3), Speech (2), Bold, Italic, Underline, Paste and Match Style, Delete, Find and Replace, Use Selection to Find, Jump to Selection, Hide Others, Show All, Zoom, Bring All to Front |
| Not wired, no plan | 36 | List in §2.4 |

Hotkeys (Arc in scope: 79 menu keys from the nib plus 25 code-only keys; the code-only defaults are web-sourced guesses, MH "Shortcuts that live in code"):

| Measure | Menu keys | Code-only keys | Total |
|---|---:|---:|---:|
| Arc keys in scope | 79 | 25 | 104 |
| Registered | 79 | 25 | 104 (plus 3 standard macOS keys: Cmd+E, Cmd+Ctrl+Space, Show Fonts Cmd+T) |
| Bound on `main` | 34 (27 like Arc) | 0 | 34 |
| Bound in PR #52 | 39 | 6 (split pane 1–4, next, previous) | 45 (38 like Arc) |
| Unbound, planned | 25 | 19 (Cmd+1…9, Ctrl+1…9, global Cmd+Opt+N) | 44 |
| Unbound, system with no dispatch spec | 9 | 0 | 9 |
| Unbound, no plan | 6 | 0 | 6 |

### 2.3 Gaps in the reference data

- `Packages/OpenKit/Sources/OpenCommands/Resources/expected-menu.json` has no row for Tabs ▸ "Reveal Tab in Sidebar" (`revealCurrentTabInSidebar:`, MH Tabs table). So `commands-dump` reports `missing=0` although the registry has no command for it. Arc also has View ▸ "Reveal Current Tab" (`focusSidebar:`, Ctrl+Space), which the registry has as `reveal-current-tab`.
- `docs/commands.md` names the Cmd+O command "Move Little Open or Peek to Space…". The live registry and `commands-dump` use "Open Little Open or Peek in…" (`CommandRegistry.swift`, `open-in-current-space`).
- Gestures are not in the registry and not counted above: page swipe back/forward (no plan), Space swipe (done in `OpenSidebar`), sidebar edge swipe (no plan), pinch zoom (not verified), Opt+Cmd-click Little Open (planned, conditional), Shift-click Peek (in PR #52), hold Cmd for shortcut hints (no plan), Cmd+Shift drag Capture (no plan), double-click rename (in PR #52).

### 2.4 Missing lists

Arc menu items with no plan (36). "(UI elsewhere)" means another surface already offers the action, but the menu command has no dispatch.

- File: Capture… (Cmd+Shift+2), Capture Full Page, Capture in Portrait Mode, New Profile (UI elsewhere: `OpenSettings` sheet), New Boost, Edit Boost, New Legacy Boost (Advanced), Boost Gallery (the last four: Boost editor plan in progress).
- Edit: Copy URL as Quote (Cmd+Ctrl+Shift+C).
- View: Show/Hide Toolbar (Cmd+Shift+D), Clear Cache and Refresh, Clear Cookies and Refresh, Cast…, Exit (Esc; OpenFeatures already handles Esc for Peek and a maximized split), Appearance ▸ Automatic, Light, Dark, Developer ▸ Network Inspector, Toggle Developer Mode (Ctrl+D), Allow JavaScript from Apple Events.
- Spaces: Manage Spaces…, Rename Space (UI elsewhere: inline rename), Edit Theme… (theme editor plan in progress), Change Profile (UI elsewhere: Set Profile menu).
- Tabs: Reset all tabs in this Space, Expand All Folders, Collapse All Folders, Join Meeting (Cmd+Ctrl+J), Reveal Tab in Sidebar (not registered).
- Archive: Clear Archive (UI elsewhere: `OpenSettings` Library).
- Window: View Media (UI elsewhere: `OpenSettings` Library).
- Help ▸ Troubleshooting: Open Task Manager, Record Trace, Cancel Trace, Copy Open Info, Reveal Open Data.

Arc keys with no plan (6): Capture Cmd+Shift+2, Copy URL as Quote Cmd+Ctrl+Shift+C, Show/Hide Toolbar Cmd+Shift+D, Exit Esc (as a menu command), Join Meeting Cmd+Ctrl+J, Toggle Developer Mode Ctrl+D.

Arc keys that are system items with no dispatch spec (9): Hide Others Cmd+Opt+H, Paste and Match Style Cmd+Shift+V, Find and Replace Cmd+Opt+F, Jump to Selection Cmd+J, Show Spelling and Grammar Cmd+:, Check Document Now Cmd+;, Bold Cmd+B, Italic Cmd+I, Underline Cmd+U.

Arc keys planned but unbound (44): Settings Cmd+,; New Incognito Window Cmd+Shift+N; New Little Open Window Cmd+Opt+N; Blank Window Cmd+Ctrl+N; Close Window Cmd+Shift+W; Save Page As Cmd+Shift+S; Copy URL Cmd+Shift+C; Copy URL as Markdown Cmd+Opt+Shift+C; Find Previous Cmd+Shift+G; Force Refresh Cmd+Shift+R; Zoom In Cmd++; Zoom Out Cmd+Shift+-; Reveal Current Tab Ctrl+Space; Cycle Tab Cmd+Ctrl+→ and Cmd+Ctrl+←; Clear Unpinned Tabs Cmd+Shift+K; New Folder Cmd+Shift+N; Peek Email Cmd+Shift+E; View History Cmd+Y; View Downloads Cmd+Shift+J; View Library Cmd+Shift+L; Developer Tools F12; JavaScript Console Cmd+Opt+J; View Source Cmd+Opt+U; Inspect Elements Cmd+Opt+C; global Little Open Cmd+Opt+N; Go to tab Cmd+1…9; Go to Space Ctrl+1…9.

## 3. Unplanned gaps, ranked

Ranking is by user impact for an Arc user who switches to Open. **P0** blocks daily use. **P1** is noticeable. **P2** is polish. Each gap has no plan for the missing part. Most also have no code; where code exists, the line says so.

### 3.1 P0

1. **Open's own password manager.** Save and fill prompts on login forms, a "Manage Passwords" page, cards and addresses. Evidence: FC §4.4 action table ("Manage Passwords: Open password manager (Profile)"); IS §18 Profiles pane rows "Passwords" and "Credit Cards". No plan; OpenEngine has no password-store or autofill API (only the Keychain key setting in `Engine/OpenEngine/include/OpenEngine/OEEngine.h`), and nobody has tested whether Chromium's own prompts appear in Alloy or hosted Chrome-style tabs. Belongs in: a new engine patch in `docs/engine-patches.md`, the Profiles pane (`settings`), and the extensions UI plan for users who rely on 1Password or Bitwarden.
2. **Write imported Arc passwords, cookies, cards, and addresses into Open.** Without it, every switcher is logged out of every site. Evidence: import2 §3.7 "Destination (Part B, waits for the engine)" and its lead decision "Writing secrets into Open's profile waits for the engine's password-store/ProfileWriter API". Readers and decryption exist (`OpenImport/ArcSecrets.swift`, `ChromiumCrypto.swift`, synthetic fixtures pass). No engine patch is planned. Belongs in: `docs/engine-patches.md` (new patch: one batch call into `ProfileWriter`, the cookie store, and `WebDataService`), then import2 Part B, then the first-run consent step.
3. **System menu items lose their handler when MenuBuilder replaces the M1 menu.** `MenuBuilder` routes every item, including Cut, Copy, Paste, Undo, Select All, Quit, Hide, Minimize, Spelling, and Speech, through `CommandDispatcher.performCommand(id)` (`OpenCommands/MenuBuilder.swift`, `MenuCommandTarget.openCommandAction`). The app-shell §4.3 command table lists none of the 40 system ids. Nine of them work on `main` today through the responder chain (`App/MainMenu.swift`), so Step C can break copy and paste. Evidence: MH Edit, Window, Arc menus; app-shell §4.3. Belongs in: app-shell §4.3 (add a row that forwards system ids to `NSApp.sendAction` with the standard selectors) or `MenuBuilder` (give system items their AppKit selector and no target).

### 3.2 P1

4. **Today auto-archive never runs.** Code exists: `BrowserModel.archiveExpiredTabs(now:)` with per-profile thresholds; only `openkit` calls it. No App timer is planned; app-shell §4.4 plans only the Little Open sweeper. Evidence: FC §3.3 r10–13. Belongs in: app-shell Step G or H (one timer, same cadence as the Little Open sweeper, plus a sweep at launch).
5. **Done in this PR: sleep keep-alive site list.** `OpenSleep` has a built-in host/path table plus `x.com`, the `keepAlive` freeze + discard gate, and per-profile user additions in snapshot field `ProfileSettings.keepAliveSites`. Evidence: FC §3.4 r16; the read-only `keepaliveAllowList` and Notion-only `tabSuspensionBlocklist` in Arc's `web_content_behavior.json`. `openkit sleep-demo` covers 48 h protection, path/TLD/subdomain scope, profile isolation, and navigation away. See `docs/sleep.md`. Settings UI is deferred to Site Control Center; native notifications remain unverified (gap 12).
6. **Multi-select in the sidebar.** Shift/Cmd-click, New Folder from Selection, and bulk archive, move, and drag. Evidence: FC §1.5 r24 ("Supports multiselect to prefill the created folder"); MH "Gestures and mouse". The model already takes several nodes (`createFolder(withNodes:)`). Belongs in: `OpenSidebar` (design.md §5) and app-shell §4.1.
7. **Reorder Spaces (Space Manager).** No view can reorder Spaces. The model command and intent exist (`moveSpace(id:to:)`). Evidence: FC §2.2 r8 ("Drag to Reorder Space", Spaces ▸ Manage Spaces…). Belongs in: the in-progress Space creation + theme editor plan, or `OpenSidebar` (drag in the switcher).
8. **Page translation.** Offer bubble, translate, revert, other language, never translate a site, reset prompts. Evidence: FA §9.2 TR-1–3 (`ADKClient._translate`, `TranslateBubbleView`). Belongs in: an engine patch (Chromium translate in the fork) plus a small shell bubble; Settings already has the "Reset Translated-site Prompts" button (`OpenSettings/AdvancedPane.swift`).
9. **Two-finger swipe back and forward on the page.** Evidence: MH "Gestures and mouse" (`PageSwipeController`, `webContentsWantsOverscrollSwipeEvents:`). No plan, and no e2e check proves OpenEngine supports it. Belongs in: OpenEngine (engine-api) and app-shell §4.13.
10. **Delete Space has no confirmation.** One menu click archives every tab of the Space (Undo exists). Evidence: FC §2.2 r6 ("Delete the space and close all tabs within it."). Belongs in: app-shell §4.1 (`deleteSpace` row) or the in-progress Space plan.
11. **Delete folder has no confirmation.** Evidence: FC §1.5 r25 ("Deleting this folder will archive the tabs inside it."). Belongs in: app-shell §4.1.
12. **Web notifications are not verified end to end.** Only the permission grant is tested (`docs/engine-spike.md` "Permission prompts"). Evidence: Chromium notifications need the Alerts helper and a macOS authorization. Belongs in: app-shell Step D (add an e2e check).

### 3.3 P2

13. **Capture tool** (area, full page, portrait; Cmd+Shift+2; Cmd+Shift drag; Site Control footer). Evidence: FA §9.1 CA-1–4; MH File. Library reads the index only (`OpenSettings/CapturesSection.swift`). Belongs in: a new OpenFeatures piece plus the Site Control Center plan.
14. **Copy URL as Quote** (Cmd+Ctrl+Shift+C). Evidence: FC §1.4 r19. Belongs in: app-shell §4.3 (needs the page selection from the engine).
15. **Copy URL toast** ("Copied Current URL" with Share) and the **Arc toast look** (Space-tinted, top-right, stacking). Evidence: FC §4.7 r18; IS §16. Belongs in: app-shell §3.7 and `OpenFeatures`.
16. **Zoom level toast** ("110%"). Evidence: IS §16. Belongs in: app-shell §3.7.
17. **Expand / Collapse All Folders; Reset all tabs in this Space.** Registry only. Evidence: FC §1.5 r23, §3.2 r8. Belongs in: app-shell §4.3 (model loops).
18. **Turn folder into Space; Export Space into folder; Turn Space into folder.** Intents and menu items exist; no model command. Evidence: FC §2.2 r7; IS §15. Belongs in: `OpenModel` plus app-shell §4.1.
19. **Hover Previews** of folder, pinned, and favorite rows. The Settings switch exists (`OpenSettings`). Evidence: FC §1.2 r13. Belongs in: `OpenSidebar` plus `OpenFeatures` (reuse the Peek host).
20. **Tidy titles** for known sites. Evidence: FC §1.2 r9. Belongs in: `OpenSidebar` or `OpenModel` (an Open-written rule table).
21. **Unread badge** on rows added in the background (field exists, never drawn). Evidence: FC §1.2 r12. Belongs in: `OpenSidebar`.
22. **Inline autocomplete** in the command bar. Evidence: IS §9.3. Belongs in: `OpenCommandBar` and `OpenSuggest` (commandbar.md §10 gap 3).
23. **One command-bar row per Split View.** Evidence: FC §4.2 r4. Belongs in: `OpenSuggest` (suggest.md Q1).
24. **Browser-actions-only scope** in the command bar. Evidence: FC §4.6 r14. Belongs in: `OpenSuggest` modes.
25. **Hold-Cmd shortcut hints and the Essential Keyboard Shortcuts window.** Evidence: MH "Command Bar", Help. Belongs in: `OpenCommandBar` and a small App window.
26. **Optional toolbar** (Show/Hide Toolbar, full URL). Evidence: FC §8.2 r6. Belongs in: `OpenFeatures` window layout.
27. **Website appearance menu** (Automatic, Light, Dark). Evidence: MH View ▸ Appearance. Belongs in: OpenEngine (color-scheme override) and app-shell §4.3.
28. **Clear Cache / Clear Cookies and Refresh.** Evidence: MH View. Belongs in: app-shell §4.3 (reuse `clearBrowsingData(origin:)`).
29. **Developer menu extras and Troubleshooting items** (Network Inspector, Toggle Developer Mode, Allow JavaScript from Apple Events, Task Manager, traces, Copy Open Info, Reveal Open Data). Evidence: MH Developer, Help ▸ Troubleshooting. Belongs in: app-shell §4.3.
30. **Cast.** Evidence: MH View. Belongs in: OpenEngine (Chromium media router) — may stay out of v1.
31. **Separate From Pinned Tab; Clear unselected Today tabs; auto-archive education banner; first-hide sidebar hint.** Evidence: FC §3.2 r7, §1.8 r40, §3.3 r15; IS §13. Belongs in: `OpenModel` and `OpenSidebar`.
32. **Haptic feedback on reorder; sound effects.** Settings switches exist (`OpenSettings`). Evidence: FC §1.6 r33; FA §9.7. Belongs in: `OpenSidebar` (haptics) and a small sound player with Open's own recordings.
33. **Change Icon… for folders and pinned tabs.** Evidence: IS §15. Belongs in: the in-progress Space icon picker, if it covers items.
34. **Archive a whole folder and restore it as a folder.** Evidence: FC §1.5 r26. Belongs in: `OpenStore/ArchiveStore.swift` (folder records) and settings §6.2.
35. **Little Open downloads tray.** Deferred by routing §0.2. Evidence: FA LA-10. Belongs in: routing Phase B or the downloads step.
36. **Edge-swipe gesture to hide the sidebar.** Evidence: MH "Gestures". Belongs in: `OpenFeatures`.
37. **Extension keyboard shortcuts and extension omnibox keywords.** Evidence: MH "Custom shortcuts" ("Extension Shortcuts"); FC §4.2 r4. Belongs in: the in-progress extensions UI plan, if it does not cover them already.
38. **Import Arc Boosts.** Blocked on a sample file. Evidence: DM §2.6, §6 item 2. Belongs in: `OpenImport`.
39. **Join Meeting** (Cmd+Ctrl+J) and **Meet link toast** (deferred by routing §0.2). Evidence: FC §4.4, §6.2 r7. Needs a calendar source; possibly out of scope.
40. **Auto-disable an extension ad blocker on allow-listed sites.** Evidence: FA AD-7. Belongs in: `OpenAdBlock`; Arc's reason is unknown.
41. **Reveal Tab in Sidebar** is missing from the registry and from `expected-menu.json` (§2.3). Belongs in: `OpenCommands`.

### 3.4 Top 10

| Rank | Gap | Priority |
|---:|---|---|
| 1 | Open's own password manager (save, fill, manage) | P0 |
| 2 | Writing imported Arc passwords and cookies into Open | P0 |
| 3 | System menu items (Cut, Copy, Paste, Quit…) have no dispatch once MenuBuilder lands | P0 |
| 4 | Today auto-archive never runs in the App | P1 |
| 5 | Sleep keep-alive list for Gmail, Slack, calendar, chat — done in this PR | P1 (done) |
| 6 | Multi-select in the sidebar | P1 |
| 7 | Reorder Spaces (Space Manager) | P1 |
| 8 | Page translation | P1 |
| 9 | Two-finger swipe back and forward on the page | P1 |
| 10 | Delete Space confirmation | P1 |

## 4. Performance budget status

Budgets from `docs/architecture.md` (release build, M5 Pro, idle machine). All runs below were on a loaded machine (load average 6–10 on 18 cores), so they are upper bounds.

| Budget | Target | Latest measured value | Where | Source file | Verdict |
|---|---|---|---|---|---|
| Cold launch to sidebar drawn | ≤ 250 ms | PR #52 (real window): fresh 261 ms, warm 253 ms (medians of 5, presented frame) | PR #52 | `docs/app-shell.md` and `docs/engine-spike/results-window-release.json` (branch `t3/app-shell-real-window`) | FAIL by 3–11 ms |
| | | PR #45 (Step A, real sidebar, M1 engine wiring): fresh 224 ms, warm 242 ms | PR #45 | `docs/app-shell.md` and `docs/engine-spike/results-window-release.json` on branch `t3/app-shell-startup-window` (kept in PR #52 as `results-window-step-a-release.json`) | PASS |
| | | `main` (M1 shell, fork dev engine): 386 ms "window and sidebar shown" (median of 3) | main | `docs/engine-spike.md` "Fork vs prebuilt"; `docs/engine-spike/results-measure-release-fork.json` | FAIL |
| Intermediate marks `main` ≤ 50 ms, `modelLoaded` ≤ 120 ms (app-shell §5.1) | — | PR #52: `main` 152/146 ms, `modelLoaded` 154/148 ms (fresh/warm) | PR #52 | `docs/app-shell.md` (PR #52) | FAIL |
| Cold launch to first web paint (restored tab) | ≤ 700 ms | PR #52: fresh 521 ms, warm 493 ms; PR #53 (hosted Chrome-style tabs): 454 ms; `main` fork: 584 ms | PR #52, PR #53, main | `results-window-release.json` (PR #52); `docs/engine-patches.md` P1 status, `results-measure-release-p1.json` (PR #53); `results-measure-release-fork.json` (main) | PASS (median); one fresh outlier at 2,237 ms (PR #52) |
| Tab switch to content visible (live tab) | ≤ 16 ms | not measured | — | `features-render bench` measures only fake-host layout (200 four-pane layouts, median 0.008 ms, `docs/m4.md`) | not measured |
| Sidebar scroll and drag at 120 fps | 8.33 ms per frame | Scroll p95 3.67 ms, max 5.60 ms; moveNode p95 4.84 ms; 1,000 rows, offscreen (this audit, load 8.5) | harness | `sidebar-render bench --rows 1000` on `42bba0b`; earlier runs in `docs/design.md` §11 | PASS (harness only; live app not measured) |
| Idle CPU (no media) | ≈ 0 % | 1.2 % of one core with 10 pages over 10 s (fork); 1.1 % (PR #53) | main, PR #53 | `docs/engine-spike.md` "Fork vs prebuilt"; `docs/engine-patches.md` P1 status | not met with 10 pages (sites keep timers); empty-window idle not measured |
| Command bar open to first results | ≤ 50 ms | App: not measured (no App wiring). Library: first snapshot p95 0.570 ms; keystroke → rows drawn, wall p95 4.49 ms (this audit); history snapshot p95 16.2 ms | library | `docs/suggest.md` "Performance"; `commandbar-render check` on `42bba0b`; `docs/commandbar.md` §6 | library PASS; app not measured |

Memory has no budget in `docs/architecture.md`. Latest values (fork, `results-measure-release-fork.json`): 239 MB for 1 page, 1,210 MB for 10 pages. PR #53: 225 MB and 947 MB.

## 5. Items that need the user

### 5.1 Accounts, money, and approvals (release §10)

| # | Item | Blocks |
|---|---|---|
| U-1 | Apple Developer Program membership ($99/year) | Signing, notarization |
| U-2 | Developer ID Application certificate in the login Keychain | Signing |
| U-3 | Notary credentials (app-specific password, `store-credentials "open-notary"`) | Notarization |
| U-4 | Approve the Sparkle key generation and keep the private key backup | Update signing |
| U-5 | Enable GitHub Pages for `SergeSerb2/open` (`gh-pages` branch) | Update feed |
| U-6 | Confirm the license, patent and security review (MPL-2.0 adblock-rust, GPL-3.0 uBO resources, H.264/AAC, Chromium/CEF; the adblock, regex and aho-corasick crate review in docs/engine-patches.md "Security review") | First public release |
| U-7 | Approve each public release (tag, `gh release create`) | Each release |

### 5.2 Arc sessions only the user can run

Agents must not launch or drive Arc (AGENTS.md rules 4–5). These need the user to use Arc while the recorder runs (`docs/re/runtime-observations.md` §7 gives the steps and labels).

| What | Why | Source |
|---|---|---|
| 60 fps video of Space switch, folder expand, Peek open, command bar open, sidebar hide | Motion tokens are provisional | IS §19 item 1; DT §9 item 6 |
| Active-window traffic lights and glyphs | Active state never captured | IS §19 item 2; RO §7 #1 |
| Sidebar minimum width (slow drag) | 180 pt hide threshold is a guess | IS §19 item 3; app-shell Q3 |
| Little Arc window (Cmd+Opt+N), Library (Home button), Site Control Center popover | No capture of these surfaces | IS §19 item 4; RO §7 #11, #18, #19 |
| Favorite tile hover and its context menu; empty sidebar menu; split row menu | Menus and hover are guesses | IS §19 item 5; IS §15 |
| Light macOS appearance and a dark Space | Light-mode default theme and dark tokens are guesses | IS §2; design.md §9; RO §7 #16 |
| Theme editor with color, grain, intensity changes | Theme fit and editor layout | RO §7 #15; design.md §9 |
| Toasts on a page (copy URL, zoom) | Toast look | RO §7 #19 |
| Arc Settings ▸ Shortcuts list | Ground truth for Go-to-Item, Go-to-Space, Split-focus defaults and the customizable set | MH "Needs a person" items 3, 7; `docs/commands.md` open questions 2–3 |
| Menu order on screen; which duplicate key carrier shows | Menu order is not proven by the nib | MH "Needs a person" items 1–2 |
| Fresh-profile defaults: auto-archive threshold, search engines, ad-block lists, Little Arc and Peek switches, sound effects | Shipping defaults are guesses | FC Appendix C items 1–2, 6, 10; FA §7.4 q1 |
| Pinned-tab affordances: Back to Pinned URL, Close and Keep Pinned, Separate From Pinned Tab | Exact semantics are guesses | FC Appendix C item 4 |
| Air Traffic Control editor: match types, source-app picker, rule order | Routing UI scope | FC Appendix C item 6; routing Q9 |
| Archive one tab, create a Boost, create a second Arc profile, open Little Arc plus a split, create a Live Folder, remap a hotkey, take a Capture; then quit Arc | Locks file schemas for Import (archive wrapper, Boosts, multi-profile, Little Arc window style, key bindings) | DM §6 items 1–8; profiles Q1 |
| Run three AppleScript checks against Arc (`execute` result form, `make new space`, `location` ordering) | AppleScript parity | applescript §14 Q1–Q3 |

### 5.3 Consent

- A real import of passwords and cookies needs the user's explicit consent in the app's import flow. Until then, agents must not touch the "Arc Safe Storage" Keychain item or decrypt real Login Data, Cookies, or Web Data (import2 lead decision).
- `tools/verify-all.sh --with-arc-data` copies the user's Arc JSON read-only. Run it only when the user opts in (`docs/verification.md`).

### 5.4 Decisions

| Decision | Default today | Source |
|---|---|---|
| Folders as `chrome.tabGroups`: Chrome cannot group pinned tabs. Proposal: report tabs inside folders as unpinned, grouped tabs | Not built | PR #53 `docs/followups.md`; engine-patches lead decision 3 |
| Do Boosts apply in incognito, Peek, Little Open, and Split panes? | Apply everywhere | boosts-zap Q4 ("Product to confirm") |
| Keep Safe Browsing on? | Not decided | engine-patches P5 ("Keep Safe Browsing as a product decision") |
| Pinned tabs sleep like other tabs (Chrome protects them) | Sleep; say so in Settings | memory-design §5 |
| Tab-sleep mode names in Settings | Designer names later | memory-fork lead decision |
| Is Join Meeting (calendar) in v1? | Not planned | §3.3 item 39 |
| Is Peek Email in v1? | Disabled | app-shell §4.3 |
| Password manager approach: Chromium's built-in manager in the fork, or extensions only | None | §3.1 gap 1 |
| Library filesystem sources | Deferred to v1.1 | settings D-9 (decided) |
| Widevine | Out of v1 | fork-infra lead decision (decided) |

Design reviews of Settings, the first-run screens, and the Links pane belong to the lead and an Opus designer, not the user (settings lead decision; first-run criterion 10; routing §0.2).

## 6. Evidence for this audit

The audit started on `42bba0b`. PR #51 merged during the audit, so the branch was fast-forwarded to `dc62e65` and the checks marked "both" ran again. PRs #54, #55, #56, and #59 merged next (docs, a text file, a script, and `OpenSettings` polish); the branch merged each one, and `tools/verify-all.sh` ran again on the final merge. No unit tests, no Arc launch, no desktop input, and no Arc user data were used.

| Command | Tree | Result |
|---|---|---|
| `cd Packages/OpenKit && nice -n 10 swift build -c release -j 6` | both | Build complete |
| `.build/release/commands-dump` | both | exit 0: `missing=0 extra=0 different=0 allowedMissing=11`; suggest actions 89; seed coverage 79/79; global hotkey registers and unregisters |
| `.build/release/sidebar-render check` | both | 125 passed, 0 failed |
| `.build/release/features-render check` | both | 147 passed, 0 failed |
| `.build/release/commandbar-render check` | both | 78/78 passed |
| `.build/release/settings-preview check` (inside verify-all) | `dc62e65` | 28 checks passed, 0 failed |
| `.build/release/sidebar-render bench --rows 1000` | `42bba0b` | scroll p95 3.67 ms; moveNode p95 4.84 ms; Space switch 7.6–14.8 ms (load 8.5) |
| `tools/verify-all.sh` | all | `42bba0b`: 14 PASS; `dc62e65`: 15 PASS (adds `settings-preview`); merges with `724e35d`, `c95be65`, `211a8bb`: 15 PASS each; final merge with `f41955c`: 15 PASS; no SKIP |
| Coverage join (§2) with a fresh `commands-dump --markdown` | both | Same counts on both trees |
| `git grep` for library types in `App/` on `origin/main` and `origin/t3/app-shell-real-window` | both | No App use of `MenuBuilder`, `CommandBarController`, `SuggestEngine`, `HistoryStore`, `FaviconStore`, `BoostStore`, `AdBlockStore`, `SleepController`, `ScriptHost`, `RoutingEvaluator`, `GlobalHotkeyService`, `archiveExpiredTabs` |
| Diff of the MH menu tables against `expected-menu.json` | both | 1 Arc item missing (Reveal Tab in Sidebar); 2 extra standard macOS items |

### 6.1 Doc and code drift found

- `docs/commands.md` command table: the Cmd+O title is stale (§2.3).
- `docs/architecture.md` module list puts Boosts, Zap, Site Control Center, ad blocking, and Air Traffic Control in `OpenFeatures`. They live in `OpenBoosts`, `OpenAdBlock`, and `OpenRouting`; Site Control Center has no library yet.
- Before #51, `main` defaulted new profiles to DuckDuckGo (`OpenModel/Containers.swift`), while FC §4.5 r11 and `docs/suggest.md` say Google. #51 fixed it.
- app-shell §4.3 lists `copy-url` and `copy-url-markdown` but not `copy-url-quote`, and no system ids (§3, gap 3).
- app-shell §3.7 reuses a bottom-center black toast; IS §16 measures a Space-tinted toast at the top right of the page.

## Appendix A. Every in-scope Arc menu item

`main` and `PR #52`: Y = works like Arc, P = partial, — = not wired. The plan column names the plan for the missing part. "system (no dispatch spec)" means app-shell §4.3 names no handler (§3, gap 3). Two rows (Emoji & Symbols, Show Fonts) are standard macOS items that the reference table adds.

| Menu | Arc item | Arc key | Registry id | main | PR #52 | Plan for the missing part |
|---|---|---|---|---|---|---|
| Open | About Open | — | `about-open` | Y | Y | app-shell §4.3 |
| Open | Set as Default Browser | — | `set-default-browser` | — | — | app-shell §4.3, settings adapter |
| Open | Settings… | Cmd+, | `settings` | — | — | app-shell §4.3, settings adapter |
| Open | Check for Updates… | — | `check-for-updates` | — | — | app-shell §4.3 |
| Open | Import from Another Browser… | — | `import-from-browser` | — | — | app-shell §4.3, settings adapter |
| Open | Hide Open | Cmd+H | `hide-open` | Y | Y | — |
| Open | Hide Others | Cmd+Opt+H | `hide-others` | — | — | system (no dispatch spec) |
| Open | Show All | — | `show-all` | — | — | system (no dispatch spec) |
| Open | Quit Open | Cmd+Q | `quit-open` | Y | Y | — |
| File | New Tab… | Cmd+T | `new-tab` | P | P | app-shell §4.3 |
| File | Open Command Bar | Cmd+L | `open-command-bar` | P | P | app-shell §4.3 |
| File | New Window | Cmd+N | `new-window` | — | Y | app-shell §4.3 |
| File | New Incognito Window | Cmd+Shift+N | `new-incognito-window` | — | — | app-shell §4.3 |
| File | New Little Arc Window | Cmd+Opt+N | `new-little-open-window` | — | — | app-shell §4.3 |
| File | Blank Window | Cmd+Ctrl+N | `blank-window` | — | — | app-shell §4.3 |
| File | Archive Tab | Cmd+W | `archive-tab` | Y | Y | app-shell §4.3 |
| File | Close Window | Cmd+Shift+W | `close-window` | — | — | app-shell §4.3 |
| File | Restore Last Closed Tab | Cmd+Shift+T | `restore-last-closed-tab` | Y | Y | app-shell §4.3 |
| File | Print… | Cmd+P | `print` | Y | Y | app-shell §4.3 |
| File | Save Page As… | Cmd+Shift+S | `save-page-as` | — | — | app-shell §4.3 |
| File | Share… | — | `share-page` | — | — | app-shell §4.3 |
| File | Capture… | Cmd+Shift+2 | `capture-page` | — | — | none |
| File | Capture Full Page | — | `capture-full-page` | — | — | none |
| File | Capture in Portrait Mode | — | `capture-portrait` | — | — | none |
| File | New Profile | — | `new-profile` | — | — | none (`OpenSettings` has the create sheet) |
| File | New Boost | — | `new-boost` | — | — | none (Boost editor plan in progress) |
| File | Edit Boost | — | `edit-boost` | — | — | none (Boost editor plan in progress) |
| File | New Legacy Boost (Advanced) | — | `new-legacy-boost` | — | — | none (Boost editor plan in progress) |
| File | Boost Gallery | — | `boost-gallery` | — | — | none (Boost editor plan in progress) |
| Edit | Undo | Cmd+Z | `undo` | Y | Y | — |
| Edit | Redo | Cmd+Shift+Z | `redo` | Y | Y | — |
| Edit | Cut | Cmd+X | `cut` | Y | Y | — |
| Edit | Copy | Cmd+C | `copy` | Y | Y | — |
| Edit | Paste | Cmd+V | `paste` | Y | Y | — |
| Edit | Paste and Match Style | Cmd+Shift+V | `paste-and-match-style` | — | — | system (no dispatch spec) |
| Edit | Delete | — | `delete` | — | — | system (no dispatch spec) |
| Edit | Select All | Cmd+A | `select-all` | Y | Y | — |
| Edit | Copy URL | Cmd+Shift+C | `copy-url` | — | — | app-shell §4.3 |
| Edit | Copy URL as Markdown | Cmd+Opt+Shift+C | `copy-url-markdown` | — | — | app-shell §4.3 |
| Edit | Copy URL as Quote | Cmd+Ctrl+Shift+C | `copy-url-quote` | — | — | none |
| Edit | Emoji & Symbols | Cmd+Ctrl+Space | `emoji-and-symbols` | — | — | system (no dispatch spec) |
| Edit > Find | Find… | Cmd+F | `find` | P | P | app-shell §4.3 |
| Edit > Find | Find Next | Cmd+G | `find-next` | Y | Y | app-shell §4.3 |
| Edit > Find | Find Previous | Cmd+Shift+G | `find-previous` | — | — | app-shell §4.3 |
| Edit > Find | Find and Replace… | Cmd+Opt+F | `find-and-replace` | — | — | system (no dispatch spec) |
| Edit > Find | Use Selection to Find | Cmd+E | `use-selection-to-find` | — | — | system (no dispatch spec) |
| Edit > Find | Jump to Selection | Cmd+J | `jump-to-selection` | — | — | system (no dispatch spec) |
| Edit > Spelling and Grammar | Show Spelling and Grammar | Cmd+: | `show-spelling` | — | — | system (no dispatch spec) |
| Edit > Spelling and Grammar | Check Document Now | Cmd+; | `check-spelling` | — | — | system (no dispatch spec) |
| Edit > Spelling and Grammar | Check Spelling While Typing | — | `check-spelling-while-typing` | — | — | system (no dispatch spec) |
| Edit > Spelling and Grammar | Check Grammar With Spelling | — | `check-grammar` | — | — | system (no dispatch spec) |
| Edit > Spelling and Grammar | Correct Spelling Automatically | — | `correct-spelling-automatically` | — | — | system (no dispatch spec) |
| Edit > Substitutions | Show Substitutions | — | `show-substitutions` | — | — | system (no dispatch spec) |
| Edit > Substitutions | Smart Copy/Paste | — | `smart-copy-paste` | — | — | system (no dispatch spec) |
| Edit > Substitutions | Smart Quotes | — | `smart-quotes` | — | — | system (no dispatch spec) |
| Edit > Substitutions | Smart Dashes | — | `smart-dashes` | — | — | system (no dispatch spec) |
| Edit > Substitutions | Smart Links | — | `smart-links` | — | — | system (no dispatch spec) |
| Edit > Substitutions | Text Replacement | — | `text-replacement` | — | — | system (no dispatch spec) |
| Edit > Substitutions | Data Detectors | — | `data-detectors` | — | — | system (no dispatch spec) |
| Edit > Transformations | Make Upper Case | — | `make-upper-case` | — | — | system (no dispatch spec) |
| Edit > Transformations | Make Lower Case | — | `make-lower-case` | — | — | system (no dispatch spec) |
| Edit > Transformations | Capitalize | — | `capitalize` | — | — | system (no dispatch spec) |
| Edit > Speech | Start Speaking | — | `start-speaking` | — | — | system (no dispatch spec) |
| Edit > Speech | Stop Speaking | — | `stop-speaking` | — | — | system (no dispatch spec) |
| Edit > Format > Font | Show Fonts | Cmd+T | `show-fonts` | — | — | system (no dispatch spec) |
| Edit > Format > Font | Bold | Cmd+B | `font-bold` | — | — | system (no dispatch spec) |
| Edit > Format > Font | Italic | Cmd+I | `font-italic` | — | — | system (no dispatch spec) |
| Edit > Format > Font | Underline | Cmd+U | `font-underline` | — | — | system (no dispatch spec) |
| View | Show/Hide Sidebar | Cmd+S | `toggle-sidebar` | P | Y | app-shell §4.3 |
| View | Show/Hide Toolbar | Cmd+Shift+D | `toggle-toolbar` | — | — | none |
| View | Enter Full Screen | Cmd+Ctrl+F | `toggle-full-screen` | Y | Y | app-shell §4.3 |
| View | Refresh the Page | Cmd+R | `reload` | Y | Y | app-shell §4.3 |
| View | Force Refresh the Page | Cmd+Shift+R | `force-reload` | — | — | app-shell §4.3 |
| View | Stop Loading | Cmd+. | `stop-loading` | Y | Y | app-shell §4.3 |
| View | Clear Cache and Refresh | — | `clear-cache-and-refresh` | — | — | none |
| View | Clear Cookies and Refresh | — | `clear-cookies-and-refresh` | — | — | none |
| View | Zoom In | Cmd++ | `zoom-in` | Y | Y | app-shell §4.3 |
| View | Zoom Out | Cmd+- | `zoom-out` | Y | Y | app-shell §4.3 |
| View | Zoom to Actual Size | Cmd+0 | `zoom-actual-size` | Y | Y | app-shell §4.3 |
| View | Add Split View | Ctrl+Shift+= | `add-split-view` | P | P | app-shell §4.3, OpenFeatures |
| View | Close this Split Pane | Ctrl+Shift+- | `close-split-pane` | — | P | app-shell §4.3, OpenFeatures |
| View | Expand Current Split | — | `expand-current-split` | — | — | OpenFeatures |
| View | Separate Page from Split View | — | `separate-from-split-view` | — | — | OpenFeatures |
| View | Reveal Current Tab | Ctrl+Space | `reveal-current-tab` | — | — | app-shell §4.3 |
| View | Expand Pinned Section | — | `expand-pinned-section` | — | — | app-shell §4.3 |
| View | Collapse Pinned Section | — | `collapse-pinned-section` | — | — | app-shell §4.3 |
| View | Cast… | — | `cast` | — | — | none |
| View | Exit | Esc | `exit-modal` | — | — | none (OpenFeatures handles Esc for Peek and a maximized split) |
| View > Appearance | Automatic | — | `appearance-automatic` | — | — | none |
| View > Appearance | Light | — | `appearance-light` | — | — | none |
| View > Appearance | Dark | — | `appearance-dark` | — | — | none |
| View > Developer | Developer Tools | F12 | `developer-tools` | Y | Y | app-shell §4.3 |
| View > Developer | JavaScript Console | Cmd+Opt+J | `javascript-console` | — | — | app-shell §4.3 |
| View > Developer | View Source | Cmd+Opt+U | `view-source` | — | — | app-shell §4.3 |
| View > Developer | Inspect Elements | Cmd+Opt+C | `inspect-elements` | — | — | app-shell §4.3 |
| View > Developer | Network Inspector | — | `network-inspector` | — | — | none |
| View > Developer | Toggle Developer Mode | Ctrl+D | `toggle-developer-mode` | — | — | none |
| View > Developer | Allow JavaScript from Apple Events | — | `allow-js-apple-events` | — | — | none |
| Spaces | Next Space | Cmd+Opt+Right | `next-space` | Y | Y | app-shell §4.3 |
| Spaces | Previous Space | Cmd+Opt+Left | `previous-space` | Y | Y | app-shell §4.3 |
| Spaces | New Space… | — | `new-space` | — | — | app-shell §4.3 |
| Spaces | Manage Spaces… | — | `manage-spaces` | — | — | none |
| Spaces | Rename Space | — | `rename-space` | — | — | none (sidebar inline rename exists) |
| Spaces | Edit Theme… | — | `edit-theme` | — | — | none (theme editor plan in progress) |
| Spaces | Change Profile | — | `change-profile` | — | — | none (sidebar Set Profile menu exists) |
| Tabs | New Tab… | Cmd+T | `new-tab` | P | P | app-shell §4.3 |
| Tabs | Pin/Unpin Tab | Cmd+D | `pin-unpin-tab` | Y | Y | app-shell §4.3 |
| Tabs | Duplicate | — | `duplicate-tab` | — | — | app-shell §4.3 |
| Tabs | Rename Current Item | — | `rename-tab` | — | — | app-shell §4.3 |
| Tabs | Reset Tab to Original URL | — | `reset-tab` | — | — | app-shell §4.3 |
| Tabs | Reset all tabs in this Space | — | `reset-all-tabs-in-space` | — | — | none |
| Tabs | Next Tab | Cmd+Opt+Down | `next-tab` | Y | Y | app-shell §4.3 |
| Tabs | Previous Tab | Cmd+Opt+Up | `previous-tab` | Y | Y | app-shell §4.3 |
| Tabs | Cycle Tab Forward | Cmd+Ctrl+Right | `cycle-tab-forward` | — | — | app-shell §4.3 |
| Tabs | Cycle Tab Backward | Cmd+Ctrl+Left | `cycle-tab-backward` | — | — | app-shell §4.3 |
| Tabs | Tab Switcher (forward) | Ctrl+Tab | `tab-switcher-forward` | P | P | app-shell §4.3 |
| Tabs | Tab Switcher (backward) | Ctrl+Shift+Tab | `tab-switcher-backward` | P | P | app-shell §4.3 |
| Tabs | New Folder… | Cmd+Shift+N | `new-folder` | — | — | app-shell §4.3 |
| Tabs | Expand All Folders | — | `expand-all-folders` | — | — | none |
| Tabs | Collapse All Folders | — | `collapse-all-folders` | — | — | none |
| Tabs | Clear Unpinned Tabs | Cmd+Shift+K | `clear-unpinned-tabs` | — | — | app-shell §4.3 |
| Tabs | Peek Email… | Cmd+Shift+E | `peek-email` | — | — | app-shell §4.3 |
| Tabs | Join Meeting | Cmd+Ctrl+J | `join-meeting` | — | — | none |
| Tabs | Open Little Arc or Peek in… | Cmd+O | `open-in-current-space` | — | P | app-shell §4.3, OpenFeatures |
| Tabs | Reveal Tab in Sidebar | — | not registered | — | — | none (missing from `expected-menu.json`) |
| Archive | Go Back | Cmd+[ | `go-back` | Y | Y | app-shell §4.3, OpenFeatures |
| Archive | Go Forward | Cmd+] | `go-forward` | Y | Y | app-shell §4.3, OpenFeatures |
| Archive | View History | Cmd+Y | `view-history` | — | — | settings adapter |
| Archive | View Archive | — | `view-archive` | — | — | settings adapter |
| Archive | Clear Archive | — | `clear-archive` | — | — | none (`OpenSettings` Library has Clear) |
| Extensions | Manage Extensions… | — | `manage-extensions` | P | P | app-shell §4.3 |
| Extensions | Add Extension… | — | `add-extension` | — | — | app-shell §4.3 |
| Window | Minimize | Cmd+M | `minimize-window` | Y | Y | — |
| Window | Zoom | — | `zoom-window` | — | — | system (no dispatch spec) |
| Window | View Downloads | Cmd+Shift+J | `view-downloads` | — | — | app-shell §4.3, settings adapter |
| Window | View Library | Cmd+Shift+L | `view-library` | — | — | app-shell §4.3, settings adapter |
| Window | View Media | — | `view-media` | — | — | none (`OpenSettings` Library has Media) |
| Window | View Boosts | — | `view-boosts` | — | — | app-shell §4.3 |
| Window | Bring All to Front | — | `bring-all-to-front` | — | — | system (no dispatch spec) |
| Help | Open Help Center | — | `help-center` | — | — | app-shell §4.3 |
| Help | Getting Started | — | `getting-started` | — | — | app-shell §4.3 |
| Help | Essential Keyboard Shortcuts | — | `keyboard-shortcuts-edu` | — | — | app-shell §4.3 |
| Help | Release Notes | — | `release-notes` | — | — | app-shell §4.3 |
| Help | Contact the Team | — | `contact-team` | — | — | app-shell §4.3 |
| Help > Troubleshooting | Open Task Manager | — | `task-manager` | — | — | none |
| Help > Troubleshooting | Record Trace | — | `record-trace` | — | — | none |
| Help > Troubleshooting | Cancel Trace | — | `cancel-trace` | — | — | none |
| Help > Troubleshooting | Copy Open Info | — | `copy-open-info` | — | — | none |
| Help > Troubleshooting | Reveal Open Data | — | `reveal-open-data` | — | — | none |
