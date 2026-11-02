# Command bar completion, scopes, shortcut hints, and the optional toolbar

Arc 1.170.0 (build 89123). Findings for `docs/plans/commandbar-completion.md` (status gaps 22–26). Written 2026-10-25.

Personal data is not in this file. Captured titles and hosts are replaced by placeholders: `<host>` is a site host, and "the tab" is an open tab on that host. Raw output is in `.re/commandbar-completion/` (git-ignored).

Marks: **measured** (pixels or AX), **decoded** (bytes or instructions in the binary), **string** (a string in the binary), **derived** (follows from the measured or decoded facts), **guess**.

Frame ids: **F** = full session `.re/runtime/sessions/20261024-213009-session-full/`, **A** = fast session `…-session-anim/` (`interaction-states.md` §0). Window 2216×1394, backing scale 1. Panel coordinates are points from the command bar panel's top-left corner (`[725, 528]` in the window).

## Evidence index

| Command | Output |
|---|---|
| `strings .re/bin/Arc-arm64` (existing `.re/hotkeys/strings-raw.txt`) | the string rows below, cited by line |
| Section `__TEXT,__swift5_reflstr` of `.re/bin/Arc-arm64`, split on NUL | `.re/commandbar-completion/reflstr.txt` (Swift field names) |
| Shared Ghidra project, read-only: `analyzeHeadless … ArcMain -process Arc-arm64 -noanalysis -readOnly -postScript AdrpBatch.java needles.txt` (18 needles) | `.re/commandbar-completion/ghidra.txt`, `.log` (exit 0) |
| `xcrun objdump -d --start-address … --stop-address …` on `.re/bin/Arc-arm64` | small-string literals at the addresses below |
| File reads of `__TEXT,__const` (address 0x103644840 = file offset 56903744) | flag default values |
| CoreGraphics pixel dumps of sRGB-converted frames (`/tmp` tool, not kept) | measured boxes and colors |

## 1. Inline autocomplete

| ID | Finding | Mark | Evidence |
|---|---|---|---|
| CC-1 | Arc shows inline autocomplete as text appended to the typed text, with the appended part selected. The typed part keeps the normal input color. There is no ghost text. | measured | F0043: the field shows 5 typed letters plus 5 selected letters of `<host>`. F0062: 6 typed letters plus the selected `.com`-style suffix. |
| CC-2 | The completion selection uses the same fill as the Cmd+L selection: the Space's `dark.subtitle` (`#807571` exact in Space 1). Selected glyph cores are `#EEEEF1`. The box is `[98, 21, 51, 21]` in panel points for a 5-letter suffix. Its left edge touches the last typed glyph's advance. Its right edge ends 1 pt after the last glyph's ink. No caret shows. | measured | F0043 pixels, rows 549–569, columns 823–873 of the window |
| CC-3 | The field's AX value holds the whole text, typed part plus completion. | measured | F0043 and F0062 `ax.json`: `commandBarTextField` value length 10 for a 10-letter host |
| CC-4 | The completion comes from row 1, and row 1 keeps the selection. In both frames row 1 is a Switch to Tab row for an open tab on `<host>`, and the completion is that tab's host. Row 2 is the typed-text search row, which shows the typed text, not the completed text. The leading icon is row 1's favicon. | measured | F0043, F0062 panel crops |
| CC-5 | The Site Search hint is computed from the typed text, and it never offers Space while a completion shows. F0043 and F0062 show "Search \<Engine\> [Tab]" only, although in F0062 the typed text equals the engine's name. | measured | F0043, F0062 hint group |
| CC-6 | The field may show the completion in the candidate's letter case. In F0062 the typed-search row (row 2) starts with a capital letter, but the field shows the host in lower case. | derived (one frame) | F0062 row 2 vs field |
| CC-7 | After the whole host is in the field with the caret at the end (F0061), row 1 is a navigate row for that host with its favicon on the white plate and no subtitle. The open tab is row 3 with "Switch to Tab". Arc does not show a further completion there, although longer URLs on the host are listed (row 5). | measured | F0061 |
| CC-8 | Earlier claim corrected: `interaction-states.md` §9.3 said F0040 shows a completion. It does not. F0040's AX value lags the image by one key (caveat 3 in `interaction-states.md` §0). The image shows the fully typed host, the caret at the end, and no selection. No open tab or history entry for that host existed yet (the first Today tab appears in F0041). | measured | F0040 crop: no selection pixels; AX value length 9 vs 10 drawn letters |
| CC-9 | The command bar input keeps the user's text apart from the field text, and tracks Backspace. The input container has `lastUserInput`, `latestInputAndDidBackspace`, `isBackspacingStatus`, and `commandBarUndoManager`. The input view state has `autocompleteString`. The module declares `CommandBarAutocompleteSuggestion` and `BackspacingStatus`. Key handlers include `onBackspacePressed`, `onKeyboardLeft`, `onKeyboardRight`, `onTabKeyPressed`, and `onEscapePressed`. | string | `strings-raw.txt` 12296–12298 (types), 162845–162870 (handlers), 163095–163125 (fields); `reflstr.txt` 105041, 107366, 107403, 107467 |
| CC-10 | Arc can also ask its engine (ArcCore, Chromium) for autocomplete with a flag that prevents inline autocomplete: ObjC selector `autocomplete:cursorPosition:preventInlineAutocomplete:startFresh:keyword:error:completion:`, plus `createAutocompleteControllerWithProviders:` and `deleteAutocompleteMatch:`. guess: Arc maps Backspace and caret moves to Chromium's "prevent inline autocomplete" rule. | string | `strings-raw.txt` 176106, 177119, 177441 |
| CC-11 | A suggestion can be deleted from the bar ("Delete Suggestion", handler `onDeleteSuggestion`, `DeletableAutocompleteMatches`). Not in this plan's scope. | string | 52715, 162855, 829–831 |

