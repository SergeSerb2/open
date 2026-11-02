# Command bar and toolbar completion — implementation plan for Open

Status: plan (2026-10-25). Not implemented. It closes `docs/status.md` §3.3 gaps 22–26: inline autocomplete, one row per Split View, the browser-actions scope (and the other missing command bar scopes), the Cmd+1…9 numbering with the Essential Keyboard Shortcuts window, and the optional toolbar.

Amended 2026-10-26 for Arc capture session 2 (`docs/re/commandbar-completion.md` §8, CC-39…CC-44; `docs/re/interaction-states.md` §20.9, §20.12). The changes: holding Command shows **no** hints (§4.4); the (i) button opens an **inline privacy footer** in the bar, not a window (§4.8); the bar has **no open or close animation** (§4.9); the Site Search chip and inline completion follow the captured look and keys (§4.1, §4.3.6). The lead decisions at the end record what this supersedes. Evidence notation: **S2 18/0044** = frame 0044 of `.re/runtime/sessions/20261026-103712-18-command-bar/`; **V 9.70 s** = time in `.re/runtime/video/21-motion.mov`. Frames S2 18/0003–0035 also show one of the user's own Spaces: masks and scene files for them stay in `.re/` (never committed).

Implementers: coding agents with no other context. Follow this file literally. "Open choice" means the choice is final for v1 unless the lead changes it in §8. "guess" means: build the stated value, keep it in one token, and mark it `// guess` in code, so a later capture can fix it in one edit. Cite the finding IDs (CC-n) from `docs/re/commandbar-completion.md` in code comments where a behavior comes from Arc.

User-visible text never uses the Arc brand (AGENTS.md). "Little Arc" is "Little Open". Do not copy Arc assets, code, or data files. SF Symbols are system glyphs and are allowed. No unit tests (AGENTS.md rule 6): verify through the offscreen harnesses (`commandbar-render`, `sidebar-render`, `features-render`, `settings-preview`, `commands-dump`, `openkit suggest-check`) and the real app over the automation channel (§5).

Read first, in this order: `AGENTS.md`; `docs/re/commandbar-completion.md` (all of it: the evidence for this plan); `docs/commandbar.md`; `docs/suggest.md`; `docs/commands.md`; `docs/design.md` §2, §5; `docs/plans/app-shell.md` §3.5, §4.2, §4.3, §6, §7; `docs/re/interaction-states.md` §5, §9, §11; `docs/re/features-core.md` §4, §7.2, §8.2–8.3; `docs/re/menus-and-hotkeys.md` "Shortcuts that live in code", "Command Bar"; `docs/automation.md`.

## Goal

Finish Arc's command bar and window chrome in Open:

1. Inline autocomplete in the command bar field, with Arc's selection look and Chromium-style key rules.
2. One command bar row per Split View, with both pane icons and both titles.
3. Command bar scopes: an "Actions" scope (browser actions only) and an entry for the existing Tabs scope. Every other Arc command bar mode is listed with an owner or a reason to skip.
4. One numbering model for the sidebar items that Cmd+1…9 select, and the Essential Keyboard Shortcuts window. Holding Command shows nothing, as in Arc (CC-39).
5. The optional toolbar (View ▸ Show/Hide Toolbar, Cmd+Shift+D): a 32 pt bar on top of the page with navigation and the URL, and its rules next to the sidebar URL field.
6. Arc's (i) privacy footer inside the bar (CC-42), and a bar that appears and goes with no animation (CC-44).

## Success criteria

1. Typing a prefix of a strong tab or history host shows the rest of the host selected in the field in the same frame as the rows (tabs) or with the history snapshot. Return opens what row 1 shows. Backspace removes only the completion. IME composition never shows a completion.
2. `commandbar-render compare` against F0043 and F0062 (completion), F0061 (accepted completion), and A0120 (split row): every element ≤ 1 pt, ΔE00 ≤ 2. The eight existing comparisons in `docs/commandbar.md` §8 keep their numbers (no regression).
3. A Split View appears once in the command bar, with "Switch to Split View". Return selects the split and focuses the pane that matched.
4. Typing `actions` then Tab enters the Actions scope (chip "Actions", placeholder "Search…"); typing `tabs` then Tab enters the Tabs scope. Backspace on the empty scope restores the text typed before the scope. Typing `wikipedia` then Tab shows the captured Site Search chip (orange capsule, text only, placeholder "Search…"; §4.3.6), and `commandbar-render compare` against S2 18/0016 and 0018 is within the targets of criterion 2.
5. Cmd+1…9 select exactly the items of `BrowserModel.goToItemTargets`. Holding Command alone for 2 s shows nothing: no badge, no timer, no event monitor (CC-39). Idle CPU stays at zero.
6. Help ▸ Essential Keyboard Shortcuts, the command bar action, and Settings ▸ Shortcuts ▸ "Learn the Essential Shortcuts" all open one floating window with five items and the user's current keys.
7. Cmd+Shift+D toggles a 32 pt toolbar on the key window. The menu item reads "Show Toolbar" or "Hide Toolbar". The page gets 32 pt shorter. The state survives relaunch. The sidebar hides its URL field and its back, forward, and reload buttons while the toolbar shows.
8. Performance: the command bar shows first results ≤ 50 ms after Cmd+T in the real app; keystroke → rows drawn p95 ≤ 8 ms in `commandbar-render bench`; inline completion adds ≤ 0.3 ms p95 and no extra panel layout pass; the first snapshot stays < 5 ms p95 with 5,000 tabs (500 of them in splits).
9. `tools/verify-all.sh` passes at every step. The App e2e checks in §5.3 pass after Step 9.
10. The (i) button and Cmd+I show the inline footer (§4.8) and never open a window. Nothing else shows the footer. "Dismiss" hides it and sets `open.general.searchSuggestNoticeDismissed`. `commandbar-render compare` against S2 18/0044 is within the targets of criterion 2.
11. Cmd+T and Esc show and remove the whole panel between two frames: no scale, no fade, no animation key on any bar layer (CC-44).

## Non-goals

- No Arc Max: ChatGPT scope, Ask/Browse for Me, Instant Links, Arc Search (AGENTS.md v1 scope).
- No learned ranking. Ranking stays the deterministic heuristic of `docs/suggest.md`, with the one new rule in §4.1.3.
- No "Delete Suggestion" (CC-11), no Undo/Redo-by-name rows, no extension omnibox keywords (extensions UI plan), no Copy URL tracker stripping (CC-31, §8 Q8).
- No Shared Quotes items in the URL menu (Open has no Shared Quotes).
- No new library target. Each piece goes into the library that owns its area.

## 0. Locked decisions

| # | Decision | Why |
|---|---|---|
| D1 | `OpenSuggest` stays UI-free. It decides which row may complete and returns the completion text in the snapshot. `OpenCommandBar` owns the field, the selection, and the key rules. | `docs/suggest.md` "OpenSuggest never imports AppKit". One place decides ranking. |
| D2 | A completion always belongs to row 1 (the top hit). The field never shows a completion for a row that is not row 1, and Return always acts on the highlighted row. | CC-4; the WYSIWYG Return rule in `docs/commandbar.md` §4. |
| D3 | The completion is real text in the field editor with a selection over it. It never registers undo and never posts a text-change query. | CC-1, CC-3 (the AX value holds the whole text). |
| D4 | The engine query text is always the user's typed text (`userText`), never the field text. | CC-4: row 2 shows the typed text; CC-9 `lastUserInput`. |
| D5 | Split View rows keep `SuggestionKind.switchToTab` with `tabLocation == .splitPane` and a new `split` payload. No new intent: `.switchToTab(paneTabID, spaceID:)` targets a pane; the App selects its split and focuses that pane. | Smallest change to `CommandBarIntent` and to `docs/plans/app-shell.md` §4.2. |
| D6 | Scopes are one concept in the bar: `CommandBarScope` = Site Search, Actions, or Tabs. They share the chip, the Tab trigger, Backspace exit, and text restore. | CC-16, CC-19: Arc models TypeTravel and Site Search as peers. |
| D7 | The Cmd+1…9 numbering is one model query, `BrowserModel.goToItemTargets`. The Cmd+N key handler (app-shell Step C) calls it. | One numbering rule for every caller. (The hint badges that also called it are removed, D13.) |
| D8 | The optional toolbar is the existing `PaneChromeView` (the Split View pane bar) shown on a single pane. No second bar view. | CC-33: Arc's toolbar height default is 32, the same as the pane bar; CC-34 AX ids are shared. |
| D9 | Toolbar visibility is per window: `BrowserWindowState.showsToolbar`. "Show full URL" is app-wide (`open.advanced.showFullURLWithToolbar`, exists). | CC-34, CC-37. |
| D10 | The Essential Keyboard Shortcuts window lives in `OpenSettings` (SwiftUI, like the Settings and Library windows), created on first use, never at launch. | Static content; cheap in SwiftUI; same owner as the Shortcuts pane that opens it. |
| D11 | No toolbar animation. Showing or hiding it resizes the page once. | Performance: a per-frame page resize costs Chromium a relayout per frame. Arc's motion is not captured. |
| D12 | The command bar has no open or close animation. Present and dismiss change the panel in one frame. The `Motion.commandBarOpen*` and `Motion.commandBarClose*` tokens and their Core Animation code are deleted (§4.9). | CC-44: in the video the bar appears or goes between two frames ≤ 38 ms apart, 4 of 4 times (V 9.70, 10.88, 13.02, 14.20 s). |
| D13 | No hold-Command hints. Open builds no badge view, no flags monitor, and no hints setting. Only the numbering model stays (§4.4). | CC-39: no hints after 2–4 s (S2 18/0001–0003). With CC-23 (flag default off) this is Arc's shipping behavior. |
| D14 | The (i) button shows the search-suggestion privacy notice as a footer inside the bar (§4.8). It opens **only** on (i) or Cmd+I, never by itself. It is the same notice as Settings "Code 4" and uses the same key, `open.general.searchSuggestNoticeDismissed`. | CC-42 (S2 18/0044); features-core §4.5 rule 13 (same text); lead ruling 2026-10-26 (no capture shows it unasked) |

## 1. What Arc does (summary)

Full evidence with addresses and frames: `docs/re/commandbar-completion.md`.

