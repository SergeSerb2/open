# Open v1 status inventory

Refreshed 2026-10-26 by the lead (main `94ffd62`); counts PRs through #118 plus #108 and #110.

Section 8 reconciliation (2026-11-05): merged [#149](https://github.com/SergeSerb2/open/pull/149), [#152](https://github.com/SergeSerb2/open/pull/152), [#153](https://github.com/SergeSerb2/open/pull/153), [#154](https://github.com/SergeSerb2/open/pull/154), [#156](https://github.com/SergeSerb2/open/pull/156), [#158](https://github.com/SergeSerb2/open/pull/158), [#160](https://github.com/SergeSerb2/open/pull/160), [#162](https://github.com/SergeSerb2/open/pull/162), [#163](https://github.com/SergeSerb2/open/pull/163), [#164](https://github.com/SergeSerb2/open/pull/164), [#165](https://github.com/SergeSerb2/open/pull/165). Checks below are saved PR evidence, not new runtime runs. G2 App sleep acceptance is included. Idle CPU, cold launch and other speed gates remain separate.

Section 6 reconciliation (2026-11-06): main includes [#175](https://github.com/SergeSerb2/open/pull/175) (UI kit), [#177](https://github.com/SergeSerb2/open/pull/177) (P3), [#179](https://github.com/SergeSerb2/open/pull/179) (command bar/Settings), [#184](https://github.com/SergeSerb2/open/pull/184) (E11/E12, tab events and pin safety), and [#189](https://github.com/SergeSerb2/open/pull/189) (App wiring). [Closeout PR](https://github.com/SergeSerb2/open/pull/190) adds real-App X-27. Saved suite evidence belongs to each named PR; the closeout receipt is recorded separately in [extensions closeout](engine-spike/extensions-closeout-receipt.md). X-13 (Section 12), global OS shortcut delivery, packed permission-increase updates, and reference captures remain open.

Section 1 reconciliation (2026-10-28): sidebar rows below count merged PRs #123–#135 through main `52212f17`. Saved PR receipts retain their original revisions and results. Captures and the [final-main soak](verification.md#section-1-completion-2026-10-28) remain pending; other sections and the first-audit counts are not refreshed here.

First audit date: 2026-10-25 (America/Vancouver). First base: `origin/main` at `f41955c`. This refresh uses branch `t3/27419945` at main `94ffd62`. It counts merged PRs through #118 plus #108 and #110. It counts open PRs only as work in flight (§0.3).

This file lists every v1 line item from the RE catalog (`docs/re/`), the AGENTS.md v1 scope, and the platform basics a browser needs. For each item it names the plan, the library code, the App wiring, and the evidence. It is an inventory. It changes no code.

Arc capture session 2 (2026-10-26, `re/interaction-states.md` §20, `re/capture-session-2-results.md`, #108): notes that start with "S2 (2026-10-26)" carry its facts, including the folder hover-card video sample (V 46.11–46.46 s) and the Essential Keyboard Shortcuts row.

## 0. How to read this file

### 0.1 Status values

| Status | Meaning |
|---|---|
| **done** | A user can use it in the app built from `main` today. On `main` the App is now the real Arc window (app-shell Steps A–C merged: PR #45, #52, #85). "done" means the App shows it, not only a library or a harness. Where code exists only in a library or a harness, the note says "library only" and the status stays **planned**. |
| **in PR** | Its code is in an open PR (§0.3). It does not count as done. |
| **planned** | A plan names the missing part. Library code can already exist on `main`. |
| **unplanned** | No plan covers the missing part. Library code can exist (the note says so). |
| **out of scope** | Excluded by AGENTS.md (accounts, sync, Easels, Notes, Arc Max) or by a lead decision. Listed only so nobody builds it by accident. |

"(partial)" after a status means part of the row works and the note says which part.

### 0.2 Short names

- RE docs: **FC** `re/features-core.md`, **FA** `re/features-advanced.md`, **MH** `re/menus-and-hotkeys.md`, **IS** `re/interaction-states.md`, **DM** `re/data-model.md`, **DT** `re/design-tokens.md`, **RO** `re/runtime-observations.md`. "r9" means rule 9 in that section.
- Plans (`docs/plans/`): `app-shell`, `media-pip`, `m4` (`m4-split-peek-littleopen`), `routing` (`routing-little-open`), `profiles`, `settings` (`settings-library`), `boosts-zap`, `adblock-fork`, `memory-fork`, `import2` (`import-phase2`), `applescript`, `first-run`, `release`, `fork-infra`, plus plans merged since the first audit: `extensions-ui` (#58), `site-control-boost-editor` (#61, spec replaced by #107), `space-theme-editor` (#62), `commandbar-completion` (#70), `sidebar-completion` (#71), `passwords-autofill` (#72), `page-platform` (#73). Step letters (Step C, Step E…) are app-shell §7 steps.
- Library paths are under `Packages/OpenKit/Sources/`.
- App wiring: **main** (M1 shell on `main`), **PR #45/#52/#53** (real app of that PR), **none**.
- Harness checks run in this audit (§6): `sidebar-render check` 125/125, `features-render check` 147/147, `commandbar-render check` 78/78, `commands-dump` OK, `settings-preview check`, and `tools/verify-all.sh`. Check IDs such as `features-render S3` come from the check output.
- App wiring: **main** (the real window on `main`), **none**, or the open PR that adds it.
- Harness checks named in the first audit (§6) stay as they were. This refresh ran no builds and no harness (§6). It read PR bodies, plans, `docs/followups.md`, and code on `main`. Check IDs such as `features-render S3` come from the first audit or from a PR body.
- e2e suites: `tools/e2e/engine_e2e.py --only <suite>`. On `main` now: `shell`, `features`, `extensions`, `measure`, `window`, `sidebar`, `peek` (PR #52, merged), `tabstrip` and `profiles` (PR #53, #88, merged). Section 6 also uses `actions`, `extensions-p3`, `extensions-e2`, `extensions-ui`, and `find`; see §1.16. Results: `docs/engine-spike/results-*.json`.

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
| Extensions P1 tab-strip bridge | [#53](https://github.com/SergeSerb2/open/pull/53), [#184](https://github.com/SergeSerb2/open/pull/184) | done; `extensions`, `tabstrip`, `extensions-e2` |
| Extensions P2 toolbar actions and popups | main ([#93](https://github.com/SergeSerb2/open/pull/93)); App strips [#175](https://github.com/SergeSerb2/open/pull/175), [#189](https://github.com/SergeSerb2/open/pull/189) | done; `actions`, `extensions-ui` |
| Space creation + theme editor plan | branch `plan/space-theme-editor` | plan in progress |
| Site Control Center + Boost editor plan | branch `plans/site-control-boost-editor` | plan in progress |
| Media controls + Picture in Picture plan | PR #59, merged to `main` as `211a8bb` during this audit (`docs/plans/media-pip.md`) | planned (rows cite `media-pip`) |
| Extensions UI | main: [#175](https://github.com/SergeSerb2/open/pull/175), [#177](https://github.com/SergeSerb2/open/pull/177), [#179](https://github.com/SergeSerb2/open/pull/179), [#184](https://github.com/SergeSerb2/open/pull/184), [#189](https://github.com/SergeSerb2/open/pull/189) | wired; explicit S9/S12 dependencies in §1.16 |
| Site Control Step 1 (popover chrome, render harness) | PR #69, branch `t3/site-control-boost-editor-1` | in PR |
| Site Control Center Step 2 (sections, menu, picker) | PR #96, branch `t3/site-control-boost-editor-2` | in PR |
| Boost editor Step 4 (native controls, wheel, undo) | PR #103, branch `t3/site-control-boost-editor-4` | in PR |
| Page context-menu allowlist | PR #94, branch `m7/context-menu-allowlist` | in PR |
| Ad-block Step 2 (Rust shim) | PR #98, branch `m6/adblock-shim` | in PR |
| Ad-block Step 3 (per-Profile C++ service) | PR #100, branch `m6/adblock-service` | in PR |
| Plans: Arc capture session 2 facts | PR #108, merged during this refresh | merged (docs only) |
| Media Step 3b (mini-player redesign) | PR #110, merged during this refresh | merged; App wiring still Step 6 |
| Engine launch race and full-screen test fix | PR #112, branch `engine/launch-zone-and-fullscreen` | in PR |
| App shell Step D (page features: downloads UI, find, context menus, permissions) | unpublished work; no open PR at this refresh | in flight; not counted as wired |
| Theme Step 9 (pad-law calibration; RE + plan merged in PR #114) | unpublished work; no open PR at this refresh | in flight; not counted as wired |

Merged since the first audit and now counted on `main`: app shell Steps A–C (#45, #52, #85), P1 tab-strip bridge (#53), release Step 11 (#57), and the plans in §0.2. Open PRs were checked again when this refresh ended (`gh pr list --state open`: #69, #93, #94, #96, #98, #100, #103, #112). PR #108 and #110 merged during the refresh.

### 0.4 Headline

- The App on `main` is now the real Arc window. App shell Steps A–C merged (#45, #52, #85). The App links `OpenModel`, `OpenStore`, `OpenWeb`, `OpenFeatures`, `OpenSettings`, `OpenCommandBar`, `OpenCommands`, `OpenSuggest`, `OpenSidebar`, and `OpenDesign` (`project.yml`, target `Open`).
- Step C (#85) wires the command bar, the registry menus, one keyboard router per window, and the Settings and Library presenters in the App (`App/CommandBar/AppCommandBarDelegate.swift`, `App/MainMenu.swift`, `App/Settings/AppSettingsActions.swift`, `App/Stores/AppStores.swift`). `App/` now uses `MenuBuilder`, `CommandBarController`, `SuggestEngine`, `HistoryStore`, `FaviconStore`, `AdBlockStore` (settings only; no blocking yet), and `GlobalHotkeyService` (real Little Open windows; §1.9). `SleepController` runs in the App since app-shell Step G (`App/Sleep/`, stock engine API). Today and Little Open auto-archive share `ExpirySweeper` in `App/AutoArchive/`.
- The gap is now single features, not the shell. The top open gaps moved from "unplanned" to "planned": passwords and secrets import now have a plan (#72), and system-menu dispatch is closed (#85). Daily use still needs a password manager and a write path for imported secrets. Today auto-archive is now on main in #130 (§3), with shown-tab protection and activity measured from final deselection.

Row count by status (other areas retain their historical counts; §1.16 is refreshed with 14 unique rows on 2026-11-06; a "(partial)" row counts under its base status):

| Area | done | in PR | planned | unplanned | out of scope |
|---|---:|---:|---:|---:|---:|
| 1.1 Sidebar | 23 | 0 | 5 | 0 | 0 |
| 1.2 Spaces | 10 | 0 | 6 | 0 | 2 |
| 1.3 Tabs | 22 | 0 | 6 | 1 | 0 |
| 1.4 Favorites | 5 | 0 | 0 | 0 | 0 |
| 1.5 Folders | 6 | 0 | 3 | 0 | 0 |
| 1.6 Archive | 4 | 0 | 0 | 1 | 0 |
| 1.7 Command bar | 11 | 0 | 4 | 0 | 1 |
| 1.8 Menus and hotkeys | 7 | 0 | 1 | 0 | 0 |
| 1.9 Split View, Peek, Little Open | 27 | 0 | 1 | 1 | 1 |
| 1.10 Profiles | 4 | 0 | 6 | 0 | 0 |
| 1.11 Air Traffic Control | 3 | 0 | 2 | 1 | 0 |
| 1.12 Boosts and Zap | 1 | 1 | 5 | 1 | 1 |
| 1.13 Site Control Center | 0 | 6 | 3 | 0 | 0 |
| 1.14 Ad blocking | 2 | 1 | 3 | 1 | 0 |
| 1.15 Import from Arc | 1 | 0 | 10 | 1 | 1 |
| 1.16 Extensions | 11 | 0 | 1 | 0 | 2 |
| 1.17 Engine and platform basics | 19 | 1 | 24 | 1 | 1 |
| 1.18 Settings and Library | 10 | 0 | 0 | 0 | 2 |
| 1.19 First run | 0 | 0 | 4 | 0 | 0 |
| 1.20 Release | 2 | 0 | 7 | 0 | 0 |
| **Total (mixed audit dates)** | **157** | **9** | **101** | **8** | **11** |


## 1. Feature tables

Columns: feature · RE doc + section · plan · library code · App wiring · verified how · status · notes.

### 1.1 Sidebar: window chrome, rows, controls

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Arc window chrome: hidden title bar, system traffic lights, theme background, inset rounded web panel (10 pt, radius 6, shadow) | FC §8.2 r7; RO §1.1–1.2 | app-shell §3.1–3.2 | `OpenDesign/ThemeBackgroundView.swift`, `OpenDesign/Metrics.swift` (`WindowMetrics`, `PanelMetrics`) | main | e2e `window` (#52, merged, 38 functional PASS); live static compare vs capture F0001: 31 elements, worst 1.0 pt, ΔE00 1.61 (`docs/app-shell.md`) | done | Traffic-light placement and dimmed look fixed in #90 and #104. |
| Section order: Favorites, Pinned, divider, New Tab row, Today | FC §1.1 r1–5; IS §6 | `docs/design.md` §5 | `OpenSidebar/SpacePageView.swift`, `OpenSidebar/FavoritesView.swift` | main | `sidebar-render check`; e2e `sidebar` 18/18 (#52, merged) | done | |
| Tab row states: hover fill, selected fill and shadow, close ×, "−" on loaded pinned rows | FC §1.2 r8, r11; IS §3 | design.md §5.3 | `OpenSidebar/SidebarRows.swift` | main | `sidebar-render check`; design.md §8 (ΔE ≤ 2.03); selected-row radius token fixed in #113 | done | |
| Engine favicon on loaded rows | FC §1.2 r8 | app-shell §4.13 | — | main (#131) | `sidebar-completion` FV1–FV2: engine report and replacement pixels; `EngineWebContentHost.swift` `onFaviconChange` | done | |
| Stored favicons for unloaded and imported rows | FC §1.2 r8 | app-shell §4.8 (favicon part of Step H) | `OpenStore/FaviconStore.swift`, `StoredFaviconCache.swift`; App engine ownership hook; shared `FaviconView` | main (#131) | `favicons`; `features-render` FV1–FV10, FV13, FV15–FV17; real-App `sidebar-completion` FV1–FV6, FV14, FV16 | done | PR #131 final gate 22/22 PASS; real-App `sidebar-completion` 158/158 and `app-actions` 49/49. The FV17 harness fix changes favicon-check 32/33 to 33/33 after stale revocation. Stored-icon scroll p95 0.86 ms at 1,000 rows; delayed-draw negative proof p95 30.88 ms FAIL. FV16 failed on `5fdaa84f`, then passed: missing/404 destinations keep placeholders and zero records after relaunch; FV14 unchanged-icon path still passes. Confirm document/icon ownership before same-origin copy; preserve existing records; revoke only tagged copies. Bounded async store/cache and page URL keys serve unloaded pins, slept rows, URL-only imported rows, Favorites and Library archive rows. Import has no mapped icon bytes; unknown pages keep placeholders. |
| Per-tab audio icon and mute button | FC §1.2 r10 | app-shell §4.1; media-pip | `SidebarRows.swift`; model `setMuted` | main (`toggleMute` sets host `isMuted`) | e2e `features` "Audible state and mute" (`docs/engine-spike.md`); row speaker finished in #67; leading speaker in media-pip Step 2b (`sidebar-render check` RI1–RI5, `compare-media --state row-audible/row-muted` vs S2 12/0022, 0027 within 1 pt and ΔE00 2; real App window vs 12/0022, 12/0027, 13/0002, 14b/0014: ≤ 1 pt, ΔE00 ≤ 1.21, `Packages/OpenKit/MediaRenders/section3-parity/`) | done (partial) | Audible is Chromium's tab audio signal (patch P6 in the fork's media controller, Section 3 Step 7), so Web Audio counts (e2e `media` `media_web_audio`). Step 2b: the speaker is **leading**, a 26 × 26 button with an outline glyph right after the favicon, and the title moves from x 43 to x 69 (IS §20.7, C18). The hover plate is a guess (no capture). |
| Mute all tabs / Unmute all tabs | FC §1.2 r10, §4.4 | media-pip (command-bar actions, §4.8, Q10) | `OpenCommands/CommandRegistry.swift` (`mute-all-tabs`, `unmute-all-tabs`, no menu); `App/Media/MediaCoordinator.swift` `muteAll` | main | `commands-dump` (registered); e2e `media` `media_mute_all` | done | App-wide, one Undo step: Mute every tab with a live page, Unmute every muted tab (Section 3 Steps 5–6). Each page host follows its tab's `isMuted` by Observation, so Undo/Redo reach the engine. |
| Recording indicator on rows (camera or microphone in use) | FC §1.2 r10 (2026-10-25 update); FA §8 | media-pip | `OpenSidebar/SidebarRows.swift` (lazy recording slot, #67) | main | `sidebar-render check` recording rows (#67; RI3 leading slot in Step 2b) | done | The row slot is in the App sidebar. Live capture state still comes from the engine. Step 2b moved the dot to a leading 14 pt slot after the favicon and before the speaker; the title moves right by 14 as well. Leading placement is a guess (no capture; Arc names `hasLeadingRecordingIndicator`). |
| Tidy titles for known sites (for example Gmail fragment → "Inbox") | FC §1.2 r9 | sidebar-completion (M3) | Open-written rule table; `displayTitle` in `OpenModel`, rows in `OpenSidebar` | main | 42 display fixtures; real sidebar rename flow (#78) | done | Merged in #78. Rename and search keep the raw title. See §3, gap 20 (closed). |
| Unread badge on rows added in the background | FC §1.2 r12 | sidebar-completion (M1, S3) | model field `Tab.isUnread` (`OpenModel/LiveNodes.swift`); dot in `OpenSidebar` | main (#75, #95, #127) | `sidebar-render check` unread dot with snapshot roundtrip (#95) | done (partial) | Merged in #75 (inputs), #95 (dot), and #127 (engine background-open trigger). Capture C5 remains open for Arc trigger/appearance calibration. See §3, gap 21 (closed). |
| Hover Previews of folder, pinned, and favorite rows | FC §1.2 r13; IS §18 General, §20.13 | sidebar-completion §3.6 (S5, #102; A2) | `OpenSidebar/HoverPreviewTracker.swift`, `FolderPreviewView.swift` (#102); `OpenFeatures/HoverPreviewController.swift` (A2); `OpenSettings` sheet | main (#127) | `sidebar-render check` HP1–HP6 (#102, #115); `features-render` HP7–HP10, SP5–SP6; e2e `sidebar-completion` E11–E14 (A2), including E12 MRU Control-release host reuse after the #127–#130 merge | done (partial) | A2: the App opens the preview panel. Page previews of pinned tabs and Favorites show the live page through the Peek host, 420 × min(560, H − 20) pt at sidebar width + 8; the folder card (240 pt, "Search <folder>…", two-line rows with "N minutes ago") sits at sidebar width + 4. Any other sidebar intent hides the preview. Separate From Pinned Tab (⌥-click on the reset plate) moves the live page into a new Today tab (same engine page, history intact) and puts the pinned tab back to its pinned URL, unloaded. Background opens are unread. No delay setting: fixed 0.5 s, an Open choice (one Arc sample ≈ 0.42 s, V 46.11–46.46 s; Step S5b, merged #123). Lead decision S2: two Previews sources, "Folders" and "Pinned tabs and Favorites"; Arc's live-data sources are post-v1. The Today auto-archive sweeper (item 6, merged #130) now triggers the existing education banner after a shown-Space archive. Capture C4 and calibration C remain open for card geometry/colors; the folder video proves positions only. |
| Rename a row inline (double-click, "Rename…", Return, Esc) | FC §1.3 r15–16 | design.md §5.6 | `SpacePageView.swift` (`doubleAction` → `beginRename`); model `renameNode` | main | `sidebar-render check` (menus); real editor flow in #78 | done | Tabs ▸ Rename Current Item also works (`App/MainMenu.swift` `rename-tab`, #85). |
| Row context menus: Today tab, pinned tab, favorite, folder, split row, Space, plus | IS §15; MH "Context menus", "Split row menu" | design.md §5.6 | `OpenSidebar/SidebarMenus.swift` | main (#128, #132; partial) | `sidebar-render check` (order for 4 targets) | done (partial) | Merged A3 (#128) adds selection Copy Links/Markdown and Move to/New Space, and folder Copy All Links. Space export already uses the package fallback and has E10 browser/Manager proof. Merged #132 adds folder → Space, single-row Move to New Space, tab Share, and a disabled Share Space. Site Control, Space icon/theme, New Profile, Edit Pinned URL, Change Icon and Customize Page remain in their assigned lanes. Favorite and plus menu appearance remain guesses (design.md §5.6); `favorites-hover` and C1 capture requests remain open. |
| Multi-select rows (Shift/Cmd click) and New Folder from Selection | FC §1.5 r24; MH "Gestures and mouse" | sidebar-completion (S1, S2) | `OpenSidebar/SidebarSelection.swift`; bulk model commands (#75) | main (#128) | `sidebar-completion` E1–E4; `sidebar-render` and `commands-demo` | done (partial) | A3 routes menu and App-key Pin/Unpin, Duplicate, and sidebar-focused New Folder through the ordered selection. Same-title folder rename adds no undo. Real native input, one-step undo, and actual engine pin flags pass; drop proof uses the production intent, not an OS drag session. Capture C1 remains open for selection fill, menus and native drag appearance. |
| Drag and drop: reorder, Today ↔ Pinned (pin/unpin), into folders, Favorites, URLs from other apps, Space icon hover-switch | FC §1.6 r28–32 | design.md §5.5 | `OpenSidebar/DragDrop.swift`; model `canMoveNode` | main | `sidebar-render check` (drop mapping, cross-Space drag, refusals, bulk drags in #91); e2e `sidebar` (reorder through the production intent) | done | No test drives a real macOS drag session (`docs/app-shell.md`). |
| Haptic feedback when reordering | FC §1.6 r33; IS §18 Advanced | sidebar-completion (S4); settings | `OpenSidebar/SidebarHaptics.swift`; `OpenSettings` switch | main | `sidebar-render check` haptics (#99) | done | Merged in #99. The live preference is read at the interaction point. |
| Show/Hide Sidebar (Cmd+S) with Arc's motion | FC §1.7 r35–36; IS §13, §20.12 | app-shell §3.3 | `OpenFeatures/BrowserWindowController.swift`, `OpenDesign/Motion.swift` | main (#122, #129) | e2e `window`: `motion_sidebar_toggle`, `motion_end_frame_curves`, `motion_show_panel_right_edge`, `motion_reduce_motion`; 2026-10-28 [re-check](sidebar-completion/recheck-122.md) | done | #122 set response 0.10 s / damping 0.95. Real installed sidebar/panel springs and their scheduled duration/settling estimate (0.139128 s) agree; the moving-frame pixel check passes. Arc's ≈ 0.29 s show delay is intentionally absent (app-shell Q11). |
| Hover-reveal card while hidden | IS §13, §20.2 | app-shell §3.3 | `OpenFeatures/BrowserWindowController.swift`, `OpenFeatures/SidebarRevealController.swift` | main | e2e `window` (`hide_reveal`, `fullscreen_hover_reveal`, `reveal_timing`, `card_edges_*`); card fixes in #90 | done (partial) | Zones and the 0.15 s dwell decoded (IS §13); exit delay is a guess. S2 (2026-10-26): slide in ≈ 0.14 s with a 3 pt overshoot, out ≈ 0.10 s; the card is translucent over the blurred page. Open's card is opaque (`docs/followups.md`). Change: app-shell §3.3, PR #104 follow-up. |
| Resize 164–500 pt; drag past the minimum hides while pressed; Cmd+S restores the pre-drag width; double-click on the edge resets to 228 | FC §1.7 r36; IS §13, §20.1 | app-shell §3.3 (D4) | `OpenDesign` `WindowMetrics`, `CompactToolbarMetrics` | main (#126, #129) | e2e `window` (`width_*`, floor 164 with the compact toolbar); e2e `sidebar-completion` E19; `features-render` GH1–GH5 (A1, #126); 2026-10-28 [re-check](sidebar-completion/recheck-122.md) | done (partial) | The 164 pt floor shipped with the compact toolbar (#126); #122's interim 218 pt floor is gone. Native held-drag limits, hidden release/restore, and double-click from 364 and 500 to 228 all pass. No value changed in merged #129. C10 is complete for the broad flow; refinement `drag-hide-threshold` remains open for the exact x82 trigger. |
| Hint toast on first hide ("You can use ⌘S…") | IS §13 | sidebar-completion §3.12 (A1) | `OpenFeatures/HintToastView.swift`, `OpenDesign/HintToastTokens.swift` | main (#126) | `features-render` HT1–HT3; e2e `sidebar-completion` E17; compare with A0440 worst 1 pt, ΔE00 1.17 (`docs/sidebar-completion/a1/hint-compare.md`) | done | Shows once, on the first hide by any path (toolbar button, Cmd+S, View menu, "More options", resize gesture); `open.sidebar.hideHintShown` records it. |
| URL pill: host, Copy button, Site Control button; click opens Cmd+L | FC §4.1 r2; IS §3 | app-shell §3.5 (Step C) | `OpenSidebar/ChromeViews.swift` | main | `sidebar-render check` (click reaches the delegate); Step C in #85 | done (partial) | Click now opens the real command bar (`performSidebar` `.openCommandBar`). The Site Control button still sends `showSiteControls`, which the App refuses (factory line 366). |
| Toolbar row: toggle, back, forward, reload; a split keeps only the toggle | IS §11; design.md §15 | design.md | `ChromeViews.swift` | main (#126) | `sidebar-render check`; CT1–CT3 (#126); compact compare with S2 06/0029 worst 1 pt, ΔE00 0.80 (`docs/sidebar-completion/a1/compact-toolbar-compare.md`) | done (partial) | Below 219 pt: Back, Forward, "More options" (28 × 28), smaller arrows as measured (A1, #126). The "More options" menu content is a guess until C11. |
| Bottom bar: Home (Library), Space switcher, plus menu | FC §1.1 r6, §1.8 r41; FA SP-1; IS §5 | design.md | `OpenSidebar/BottomBarView.swift` | main | `sidebar-render check` | done | Home opens the Library in the App (Step C, #85; factory `showLibrary`). |
| Tooltips: capsule, keycaps, placement | IS §5 | design.md §5.6 | `OpenSidebar/Tooltip.swift` | main | `sidebar-render check` (one schedule per hover) | done | 0.6 s delay is a guess. Tooltip fill for the default theme measured in #113. |
| Inactive-window glyph tones | design.md §5.3 | app-shell §3.1 | `OpenSidebar` | main | `sidebar-render` inactive comparison (design.md §8) | done | The inactive default-theme darkening is still open (`docs/followups.md`). |
| Row accessibility and keyboard navigation | — (Open requirement) | design.md §14 | `OpenSidebar` | main | `sidebar-render check` (AX dump, key events) | done | |
| Sidebar media controls (mini player stack above the bottom bar) | FA §8 (PP-6, PP-20) | media-pip (D-1, D-3; redesign in §13, #109) | `OpenSidebar/MediaControlsView.swift`, `MiniPlayerCardView.swift` (#92, #110); `OpenMedia` store (#63); App `App/Media/MediaCoordinator.swift` | main (Section 3 Steps 5–6) | e2e `media` (`media_card_on_leave`, `media_card_controls`, `media_card_scope`, `media_cards_max_three`, `media_idle_cpu`, `media_card_leaves_on_close`); `sidebar-render check` MC1–MC16 | done | The App sets `SidebarContext.media` and `displayedTabIDs`; a card appears when a playing tab leaves the screen and goes when it returns, closes or archives. Media state comes from the fork's media session (`CefMediaController`, Section 3 Step 7; the frame probe of Steps 5–6 is gone). Real-window compare: see `Packages/OpenKit/MediaRenders/step6-real-window/`; two-card stack vs S2 16/0001 in `section3-parity/` (≤ 1 pt, ΔE00 0.47). |
| Hide the sidebar with the gesture (`hideSidebarWithGesture`) | MH "Gestures"; SC §10; IS §20.1 | sidebar-completion §3.16; app-shell §3.3 | `OpenFeatures/BrowserWindowController.swift` | main (#126, #129) | `features-render` GH1–GH5; e2e `sidebar-completion` E19 (#126); `window.width_hide_while_pressed`, `width_hidden_commit`, `width_cmd_s_restores_start` ([re-check](sidebar-completion/recheck-122.md)) | done (partial) | The resize drag past 164 hides while pressed; release sends `.sidebarHiddenByGesture` once and keeps the pre-drag width for Cmd+S. The exact x82 hide trigger remains a guess within the captured x65–85 band; C10 refinement `drag-hide-threshold` remains open. Cancellation and gesture Undo stay in follow-ups. |



### 1.2 Spaces

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Space model: name, icon, theme, one profile; at least one Space; "Space N" fallback | FC §2.1 r1–3 | `docs/model.md` | `OpenModel/Containers.swift`; `BrowserModel.displayTitle(for:)` | main | `openkit commands-demo` (verify-all) | done | Typed icons and atomic commands in #68. |
| Switcher in the bottom bar (current in color, others gray 0.55) | FC §2.5 r14 | design.md §5.3 | `BottomBarView.swift` | main | `sidebar-render check` | done | |
| Switch by click: page slide, theme cross-fade, content swaps at once | FC §2.4 r12; IS §10, §20.12 | design.md §5.4 | `OpenSidebar/SpacePagerView.swift`, `OpenDesign/Motion.swift` | main (#122, #129) | `sidebar-render check` (pager and theme); e2e `window.motion_space_switch`, `sidebar.space_switch_wrapper`, `sidebar.space_switch_click_spring`; 2026-10-28 [re-check](sidebar-completion/recheck-122.md) | done | #122 set the measured critical response to 0.20 s. A native switcher click selects and shows the correct page and installs that spring with non-zero travel. Its computed remainder at 0.27 s is 0.448 pt, consistent with S2's visual settling; CA duration/settling estimate is 0.30 s. Response and settling time are different quantities. |
| Two-finger swipe between Spaces | MH "Gestures" | design.md §5.4 | `SpacePagerView.swift` | main | `sidebar-render check` (swipe; short swipe snaps back) | done | |
| Next/Previous Space (Cmd+Opt+→/←) | MH Spaces | app-shell §4.3 | — | main | none (code read: `App/MainMenu.swift` `next-space` case, #85) | done | |
| Go to Space 1–9 (Ctrl+1…9) | MH "Shortcuts that live in code" (keys are a guess) | app-shell §4.3 (Step C) | registry `go-to-space-1…9` | main | `commands-dump` | done | Step C dispatches `go-to-space-*` (`App/MainMenu.swift:82`, #85). Keys are still a guess. |
| Last active tab per Space | FC §2.4 r13 | — | model `selectedNodeBySpace` | main | e2e `window` (restores selections, #52 merged) | done | |
| New Space flow: name, icon, theme, profile | FC §2.2 r4 | space-theme-editor (#62) | model `createSpace` (#68: failable overload, no theme by default) | main (no flow) | `space-editor-render` creation gate (#82) | planned | Spot-check: the App still creates a Space titled "Space" with no flow (`App/WebContent/EngineWebContentHostFactory.swift:355`, `App/MainMenu.swift` `new-space`). The form is Steps 5–8 of the space plan. S2 (2026-10-26): a new Space starts with no theme unless a color is picked in the form (C10; space-theme-editor Q2). |
| Rename Space inline (header double-click, menu) | FC §2.2 r5 | design.md; space-theme-editor | `SpacePageView.swift` header `beginRename`; model `updateSpace` | main (#132) | `sidebar-completion` `I10_rename_*` | done | Items 9–10 (#132): Spaces ▸ Rename Space uses the same inline editor, revealing a hidden sidebar. Cancel and model Undo are covered by `I10_rename_*`. |
| Change Space icon (emoji and symbol picker) | FC §2.3 r9 | space-theme-editor (#62) | model `SpaceIcon`; typed icons (#68) | none | none | planned | Spot-check: library only. The App refuses `changeSpaceIcon` (factory line 366) and does not link `OpenSpaceEditor` (`project.yml`). |
| Theme rendering: gradient, grain, light/dark content | FC §2.3 r10; DT §6; RO §3.3 | design.md §3; space-theme-editor Step 2 | `OpenDesign/ThemeField.swift`, `Grain.swift`, `SpaceThemeStyle.swift`; theme engine and textures (#82) | main | `sidebar-render check`; design.md §8 per-state ΔE; `space-editor-render` (#82) | done | Rendering is in the App. Pad-law calibration is theme Step 9 (in flight; plan in #114). |
| Theme editor popover: color pad, presets, intensity, grain, text mode | IS §14 | space-theme-editor Steps 3–4 | `OpenSpaceEditor/ThemeEditorPanel.swift`, `ColorPadView.swift`, `PresetStripView.swift` (#86, #89) | none | `space-editor-render` checks and capture fits (#86, #89) | planned | Spot-check: library only. Steps 1–4 merged (#68, #82, #86, #89), but the App refuses `editSpaceTheme` (factory line 366). No panel opens in the App. Steps 5–8 stay deferred. |
| Delete Space: archive its tabs, Undo | FC §2.2 r6 | model.md | model `deleteSpace(archiveTabs:)` with undo | main | `openkit commands-demo` | done | |
| Delete Space confirmation alert | FC §2.2 r6 | sidebar-completion §3.3 (A1) | `OpenFeatures/SidebarConfirmations.swift` | main (#126) | `features-render` DA1–DA3; e2e `sidebar-completion` E7 and the Manager Delete | done (partial) | Sheet on the browser window (Library window from the Space Manager). AppKit gives the destructive button no Return key (Section 1 decision; C3 remains open to confirm Arc behavior). |
| Reorder Spaces; Space Manager (Manage Spaces…) | FC §2.2 r8 | sidebar-completion (S4) | `OpenSidebar/SpaceManagerView.swift` (#99); Library host (#87); model `moveSpace(id:to:)` | main (#124) | `sidebar-render` Space Manager checks (#99); e2e `sidebar-completion` (#124: real Library page, grabber drag, undo, relaunch, rebind; spec geometry 0 pt) | done (partial) | The App injects the real view through `makeSpaceManagerView()`. Spaces ▸ Manage Spaces…, the Space menu, and the command bar open Library ▸ Spaces. No Arc frame of the Manager exists: geometry is checked against plan §3.2 and the S4 R1 header (`docs/design.md` §20); capture C2 and calibration C remain open. SM6 structure/instruction gate merged in #125: 679,842,406 ≤ 745,172,115; quiet absolute latency remains separate. Delete in the Manager confirms through the A1 alert (see the Delete Space row). See §3, gap 7. |
| Turn Space into folder; Export Space into folder; Turn folder into Space | FC §2.2 r7; IS §15 | sidebar-completion (M1 Space export); space-theme-editor (folder → Space) | bulk and Space model commands (#75) | main (#128, #132) | `commands-demo`; `sidebar-completion` E10 and `I9_folder_*` | done | Browser Export and Manager Turn into Folder preserve ordered child IDs and undo once. Folder → Space keeps the Profile and title, moves its children to Today in order, removes the folder, and undoes/redoes once. Empty folders also work. Today placement follows the Section 1 implementation brief; the older theme plan uses Pinned. |


| Share Space | FC §2.2 r5 | — | menu item exists in `SidebarMenus.swift` | main (#132), disabled | `sidebar-completion` `I9_share_space_disabled` | out of scope | Account feature. The menu item is visible and disabled; menu automation refuses it. |
| Live Folders | FC §1.5 r27 | — | — | — | — | out of scope | FC marks it not required for v1. |

### 1.3 Tabs: pinned and Today lifecycle

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| New Today tab at the top, under New Tab | IS §6, §9.3 | — | model `newTab` (index 0) | main | `openkit commands-demo` | done | |
| New Tab opens the command bar, not a blank page | FC §3.5 r18 | app-shell §3.5, §4.2 (Step C) | `OpenCommandBar` | main | `commandbar-render check`; Step C e2e (#85) | done | Spot-check: `App/CommandBar/AppCommandBarDelegate.swift:34` builds a real `CommandBarController` per window. Merged in #85. |
| A new window opens with the command bar open | FC §3.5 r19; IS §17 | `docs/commandbar.md` §10 item 1; app-shell §3.5; Section 2 item 10 | `AppDelegate.makeUserWindow()` | main (#144) | e2e `commandbar` `new_window_opens_command_bar`; `lazy_commandbar` (launch makes no bar) | done | File ▸ New Window and Blank Window open the new window with the bar in New Tab mode. Evidence: Cmd+N F0098, F0157; the window-only window A0359; Little Arc ⌥⌘N S2 19/0029; `showCommandBarOnNewlyCreatedWindows` is one Bool in Arc's app state next to `isRestoringSession` and `initialSessionRestorationState` (strings). Windows restored at launch and windows made for a moved tab do not open it (guess: no launch capture; capture request). |
| Pin/unpin; the pinned URL is the URL at pin time | FC §3.2 r9 | model.md | model `pinTab`, `unpinTab` | main (Cmd+D) | e2e `sidebar` (engine pin flag, #52 merged) | done | |
| "/" mark when a pinned tab left its pinned URL | IS §3 | design.md §15 | `SidebarRows.swift` | main | `sidebar-render check` | done | |
| Reset tab to its pinned URL | FC §3.2 r3–4 | app-shell §4.1 | model `resetPinnedTab` | main (#95, #127) | `sidebar-render` pinned reset actions (#95) | done (partial) | Menu and favicon actions dispatch it (`App/MainMenu.swift` `reset-tab`). Capture C7 remains open for the reset plate, modifiers and tooltip. |
| Close and keep pinned (unload) | FC §3.2 r5 | app-shell §4.1 | — | main ("−" button) | e2e `sidebar` (pinned unload and wake) | done | |
| Replace pinned URL with current | FC §3.2 r6 | — | model `replacePinnedURL` | main | `openkit commands-demo` | done | In `AppCommand.implemented` (#85). |
| Edit pinned URL dialog | FC §3.2 r3 | app-shell §4.1 (command bar in edit mode); Section 2 item 11 | intent `editPinnedURL`; `BrowserModel.setPinnedURL`; `AppCommandBarSession` pinned edit | main (#144) | e2e `commandbar` `edit_pinned_url` | done | Edit Pinned Page ▸ Edit… opens the command bar in edit mode with the pinned URL selected; Return (a page or a search) stores the new pinned URL in one undo step, and a tab still on its old pinned page goes to the new one (guess). Arc's strings name a dialog ("Title of Edit Pinned URL dialog", "Pinned tab URL input placeholder", "Button that updates the pinned URL"); the command bar is Open's choice (app-shell §4.1). |
| Separate From Pinned Tab | FC §3.2 r7 | sidebar-completion (M1, S3) | model command (#75); favicon actions (#95) | main (#75, #95, #127) | `openkit commands-demo` B-checks (#75); `sidebar-render` (#95) | done (partial) | Merged #127 rekeys the live host into Today without losing page state (E14). The command runs through the sidebar model path in the App. Capture C7 remains open for the modifier/reset-plate appearance. |
| Reset all tabs in this Space | FC §3.2 r8 | sidebar-completion (M1); app-shell Step C | registry `reset-all-tabs-in-space`; App loop over tabs | main (#128) | `sidebar-completion` E9 | done | Real-App proof resets live pinned descendants in a folder and split. Favorites and another Space stay unchanged. Host/path differences control enablement. |
| Archive Tab (Cmd+W): Today archives; pinned and favorite unload | FC §1.2 r11, §3.3 r14 | — | model `closeTab`; `OpenStore/ProfileArchiveSink.swift` | main | e2e `shell`, e2e `sidebar` | done | |
| Restore Last Closed Tab (Cmd+Shift+T), same tab ID | MH File | — | `OpenStore/ArchiveStore.swift`; model `restoreArchivedTab` | main | e2e `shell` | done | |
| Today auto-archive after the threshold | FC §3.3 r10–13 | sidebar item 6 | `OpenFeatures/ExpirySweeper.swift`, `TodayAutoArchiveController.swift`; `App/AutoArchive/` | main (#130) | PR #130: AA1–AA12/AA-visible; `features-render` 317/317 ×3 after the AA2 fixture fix; final e2e `sidebar-completion` 121/121, `app-actions` 49/49, `sidebar` 21/21, `window` 76/76 | done | Launch/wake sweep and one next-expiry timer; real Profile SQLite writes. Shown tabs (all selected split panes, any window) are excluded from both sweep and deadline. The shared mutation commit path caches shown Tab references and starts inactivity when the final window stops showing them, including structural edits and undo/redo. No extra undo step or polling. |
| Thresholds Never/1h/6h/12h/24h/7d/30d; per profile; default 12 h; Little Open 6 h | FC §3.3 r11–12; IS §18 | settings §5.2; sidebar item 6 | model `AutoArchiveInterval`, `ProfileSettings`; archive-scope sheet in `OpenSettings` | main (#130) | `settings-preview check`; AA2/AA6; AA_APP threshold/Never/all-Profile checks | done (Today) | Real Settings writes and undo re-arm the Today timer. Never leaves no timer when no other candidates exist. Little Open uses the same timer (Section 9; e2e `littleopen` timer rows). |
| Auto-archive education banner | FC §3.3 r15 | sidebar-completion (S5), item 6 | `OpenSidebar/SidebarBannerView.swift`; `TodayAutoArchiveController`; App intents | main (#130) | AA8–AA10; E16 banner, Got it, relaunch dismissal, correct-Profile Settings link | done (partial) | Shown-Space trigger; all finite windows show their own threshold; app-wide persisted dismissal. Geometry remains a guess until capture C6 and calibration C. |
| Clear Today (divider "Clear", Cmd+Shift+K) with Undo | FC §1.8 r40; IS §6 | app-shell §4.3 (key) | model `clearToday` with undo; Clear control in `SidebarRows.swift` | main | `sidebar-render check` (clear and undo); e2e `sidebar` | done | Key dispatched in Step C (`clear-unpinned-tabs`, #85). |
| Clear unselected Today tabs | FC §1.8 r40 | sidebar-completion (M1, S2) | model Clear keeping selected descendants (#75); Option Clear (#91) | main (#75, #91, #128) | `openkit commands-demo`, `sidebar-render` (#75, #91) | done (partial) | Option changes only the Clear tooltip; the action keeps the selection. Merged A3 (#128) E15 proves the App path. Capture C8 remains open for tooltip/menu alternates. |
| Duplicate tab, folder, or split | FC §1.4 r18 | app-shell §4.3; sidebar-completion (M1) | model `duplicateNode(id:)` (`OpenModel/BrowserModel.swift:551`), `duplicateNodes` | main (#128) | `commands-demo`; `sidebar-completion` E3 | done | Menu-bar Duplicate and selection-menu Duplicate use the bulk command for nonempty selection, with one undo. Single-item fallback stays available with no selection. |
| Next/Previous Tab (Cmd+Opt+↓/↑) | MH Tabs | app-shell §4.3 | — | main | none (code read) | done | |
| Cycle Tab Forward/Backward (Cmd+Ctrl+→/←) | MH Tabs | app-shell §4.3 | registry | main | `commands-dump` | done (partial) | Step C maps both ids to the same sidebar cycle as Next/Previous Tab (`App/MainMenu.swift:123`, #85). |
| Tab Switcher (Ctrl+Tab), most-recent order | MH Tabs; sidebar-completion RE §13 TS-R3–R8 | Section 1 item 11 | `OpenFeatures/TabSwitcherController.swift`; App real key router and host snapshots | main (#134) | `features-render` 372/372 (TS1–TS14 and stored-favicon checks); e2e `sidebar-completion` 174/174 total (172 feature rows plus fingerprint/cleanup) | done (partial) | Lazy frozen five-item MRU, reverse, 100 ms overlay delay, release-all-initiating-modifiers commit, bare-key immediate switch, Esc cancel; modifier monitor and lifecycle observers exist only while active. Owned auxiliary releases work; app deactivation / owned key loss cancels. No tab loads for previews. Merged #134 keeps the shared preview-host handoff; E12 checks MRU release-to-commit reuse. Exact geometry/colors and Profile-wide candidate scope remain guesses; TS-C1 capture pending. |
| Go to tab 1–9 and last (Cmd+1…9); "Include Favorites" option | MH code-only table; FC §7.2; sidebar-completion RE §13 TS-R1–R2 | Section 1 item 11; commandbar-completion §4.4 (Step 7) | `OpenModel/GoToItemNumbering.swift` (`goToItemTargets`, the one numbering query for keys, the Tabs menu and the last item); registry and native Tabs menu; `App/MainMenu.swift`; existing Shortcuts settings | main (#134, #142) | e2e `sidebar-completion` 174/174 total (172 feature rows plus fingerprint/cleanup), including TS numbered-key rows and dynamic menu dispatch; `commands-dump` missing/extra/different 0/0/0 | done (partial) | Menus and keys share the Favorites preference. Cmd+9 defaults to last, including with fewer than nine tabs; the existing ninth-tab option selects item nine. Cmd+9 stays on the numbered-tab route and the dynamic last/ninth tab menu row; no separate Go to Last Tab menu item is added (the committed Arc Tabs reference has none). Arc defaults remain unknown; TS-C1 remains open for preference defaults and candidate scope. Step 7 (Section 2): the list is now the model query of commandbar-completion §4.4.1: collapsed folders and a collapsed pinned section give nothing, a peeked folder its one visible child, and a split counts once (it selects its focused pane); `commands-demo` N1–N7; `sidebar-render` checks that a Command press changes no sidebar pixel (no hints, D13); `show-shortcuts-overlay` is disabled with no handler. |
| Reveal Current Tab (Ctrl+Space) and Reveal Tab in Sidebar | MH View, Tabs | app-shell §4.3 (`reveal-current-tab`) | registry `reveal-current-tab` and `reveal-tab-in-sidebar` (`OpenCommands/CommandRegistry.swift:184`) | main | `commands-dump` | done | Closed in #85: both ids registered, `reveal-tab-in-sidebar` maps to `reveal-current-tab` (`App/MainMenu.swift:38`). See §2.3, §3 gap 41 (closed). |
| Lazy loading: only the selected tab loads at launch | `docs/architecture.md` tactics | app-shell §5 | `OpenFeatures/WebContentContainer.swift` | main | e2e `shell`, e2e `window` | done | |
| Placeholder for unloaded and sleeping tabs | `docs/memory-design.md` §2 | app-shell §3.4 | `OpenFeatures/PlaceholderContentView.swift` | main | `features-render check`; e2e `sidebar` | done | |
| Tab sleeping: freeze 30 s, discard by mode, never-sleep gates | FC §3.4 r16; memory-design §5 | app-shell Step G; memory-fork S1–S6 | `OpenSleep/SleepPolicy.swift`, `SleepController.swift`, `App/Sleep/AppSleepCoordinator.swift`, `App/WebContent/EngineSleepAdapter.swift` | main (#156, #158, #165) | `sleep-demo` 172/172; e2e `sleep` F0, F2, F4 restore/corrupt fallback, F5 discard/destroyed/unfreeze | done (capture fixture blocked) | G2 uses setPageFrozen, in-place discard and navigation-history capture/restore. Discard wake n=20 p95 25.0 ms; destroyed wake n=10 p95 92.7 ms (load 9.2/8.4/7.4, #165 receipt). `sleep_f3_capture` remains BLOCKED without a camera/mic grant. |
| Keep-alive sites never frozen or discarded (Gmail, Slack, Notion, Spotify, calendar, chat) | FC §3.4 r16 (`keepaliveAllowList`) | sleep.md; settings-library §2 | `OpenSleep/KeepAliveRules.swift`, `SleepPolicy.swift`, `SleepController.swift` | main (#156) | verify-all `sleep-demo`; e2e `sleep` `sleep_keep_alive` | done | Live in the App since Step G: a `mail.google.*/mail` page stays live for 48 simulated hours; the hidden-host cache keeps protected pages too. Notification permission protection passes `sleep_n5_notifications` (#156). Native delivery remains BLOCKED (U-N1, #160). See §3, gap 5. |
| Battery Saver uses the aggressive discard time | FC §3.4 r17 | memory-design §5; settings-library Tab Sleeping | `SleepController.lowPowerMode`, `App/Sleep/AppSleepCoordinator.swift` | main (#156, #153) | `sleep-demo` Battery Saver rows; e2e `sleep_battery_saver` | done | Low Power Mode makes Automatic act as Aggressive; "Battery Saver Mode Activated/Deactivated" toasts. ToastCenter supplies the Settings button, which opens Settings ▸ Advanced (#153); `features-render` R-T1–R-T7 covers the toast view. |

### 1.4 Favorites

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Favorites grid per profile, shared by that profile's Spaces | FC §2.1 r1; IS §4 | design.md | `FavoritesView.swift`; model `Profile.favorites` | main | `sidebar-render check` (add, remove, 32 seeded permutations) | done | Column rule for counts other than 6 is a guess (design.md §9). |
| Add, remove, reorder by drag; "Remove from Favorites" | FC §1.4 r20, §1.6 r30 | design.md §5.5 | model `addFavorite`, `removeFavorite` (favorites move, never copy) | main | `sidebar-render check` | done | Menu ids `add-to-favorites`, `remove-from-favorites` dispatch in Step C (#85). |
| Select a favorite; closing unloads it and keeps the tile | FC §1.2 r11 | app-shell §4.1 | — | main | e2e `sidebar` (#52 merged) | done | |
| Favorite tile hover state and context menu | IS §4, §15 (not captured) | design.md §5.6 (guess) | `FavoritesView.swift`, `SidebarMenus.swift` | main | `sidebar-render check` | done (partial) | Capture `favorites-hover` remains open (§5.2); preview/favicon work in #127/#131 does not prove this Arc state. |
| Links in a favorite open Peek | FA PK-2 | m4 §4 | `OpenFeatures/PeekPolicy.swift` | main | `features-render P1`; e2e `peek` 6/6 (#52 merged) | done | |

### 1.5 Folders

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Folders in Pinned or Today; nested; collapse state persists | FC §1.5 r21–23 | design.md | model `createFolder`, `setExpanded`; `SidebarRows.swift` | main | `sidebar-render check`; e2e `sidebar` (folder collapse) | done | |
| New Folder (menus; Cmd+Shift+N with the sidebar focused) and New Nested Folder | FC §1.5 r24; IS §15 | app-shell §4.3 (key) | intents `newFolder`, `newNestedFolder`; registry `new-folder` | main (#128) | `sidebar-render`; `sidebar-completion` E2 and text-editor flow | done | Menu and Cmd+Shift+N group the nonempty selection with one undo. Text fields retain Delete and do not group a stale selection. Empty selection keeps the existing empty-folder action. |
| Delete folder archives its tabs | FC §1.5 r25 | sidebar-completion (M2, A1, A3) | model `archiveNodes` (one folder record, #77); `SidebarConfirmations` (#126) | main (#128) proof | `commands-demo`; FA1–FA7; `features-render` DA4–DA5; e2e E8/E18 | done (partial) | The alert comes first ("Delete your <folder> folder?" / "Are you sure?"), then the "Folder deleted" toast with Undo; the current tab's neighbor is selected. Capture C3 remains open for alert design and Return behavior. |
| Expand and collapse animation | IS §7, §20.12 | sidebar-completion §3.17 (S6) | `OpenDesign/Motion.swift`; `SpacePageView.swift` | main (#135) | FP7; E20 installed native curves and presentation frames | done | Merged S6: FP10 paired gate 3/3 PASS. Expand 0.20 s easeOut; collapse 0.25 s CA default; unrelated row edits retain 0.22 s. [Receipt](plans/sidebar-s6-receipt.md). |
| Collapsed folder keeps its last active child visible ("peek"; three-dot folder glyph; Arc `expandedItems` `peeked`) | IS §20.4 | sidebar-completion §3.17 (Step S6) | `OpenModel`, `OpenStore`, `OpenImport`, `OpenSidebar` | main ([#135](https://github.com/SergeSerb2/open/pull/135)) | FP1–FP9, FP11; FP6 capture; E20 native save/relaunch | done (partial) | One retained real child; same-step undo/persistence and one fitted dot color. Targeted reconciliation keeps all frozen PNGs byte-identical. Peek drop indices and both unload-to-split paths are fixed. Child caches initialize before first folder observation, covering collapsed reloads and nested rows exposed later. Full gate 22/22 PASS (sidebar 608/608, features 380/380); native completion 193/193 and sidebar 19/19 PASS. FP10 paired 3/3 PASS under the unchanged matched-plain rule, layouts/frame 18/18. Capture C11 remains open for Q17/Q18 and the listed folder choices. The <1 ms median goal remains open; final-main soak is pending lead. [Receipt](plans/sidebar-s6-receipt.md). |
| Expand All Folders / Collapse All Folders | FC §1.5 r23 | sidebar-completion (M1); app-shell Step C | model expand/collapse (#75, #95); registry | main (#128) | `sidebar-render`; `sidebar-completion` E9 | done | Real-App recursive Pinned/Today folder state and disabled-after-action enablement pass. |
| Copy All Links (plain, Markdown) | IS §15 | app-shell §4.1 | intent `copyAllLinks` | main (#128, #132) | `sidebar-completion` A3 copy flows | done | Selection Copy Links/Markdown and folder Copy All Links share a depth-first formatter. Selected containers cover selected descendants once, in order. Clipboard content is verified through the real menu; `I9_copy_folder_plain/markdown` also covers nested folders and split panes. The captured Space menu emits no Copy All Links intent. |
| Archive a whole folder; restore it as a folder | FC §1.5 r26 | sidebar-completion (M2, A3) | `ArchiveStore` folder records; Library restore (#77) | main (#128) proof | `commands-demo`; FA1–FA7; real-App E18 Delete → Library restore → relaunch | done | Spot-check: the App Library presenter passes real archive stores (`App/Settings/AppSettingsActions.swift:34`). Restore keeps nested folders, splits, and IDs. See §3, gap 34 (closed). |
| Change Icon… for folders and pinned tabs | IS §15; FC §1.5 r21 | space-theme-editor (shared picker, Steps 5–8) | typed `iconOverride` (#68); intent only in the App | none | none | planned | The App refuses `changeIcon` (factory line 367). Rows draw a stored override, but no picker opens. |


### 1.6 Archive

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Archive store per profile (SQLite); reasons closed, auto, cleared, folder deleted | FC §3.6; DM "Archive and session files" | model.md | `OpenStore/ArchiveStore.swift`, `ProfileArchiveSink.swift` | main | verify-all `roundtrip`, `commands-demo` | done | Folder records added in #77. |
| Library ▸ Archive: search, Space filter, restore with toast and View, delete, Clear Archive with confirmation | FC §3.6 r20–23 | settings §6.2 (App step = app-shell) | `OpenSettings/ArchiveSection.swift`, `LibraryViewModel.swift` | main | `settings-preview check`; Step C presenters (#85) | done | Spot-check: `App/Settings/AppSettingsActions.swift:32` `showLibrary` builds the Library with real per-profile archive stores. Rows show reason and "Little Open"; a filter by close type or Little Open is not confirmed. |
| View Archive menu command | MH Archive | settings adapter table (`docs/settings.md`) | registry `view-archive` | main | — | done | Dispatched in Step C (`App/AppDelegate.swift` `view-archive`, #85). |
| Clear Archive menu command | MH Archive | none (the `OpenSettings` Library has the button, not the command) | registry `clear-archive`; shared Library confirmation | main (#132) | `sidebar-completion` `I10_clear_archive_*` | done | Opens Library ▸ Archive and requests the button’s same confirmation. Cancel changes no store; confirm clears all registered Profile archives. Disabled without a browser window. No default shortcut (MH Archive). |
| Archive empty state | FC §3.6 r23 | settings | `OpenSettings` | main | `settings-preview` (empty-state renders) | done | Shown by the App Library (Step C). |

### 1.7 Command bar

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Panel UI: centered overlay, 50 pt rows, theme selection color, no open or close animation | IS §9.1–9.2, §20.12 | `docs/commandbar.md` | `OpenCommandBar/*`, `OpenDesign/CommandBarTokens.swift` | main | `commandbar-render check` 91/91 (flow 87); e2e `commandbar` `commandbar_no_open_animation` / `_no_close_animation`; commandbar.md §8 comparisons | done (partial) | Section 2 Step 0: the bar shows and goes in one frame (CC-44), as in Arc. Light appearance and the S2 edge-style conflict stay open (`docs/followups.md`). |
| Cmd+T new-tab mode; Cmd+L edit-current-URL mode (URL selected) | FC §4.1 r1; IS §9.3 | app-shell §3.5, §4.2 | `CommandBarController.swift` | main | `commandbar-render check` (Cmd+T and Cmd+L flows) | done | |
| Esc closes; click outside dismisses; focus returns to the page | FC §4.1 r3 | app-shell §3.5 | `CommandBarController.swift` | main | `commandbar-render check` | done | |
| Sources: what you typed, open tabs of the profile, pinned and favorites, history, remote suggestions, calculator, actions, Site Search | FC §4.2 r4 | `docs/suggest.md` | `OpenSuggest/Providers.swift` and siblings | main | verify-all `suggest-check` (31/31) | done | Spot-check: `AppStores.suggest(for:)` builds a per-profile `SuggestEngine` with real history stores. Step H records committed link and typed visits per Profile (§1.17); the empty Cmd+T rule is unchanged. |
| Results stay inside the current profile | FC §4.2 r5 | suggest.md "Modes" | `OpenSuggest` | main | `suggest-check` | done | |
| Ranking and dedupe hosts | FC §4.3 r6–7 | suggest.md "Ranking" | `OpenSuggest/Ranking.swift` | main | `suggest-check` | done | Empty Cmd+T matches Arc since Section 2 item 9 (#145): up to four open tabs, then "Contact the Team", no history (S2 18/0008, 18/0044 AX). |
| Inline autocomplete in the field | IS §9.3, §20.9 | commandbar-completion §4.1 (#70), Steps 1–2 | `OpenSuggest/InlineCompletion.swift` (rule T3a, history carry-over, current tab in Cmd+T); `OpenCommandBar/CompletionSession.swift`, `CommandBarController` keys | main (#138) | `suggest-check` 32–40, 44; `commandbar-render` flows 69–80, 86 and the completion budget (p95 +0.08–0.10 ms ≤ +0.3, no extra layout pass); compares F0043, F0062, F0061 ≤ 1 pt, ΔE00 ≤ 1.93; S2 18/0009 completion elements ≤ 1 pt, ≤ 1.37; e2e `commandbar` 55/55 | done | Built in Section 2 Steps 1–2. The completed part is selected; Backspace removes only it (CC-40). Remaining S2 18/0009 misses are the edge style and the selected subtitle (ΔE00 2.67; `docs/commandbar.md` §8.3). See §3, gap 22. |
| One row per Split View ("Switch to Split View") | FC §4.2 r4; suggest.md Q1 | commandbar-completion §4.2 (#70), Steps 3–4 | `OpenSuggest` `TabIndex.splits`, `TabsProvider` split rows, `Suggestion.split`; `OpenCommandBar` split plate sublayers and titled rule | main (#139) | `suggest-check` 41; `commandbar-render` flow 81; A0120 compare (split elements ≤ 1 pt, ΔE00 ≤ 1.05); e2e `commandbar_split_one_row` | done | Built in Section 2 Steps 3–4. See §3, gap 23 (closed). |
| Browser actions by name (90 actions; 80 Arc seed ids; Section 2 item 9 added Contact the Team) | FC §4.4 r9 | `docs/commands.md` | `OpenCommands/SuggestAdapter.swift`, `OpenSuggest/ActionRegistry.swift` | main | `commands-dump` (actions 89, seed coverage 79/79) | done | Actions run through Step C dispatch. An action can still be a stub (for example Boosts). |
| Search engines: Google default, built-in list, custom engines per profile | FC §4.5 r11–12 | settings §5.2 | `OpenModel/SearchEngine.swift` (moved by #51), `OpenSuggest/SearchEngine.swift`; custom-engine sheet in `OpenSettings` | main | `settings-preview` `profile-search` | done | Step C resolves custom engines through `SearchEngines.resolve` (#85) and shows the Settings sheet in the App. |
| Search-suggestion privacy notice | FC §4.5 r13; CC-42 | settings (review "Code 4"); commandbar-completion §4.8 | `OpenSettings` `prepareForRemoteSuggestions`; `OpenCommandBar/PrivacyFooterView.swift` | main | `settings-preview` `suggestion-notice`; `commandbar-render` flows 88–90; S2 18/0044 compare (footer elements ≤ 1 pt, ΔE00 ≤ 0.62); e2e `commandbar` footer rows | done | Section 2 Step 0: (i) and Cmd+I show Arc's inline footer; "Dismiss" writes the Settings key and turns remote suggestions on for the open bar; "Search Settings…" opens Settings ▸ Profiles for the bar's Profile. Line 2's link hides until Open has a privacy page (`docs/followups.md`). |
| Site Search: Tab or Space trigger, pill, Backspace exits | FC §4.6 r15–16 | suggest.md §7; commandbar-completion §4.3.6 | `OpenSuggest/SiteSearch.swift`; scope chip in `OpenCommandBar` | main (#140) | `suggest-check`; flows 84, 91; S2 18/0016 and 0018 compares (chip and text 0 pt) | done | Decided by evidence: Site Search runs in the App (#85). Step 5 draws the captured chip (CC-41): orange P3 capsule with a glow, "Search…", orange scoped selection, no (i); Backspace on empty restores the text from before the scope. |
| Search-tabs scope | FC §4.6 r14 | suggest.md "Modes" (`searchTabs`) | `OpenSuggest` | main | `suggest-check` | done | `search-tabs` opens the bar in that mode (`App/MainMenu.swift` `search-tabs` case). Entry gesture is a guess. |
| Browser-actions-only scope | FC §4.6 r14 | commandbar-completion §4.3 (#70), Step 5 | `OpenSuggest` `searchActions`, scope keywords; `OpenCommandBar` `CommandBarScope`; `search-actions` command | main (#140) | `suggest-check` 42–43; flows 82–85; e2e `commandbar_actions_scope` | done | Built in Section 2 Step 5. "actions" + Tab, or the `search-actions` command (no default keys). See §3, gap 24 (closed). |
| Toast after Copy URL ("Copied Current URL" with Share) | FC §4.7 r18; IS §16; PG-1.10, PG-1.11 | page-platform Step 3 (Section 8) | `App/Page/PageCommands.swift` (`copyURL`, `copyURLMarkdown`, `copyURLQuote`, `shareFromToast`) | main (#163) | e2e `page` T-E1, T-E2, Q1–Q5, EP3; `commandbar` `copy_url_without_trackers` | done | Copy URL and Copy URL as Markdown show "Copied a clean link without trackers" / "Copied Current URL" with Share (the system picker anchored to the button; the toast stays while it is open). With Shared Quotes on and text selected, the same toast offers "Share a link directly to this text instead?" (decided at once from the engine's selection state, EP-3). Copy URL as Quote uses the engine's selection and Chromium's text-fragment generator (EP-2, prefix/suffix context where needed); the Share Quote status button under the URL field shows while text is selected (Step 15). The pane-bar Copy button still shows the toast without Share. |
| Hold-Cmd shortcut hints | MH "Command Bar"; CC-39 | commandbar-completion §4.4 (no hints) | registry `show-shortcuts-overlay` (no key, stays disabled) | none | none | out of scope | S2 (2026-10-26): Arc shows no hints after 2–4 s (CC-39); lead decision: Open builds none. Keycaps on action rows are part of `OpenCommandBar` (commandbar.md §3.3) and show in the App. See §3, gap 25. |



### 1.8 Menus and hotkeys (summary; numbers in §2)

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| One command registry for menus, keys, and the command bar | MH | `docs/commands.md` | `OpenCommands/CommandRegistry.swift` | main | `commands-dump` OK; Step C (#85) | done | `App/MainMenu.swift` now builds the menu from the registry and dispatches 76 App ids plus system and split ids (§2). |
| Arc-order menu bar built from the registry | MH "Full menu tree" | app-shell §4.3 | `OpenCommands/MenuBuilder.swift` | main | `commands-dump` (missing 0, extra 0, different 0) | done | Spot-check: system items keep their AppKit selector with target `nil` (`OpenCommands/MenuBuilder.swift:125`). See §3, gap 3 (closed in #85). |
| Keyboard routing: browser key vs page key; site-then-browser double press | MH "Custom shortcuts" | app-shell §4.3 | `OpenCommands/KeyboardRouter.swift` | main | `commands-dump` (router priority); Step C e2e (#85) | done | One router per window, plus an App fallback (`App/AppDelegate.swift` `fallbackKeyboard`). Native page and text editing wins over model undo (#85). |
| Custom shortcuts: record, conflicts, reset, priority | MH "Custom shortcuts"; FC §7.2 Shortcuts | settings §5.4 | `OpenCommands/KeyBindings.swift`; `OpenSettings/ShortcutsPane.swift` | main | `commands-dump` (overrides); `settings-preview` `shortcuts-save` | done | The App reloads bindings on change (`App/Settings/AppSettingsActions.swift:110` `keyBindingsDidChange`). |
| Global Little Open hotkey (Cmd+Opt+N) | MH "Global hotkey and Little Arc" | app-shell §4.3 | `OpenCommands/GlobalHotkey.swift`, `AppLittleOpen` | `s9/little-open-app` | e2e `littleopen` B4, same-press guard | done | Registers on fresh empty launches and opens a focused blank window. Actual global input from another app remains a hand check. |
| Dynamic Spaces and Tabs menu sections | MH "Menu bar at a glance" | commands.md | `MenuBuilder.swift` | main | `commands-dump` | done | `App/MainMenu.swift:13` passes live Spaces and ordered tabs. |
| Essential Keyboard Shortcuts window | MH Help | commandbar-completion §4.5 (Step 6, #70) | `OpenSettings/EssentialShortcutsWindow.swift`; App `keyboard-shortcuts-edu`, Settings callout | main (#141) | `settings-preview` `essential-shortcuts`, `shortcuts-callout` and scenes; e2e `essential_shortcuts_window` | done | One shared floating window (CC-27), Arc's five rows (CC-28) with live keycaps; Esc and Cmd+W close it and never a tab. Reached from Help, the command bar action, and Settings ▸ Shortcuts; first run's "Learn Essential Shortcuts" belongs to `first-run.md`. Content is Open's design until a capture exists (plan §9 item 4). See §3, gap 25. |
| Reference table complete | MH | — | `OpenCommands/Resources/expected-menu.json` | — | code read (§2.3) | done | Tabs ▸ "Reveal Tab in Sidebar" is now in the table (line 652) and in the registry (#85). |


### 1.9 Split View, Peek, Little Open

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Split View as one sidebar item: up to 4 panes, horizontal or vertical | FA SV-1, SV-3, SV-4 | m4 | model `makeSplit`, `addPane`; `OpenFeatures/SplitViewController.swift` | main; real-App proof on `s9/split-app` | `features-render S1/S2/S6`; e2e `split` `E1_two_live_pages`, `E1_four_live_pages`, `four_horizontal_frames`, `four_vertical_frames`, `add_up_to_four` | done | Real App hosts two and four live pages; fifth pane is refused. `split` 40/40 ×3 consecutive Chrome Release runs. Sidebar speed: machine noise, not a branch regression (lead ruling; both identical-main controls retained). Exact-base audit, timing target/gate and limits: `docs/split-app.md`. |
| Create a split: shortcut, drag a row onto the page, context menu, plus menu | FA SV-5 | m4 §3 | `OpenFeatures/SplitDropOverlayView.swift`; sidebar intents | main; real-App proof on `s9/split-app` | e2e `split` `C1_shortcut`, `C2_edge_drop/center_select/cancel`, `C3_combine/own_pane_refused`, `C4_context_menu/context_add`, `C5_commandbar_plus`; empty/Favorite/cap enablement rows | done | Keys use `route=app`. Drops use actual destination callbacks with NSDraggingInfo and the real sidebar pasteboard type; no WindowServer drag-session claim. |
| Divider resize; 200 pt minimum; fractions persist | FA SV-7 | m4 (lead Q2) | `OpenFeatures/SplitDividerView.swift` | main; real-App proof on `s9/split-app` | e2e `split` `divider_horizontal_double_click`, `divider_drag_commit`, `narrow_equal_scaling`, `relaunch_orientation_fractions_focus` | done | Real in-App mouse events; exact live movement, one release commit and persisted nonuniform fractions. Narrow content below 800 pt scales four panes equally below 200 pt. |
| Pane focus ring; Ctrl+Shift+1…4, next/previous pane | FA SV-8 | m4; app-shell §4.3 | OpenFeatures `handles(_:)` key path | main; real-App proof on `s9/split-app` | e2e `split` `focus_keys_ring_sidebar`, `focus_page_click`, `snapshot_two_panes`, `pane_motion_no_extra_ring_animation` | done | Split IDs stay on OpenFeatures. App-route keys and page click update exactly one ring, sidebar host and window title. PNG ring ΔE00≤2; sidebar cells keep the measured equal fills. |
| Maximize a pane (Expand Current Split) | FA SV-11 | m4 | `SplitViewController.swift` | main; real-App proof on `s9/split-app` | e2e `split` `expand_escape_focus_restore`, `relaunch_orientation_fractions_focus` | done | Expand preserves all live hosts. Esc and pane-focus keys restore frames/fractions; transient maximize is not persisted. |
| Close pane, separate pane, Separate All, flip orientation | FA SV-10, SV-4 | m4 | model `removePane`, `unsplit`, `setSplitOrientation` | main; real-App proof on `s9/split-app` | e2e `split` `close_focused_pane`, `separate_focused_pane`, `separate_all`, `collapse_two_to_one_selection`, `separate_two_to_one_selection`, `option_close_unsplits`, `four_vertical_frames` | done | Real menus, app-route close key and Option-click; surviving selection and archive/retained tabs are checked. |
| Pane top bar in the page's color | IS §11 | m4 visual finish; engine-api "Page background color" | `OpenFeatures/PaneChromeView.swift` | main (renderer color query after load) | `features-render RR3`; "M4 page color" check (#52) | done | |
| Sidebar split row (one cell per pane) and split row menu | IS §7; MH "Split row menu" | design.md §15 | `SidebarRows.swift`, `SidebarMenus.swift` | main; real-App proof on `s9/split-app` | `sidebar-render check`; e2e `split` `focus_keys_ring_sidebar`, `C4_context_menu/context_add`, `add_up_to_four`, `separate_all` | done | Measured equal cell fills remain unchanged; one selected split row follows pane focus through its URL/title. |
| Share Split View | FA SV-13 | — | — | — | — | out of scope | Account link. |
| Peek for cross-site links in pinned tabs and favorites (eTLD+1) | FA PK-2 | m4 (lead Q1) | `PeekPolicy.swift`, `PeekController.swift` | `s9/peek-app`: OpenEngine wrapper navigation delegate | e2e `peek_policy_pinned_cross_site`, `peek_policy_favorite`, `peek_policy_same_site` | done | Real DevTools user-gesture link clicks; same-site subdomains navigate in place. [Receipt](plans/s9-peek-receipt.md). |
| Shift-click opens Peek in any tab | FA PK-3 | m4 | `PeekController.swift` | `s9/peek-app`: wrapper `NEW_WINDOW` policy and lazy window path | e2e `peek_policy_shift_today`, `peek_shift_fresh_window`; Cmd-click remains a new tab | done | No Chromium fork change. |
| Peek overlay: geometry, dim, three buttons | FA PK-1; IS §12 | m4 | `OpenFeatures/PeekOverlayView.swift` | main; native shown-state corrected in `s9/peek-app` | `features-render P2`; real-App `peek_overlay_geometry_dim_buttons`; F0090 compare worst 1 pt, ΔE00 1.86 | done | Measured visuals unchanged. Open always dims (m4.md "Limits"). |
| Expand Peek into a tab (same live page) | FA PK-6 | m4 (lead Q5) | `PeekController.swift` | `s9/peek-app` | e2e `expand_rebinds_host`, `peek_expand_page_state` in Alloy and Chrome | done | Alloy keeps engine ID and JS state. Chrome uses the allowed history/scroll/form restore fallback (one reload; JS heap is not kept). |
| Dismiss Peek with "Peek closed" undo toast; nested peeks (depth cap 5) | FA PK-7, PK-8 | m4 | `PeekController.swift` | `s9/peek-app`: View ▸ Exit / App Esc and wrapper navigation policy | e2e `peek_closed_toast_undo`, `peek_closed_undo_while_hovered`, `peek_click_outside_undo`, `peek_nesting_cap` | done | Native nested link clicks push to 5; the next click navigates in place; Esc pops once. |
| Peek badge on the source row; Peek follows its source tab | IS §12 | design.md §15 | `OpenSidebar`, `OpenFeatures` | main; audited in `s9/peek-app` | e2e `peek_badge_sidebar_state`, `peek_source_selection_hides`, `peek_follows_source_split` | done | Reads actual sidebar state; hiding preserves the badge; source split changes the row owner. |
| Peek Split button | IS §12; m4 lead Q4 | m4 | `PeekController.swift` | main; Chrome history fallback in `s9/peek-app` | e2e `peek_split_beside_source`, `peek_split_favorite_refused`, `peek_visibility_split` | done | Adds the promoted page beside its source; Favorites refuse without creating a tab. |
| Peek sleep visibility, including source underneath | sleep.md; m4 §7 | app-shell §4.7 | `AppVisibilityProvider`, `PeekController.refresh` | `s9/peek-app`, existing shared sleep feed | e2e `peek_visibility_ticker`, `peek_nested_visibility`, source-hide/dismiss/expand/split visibility rows | done | 31 s controller clock + ticker; source freeze gate visible; engine refuses Peek freeze. Removing the Peek feed makes the gate FAIL. |
| Peek Email (Cmd+Shift+E) | FA PK-4 | S11 lead decision (2026-11-05) | `App/PageChrome/PeekEmailCommand.swift` | main (#178) | e2e `context-menus` `cm_peek_email*` | done | Profile Favorites first, then focused Space’s pinned tabs and the Profile’s other Spaces in sidebar order. Exact known-webmail hosts only; iCloud requires `/mail`. Today-only and unrelated Profiles do not enable it. Uses section 9’s public Peek entry; no live mail lookup. From an empty Space, selects the saved tab through the split-aware command path so a pinned split pane keeps its Peek visible. |
| Peek settings switches | FA PK-5; IS §18 Links | settings §5.3 | `OpenSettings/LinksPane.swift` | main; real effects audited in `s9/peek-app` | e2e `peek_setting_off_otherSites`, `peek_setting_off_shiftClick` | done | Switches independently gate their triggers; persistent preference values restore in finally. |
| Little Open window: a 490×329 command-bar first frame at the screen's top-right, 1185×832 after load, Arc's title bar, one page, no sidebar | FA LA-1; IS §20.10 | routing §9.3, Steps 6–7; m4 §6 | `OpenFeatures/LittleOpen*.swift`, `App/LittleOpen` | `s9/little-open-app` | e2e `littleopen` B4/B9/B10; [App receipt](little-open/verification.md) | done | Real standalone Chrome tabs in one hidden Browser per window, created after the first window transaction commits. The bar has no engine Browser/page. Native field focus, title bar and page snapshot remain; no sidebar tab. The three pre-creation race rows and timing method are in [the deferred Browser report](little-open/deferred-browser.md). Functional acceptance is 39/39 ×3 after main `e83dc38f`; the earlier immediate-submit page-load result remains recorded. Fresh 20-pair typed (400 ms wait), external-link, and immediate-submit receipts are in the report’s Realistic timing section; the lead decides timing acceptance (PR #185 stays draft). |
| Entry: links from other apps | FA LA-2 | routing §8, Step 6; app-shell Step E | `OpenRouting`; `App/ExternalLink`; `AppLittleOpen` | Steps 5–6 | e2e `routing`; `littleopen` B4/B6 | done | LaunchServices reaches real Little Open windows. Same URL resurfaces its session. Cold delivery preserves saved windows; a windowless snapshot leaves only Little Open. Real Mail click remains a hand check. |
| Entry: global hotkey Cmd+Opt+N | FA LA-3 | app-shell §4.3, §4.4 | `GlobalHotkey.swift`, `AppLittleOpen` | `s9/little-open-app` | e2e `littleopen` B4 and `same_press_guard` | done | Registered Carbon hotkey and menu share key-down timestamps. One press creates one window. A real press from another app remains a hand check. |
| Entry: Opt+Cmd-click a link | FA LA-4 | routing §9.5; app-shell §4.4 | OpenEngine `shouldNavigate` with modifiers; factory policy | `s9/little-open-app`, merged `s9/peek-app` hook | e2e `littleopen` `option_command_click`, `option_command_toggle_off` | done | Toggle defaults on. The source Profile owns the standalone page. Toggle off navigates in place. |
| Entry: File ▸ New Little Open Window; AppleScript app-level `tab` | FA LA-5 | app-shell §4.3, §4.10 | `AppLittleOpen`; scripting hook | main (#183 menu; #174 scripting) | e2e `littleopen` B4/B6; `applescript` app-level make returns 1011 | done (menu); scripting 1011 | File opens a focused blank Little Open window. AppleScript app-level creation returns 1011 until Section 9’s coordinator returns a script-addressable tab; standalone pages are not model tabs and `ScriptHost.makeLittleTab` remains nil. |
| Move to a Space (Cmd+O "Open Little Open or Peek in…") | FA LA-6; IS §20.10 | m4; routing §9.3–§9.5 | `OpenFeatures`, `AppLittleOpen` | `s9/peek-app`, `s9/little-open-app` | e2e `peek` Cmd+O rows; `littleopen` B5 | done | Selected Today top, creates or focuses a main window, closes Little Open without archiving. Bar state does nothing. Native Space picker is supported. |
| One profile per Little Open window; switch with confirmation | FA LA-7 | routing §9.2 | `LittleOpenSession`, `AppLittleOpen` | `s9/little-open-app` | e2e `littleopen` `profile_confirm_cancel` | done | Exact NSAlert copy, Cancel, Switch Profile and suppression preference. Confirm destroys and rebuilds the host in the new Profile. |
| Auto-archive stale Little Open windows (6 h) | FA LA-8 | routing §9.6 | App `ExpirySweeper`; coordinator deadline/sweep | `s9/little-open-app` | e2e `littleopen` B7, `sweeper_*` | done | One timer shared with Today; Never creates no timer. Real SQLite keeps `littleOpen:` locations. Restore goes to focused Today. |
| First-run intro (NUX) | FA LA-9 | routing §9.3 | `LittleOpenWindowController` | `s9/little-open-app` | e2e `littleopen` `NUX_once` | done | First page shows the intro. Dismissal persists across sessions. |
| Show/Close all Little Open windows (Dock menu) | FA LA-5 | routing §9 | `AppLittleOpen`, runtime Window/Dock menus | `s9/little-open-app` | e2e `littleopen` menu, show and close rows; `commands-dump` | done | Window menu lists sessions. Show resurfaces all; Close All writes no archive. New registry ids use the existing code-only category. |
| Downloads tray in Little Open | FA LA-10 | deferred by routing §0.2 (button shown disabled) | none | none | none | unplanned (deferred) | |

### 1.10 Profiles

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Create, rename, delete with guards; default profile cannot be deleted | FC §5.1 r1–3 | profiles §2 (D-P1) | `OpenModel/BrowserModel.swift` (`createProfile`, `deleteBlockReason`), `ProfilesSettingsModel.swift` | main (pane) | verify-all `profiles` | done (partial) | The Profiles pane shows in the App (Step C). Data delete refuses while the profile's engine context is alive (`App/Settings/AppSettingsActions.swift:93`); full engine unload waits (`docs/followups.md`). |
| Profiles settings pane: list, search, auto-archive, downloads, clear data | IS §18 Profiles | settings §5.2 | `OpenSettings/ProfilesPane.swift` | main | `settings-preview check`; Step C (#85) | done (partial) | Step H clears History for Last hour, Last 24 hours, Last 7 days and All time in the selected Profile. Cookies + cache still require All time together; Downloads clearing remains unwired. Unsupported combinations fail before mutation (`AppSettingsActions.clearBrowsingData`). |
| Engine context per profile: separate cookies, cache, extensions | FC §5.2 r4–6 | profiles §6; #88 supersedes engine-patches lead decision 4 | App profile → `OEBrowserContext` | main | e2e `features` "Profiles"; e2e `--only profiles` (#88) | done | Merged in #88: Chromium data under `<root>/Engine/<dir>`; a second profile's cookie survives a relaunch. A launch that cannot migrate keeps the old layout and retries. |
| Assign a Space to a profile ("Set Profile"); hosts are torn down on change | FC §2.6, §5.4 | profiles D-P2; app-shell §4.8 | model `moveSpace(id:toProfile:)` | main (explicit teardown) | e2e `sidebar` (Space/profile selection) | done | |
| Confirmation before moving a Space to another profile ("don't show again") | FC §5.4 r9 | profiles §7.3 | data only | none | none | planned | |
| Profile indicator in the Space header and Little Open | FC §5.3 r7 | profiles §7 (data; designer visuals) | none | none | none | planned | |
| Missing-profile fallback to Default | FC §5.3 r8 | profiles | model `repairMissingProfileReferences` | none (only `openkit` calls it) | verify-all `profiles` | planned | Still no App caller found in this refresh. Library only. |
| New Profile (File menu; Set Profile ▸ New Profile…) | FC §5.1 r2 | settings (create sheet) | `OpenSettings` sheet | main (sheet); sidebar intent refused | none | planned (partial) | The create sheet shows in App Settings. The sidebar `newProfile` intent still returns `false` (factory line 366), and File ▸ New Profile has no dispatch. |
| Incognito windows: ephemeral context, distinct look, no history | FC §3.1 r2, §8.1 r3 | app-shell §4.8 (Q8); profiles D-P8 | engine off-the-record context of Default | none | none | planned | Note: engine incognito is an off-the-record profile of Default, not of the Space's profile (`docs/followups.md`, #88 review). The incognito sidebar look is not specified. |
| Download location per profile | FC §5.2 r4 | S11 Downloads design; app-shell §4.9 | `App/PageChrome/DownloadsCenter.swift`, `DownloadDestinationChoice.swift`; `OpenSettings` setting | main (#181) | e2e `downloads` 34/34; full verify + quiet timing rerun (see `docs/downloads.md`) | done | Profile folders, unique names, fallback event and queued save sheets are implemented. Real-App save acceptance/cancellation, Library cancellation of a pending sheet, and second-Profile isolation pass; receipts are in `docs/downloads.md`. |

### 1.11 Air Traffic Control (link routing)

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Rule model and evaluator: first match wins; host and URL matches; source app; destinations Space, most recent Space, Little Open | FC §6.1; FA LA-12, LA-13 | routing Phase A + Phase B Step 5 | `OpenRouting/RuleEvaluator.swift`, `RoutingTypes.swift`; `AppLinkExecutor` | Step 5 | verify-all `route` (A1–A17); e2e `routing` | done (partial) | App evaluates fresh snapshots per URL with managed AppKit window order. Little Open reaches the real coordinator (Steps 6–7). |
| Links pane: rules editor and Test | FC §6.3 | settings §5.3 | `OpenSettings/LinksPane.swift`; `OpenRouting/LinksSettingsModel.swift` | main + Step 5 intake | `settings-preview` (rules, order, invalid drafts; agrees with `openkit route`); e2e `routing` | done | Saved rules now drive external-link intake. |
| External link intake with a cold-launch queue | FC §6.2 r5; FA LA-13 | routing §8; app-shell Step E | `App/ExternalLink/ExternalLinkIntake.swift`, `SourceAppResolver.swift` | Step 5 | e2e `routing_cold_launch_queue`, `routing_dedupe_2s`; [receipt](routing.md#phase-b-step-5--app-intake-2026-11-05) | done | Will-finish AppleEvent handler; unknown-source delegate fallback; pending and drain counters; real LaunchServices normal cold launch plus a slow-readiness fixture. Queue and dedupe both have break-and-revert proofs. |
| Set as Default Browser | FC §7.2 General | routing §8.4; app-shell §4.4 | `App/ExternalLink/DefaultBrowserService.swift` | Settings + existing menu command | SDK typecheck; read-only `default-browser-state`; e2e `routing_default_browser_read_only` | done (API; B2 unverified) | One sequential async request per scheme, separate catches, both schemes re-checked. Bundle-id state check, change callback, no launch prompt. Tests never call the setter. Accept/decline of the real system prompt remains a user hand check. |
| Air Traffic Control command-bar action | FC §6.3 r8 | `docs/settings.md` adapter table | registry `air-traffic-control` | main | `commands-dump` | done | Opens Settings ▸ Links (`App/AppDelegate.swift` `air-traffic-control`, #85). |
| Meeting links (Meet) toast | FC §6.2 r7 | excluded by routing §0.2 ("Meet links route like any other link in v1") | — | — | — | unplanned (deferred) | |

### 1.12 Boosts and Zap

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Boost model, per-profile store, site matching | FA BO-1, BO-5 | boosts-zap | `OpenBoosts/Boost.swift`, `BoostStore.swift`, `BoostMatcher.swift` | `App/Boosts/AppBoosts.swift` | verify-all `boosts`; e2e `boosteditor` | implemented (Section 12) | One store and matcher per loaded Profile; shared editor/Library mutation boundary. |
| Components: CSS, JS, color, font, text zoom and transform, Zaps | FA BO-2–4; BO-23 (color remap, #111) | boosts-zap (lead Q8); site-control-boost-editor | `OpenBoosts/InjectionPlan.swift`, `Resources/boost-applier.js` | `BoostEngineAdapter` | `boosts` A1–A6; e2e `boosteditor` | implemented (partial) | The color remap acts in HSLA space (`docs/re/features-advanced.md` BO-23, #111). |
| Document-start injection; SPA re-apply | FA BO-8–9 | app-shell §4.5 | `boost-applier.js` | `BoostEngineAdapter`; commit/address hooks | e2e `boosteditor` B9; `features` User scripts | implemented | Main-frame document start; separate user JS; SPA refresh. |
| Isolated world for the applier and the picker | `docs/followups.md`; engine-patches P7 | engine-patches P7 | — | — | `boosts` (Chrome isolated world) | planned | |
| Zap picker: hover, click, robust selector, related elements, undo | FA ZA-1–6 | boosts-zap §7 | `Resources/zap-picker.js`, `PickerMessages.swift` | none | `boosts` A7–A11, O1–O3, E1–E3 | planned | |
| Global switch "Enable Boosts on websites you visit" | FA BO-5; IS §18 Advanced | settings §5.5 | `OpenSettings/AdvancedPane.swift` | main (switch) | `settings-preview` | done (partial) | The switch removes scripts and clears live pages; re-enabling refreshes them. e2e `boosteditor` B10/B12. |
| Boost editor (simple panel, full editor), gallery, New/Edit Boost, View Boosts | FA BO-11–13; MH File, Window | site-control-boost-editor (#61; spec in #107) | `OpenSiteControl/BoostEditor*`; `OpenSettings/BoostsSection.swift` | `App/Boosts`; command and Customize Page dispatch | e2e `boosteditor`; `settings-preview` | implemented (partial) | Simple editor and Library are wired. Code mode and Zap are blocked. Legacy uses simple mode; Gallery disabled. |
| Boost sharing and install from link | FA BO-6 | — | — | — | — | out of scope | |
| Import Arc Boosts | DM §2.6 | none (no `StorableBoostsData.json` sample on this Mac) | — | — | — | unplanned | Blocked on a sample (§5.2). |

### 1.13 Site Control Center

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Popover from the URL pill button | FA SC-1 | site-control-boost-editor (#61, spec in #107); interim `NSPopover` in app-shell §4.9 | popover chrome in PR #69; sidebar sends `showSiteControls` | none | none on `main` | in PR | Step 1 is PR #69. In the App today `showSiteControls` still returns `false` (factory line 366). The panel is 236 pt with a top arrow (capture session 2, #107). |
| Site permissions rows | FA SC-2 | site-control-boost-editor Step 2; app-shell §4.9 | sections in PR #96; engine `permission` / `setPermission` | none | e2e `features` "Permission prompts" (engine) | in PR | Step 2 is PR #96. |
| Boosts section | FA SC-3 | site-control-boost-editor Steps 2, 4 | in PR #96, #103 | none | none | in PR | |
| Extensions section (pin, site access) | FA SC-4 | site-control-boost-editor; extensions-ui §3.9–3.10 | `OpenExtensionsUI`, optional SCC context ([#175](https://github.com/SergeSerb2/open/pull/175)) | App `.showSiteControls` remains a stub | `extensions-render picker.keys`; `sitecontrol-render extensions-check`; `extensions-ui X13_picker` BLOCKED | planned (library ready) | Section 12 owns the SCC presenter/data source and Cmd+E picker. Pin/context-menu APIs and per-window context are wired in [#189](https://github.com/SergeSerb2/open/pull/189). |
| Footer: Copy URL, Share | FA SC-5 | site-control-boost-editor | in PR #69, #96 | none | none | in PR | Session 2: 4 action buttons (Share, New Boost, two Capture). Copy URL moved to the ⋯ menu (#107). |
| Footer: Capture, Capture in Portrait Mode, Capture Full Page | FA SC-5, §9.1 | page-platform (#73) | none | none | none | planned | See Capture in §1.17. |
| Ad-block per-site toggle with reload | FA SC-6, AD-7 | site-control-boost-editor; `docs/adblock-lists.md` | `OpenAdBlock/SiteRules.swift` (`setExcluded`) | none | `openkit adblock` | planned | The toggle needs the panel (PR #69, #96) and blocking (§1.14). |
| Security state (secure or not) | FA SC-7 | site-control-boost-editor | in PR #96 | none | none | in PR | |
| Clear cookies and cache for the site; zoom reset | app-shell §4.9 | app-shell §4.9; site-control-boost-editor E2 | engine `clearBrowsingData(origin:)` | none | none | planned | Whole-profile clear works from Settings (§1.10). Per-site clear waits for the panel. |

### 1.14 Ad blocking

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| 46-list catalog, upstream URLs, pins, ETag downloads, per-profile lists, global switch | FA AD-3, AD-4, AD-6 | adblock-fork (Swift slice) | `OpenAdBlock/*` | main (store) | verify-all `adblock-perf`, `adblock-catalog` | done (partial) | Spot-check: Step C creates `AdBlockStore` and attaches it to Settings (`App/Stores/AppStores.swift:15`, `AppSettingsActions.swift:21`). Blocking is still off. List pins are stale; refresh is Step 7 work (`docs/followups.md`). |
| Network blocking (adblock-rust in the fork) | FA AD-2, AD-5; `docs/adblock-design.md` | adblock-fork Steps 1–8 (plan revised in #105) | Step 1 on `main`: crate vendored (#97, `Engine/fork/patches/rust/0001-adblock-vendor.patch`); Steps 2–3 in PR #98, #100 | none | Real ad-tech URLs: 5.5 µs per check; in-tree 6.0 µs (#97) | in PR | The App blocks nothing today: "Ad blocking is not active in this build" (`AppSettingsActions.swift:112`). |
| Cosmetic filtering and scriptlets | FA AD-5 | adblock-fork (cosmetic pull, #105) | — | none | none | planned | Steps 4–8 of the fork plan. |
| Per-site exclusion | FA AD-7 | adblock-lists | `SiteRules.swift` | main (saved only) | `openkit adblock` | planned (partial) | Settings saves exclusions. No matcher reads them until blocking lands. |
| Settings: lists by category, advanced, reset, debug info | FA AD-8 | settings §5.5 | `OpenSettings/AdBlockSettingsModel.swift` | main | `settings-preview` (loopback server) | done | Shown in the App (Step C). Debug info says the engine adapter is pending. |
| Warning when an extension blocker also runs | FA AD-1 | settings (`hasOtherBlocker`) | `OpenSettings` | main (partial) | `settings-preview` | planned (partial) | P3 exposes the live per-Profile registry (#177); `AdBlockSettingsModel.hasOtherBlocker` still has no App assignment. |
| Auto-disable an extension blocker on allow-listed sites (uBlock on YouTube) | FA AD-7 | none | none | none | none | unplanned | Arc's reason is unknown (FA §7.4 q6). |

### 1.15 Import from Arc

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Sidebar: Spaces, pinned, Today, folders, splits, favorites, icons, themes | DM §2, §5 | model.md "OpenImport" | `OpenImport/ArcImport.swift` | CLI `openkit import-arc` only | verify-all `roundtrip`; `import-arc` needs `--with-arc-data` (not run) | planned | Spot-check: the App wizard now shows (Step C), but `runImport` returns "Import is not available in this build" (`App/Settings/AppSettingsActions.swift:111`). Library and CLI only. |
| Windows and session selection | DM §2.4, "Archive and session files" | model.md | `ArcImport.swift` | CLI only | model.md (session1 snapshot: 2 applied selections) | planned | |
| Routing rules | DM | model.md | `ArcImport.swift` | CLI only | model.md | planned | |
| Archive | DM "Archive and session files" | model.md | `ArcImport.swift`; `ArchiveStore.importRecords` | CLI only | model.md | planned | |
| History | import2 §2 | model.md "phase 2" | `OpenImport/ArcHistoryImport.swift`, `OpenStore/HistoryImport.swift` | CLI `import-arc-history` only | model.md (F1, F2: 100,000 visits in 1.443 s; real History 24 visits) | planned | |
| Read and decrypt passwords, cookies, cards, addresses (consent-gated) | import2 §3 | import2 Part A; passwords-autofill (#72) | `OpenImport/ArcSecrets.swift`, `ChromiumCrypto.swift` | CLI (synthetic fixtures only) | `openkit verify-secrets-fixture`; model.md S1/S2 | planned (counts only) | The real Keychain path was never run (lead decision). The App reports `canImportPasswordsAndCookies == false`. |
| Write imported secrets into Open's profile | import2 §3.7 "Part B" | passwords-autofill (#72: Chromium manager in the fork) | none yet | none | none | planned | Was unplanned. The plan closes the §5.4 decision: use Chromium's built-in manager with Arc's UI. See §3, gap 2. |
| Extensions: detect reinstall candidates | import2 §2 | model.md | `OpenImport/ArcExtensions.swift` | CLI | model.md (synthetic union) | planned (detect only) | P3 management install is on main (#177); the import reinstall workflow still needs wiring (Import owns it). |
| Boosts | DM §2.6 | none | — | — | — | unplanned | Blocked on a sample. |
| Multi-profile Arc installs | DM §6 item 3; profiles Q1 | profiles Q1 (lenient parser) | `ArcImport.swift` | — | — | planned | Needs a sample (§5.2). |
| Import wizard (Settings ▸ General ▸ Import from Arc…) | — | settings §5.8 | `OpenSettings/ImportWizard.swift`; shared count probe (#66) | main (UI) | `settings-preview` `import-counts`; 32-flow receipt (#66) | done (partial) | The wizard shows in the App and counts with the importer rules (#66). Run still returns the not-available outcome. |
| Import in the first-run flow | — | first-run Steps A–B done (#66); C–F left | `OpenSettings/FirstRun.swift` | none | 32-flow receipt (#66) | planned | Preview screens only. No App change in #66. |
| Top Sites, site engagement | — | import2 lead decision: skip | — | — | — | out of scope | |

### 1.16 Extensions

Main has the shell and engine milestones listed above. The suites here are separate evidence gates: `extensions` proves the runtime, `actions` proves engine actions/popups, `extensions-p3` proves registry/consent/commands, `extensions-e2` proves windows/omnibox/tab events, and `extensions-ui` proves the native shell. `tabstrip` and `find` cover their shared paths. Each uses the real App; render CLIs cover library surfaces only.

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Extension runtime: MV3 service workers, content scripts, declarativeNetRequest, options pages | AGENTS.md v1 | engine-spike; engine-patches P1–P3 | `Engine/OpenEngine` | main (#53, #93, [#177](https://github.com/SergeSerb2/open/pull/177)) | `extensions` 8/8; `actions`; `extensions-ui X5_ublock_dnr_badge` | done | Real uBO Lite, Dark Reader, 1Password and Bitwarden fixtures. |
| `chrome.tabs` and `chrome.windows` see Open's tabs | engine-patches P1 | extensions-ui §7; engine-patches | fork tab-strip bridge, `TabStripMirror` | main (#53, [#184](https://github.com/SergeSerb2/open/pull/184)) | `tabstrip` 35/35; `extensions-e2` sidebar events/array moves; `extensions-ui X6_popup` | done (partial) | Normal extension windows adopt selected Today tabs; popup windows retain their own browser identity. Standalone Little Open execution remains X-19 below; remaining P1 limits stay in followups. |
| Live icon, badge, title, enabled, pin/order and context menu | FA EX-1/2/9/14 | extensions-ui §3.1–3.6, E1–E7 | `OEExtensionAction`, `OpenExtensionsUI` ([#175](https://github.com/SergeSerb2/open/pull/175)) | main ([#189](https://github.com/SergeSerb2/open/pull/189)) | `actions` 26/26; `extensions-e2` pin/native-drag safety; `extensions-ui X2–X5, X10–X11` | done | Chromium draws `toolbarImage`; shell caches by image identity. Engine #184 fixes repeated pins, invalid moves and persisted duplicates. App keeps a first-ID guard and exposes `duplicatesDropped`; acceptance requires zero. |
| Popup host, `setIcon`, `onClicked`, `chrome.action.openPopup()` | FA EX-12/13 | extensions-ui §3.7, E6 | `ExtensionViewHost`, `ExtensionPopupPanel` | main (#93, #175, #189) | `actions` popup/API/callback-close rows; `extensions-ui X6–X10`, popup timing | done | Ready/resize, focus, D1–D8 observers and Inspect Popup keep-open use the real panel. |
| Install, remove, enable/disable, permission prompts and Web Store consent | FA EX-15 | extensions-ui §3.11, E8–E10 | live per-context manager ([#177](https://github.com/SergeSerb2/open/pull/177)), prompt sheet/queue (#175) | main (#189) | `extensions`; `extensions-p3` 14/14 and hosted-store receipt; `extensions-ui` install Cancel/Add, X14/X15, FIFO/close/quit | done (partial) | Open sheets are the normal handler. Chromium dialogs run only without a shell handler. Packed permission-increase update/re-enable consent is UNVERIFIED; normal disable/re-enable and optional permissions pass. |
| Extensions menu, overflow, Manage/Add pages | MH Extensions; FA EX-5/11 | extensions-ui §3.5, §3.12 | `ExtensionsMenuBuilder`, `OpenCommands` | main (#175, [#179](https://github.com/SergeSerb2/open/pull/179), #189) | `extensions-render menu.bar/menu.relabel`; `extensions-ui X16/X17`, overflow anchor | done | Pinned first, unpinned by name, then Manage/Add; lazy menu update. Manage is a focused-Space singleton. The page-menu Manage hook is still open in Section 11. |
| URL, pane and toolbar placement; Find coexistence | FA EX-1/2 | extensions-ui §3.2–3.3 | `ExtensionStripView`, `ToolbarMetrics.siteControls(width:stripWidth:)` | main (#175, #189) | `extensions-render`; `extensions-ui X3/X18`, toolbar/overflow and native Find overlap; `find` F33 six pinned-strip native-close gates | done | URL hover-only; focused pane only. Toolbar rightmost maxX w−5; SCC left of strip (guess C1). Reference captures remain open. |
| Cmd+E extension picker / SCC Extensions section | FA EX-6–10 | extensions-ui §3.9–3.10 | shared row/tile body and keyboard focus (#175); hidden command (#179) | `.showSiteControls` stub; context/refresh seam ready (#189) | library `picker.keys`, `sitecontrol-render extensions-check`; real-App `extensions-ui X13_picker` BLOCKED | planned | Section 12 owns the presenter/data source. No real-App picker acceptance yet. |
| Little Open Extensions button and menu | FA EX-3 | extensions-ui §3.4, ruling A | title-bar button/menu and standalone browser attachment | #185 page; [#192](https://github.com/SergeSerb2/open/pull/192) | `extensions-ui X19_button_menu`, `X19_popup_less_target`, `X19_activeTab_grant`, `X19_popup_tabs_query`, `X19_popup_anchor`, `X19_extra_tab_main_today`, `X19_one_action`, `X19_zero_actions`, `X19_profile_switch` PASS | done | Button inside URL capsule [w−252,16,16,16], guess S-7. Actions bind to the standalone OEBrowser, then re-attach after Profile replacement. Old delegate and action list clear. No main-window fallback. Extra extension tabs open selected in the most recent main window’s Today (guess, Arc capture needed). |
| Native extension popup windows | FA EX-12 | extensions-ui §3.8, E11 | `ExtensionWindowController` | main ([#184](https://github.com/SergeSerb2/open/pull/184)) | `extensions-e2 X20_*`: native class/view, bounds, popup type, resize/focus/remove; popup Cmd+W | done | Standard titled/resizable window with its own hidden Browser/strip and native frame autosave. |
| Extension keyboard shortcuts and Settings Extension Shortcuts | FA EX-11; MH Custom shortcuts | extensions-ui §6.2–6.3 | command snapshots (#177), Shortcuts menu/notice (#179) | `ExtensionShortcutTable`, Settings adapter (#189) | `extensions-ui X12_*`, `X27_*` ([closeout PR](https://github.com/SergeSerb2/open/pull/190)); `settings-preview`; `commands-dump` | done | X-27 proves menu singleton, exact user-conflict notice, dropped command, Open-key priority and extension recovery through real KeyBindingStore saves. Global (`"global": true`) command OS delivery remains UNVERIFIED. |
| Omnibox keywords and run extension by name | FA EX-19/20; FC §4.2/4.4 | extensions-ui §3.14 | providers/scope UI (#179), E12 engine/App source (#184) | main (#189) | `extensions-e2 X22–X26`; `suggest-check`; `commandbar-render` extension scenes | done | Current/new/background disposition, stale-reply rejection, cancel/delete and Site Search priority. Gap 37 is closed. |
| Folders as `chrome.tabGroups` | engine-patches lead decision 3 | no groups in v1 (#64) | Chromium 0304 (no group model) | main | `tabstrip no_tab_groups` | out of scope | No evidence Arc maps folders to groups; §5.4. |
| `chrome.sidePanel` hosting | FA EX-17 | extensions-ui Q6 | — | — | lead ruling Q6 | out of scope | Not in v1. |

Extensions follow each Profile's own `OEBrowserContext`; no shell install/pin/command store is shared across Profiles. P3's non-default-profile install receipt proves registry isolation. Section 10 owns the remaining per-Profile UI gaps; the default-profile suites do not close them. Reference captures S-1…S-12 and toolbar C1 remain in the plan's capture list. Global OS delivery and packed permission-increase updates are separate unverified gates, not the two blocked App presentation rows.

### 1.17 Engine and platform basics

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Own Chromium 156 fork with CEF embedding layer; default engine source | AGENTS.md | fork-infra; `docs/engine-fork.md` | `Engine/fork` | main (PR #46) | e2e on the fork (`results-shell-release-fork.json`, `results-features-alloy-fork.json`) | done | |
| Proprietary codecs (H.264, AAC, HEVC) | engine-patches P4 | P4 | GN args | main | `results-features-alloy-fork.json` (`codecs`) | done | Licensing is on the release checklist (U-6). |
| Widevine DRM | — | — | — | — | — | out of scope | Lead decision (fork-infra appendix). |
| Downloads: destination and progress | FA DL-1; page-chrome §4 | app-shell §4.9; S11 Downloads design | `App/PageChrome/DownloadsCenter.swift`; `OpenSettings/DownloadsSection.swift` | main ([#181](https://github.com/SergeSerb2/open/pull/181)) | e2e `downloads` 34/34; 34 negative proofs; full verify + quiet timing rerun | done | One callback-driven session list, cached file availability, Profile destination routing, live byte/speed/source subtitles, pause/resume/cancel, file-type menus and Trash. No completed-download history writer. See `docs/downloads.md` for exact evidence limits. |
| Downloads UI: Home badge, Cmd+Shift+J, Library section, quit warning | FA DL-1; FC §8.1 r4; page-chrome §4 | app-shell §4.9; S11 Downloads design (supersedes popover) | `HomeDownloadButton.swift`, `DownloadsSection.swift`, `DownloadsCenter.swift` | main (#181) | e2e `downloads` 34/34; idle ten zero counters; e2e `window` 76/76 | done | Home owns the progress ring and finite completion animation; Home during/recently after a transfer and Cmd+Shift+J select Library ▸ Downloads. The download quit alert precedes history/sleep capture and page-beforeunload. Geometry and the 60 s recent interval remain guesses. No separate popover. |
| Find in page: bar, count, next, previous, Esc | MH Find; page-chrome §1 | app-shell §4.9 | `App/PageChrome/FindBarView.swift`, `FindController.swift` | main ([#187](https://github.com/SergeSerb2/open/pull/187)) | e2e `find` 58/58; lead final merge: `find` 59 PASS, `split` 81 PASS; `page-chrome` 41/41; full verify | done (reference captures pending) | One bar per pane/Peek, inside the page viewport at top/right 10 pt, clear of toolbar and extension chrome. Toolbar off/on, split/narrow panes, Peek, live resize and native close clicks pass. First/repeat p95 3.832/0.949 ms over twenty samples each (8.333 ms limit; load1 6.05–8.22); lead post-#186 merge 3.67/0.89 ms. Light/dark ΔE00 0.498/0.384; idle counters zero. The old root Find field is removed; Section 6 removed the legacy root extension-bar hiding bridge in [#189](https://github.com/SergeSerb2/open/pull/189). Find and Replace opens Find; Jump to Selection scrolls the DOM selection through page-world JavaScript. See `docs/engine-spike/find/README.md` and the Section 11 leftovers. |
| Page context menu: link, image, selection, spelling; Open in Peek, Little Open, Split | MH "Context menus"; `docs/re/page-chrome.md` §5 | S11 lead design (2026-11-05); allowlist #94 | `App/PageChrome/PageContextMenuBuilder.swift`, `PageContextMenuHooks.swift` | main ([#178](https://github.com/SergeSerb2/open/pull/178), #183) | e2e `context-menus` 34/34 (#178 and #183); native receipts below | done (Open order; Arc order unverified) | Preserve Chromium order/submenus/checkmarks. Open replaces link-open actions and adds Profile search/Go to after Copy; Translate → Capture → Source → Inspect on pages. Peek uses Section 9’s public entry. Little Open forwards URL/Profile to the real coordinator merged in #183; it is no longer a stub. Hooks: `mediaItems` after image/media; `extensionItems` before Inspect; both empty by default. Exact Arc page-menu order remains unverified ([page-chrome §5](re/page-chrome.md#5-page-context-menus)); #170 supplies static facts, not visible-order acceptance. |
| Permission prompts (Arc style, remember) | FA SC-2; page-chrome §3 | app-shell §4.9; S11 design; Section 12 hook | `App/PageChrome/PermissionPromptPresenter`, `SitePermissionStore` | main ([#180](https://github.com/SergeSerb2/open/pull/180)) | e2e `page-chrome` 41/41; `features`, `page`, `sleep`; [S11 receipts](engine-spike/s11-dialogs-permissions.md) | done (partial) | Allow persists in the engine Profile; Not Now denies one request and restores the prior setting. URL-pill/toolbar/content anchors pass; Section 12 supplies `anchorProvider` and uses `SitePermissionStore`. Protocol handlers have no engine API path; enumeration covers App-known origins only. Little Open now uses the standalone surface and an in-window permission card; MIDI persistence, focus, motion, and negative proofs are covered by `page-chrome` `little_*` ([receipt](engine-spike/s11-littleopen-pagechrome.md)). Arc captures remain open (#170, page-chrome §7). |
| Web notifications delivered to macOS Notification Center | — | page-platform Steps 7, 16 | `App/Page/NotificationAuthorization.swift`, `NotificationClicks.swift`, `Helper/Info-Alerts.plist`; `Engine/fork/src/open/browser/page/open_notifications.cc` | main (#160, engine #158) | e2e `page` N1–N4, N6; `sleep` N5 (#156) | done (partial) | Engine display/list, Alerts helper, page activation and 500 ms origin/profile fallback pass. `N1_macos_delivered` (U-N1) and `N6_click_opens_tab` (P1 clients.openWindow) are BLOCKED. See gap 12. |
| JavaScript dialogs: alert, confirm, prompt, beforeunload | page-chrome §2 | app-shell §4.9; S11 design | `App/PageChrome/PageDialogPresenter` | main (#180) | e2e `page-chrome` 41/41; `shell` 7/7; `window` 76 PASS; runner lifetime 4/4; [S11 receipts](engine-spike/s11-dialogs-permissions.md) | done (partial) | Native sheets, exact title/button copy, per-document suppression, background queues and one-completion teardown pass. Beforeunload uses the engine close path; Cancel keeps the tab or aborts quit. Messages over 8 KiB / prompt defaults over 4 KiB are refused; truncation parity and queue boundaries remain follow-ups. Little Open sheets and close/quit beforeunload now use the same queue; `page-chrome` `little_*` covers the real window and early-load/hidden cases ([receipt](engine-spike/s11-littleopen-pagechrome.md)); Arc captures remain open (#170, page-chrome §7). |
| History recording per profile (FTS) | FC §4.2 | app-shell §4.8 (Step H) | `App/Stores/AppHistoryRecorder.swift`; `OpenStore/HistoryStore.swift` | main ([#172](https://github.com/SergeSerb2/open/pull/172), [#183](https://github.com/SergeSerb2/open/pull/183)) | e2e `history` 26/26; `littleopen` `history` in 34/34 ×3; `suggest-check`; `openkit bench` | done | Main-frame document and same-document commits record off the main actor; redirects record the final URL, reloads add none, title changes update the existing visit. Internal and ephemeral pages are excluded. Back/forward, Peek and Little Open counting as links remain lead-directed guesses. #183 closes the Little Open history gap: each page is an `EngineWebContentHost` with its own per-Profile `AppHistoryRecorder`; close flushes accepted titles, and quit closes Little Open windows before other hosts. |
| History view (Cmd+Y) | MH Archive | settings Library History | `OpenSettings/HistorySection.swift` | main (#85, #172) | e2e `history` 26/26 (live Cmd+Y, delete/clear and Profile isolation); `settings-preview` | done | Cmd+Y opens Library ▸ History (#85). Committed visits and coalesced titles appear live through an event stream. Delete Selected, row Delete and Clear History mutate only the selected Profile's store. |
| Picture in Picture for video | FA §8 (PP-1, PP-2) | media-pip (D-8: phase 1 keeps Chromium's PiP window) | phase-2 window in `OpenFeatures` (#101); App session `MediaCoordinator` | main (phase 2: Open's own window, media-pip Steps 9–10, fork patch `chromium/0402`) | e2e `features` "Picture in Picture"; e2e `media` `media_auto_pip_on_leave`, `media_back_to_tab`, `media_close_snoozes`, `media_largest_video`, `media_pip_frames`, `media_pip_minimize`, `media_pip_keep_on_top`; `features-render check` PP1–PP8 (#101); phase-2 window vs S2 13 (`Packages/OpenKit/MediaRenders/section3-parity/`: 320 × 180 at 10 pt insets on the capture display, continuous 6 pt corner, 1 pt white 0.12 edge) | done | The App owns the PiP session (§4.4.6): one PiP app-wide, Back to Tab, Close pauses and snoozes. Steps 9–10: the video plays in Open's own window (the fork's `OpenVideoOverlayWindow` puts Chromium's video surface into an `NSView`; Chromium's controller keeps its rules), with Minimize to a card and Keep Window on Top (plan §14.5). Without the App's delegate the engine falls back to Chromium's window (phase 1). Phase 1 learned of Chromium's own Close/Back to Tab only as a PiP exit (§4.4.1); it waits 400 ms for the pause of a Close (§14.3). PiP from the engine needs no user gesture and respects `disablePictureInPicture` (e2e `media_pip_no_gesture`, `media_pip_disabled_engine`). Open's window follows the S2 13 capture; Chromium's window (phase 1) missed it (501 × 282 at 32 pt insets, square corners). |
| Auto-PiP on tab leave; Google Meet auto-PiP; Document PiP | FA §8 (PP-3–5) | media-pip (D-4, D-5) | policy (#63); App leave events (`MediaCoordinator.windowChanged`); Document PiP header (#101) | main (tab leave, Section 3 Steps 5–6) | `media-demo` AP1–AP11; e2e `media` `media_auto_pip_on_leave` (request→enter in the run), `media_auto_pip_return`, `media_auto_pip_negatives` (setting off, inaudible, `disablePictureInPicture`, disallowed host, `activatesWhenInaudible`) | done (tab leave); planned (Meet, Document PiP) | Leave events come from the displayed-set diff of each window (selection, Space switch, split), so minimize, occlusion and app hide never open PiP (D-4). Meet's own auto-PiP (EM-6) and Document PiP (EM-7) are Step 11. |
| Mini player controls: play/pause, tracks, mute, camera/microphone toggles | FA §8 (PP-6–9, PP-21) | media-pip; redesign §13 (#109) | `OpenSidebar` cards (#92, #110); App `MediaCoordinator.perform` | main (play/pause, previous/next, mute, Back to Tab, Close, Open PiP) | e2e `media` `media_card_controls` (real card clicks; `navigator.mediaSession` handlers count previous/next) | done | Commands go to Chromium's media session, which calls the page's own `mediaSession` action handlers (Step 7). Step 8: the volume drawer sets the engine's tab volume (EM-2; e2e `media_volume_drawer`), and a capturing tab with microphone or camera toggles gets a recording card even when its session is not controllable (e2e `media_recording_card`; `media-demo`). The drawer layout is a guess (§13.7 O2); microphone/camera cards ship with Step 8 (Q13). |
| Print (Cmd+P), print to PDF | MH File | — | — | main | e2e `features` "Print to PDF" | done | |
| Save Page As (Cmd+Shift+S) | MH File | app-shell §4.3 | MHTML snapshot from the App | main | none (code read) | done | Step C saves an MHTML snapshot (`App/MainMenu.swift:162` `savePage`, #85). |
| Zoom in, out, actual size | MH View | — | — | main | e2e `features` "Zoom" | done | |
| Zoom toast ("110%") | IS §16; PG-3.1 | page-platform Step 3 (Section 8) | `App/Page/PageCommands.swift` `zoomPage`; EP-5 in `OEWebContent resetZoom` | main (#163) | e2e `page` Z1, Z2, Z4 | done | `zoom-in`/`zoom-out`/`zoom-actual-size` show the percent ("110%", "125%", "100%"); Actual Size also resets the pinch scale. Smart zoom: user check U-S1. |
| Toasts: Space-tinted, top-right of the page, stacking | IS §16; PG-1, PG-14 | page-platform Steps 1–2 (Section 8) | `OpenFeatures/Toasts/` (`ToastCenter`, `ToastView`, `ToastOverlayView`), `OpenDesign/PageTokens.swift` | main (#153) | `features-render` R-T1–R-T7; automation `toasts`, `toast-action` | done | One `ToastCenter` per window and per Little Open window; every toast (Peek closed, sidebar undo toasts, Copy URL, pane-bar Copy, command bar "Copied") uses it. Fill and text read one rule with the first-hide hint (`SpaceThemeStyle.toastFill`/`toastText`), including the macOS Light lavender toast (S2 20/0048). Share button and zoom toast merged in #163 (e2e `page` T-E1/T-E2, Z1/Z2/Z4). |
| Native and HTML full screen | FC §8.2 r5 | app-shell §3.8 | — | main | e2e `features` "HTML fullscreen"; e2e `window` | done | A flaky full-screen test fix is PR #112 (in PR). |
| Multiple windows (Cmd+N), per-window state | FC §8.1 r1 | app-shell §3.8 | model window commands | main | e2e `window` (two windows, restore) | done | |
| Close Window (Cmd+Shift+W), Blank Window, last-window behavior | FC §8.1 r2, r4; IS §17 | app-shell §3.8, §4.3 | `App/MainMenu.swift`; system close handler | main (#85; #178 keeps Blank Window unchanged) | code read; e2e `window` covers standard-window close/restore | done (partial) | `blank-window` follows the existing New Window path; `close-window` is a system item (#85). Blank Window parity remains GUESS: a distinct “This Window” sidebar has no proved specification. #178 adds no separate Blank Window behavior. |
| Renderer crash recovery (Sad Tab) | FA ST-1 | app-shell §4.13 (placeholder offers reload) | model `tab.live.isCrashed` | main (crash state reaches the model) | e2e `features` "Renderer crash" | planned (page UI) | |
| Relaunch restores windows, tabs, selection | FC §3.7 r24–25 | app-shell §3.8 | `OpenStore/SnapshotStore.swift` | main (#149) | e2e `shell` persistence; e2e `window` restore; Release `relaunch` 70/70 | done | `tools/e2e/engine_e2e.py`; three committed results-relaunch-release receipts. |
| "Restore windows from previous session" switch | FC §3.7 r24; IS §18 Advanced | settings | `OpenSettings` | main (setting) | `settings-preview` | planned (setting only) | The switch shows in the App. Restore always runs. |
| Warn before quitting; downloads in progress | FC §7.2 General, §8.1 r4 | settings G-2; S11 Downloads design | `OpenSettings`, `App/PageChrome/DownloadsCenter.swift` | main (#181) | e2e `downloads`: Keep/Close/empty-quit PASS | done (downloads); generic warning UI not implemented | Downloads warning uses the evidenced strings and runs before quit capture. The Settings switch exists, but generic Warn-before-quitting UI is not implemented because no Arc warning presentation was proved. [Downloads RE](re/downloads-s11.md) records preference/action labels only (`FUN_1005a4098`, `FUN_100ff5350`); #181 does not claim a generic dialog. |
| Updates (Sparkle, Check for Updates…) | FC §7.2 General | release §6; Sparkle pinned in Step 7 (#83) | Sparkle in the release build (#83) | main (stub) | Release build copies Sparkle (#83) | planned | In the App, Check for Updates reports that no feed is available (`AppSettingsActions.swift:89`). |
| Developer tools, JavaScript console, view source, inspect | MH Developer | page-platform Steps 4–5 | `App/MainMenu.swift`, `App/Page/PageToolsCommands.swift`; `OEWebContent.mm` | main (#164) | e2e `page` D1/D2, `D1_key_cmd_opt_j_chrome`, `D1_quit_with_devtools_open` | done | Console/Elements/Network switch the existing DevTools front end; View Source opens a view-source tab. |
| Network Inspector, Toggle Developer Mode, Allow JavaScript from Apple Events | MH Developer | page-platform Steps 5, 16, 18 | `App/Page/PageToolsCommands.swift`, `DeveloperMode.swift`; `OpenScripting/ScriptCommands.swift` | main (#164, #174) | e2e `page` D1–D4; `applescript` D4 off/on/off PASS | done (D4 PASS; external consent blocked) | Network uses the DevTools front end. Developer Mode stores site hosts and shows the full URL. #174 hosts the JavaScript gate: off returns 1013; on returns JavaScript text; off again returns 1013. D4 passes through self-sent Apple events. External osascript/JXA remain BLOCKED by macOS Automation consent (-1744); see `docs/scripting.md` hand checks. |
| Page translation: offer, translate, revert, never translate a site, reset | FA §9.2 TR-1–3 | page-platform (#73: on-device path; Chromium translate needs a Google key) | `OpenTranslate`, `OpenSidebar/URLStatusButton.swift`, `OpenFeatures/Translate/`, `App/Page/TranslateAdapter.swift` | main (#152) | `openkit lang-detect`; `features-render` R-X1; `sidebar-render` S-US1; e2e `page` X1–X6 | done (partial) | Apple Translation + NaturalLanguage, no network. Runtime in the main world until P7 (Step 19). e2e uses the automation-only fixture backend; Apple's backend row waits for U-X1. See §3, gap 8. |
| Capture: area, full page, portrait; Cmd+Shift+2; Cmd+Shift drag | FA §9.1 CA-1–4; MH Gestures | page-platform Step 13 (Section 8) | `OpenFeatures/Capture/*`, `OpenDesign/CaptureTokens.swift`, `App/Page/CaptureLibraryWriter.swift`, `App/Page/CaptureCommands.swift`, `OEWebContent.captureFullPage` (EP-8); `OpenSettings/CapturesSection.swift` (reader) | main (#154) | `features-render` R-C1–R-C3 and controller rows; e2e `page` C1–C6 (C7 blocked: no incognito window) | done (partial) | Overlay, result card, and portrait canvas are guesses until captures C-C1 and C-C2. Toasts use ToastCenter (#153). See §3, gap 13. |
| Sound effects | FA §9.7 | sidebar-completion (M4) | `OpenFeatures/SoundEffects.swift` with Open-generated sounds (#80); `OpenSettings` switch | none | `features-render` SE1–SE3 (#80) | planned | Spot-check: library only. Sounds exist and play through `SoundEffects`, but no App or sidebar code calls `play` (grep finds callers only in `features-render`). The switch defaults off. |
| Share (File ▸ Share…, row Share…) | MH File; IS §15 | app-shell §4.1, §4.3 | `App/SidebarMenuActions.swift` | main (#132) | `I9_share_system_picker` | done | File ▸ Share uses the system picker. Items 9–10 (#132) wire the row Share… item through `share` to `NSSharingServicePicker`, anchored at the row; `I9_share_system_picker` checks its URL, service query and cancellation. |
| Spelling, substitutions, transformations, speech, font menus | MH Edit | app-shell Step C (system dispatch) | registry; `SystemCommandActions` selectors | main | — | done | Closed in #85: 46 system ids keep AppKit selectors (§2). See §3, gap 3 (closed). |
| Two-finger swipe back/forward on the page; pinch zoom | MH "Gestures" | page-platform Steps 11–12 | `OpenFeatures/SwipeIndicatorView.swift`, `OpenDesign/SwipeIndicatorTokens.swift`; `App/WebContent/EngineWebContentHostFactory.swift` | main (#158, #162) | `features-render` R-W1; e2e `page` SW1–SW4 | done (partial) | Tab and split-pane indicator, cancellation, system preference and Capture pause pass. Real gestures and pinch/smart zoom remain U-S1. Peek uses the same native indicator (`peek_swipe_indicator`, s9); Little Open also attaches it in its standalone host; Zap and command-bar backdrop pause remain open. |
| Optional toolbar (Show/Hide Toolbar, full URL) | FC §8.2 r6 | commandbar-completion §4.6 (#70, Step 8) | `BrowserWindowState.showsToolbar` (snapshot field, absent = off); `PaneChromeView` toolbar role; `BrowserWindowController.toggleToolbar`, `menuTitle(for:)`; sidebar `.setToolbarShown`, `.setShowFullURL`, `.manageExtensions` | main (#143), main (#144) (App) | `features-render` TB1–TB13; `commands-dump` runtime titles; `roundtrip` toolbar; e2e `toolbar` (10 rows) | done | The 32 pt bar is the split pane bar on a single pane: back, forward, reload, copy, host, Site Control Center (no split menu, no close). With it, the sidebar hides its URL field, Back, Forward and Reload, and Favorites move up to y 46 (layout guess, plan §9 item 1). View menu titles follow the window (CC-32). App (Step 9): Cmd+Shift+D on the key window; the right-click "Show Full URL" writes Settings ▸ Advanced's setting and every window follows it; Manage Extensions opens the extensions page; a new window copies the key window's toolbar (guess); the toolbar survives a relaunch; the Little Open window disables the command. See §3, gap 26. |
| Website appearance: Automatic, Light, Dark | MH View ▸ Appearance | page-platform Steps 5, 17 | `App/Page/WebsiteAppearance.swift`; `OEBrowserContext.websiteColorScheme` | main (#158, #164) | e2e `page` A1/A2, both styles and after navigation | done | Automatic follows app appearance; fork 0505 applies the preference without reload. |
| Clear Cache and Refresh; Clear Cookies and Refresh | MH View | page-platform Step 6 | `App/Page/PageToolsCommands.swift`; `OEBrowserContext.clearBrowsingData(origin:)` | main (#164) | e2e `page` K1/K2 | done (partial) | Host cookies clear, then reload. Domain cookies stay. Clear Cache stays disabled until Site Control E2. |
| Cast | MH View | page-platform EP-12 | `App/Page/PageToolsCommands.swift`; `Engine/OpenEngine/src/OEApp.mm` | main (#164) | e2e `page` H4 | out of v1 | Hidden and not runnable; MediaRouter stays disabled. |
| Troubleshooting: Task Manager, Record/Cancel Trace, Copy Open Info, Reveal Open Data | MH Help | page-platform Steps 4–5 | `App/Page/TroubleshootingActions.swift`; `OEEngine.mm` | main (#164) | e2e `page` H1–H4 | done (partial) | Trace Stop/Show in Finder use ToastCenter. Task Manager needs a live Chrome-style page; H1 Alloy is BLOCKED. Cast stays hidden (MediaRouter off). |
| Password manager: save and fill prompts, Manage Passwords | FC §4.4 table ("Manage Passwords"); IS §18 Profiles ("Passwords", "Credit Cards") | passwords-autofill (#72: Chromium manager, Arc UI) | registry `manage-passwords` (command bar only) | main (partial) | not verified in OpenEngine | planned | Was unplanned (P0). Today Settings opens `chrome://settings/passwords` in a hosted tab (`AppSettingsActions.swift:105`). No Open save or fill prompt exists. See §3, gap 1. |
| AppleScript with Arc's terms | FA §10 | applescript Steps 1–7; app-shell §4.10 H1–H4 | `OpenScripting/*`; `App/Scripting/AppScriptEngineBridge.swift`; `App/Resources/Open.sdef`; `App/Info.plist`; `project.yml` | main ([#174](https://github.com/SergeSerb2/open/pull/174)) | e2e `applescript`: final 137 PASS / 2 external-consent BLOCKED; warm/cold, A-checks, R1–R3, 1000–1014; `page` D4 PASS; `sdef Open.app` | done (partial) | H1–H4 host the dictionary and live engine commands. Direct source evaluation, strict CSP, result conversion, shared 10 s deadline and timeout recovery pass. External osascript/JXA and Script Editor remain BLOCKED by Automation consent (-1744); numbered hand checks are in `docs/scripting.md`. Incognito creation returns 1010. App-level Little Open tab creation still returns 1011: `makeLittleTab` is nil until Section 9’s coordinator can return a script-addressable tab; #183’s standalone pages are not model tabs. |
| Tab-sleep engine patches (P-MEM-01…07) | memory-design §6 | memory-fork S1–S6 | `Engine/fork/patches/cef/0101*`, `0104*`, `0105*`, `0302*`; `Engine/fork/src/open/browser/memory/`; `OEApp.mm`; `App/WebContent/EngineSleepAdapter.swift` | main (#158 + #165) | `tabstrip` sleep_hosted_visibility/freeze/unload_flag/capture/discard/discard_keeps_tab_id; `sleep` F0/F2/F4/F5 | done (capture fixture blocked) | Engine APIs and App G2 wiring are merged. App restore, corrupt fallback, discard/destroyed wake and unfreeze pass in #165. `sleep_f3_capture` remains BLOCKED. |
| Trim the Chrome layer (P5) | engine-patches P5 | P5 | — | — | — | planned | |
| Join Meeting (Cmd+Ctrl+J) | FC §4.4; MH Tabs | Lead decision S2 on live-data sources | registry; `App/MainMenu.swift` comment/false gate | main (#178; disabled) | e2e `context-menus` `cm_join_meeting_disabled` | post-v1 | Needs calendar live data. Do not add a calendar source in v1. |
| Help: Help Center, Getting Started, Release Notes, Contact the Team | MH Help (selectors); destinations are Open lead decisions | S11 (2026-11-05) | `AppCommand.helpURL(for:)` | main (#178) | e2e `context-menus` `cm_help_*` | done | Foreground Today tabs: commands document; repository `#readme`; `/releases`; `/issues/new`, respectively. |

S11 real-App acceptance passed after the #179/#181 main merge (`e485b6bd`): `context-menus` 34/34, `features` 19/19, `shell` 7/7, `app-actions` 63/63, `commandbar` 63/63, and `page` 81 PASS / 5 existing BLOCKED. Every accepted run had zero interruptions and clean owned-process shutdown. Window display receipts are reported separately in the PR; foreground-interrupted attempts are archived and never counted. Receipts: `.re/s11-context-menus/final-<suite>.json` and `regression-summary.json`. The five page blocks are Alloy Task Manager, native notification delivery, notification tab opening, unavailable Apple translation data, and incognito capture; none is a context-menu gate.

The context-menu receipt records final native order for page/link/mailto/image/linked-image/selection/URL/editable targets and executes every Open item, including URL/Profile forwarding to section 9’s Little Open entry. That entry now uses the real coordinator; Section 9 reran `context-menus` 34/34 on `4426c9b8` with engine `7b490905…`. Chromium’s image command creates the correct background Today tab/opener and is preserved. Selection (16 KiB), URL (64 KiB), node (128), and depth (8) boundary cases passed. Generated native titles at 1024 UTF-8 bytes are accepted; 1025 are refused. Chromium elides long extension titles upstream to 77 bytes; that extension case alone does not prove the App title limit. Every one of the 34 passing gate names has a recorded negative proof (`.re/s11-context-menus/negative-coverage.json`), including a failed Little Open entry after omitting its public call; all proof changes were restored and the real App rebuilt. The added empty-Space mail split gate fails on the saved old-handler App and passes with the split-aware selection fix; its negative proof has zero interruptions and clean owned-process shutdown. Headless `commands-dump` passed: missing/extra/different 0/0/0, the same 11 allowed-missing rows.


### 1.18 Settings and Library

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Settings window: 684×650, pane tabs, one reused window | IS §18 | settings | presenter in `OpenSettings` (`SettingsPresenter`) | main | `settings-preview check` (verify-all); renders in `docs/settings/`; Step C (#85) | done | Spot-check: `App/Settings/AppSettingsActions.swift:25` owns the presenter for the App. The Library's Spaces section hosts the real Space Manager (§1.2, #124). |
| General pane | FC §7.2 General; IS §18 | settings §5.1 | `OpenSettings/GeneralPane.swift` | main | `settings-preview` | done | Some actions are stubs (updates, import run). |
| Profiles pane | FC §7.2 Profiles | settings §5.2 | `OpenSettings/ProfilesPane.swift` | main | `settings-preview` | done (partial) | See §1.10 limits. Passwords and cards open `chrome://settings` pages. |
| Links pane | FC §7.2 Links | settings §5.3 | `OpenSettings/LinksPane.swift` | main | `settings-preview` | done | Rules have no effect until link intake lands (§1.11). |
| Shortcuts pane | FC §7.2 Shortcuts | settings §5.4 | `OpenSettings/ShortcutsPane.swift` | main | `settings-preview` (`shortcuts-callout`) | done | "Learn the Essential Shortcuts" is a callout button that opens the Essential window (Step 6, CC-29/CC-30); the list shows every active command. |
| Icon pane (Open's own icons) | FC §7.1 App Icon | settings | `OpenSettings/AppIconPane.swift` | main | `settings-preview` | done (partial) | Icon switching is not connected (`AppSettingsActions.swift:119`). |
| Advanced pane plus Ad Blocking and Tab Sleeping groups | FC §7.2 Advanced | settings §5.5 | `OpenSettings/AdvancedPane.swift` | main | `settings-preview` | done (partial) | Ad blocking and sleep save settings only (§1.3, §1.14). |
| Clear Browsing Data per profile with time range | FC §7.2 Profiles | settings | `OpenSettings` sheet and action | main | `settings-preview` | done (partial) | Only cookies + cache together, all time (§1.10). |
| Cmd+, opens Settings in the app | MH Arc menu | app-shell §4.11; settings adapter table (`docs/settings.md`) | — | main | none (code read) | done | Dispatched in Step C (`App/AppDelegate.swift` `settings`, #85). |
| Library window: Archive, Downloads, Captures, Media, History | FA §9.6 LB-1 | settings §6 (D-9) | presenter in `OpenSettings` (`LibraryPresenter`) | main | `settings-preview`; Step C (#85) | done (partial) | All sections open in the App, including Spaces (the real Space Manager, #124). Media still has no live source (§1.1). |
| Library folder sources (Documents, Desktop, Downloads folders, Screenshots) | FA LB-1 | deferred to v1.1 (settings D-9) | — | — | — | out of scope (lead decision) | |
| Account, Max, Staff panes | FC §7.1 | — | — | — | — | out of scope | |

### 1.19 First run

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| First-run window: Welcome → Import → Default browser | FC §3.7 r25 | first-run Steps A–B (#66); C–F left | `OpenSettings/FirstRun.swift` (preview screens) | none | 214 renders inspected; 32-flow receipt (`docs/first-run/`, #66) | planned | Spot-check: library only. PR #66 has no App change. Real-window checks are Step C entry criteria. |
| Import step with live counts and a separate consent step for secrets | — | first-run §5.4 | shared count probe with the Settings wizard (#66) | none | probe receipt (`docs/first-run/probe-checks.json`) | planned | Counts match the importer rules. No import runs yet. |
| Default browser step | — | first-run §3.5 | preview screen (#66); shared App `DefaultBrowserService` (routing Step 5) | first-run wiring pending | renders at 1x and 2x (#66); service state read by e2e `routing` | planned | The Settings action uses the shared service (§1.11). The first-run button can call that same service when its App wiring lands; its real system prompt is still user-only B2. |
| Re-running import adds no duplicates | — | first-run (criterion 7) | stable import IDs (`ArcImport.swift`) | — | verify-all `roundtrip`; model.md (idempotent archive re-import) | planned | |

### 1.20 Release

| Feature | RE | Plan | Library code | App wiring | Verified how | Status | Notes |
|---|---|---|---|---|---|---|---|
| Official engine build (ThinLTO, PGO) | — | fork-infra Step 10; release §2 | `Engine/fork/gn/release.args.gn` | — | — | planned | `engine-distrib --config release` is gated: CEF's `make_distrib.py` reads only `out/Release_GN_arm64` (`docs/followups.md`). |
| Bundle IDs `io.github.sergeserb2.open*` | — | release §4.1 (C-3), Step 4 | `project.yml` (`io.github.sergeserb2.open…`, #74) | — | Real Debug build and launch (#74) | done | Product names and CEF's own ID stay. |
| Developer ID signing, hardened runtime, entitlements | — | release §4; Steps 5–6 | entitlements match the plan (#76); metadata stamped (#79) | — | `plutil -lint` on 6 plists (#76); Release build (#79) | planned (partial) | Policy is done. Signing needs U-1, U-2 (§5.1). `tools/release.sh` alone applies Hardened Runtime (#79). |
| Notarization and DMG | — | release §3 | — | — | — | planned | Needs U-3. |
| Sparkle updates with an appcast on GitHub Pages | — | release §6; Step 7 | Sparkle pinned and copied in Release (#83); placeholder key (#79) | — | Release build copies Sparkle (#83) | planned (partial) | The feed location needs U-8. The key-match proof is still weak (`docs/followups.md`). |
| English-only locales | engine-patches P5 | release §2.7 | `tools/embed-cef.sh` (`OPEN_KEEP_LOCALES`); `tools/release-locales.txt` (#54, merged) | — | — | planned (partial) | The pipeline is on `main` (#57). A public release build still needs U-1…U-7. |
| License inventory and acknowledgements | `docs/followups.md` | release §7, Step 9 | `docs/release/licenses.md`, `tools/generate-acknowledgements.py` (#55, merged) | — | — | planned (partial) | Crate checksums joined P8 in #97. The review itself needs U-6. |
| Crash symbol archive (dSYMs kept on this Mac) | — | release §2.5 | — | — | — | planned | |
| `tools/release.sh --dry-run` | — | release §11, Step 11 | `tools/release.sh` (#57, merged) | — | Stamped dry run (#57, #79) | done | A real signed release still needs §5.1. |

## 2. Menu and hotkey coverage

### 2.1 Method

1. Arc's in-scope menu rows come from `expected-menu.json` (`inScope: true`; 149 rows today, including New Tab in two menus). Out-of-scope rows are the 11 rows it marks `inScope: false` (account, Notes, Easels, Arc Max, Dia, Privacy Policy, Restore Data).
2. "Registered" means a `CommandRegistry` command exists. The first audit ran `commands-dump` (`missing=0 extra=0 different=0 allowedMissing=11`, seed coverage 79/79). This refresh did not run it again. It read `CommandRegistry.swift` (173 command definitions) and `expected-menu.json` on `main`.
3. "Wired" means the menu item or key reaches dispatch on `main`. Sources: `AppCommand.implemented` and `AppCommand.featureIDs` (`App/MainMenu.swift`), `SystemCommandActions.selectors` (`OpenCommands/MenuBuilder.swift`), app-level cases in `App/AppDelegate.swift`, `go-to-*` prefix dispatch, and the OpenFeatures key path for split panes. A stub counts as wired here and is named (View Boosts, Check for Updates). Appendix A still shows the first audit; use §2.4 for today's missing list.
4. "Planned" means a merged plan names the work. "System" means a standard AppKit item. Since Step C (#85) system items keep their AppKit selector with target `nil`, so the old "no dispatch spec" class is closed.
5. A scratch script joined `expected-menu.json` titles to registry ids, then to the dispatch sets above (§6). Two titles use Open names in the registry ("New Little Open Window", "Open Little Open or Peek in…") and were matched by hand.

### 2.2 Numbers

Menu items (in-scope rows in `expected-menu.json`; duplicates keep their own row):

| Measure | Count | Notes |
|---|---:|---|
| Arc items in scope | 149 | Was 147. Reveal Tab in Sidebar and one further row joined the table. |
| Registered | 149 | Was 146. Every in-scope row now has a command. |
| Wired on `main` | 116 | Was 37. Includes 46 system items and stubs (Boosts, updates). |
| Not wired | 33 | List in §2.4. Almost all are now planned. |

Hotkeys. Menu keys come from the same rows (78 rows carry a key). Code-only keys stay 25 (MH guesses), split focus keys in OpenFeatures aside. Treat the code-only column as a read of Step C dispatch, not a fresh key press test.

| Measure | Menu keys | Code-only keys | Total |
|---|---:|---:|---:|
| Arc keys in scope | 78 | 25 | 103 |
| Registered | 78 | 25 | 103 |
| Bound on `main` | 71 | 25 (Cmd+1…9, Ctrl+1…9, split focus, global stub) | 96 |
| Unbound | 7 | 0 | 7 |

### 2.3 Gaps in the reference data

- Closed: `expected-menu.json` now has Tabs ▸ "Reveal Tab in Sidebar" (line 652) and the registry has `reveal-tab-in-sidebar` (`CommandRegistry.swift:184`). Step C maps it to `reveal-current-tab` (#85). Rerun `commands-dump` to confirm the counts; this refresh did not run it.
- Cmd+O documentation now matches the registry: “Open Little Open or Peek in…” (`open-in-current-space`). The 11 allowed-missing menu rows are unchanged.
- Gestures are not in the registry and not counted above: page swipe back/forward (#158/#162, SW1–SW4), Space swipe (done), sidebar edge swipe (planned, sidebar-completion), pinch zoom (not verified), Opt+Cmd-click Little Open (done; §1.9), Shift-click Peek (done), hold Cmd for shortcut hints (planned, #70), Cmd+Shift drag Capture (#154, C5/C6), double-click rename (done).
- New: Copy URL as Quote dispatches, but writes the Markdown form. `copy-url-quote` and `copy-url-markdown` write the same "[title](url)" text (`App/MainMenu.swift:141`). A quote needs the page selection. See §6.1.

### 2.4 Missing lists

Section 9 closes View ▸ Exit through the shared App handler; the prior list below remains historical. See the [Peek receipt](plans/s9-peek-receipt.md).

Historical menu audit before Section 8 (29: 30 after items 9–10 merged in #132, minus Show/Hide Toolbar, which dispatches since commandbar-completion Step 9, #144; the earlier `main` snapshot had 33). The plan column is in §1. "(UI elsewhere)" means another surface offers the action.

- File: New Incognito Window, Capture…, Capture Full Page, Capture in Portrait Mode, New Profile (UI elsewhere: Settings sheet), New Boost, Edit Boost, New Legacy Boost, Boost Gallery.
- View: Clear Cache and Refresh, Clear Cookies and Refresh, Cast…, Exit (Esc as a menu command), Appearance ▸ Automatic, Light, Dark, Developer ▸ Network Inspector, Toggle Developer Mode, Allow JavaScript from Apple Events.
- Spaces: Edit Theme….
- Tabs: Peek Email…, Join Meeting.
- Window: View Media opens the Library at its Media section (Arc `viewScreenshotsAndCaptures:`; Section 3, e2e `media` `media_view_media_menu`).
- Help ▸ Troubleshooting: Open Task Manager, Record Trace, Cancel Trace, Copy Open Info, Reveal Open Data (the last two work from Settings).

Items 9–10 merged to `main` in #132; Manage Spaces was already merged in #124:

| Entry | Dispatch and enablement | Real App evidence |
|---|---|---|
| Spaces ▸ Rename Space | Focused Space inline title editor; reveals a hidden sidebar; disabled without a browser window or during a sheet | `I10_rename_space_inline/undo`, `I10_rename_hidden_sidebar_reveals`, `I10_rename_cancel_unchanged` |
| Spaces ▸ Change Profile | Same Set Profile menu at the Space header; checked current Profile and existing selection intent; disabled without a browser window | `I10_change_profile_opens_set_profile`, `I10_change_profile_choice_dispatches/undo` |
| Spaces ▸ Manage Spaces… | Existing Library ▸ Spaces presenter, retained with no browser (existing design) | `I10_manage_spaces_menu`; existing E5 entry/reuse rows |
| Archive ▸ Clear Archive | Existing Library confirmation and stores; Cancel is inert; disabled without a browser window or during a sheet | `I10_clear_archive_library_confirmation/cancel/confirm` |

All four keep empty key equivalents, as recorded in `docs/re/menus-and-hotkeys.md` (Spaces and Archive) and `docs/commands.md`; `I10_menu_enablement_and_keys` checks them. `I10_no_browser_window_disables_commands` checks the three newly wired commands.

Items 9–10 verification before the `013cdb45` main merge (2026-10-28):

| Command / gate | Result |
|---|---|
| `heavy.sh tools/verify-all.sh --only features-render,sidebar-render,commands-demo,settings-preview` | PASS: build + 4 checks; 0 FAIL/SKIP. Commands 232/232, settings 37/37, sidebar 564/564, features 286/286. |
| `heavy.sh tools/build.sh` | PASS (Debug app, Swift 6). |
| Locked Chrome `--only sidebar-completion` | PASS 134/134 suite rows, including all 29 new items 9–10 rows. Engine fingerprint and owned-process cleanup also PASS. |
| Locked Chrome `--only app-actions` | PASS 47/47 feature rows + engine fingerprint + owned-process cleanup (49 total, same count as A3). |

The focused items 9–10 run also passes 31/31 (29 new rows plus provenance and cleanup). No owned windows or processes remain. Saved #132 receipts are in `.re/sidebar-intents-menus/`; generated `docs/engine-spike/` results are excluded from this change. The full paths for `heavy.sh` and the on-screen lock are the AGENTS.md commands.

Verification after merging `origin/main` at `013cdb45` (2026-10-28):

| Command / gate | Result |
|---|---|
| `heavy.sh tools/verify-all.sh --only features-render,sidebar-render,commands-demo,settings-preview` | PASS: build + 4 checks; 0 FAIL/SKIP. Commands 232/232, settings 37/37, sidebar 564/564, features 325/325, including main’s auto-archive flows. |
| `heavy.sh tools/build.sh` | PASS (Debug app). |
| Locked Chrome `--only sidebar-completion` | PASS 148/148 suite rows: A1/A2/Manager/A3, items 9–10, and E16/AA_APP. Engine fingerprint and owned-process cleanup also PASS. |
| Locked Chrome `--only app-actions` | PASS 47/47 feature rows plus fingerprint/cleanup (49 total). |

Both suites completed without foreground interruptions. The merge retains both parents’ e2e helpers and named assertions, with one definition per helper and automation handler. Combined receipts are in `.re/sidebar-intents-menus/merge-main/`. Generated `docs/engine-spike/` outputs are restored to the incoming main versions before the merge commit.

PR #132 final receipt: full verifier 21/22 PASS with the known Site Control editor FAIL; `sidebar-completion` 150/150 (including 31 I9/I10 rows), `app-actions` 49/49, and `sidebar` 21/21 PASS. The earlier scoped receipts above keep their original counts; #133 later fixes the verifier flake.

Sidebar intents merged in #128/#132: `moveToNewSpace` reuses A3’s atomic plain New Space helper (`I9_move_single_*`). `share` for pinned/Favorite tab URLs invokes `NSSharingServicePicker` at the row (`I9_share_system_picker`); automation cancels without choosing a service. Share Folder has no single-tab URL and remains refused; Share Space is disabled as out of scope. The factory still refuses `showSiteControls`, `changeSpaceIcon`, `editSpaceTheme`, `newProfile`, `editPinnedURL`, `changeIcon`, and `customizePage`, as assigned to other sections.

Items that left this list since the first audit: Copy URL as Quote (correct selection link since #163), Reset all tabs in this Space, Expand and Collapse All Folders, Reveal Tab in Sidebar, and every system item (29). Step C dispatched them (#85).

Menu keys with no dispatch (6; Show/Hide Toolbar Cmd+Shift+D dispatches since commandbar-completion Step 9): New Incognito Window Cmd+Shift+N, Capture Cmd+Shift+2, Exit Esc, Toggle Developer Mode Ctrl+D, Peek Email Cmd+Shift+E, Join Meeting Cmd+Ctrl+J. All are planned except Join Meeting, which needs a decision (§5.4).

PR #134 earlier tab-switcher / cold-command-bar receipt, based on main
`dee105e6` (2026-10-28; final PR receipt follows):

| Check | Result |
|---|---|
| Heavy verify: features-render, sidebar-render, commands-demo | PASS 335/335, 564/564, 232/232; 0 build warnings/errors. |
| Extra command-bar / suggestion checks | PASS 78/78 and 34/34; pending-Return assertions unchanged. |
| Heavy Debug App build | PASS. |
| Locked sidebar-completion | PASS 164/164 feature rows, 166 total with provenance/cleanup; includes E12, all TS and I9/I10 rows, E16/AA_APP. |
| Locked app-actions, 3 runs | PASS 48/48 feature rows, 50 total each; cold 3.35 / 3.42 / 3.28 ms at the unchanged 50 ms limit. |
| Whitespace / merge audit | PASS; one definition per automation command and Python helper; both parents' docs rows retained. |

All final on-screen runs had zero foreground interruptions and passed cleanup.
The extra app-actions row checks cold launch / Cmd+T switcher laziness. Opening the
bar applies ready local results before cold AppKit focus and a main-actor turn;
text edits keep pending-Return cancellation. Live main/branch comparisons and
phase/sample evidence are in `docs/re/sidebar-completion.md` §13. Receipts are in
`.re/tab-switcher-cold-open/final-*`; generated `docs/engine-spike` artifacts were
restored. TS-C1 visual/candidate-scope capture remains open.

Merged PR #134 modifier/auxiliary-window review receipt, based on main
`786b19ad` (2026-10-28): TS11–TS14 each FAIL on `d6eeb860` (335 pass, 4 fail),
then PASS with initiating event/modifiers, immediate bare-key switching and
active-only lifecycle cancellation. FULL verification is 22/22 PASS, including
features 372/372; Debug App build PASS; locked sidebar-completion 174/174 and
app-actions 50/50 PASS, cold 4.78 ms. Both e2e suites have zero interruptions
and successful cleanup. The merge retains stored favicons, all TS/FV/intents/
archive helpers exactly once, and both sets of docs rows. See
`docs/re/sidebar-completion.md` §13 PR #134 review and
`.re/tab-switcher-review/final-*` for the complete table and receipts.

## 3. Gaps, ranked

Ranking is by user impact for an Arc user who switches to Open. **P0** blocks daily use. **P1** is noticeable. **P2** is polish. Numbers keep the first audit's order. A gap marked **closed** stays here with its PR. An open gap names its plan today; many gaps that were unplanned now have one.

### 3.1 P0

1. **Open — Open's own password manager.** Save and fill prompts, Manage Passwords, cards and addresses. Now planned: `docs/plans/passwords-autofill.md` (#72) uses Chromium's built-in manager with Arc's UI (RE PW-1…PW-12). No code yet. Settings opens `chrome://settings/passwords` in a hosted tab. Keep as P0 until save and fill work in the App.
2. **Open — write imported Arc passwords, cookies, cards, and addresses into Open.** Without it, every switcher is logged out of every site. Now planned in the same plan (#72, engine write path). Readers and decryption exist (`OpenImport/ArcSecrets.swift`, synthetic fixtures). The App still reports `canImportPasswordsAndCookies == false` and imports nothing. Keep as P0.
3. **Closed in PR #85 — system menu items keep their handler.** `MenuBuilder` gives system items their AppKit selector with target `nil` (`OpenCommands/MenuBuilder.swift:125`, 46 ids in `SystemCommandActions`). The App forwards the same ids (`App/MainMenu.swift:79`). Copy, Paste, Quit, Spelling, and Speech keep the responder chain.

### 3.2 P1

4. **Closed in #130 — Today auto-archive runs in the App.** Sidebar item 6 composes `TodayAutoArchiveController` with one reusable `ExpirySweeper`. Launch and workspace wake use the same sweep path as the one-shot deadline timer. Observation re-arms for activity, ancestry, window selection/visibility, Settings, and undo. The sweep and deadline share the model’s shown-tab rule. One cached shown-tab snapshot in the model stamps activity at its shared mutation commit path, including split separation/dissolution, tab or ancestor moves, archive/delete, window changes, and undo/redo, with no extra undo step. Retained closed-window state is transiently marked as not showing content. Real-App E16/AA_APP and SQLite readback passed on 2026-10-28 (`.re/structural-visibility/sidebar-completion.json`, 121/121); AA1–AA12 and AA-visible checks, including eight structural/undo flows, passed in `features-render` (325/325 total; `.re/structural-visibility/features-render.log`). Idle with all Profiles at Never: running, no timer/deadline, sweep count 3 → 3, all five reported process tasks 0% CPU over a one-second sample. The implementation is merged in #130. These are saved PR receipts; final-main soak and release acceptance remain separate.
5. **Closed in #156** — sleep keep-alive site list. `OpenSleep/KeepAliveRules.swift` and the App controller protect matched sites (`sleep_keep_alive`). Notification protection passes `sleep_n5_notifications`; native delivery remains U-N1 (#160).
6. **Closed behavior in PR #75, #81, #91, and #128 — multi-select in the sidebar.** Shift/Cmd-click, New Folder from Selection, bulk archive, move, pin, duplicate, and drag work in the App sidebar. Evidence: `sidebar-render` selection flows, `commands-demo` B-checks, and merged A3 (#128) real-App E1–E4 (menu/key selection dispatch, native input, engine flags, and one undo). Capture C1 remains open for visual calibration; OS drag-session hit testing remains unproven.
7. **Closed in PR #124 — reorder Spaces (Space Manager).** The App injects the real Space Manager into Library ▸ Spaces: one model, live browser intent routes, native Library undo and context replacement ([review receipt](engine-spike/space-manager-review-r1.md)). Capture C2 is still requested for a pixel comparison. Bottom-switcher reorder stays out (lead Q5).
8. **Behavior merged in #152** — page translation. `App/Page/TranslateAdapter.swift` and `OpenTranslate` pass X1–X6 on the fixture backend, R-X1 and S-US1. Step 19 isolated world and X1 Apple backend assets remain open.
9. **Behavior merged in #158/#162** — page swipe and indicator. `EngineWebContentHostFactory.swift`, `SwipeIndicatorView.swift`; SW1–SW4 and R-W1 pass. U-S1 real gestures and the swipe interim follow-up remain open.
10. **Closed in PR #126 — Delete Space confirmation.** System sheet with Arc's copy; Cancel changes nothing; Delete archives with one undo step. Capture C3 remains open for Arc's alert/Return behavior.
11. **Closed in PR #126 — Delete folder confirmation.** One alert for one or several folders, then "Folder deleted" / "Folders deleted" with Undo. Capture C3 remains open.
12. **Partly closed in #156/#158/#160** — web notifications. `NotificationAuthorization.swift`, `NotificationClicks.swift`, `open_notifications.cc`: N1 engine display/list, N2 Alerts helper/list, N3 activation/click, N4 fallback and N6 engine display pass; N5 sleep permission gate passes. `N1_macos_delivered` (U-N1) and `N6_click_opens_tab` (P1 clients.openWindow) remain BLOCKED.

### 3.3 P2

13. **Behavior merged in #154/#153** — Capture. `OpenFeatures/Capture/`, `App/Page/CaptureCommands.swift`, `CaptureLibraryWriter.swift`; R-C1–R-C3 and C1–C6 including 2x emulation pass. ToastCenter is wired. C7 incognito and visual captures C-C1/C-C2 remain open.
14. **Closed in #163** — Copy URL as Quote and Share Quote. `App/Page/PageCommands.swift` and `TranslateAdapter.swift`; e2e `page` Q1–Q5 and EP3 pass on #158 selection APIs.
15. **Closed in #153/#163** — Copy URL toast. `OpenFeatures/Toasts/` and `App/Page/PageCommands.swift`; R-T1–R-T7, T-E1/T-E2 pass, including Share hold.
16. **Closed in #163** — zoom toast. `App/Page/PageCommands.swift`; Z1/Z2/Z4 pass. EP-5 needs no new engine code; resetZoom already resets pinch scale.
17. **Closed in PR #85 — Expand / Collapse All Folders; Reset all tabs in this Space.** Both dispatch in the App (`App/MainMenu.swift:151`, `:157`). Nested reconcile in #95. Merged A3 (#128) E9 verifies recursive enablement and live folder/split resets, with Favorites and other Spaces excluded.
18. **Space export closed in #124/#128; folder → Space closed in #132.** Browser Export and Manager Turn into Folder use the real model fallback. Merged A3 (#128) E10 verifies exact ordered IDs and one undo. `turnFolderIntoSpace` keeps the owning Profile and moves ordered children into Today with one undo (`I9_turn_folder_*`). The future New Space form remains in the Space/theme lane.
19. **Behavior closed in #127; capture C4 remains open — Hover Previews.** Tracker, folder card, and switches merged (#80, #102). **A2 (2026-10-28): the App opens the preview panel** for folders, pinned tabs and Favorites, with live pages through the Peek host (sidebar-completion §3.6; E11–E14). Lead decision: two Previews sources ("Folders", "Pinned tabs and Favorites"); Arc's live-data sources are post-v1; no delay setting (fixed 0.5 s, an Open choice; one Arc sample ≈ 0.42 s, V 46.11–46.46 s; Step S5b, merged #123). Banner trigger merged in #130; C4/calibration C remain open.
20. **Closed in PR #78 — Tidy titles.** Open-written rules drive `displayTitle` in rows, search, and the Library. Rename keeps the raw title.
21. **Closed in PR #95 — Unread badge.** Unread tabs and collapsed folders draw a dot in the App sidebar. Inputs in #75; engine background-open trigger merged in #127. Capture C5 remains open.
22. **Closed — Inline autocomplete.** Built in commandbar-completion Steps 1–2 (Section 2): engine rule T3a and `inlineCompletion`, the field's completion and its keys, checked by `suggest-check`, `commandbar-render` flows and budget, the F0043/F0062/F0061/S2 18/0009 compares, and e2e `commandbar`.
23. **Closed — One command-bar row per Split View.** Built in commandbar-completion Steps 3–4 (Section 2).
24. **Closed — Browser-actions-only scope.** Built in commandbar-completion Step 5 (Section 2).
25. **Closed — Hold-Cmd hints and the Essential Keyboard Shortcuts window.** **S2 (2026-10-26): closed for hints** (Arc shows none, CC-39; lead decision: Open builds none; out of scope in §1.7). The window is built (commandbar-completion Step 6, Section 2); the (i) button opens the privacy footer, not this window (CC-42).
26. **Closed — Optional toolbar.** commandbar-completion Step 8 (#143: 32 pt bar on the split pane bar, sidebar hiding, menu titles, snapshot field) and Step 9 (App wiring, e2e `toolbar`). The sidebar layout with the toolbar is a guess until a capture exists (plan §9 item 1).
27. **Closed in #158/#164** — Website appearance. `App/Page/WebsiteAppearance.swift` and fork 0505; A1/A2 pass on both styles and after navigation.
28. **Partly closed in #164** — Clear Cookies and Refresh. `App/Page/PageToolsCommands.swift`; K1/K2 pass. Per-site cache clearing stays disabled until Site Control E2.
29. **Behavior merged in #164** — Developer extras and Troubleshooting. `App/Page/{PageToolsCommands,DeveloperMode,TroubleshootingActions}.swift`; D1–D4 and H2–H4 pass. D4 self-scripting passes with App hosting (#174, e2e `applescript` and `page`); external osascript consent and H1 Alloy remain BLOCKED.
30. **Closed for v1 in #164** — Cast stays hidden and cannot run. `App/Page/PageToolsCommands.swift`, `OEApp.mm`; H4 passes.
31. **Behavior closed in #126/#127/#128/#130 — Separate, Clear, banner, hint.** Separate From Pinned Tab (#75, #95, #127 host reuse), Clear keeping selection (#75, #91, #128 App proof), the banner (#102 view, #130 App trigger), and the first-hide hint (#126, shows on the first hide by any path, C17). Capture C6/C7/C8 calibration remains open. Every Clear shows "Cleared Tabs" with Undo (#126).
32. **Closed for v1 (#99, #126) — Haptics done; sounds wired, off.** The App resolves Open's own sound resources and `SoundEffects.play` respects `open.advanced.playSoundEffects` (off; e2e `A1_sound_effect_gated_off`). No event plays the general sound until capture C9 (lead Q6).
33. **Open — Change Icon… for folders and pinned tabs.** Planned with the shared picker (space-theme-editor Steps 5–8). The App refuses the intent.
34. **Closed in PR #77/#128 — Archive a whole folder and restore it as a folder.** One folder record, nested restore in the App Library; merged A3 E18 proves restore/relaunch with original IDs.
35. **Open (deferred) — Little Open downloads tray.** Still deferred by routing §0.2.
36. **Closed in PR #126 — Hide the sidebar with the gesture.** The 164 pt floor, compact toolbar and hint trigger merged in A1 (#126); #129 rechecks native width/hide/reset and the springs. The gesture is the resize drag past 164 pt. C10 is complete for the broad flow; refinement `drag-hide-threshold` and C11 compact-menu contents remain open. Lost mouse-up and gesture Undo stay in section 5 follow-ups.
37. **Closed — Extension shortcuts; omnibox keywords.** extensions-ui §6.3 and §3.14 are implemented in [#179](https://github.com/SergeSerb2/open/pull/179), [#184](https://github.com/SergeSerb2/open/pull/184), [#189](https://github.com/SergeSerb2/open/pull/189) and the [X-27 closeout](https://github.com/SergeSerb2/open/pull/190). `settings-preview`, real-App `extensions-ui X27_*` and `extensions-e2 X22–X26` prove both. Global OS shortcut delivery remains a separate unverified gate (§1.16).
38. **Open (blocked) — Import Arc Boosts.** No sample file exists on this Mac. Belongs in `OpenImport`.
39. **Post-v1 — Join Meeting and Meet link toast.** Meet toast stays deferred. Join Meeting needs calendar live data (lead decision S2).
40. **Open — Auto-disable an extension ad blocker on allow-listed sites.** No plan. Arc's reason is unknown.
41. **Closed in PR #85 — Reveal Tab in Sidebar.** In the registry, in `expected-menu.json`, and dispatched.



### 3.4 Top 10

| Rank | Gap | Priority |
|---:|---|---|
| 1 | Open's own password manager (save, fill, manage) — planned in #72 | P0 |
| 2 | Writing imported Arc passwords and cookies into Open — planned in #72 | P0 |
| 3 | System menu dispatch — closed in #85 | P0 (done) |
| 4 | Today auto-archive — merged in #130 | P1 (done) |
| 5 | Sleep keep-alive list — closed in #65/#156 | closed |
| 6 | Multi-select behavior — closed in #75, #81, #91, #128; C1 pending | P1 (done) |
| 7 | Reorder Spaces (Space Manager) — closed in #124 | P1 (done) |
| 8 | Page translation — #152 merged; Step 19 and U-X1 remain open | P1 |
| 9 | Page swipe — #158/#162 merged; U-S1 remains open | P1 |
| 10 | Delete Space confirmation — closed in #126 | P1 (done) |

## 4. Performance budget status

Budgets from `docs/architecture.md` (release build, M5 Pro, idle machine). The first audit ran on a loaded machine, so its values are upper bounds. This refresh adds values from PR bodies and `docs/app-shell.md`. Earlier refreshes ran no new timing. Section 8 speed-gate and Idle CPU measurements below were collected on 2026-11-05.

| Budget | Target | Latest measured value | Where | Source file | Verdict |
|---|---|---|---|---|---|
| Cold launch to sidebar drawn | ≤ 250 ms | Real window: fresh 261 ms, warm 253 ms (medians of 5, presented frame) | main (Step B, #52) | `docs/app-shell.md`; `docs/engine-spike/results-window-release.json` | FAIL by 3–11 ms |
| | | Step A: fresh 224 ms, warm 242 ms | #45 (in main) | `docs/app-shell.md` | PASS (Step A only) |
| | | Step C (#85): two Release sidebar launch-budget FAIL load exceptions, kept for Step I. No new median in the PR body. | main (Step C) | PR #85 body | FAIL (load exception; no new median) |
| Intermediate marks `main` ≤ 50 ms, `modelLoaded` ≤ 120 ms (app-shell §5.1) | — | Step A: `main` 113/135 ms, `modelLoaded` 115/137 ms (fresh/warm). Step B: `main` 152/146 ms, `modelLoaded` 154/148 ms | #45, #52 | `docs/app-shell.md` | FAIL |
| Cold launch to first web paint (restored tab) | ≤ 700 ms | Step B: fresh 521 ms, warm 493 ms. Step A: fresh 461 ms, warm 452 ms. Hosted Chrome-style tabs: 454 ms (#53) | main | `docs/app-shell.md`; `docs/engine-patches.md` P1 status | PASS (median); fresh outliers at 1,798 ms (Step A) and 2,237 ms (Step B) |
| Tab switch to content visible (live tab) | ≤ 16 ms | Real App single→single / single→split p95 7.774 / 10.060 ms; main 7.652 / 14.736 ms. Three interleaved pairs, 40 samples/path/run; every-pane first rAF and native layout/CA flush return combine by max. | `s9/split-app`, main `ffcf4649`, engine `3f45b07b` | `docs/split-app.md`; `docs/split-app-timings.json` (all samples and loads) | Approved relative/25 ms gate PASS; 16 ms target NOT MET consistently across standalone runs. Physical presentation remains unproved; P1 follow-up stays open. |
| Sidebar scroll and drag at 120 fps | 8.33 ms per frame | First audit: scroll p95 3.67 ms; moveNode p95 4.84 ms (1,000 rows, offscreen). Later: 50-row bulk guards at p95 2.65/1.99 ms (S5, #102); mini-player pairs at p95 about 2.5 ms (#92). S8 current-display A/B: median of 20 per-run p95 values 5.605 → 4.680 ms (−16.50%, faster but outside ±10%; full load records in `docs/s8-speed-gates.md`) | harness | `sidebar-render bench`; PR #92 and #102 bodies; `docs/s8-speed-gates.md` | PASS (harness only). MC9 mean rose 0.463 ms past its 0.3 ms rule and merged as a lead load exception (#92). |
| Toast and history-swipe idle work | Zero timers/links/animations, draw/layout/display/invalidation and new queue work | Idle flow 19/19 PASS; seven real faults yield 66 idle FAIL lines, then clean 19/19 PASS. Each sample prints its elapsed time and load. | `s8/speed-gates` | `tools/verification/features-idle.py`; `docs/s8-speed-gates.md` | PASS (offscreen native flow; existing fake web host; no whole-App CPU claim) |
| Command-bar keystroke / inline completion | CPU p95 <8 ms; completion added p95 ≤0.3 ms; max 1 layout pass | A: CPU 8.25 ms FAIL, completion +0.248 ms PASS; B: CPU 3.91 ms PASS, completion +0.040 ms PASS. Max 1 layout pass; suggest-check 47/47 both. All values collected today on built-in 2x; full 1/5/15-minute loads in the report. | pre-#153 A vs post-UI B, engine f34400e7 for App builds | `docs/s8-speed-gates.md` | Existing limits unchanged; baseline CPU failure retained; current passes |
| Idle CPU (no media) | ≈ 0 % | Release/f34400e7, matched built-in 2x main: blank 0.1225 → 0.5925 %; ten tabs (nine live pages) 4.2384 → 3.8613 % of one core, settled 60 s OS samples. Frozen-tab passes 24 → 1 across two CPU windows. | s8/idle-cpu; measured on 03a0d5cb, final G2 merge 18c14f33 built | `docs/idle-cpu.md`; `docs/engine-spike/idle-cpu-matched-2026-11-05.json` (all load averages and PIDs) | target not met with ten pages; blank now measured; page JS/GPU work remains. Single-run totals do not establish a causal CPU saving; final regression deferred by user. |
| Command bar open to first results | ≤ 50 ms | Library first-audit snapshot p95 0.570 ms, keystroke-to-rows wall p95 4.49 ms, history snapshot p95 16.2 ms. PR #134 App Debug cold opens: 3.35, 3.42, 3.28 ms (median 3.35), three app-actions runs; final PR run 4.78 ms, unchanged entry-to-first-view-application scope; excludes frame presentation.  S8 current-display Release cold samples: 4.729 → 4.922 ms (A load 10.03/6.77/6.71; B load 10.27/6.88/6.75); same entry-to-snapshot scope; `docs/s8-speed-gates.md`. Live pre-fix comparison: main `dee105e6` 21.81 ms, branch 33.59 ms. | library; merged #134 (saved App Debug receipts) | `docs/re/sidebar-completion.md` §13 evening investigation; `.re/tab-switcher-cold-open/final-app-actions-{1,2,3}-results.json` | PASS (library and PR #134 App Debug; no Release/frame-presentation claim) |

No budget, for the record: ad-block matching runs 5.5 µs per real ad-tech URL check, 6.0 µs in the tree (#97). Sleep pass CPU p95 is 0.548 ms at 5,000 tabs (#65). Memory has no budget. Latest named values stay 225–239 MB for 1 page and 947–1,210 MB for 10 pages (`results-measure-*.json`).

## 5. Items that need the user

### 5.1 Accounts, money, and approvals (release §10)

| # | Item | Blocks |
|---|---|---|
| U-1 | Apple Developer Program membership ($99/year) | Signing, notarization |
| U-2 | Developer ID Application certificate in the login Keychain | Signing |
| U-3 | Notary credentials (app-specific password, `store-credentials "open-notary"`) | Notarization |
| U-4 | Approve the Sparkle key generation and keep the private key backup | Update signing |
| U-5 | Enable GitHub Pages for `SergeSerb2/open` (`gh-pages` branch) | Update feed |
| U-6 | Confirm the license, patent and security review (MPL-2.0 adblock-rust, GPL-3.0 uBO resources, H.264/AAC, Chromium/CEF; the adblock, regex and aho-corasick crate review in docs/engine-patches.md "Security review"). Fuzz the list parsers before release (`docs/followups.md`). | First public release |
| U-7 | Approve each public release (tag, `gh release create`) | Each release |
| U-8 | Choose the public update feed location. Step 6 ships an inert placeholder key and no real feed (#79). | Sparkle updates |

### 5.2 Arc sessions only the user can run

Agents must not launch or drive Arc (AGENTS.md rules 4–5). These need the user to use Arc while the recorder runs (`docs/re/runtime-observations.md` §7 gives the steps and labels).

Capture session 2 ran on 2026-10-26 and is committed as findings only (#106; routing in `docs/re/capture-session-2-results.md`). It answered much of this table: window chrome, sidebar limits (minimum 164 pt), the reveal card, Favorites, Site Control Center, Boost editor and Zap, media, theme editor and New Space, command bar motion, Little Arc, macOS Light, and sidebar motion. Plans now cite those facts (#107, #108, #109). Keep this table for what session 2 did not settle. Open items: the Sparkle twinkle timing in Site Control (needs video at 30 fps or more, `docs/followups.md`), paused and muted mini-player states (#109 §13.7), live-window ring color refits (#104), and the file-schema and AppleScript rows below.

| What | Why | Source |
|---|---|---|
| 60 fps video of Space switch, folder expand, Peek open, command bar open, sidebar hide | Motion tokens are provisional | IS §19 item 1; DT §9 item 6. S2 (2026-10-26): done except Peek (IS §20.12; app-shell §3.3) |
| Active-window traffic lights and glyphs | Active state never captured | IS §19 item 2; RO §7 #1 |
| Sidebar minimum width (slow drag) | 180 pt hide threshold is a guess | IS §19 item 3; app-shell Q3. S2 (2026-10-26): done: minimum 164, maximum 500 (IS §20.1) |
| Little Arc window (Cmd+Opt+N), Library (Home button), Site Control Center popover | No capture of these surfaces | IS §19 item 4; RO §7 #11, #18, #19. S2 (2026-10-26): Little Arc done (IS §20.10, routing §9.3); Site Control Center captured (IS §20.5); Library still open |
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
| Folders as `chrome.tabGroups` | Decided in #64: v1 has no tab groups. Folder tabs stay pinned with `groupId: -1`. | `docs/re/arccore-engine.md` §4.3.1; engine-patches P1 |
| Do Boosts apply in incognito, Peek, Little Open, and Split panes? | Apply everywhere | boosts-zap Q4 ("Product to confirm") |
| Keep Safe Browsing on? | Not decided | engine-patches P5 ("Keep Safe Browsing as a product decision") |
| Pinned tabs sleep like other tabs (Chrome protects them) | Sleep; say so in Settings | memory-design §5 |
| Tab-sleep mode names in Settings | Designer names later | memory-fork lead decision |
| Is Join Meeting (calendar) in v1? | Post-v1; needs calendar live data (lead decision S2) | §1.17 |
| Is Peek Email in v1? | Saved known-webmail Favorite/pinned tab in the window’s Profile; S11 lead decision | §1.9 |
| Password manager approach | Decided in #72: Chromium's built-in manager in the fork, with Arc's UI | `docs/plans/passwords-autofill.md` |
| Library filesystem sources | Deferred to v1.1 | settings D-9 (decided) |
| Widevine | Out of v1 | fork-infra lead decision (decided) |

Design reviews of Settings, the first-run screens, and the Links pane belong to the lead and an Opus designer, not the user (settings lead decision; first-run criterion 10; routing §0.2).

## 6. Evidence

### 6.0 First audit (2026-10-25)

The audit started on `42bba0b`. PR #51 merged during the audit, so the branch was fast-forwarded to `dc62e65` and the checks marked "both" ran again. PRs #54, #55, #56, and #59 merged next; `tools/verify-all.sh` ran again on the final merge. No unit tests, no Arc launch, no desktop input, and no Arc user data were used.

| Command | Tree | Result |
|---|---|---|
| `cd Packages/OpenKit && nice -n 10 swift build -c release -j 6` | both | Build complete |
| `.build/release/commands-dump` | both | exit 0: `missing=0 extra=0 different=0 allowedMissing=11`; suggest actions 89; seed coverage 79/79; global hotkey registers and unregisters |
| `.build/release/sidebar-render check` | both | 125 passed, 0 failed |
| `.build/release/features-render check` | both | 147 passed, 0 failed |
| `.build/release/commandbar-render check` | both | 78/78 passed |
| `.build/release/settings-preview check` (inside verify-all) | `dc62e65` | 28 checks passed, 0 failed |
| `.build/release/sidebar-render bench --rows 1000` | `42bba0b` | scroll p95 3.67 ms; moveNode p95 4.84 ms; Space switch 7.6–14.8 ms (load 8.5) |
| `tools/verify-all.sh` | all | 14–15 PASS on each merge; final merge with `f41955c`: 15 PASS; no SKIP |
| Coverage join (§2) with a fresh `commands-dump --markdown` | both | Same counts on both trees |
| `git grep` for library types in `App/` | both | No App use of the Step C…H types at that time |
| Diff of the MH menu tables against `expected-menu.json` | both | 1 Arc item missing (Reveal Tab in Sidebar); 2 extra standard macOS items |

### 6.0.1 Refresh (2026-10-26)

This refresh ran no builds and no `verify-all`. It used merged PR bodies, merged plans, `docs/followups.md`, and code reads on `main` at `94ffd62`. Spot-checks opened the App files below. "Library only" means no App path was found.

| Check | How | Result |
|---|---|---|
| Command bar in the App | Read `App/CommandBar/AppCommandBarDelegate.swift` | Builds `CommandBarController` per window (line 34). Wired (#85). |
| Menus and system dispatch | Read `App/MainMenu.swift`; `OpenCommands/MenuBuilder.swift:125` | Registry menu; 76 App ids; system items keep AppKit selectors. Wired (#85). |
| Settings and Library in the App | Read `App/Settings/AppSettingsActions.swift` | Presenters own the App windows. Stubs: import run, updates, Boosts, icon switch, ad-block on. |
| Reveal Tab in Sidebar | Grep registry and `expected-menu.json` | `reveal-tab-in-sidebar` at registry line 184 and table line 652. Closed. |
| Today auto-archive | `App/AutoArchive/`, AA1–AA12/AA-visible, and E16/AA_APP real-App proof (2026-10-28) | Merged in #130 with saved real-App proof; one deadline timer, launch/wake, real SQLite, banner actions and dismissal; shown tabs are protected and their deadline starts at final deselection. |
| Sleep | Grep `SleepController` in `App/` | `App/Sleep/AppSleepCoordinator.swift` (#156 + #165, fork API; e2e sleep F0/F2/F4/F5). |
| Boosts and routing | Grep `BoostStore`, `RoutingEvaluator`, `ScriptHost` in `App/` | No hits. Library only. The Link pane shows; intake does not run. |
| History and favicons | Read `App/Stores/AppStores.swift`, `EngineWebContentHost.swift`, `StoredFaviconCache.swift` | Merged #131 favicon follow-up (2026-10-28): history still records typed visits only. Engine favicon reports now persist off the main actor; shared sidebar/Favorite rows use a bounded decoded cache, and the Library reads the same store. |
| Space editor | Grep `OpenSpaceEditor` in `App/` and `project.yml`; read factory line 366 | Not linked. `editSpaceTheme` and `changeSpaceIcon` return `false`. Library only. |
| Space Manager | Read merged #124 `AppSettingsActions.makeSpaceManagerView`; real `sidebar-completion` flow | App injection and Manage Spaces routes on `main` (#124). |
| Hover previews | PR #123 fixed delay; #127 `HoverPreviewController` and real-App E11–E14 | Merged: live page/folder panel and host return/rekey. Capture C4/calibration C remain open. |
| Mini player and PiP | Grep `SidebarContext.media` set; PR #92, #101 bodies | Closed by Section 3 Steps 5–6: `MediaCoordinator.attach` sets `media`; cards and auto-PiP run in the App (e2e `media`). Open's own phase-2 PiP window is still harness-fed until Step 10. |
| Sounds | PR #126 App resource resolver and `A1_sound_effect_gated_off` | Merged: setting stays off, no general-event caller until capture C9. |
| Little Open | `App/LittleOpen`, e2e `littleopen` | Real Chrome tabs in standalone windows and App entry points are wired; see §1.9. `StandalonePageSurface` provides visibility and capsule/content anchors (`littleopen_surface_hook`); Section 11 adds JS sheets, beforeunload close/quit and in-window permission cards, covered by real-App `page-chrome` `little_*` and negative proofs ([receipt](engine-spike/s11-littleopen-pagechrome.md)). |
| Duplicate | Read `BrowserModel.swift:551`; factory line 364 | `duplicateNode` exists and the App calls it. Wired. |
| Folder restore | Read `AppSettingsActions.swift:34`; PR #77 | The Library gets real archive stores. Wired. |
| Menu join (§2) | Script over `expected-menu.json`, registry titles, dispatch sets | 149 rows, 116 wired, 33 not wired; 7 menu keys open. |
| Open PRs at the end | `gh pr list --state open` | #69, #93, #94, #96, #98, #100, #103, #112. #108 and #110 merged during the refresh. |

Merged PR bodies used for §4 and the step claims: #63–#68, #74–#102, #104, #105, #107, #109, #111, #113–#118 (`gh pr view`, 2026-10-26).

### 6.1 Doc and code drift found

First audit:

- `docs/commands.md` command table: Cmd+O now matches “Open Little Open or Peek in…” (S11).
- `docs/architecture.md` module list puts Boosts, Zap, Site Control Center, ad blocking, and Air Traffic Control in `OpenFeatures`. They live in `OpenBoosts`, `OpenAdBlock`, and `OpenRouting`. Not rechecked line by line in this refresh.
- Before #51, `main` defaulted new profiles to DuckDuckGo. #51 fixed it.
- app-shell §4.3 listed no system ids. Fixed in code by #85; fix the plan text or mark it historical.
- Closed in #153: `OpenFeatures/Toasts/` replaces the old bottom toast; R-T1–R-T7 cover placement, lifetimes and motion.

Found in this refresh:

- `docs/plans/app-shell.md` Status line still says "Steps C–I remain planned". Step C merged in #85. Update the line to Steps A–C done.
- Closed in #163: `App/Page/PageCommands.swift` implements Copy URL as Quote with the engine selection and text-fragment link; Markdown has its own path.
- Fixed in commandbar-completion Step 6: `OpenSettings/ShortcutsPane.swift` draws "Learn the Essential Shortcuts" as Arc's callout button that opens the Essential window (RE CC-29).
- Closed in Section 2 item 12 (#146): Copy URL (`copy-url`, the sidebar copy button, the pane-bar and toolbar copy button) removes trackers by Arc's decoded rule (RE CC-31a, `OpenModel/TrackerStripping.swift`) and shows Arc's toast for each case. Copy as Markdown and Copy as Quote now clean URLs in `App/Page/PageCommands.swift` (#163). Copy Link of sidebar rows and Share remain separate; Arc runs the same cleaner in five more places (not traced; `docs/followups.md`).
- `SuggestEngine` hides the current tab in every mode. `docs/suggest.md` limits that to edit mode, and Arc lists the tab in Cmd+T (#70 Step 1). Check `TabsProvider` before the commandbar-completion steps land.
- Sidebar motion was corrected in #122 and verified in the 2026-10-28 [re-check](sidebar-completion/recheck-122.md): Cmd+S response 0.10 s and Space response 0.20 s. The command bar no longer animates (commandbar-completion Step 0, #137), as in Arc (CC-44).
- The reveal card is opaque in Open and translucent in Arc. The default dark theme has no inactive variant in Open. Both are in `docs/followups.md` with fits.
- Verify gates are not portable yet: four checks fail on the M1 for machine reasons (`docs/followups.md`, "Verification (portability)"). Status words in this file do not claim an M1 gate pass.

## Appendix A. Every in-scope Arc menu item (first audit)

This appendix is the first audit's table. It is history. Section 8 current dispatch and verification are in §1.3, §1.7 and §1.17 (#153/#154/#156/#158/#160/#162/#163/#164). Today's counts and missing list are in §2.2 and §2.4. `main` and `PR #52`: Y = works like Arc, P = partial, — = not wired.

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
| File | Capture… | Cmd+Shift+2 | `capture-page` | — | — | page-platform Step 13 |
| File | Capture Full Page | — | `capture-full-page` | — | — | page-platform Step 13 |
| File | Capture in Portrait Mode | — | `capture-portrait` | — | — | page-platform Step 13 |
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
| View | Show/Hide Toolbar | Cmd+Shift+D | `toggle-toolbar` | Y | — | commandbar-completion §4.6 (Steps 8–9, #143) |
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
| View | Exit | Esc | `exit-modal` | Y (s9) | — | `s9/peek-app`: key standard window; Find keeps Esc first, then top Peek (Undo) → maximized split restore → disabled. e2e menu priority, App Esc and plain Esc to page; negative proof in [receipt](plans/s9-peek-receipt.md). |
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
| Spaces | Manage Spaces… | — | `manage-spaces` | Y | Y | merged #124; App Library Spaces; capture C2 pending |
| Spaces | Rename Space | — | `rename-space` | main (#132) | `I10_rename_*` | sidebar inline rename |
| Spaces | Edit Theme… | — | `edit-theme` | — | — | none (theme editor plan in progress) |
| Spaces | Change Profile | — | `change-profile` | main (#132) | `I10_change_profile_*` | existing Set Profile menu |
| Tabs | New Tab… | Cmd+T | `new-tab` | P | P | app-shell §4.3 |
| Tabs | Pin/Unpin Tab | Cmd+D | `pin-unpin-tab` | Y | Y | app-shell §4.3 |
| Tabs | Duplicate | — | `duplicate-tab` | Y | Y | merged #128 A3 E3; selection-aware |
| Tabs | Rename Current Item | — | `rename-tab` | — | — | app-shell §4.3 |
| Tabs | Reset Tab to Original URL | — | `reset-tab` | — | — | app-shell §4.3 |
| Tabs | Reset all tabs in this Space | — | `reset-all-tabs-in-space` | Y | Y | merged #128 A3 E9 live pages |
| Tabs | Next Tab | Cmd+Opt+Down | `next-tab` | Y | Y | app-shell §4.3 |
| Tabs | Previous Tab | Cmd+Opt+Up | `previous-tab` | Y | Y | app-shell §4.3 |
| Tabs | Cycle Tab Forward | Cmd+Ctrl+Right | `cycle-tab-forward` | — | — | app-shell §4.3 |
| Tabs | Cycle Tab Backward | Cmd+Ctrl+Left | `cycle-tab-backward` | — | — | app-shell §4.3 |
| Tabs | Tab Switcher (forward) | Ctrl+Tab | `tab-switcher-forward` | Y | Y | merged #134; TS-C1 pending |
| Tabs | Tab Switcher (backward) | Ctrl+Shift+Tab | `tab-switcher-backward` | Y | Y | merged #134; TS-C1 pending |
| Tabs | New Folder… | Cmd+Shift+N | `new-folder` | Y | Y | merged #128 A3 E2; sidebar selection only outside text editing |
| Tabs | Expand All Folders | — | `expand-all-folders` | Y | Y | merged #128 A3 E9 recursive enablement |
| Tabs | Collapse All Folders | — | `collapse-all-folders` | Y | Y | merged #128 A3 E9 recursive enablement |
| Tabs | Clear Unpinned Tabs | Cmd+Shift+K | `clear-unpinned-tabs` | — | — | app-shell §4.3 |
| Tabs | Peek Email… | Cmd+Shift+E | `peek-email` | — | — | app-shell §4.3 |
| Tabs | Join Meeting | Cmd+Ctrl+J | `join-meeting` | — | — | none |
| Tabs | Open Little Arc or Peek in… | Cmd+O | `open-in-current-space` | — | P | app-shell §4.3, OpenFeatures |
| Tabs | Reveal Tab in Sidebar | — | not registered | — | — | none (missing from `expected-menu.json`) |
| Archive | Go Back | Cmd+[ | `go-back` | Y | Y | app-shell §4.3, OpenFeatures |
| Archive | Go Forward | Cmd+] | `go-forward` | Y | Y | app-shell §4.3, OpenFeatures |
| Archive | View History | Cmd+Y | `view-history` | — | — | settings adapter |
| Archive | View Archive | — | `view-archive` | — | — | settings adapter |
| Archive | Clear Archive | — | `clear-archive` | main (#132) | `I10_clear_archive_*` | Library confirmation, Cancel and Clear |
| Extensions | Manage Extensions… | — | `manage-extensions` | Y | Y | [#179](https://github.com/SergeSerb2/open/pull/179), [#189](https://github.com/SergeSerb2/open/pull/189); `extensions-ui X17_manage_singleton` |
| Extensions | Add Extension… | — | `add-extension` | Y | Y | #179, #189; real menu X16; dispatch opens a new Web Store Today tab |
| Extensions (hidden) | Open Extensions | Cmd+E | `open-extensions-picker` | Y | — | #179 registry; #189 context seam; X13 BLOCKED on Section 12 SCC presenter |
| Settings > Shortcuts > … | Extension Shortcuts | — | `extension-shortcuts` (also code-only) | Y | Y | `settings-preview`; `extensions-ui X27_*`; [closeout PR](https://github.com/SergeSerb2/open/pull/190) |
| Window | Minimize | Cmd+M | `minimize-window` | Y | Y | — |
| Window | Zoom | — | `zoom-window` | — | — | system (no dispatch spec) |
| Window | View Downloads | Cmd+Shift+J | `view-downloads` | — | — | app-shell §4.3, settings adapter |
| Window | View Library | Cmd+Shift+L | `view-library` | — | — | app-shell §4.3, settings adapter |
| Window | View Media | — | `view-media` | — | — | done: Library Media section (Arc `viewScreenshotsAndCaptures:`) |
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