## 2. Split View rows

| ID | Finding | Mark | Evidence |
|---|---|---|---|
| CC-12 | A Split View shows as one row, with the accessory "Switch to Split View" (string comment "Caption for switch-to-tab results that open a tab within a split view"). | measured, string | A0120 and A0121 row 3; `strings-raw.txt` 52645–52646 |
| CC-13 | The row icon is a plate of 30×30 pt at row `[12, 10]`, white 0.05 over the panel (the same token as the action icon plate). Its corner radius is about 7 pt (fitted from the corner coverage). A 1 pt gap at the plate's center splits it into two cells. Each cell holds one pane's favicon, about 9 pt, centered in the cell. | measured | A0120 row 3, pixels: plate columns 12–41, rows 10–39 (value 60 over 49); gap columns 26–27 (value 54 = half coverage); left favicon ink `[15, 21, 9, 9]` |
| CC-14 | The title starts at row x 50: the plate's right edge plus 8 pt, as for normal rows (24 pt plate, title at 44). The pane titles follow each other with a 1 pt vertical rule between them. The rule is 12 pt tall (row y 20.5–32.5), white ≈ 0.17, with about 5 pt of space on each side. There is no subtitle. | measured | A0120 row 3: title ink starts at x 50.5; rule columns 137–138 at value 67 over 49 |
| CC-15 | The suggestion model keeps several icons and their layout direction: suggestion fields `iconsInfo`, `icons`, `layoutOrientation` with cases `horizontal` and `vertical`. guess: a vertical split stacks the cells. | string | `reflstr.txt` 106883, 106936 |

## 3. Scoped searches and other modes

| ID | Finding | Mark | Evidence |
|---|---|---|---|
| CC-16 | Scoped search has two kinds outside Arc Max: TypeTravel (the browser-actions scope) and Site Search. Ranking config keys: `ScopedSearchType` with `TypeTravelCodingKeys` and `SiteSearchCodingKeys`. | string | 10980–10984 |
| CC-17 | The actions scope pill title is "Actions": `NSLocalizedString("Actions", comment: "title for scoped search of browser actions in Arc")`. | decoded | small-string literal `0x0073_6e6f_6974_6341` loaded at `0x101d80a38` (function `0x101d809f4`), passed with the comment string at `0x1039ec330` |
| CC-18 | The bar has two placeholders: "Search or Enter URL…" and "Search…" (comment "Placeholder text to search."). guess: "Search…" is the placeholder of a scope without a site name. | decoded | function `0x1021ffa58`: string at `0x10394a670`; small string `0x80e2686372616553` + `0xa9…a6` = "Search…" |
| CC-19 | A scope remembers the text from before it started and can restore it: fields `queryBeforeEnteringScopedSearch`, `postScopedSearchQuery`, `postScopedSearchRestoration`. The pill can show a close accessory (`shouldDisplayCloseAccessory`) whose action is "Title for action to go back to the previous search state." The pill takes a scope color (`ScopedSearchColor`, `scopedSearchAccessoryColorPaletteSubscription`). | string | 12392–12394, 162963–162977, 52683 |
| CC-20 | Entry gestures for the actions scope are not proven. Two app defaults exist: `controlKeyShowsTypeTravel` and `commandKeyShowsCommandBar`. Neither is set in the user's defaults, so they are off or hidden. An entry point is named `toggleBetweenTypeTravelAndCommandBar`. guess: an internal option lets a bare Control press open the actions scope. | string, measured | 35467–35468 (next to `ApplePersistenceIgnoreState`), 40187; `.re/runtime/defaults.txt` has neither key |
| CC-21 | A tabs-only scope uses the Site Search trigger mechanism: setting `migratedToTabOnlySiteSearchTrigger` (already cited in `features-core.md` §4.6 r14). | string | `features-core.md` §4.6 |
| CC-22 | The Site Search hint draws "Tab", "or", "Space" as separate localized parts in a row with 8 pt spacing. A Boolean on the hint model decides whether "or Space" shows. | decoded | function `0x10221eee4`: `NSLocalizedString` of "Tab", "Space", "or"; `HStack` spacing `0x4020000000000000` (8.0) |