| Topic | Arc | Mark |
|---|---|---|
| Inline completion look | The rest of the host is appended and selected; selection fill = the Space's `dark.subtitle` (`#807571` in Space 1, the same as Cmd+L); no caret; AX value = whole text (CC-1…CC-3) | measured |
| Which row | Row 1, the top hit; in F0043 and F0062 an open tab on that host. Row 2 is the typed-text search row (CC-4) | measured |
| Hint while completing | "Search \<Engine\> [Tab]" from the typed text, never "or Space" (CC-5) | measured |
| Letter case | The field shows the candidate's case (CC-6) | derived |
| Accepted completion | Whole host, caret at end, row 1 = navigate row for the host, no further completion (CC-7) | measured |
| Backspace and arrows | Tracked (`isBackspacingStatus`, `latestInputAndDidBackspace`, `onKeyboardLeft/Right`) (CC-9, CC-10). Session 2: "wiki" completes to "wikipedia.org" with the added part selected and the hint "Search Wikipedia [Tab]"; Backspace removes only the completion and leaves "wiki" (CC-40, S2 18/0009–0010) | Backspace measured; Right and Left still guess (no frame isolates them) |
| Split row | One row; plate 30×30 at `[12, 10]`, radius ≈ 7, two cells split by a 1 pt gap, ≈ 9 pt pane icons; title at x 50; titles split by a 1 pt × 12 pt rule, white ≈ 0.17; "Switch to Split View" (CC-12…CC-15) | measured |
| Actions scope | Pill "Actions"; placeholder "Search…"; scope restores the earlier text; pill close accessory; entry gesture unknown (CC-16…CC-20) | decoded, string |
| Tabs scope | Uses the Site Search trigger mechanism (CC-21) | string |
| Site Search chip | `wikipedia` + Tab: an orange capsule "Wikipedia" (`#FFA000`, white text, no icon, soft glow) at panel `[54, 20, 81, 24]`; the field moves to x 146 with the drawn placeholder "Search…"; the selected row in the scope is orange too; Backspace on the empty field removes the chip and gives back "wikipedia" (CC-41, S2 18/0016, 0018, 0021) | measured |
| Hold-Command hints | Favorites ("top apps") show their shortcuts while Command is held, behind a remote flag whose built-in default is off (CC-23, CC-24). Session 2: holding Command 2–4 s shows no hints (CC-39, S2 18/0001–0003), so the shipping app has them off | measured |
| (i) button | Opens an inline footer at the bottom of the bar: "We talk to your search engine to help us suggest results." / "Learn more about your data on Arc here." with the buttons "Search Settings…" and "Dismiss". Not a window (CC-42, S2 18/0044) | measured |
| Open and close | No animation: the whole bar appears or goes between two video frames (CC-44, V 9.70–14.20 s) | measured |
| Essential Keyboard Shortcuts | Floating, non-resizable titled window, hidden title, movable by background; five items (CC-27, CC-28); opened from Help, Settings ▸ Shortcuts callout button, welcome view (CC-29); not from (i) (CC-42) | decoded |
| Optional toolbar | 32 pt content top bar, per window, menu title switches Show/Hide, URL pill menu "Show as Toolbar" / "Hide Toolbar" / "Show Full URL" / "Manage Extensions", Advanced setting "Show full URL when Toolbar is enabled" (CC-32…CC-38) | decoded, string |

## 2. Current state (origin/main `d1720e3`, 2026-10-25)

| Area | State | Source |
|---|---|---|
| Command bar library | Done and checked (78/78). No completion, no scopes other than Site Search, one row per split pane. | `docs/commandbar.md` |
| Suggest engine | Done (31/31). Modes `newTab`, `editCurrentURL`, `searchTabs` (no UI entry). `TabsProvider` excludes the current tab in every mode, although `docs/suggest.md` "Input" says only edit mode does. | `Packages/OpenKit/Sources/OpenSuggest/Providers.swift` (`excluded`) |
| Registry | `toggle-toolbar` (Cmd+Shift+D), `keyboard-shortcuts-edu` (Help), command bar action `keyboard-shortcuts`, `show-shortcuts-overlay` (no key, excluded from the bar), `go-to-tab-1…9`, `go-to-last-tab` exist. No handler. | `OpenCommands/CommandRegistry.swift`, `SuggestAdapter.swift` |
| Settings | `open.advanced.showFullURLWithToolbar` (default false) shows in Advanced. `open.shortcuts.includeFavoritesInTabNumbering` (true) and `open.shortcuts.switchToNinthEnabled` (true) exist. The Shortcuts pane draws "Start with the basics" / "Learn the Essential Shortcuts" as a two-segment filter (wrong, CC-30). | `OpenSettings/SettingsTypes.swift`, `ShortcutsPane.swift` |
| Split pane bar | `PaneChromeView` draws the 32 pt bar only in splits, with F0081 metrics (`SplitMetrics`). | `OpenFeatures/PaneChromeView.swift`, `WebContentContainer.swift` |
| App | The command bar, menus, and keys are not wired on `main` (app-shell Step C in progress). | `docs/status.md` §0.3 |

## 3. Architecture

### 3.1 Files (create exactly these; edit only what is listed)

| Library | New files | Edited files |
|---|---|---|
| `OpenSuggest` | `InlineCompletion.swift` | `SuggestTypes.swift`, `Ranking.swift`, `Providers.swift`, `TabIndex.swift`, `SiteSearch.swift`, `SuggestEngine.swift`, `ActionRegistry.swift` (scope keywords only) |
| `OpenCommandBar` | `CompletionSession.swift`, `ScopeChip.swift`, `PrivacyFooterView.swift` | `CommandBarController.swift`, `CommandBarTypes.swift`, `CommandBarView.swift` (remove the open/close animation), `InputRowView.swift`, `Presentation.swift`, `ResultRowView.swift`, `ResultsView.swift` (AX label; list clip above the footer) |
| `OpenDesign` | — | `CommandBarTokens.swift` (split row, chip look, chip close, footer; delete `commandBarOpen`, `commandBarOpenScale`, `commandBarClose`, `commandBarCloseScale`), `Metrics.swift` (`ToolbarMetrics`) |
| `OpenModel` | `GoToItemNumbering.swift` | `Containers.swift` (`showsToolbar`), `BrowserModel.swift` (`setToolbarShown`) |
| `OpenStore` | — | `SnapshotDTOs.swift` (`showsToolbar`, optional on decode) |
| `OpenSidebar` | — | `ChromeViews.swift`, `SidebarView.swift`, `SidebarMenus.swift`, `SidebarIntent.swift`, `ModelSidebarActions.swift` (toolbar only) |
| `OpenFeatures` | — | `PaneChromeView.swift`, `WebContentContainer.swift`, `BrowserWindowController.swift` |
| `OpenCommands` | — | `CommandRegistry.swift`, `MenuBuilder.swift` (title hook), `SuggestAdapter.swift` |
| `OpenSettings` | `EssentialShortcutsWindow.swift` | `ShortcutsPane.swift`, `SettingsTypes.swift` |
| Harnesses | — | `commandbar-render/*`, `sidebar-render`, `features-render`, `settings-preview`, `commands-dump`, `openkit` (`suggest`, `suggest-check`, `commands-demo`) |
| App (Step 0) | — | `App/CommandBar/AppCommandBarDelegate.swift` (the `CommandBarIntent` switch: remove `.showHelp`, add `.openSearchSettings`, implement `didDismissPrivacyNotice`; see §6 Step 0) |
| App (Step 9) | — | `App/CommandBar/AppCommandBarDelegate.swift`, the App `CommandDispatcher` extension, `App/Automation/AutomationController.swift`, `tools/e2e/engine_e2e.py` |
| Docs | — | `docs/commandbar.md`, `docs/suggest.md`, `docs/commands.md`, `docs/design.md` §2, `docs/settings.md`, `docs/status.md` |

### 3.2 Data flow (inline completion)

```text
keystroke ─► CommandBarFieldEditor (insert / delete / move / mark)
          ─► CompletionSession: userText, lastEdit, displayed completion
          ─► SuggestEngine.query(userText, context(allowsInlineCompletion: lastEdit == .insertAtEnd))
snapshot  ─► Ranking (rule T3a picks the completion row) + InlineCompletion(rowID, fieldText, typedLength)
          ─► CommandBarController.apply: rows; if row 1 is selected and the session allows it,
             write fieldText into the editor (no undo, no query) and select [typedLength, end)
```

## 4. Design spec

### 4.1 Inline autocomplete

#### 4.1.1 When a completion may show (all must hold)

1. The bar mode is `.newTab` or `.editCurrentURL`, with no scope (no Site Search, Actions, or Tabs chip).
2. The last edit was an insertion that left the caret at the end of the text with no selection: typing, or committing IME text at the end. Open rule: paste never completes; a deletion, undo, redo, or caret move turns completion off until the next insertion at the end.
3. No marked (IME) text exists.
4. `userText`, after the scheme and `www.` strip in §4.1.2, is not empty and has no whitespace.
5. The applied snapshot is for the current `userText`, it has a completion, and row 1 is selected.

The controller passes rule 2 to the engine as `SuggestContext.allowsInlineCompletion`. The engine checks rules 1 and 4. The controller checks rules 3 and 5 when it applies a snapshot.

#### 4.1.2 Which text completes (`InlineCompletion.fieldText(typed:url:)`)