## 4. Hold-Command shortcut hints

| ID | Finding | Mark | Evidence |
|---|---|---|---|
| CC-23 | Arc has a remote feature flag `show-top-app-shortcuts-when-holding-cmd`. "Top apps" is Arc's internal name for Favorites. The flag's built-in default is false; the server value is not known. | decoded | flag table in function `0x1013daf24`: entry at `+0x11a0` = this key, bytes `00 02 00` (the first byte is the default: other entries such as `sidebar-sync-cloudkit` and `certificate-transparency-enabled` have `01`) |
| CC-24 | The favorites container view state has `showShortcutsWhenHoldingCmd`, next to `items`, `pinnedExtensions`, `hasDismissedEmptyState`, `tabReorderingHapticsDisabled`, and `windowTheme`. derived: while Command is held, Favorites tiles show their Command-number shortcut. | string, derived | `reflstr.txt` 91360; `strings-raw.txt` 159359 |
| CC-25 | The numbered shortcuts have Settings options: include Favorites in the numbering (`excludeFavoritesInSwitchToNthTab`, inverted) and "Switch to ninth tab" (`switchToNinthSidebarItemEnabled`). Strings: "Jumps to the first item" … "Jumps to the ninth item", "Jumps to the last item at the bottom of your Sidebar". | string | `menus-and-hotkeys.md` "Shortcuts that live in code"; `features-core.md` §7.2 Shortcuts |
| CC-26 | No capture shows the hints. Their look, delay, and fade are not known. | — | `interaction-states.md` §2 |

## 5. Essential Keyboard Shortcuts window

| ID | Finding | Mark | Evidence |
|---|---|---|---|
| CC-27 | Help ▸ Essential Keyboard Shortcuts (`keyboardShortcutsEDU:`) opens `KeyboardShortcutsEDUWindow`. The window is created with a zero rect and style mask `0x8007` (titled, closable, miniaturizable, full-size content; not resizable). It hides the title (`setTitleVisibility: 1`), uses a transparent title bar, is not opaque, is movable by its background, uses window level 3 (floating), and collection behavior `0x100` (full-screen auxiliary). Its content is a SwiftUI hosting controller, so the content sets the size. The window title is "Essential Keyboard Shortcuts". | decoded | function `0x101ebd734`: `initWithContentRect:styleMask:backing:defer:` with `(0,0,0,0, 0x8007, 2, 0)`; title from the 28-character string at `0x1039f1860` |
| CC-28 | The window lists five items, in this order, each a title and a description: "Open a New Tab" — "Open the Command Bar to create a new tab"; "Switch to a Recent Tab" — "Hold this to quickly switch between recent tabs"; "Copy Page URL" — "Copy the current tab's URL without trackers"; "Add Split View" — "View multiple websites side-by-side"; "Open Little Arc" — "Use a smaller browser window for quick searches". derived: the keys are Cmd+T, Ctrl+Tab, Cmd+Shift+C, Ctrl+Shift+=, Cmd+Opt+N. | decoded | function `0x101eb9a10`: small strings `Open a New Tab`, `Copy Page URL`, `Add Split View`, `Open Little Arc`; strings at `0x1039f1750…0x1039f1830` |
| CC-29 | Entry points (`KeyboardShortcutsEDUEntryPoint`): the Help menu; Settings ▸ Shortcuts, where a callout "Start with the basics" holds a button "Learn the Essential Shortcuts" (comments: "Callout on a container with a button to learn the essential keyboard shortcuts", "Label on the button that will open an educational view to lear[n] essential keyboard shortcuts"); and the welcome view ("Learn Essential Shortcuts"). The button glyph is `command.circle.fill`. | string, measured | 52224–52227, 52307; capture `c-shortcuts.png` (A0504) |
| CC-30 | Correction for Open: `OpenSettings/ShortcutsPane.swift` and `docs/plans/settings-library.md` treat "Start with the basics" / "Learn the Essential Shortcuts" as a two-segment filter. Arc's comments say it is a callout with one button that opens the Essential Keyboard Shortcuts window. | string | CC-29 |
| CC-31 | Arc's Copy URL removes tracking parameters ("Copy the current tab's URL without trackers"). Open's `copy-url` copies the plain URL (`docs/plans/app-shell.md` §4.1). | decoded, derived | CC-28 |
| CC-31a | Arc's tracker rule for Copy URL, decoded (Section 2 item 12). One cleaner function takes a URL and returns the cleaned URL and a "changed" flag; Copy URL copies the result. derived: the flag picks the toast "Copied a clean link without trackers" over "Copied Current URL" (the caller at `0x1029ac780` reads it into its result; both strings exist; the toast choice itself is not traced). Steps: (1) a query that contains `;` is left alone; a URL with no query items is left alone unless its host is Amazon. (2) Site rules, where a host matches a domain when it equals it or ends with "." + domain: twitter.com and x.com drop the exact names `t`, `s`; amazon.com drops names starting with `_encoding`, `ascsubtag`, `pd_rd_`, `pf`, `pf_rd_`, `psc`, `tag`, `ie`, `hv`, the exact names `content-id`, `crid`, `dib`, `dib_tag`, `keywords`, `qid`, `rnid`, `s`, `sprefix`, `th`, and a last path segment that starts with `ref=`; youtube.com drops `feature`, `app`, `embeds_referring_euri`, `source_ve_path`; ebay.com drops `_trkparms`, `_trksid`, `_from`, `hash`, `_skw`, `itmmeta`, `itmprp`. (3) Everywhere: names that start with one of 42 prefixes (`_bta_c` … `utm_`, `vero_`, including `ref`, `mc_`, `pk_`, `spm`) and 23 exact names (`fbclid`, `gclid`, `srsltid`, `si`, `share_id`, …) are dropped. Comparisons are case-sensitive. The full lists are in `OpenModel/TrackerStripping.swift`. | decoded: main binary, cleaner at `0x100826084` (shared Ghidra project, `AdrpBatch`/`DecompAddrs` scripts; raw output `.re/s2cb/ghidra-trackers.txt`, `.re/s2cb/trackers/ghidra-helpers.txt`, `ghidra-predicates.txt`); the item-name tests at `0x10082708c` (prefix set + exact set), `0x100826f18` (prefix), `0x10082829c` (exact); host match at `0x100775194`; lists read from `__DATA,__data` (`.re/s2cb/trackers/arrays.json`) | CC-31 |

## 6. Optional toolbar

| ID | Finding | Mark | Evidence |
|---|---|---|---|
| CC-32 | View ▸ "Show/Hide Toolbar" (Cmd+Shift+D, `toggleArcToolbar:`) changes its title at run time: "Show Toolbar" or "Hide Toolbar" (comments "Show toolbar menu item title", "Hide toolbar menu item title"). The sidebar item has the same pair ("Show sidebar menu item title", "Hide sidebar menu item title"). | decoded | `0x1003151d0`: two 12-character literals starting "Show Too" and "Hide Too", chosen with `csel`; strings 33399–33402 |
| CC-33 | The toolbar's height is a remote setting `toolbar-display-height` with the built-in default **32** (an integer). This equals the Split View pane bar (`topBarPanel`, 32 pt, `interaction-states.md` §11). | decoded | function `0x1013d9c14`: default from `__TEXT,__const` `0x1037343e0` = `20 00 00 00 00 00 00 00` with type tag 1 |
| CC-34 | The toolbar is the content top bar: AX ids `contentToolbar`, `topBarPanel`, `contentToolbarTranslateButton`, `contentToolbarOpenExtensionsButton`, `contentToolbarCloseSplitButton`, `contentToolbarSplitViewMenu`. Window state file `WindowState+ContentToolbar.swift`. The content layout state has `sidebarPresentation`, `sidebarWidth`, `contentInsets`, `showingToolbar`. derived: the toolbar is per window, and it insets the page by its height. | string, derived | 37160–37230, 33480–33481; `reflstr.txt` 548 |
| CC-35 | A remote flag `show-toolbar-in-split-view-enabled` exists (built-in default false). | decoded | flag table entry at `+0xca0`, bytes `00 02 00` |
| CC-36 | The URL pill has a context menu with actions "Show as Toolbar" / "Hide Toolbar", "Show Full URL" / "Hide Full URL", "Manage Extensions", and "Show/Hide Shared Quotes" (comments "Title for the 'Show as Toolbar' context menu action." and the others). Two action lists exist: `commandBarPlaceholderContextMenuActions` (sidebar pill) and `commandBarToolbarContextMenuActions` (toolbar). derived: "Show as Toolbar" moves the URL field from the sidebar into the toolbar. | string, derived | 34009–34017; `reflstr.txt` 1271, 14462 |
| CC-37 | Settings ▸ Advanced has "Show full URL when Toolbar is enabled" (`toolbarShowFullURLsEnabledPreference`, app-wide user default). The pill's view state reads `shouldToolbarShowFullURLs`. | string | 51833, 35403, 139505 |
| CC-38 | The Shortcuts pane description is "Shows or hides the toolbar at the top of your window." | string | 52150 |