1. Only rows of kind `switchToTab` (including split rows, using the matched pane's URL) and `history` can complete. Remote, typed, calculator, action, and Site Search rows never complete.
2. The row's URL scheme is `http` or `https`.
3. Split `typed` into `lead` and `body`: `lead` is a leading `https://` or `http://` (case-insensitive), then a leading `www.`; `body` is the rest. `lead` is kept exactly as typed.
4. The candidate `c`: if `body` contains `/`, `?`, or `#`, `c` = `TextMatching.matchableURL(url)` without a trailing `/` on a root path. Otherwise `c` = `TextMatching.displayHost(url)` plus `:port` for a non-default port. So a text without a path completes only to a host, and a whole host never completes to a deeper path (CC-7). guess: the host-only rule (CC-1 and CC-7 show root hosts only).
5. `c` completes when it starts with `body` (case-insensitive, `TextMatching.fold`) and is longer than `body`. Then `fieldText = lead + c` and `typedLength = (lead + body).utf16.count`.
6. The field shows `c` in the candidate's letter case, also for the typed part (CC-6). `userText` keeps the user's case.

Examples: `gith` + history `https://github.com/openai` → `github.com` (selected `hub.com`); `github.com` → none (whole host); `github.com/op` → `github.com/openai`; `localhost:30` + tab `http://localhost:3000/admin` → `localhost:3000`; `https://goo` + tab `https://www.google.com/` → `https://google.com`; `git hub` → none (space).

#### 4.1.3 Ranking interplay (`OpenSuggest/Ranking.swift`)

New top-hit rule **T3a — inline completion** (`TopHitRule.inlineCompletion = "T3a-inline-completion"`), checked after T2 and before T3:

- It applies when `allowsInlineCompletion` is true, §4.1.1 rules 1 and 4 hold, the input is not arithmetic (T4), and no row passes T5 (exact tab title or host).
- It picks the highest-ranked row that has `canBeTopHit` (T7 eligibility, `docs/suggest.md`) and a §4.1.2 completion.
- The typed URL or typed search row stays in the list (normally row 2), so the user can still arrow to it (CC-4).

After the top hit is chosen by any rule (T3a, T5, or T7), the engine sets `snapshot.inlineCompletion` if `allowsInlineCompletion` is true and the top-hit row has a §4.1.2 completion. Rules T1–T4, T6, and T8 never produce a completion.

Effects to keep (all have `suggest-check` scenarios, §5.1):

| Input | allowsInlineCompletion | Top hit | Completion |
|---|---|---|---|
| `googl` with an open tab on that host | true | the tab (T3a) | `e.com` (F0043) |
| `Google` = tab title | true | the tab (T5) | `.com`, field in lower case (F0062) |
| `google.co` (URL-like) with that tab | true | the tab (T3a) | `m` |
| `google.co` after Backspace | false | typed URL (T3) | none |
| `google.com` (whole host) | true | typed URL (T3; T5 matches the host, so T3a is skipped) | none (F0061) |
| `2+2` | true | calculator (T4) | none |

Two more engine changes in the same step:

1. **Current tab in Cmd+T.** `TabsProvider` excludes the current tab only in `.editCurrentURL` mode, as `docs/suggest.md` "Input" already says. Evidence: F0063 and F0043 list the page behind the bar as a "Switch to Tab" row (derived). The F0043 completion comes from that row.
2. **History carry-over.** Snapshot 0 carries over the previous query's history rows whose URL still matches the new text when the new text extends the old one (same rule as the remote carry-over in `docs/suggest.md` §4). The history snapshot replaces them. Without this, a history completion disappears for one or two frames on every keystroke.

#### 4.1.4 Display (tokens; all existing unless named)

| Element | Value | Evidence |
|---|---|---|
| Completed text | Field text, same font (18 Medium) and baseline as typed text | CC-1 |
| Selection fill | `CommandBarTheme.textSelection` (theme `dark.subtitle`; `#807571` in Space 1) | CC-2, F0043 |
| Selected text | `CommandBarRole.inputTextSelected` (#F2F2F5; F0043 core `#EEEEF1`, within ΔE 2) | CC-2 |
| Selection box | From the last typed glyph's advance to the field's text end; box `[98, 21, 51, 21]` in panel points for F0043. AppKit's selection rect must match within 1 pt; if it ends 2 pt late, as in `docs/commandbar.md` §8.3, record it there. | CC-2 |
| Caret | Hidden while the completion is selected (AppKit default for a selection) | CC-2 |
| Leading icon | Row 1's icon (existing rule) | CC-4 |
| Site Search hint | From `userText`; `hintAllowsSpace = false` while a completion shows. Session 2 shows the same rule: "wiki" with the completion "wikipedia.org" gives "Search Wikipedia" + [Tab], no "or Space" (AX button "Search Wikipedia, Tab" at panel `[597, 20, 147, 24]`) | CC-5, CC-40 (S2 18/0009) |

Capture check (session 2, CC-40): the completed part is selected and the caret is hidden (S2 18/0009); this matches the rows above. The S2 frame is a blue Space at window 1728 × 1084 (panel top 373 = (1084 − 339) / 2, the existing position rule), so §5.2 adds it as a second completion comparison.

#### 4.1.5 Keys while a completion shows

| Input | Result | Mark |
|---|---|---|
| A character that equals the next completed character (case-insensitive) | Keep the completion: move the selection start by one, append the character to `userText`, query `userText`. No flicker: the field changes before the new snapshot arrives. | Open rule (Chromium behavior) |
| Any other character, or Space | Replaces the selection (normal text system). Query `userText`. A new completion may show when its snapshot arrives. Space never enters Site Search here (CC-5). | derived |
| Backspace, Forward Delete, Option/Cmd+Backspace | Remove only the completion; `userText` stays; completion is off until the next insertion at the end (`didBackspace`). Re-query `userText` with `allowsInlineCompletion = false` so the top hit can change (for example to the typed URL). | Backspace measured: "wikipedia.org" → "wiki" (CC-40, S2 18/0010); Forward Delete and Option/Cmd+Backspace guess (Chromium) |
| Second Backspace | Deletes the last typed character as usual; completion stays off. | Open rule |
| Right arrow, End, Cmd+Right, Ctrl+E | Accept: `userText = fieldText`, caret at the end, no selection. Query with `allowsInlineCompletion = false`. | CC-7; key set guess |
| Left arrow, Home, Cmd+Left | The completed text becomes typed text; the caret goes to the selection start (Left) or the line start (Home, Cmd+Left). Query the new text with completion off. | guess (native NSTextView) |
| Shift+arrows, Cmd+A, a mouse click or drag in the field | The completed text becomes typed text; the selection or caret follows the gesture. Query the new text with completion off. | Open rule |
| Up, Down, pointer hover on another row | Move the row selection (existing). The completion hides while row 1 is not selected (field = `userText`, caret at the end) and shows again when row 1 is selected again. No query. | Open rule (D2) |
| Return, Cmd/Shift/Opt+Return | Act on row 1, the completion row (existing WYSIWYG rule). | D2 |
| Tab | With a Site Search or scope hint: enter that scope using `userText` (completion dropped). Without a hint: normal focus traversal (existing). | CC-5 |
| Esc | Closes the bar (existing; one press). | `docs/commandbar.md` §4 |
| Cmd+Z | Undo the last typing step. The completion is never in the undo stack. After undo, completion is off until the next insertion. | D3 |
| Cmd+C, Cmd+X | Copy or cut the selected completed text (native). Cut counts as a deletion. | native |

#### 4.1.6 IME

- Marked text never shows a completion. When composition starts (`setMarkedText`) while a completion shows, the controller removes the completion first (field = `userText`, caret at the end) without a query, then lets the input method mark.
- During composition, Return, Tab, Esc, Space, and arrows stay with the input method (existing flows 36–44).
- A commit that inserts at the end counts as an insertion (completion may show with the next snapshot). A commit that replaces text in the middle does not.
- The existing rule stays: zero queries while marked; one query on commit.

#### 4.1.7 Timing and performance

- A completion from a tab row shows in the same frame as snapshot 0 (synchronous). A completion from history shows with the history snapshot (p50 ≈ 12 ms, `docs/suggest.md`) or at once through the carry-over (§4.1.3).
- There is no animation. The selection appears and moves in one frame.
- The completion check runs on at most 12 rows per snapshot: string prefix compares only. Budget: ≤ 0.05 ms p95 in `suggest-check`.
- Applying a completion edits the field editor's storage and selection once per snapshot. It must not call `layoutSubtreeIfNeeded` on the panel and must not redraw rows. Budget: keystroke → rows drawn p95 ≤ 8 ms; the completion keystroke bench (§5.4) adds ≤ 0.3 ms p95 over the plain bench.

#### 4.1.8 Accessibility

- The field's AX value is the whole field text, and its selected text range is the completion (CC-3). AppKit provides both once the completion is real text (D3).
- No extra announcement. Row selection announcements stay as they are.

### 4.2 One row per Split View

#### 4.2.1 Engine (`OpenSuggest`)

- `TabIndex.Entry` gains `splitID: ItemID?` and `paneIndex: Int`. Placements of split panes fill them. A new `TabIndex.splits: [ItemID: SplitSummary]` holds pane entry slots in pane order and the orientation. It is rebuilt with the structure scope (the split's pane list and orientation are structure).
- `TabsProvider` scans panes as today, then groups matches by `splitID`. One candidate per split: quality = the best pane's quality, frecency = the most recent pane's recency, boost = the `.splitPane` location boost (+12) plus the current-Space boost. Empty query: one candidate per split.
- The row: `id = "split:<splitID>"`, kind `.switchToTab`, `tabLocation = .splitPane`, `tabID` = the best-matching pane (empty query: `Split.focusedPaneID`, else the first pane), `url` = that pane's URL, `title` = pane titles joined with `" | "` (CLI and AX fallback only), and a new field:

```swift
public struct SplitRowInfo: Sendable, Hashable {
    public var splitID: ItemID
    public var paneTabIDs: [ItemID]       // pane order
    public var paneTitles: [String]
    public var paneIcons: [IconHint?]
    public var isVertical: Bool           // SplitOrientation.vertical
}
public var split: SplitRowInfo?           // on Suggestion; nil for every other row
```

- Exact tab (T5) and T7 eligibility read any pane: a pane title or host equal to the query makes the split row exact.
- Dedupe: a history or typed-URL row whose URL key equals any pane's key folds into the split row, with open-tab precedence (5).
- Edit mode: the split row is left out when the current tab is one of its panes (the same rule as the current tab).
- Caps: a split row counts as one `switchToTab` row.

#### 4.2.2 Drawing (`OpenCommandBar`)

New icon case `CommandBarIcon.split([CommandBarIcon], vertical: Bool)` and row field `titleParts: [String]` (empty for other rows). New tokens in `CommandBarMetrics`:

| Token | Value | Mark, evidence |
|---|---|---|
| `splitPlate` | `[12, 10, 30, 30]` in row points for 2 horizontal panes | measured, A0120 (CC-13) |
| `splitPlateRadius` | 7, continuous | fitted, A0120 corner coverage |
| `splitCellGap` | 1 pt gap at each cell boundary (the panel shows through) | measured, A0120 |
| `splitPaneIconSize` | 9 pt, centered in its cell | measured ink, A0120 |
| Cells for 3–4 panes | Plate width 15 × n; vertical splits stack cells in a 30×30 plate (icon = min(9, cell height − 4)) | guess (no capture; §9 item 6) |
| `splitTitleX` | Plate max x + 8 (50 for 2 panes) | measured (CC-14) |
| `splitTitleRule` | 1 pt wide, 12 pt tall, row y 20.5–32.5, white 0.17, 5 pt gap each side | measured, fitted alpha (CC-14) |
| Plate fill | `CommandBarRole.plate` (white 0.05), the action plate token | measured |
| Selected row | Plate white (like favicon plates on the selected row); the gap shows the focus color | derived from F0061/F0063 plates |
| Accessory | `.switchTo("Switch to Split View")` (exists) | CC-12 |
| Subtitle | None | CC-14 |

Title layout: each part uses the row title font (13 Medium). Parts follow each other with the rule between them. If the line is too long, the last part truncates at its tail first, then earlier parts (guess). Unchanged rows still redraw only when their content changes.

AX: the row button label is the pane titles joined with ", ", and its value is "Switch to Split View".

#### 4.2.3 Choosing the row

`.switchToTab(paneTabID, spaceID:)` (D5). The App (Step 9): if `model.parent(of: paneTabID)` is `.splitPane(splitID)`, switch Space if needed, then `model.selectNode(windowID:spaceID:nodeID: splitID)` and `model.focusSplitPane(splitID:tabID: paneTabID)`, then `sidebar.reveal(nodeID: splitID)`, then focus that pane's page.

### 4.3 Scopes and other modes

#### 4.3.1 Scope model (`OpenCommandBar`)

```swift
public enum CommandBarScope: Sendable, Hashable { case site(SiteSearch), actions, tabs }
public private(set) var scope: CommandBarScope?          // replaces siteScope
public enum CommandBarMode { case newTab, editCurrentURL, searchTabs, searchActions }  // adds searchActions
```

`present(.searchTabs)` and `present(.searchActions)` open with that scope set. Their base mode for exit is `.newTab`.

| Scope | Chip | Placeholder | Engine |
|---|---|---|---|
| Site Search | site name only, no icon (§4.3.6; replaces the icon + name guess in the library) | "Search…" (CC-41; replaces the "Search \<Site\>…" guess) | `siteSearchID` (exists) |
| Actions | "Actions", no icon (guess: same chip view as Site Search) | "Search…" | `SuggestMode.searchActions` |
| Tabs | "Tabs" (guess), no icon | "Search…" (replaces the "Search Tabs…" guess) | `SuggestMode.searchTabs` (exists) |

Evidence: CC-17 (title "Actions"), CC-18 ("Search…"), CC-21 (Tabs uses the Site Search trigger), CC-41 (the captured Site Search chip and placeholder, S2 18/0016).

#### 4.3.2 Entering a scope

| Gesture | Result | Mark |
|---|---|---|
| Type `actions` (exactly; also `action`, `commands`) | Hint "Search Actions [Tab]" (no "or Space") | Open choice (CC-20: Arc's gesture is unknown) |
| Type `tabs` (exactly; also `tab`) | Hint "Search Tabs [Tab]" | Open choice |
| Tab with that hint | Enter the scope; the field empties; `queryBeforeEnteringScope` = the typed text | CC-19 |
| Space after `actions` or `tabs` | Types a space; never enters a scope | Open rule: keeps searches such as "tabs vs spaces" |
| Command `search-actions` / `search-tabs` (no default keys, customizable) | Opens the bar in that scope | Open choice |

Scope hints use exact keyword matches only, so they never hide a Site Search hint for a prefix. If a site and a scope share a keyword, the scope wins. The engine gets the keywords from `SiteSearchIndex` as two built-in pseudo-sites (`scope-actions`, `scope-tabs`) with no URL template; the controller maps their ids to `.actions` and `.tabs`.

#### 4.3.3 Inside a scope

- Actions: only `ActionsProvider` runs. No 2-character minimum. The empty query lists available actions in `ActionRegistry` seed order (guess; Arc ranks by recent use, CC-16 ranking keys). Up to 12 rows, 5 visible, scrolled (existing panel limits). Requirements still hide actions that do not apply. Top hit: the best action for a non-empty query (new rule `T2a-search-actions`); none for the empty query. Rows keep their keycaps.
- Tabs: existing `searchTabs` behavior, with split rows (§4.2).
- No remote, history, calculator, typed, or Site Search rows in either scope. No inline completion (§4.1.1 rule 1).

#### 4.3.4 Leaving a scope

| Gesture | Result | Mark |
|---|---|---|
| Backspace on an empty field | Leave the scope. The field shows `queryBeforeEnteringScope`, caret at the end; query it. For a scope opened by command, the field is empty and the mode is `.newTab`. | CC-19 (derived); applies to Site Search too |
| Click the chip's close glyph | Same as Backspace on empty | CC-19 |
| Esc | Closes the bar (existing) | — |

Chip close glyph: on pointer hover, an `xmark.circle.fill` glyph (11 pt) replaces the chip's text at its left edge and the text moves right by 15 pt, so the chip grows by 15 pt while hovered. guess (no capture; the captured chip has no icon to replace, §4.3.6).

Session 2 confirms the restore rule for Site Search: `wikipedia` + Tab, then Backspace on the empty field, gives back "wikipedia" with the caret at the end (CC-41, S2 18/0021).

#### 4.3.5 Arc command bar modes and their owners

| Arc mode or entry | Evidence | Open |
|---|---|---|
| New tab (Cmd+T), edit URL (Cmd+L) | FC §4.1 | done (library); App in app-shell Step C |
| Site Search scope | FC §4.6 r15–16 | done; this plan adds text restore and the chip close glyph |
| Actions scope (TypeTravel) | CC-16, CC-17 | this plan |
| Tabs scope | CC-21 | engine done; this plan adds the entry and the chip |
| Edit pinned URL (`CommandBarEditPolicy`) | FC §4.1 r1 | app-shell §4.1 (`editPinnedURL`) |
| New window opens with the bar | IS §17 | app-shell §3.5, `docs/commandbar.md` §10 item 1 |
| Add Tab to a split (fills an empty pane) | `ForceRouteDestination`, sidebar `.addTabToSplit` | app-shell §4.1 / M4; needs a `CommandBarDestination` for a pane — owner app-shell Step C |
| Search-suggestion privacy notice | FC §4.5 r13 | settings ("Code 4"); not this plan |
| ChatGPT scope, Ask, Browse for Me, Instant Links, Arc Search | CC-16; FC §4.2 | out of scope (Arc Max) |
| Little Arc under the command bar | flag `little-arc-shows-under-command-bar-enabled` (built-in default false) | skip |
| Control key opens actions (`controlKeyShowsTypeTravel`) | CC-20 (hidden default, off) | skip; §8 Q2 |

#### 4.3.6 Chip look (CC-41)

Measured on S2 18/0016 (chip, empty field) and 0018 (typed query); panel points from the panel's top-left (panel `[481, 373]` in the 1728 × 1084 window). The library today draws the theme focus color, a site icon, and radius 6 (`InputRowView.drawChip`, all guesses). Replace them with:

| Part | Value | Mark, evidence |
|---|---|---|
| Frame | x 54 (1 pt after the field's old x 53), y 20, height 24; width = text width + 2 × 10 (81 for "Wikipedia") | measured (pixel bounds x 535…615, y 393…416) |
| Shape | Capsule (radius = height / 2), continuous | visual |
| Fill | `CommandBarColors.siteSearchChip` = `#FFA000` | measured (sRGB after the display profile, `interaction-states.md` §20.9). guess: one color for every site; the per-engine reading in CC-41 has no second sample |
| Glow | An outer glow in the fill color, about 12 pt wide, fading to the panel fill; drawn as a shadow of the capsule path: color `siteSearchChip` a 0.35, blur radius 6, no offset | fitted (pixels 523…534 left of the chip rise from the panel fill toward orange) |
| Text | The site name, 13 Semibold, white, centered; no icon | text and color measured; size and weight fitted (ink width 61 pt for "Wikipedia") |
| Field | Text field x = chip max x + 11 (146 for "Wikipedia"); drawn placeholder "Search…" in the placeholder style (18 Medium, white 0.55). The AX placeholder value is empty in Arc; Open keeps the native placeholder equal to the drawn one (accessibility rule, `docs/commandbar.md` §4) | measured (AX `commandBarTextField` x 627 in the window; image), Open rule for AX |
| Leading icon | Unchanged magnifier at `[23, 23, 18, 18]` | measured (S2 18/0016) |
| Selected row inside the scope | Fill `siteSearchChip` (with the row selection radius), white title and icon | measured (S2 18/0018: the "bird" row is orange) |
| Actions and Tabs chips | The same view and tokens with their titles (§4.3.1) | guess (no capture) |
| Panel with the chip and no rows | Input row only, ≈ 64 pt tall | measured (S2 18/0016; confirms the `docs/commandbar.md` §3.1 guess) |

Tokens: `CommandBarMetrics.chipHeight` 24 (exists), `chipRadius` = height / 2 (was 6), `chipPaddingX` 10 (was 8), `chipToText` 11 (was 8), `chipIconSize` deleted; `BarFont.chip` = 13 Semibold; new `CommandBarColors.siteSearchChip` and `CommandBarMetrics.chipGlowBlur` 6, `chipGlowAlpha` 0.35. Light appearance of the chip: not captured; use the same tokens (guess).

### 4.4 Cmd+1…9 numbering (no hold-Command hints)

Arc shows no hints while Command is held (CC-39, S2 18/0001–0003, D13). This section keeps only the numbering model, because the Cmd+1…9 key handler needs it. Do not build a badge view, a flags monitor, a delay timer, or a "Show shortcuts while holding ⌘" setting.

#### 4.4.1 Numbering (`OpenModel/GoToItemNumbering.swift`, D7)

```swift
extension BrowserModel {
    /// Targets of go-to-tab-1…9 for this window. Index 0 = Cmd+1. Nil = no target.
    public func goToItemTargets(windowID: WindowID, includeFavorites: Bool, ninthSelectsLast: Bool) -> [ItemID?]
}
```

Order: the Favorites of the focused Space's Profile in grid order (when `includeFavorites`), then the focused Space's pinned section, then Today, in sidebar row order. Expanded folders contribute their visible children; a peeked folder (sidebar-completion §3.17) contributes its one visible child; collapsed folders contribute nothing; folder rows themselves are not targets; a collapsed pinned section contributes nothing; a split counts once (its id). Slot 9: the ninth item when `ninthSelectsLast` is false, else the last item. Settings: `includeFavorites` = `open.shortcuts.includeFavoritesInTabNumbering` (true); `ninthSelectsLast` = NOT `open.shortcuts.switchToNinthEnabled` (true). Open choice (Arc's exact numbering is not captured; CC-25).

#### 4.4.2 What holding Command does

Nothing. A Command press alone draws no badge, starts no timer, and installs no event monitor, so idle CPU and key latency do not change. Cmd+1…9 still run `go-to-tab-N` through `goToItemTargets` (D7).

The registry id `show-shortcuts-overlay` ("Show Shortcuts While Holding Command") stays registered with no handler: `isCommandEnabled` returns false, it has no menu item, and it stays out of the command bar (existing `SuggestAdapter` exclusion). Settings ▸ Shortcuts gets no hints toggle, and no `open.shortcuts.showHintsWhileHoldingCommand` key is added.

Removed by the 2026-10-26 amendment (do not build): the badge view `ShortcutHintBadge`, `ShortcutHintMetrics`, `Motion.shortcutHintDelay` / `shortcutHintFadeIn` / `shortcutHintFadeOut`, `SidebarContext.shortcutHints`, and the App-wide flags monitor. Arc's code has the feature behind the remote flag `show-top-app-shortcuts-when-holding-cmd` (CC-23), and the shipping app keeps it off (CC-39).

### 4.5 Essential Keyboard Shortcuts window

#### 4.5.1 Window (`OpenSettings/EssentialShortcutsWindow.swift`, CC-27)

- One shared window per app, created on first open and reused.
- Style mask: titled, closable, miniaturizable, full-size content view; not resizable. Title "Essential Keyboard Shortcuts" (AX and the Window menu) with hidden title visibility and a transparent title bar. Not opaque. Movable by the window background. Level `.floating`. Collection behavior `.fullScreenAuxiliary`.
- First open: centered on the screen of the key browser window. Later opens: bring to front where it was.
- Esc and Cmd+W close it. It never becomes a browser window (no sidebar, no command bar).

#### 4.5.2 Content (Open design; no capture, §9 item 4)

| Part | Value |
|---|---|
| Width | 440 pt; the content sets the height (about 382 pt) |
| Insets | Top 40 (clears the traffic-light zone), sides 24, bottom 24 |
| Background | `CommandBarColors.bannerBackground` (#FDFDFE light / #161616 dark), following the macOS appearance |
| Header | "Essential Keyboard Shortcuts", 17 Semibold, primary text; 16 pt below it the list starts |
| Rows | 5 rows × 56 pt, 1 pt separators `CommandBarHairlineDividerColor` |
| Row text | Title 14 Semibold primary; description 12 Regular, black 0.55 / white 0.55 |
| Keys | One keycap per key, right-aligned: 24 pt tall, radius 5, padding 4, gap 4, plate `CommandBarAccessoryBackgroundColor`, text 13 Medium `CommandBarAccessoryForegroundColor` (the command bar keycap tokens) |

Rows, in Arc's order (CC-28). Text is Arc's except the brand and the tracker claim (§8 Q8):

| Title | Description | Command id (key from `KeyBindingStore`) |
|---|---|---|
| Open a New Tab | Open the Command Bar to create a new tab | `new-tab` (⌘T) |
| Switch to a Recent Tab | Hold this to quickly switch between recent tabs | `tab-switcher-forward` (⌃Tab) |
| Copy Page URL | Copy the current tab's URL | `copy-url` (⇧⌘C) |
| Add Split View | View multiple websites side-by-side | `add-split-view` (⌃⇧=) |
| Open Little Open | Use a smaller browser window for quick searches | `new-little-open-window` (⌥⌘N) |

A cleared binding shows "—". The window updates when the bindings change.

#### 4.5.3 Entry points

| Entry | Id or control |
|---|---|
| Help ▸ Essential Keyboard Shortcuts | `keyboard-shortcuts-edu` |
| Command bar action "Essential Keyboard Shortcuts" | `keyboard-shortcuts` (mapped by `SuggestAdapter`) |
| Settings ▸ Shortcuts callout | New callout (below) |
| First run "Learn Essential Shortcuts" | Owner: `docs/plans/first-run.md` (call `keyboard-shortcuts-edu`) |

The command bar (i) button and Cmd+I do **not** open this window. They show the inline privacy footer (§4.8, CC-42; supersedes the 2026-10-26 Q9 decision).

Settings ▸ Shortcuts fix (CC-29, CC-30): replace the two-segment filter with a callout of the same frame (359×35, radius 6, `SettingsTokens.button`): the left label "Start with the basics" (not interactive) and a button "Learn the Essential Shortcuts" with `command.circle.fill`, accent fill, that opens the window through an `OpenSettings` callback the App sets. Remove the `basics` filter: the list shows every active command. Update `docs/settings.md` and the `settings-library` plan row (§5 "Shortcuts pane shape").

### 4.6 Optional toolbar

#### 4.6.1 State

- `BrowserWindowState.showsToolbar: Bool` (default false). `WindowDTO.showsToolbar` is optional on decode (absent = false). Model command `setToolbarShown(windowID:_:)`, no undo (window chrome, like `sidebarMode`), then the debounced snapshot save.
- A new standard window (Cmd+N) copies the key window's value (guess). Little Open windows never show it: `toggle-toolbar` is disabled there.

#### 4.6.2 The bar (`PaneChromeView` on a single pane, D8)

| Part | Value | Mark |
|---|---|---|
| Height | 32 (`SplitMetrics.barHeight`; Arc `toolbar-display-height` default 32) | decoded (CC-33) |
| Frame | The top 32 pt of the pane slot, inside its clip (radius 6); the page gets the rest | same as splits |
| Fill | The page's reported background color, else the Space's `light.background`, else white | measured on F0081 (IS §11) |
| Left | Back `[5, 4, 32, 24]`, forward `[42, …]`, reload or stop `[79, …]` (`SplitMetrics`) | measured F0081 |
| Center | Copy-link button 24 pt, 3 pt gap, the host (or the full URL, below), centered on the bar (existing centered group) | measured F0081 |
| Right | An extensions button slot `[W − 37, 4, 32, 24]` (the close button's place) that the extensions UI plan fills, then Site Control Center `[W − 73, 2, 32, 28]`. While the slot is empty (until that plan lands), Site Control Center sits at `[W − 37, 2, 32, 28]`. No split menu, no close. | CC-34 (`contentToolbarOpenExtensionsButton`); positions guess |
| URL text | Host without `www.` (existing); with `open.advanced.showFullURLWithToolbar` on: the full `absoluteString`, tail truncation | CC-37; full form guess |
| Click on the URL group | Opens the command bar in `.editCurrentURL` (Cmd+L) | derived (`commandBarToolbarButton`, CC-34) |
| Right-click on the bar | Menu: "Show Full URL" or "Hide Full URL", "Hide Toolbar", separator, "Manage Extensions" | CC-36; order guess |

In a selected split, every pane keeps its own bar (no change). The toolbar flag only adds the bar to the single-pane case. Peek is unchanged.

#### 4.6.3 Next to the sidebar URL field

| Toolbar | Sidebar | Mark |
|---|---|---|
| Hidden | As today: URL field `[8, 46, W − 16, 36]`, back, forward, reload | — |
| Shown | The URL field hides; back, forward, and reload hide (the toggle stays, as for a selected split); Favorites start at y 46 instead of 82 | derived from CC-36 "Show as Toolbar"; layout guess (§9 item 1) |

Right-click on the sidebar URL field (new menu): "Show as Toolbar", separator, "Manage Extensions" (CC-36; order guess). New `SidebarIntent` cases: `.setToolbarShown(Bool)`, `.setShowFullURL(Bool)`, `.manageExtensions`. `ModelSidebarActions` handles `.setToolbarShown` (model command). The App handles the other two.

The hover-reveal card follows the same rule (no URL field while the toolbar shows). With the sidebar hidden, the toolbar is the only URL and navigation UI, which is the main reason to turn it on.

#### 4.6.4 Menu and keys

- View ▸ Show Toolbar / Hide Toolbar, Cmd+Shift+D (`toggle-toolbar`, exists). The title follows the key window's state (CC-32).
- New `CommandDispatcher` requirement with a default: `func menuTitle(for id: String) -> String?` (default nil). `MenuBuilder` validation sets the item title when it is not nil. The App returns "Show Toolbar" / "Hide Toolbar" for `toggle-toolbar` and "Show Sidebar" / "Hide Sidebar" for `toggle-sidebar` (CC-32 has the same pair for the sidebar).
- `expected-menu.json` keeps "Show/Hide Toolbar" as the reference title; `commands-dump` compares the static title and separately checks that the hook changes it (§5.1).

#### 4.6.5 Timing and performance

No animation (D11). The toggle changes the container layout once; Chromium resizes the page once. The bar has no timers; its text updates on URL and loading changes only (existing `PaneChromeView.update`).

### 4.7 Registry ids and keys

| Id | Title | Default key | Menu | New? | Handler |
|---|---|---|---|---|---|
| `toggle-toolbar` | Show/Hide Toolbar (runtime: Show Toolbar / Hide Toolbar) | Cmd+Shift+D | View | exists | App: `setToolbarShown` on the key window |
| `toggle-sidebar` | Show/Hide Sidebar (runtime: Show Sidebar / Hide Sidebar) | Cmd+S | View | exists | title hook only |
| `keyboard-shortcuts-edu` | Essential Keyboard Shortcuts | — | Help | exists | App: show the window |
| `show-shortcuts-overlay` | Show Shortcuts While Holding Command | — | — | exists | none: stays disabled (no hints, D13, CC-39) |
| `search-actions` | Search Actions | — (customizable) | — | new | App: present `.searchActions` |
| `search-tabs` | Search Tabs | — (customizable) | — | new | App: present `.searchTabs` |
| `go-to-tab-1…9` | Go to Tab N | Cmd+1…9 | — | exists | app-shell Step C; must use `goToItemTargets` (D7) |

`search-actions` and `search-tabs` join the `SuggestAdapter` exclusion list (they make no sense as command bar rows; the keywords enter the scopes). `commands-dump` must stay at `missing=0 extra=0 different=0`, seed coverage 79/79, and no new conflicts.

### 4.8 (i) privacy footer (CC-42, D14)

The (i) button shows Arc's search-suggestion privacy notice as a footer inside the bar. It is the notice that features-core §4.5 rule 13 decodes (`SearchSuggestionsPrivacyView`), with the same first line.

Layout, measured on S2 18/0044 (a 5-row panel, height 329, at window `[481, 373]`; panel points, `H` = panel height, `W` = 766):

| Part | Value | Mark, evidence |
|---|---|---|
| Band | Black, `[0, H − 61, W, 61]`, clipped by the panel corner (window y 641…701; the panel's bottom edge is y 702) | measured (pixels `#000000` across the band) |
| Panel and list | The panel frame does not change. The list keeps its frame but its visible area ends at the band top, so the last visible row goes behind the band (5 rows → 4 visible); the list still scrolls to every row. Panels shorter than 2 rows grow by 61 pt so the footer never covers the only row (guess) | measured for 5 rows (AX table frame unchanged between 0043 and 0044); short panels guess |
| (i) button | Hidden while the footer shows; the field gets its 42 pt back (field width 656 → 698) | measured (AX field width; no (i) in the image) |
| Icon | SF Symbol `info.circle`, 13 × 13 at `[18, H − 37]`, white 0.5 | frame measured (AX `info.circle`); color fitted (core #767676; Step 0) |
| Line 1 | "We talk to your search engine to help us suggest results." at `[46, H − 48]`, **13 Bold**, white ≈ 0.93 | text and frame measured (AX 365 × 16); Step 0 fit: ink width 364 px and ink mass match 13 Bold (Semibold is 356 px); color ΔE00 0.09 |
| Line 2 | "Learn more about your data on Open " + link "here" + "." at `[46, H − 30]`, 13 Regular, white 0.5; "here" in the same color, underlined, pointer cursor | text measured (AX); "Arc" becomes "Open" (naming rule); size and color fitted (core #7A7A7A; Step 0) |
| "Search Settings…" | Button `[W − 223.5, H − 49.5, 132, 37]` | measured (AX) |
| "Dismiss" | Button `[W − 82.5, H − 49.5, 72, 37]`: 9 pt after "Search Settings…", 10.5 pt from the panel's right edge | measured (AX) |
| Button look | Fill `#302F63`, 1 pt edge `#6362AD`, radius 8 continuous (visual), title 13 Regular, white 0.9 | fill measured; Step 0: the buttons sit on half points, so the edge covers two pixels at half strength (one pixel reads `#494988`); the pair solves to `#6362AD`; title fitted on ink widths 104 and 45 px and core color |
| Light appearance | Not captured. Use the same layout; band `CommandBarColors.bannerBackground` light (`#FDFDFE`), dark text (guess) | guess |

Behavior:

| Event | Result | Mark |
|---|---|---|
| Click (i), or Cmd+I while the field has focus | Show the footer (no animation, like the panel, D12). Cmd+I again hides it. | (i) measured; Cmd+I Open rule (it already maps to (i)) |
| The bar opens (any mode, any notice state) | No footer. The footer opens only on (i) or Cmd+I. The existing Settings gate is unchanged: remote suggestions stay off while `open.general.searchSuggestNoticeDismissed` is false (`prepareForRemoteSuggestions`, `docs/settings.md`) | lead ruling 2026-10-26: no capture shows the footer unasked; §9 item 9 asks for one |
| "Dismiss" | Hide the footer, set `open.general.searchSuggestNoticeDismissed = true` (the Settings "Code 4" key; no new key), and re-run the current query so remote rows can arrive | text measured; key reuse Open rule |
| "Search Settings…" | New intent `.openSearchSettings(profileID:)`: the bar closes; the App runs the existing `search-settings` command (Step 0; #85 opens Settings on its General pane). Step 9 points that command at the search engine section of the bar's Profile in Settings ▸ Profiles | target not captured; Open choice (Open keeps search engines in Profiles) |
| "here" | `.open(CommandBarText.privacyURL, .newTab, [])`; the URL is Open's privacy page, owned by `docs/plans/release.md` (until it exists the link is hidden, not dead) | Open choice |
| Esc | Closes the bar (one press, as today); the footer goes with it | existing rule |
| Typing, Up, Down, Return | Unchanged; the footer stays until "Dismiss", Cmd+I, or close | guess |

API: `CommandBarIntent.showHelp` is removed (the bar handles (i) itself). New intent `.openSearchSettings(profileID: ProfileID)`. Both are source-breaking for the App's exhaustive switch in `App/CommandBar/AppCommandBarDelegate.swift`; Step 0 edits that file in the same PR (§6). The controller reports `didDismissPrivacyNotice` through the delegate so the App writes the key. `CommandBarRequest` gets no notice field: the bar never opens the footer by itself. AX: the footer is a group "Search suggestions privacy" with two static texts, a link "here", and the two buttons.

### 4.9 Open and close: no animation (CC-44, D12)

| Event | Result |
|---|---|
| `present` | The panel, its shadow, its rows, and the field show in the next frame at full size and alpha 1. |
| `dismiss` | The panel and its shadow go in the next frame. |

Delete `Motion.commandBarOpen`, `commandBarOpenScale`, `commandBarClose`, and `commandBarCloseScale` (`OpenDesign/CommandBarTokens.swift`) and the Core Animation code that uses them in `CommandBarView.swift` (scale and fade). Set the panel's frame and `isHidden` inside a `CATransaction` with actions disabled, so no implicit animation runs. Arc's AX shows a collapsed field (width 2) during a close (S2 18/0029, 0047); that is internal layout state with no visible frame, and Open does not reproduce it. `docs/commandbar.md` §5 is updated in the same step. PR #104's follow-up list also names this change; if #104 lands it first, Step 0 only adds flow 87 and the compare rows.

### 5.1 Harness checks (no unit tests; all run the real code paths)

`openkit suggest-check` — new scenarios (32 onward):

| # | Scenario |
|---|---|
| 32 | `googl` + open tab on that host, completion on → top hit the tab (T3a), `fieldText` = host, `typedLength` 5 |
| 33 | Same with completion off → no completion; top hit by the old rules |
| 34 | `Google` = tab title → T5, completion lower-case host (CC-6) |
| 35 | `google.co` → T3a with completion on; T3 typed URL with it off |
| 36 | Whole host typed → T3, no completion (F0061) |
| 37 | Path rule: `github.com/op` → full URL; `gith` → host only; `github.com` → none; `localhost:30` keeps the port; `https://goo` keeps the scheme |
| 38 | No completion for remote rows, `file:` URLs, arithmetic, whitespace, scopes |
| 39 | Current tab: offered in new-tab mode, absent in edit mode |
| 40 | History carry-over: `gi` → `git` keeps the history completion row in snapshot 0 |
| 41 | Split: one row per split; any pane title matches; exact pane title → T5; history for a pane URL folds in; edit mode leaves out the current split |
| 42 | Actions mode: empty query lists seed order; `side` → Show/Hide Sidebar top hit; requirements still hide |
| 43 | Scope keywords: `actions` and `tabs` give scope hints; `act` and `tab vs` do not; a site keyword still gives its site hint |
| 44 | Performance: first snapshot p95 < 5 ms with 5,000 tabs incl. 500 two-pane splits and completion on; completion check p95 ≤ 0.05 ms |

`commandbar-render` — new scenes (`render --state`): `completion`, `completion-case`, `completion-accepted`, `split-row`, `split-row-selected`, `actions-scope`, `actions-scope-empty`, `tabs-scope`, `scope-chip-hover`, `site-chip` (re-drawn to §4.3.6), `site-chip-query`, `privacy-footer`, `privacy-footer-light`. New flows (69 onward; real key events through the window and the field editor):

| # | Flow |
|---|---|
| 69 | Typing `gi` → `git` → `gith`: completion follows in the same frame as each snapshot; field = host; selection = tail; no undo entries |
| 70 | Matching character keeps the completion without a frame where it disappears (check every applied snapshot and every field change) |
| 71 | Non-matching character replaces the completion |
| 72 | Backspace removes only the completion; `userText` unchanged; re-query with completion off; top hit becomes the typed URL for a URL-like text |
| 73 | Second Backspace deletes a typed character; no completion returns until the next insertion |
| 74 | Right / End / Cmd+Right accept; Left / Home make the text typed with the caret where the key says |
| 75 | Down hides the completion; Up restores it; no query |
| 76 | Return opens row 1 (the completion row); pending Return waits for the first snapshot and uses its completion |
| 77 | Paste never completes; Cmd+A and a click make the completion typed text |
| 78 | Tab with a hint enters Site Search from `userText`; Space with a completion types a space |
| 79 | IME: marked text removes the completion first; no completion while marked; commit at the end allows one |
| 80 | Cmd+L: typing replaces the URL, then completes |
| 81 | Split row: one row, AX label lists both titles, Return → `.switchToTab(paneID)` of the matched pane |
| 82 | `actions` + Tab → Actions chip, placeholder "Search…"; Backspace on empty → field `actions`, scope gone |
| 83 | `tabs` + Tab → Tabs chip; split rows show; Esc closes |
| 84 | Chip close glyph on hover; click → same as Backspace on empty |
| 85 | `search-actions` present → scope set; Backspace on empty → `.newTab`, empty field |
| 86 | AX: field value = whole text; selected text range = completion |
| 87 | Present and dismiss: the panel is fully drawn at alpha 1 in the first frame after `present` and gone in the first frame after `dismiss`; no layer of the bar has an animation key (CC-44) |
| 88 | Click (i): footer shows, (i) hides, field width +42; the list's visible area ends at the band top; Cmd+I hides the footer again; no window opens (CC-42) |
| 89 | Footer "Dismiss": footer hides, the delegate gets `didDismissPrivacyNotice`, the current query re-runs. `present` in every mode shows no footer, also while the notice was never dismissed |
| 90 | Footer "Search Settings…" sends `.openSearchSettings(profileID)`; "here" sends `.open(privacyURL, .newTab, [])`, or is hidden while `privacyURL` is nil |
| 91 | `wikipedia` + Tab: chip frame `[54, 20, 81, 24]` ± 0.5, fill `siteSearchChip`, no icon, field x 146, placeholder "Search…"; typing `bird` selects a row with the chip fill; Backspace on empty restores `wikipedia` (CC-41) |

`commandbar-render check` must pass every old and new flow, render every state, and keep the keystroke budget.

`sidebar-render` — scenes `toolbar-shown` (no URL field; nav buttons hidden; Favorites at y 46), `url-field-menu`. Check: a synthesized Command `flagsChanged` event with the sidebar visible changes no view (no layout, no redraw, `SidebarDiagnostics.fullReloads` = 0); `bench`: scroll p95 unchanged.

`openkit commands-demo` — new checks N1–N7: `goToItemTargets` for 7 permutations (favorites on/off, ninth on/off, collapsed folder, peeked folder, collapsed pinned) against hand-written expected lists.

`features-render` — scenes `toolbar-single` (host), `toolbar-full-url`, `toolbar-split` (unchanged split bars), `toolbar-menu`. Checks: page frame = slot − 32; control frames equal the split bar's for the same width; the bar takes the page color.

`settings-preview` — scenes `essential-shortcuts` (light, dark), `essential-shortcuts-custom-key` (an override shows), `shortcuts-callout`; check: the callout button calls the open callback; the list has every active command (no `basics` filter).

`commands-dump` — new ids registered; no conflicts; adapter exclusions; title hook: with a fake dispatcher, `toggle-toolbar` shows "Show Toolbar" and then "Hide Toolbar".

### 5.2 Comparison with Arc captures (`commandbar-render compare`, method of `docs/design.md` §7)

Targets: position ≤ 1 pt, ΔE00 ≤ 2. Scene files that copy capture titles stay in `.re/` (they hold personal data). Favicons are masked as in `docs/commandbar.md` §8.

| Capture | Scene | Elements |
|---|---|---|
| F0043 | completion, 5-letter typed prefix, open-tab row 1 | typed text, completion selection box, selected text, leading favicon, hint group ("Tab" only), row 1 selection and accessory, row 2 typed search |
| F0062 | completion with candidate case | same, plus the case rule |
| F0061 | accepted completion, caret at the end | field text, caret, row 1 navigate row without subtitle |
| A0120 | split row (row 3) | plate, gap, both pane icons (masked content, box only), title start, title rule, accessory |
| S2 18/0009 | completion in a blue Space (window 1728 × 1084) | typed text, completion selection box, hint group "Search Wikipedia" + [Tab], leading favicon (masked) |
| S2 18/0016 | Site Search chip, empty field, no rows | chip frame and fill, chip text ink, glow at 4 pt and 8 pt outside the chip, placeholder origin, panel height |
| S2 18/0018 | Site Search with a query | chip, field text, selected row fill (`siteSearchChip`) |
| S2 18/0044 | privacy footer on a 5-row panel | band frame and fill, icon, both text lines (ink boxes), both buttons (frame, fill, edge), field width without (i) |
| F0063, F0048, F0061, F0052, F0058, F0055, A0327, A0120 | the eight existing scenes | must keep their `docs/commandbar.md` §8.1 numbers |

No capture exists for the Actions and Tabs scopes, the Essential Keyboard Shortcuts window, or the toolbar on a single pane. (Hold-Command badges are not built, D13.) Frames S2 18/0009–0018 also show one of the user's own Spaces: mask the sidebar and page, and keep their scene files in `.re/`. For the toolbar, compare the `toolbar-single` render's control frames and fills with the F0081 pane bar (same component, IS §11). The others are Open design until the captures in §9 exist.

### 5.3 App end-to-end (`tools/e2e/engine_e2e.py`, after Step 9)

Automation additions (`App/Automation/AutomationController.swift`), only these:

| Command | Returns or does |
|---|---|
| `commandbar` | `{open, mode, scope, fieldText, userText, selection: [location, length], footer, rows: [{kind, title, accessory}]}` |
| `commandbar-press` | `control` = `info`, `dismiss`, `searchSettings`: performs that control's AX press action in the bar (real code path, no desktop input) |
| `flags` | `modifiers`, `down` / `up`: posts a `flagsChanged` event through `NSApplication.sendEvent` |
| `perform` | `id`: `CommandDispatcher.performCommand(id)` on the key window (skip if app-shell Step C already added it) |
| `windows` | adds `toolbar` (Bool) and `level` per window |

Checks (extend the `commandbar` suite; add `toolbar` and `numbering` suites):

| Suite | Check |
|---|---|
| `commandbar` | Visit `http://localhost:<fixture port>/alpha` twice; Cmd+T; type `localh` (`key route=app`); `commandbar` shows `fieldText` = `localhost:<port>`, selection = the tail; Return opens or switches to that page (`tabs`) |
| `commandbar` | Backspace: `fieldText == userText`; row 1 is the typed URL |
| `commandbar` | `split` two fixture tabs; Cmd+T; type the second pane's title; one row with "Switch to Split View"; Return: `tabs` shows the split selected and that pane focused |
| `commandbar` | Type `actions`, Tab, `side`, Return: the sidebar hides (`windows`) |
| `commandbar` | First results ≤ 50 ms after Cmd+T (existing check, rerun with completion on) |
| `toolbar` | Cmd+Shift+D: `windows.toolbar` true; `eval window.innerHeight` shrinks by 32; `snapshot` vs the `features-render` scene within targets; View menu title reads "Hide Toolbar"; relaunch keeps it; a Little Open window refuses the command |
| `commandbar` | Fresh data dir (notice not dismissed, suggestions on): Cmd+T → `commandbar.footer` false (never unasked); `commandbar-press control=info` → footer true; `commandbar-press control=dismiss` → footer false and `defaults key=open.general.searchSuggestNoticeDismissed` true; Cmd+T, `key i modifiers command` → footer true; `windows` count unchanged (no window opened) |
| `commandbar` | `commandbar-press control=searchSettings` → bar closed, `windows` lists Settings on the Profiles pane |
| `commandbar` | Cmd+T then `snapshot` in the same runloop turn after the key: the panel is fully drawn (no partial alpha, compare with a later `snapshot`, max channel difference ≤ 2) |
| `numbering` | `flags command down`, wait 2 s, `snapshot` equals a snapshot taken before the press (no badges); `key 2 modifiers command`: item 2 of `goToItemTargets` is selected (`tabs`) |
| `numbering` | `perform keyboard-shortcuts-edu`: `windows` lists "Essential Keyboard Shortcuts" at floating level; `key escape` closes it |
| `measure` | Idle CPU unchanged |

### 5.4 Performance gates

| Gate | Budget | Where |
|---|---|---|
| First snapshot, 5,000 tabs incl. 500 splits, completion on | p95 < 5 ms | `suggest-check` 44 |
| Completion check per snapshot | p95 ≤ 0.05 ms | `suggest-check` 44 |
| Keystroke → rows drawn (existing bench) | p95 ≤ 8 ms | `commandbar-render bench` |
| Completion keystrokes (new `bench --completion`: the 30 queries typed against a history that completes them) | p95 ≤ plain bench + 0.3 ms; panel layout passes per keystroke ≤ 1 | `commandbar-render bench --completion` |
| Cmd+T → first results in the real app | ≤ 50 ms | e2e `commandbar` |
| Cmd+T → panel fully drawn | first frame after the key (no animation, D12) | flow 87; e2e `commandbar` |
| Sidebar scroll, 1,000 rows | p95 unchanged ± 10 % | `sidebar-render bench --rows 1000` |
| Idle CPU | unchanged | e2e `measure` |

## 6. Implementation order

One PR per step. Each PR: merge `origin/main`, run `tools/verify-all.sh`, paste its table (AGENTS.md rule 10). Steps 0–8 are library work and can start now. Step 9 waits for app-shell Step C (command bar, menus, and keys in the App).

| Step | Work | Files | Acceptance |
|---|---|---|---|
| 0 | Capture fixes in the bar: delete the open/close animation (§4.9); the (i) privacy footer, `.openSearchSettings`, `didDismissPrivacyNotice`, removal of `.showHelp` (§4.8); the App's switch over `CommandBarIntent` follows in the same PR | `OpenCommandBar/PrivacyFooterView.swift` (new), `CommandBarView.swift`, `CommandBarController.swift` (the (i) and Cmd+I handlers that send `.showHelp` today), `CommandBarTypes.swift`, `InputRowView.swift`, `ResultsView.swift`; `OpenDesign/CommandBarTokens.swift`; `commandbar-render` `Flows.swift` and `ReviewFlows.swift` (the two checks that expect `.showHelp`), scenes `privacy-footer*`, flows 87–90; **App:** `App/CommandBar/AppCommandBarDelegate.swift` (merged in #85: its exhaustive `switch` over `CommandBarIntent` has `case .showHelp` at line 97, which opens `AppCommand.helpURL`). Delete that case; add `case .openSearchSettings(let profile)`, which runs the existing `search-settings` command (`factory.controller?.performCommand("search-settings", payload: profile.description)`); implement `didDismissPrivacyNotice` as `factory.app.settingsPresenter.settings.profiles.dismissSuggestNotice()` (the Settings writer of `open.general.searchSuggestNoticeDismissed`). No other App file switches over `CommandBarIntent`; the other App users of the bar (`EngineWebContentHostFactory.showCommandBar`, `AppCommandBarSession.stateForAutomation`, `didChangePresentation`) do not change. `AppCommand.helpURL` stays (the Help menu and Settings still use it). `docs/commandbar.md` §2, §4, §5, §11 | `commandbar-render check` all pass (old flows 31–34 and 45–51 updated for the footer instead of `.showHelp`); S2 18/0044 compare within targets; the eight §8 comparisons unchanged. **The App build is part of this step's acceptance, not only the package build:** `~/Library/Caches/OpenRE/scripts/heavy.sh tools/build.sh Debug` exits 0, and `tools/e2e/engine_e2e.py --only commandbar` passes (it builds on that App). `tools/verify-all.sh` builds only the package, so it cannot catch a broken App switch |
| 1 | Engine completion: `allowsInlineCompletion`, `InlineCompletion`, rule T3a, current tab in Cmd+T, history carry-over; `openkit suggest --completion` | `OpenSuggest/InlineCompletion.swift` (new), `SuggestTypes.swift`, `Ranking.swift`, `Providers.swift`, `SuggestEngine.swift`; `openkit` suggest commands; `docs/suggest.md` | `suggest-check` 1–40 and 44 (completion half) pass; first snapshot p95 within 10 % of today |
| 2 | Bar completion UI: `CompletionSession`, editor hooks, §4.1.4–4.1.8 | `OpenCommandBar/CompletionSession.swift` (new), `CommandBarController.swift`, `InputRowView.swift`; `commandbar-render` scenes, flows 69–80 and 86, `bench --completion`; `docs/commandbar.md` | `commandbar-render check` all pass; F0043, F0062, F0061 compare within targets; old §8 numbers unchanged; bench gates |
| 3 | Engine split rows (§4.2.1) | `OpenSuggest/TabIndex.swift`, `Providers.swift`, `Ranking.swift`, `SuggestTypes.swift`; synthetic world with splits; `docs/suggest.md` (close Q1) | `suggest-check` 41 and 44 pass |
| 4 | Split row drawing (§4.2.2) | `OpenCommandBar/Presentation.swift`, `ResultRowView.swift`, `ResultsView.swift`; `OpenDesign/CommandBarTokens.swift`; scenes and flow 81; `docs/commandbar.md` §8.3 row removed | A0120 split row within targets; `check` passes |
| 5 | Scopes (§4.3) and the captured chip look (§4.3.6) | `OpenSuggest/SiteSearch.swift`, `Providers.swift`, `Ranking.swift`, `SuggestTypes.swift`; `OpenCommandBar/ScopeChip.swift` (new), `CommandBarController.swift`, `CommandBarTypes.swift`, `InputRowView.swift`, `ResultRowView.swift` (scope selection fill); `OpenDesign/CommandBarTokens.swift` (chip tokens); `OpenCommands/CommandRegistry.swift`, `SuggestAdapter.swift`; `docs/commands.md`, `docs/commandbar.md` §11 q5 | `suggest-check` 42–43; flows 82–85 and 91; S2 18/0016 and 0018 compare within targets; `commands-dump` exit 0 |
| 6 | Essential Keyboard Shortcuts window, Shortcuts callout fix (no hints toggle, D13) | `OpenSettings/EssentialShortcutsWindow.swift` (new), `ShortcutsPane.swift`, `SettingsTypes.swift`; `settings-preview` scenes; `docs/settings.md`, `docs/plans/settings-library.md` row | `settings-preview check` passes with the new scenes |
| 7 | Numbering only (§4.4; no badges, D13) | `OpenModel/GoToItemNumbering.swift` (new); `openkit commands-demo` checks N1–N7; `sidebar-render` Command-press check | N1–N7 PASS; the `sidebar-render` Command-press check passes; scroll bench unchanged |
| 8 | Toolbar library (§4.6) + menu title hook | `OpenModel/Containers.swift`, `BrowserModel.swift`; `OpenStore/SnapshotDTOs.swift`; `OpenFeatures/PaneChromeView.swift`, `WebContentContainer.swift`, `BrowserWindowController.swift`; `OpenSidebar/ChromeViews.swift`, `SidebarView.swift`, `SidebarMenus.swift`, `SidebarIntent.swift`, `ModelSidebarActions.swift`; `OpenCommands/MenuBuilder.swift`; harness scenes | `features-render`, `sidebar-render`, `commands-dump`, `roundtrip` (old snapshots decode) pass |
| 9 | App wiring: `.switchToTab` for panes, scopes, `.openSearchSettings`, the dismissal key, `toggle-toolbar`, `keyboard-shortcuts-edu`, `search-actions`, `search-tabs`, `menuTitle`, the full-URL setting, go-to-tab via `goToItemTargets`; automation additions | `App/CommandBar/AppCommandBarDelegate.swift`, the App `CommandDispatcher` extension, `App/AppDelegate.swift` (EDU window), `App/Automation/AutomationController.swift`, `tools/e2e/engine_e2e.py` | e2e `commandbar`, `toolbar`, `numbering`, `measure` checks in §5.3 pass; `--only shell` and `window` still pass |
| 10 | Docs and status | `docs/status.md` (gaps 22–26 → done), `docs/commandbar.md` §10 gaps 2–4 closed | review only |

## 7. Risks

| Risk | Mitigation |
|---|---|
| The completion flickers when snapshots change row 1 | D2 plus history carry-over (§4.1.3) and the matching-character rule (§4.1.5); flow 70 checks every applied snapshot |
| Writing text into the field editor re-enters `controlTextDidChange` | A guard flag in `CompletionSession` while applying; flows 69 and 86 count queries |
| AppKit's selection rect for a partial range differs from Arc's (like the 2 pt Cmd+L difference) | Measure in Step 2; if > 1 pt, record it in `docs/commandbar.md` §8.3 and do not hand-draw the selection |
| Rule T3a changes Return for URL-like text | Only with a strong tab or history row, and only until Backspace; `suggest-check` 35–36 pin the table in §4.1.3 |
| Go-to-tab numbering differs from what app-shell Step C builds | D7: Step 9 switches the key handler to `goToItemTargets`; the e2e `numbering` check presses Cmd+2 against `goToItemTargets` |
| Remote suggestions stay off until the user dismisses the notice, and the bar never shows it by itself | Existing Settings gate (Code 4): Settings ▸ Profiles presents the notice on first appearance, and the (i) footer reaches it from the bar. Flow 89 and the e2e `commandbar` check prove that "Dismiss" turns suggestions on at once. §9 item 9 asks whether Arc shows it unasked |
| Hiding the sidebar URL field with the toolbar is wrong for Arc | One token (`showsURLFieldWithToolbar = false`); §9 item 1 asks for the capture |

## 8. Open questions (each has a default; build the default)

| # | Question | Recommendation (default) |
|---|---|---|
| Q1 | Hold-Command hints: on by default, and on which items? | **Answered by capture (CC-39): no hints.** Arc shows none after 2–4 s. Open builds none (D13); only the numbering stays. |
| Q2 | How does a user enter the Actions scope? Arc's gesture is not proven (CC-20). | Keyword `actions` + Tab, plus the unbound `search-actions` command. Do not add a bare Control-key trigger. |
| Q3 | Does the sidebar URL field hide while the toolbar shows? | Yes ("Show as Toolbar", CC-36). Favorites move up to y 46. |
| Q4 | Toolbar show/hide animation? | None (D11). |
| Q5 | Toolbar per window, and does Cmd+N inherit it? | Per window (CC-34); a new window copies the key window. |
| Q6 | Does the field show the candidate's letter case (CC-6, one frame)? | Yes, as Arc does in F0062. `userText` keeps the user's case. |
| Q7 | Left arrow with a completion? | Native: the completed text stays, caret at the selection start. Session 2 measured Backspace only (CC-40); Right and Left stay open (§9 item 5). |
| Q8 | Arc's Copy URL strips trackers (CC-31). | Out of this plan. The window text says "Copy the current tab's URL". File a follow-up for tracker stripping in `copy-url`. |
| Q9 | What do the (i) button and Cmd+I open? | **Answered by capture (CC-42): an inline privacy footer in the bar** (§4.8), not a window. The Essential Keyboard Shortcuts window keeps its other entries (§4.5.3). |
| Q10 | Split row icon for 3–4 panes and vertical splits? | 15 pt cells in a row, or stacked in a 30×30 plate for vertical. Refit when captured. |
| Q11 | Remove the Shortcuts pane `basics` filter (CC-30)? | Yes. The settings-library plan owner confirms in the Step 6 PR. |
| Q12 | Offer the current tab as "Switch to Tab" in Cmd+T? | Yes (`docs/suggest.md` "Input"; F0063, F0043). |
| Q13 | When does Arc offer "or Space" for a whole host (F0040 yes, F0061 no)? | Keep Open's current rule (exact name, host, or keyword) when no completion shows. |
| Q14 | Does the footer show unasked before the first remote suggestion? Session 2 could not show it (Arc had stored an earlier dismissal). | **Decided 2026-10-26 (lead ruling): no.** The footer opens only on (i) or Cmd+I; nothing in the capture shows it unasked. §9 item 9 is the capture request. |
| Q15 | Is the Site Search chip color per site? One sample (Wikipedia, `#FFA000`). | One token for every site and for the Actions and Tabs chips. One more capture with another site settles it. |

## 9. Screenshots needed from the user

Agents must not launch or drive Arc (AGENTS.md rules 4–5). These need the user, with the recorder running (`docs/re/runtime-observations.md` §7). One frame after each step is enough.

1. Toolbar: View ▸ Show Toolbar (Cmd+Shift+D) on a normal tab, then the same with Settings ▸ Advanced ▸ "Show full URL when Toolbar is enabled" on. Shows the bar, the sidebar top, and where Favorites sit.
2. Right-click on the sidebar URL field, and right-click on the toolbar URL (menu items and order).
3. Done in session 2: no badges (CC-39).
4. Help ▸ Essential Keyboard Shortcuts (the window).
5. Command bar: type 4 letters of a host you have open, then press Right arrow once, and (after retyping) Left arrow once, one frame after each key. Backspace is done (CC-40).
8. Site Search on a second site (for example YouTube): the chip color (Q15).
9. On an Arc install where the search-suggestion notice was never dismissed (for example a fresh macOS user account; do not reset the user's own Arc preferences): open the command bar and type a few letters. Does the privacy footer appear without a click (Q14)?
6. A command bar list that shows a three-pane split and a vertical split.
7. Command bar: type a full host (for example a site you have not opened today) and stop; then type the same host again after visiting it (the "or Space" difference, Q13).

## Appendix — Lead decisions (2026-10-26)

- Approved as the command bar completion plan.
- Q1 Hold-Cmd hints are on by default, for every Cmd+1…9 target. No hints while the sidebar is hidden.
- Q2 The Actions scope opens with `actions` + Tab, plus an unbound `search-actions` command. No bare Control trigger.
- Q3 The sidebar URL field hides while the toolbar shows ("Show as Toolbar").
- Q4 The toolbar has no animation: one page resize.
- Q5 The toolbar setting is per window. A new window copies the key window's setting.
- Q6 The field shows the candidate's letter case (F0062).
- Q7 Left arrow with a completion uses native behavior: keep the text and put the caret at the selection start.
- Q8 Stripping trackers from copied URLs is a separate follow-up.
- Q9 The (i) button and Cmd+I open the Essential Keyboard Shortcuts window.
- Q10 The split icon uses 15 pt cells for 3–4 panes and vertical splits. Refit it when it is captured.
- Q11 Remove the Shortcuts pane's `basics` filter.
- Q12 Cmd+T offers the current tab.
- Q13 Keep the current "or Space" rule for a whole host.
- The screenshots go into the user's single combined Arc capture session.

## Appendix — Lead decisions (2026-10-26, capture session 2)

These supersede the entries above where they conflict. Evidence: `docs/re/commandbar-completion.md` §8 (CC-39…CC-44), `docs/re/capture-session-2-results.md` C13, C14, C20.

- Q1 superseded: holding Command shows **no** hints, as Arc does (CC-39, S2 18/0001–0003). Open builds no badges, no flags monitor, and no hints setting; `show-shortcuts-overlay` stays registered and disabled. The Cmd+1…9 numbering (`goToItemTargets`) stays.
- Q9 superseded: the (i) button and Cmd+I show Arc's inline privacy footer in the bar ("We talk to your search engine…", "Search Settings…", "Dismiss"), not the Essential Keyboard Shortcuts window (CC-42, S2 18/0044). "Dismiss" writes the existing `open.general.searchSuggestNoticeDismissed` key.
- Q14 (lead ruling): the footer opens **only** on (i) or Cmd+I. It never shows by itself; no capture shows that. Capture request §9 item 9.
- New (D12): the command bar has **no** open or close animation (CC-44, V 9.70–14.20 s). The open spring and close fade are deleted. This replaces the provisional motion in `docs/commandbar.md` §5.
- Inline completion and the Site Search chip follow the capture: completed part selected, Backspace removes only it (CC-40); the chip is an orange text-only capsule with the placeholder "Search…" and an orange scoped selection (CC-41). Right and Left arrow rules stay guesses until a frame isolates them.

## Verification (Section 2, 2026-10-29)

The Section 2 agent implements this plan. Each row names the merged PR and its evidence. Load averages are written with every timing receipt (the M5 also runs other projects).

| Step | PR | Evidence | Result |
|---|---|---|---|
| 0 | [#137](https://github.com/SergeSerb2/open/pull/137) | `commandbar-render check` 91/91 (flows 87–90; the 9 existing states render pixel-identical to `main` at 2x, scene path identical too); S2 18/0044 compare in Display P3: 13 footer elements ≤ 1 pt and ΔE00 ≤ 0.62; App build; e2e `commandbar` 54/54 incl. `commandbar_no_open_animation`, `_no_close_animation`, `_info_shows_footer`, `_footer_dismiss`, `_cmd_i_footer`, `_footer_search_settings`; break-and-revert: an added 0.13 s fade fails flow 87 and the App row (panel opacity 0.07 right after Cmd+T), no list occlusion fails flow 88, a footer kept across `present` fails flow 89 | done |

| 1–2 | [#138](https://github.com/SergeSerb2/open/pull/138) | `suggest-check` 44/44 (scenarios 32–40, 44: completion first snapshot p95 0.446 ms vs plain 0.511, check p95 0.0116 ms, load 10); `commandbar-render check` 112/112 (flows 69–80, 86 with 17 checks; completion budget p95 +0.097 ms at load 5.4 and +0.079 ms at load 9.6, layout passes mean 0.11 on and off, max 1); compares F0043/F0062/F0061 worst 1.0 pt, ΔE00 1.93; S2 18/0009 completion box, text, and hint ≤ 1 pt, ≤ 1.37; pixel diff of the 10 states against `main` (only the intended changes, `docs/commandbar.md` §8.1); App build; e2e `commandbar` 55/55; break-and-revert: 8 extra field writes per show fail the budget (+0.912 ms), one forced panel layout per show fails the layout rule (mean 0.65 vs 0.11) | done |

| 3–4 | [#139](https://github.com/SergeSerb2/open/pull/139) | `suggest-check` 45/45 (scenario 41; 44 now with 500 two-pane splits: completion first snapshot p95 0.444 ms, plain 0.513, load 11); `commandbar-render check` 119/119 (flow 81, 5 checks); A0120 compare: split plate cells 0.0 pt / 1.04, gap 1.05, title parts 0.0 / ≤ 0.09, rule 1.0 / 0.59, worst over the scene 1.0 pt and 2.11 (left shadow); pixel diff of 13 states × 2 scales against `main`: only `empty` and `privacy-footer` change (the split row), plus two `main` renders with a black lower band (item 13); App build; e2e `commandbar` 56/56 incl. new `commandbar_split_one_row`; break-and-revert: pane rows instead of split rows fail `suggest-check` 41, no cell gap and a joined-title AX label fail flow 81 ×2 | done |

| 5 | [#140](https://github.com/SergeSerb2/open/pull/140) | `suggest-check` 47/47 (42–43); `commandbar-render check` 132/132 (flows 82–85, 91: 8 checks; states `actions-scope`, `actions-scope-empty`, `tabs-scope`, `scope-chip-hover`, `site-chip-query`); S2 18/0016 and 0018 in Display P3: chip, chip text, placeholder and field text ≤ 1 pt, text ΔE00 ≤ 1.05, chip fill ΔE00 6.0 (the harness clips P3 to sRGB); `commands-dump` 0/0/0, same 11 allowed missing; App build; e2e `commandbar` 57/57 incl. new `commandbar_actions_scope`; break-and-revert: no text restore fails flows 82, 84, 91; no scope row color fails 91; prefix scope keywords fail `suggest-check` 43 | done |

Section 2 decisions (Step 0):

- `present(_:)` and `dismiss(reason:)` lose their `animated:` parameter: with no animation it would mean nothing.
- "Search Settings…" already opens Settings ▸ Profiles for the bar's Profile in Step 0 (the plan put that in Step 9). The `search-settings` command does the same for the key window's Profile.
- While Open has no privacy page, line 2 of the footer hides (`privacyURL` nil). Hiding only the word "here" would leave a broken sentence.
- The panel edge keeps the session-1 luminance rule. Session 2 shows the dark double edge over light pages, against session-1 F0039/F0040/A0120; the rule's input is not known (`docs/followups.md`, capture request).
- `compare --space p3` measures session-2 captures in Display P3 (their AW2726DM profile exceeds sRGB); session-1 comparisons stay in sRGB.

Section 2 decisions (Step 5):

- The chip fill is Display P3 #FFA500: the captures read P3 #FFA501, which sRGB cannot hold (the plan's #FFA000 is its sRGB clip). `commandbar-render` renders into sRGB, so its compares read ΔE00 6 on the chip and the scoped row; positions match.
- Fitted against the plan's guesses: the chip title is 13 Medium (not Semibold), the glow blur 16 / alpha 0.32 (not 6 / 0.35), the field text inside a scope 18 Regular (two ink widths), and the field starts at chip + 13 (its AX frame stays at chip + 11 = 146).
- No (i) inside a scope, and the scoped Site Search row shows only the query: both measured on S2 18/0016 and 0018 (the plan did not say).
- Actions scope ranking: equal matches go by how much of the title the query covers ("side" → Show/Hide Sidebar before Reveal Tab in Sidebar). The registry seed order would put Reveal first; Arc's real order (recent use) is not kept by Open.
- The App's `search-actions` command and the `commandbar-state` `scope` field come with this step (one line each); Step 9 keeps the rest.

Section 2 decisions (Steps 3–4):

- The plate cells and pane icons are Core Animation sublayers of the row view, not drawn in `draw(_:)`: one rounded layer per cell with only the outer corners round, so the 1 pt gap needs no clear blend. Drawing the plate in `draw(_:)` made `commandbar-render` copies of that row view blank (`docs/commandbar.md` §7).
- The rule starts 4.5 pt after the first title's advance and the next title 5 pt after the rule (fitted on A0120; the plan said 5 pt each side). Text widths are exact, not rounded up.
- The selected split row's rule is white 0.5, and a split row 1 gives the input its matched pane's icon (guesses; no capture).
- The App needs no change for Step 9's pane rule: `selectTabForCommand` already focuses the pane, selects the split, and reveals it. The e2e check `commandbar_split_one_row` proves it now.
- `SplitRowInfo` also carries `paneURLs`, for the dedupe of history rows into the split row.

Section 2 decisions (Steps 1–2):

- A matching character keeps the completion with one storage edit: the completion's first character is removed and the typed one inserted in its place (normal undo coalescing). The plan's "move the selection start by one" is the visible result; removing and re-writing the whole completion cost two edits and two selection changes per keystroke.
- The field editor turns off system inline predictions, math results, and Writing Tools. Each ran NSTextCheckingController on every selection change; a URL field must not show the system's own prediction next to ours.
- The completion budget is measured in main-thread cycles over the keystroke's own work (no polling), converted at the off run's cycles per ms, as p95(on) − p95(off) (plan §5.4 wording); "no extra layout pass" compares the mean layout passes on and off. CPU-time differences moved by ±0.5 ms with machine load.
- T3a also accepts a tab row whose URL field alone matched with 2+ bytes typed, so "localhost:30" completes from a tab on `localhost:3000` (the host field has no port).
- History carry-over keeps a previous row when its host or its URL still matches (the plan says URL; host-only matches are the common case for completion).
- Home (`scrollToBeginningOfDocument`, which AppKit only scrolls) puts the caret at the start, like Cmd+Left. Forward Delete and the word and line deletions remove only the completion, like Backspace (guess, plan §4.1.5).
- The hint label font is 12.75 Medium (fitted on F0061 88 px and S2 18/0009 105 px ink widths; Regular was 2 px narrow). The selected row's subtitle is white 0.52 (fitted on S2 18/0009 row 1; it still misses by ΔE00 2.67, `docs/commandbar.md` §8.3).