## 7. Not proven; needs a person

1. A capture of the window with the toolbar shown (Cmd+Shift+D): bar controls, whether the sidebar still shows the URL pill and back/forward/reload, and where Favorites move.
2. A right-click on the sidebar URL pill and on the toolbar URL: menu items and order.
3. Hold Command for 2 s with the sidebar visible: whether Favorites or tab rows show shortcut badges, and how they look.
4. The Essential Keyboard Shortcuts window (Help menu), one capture.
5. Command bar: type a host prefix, then press Backspace, Right arrow, and Left arrow once each (one capture after each key). This proves the Backspace and arrow rules.
6. Command bar with a three-pane or vertical split in the list (the split row icon).
7. F0040 vs F0061: both show the whole host with the caret at the end, but only F0040 offers "or Space". The rule is not known.

## 8. Capture session 2 results (2026-10-26)

Session 2 item 18 (`interaction-states.md` §20.9; frames `S2 18/<frame>` = `.re/runtime/sessions/20261026-103712-18-command-bar/<frame>-*`). It answers §7 items 3 and 5 in part, and replaces the Q9 guess.

| ID | Finding | Mark | Evidence |
|---|---|---|---|
| CC-39 | Hold Command for 2–4 s with the sidebar visible: no shortcut hints appear. With CC-23 this means the hints are off in the shipping config (the flag's server value is false or unset). | measured | S2 18/0001–0003; notes 10:38:02 |
| CC-40 | "wiki" completes inline to "wikipedia.org" with the added part selected, and the trailing hint reads "Search Wikipedia" + [Tab] (AX "Search Wikipedia, Tab", `[1078, 393, 147, 24]`). Backspace removes the completion and leaves "wiki". Right and Left arrows were pressed, but no frame isolates their result (§7 item 5 stays open for them). | measured | S2 18/0009, 0010 |
| CC-41 | Tab starts Site Search: the text becomes an orange chip "Wikipedia" (`#FFA000`, white text, x 535 … 615) in front of an empty field (the field moves to x 627). Typed text gives one search row with an orange selection (`#FFA000`). Backspace in the empty field removes the chip and gives back "wikipedia" as text. guess: the chip color is a per-engine color. | measured | S2 18/0016, 0018, 0021 |
| CC-42 | The (i) button opens an inline footer at the bottom of the bar, not a window: "We talk to your search engine to help us suggest results." / "Learn more about your data on Arc here." ("here" is a link) and the buttons "Search Settings…" and "Dismiss". The Essential Keyboard Shortcuts window (CC-27) is reached from the Help menu, not from (i). | measured | S2 18/0044 |
| CC-43 | The bar's fill and selection follow the Space: `#2F2D2E` / `#484DDB` in a default dark Space, `#1B2832` / `#2A68A3` in a blue Space; in macOS Light (default theme) `#F8F8F8` / `#8E95FF`. | measured | S2 18/0044, 0009; S2 20/0018 |
| CC-44 | Open and close have no visible animation: in the video the whole bar appears or goes between two frames (≤ 38 ms apart), 4 of 4 times. | measured | `21-motion.mov` V 9.70, 10.88, 13.02, 14.20 s |

Still open: §7 items 1, 2, 4, 6, 7, and the Right and Left arrow rules.
