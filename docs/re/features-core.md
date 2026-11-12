# Core features: behavior and settings spec

Target: Arc 1.170.0 (build 89123), `company.thebrowser.Browser`, arm64 slice
`.re/bin/Arc-arm64`. Engine: ArcCore 156.0.8078.48.

This file is an implementation spec for Open. Each feature has numbered rules.
An engineer can implement and verify each rule without running Arc.

Out of scope here (other agents): Split View, Peek, Little Arc window internals,
Boosts, Zap, Site Control Center, ad blocking internals, PiP/media internals,
AppleScript. This file covers those features only where they touch the sidebar,
command bar, Spaces, Profiles, or Settings.

## How to read evidence

- **Proven** means a string, type name, nib title, or bundle file in Arc proves it.
  The evidence column gives the exact string, symbol, or file.
- **Guess** means the behavior is likely but the binary does not prove it.
  Do not ship a Guess as final. Check it at runtime.
- Raw dumps stay in `.re/features-core/` (git-ignored). Key files:
  `strings-all.txt` (all `strings -a` output, line numbers cited as `strings:N`),
  `mainmenu-nib.json` + `mainmenu-items.txt` (`rea decode-interface-builder`),
  `extract-*.txt` (filtered views of `strings-all.txt`).
- Commands used: `strings -a .re/bin/Arc-arm64`,
  `rea decode-interface-builder /Applications/Arc.app --format json`,
  `rea inspect-macho .re/bin/Arc-arm64 --format json`,
  `xcrun swift-demangle`, `plutil -p` on bundle plists and `.strings`.
  No Ghidra decompilation was used. The shared Ghidra project was still building.
  `rea inspect-native-dispatch-metadata` fails on this binary (64 MiB snapshot
  budget), so enum case lists come from strings and nib titles, not metadata.
- Help-center URLs cited below come from strings in the binary. The help site
  blocks plain `curl` (Cloudflare challenge), so article bodies were not fetched.
  Treat help-center cross-checks as **open questions** until a human opens them.

### Bundle facts that shape everything

| Fact | Evidence |
|---|---|
| Only `MainMenu.nib` is compiled Interface Builder UI | `rea decode-interface-builder`: 6 documents, only `Contents/Resources/Base.lproj/MainMenu.nib` (678 objects) is Arc UI; the rest are Sparkle |
| Almost all UI text lives in the Swift binary, not `.strings` files | Only 2 `en.lproj/Localizable.strings` exist (`ARC_AskArc`, `Settings_Settings` with 2 keys). All other labels are binary strings |
| Command bar ranking is on-device ML | Types `LocalCommandBarRanking`, `CommandBarRankingCandidate/Input/Result/Tensor`, `ASE2/ScoreAndWeights.swift` (`strings` in `.re/features-core/extract-commandbar.txt`) |
| Sidebar data is a container/item tree | Types `SidebarData`, `SidebarItem`, `SidebarContainer`, `SidebarContainerType`, `SidebarItemDataType`, `SidebarLocation` |

---

## 1. Sidebar

### 1.1 Layout: sections top to bottom

Rules:

1. The sidebar has three zones in one scroll view, top to bottom:
   (a) **Favorites** (code name **Top Apps**), (b) **Pinned** section of the
   focused Space, (c) **Today** (code name **Unpinned**) section of the focused
   Space. Evidence: types `TopApps`, `PinnedCodingKeys`, `UnpinnedCodingKeys`;
   container ID keys `topAppsContainerID`, `sidebar-item-stub-pinned-container-id`,
   `sidebar-item-stub-unpinned-container-id` (`strings`, see
   `.re/features-core/extract-sidebar.txt`).
2. Favorites render as a grid/tray above the pinned list, not as list rows.
   Evidence: `sidebarFavoritesCollectionView` (a collection view), empty-state
   strings "Drag to add Favorites" / "Favorites keep your most used sites and
   apps close" (`strings:131369-131372`). Exact column count and cell size are
   **Guess** — check the design-tokens report and runtime.
3. The Pinned section has a header and a footer and can be collapsed per Space.
   Evidence: keys `pinnedTabsHeader`, `pinnedTabsFooter`, `unpinnedTabsHeader`;
   persisted key `spacesWithCollapsedPinnedSections`; menu items "Collapse
   Pinned Tabs" / "Expand Pinned Tabs" (`strings:114116-114119`); types
   `PinnedSectionExpansionState`, `CollapsedPinnedSection`.
   Implement: store one collapsed flag per Space ID. Default expanded (**Guess**).
4. The Today section has a header row with the section title and two buttons:
   **Clear** and **Tidy/Organize**. Evidence: `UnpinnedSectionHeaderCellView`,
   `UnpinnedSectionDividerCellView`; strings "Clear Today tabs" (button title),
   "Clear unpinned tabs in this space" (tooltip), "Tidy unpinned tabs in this
   space" / "Organize Today Tabs" (AI organize, Max-related — out of scope for
   Open v1, but the button slot exists) (`strings:113404-113411`).
5. A "New Tab" row/button sits in the sidebar and creates a Today tab via the
   command bar (see §3.5). Evidence: `sidebarNewTabButton`, string "Start
   browsing by clicking New Tab in your sidebar or typing…" (`strings:133020`).
   Exact placement (above Today list vs. below) is **Guess** — runtime check.
6. The sidebar bottom bar holds, left to right (**Guess** order): Space
   switcher, "+" (new item) button, then utility buttons for Downloads,
   Library, and Media/PiP. Proven parts: `spaceSwitcher`, `sidebarPlusButton`
   (+ `ARC_SidebarPlusButton.bundle`), `downloadsMenu`, `sidebarArchivesButton`
   (Archive entry), Library via `Window ▸ View Library`. Verify order at runtime.
   Update (media/PiP pass, 2026-10-25): there is no Media/PiP button. The
   measured bottom bar is Home, switcher, plus (runtime-observations §1.1),
   and media controls live in their own `mediaControlsContainer` above it
   (features-advanced PP-20).
7. The top of the sidebar is the window chrome: traffic-light area, then the
   command-bar placeholder (URL pill) for the current tab (see §8.4). Evidence:
   `CommandBarPlaceholderView`, `commandBarPlaceholderTextField`,
   `topLeftCommandBar`. The sidebar is also the drag region for the window:
   `SidebarDragRegionWindow`, `contentWindowDraggingEnabled`.

### 1.2 Tab row content

8. Each tab row shows: favicon (left), title (one line, truncates), and
   trailing affordances. Evidence: `SidebarCellImageContainerView` (favicon),
   `sidebarItemSubtitleTextField` (editable title field), `TablistView`.
9. Titles use Arc's "tidy titles" cleanup for known sites (for example Gmail
   fragment → "Inbox", LinkedIn path rules). Evidence:
   `ARC_WebContentBehaviorConfigurationClient.bundle/.../web_content_behavior.json`
   key `tidyTitles` with per-domain `siteName` + `rules`. Open must ship an
   equivalent rule table. The JSON in the reference bundle is data, not code —
   recreate the rules, do not copy the file.
10. A tab that plays audio shows a speaker indicator; clicking it mutes or
    unmutes that tab. Evidence: `SidebarCellSpeakerIconWrapperView`,
    `sidebarTabCellMuteButton`, fields `isMuted`, `savedMuteStatus`, tooltips
    "mutes the tab" / "unmutes the tab" (`strings:113977-113978`). Global
    actions "Mute all tabs" / "Unmute all tabs" also exist
    (`muteAllTabs`, `unmuteAllTabs`). The icon is a SwiftUI view
    `SpeakerIcon{isMuted, speedup, slashStart, waveIncrement, waveReappearStart}`
    inside `SidebarCellSpeakerIconWrapperView{isMuted, foregroundTintColor}`
    (fields, `.re/media/swift-fields.tsv`): the slash and the waves animate
    when the mute state changes, and the tint follows the row's text color.
    Guess: no looping animation while audio plays. A row of a tab that uses
    the camera or microphone also shows a recording indicator
    (`isRecording`, `hasLeadingRecordingIndicator`; tooltip "This tab is using
    your camera or microphone"). Arc persists the mute flag per tab as
    `savedMuteStatus` = "allowAudio" | "mute" (66 of 66 tabs in the live
    sidebar are "allowAudio"; values only, no personal data read).
    Details: features-advanced §8 (PP-19, PP-21).
11. Hovering a row reveals a close (×) button. Activating close **archives**
    the tab (removes it from the sidebar and writes an archive record); it does
    not permanently delete it. Evidence: tooltip "closes the tab the user is
    hovering over, then removes it from the sidebar and archives it"
    (`strings`, near `strings:111571` and `132435`); `SidebarCellButton`,
    `SidebarCellButtonCloseContentView`; `completeCloseWindowContent(_:options:archiveInfo:)`.
12. Rows show an unread badge for items added in the background (for example
    Live Folder additions, links opened in another Space). Evidence:
    `SidebarItemUnreadBadgeView`, toast "New Tab Created in %@",
    "Tab moved! Click to go there." Clear the badge when the tab is focused
    (**Guess** timing — runtime check).
13. Hovering a Folder, Pinned, or Favorite row can show a preview (Glance)
    after a hover delay. Evidence: `SidebarPreviewHoverTracker`,
    `FolderPreviewView`, Preferences string "Hover your mouse over an Arc
    Folder, Pinned, or Favorited tab to quickly preview…". Preview internals
    belong to the Peek agent; the sidebar only supplies the hover trigger.
14. The selected row is highlighted; Space color tints the sidebar background
    (see §2.4). Evidence: `SidebarItemHoveredBackground`, `WindowTheme`,
    `SpaceStyleEditor`. Exact colors: design-tokens report.

### 1.3 Renaming tabs

15. Any tab can be renamed. The custom title replaces the page title in the
    sidebar until the user clears it. Evidence: `customTitle`,
    `updateCustomTitle(for:title:)`, `has_custom_title`, action "Rename Current
    Tab" / "Rename current item" (`strings:131546-131547`, `131614-131615`),
    MainMenu Tabs ▸ "Rename Current Item".
16. Entry points (**Guess** exact set — verify): double-click the row title
    ("Double-click to rename", `strings:113981`), the rename shortcut (see the
    hotkeys report), and the row context menu. Editing happens inline in
    `sidebarItemSubtitleTextField`; Enter commits, Esc cancels (**Guess**).
17. Optional AI rename on pin ("Tidy Titles" for pinned tabs) exists but is an
    Arc Max feature — **out of scope** for Open. Evidence only:
    `renamePinnedTabsEnabled`, "Have your tabs automatically renamed with
    tidier, shorter titles when you Pin them." Do not implement the AI path;
    manual rename (rule 15) is in scope.

### 1.4 Duplicate, Copy URL, and row context actions

18. **Duplicate** creates a copy of the tab next to the original. Evidence:
    `duplicateCurrentTab`, `duplicateItem(_:newItemID:options:insertionStrategy:…)`,
    "Item type cannot be duplicated", flag `duplicateIfSourceItemIsPinnedOrTopApp`
    (duplicating a Pinned/Favorite item creates a regular tab copy — **Guess**
    which section receives it; verify). MainMenu Tabs ▸ "Duplicate".
19. **Copy URL** copies the tab URL without trackers. Variants: "Copy URL",
    "Copy URL as Markdown" (`[Title](url)`), "Copy URL as Quote" (URL + selected
    text). Evidence: MainMenu Edit ▸ "Copy URL", "Copy URL as Markdown",
    "Copy URL as Quote" (see `mainmenu-items.txt`); shortcut descriptions
    "Copies the current URL to your clipboard without any trackers"
    (`strings:132809-132812`); `copyCurrentURL`, `copyCurrentURLMarkdown`,
    `copyCurrentURLAsQuote`. Show a toast after copy (see §4.7).
20. The row context menu offers at least: Open in New Window / Split actions
    (other agents), "Move to Today in \<Space\>", "Move to Pinned in \<Space\>",
    "Move to Top Apps" (Favorites) / "Remove from Top Apps", "Pin/Unpin Tab",
    "Move to Folder…" / "Move to New Folder…", Duplicate, Rename, Copy URL
    variants, Mute/Unmute, Close/Archive. Evidence: action strings
    `strings:131588-131631` ("Move to Today in ", "Move to Pinned in ",
    "Move to Top Apps", "Remove from Top Apps", "Unpin from Top Apps"),
    `moveToFolder`, `moveToNewFolder`, `createNewFolder`. Build the menu from
    these labels; exact order is **Guess**.

### 1.5 Folders

21. Folders live inside the Pinned or Today section of one Space. A folder has
    a title, an icon, an expanded/collapsed state, and an ordered child list.
    Evidence: types `Folder`, `SidebarSpaceFoldersQuery`,
    `SidebarSpaceFoldersWithDepthQuery`, `FolderIcon`/`FolderIconView`,
    `updateFolder(_:modify:)`.
22. Folders nest. Depth is tracked explicitly. Evidence:
    `SidebarSpaceFoldersWithDepthQuery`, `SidebarItemWithDepth`, analytics field
    `max_folder_depth` / `maxFolderDepth`. Maximum allowed depth is **not**
    proven — **Guess**: unlimited until a runtime check finds a limit.
23. Collapse state persists per folder. "Collapse All Folders" and "Expand All
    Folders" act on the current Space. Evidence: MainMenu Tabs ▸ "Collapse All
    Folders" / "Expand All Folders"; descriptions "Collapse all folders in your
    current space." (`strings:132883-132884`).
24. Create folder: "New Folder…" (empty) and "New Folder from Selection"
    (wraps selected tabs). Evidence: menu strings `strings:114101-114103`;
    `SidebarNewFolderOperation`, `createFolderFromSelectionInCurrentSpace`.
    Multi-select in the sidebar is supported (**Guess** modifier keys — the
    hotkeys agent should confirm; evidence: "Supports multiselect to prefill
    the created folder", `strings:132842`).
25. Deleting a folder **archives the tabs inside it**; it does not delete the
    tabs permanently. Evidence: "Deleting this folder will archive the tabs
    inside it." and "This will archive all the tabs and folders inside it."
    Show a confirmation with that text pattern.
26. Archiving a whole folder is a separate action ("archive a folder" tooltip,
    feature flag `enable-folder-archive`). Restoring a folder from Archive
    puts it back in a Space with a toast + "view it" action. Evidence:
    `strings` near 125846–125959 ("Toast indicating that a folder was
    unarchived and put back in a space…").
27. **Live Folders** (auto-updating, for example GitHub PRs) exist in Arc but
    are a separate subsystem (`LiveFoldersFeature`, `AutomaticLiveFolderData`).
    They are **not** required for Open v1 manual folders. Note the type exists
    so the data model can reserve a `live` kind; do not implement fetching.

### 1.6 Drag and drop

Evidence base: types `SidebarDragItem`, `SidebarDropType`,
`SidebarDropTargetRegion`, `SidebarDropOperation`, `SidebarDropTarget`,
`SidebarItemDragAction`, `ArcDraggingSession`, plus analytics `viaDrag`,
`dragInitiated`, `dragCompleted`. Rules below marked **Guess** need runtime
verification with two Spaces and nested folders.

28. Drag starts from any tab/folder row after a short hold/distance threshold;
    the dragged row becomes a floating snapshot (`ArcDraggingWindow`,
    `SidebarContentDragPlaceholderView`). (**Guess** threshold.)
29. Valid drop targets: reorder within a section, the other section of the
    same Space (Today ↔ Pinned), into/onto a folder, onto the Favorites tray,
    onto another Space in the Space switcher (moves the tab to that Space),
    and onto the web-content area to open a Split View (other agent; flag
    `sidebar-drag-to-split-preview-ui-enabled`). Evidence:
    `SidebarMoveToGlobalSectionDestination` ("global section" = Favorites),
    `acceptSpaceDrop`, `moveSidebarItems`, `onDropSidebarItem`.
30. Dropping a Today tab into Pinned **pins** it (sets its pinned base URL,
    see §3.2). Dropping a Pinned tab into Today **unpins** it. Dropping onto
    Favorites creates a Favorite (Top App) entry; the original tab stays where
    it was (**Guess** — the `duplicateIfSourceItemIsPinnedOrTopApp` flag hints
    that Pinned/Favorite drags copy instead of move for some targets).
31. Dragging across Spaces keeps the tab's URL and custom title; if the target
    Space uses a different Profile, the tab re-opens under that Profile's
    browser context (cookies/logins change — warn per §5.4). (**Guess** for the
    warning; the profile-move warning itself is proven in §5.)
32. Invalid drops (for example a folder into its own descendant) shake or
    no-op. Evidence: orphan protection strings "Orphan item will be dropped",
    "Orphan was intended to be re-parented into a pinned container, but no
    container was found." Implement cycle checks; exact feedback is **Guess**.
33. Reorder shows an insertion line and haptic feedback when enabled
    (Advanced preference "Haptic feedback when reordering tabs",
    `strings:132557`). Respect that setting; default **Guess** ON.
34. Escape cancels a drag. Dropping outside any target cancels. (**Guess**,
    standard AppKit behavior.)

### 1.7 Sidebar modes: pinned open, compact/floating, hidden

35. The sidebar has a **mode** and a **presentation**. Evidence: enums
    `SidebarMode`, `SidebarPresentation` (BaseModels), fields `sidebarMode`,
    `sidebarWidth`, `sidebarPresentation`, `isCompactSidebar`,
    `isSidebarAnchored`, `isSidebarHovered`, `hasHiddenSidebarWithGesture`.
    Implement three user-visible states: **shown** (anchored, pushes content),
    **compact/floating** (collapsed to a slim strip; hovering the window edge
    floats the full sidebar over content), **hidden** (fully off; edge hover
    or shortcut reveals it temporarily). Exact case names are **Guess** —
    the enum cases are not in strings. Verify transitions at runtime.
36. Toggle via View ▸ "Show/Hide Sidebar" and the sidebar toggle button
    (`sidebarToggleButton`, analytics `sidebar_toggled`, `SidebarToggledSource`).
    The toggle remembers width (`sidebarWidth`, `effectiveSidebarWidth`,
    breakpoints `sidebarBreakpoints`). Drag the sidebar edge to resize
    (`SidebarResizeRegionView`, `SidebarResizeState`).
37. **Sidebar on the right**: no string, setting, or type for a right-side main
    sidebar was found. The only "right sidebar" string is
    `assistantOverlayPreferredRightSidebarWidth` (Dia assistant overlay — a
    different product surface). **Conclusion: Arc 1.170.0 has no user-facing
    right-sidebar option (Proven by absence in strings + nib; still confirm at
    runtime).** Open v1 should keep the sidebar on the left. If Open adds a
    right option later, it is an Open extension, not an Arc clone behavior.
38. Full-screen and compact behavior: in full screen the floating sidebar must
    not fight the system menu bar. No direct string evidence — **Guess**,
    runtime check.

### 1.8 Closing, clearing, and the bottom bar

39. Closing the last Today tab does not close the window. Closing a window
    archives its window-only (unpinned, non-persistent) content per
    `completeCloseWindowContent(_:options:archiveInfo:)` and
    `removeWindowUnpinnedContainers()`. Pinned tabs and Favorites survive
    window close (they belong to the Space/Profile, not the window).
    (**Guess** split of what is window-scoped vs. Space-scoped — the function
    names prove window containers exist; verify which items restore.)
40. **Clear unpinned tabs** (header clear button, Tabs ▸ "Clear Unpinned
    Tabs"): archives **all** Today tabs in the current Space in one action.
    Evidence: "Moves all your unpinned tabs to the Archive."
    (`strings:132806`); variant "Clear unselected Today tabs" archives all but
    the selected tab (`strings:113410-113411`,
    "Deletes all unselected unpinned tabs from the sidebar."). Show a toast
    "Auto archived %d tabs" style confirmation with Undo (**Guess** Undo —
    toasts support undo via `UndoableToastContentOptions`; verify).
41. Bottom bar buttons (implement as icon buttons with tooltips):
    Space switcher (see §2.5), "+" menu (New Tab, New Folder, New Space,
    New Window… — **Guess** menu contents; evidence `sidebarPlusButton` +
    `ARC_SidebarPlusButton.bundle`), Archive (`sidebarArchivesButton`),
    Downloads (opens Downloads in Library; menu Window ▸ "View Downloads"),
    Library (Window ▸ "View Library"). No Media/PiP button: see rule 6.
    Downloads/Library open the Library overlay (`LibraryData`,
    `StorableLibrary.json`); badge the Downloads button while a download runs
    (**Guess**).

---

## 2. Spaces

### 2.1 Model

1. A Space is a named sidebar context inside a window: its own Pinned +
   Today sections, its own theme, and exactly one Profile. Favorites are
   **per Profile**, shared by all Spaces on that Profile (see §5). Evidence:
   types `SidebarSpace`, `SidebarSpaceDataModel`, `orderedSpaces`,
   `focusedSpaceID`; strings "Each Profile has different browser data, so you
   might get logged out of some websites, see different Favorites up top…"
   (`strings` near 126711) and "se different Favorites up top" confirms
   Favorites follow the Profile, not the Space.
2. Every window shows one focused Space at a time (`focusedSpaceID`,
   `lastFocusedSpaceID`, `lastActiveTabsPerSpace`). Switching Spaces swaps
   the sidebar list and the active tab; web contents for other Spaces stay
   loaded or are discarded per §3.4 (**Guess** policy).
3. At least one Space always exists. "No spaces available; creating one
   instead." (`strings`, near 135248). Default first Space name falls back to
   "Space N" ("Fallback title for a space, with the index… e.g. \"Space N\"").

### 2.2 Create, edit, delete

4. Create: Spaces ▸ "New Space…" or the "+" flow. The creation flow asks for
   name, icon/emoji, theme color, and Profile. Evidence: `ARC_SpaceCreation.bundle`,
   `spaceCreationSpaceNameTextField`, `spaceCreationProfileButton`,
   `spaceCreationThemeButton`, `SpaceStyleEditor`; description "Creates a new
   Space — for your work tabs, personal tabs, or otherwise."
5. Edit: rename inline in the sidebar header (`sidebarSpaceName`,
   `didRenameSpace`, `beginDeleteSpace`), change icon (`changeSpaceIcon`,
   `isEditingSpaceIcon`, `SidebarCustomIcon`/`SidebarIconType`), change theme
   (Spaces ▸ "Edit Theme…", `SpaceStyleEditorViewController`), change Profile
   (Spaces ▸ "Change Profile", see §5.4). Header buttons: share
   (`sidebarSpaceShareButton` — sharing is an Arc account feature, **out of
   scope**), edit (`sidebarSpaceEditButton`), more options.
6. Delete: deleting a Space **closes (archives) all tabs inside it**. Evidence:
   alert strings "Confirmation alert that the user wants to delete the space",
   "Text explaining that deleting the space will close all contained tabs.",
   button "Delete the space and close all tabs within it." Support Undo
   (`undoDeleteSpace`, `undoAddSpace`, `undoMoveSpace`,
   `undoUpdateSpaceTheme`, `undoUpdateSpaceIcon`).
7. A Space can be turned into a folder in another Space (`turnSpaceIntoFolder`,
   `Space turned into folder`, `undoTurnSpaceIntoFolder`). Implement as:
   create a folder with the Space's name containing its Pinned+Today items,
   then delete the Space. (**Guess** item mapping — verify.)
8. Reorder Spaces by dragging in the Space manager / switcher ("Drag to
   Reorder Space" tooltip; flag `win-enable-drag-to-reorder-spaces`).
   Spaces ▸ "Manage Spaces…" opens the Space Manager ("Opens the Space
   Manager, where you can rearrange your Spaces, folders, tabs, and more.").

### 2.3 Icon, emoji, and color theme

9. Each Space has a custom icon: an SF Symbol-like icon or an emoji.
   Evidence: `SidebarCustomIcon`, `SidebarIconType`, `SFSymbolEmojiLookupTable.json`
   (`ARCFoundation_ARCFoundationBase.bundle`), `ARC_Emojis.bundle/emojis.json`,
   "Default Space Icon", `updateSpaceIcon`. Ship an emoji + symbol picker;
   recreate the tables, do not copy Arc's JSON assets.
10. Each Space has a color theme that tints the window/sidebar background.
    Evidence: `SpaceStyleEditorColorSet`, `SpaceStyleColorPadView`,
    `SpaceStyleColorPickerView`, `SpaceStyleDialView`, `WindowTheme`,
    `BlendedGradientConfiguration`, "Tap to pick a color for this space",
    "Set space color to ", `didBackfillSpaceThemesFromProfileColor`
    (themes once derived from Profile color). The editor offers preset color
    sets plus a custom picker (color pad + dial). Exact preset palette:
    design-tokens report + runtime picker check. Themes support gradient
    backgrounds rendered with Metal (`WindowThemeBackgroundViewMetal`) —
    Open can use a plain gradient first and match visually.
11. Changing the theme updates all windows showing that Space immediately
    (`WindowData+SpaceStyleEditor.swift`, `undoUpdateSpaceTheme`). (**Guess**
    cross-window sync — verify with two windows.)

Added 2026-10-25 (evidence: Swift reflection records and `llvm-objdump` on the
arm64 slice; full math in `design-tokens.md` §6.5, measured editor layout in
`interaction-states.md` §14):

12. Theme editor model. The editor keeps one key color, a color count (0–3),
    a harmony wheel (`analogous` or `complimentary`), a noise amount and
    texture (`grain`, `sand`, `denim`, `tweed`), an intensity, and an
    appearance mode (Automatic, Light, Dark). Extra colors are HSL hue
    rotations of the key color. Actions (`SpaceStyleEditor.Action`):
    drag the knob, finish dragging, choose a preset, add color, remove
    color, delete all colors, change noise (slider, rotation, dial click,
    scroll wheel, drag), tap the noise knob (cycle texture), change
    intensity, force an appearance, page the presets, end a gesture, and
    Escape. The editor has its own `undoStack` and sends `registerUndo` to
    the window. The window's undo name is "Update Theme" (small-string
    literal at `0x102a109fc`).
13. Empty state. With no color, the pad shows "Tap to pick a color for this
    space" (`0x1017a7fb4`). A tap places the first knob. Removing the last
    color clears the Space theme (`didDeleteAllColors`).
14. Space creation (`SpaceCreation` module). State: `title`, `selectedProfile`,
    `customInfo` (icon), an embedded theme editor state, and a phase
    (`editing`, `animating`, `complete`). Copy: "Create a Space", "Separate
    your tabs for life, work, projects, and more.", "Space name"
    (placeholder), "Choose a Theme", "Profile", "You can use a Profile to give
    this Space its own logins, history, and browsing data.", "New Profile…"
    (menu item), "Create Space", "Cancel", "Remove icon". Views: a header with
    fanned emoji cards (rotations ±16° and ±20°), a name field with an icon
    button, a theme card, a profile card with a pop-up menu, and a submit
    button that sits inline or is anchored to the bottom. The layout changes at
    width breakpoints of 190 and 227 pt (`0x1025a3d4c`, `0x1025a3db0`). A color
    "splash" (blur and opacity) plays on create. Options carry an insertion
    index (`after(Space)` or `absolute`) and optional pinned/unpinned items
    (used by "Move to ▸ New Space…"). Undo name "New Space". guess (strong):
    the form is a page in the sidebar column; the width breakpoints match
    sidebar widths.
15. Icon picker (`CustomInfoPicker` module) is shared by Spaces, tabs, and
    folders. Two icon sets: `tabAndSpacePicker` and `folderPicker`. Two pages:
    `emoji` and `icon`. Emoji page: "Search" field, category buttons
    (`smileysAndPeople`-style groups through `symbols` and `flags`), an
    `NSCollectionView` grid (items 28×28 pt, item gap 5, line gap 2, side
    insets 10; `0x102253c88…0x102253cc0`), skin-tone popover. Icon page: a grid
    of 28 pt buttons with 17 pt glyphs and a hover background. A remove option
    when an icon is set. Undo names "Customize Space" and "Customize Tab"
    (`0x1029d1a30`, `0x1029e617c`).
16. Rename. The Spaces menu item shows a dialog with "Rename" and "Cancel"
    buttons (`0x1029d4e44`, `0x1029d4ee0`; strings "Button that updates the
    Space name", "Cancel updating Space name"). The context menu item is
    "Rename Space…" (`interaction-states.md` §15); what it opens was not
    captured. guess: the context menu edits inline in the header, and the
    dialog serves the menu bar item when the sidebar is hidden.

Added 2026-10-26 (Step 9 decode; evidence: `llvm-objdump` on the arm64 slice,
one read-only Ghidra run on the shared project with `-noanalysis -readOnly`,
Swift reflection records, and capture session 2 item 17 frames; raw output and
the fit script are local in `.re/theme-pad/`):

17. **Theme pad, intensity, and texture law.** This replaces the pad-range part
    of `design-tokens.md` §6.5 and closes the round-3 Step 9 gaps. Each sub-item
    gives the evidence. Values are facts unless marked **guess**.

    **17a. The lightness range is editor state, not a mode constant.** The
    editor state holds `lightnessRange` and `saturation`. The pad maps radius
    linearly into that range. The range is re-centered on the key color in
    these cases:

    | Event | Range | Saturation | Evidence |
    |---|---|---|---|
    | Editor opens on a Space with no color | 0.01…0.97 | 1.0 | `State.init` `0x1017a8050` (constants 0.01, 0.97, 1.0); reset case `didDeleteAllColors` `0x1017aa994` stores the pair (1.0, 0.01) from `0x103760070` and 0.97. Session 1 F0137: the first color has P3 saturation 0.9995 and sits at t = 0.273 of 0.01…0.97 (45.98 pt predicted, 45.26 pt measured). |
    | Editor opens on a color, Automatic | `max(0.01, l − 0.25)` … `min(0.97, l + 0.25)` | `max(0.01, s)` | Helper `0x1017a9414` (constants −0.25, 0.01, 0.25, 0.97; 0.75 and 0.97 when the color has no P3 form), called from `State.init`. |
    | Editor opens on a color, forced Light / Dark | Light 0.575…0.97, Dark 0.01…0.425, widened to include `l` if `l` is outside | `max(0.01, s)` | `State.init` `0x1017a8050` (branch on the `forceAppearance` bias). |
    | Preset tap (`didSelectColorSet`), Automatic | `l ± 0.25` as above | `max(0.01, s)`, or 1.0 when the color has no P3 form | Reducer case 1 `0x1017aa388`; the call to `0x1017a9414` at `0x1017aafa4` is skipped when the bias tag is `forceAppearance` (`0x1017aaf98`). |
    | Preset tap, forced Light / Dark | unchanged | as above | same branch |
    | Force Light / Dark (`didForceAppearance`) | Light 0.575…0.97, Dark 0.01…0.425 | unchanged | Reducer case 4 `0x1017aa854`: `t = clamp((l − lo)/(hi − lo))` with the **current** range, then `l' = lo' + span'·t` (spans 0.395 / 0.415 at `0x1017aa904`, `0x1017aa918`). Hue and saturation stay. |
    | Drag, add, intensity, noise | unchanged | unchanged | Reducer cases 0, 2, 3, 9 do not write the range fields (`+0x48`, `+0x50`). |
    | Remove the last color | 0.01…0.97 | 1.0 | Reducer case 10 `0x1017aa26c`: when the count reaches 0 it stores the same reset values as `didDeleteAllColors` (`0x1017aa334`–`0x1017aa364`). Other removes keep the range. |

    `l` and `s` are P3 HSL lightness and saturation of the key color. The range
    is not stored in the theme JSON (no such field in the reflection records or
    in `StorableSidebar.json`), so it is rebuilt each time the editor opens.

    The reducer is one jump table at `0x1017a9dcc` (table `0x1017ab320`, 16
    cases in the `SpaceStyleEditor.Action` declaration order: drag knob,
    color set, noise, intensity, force appearance, preset page, delegate,
    finish drag, delete all, add, remove, end gesture, Escape, tap noise
    knob, on appear, appearance updated). Returning to **Automatic** is a
    delegate message (`didSetAutomaticAppearance`), not a reducer case. **guess:**
    the host keeps the current range; no code path that re-centers it was found.

    **17b. Pad mapping with that range.** Knob → color (`0x1017a724c`): hue =
    `atan2(y, x)` in degrees, plus 360, modulo 360 (stub `atan2` `0x1035dcbf0`);
    `t = min(max(distance/0.99, 0), 1)` (0.99 at `0x1017a72cc`);
    `l = lo + t·(hi − lo)`; saturation from the state; result = P3 HSL color,
    alpha 1 (`0x1009a59a0`). Color → knob (`0x1017a6f28`):
    `r = 0.99·clamp((l − lo)/(hi − lo), 0, 1)`, angle = hue. The unit disc
    has a 170 pt radius on screen.

    Capture check (session 2 item 17; knob centers from the white ring, colors
    converted from the capture's display profile to Display P3):

    | Frames | What | Decoded | Arc | Error |
    |---|---|---|---|---|
    | 0027–0045 | Greyscale 1–9 knob centers | range `l ± 0.25` | all on the 0° axis | ≤ 0.9 pt each; the old fixed 0.01…0.97 range is off by up to 39.4 pt |
    | 0033 / 0035 / 0037 | Greyscale 4 / 5 / 6 | all at t = 0.5 → 84.2 pt | 83.5 pt for all three | 0.8 pt; this is why mid greys share a radius |
    | 0065 | Brand 8 knob | (−78.8, −29.4) pt | (−79.5, −29.5) pt | 0.7 pt (old law 30.3 pt) |
    | 0092 | knob at the center after Brand 8 | P3 (162.1, 51.5, 93.7) | (163.0, 53.0, 95.0) | ΔE00 0.39 |
    | 0093 | knob at r 0.485 | P3 (213.4, 124.1, 124.6) | (213.0, 125.0, 126.0) | ΔE00 0.37 |
    | 0098 | knob near the edge, at rest | P3 (241.2, 211.5, 211.6) | (242.0, 213.0, 213.0) | ΔE00 0.40 |

    After Brand 8 (P3 HSL h 200.5°, s 0.5176, l 0.6667) the range is
    0.4167…0.9167. So the pad center is a deep color at l 0.417, not black.
    In 0092 the knob is within 1 pt of the center, so its angle cannot be
    measured; the check takes the hue from Arc's knob and tests only
    lightness and saturation. The knob is drawn clipped at the content edge
    (window x 597), so edge positions use the ring's left edge plus 22 pt.

    **17c. Sidebar color and intensity.** The SwiftUI theme style view
    (`0x1015322b8`, module `WindowThemeUI`) reads the style's `noiseFactor`,
    `intensityFactor`, and `overlay` and builds three layers:

    - Theme color at opacity `a = 0.2 + 0.55 × intensity` (constants 0.55 at
      `0x101532444`, 0.2 at `0x101532458`).
    - Under it, a wash: `Color.black.opacity(0.35)` when the color scheme
      test is true, else `Color.white`; then `.opacity(min(a, 0.5))`
      (`0x10153240c`–`0x101532470`; stubs `Color.black`, `Color.white`,
      `Color.opacity(_:)`, `ColorScheme.==`). **guess (strong):** the black
      branch is Dark. The macOS Dark capture fits it.
    - The texture image, at opacity `noise × k` (17d).

    The Metal path has the same inputs: `GradientRenderConfiguration` holds
    `underlayColor` and a per-layer `alpha` (strings in
    `ARC_WindowThemeUI.bundle/…/default.metallib`). Its CPU fill function was
    not decoded. The capture fits the SwiftUI law:

    `sidebar = a·key + (1 − a)·M·(1 − 0.35·min(a, 0.5))`

    This is composited in gamma-encoded P3. `M` is the material under the
    theme. It is 0.8246 in this capture (fitted on 9 greys, spread
    0.820–0.829).

    | Frame | Intensity | `a` | Arc sidebar P3 | Decoded | ΔE00 |
    |---|---|---|---|---|---|
    | 0098 | 0 | 0.20 | (204.5, 199.1, 198.8) | (204.7, 198.7, 198.8) | 0.39 |
    | 0100 | ≈ 0.5 | 0.475 | (206.3, 192.5, 192.9) | (206.6, 192.5, 192.5) | 0.21 |
    | 0095 | 0.8 | 0.64 | (217.1, 198.3, 198.4) | (216.8, 197.8, 197.9) | 0.14 |
    | 0102 | 1 | 0.75 | (224.4, 202.9, 202.9) | (224.2, 202.0, 202.1) | 0.36 |
    | 0092 | 0.8, pad center | 0.64 | (168.7, 98.0, 122.5) | (166.2, 95.4, 122.4) | 1.23 |
    | 0093 | 0.8, mid radius | 0.64 | (200.2, 143.4, 142.9) | (199.0, 141.9, 142.2) | 0.54 |
    | 0065 | 0.8, Brand 8 | 0.64 | (144.6, 180.0, 198.8) | (143.1, 180.2, 199.4) | 0.45 |

    The tint at intensity 0 is the 0.2 floor. The wash also gets lighter at
    low intensity: the underlay is M × 0.93 at intensity 0 and M × 0.825 from
    intensity 0.55 up. Compositing in gamma-encoded sRGB instead of P3 raises
    the 0092 error to 2.55, and linear light raises it to 5.97 (fit only;
    **guess:** the window composites in the display's space, which is close
    to P3 on this display). A frame captured while the knob moved (0091,
    second window image) is not used: the sidebar lags the knob there.

    **17d. Texture opacity per texture.** Helper `0x10153258c` switches on
    `overlay` and multiplies the noise factor before it draws the tile image
    (small-string names `grain`, `sand`, `denim`, `tweed`):

    | Texture | Multiplier `k` | Evidence |
    |---|---|---|
    | grain | 0.80 | `0x101532600` |
    | sand | 0.15 | `0x101532648` |
    | denim | 0.60 | `0x101532628` |
    | tweed | 0.40 | `0x10153266c` |

    Each texture click sets noise to exactly 0.80 (session 2). So the textures
    draw at opacity 0.64 / 0.12 / 0.48 / 0.32. Arc's tiles differ in darkness,
    so the visible darkening is not ordered by `k`. Measured at intensity 1
    (0111 → 0112/0114/0116/0118, region x 30–200, y 820–1020, Display P3, CIE
    L* of every pixel):

    | Texture | Mean color ÷ plain (encoded) | ΔL* | L* standard deviation | Tile mean darkness = (1 − ratio)/(0.8·k) |
    |---|---|---|---|---|
    | none | 1 | 0 | 0.17 | — |
    | grain | 0.9614 | −2.89 | 2.02 | 0.060 |
    | sand | 0.9621 | −2.84 | 1.53 | 0.316 |
    | denim | 0.9414 | −4.40 | 1.28 | 0.122 |
    | tweed | 0.9160 | −6.32 | 0.92 | 0.262 |

    The darkening is the same in R, G, and B within 0.001 (grain ratios
    0.9617 / 0.9606 / 0.9616), so the texture is a neutral darkening. Tweed is
    the darkest and the smoothest; grain is the lightest per unit of opacity
    and the roughest. The tile darkness column is our fit, not a decoded
    constant. One noise value per texture was captured, so linearity in
    noise is a **guess**.

    **Not decoded:** the Metal renderer's own fill function, the light-mode
    wash (white at `min(a, 0.5)` by the decoded branch, but not captured over
    a light theme), the inactive-window material, and whether the
    `isActive ? 1.0 : 0.25` value at `0x1015324b0` scales the texture or
    another layer.

### 2.4 Switching

12. Switch by: clicking a Space in the switcher, Spaces ▸ "Next Space" /
    "Previous Space", swipe/trackpad gesture (**Guess** gesture details;
    flags `win-spaces-scroll-view-manual-snapping-enabled`,
    `win-allow-mouse-wheel-space-navigation`), and number shortcuts
    ("Jumps over to your %@ Space without needing to swipe.",
    "Go to Sidebar Item N" family in Shortcuts preferences). The hotkeys
    agent owns exact key equivalents; the sidebar must animate a horizontal
    page slide (`SidebarPagingContainerViewController`,
    `SidebarPagingContainerCollectionViewLayout`).
13. Space switching preserves each Space's last active tab
    (`lastActiveTabsPerSpace`). Returning to a Space restores its previous
    tab instead of jumping to the first tab. (**Guess** — field name is the
    only evidence; verify.)

### 2.5 Space switcher UI

14. The switcher sits at the sidebar bottom and shows one entry per Space:
    icon/emoji with the Space color, active entry highlighted. Evidence:
    `spaceSwitcher`, `SpaceSelectionHorizontalView`, `spaceHeader`,
    `sidebarSpaceHeaderIndicator`, "Item description for sidebar space
    accessibility role." Long Space lists scroll horizontally (**Guess**).
    Include a trailing "+" or "New Space" affordance (Spaces ▸ "New Space…"
    must exist even if the button differs).

### 2.6 Space ↔ Profile mapping

15. Many Spaces → one Profile is allowed; one Space → exactly one Profile.
    Evidence: "You can use any Profile across one or more Spaces."
    (`strings:132694-132695`); `didSetProfileForSpaceIDs(_:profile:…)`,
    `createProfileForSpaceIDs`, `ProfileAssignedToSpaceEntrypoint`.
    Full Profile rules in §5.

---

## 3. Tab lifecycle

### 3.1 Kinds of tabs

1. Three persistent kinds share one item model (`SidebarItem`,
   `SidebarItemDataType`): **Favorite** (Top App, per Profile),
   **Pinned** (per Space, has a pinned base URL), **Today** (per Space,
   auto-archives). Folders and Split groups are container kinds
   (`SidebarTabGroup`, `SidebarSplitViewData` — Split details: other agent).
2. Incognito windows have only Today-style tabs with a distinct header:
   "Title for Unpinned tabs in an incognito window sidebar." No Pinned or
   Favorites in incognito (**Guess** — header string proves a separate
   unpinned list; verify that pinning is disabled there).

### 3.2 Pinned tabs: reset to pinned URL

3. Every Pinned tab stores a **pinned (base) URL** plus the **current URL**.
   Navigating away changes only the current URL. Evidence: strings "Back to
   Pinned URL" (`strings:113974`), "Reset Tab to Original URL",
   "Tooltip title for resetting a pinned tab.", "Fallback title for a page's
   pinned URL title", dialog "Title of Edit Pinned URL dialog." /
   "Pinned tab URL input placeholder." / "Button that updates the pinned URL".
4. When current URL ≠ pinned URL, the row (or tab UI) shows a
   **back-to-pinned affordance**. Activating it navigates the tab back to the
   pinned URL. Evidence: "Back to Pinned URL". Exact affordance (button on
   hover vs. always-visible dot) is **Guess** — runtime check.
5. "Close and Keep Pinned" closes the web content but keeps the Pinned entry.
   Evidence: string "Close and Keep Pinned" (`strings:113987`). Closing a
   Pinned tab with the normal close archives/removes the entry instead
   (**Guess** distinction — verify both paths).
6. "Replace Pinned Tab with the Current Site" / "Replace Pin with Current
   Page" sets pinned URL := current URL. Evidence: action strings
   `strings:131536-131556`, menu "Replace Pinned URL with Current",
   "Edit the pinned URL", submenu "Title of Pinned URL submenu." /
   "Edit Pinned Page".
7. "Separate From Pinned Tab" detaches the navigated-away page into its own
   Today tab while the Pinned tab resets. Evidence: string "Separate From
   Pinned Tab" (`strings:113976`). (**Guess** exact semantics.)
8. "Reset all tabs in this Space" (Tabs menu) resets every Pinned tab in the
   focused Space to its pinned URL. Evidence: "Resets all your pinned tabs
   in the current Space." (`strings:132862`), "Title to reset Pinned Tabs
   while on a focused list."
9. Pinning a Today tab (drag to Pinned, "Pin/Unpin Tab", "Move to Pinned in
   \<Space\>") sets its pinned URL to its current URL at pin time. Unpinning
   moves it to Today and drops the pinned URL. Evidence: `tabPinned`,
   `tabUnpinned`, `tabPinnedToFolder`, descriptions in §1.4.

### 3.3 Today tabs and auto-archive

10. Today tabs that stay inactive past a threshold are **auto-archived**
    automatically. Evidence: `AutoArchiveType`,
    `AutoArchiveInactiveThreshold`, `ArchiveState+AutoArchive.swift`,
    `runAutoArchive`, `simulateAutoArchive`, banner "Arc archives tabs that
    you haven…" (Auto Archive EDU banner).
11. Threshold options (Proven list, from threshold strings
    `strings` in `.re/features-core/extract-autoarchive.txt`):
    **Never, 1 hour, 6 hours, 12 hours, 24 hours, 7 days, 30 days.**
    A hidden debug value "20 seconds" exists for debugging only — do not ship
    it. Default value is **not** proven by strings. **Guess: 12 hours** (Arc's
    long-standing default); confirm at runtime on a fresh profile before
    shipping. This is the single most important default to verify.
12. Thresholds can be set **per Profile** and separately for **Little Arc**
    windows. Evidence: `AutoArchiveTimeThresholdsPerProfile`,
    `autoArchiveTimeThresholdsPerProfile`, `autoArchiveLittleArcTimeThreshold`,
    `setAutoArchiveTabsTimeThresholdForProfile(state:profile:archiveType:threshold:)`,
    `setAutoArchiveTabsTimeThresholdForAllProfiles(…)`, dialog strings
    "Arc will now archive your tabs after %@", "Arc will never auto-archive
    your tabs.", buttons to update all Profiles vs. only the current Profile.
    Open rule: one threshold per Profile (applies to all its Spaces) plus an
    independent Little Arc threshold. Changing it in Settings offers
    "apply to all Profiles" vs. "this Profile only" (**Guess** that Open needs
    the same prompt — implement it; the dialog text proves Arc asks).
13. Auto-archive only touches Today tabs. Pinned tabs and Favorites never
    auto-archive. (**Guess** — strongly implied by "archive your [unpinned]
    tabs"; the `archiveType` parameter separates tab kinds. Verify that
    folders protect their children the same way.)
14. Manually closing a tab archives immediately regardless of the threshold
    (§1.2 rule 11). "Archive Tab" (File menu) is the explicit command.
15. An education banner explains auto-archive once ("Title for Auto Archive
    EDU sidebar banner", keys `auto_archive_education_displayed_when_tabs_auto_archive`,
    `auto_archive_education_dismissed`). Open: show a dismissible equivalent
    once per Profile (**Guess** frequency).

### 3.4 Sleeping / discarded web contents

16. Background tabs' web contents can be **frozen** (suspended, state kept)
    or **discarded** (destroyed, reload on focus). Evidence: metrics fields
    `discardedWebContentCount`, `frozenWebContentCount`, strings "Web content
    has been discarded", `ADKClient.discardWebContent`, keep-alive allowlist
    in `web_content_behavior.json` key `keepaliveAllowList` (Gmail, Slack,
    Notion, Spotify, calendar, chat and docs apps must stay alive). Implement:
    never discard keep-alive-listed sites, the active tab, tabs playing
    audio, or tabs in the visible Split. Discard policy triggers (memory
    pressure, tab count, time) are **Guess** — Chromium's tab discarding is
    the model; verify against Arc with many tabs.
17. Battery Saver interacts with sleeping: toasts "Battery Saver Mode
    Activated / Deactivated" exist, with a Settings shortcut. Evidence:
    `strings` near 128365–128367, "Toast accessory indicating that the user
    can change their Battery Saver mode settings." Power policy details are
    **Guess**; Open v1 can map Battery Saver to "discard sooner + pause
    animations" and verify later.

### 3.5 New Tab behavior

18. "New Tab" does **not** open a blank page. It opens the **command bar**
    (§4) in the sidebar context; submitting creates the Today tab. Evidence:
    `showCommandBarOnNewlyCreatedWindows`, `isCommandBarNewTabPlaceholderActive`,
    "Open the Command Bar to create a new tab" (Essential Shortcuts EDU),
    onboarding "Start browsing by clicking New Tab in your sidebar or typing…".
    Tabs ▸ "New Tab…" and File ▸ "New Tab…" are the same action.
19. A new window also starts with the command bar focused
    (`showCommandBarOnNewlyCreatedWindows`). "Blank Window" (File menu) is the
    separate no-command-bar variant (**Guess** difference — both items exist
    in the nib: "New Window" and "Blank Window"; verify what each shows).

### 3.6 Archive window and restore

20. The Archive is a Library page listing every archived tab and folder with
    title, favicon, original Space, and archive time. Evidence:
    `archivedItems`, `archiveFaviconCache`, `archiveSnapshotCache`, filters
    "Library Archive Tabs Space Filter Title", "…Little Arc Filter Title",
    "…Page Close Type Filter Title" (filter by Space, by Little Arc vs. main,
    by close type: manual vs. auto). Search/filter UI text: "Subtitle label
    for a folder in the archive".
21. **Restore** ("Restore menu item in archive page",
    `unarchiveAndPutBackItem(_:desiredSpaceID:selectItem:…)`) puts the item
    back into a chosen Space and selects it, with a toast ("Toast indicating
    that a tab was unarchived and put back in a space, with a prompt to view
    it" + a plain variant without the prompt). **Delete** ("Delete menu item
    in archive page") removes the record permanently. (**Guess**: Delete asks
    for confirmation like Clear Archive does.)
22. **Clear Archive** (Archive menu ▸ "Clear Archive") deletes all archive
    records after confirmation: "Are you sure you'd like to Clear Archive?" +
    "Title/Message of the confirmation dialog to confirm clearing the
    archive", analytics `archiveCleared`. Archive records live in
    `ArchiveDataStoreClient` / `StorableLinkRouting`-style JSON stores
    (`archiveDataStore`, `PersistedArchiveState`); the data-model agent owns
    the file format for Import.
23. Empty state: "Title for when Arc Home archived tabs aren…" +
    "Page title for when Arc Home archived tabs aren…" (truncated in strings;
    full text is a runtime/help check). Open: show an equivalent empty state.

### 3.7 What loads on launch

24. On launch Arc restores windows from the previous session when the
    Advanced/General preference is on: "When opening Arc, restore windows
    from previous session" (`strings:132555`), keys
    `shouldRestoreWindowsOnLaunch`, `restoreWindowsOnNextLaunch`,
    `onToggleRestoresWindowsOnLaunch`. Default **Guess: ON**. Restored
    windows reopen their Spaces and selected tabs; background web contents
    restore lazily via Chromium session restore ("Chromium has started
    restoring session for profile: ", `profilesExpectingRestoration`).
25. With restore off (or first run), Arc opens one window on the last focused
    Space/Profile with the command bar ready (§3.5). Evidence:
    `lastFocusedSpaceID`, `Restorable window has invalid space, will default
    to first available space.` First-run onboarding (Welcome/Arc 101) is out
    of scope except: do not block the sidebar behind sign-in — Open has no
    account (AGENTS.md locked decision).

---

## 4. Command bar (Cmd+T / Cmd+L)

### 4.1 Entry points and modes

1. One input serves both "new tab" (Cmd+T path) and "edit current URL"
   (Cmd+L path). Evidence: File ▸ "Open Command Bar", Tabs ▸ "New Tab…",
   types `CommandBarInstance`, `StandardCommandBarInstance`,
   `CommandBarEntryPoint`, `DiaCommandBarEntryPoint`. The hotkeys agent owns
   the exact key equivalents; the command bar must accept both entry points:
   - **New-tab mode**: empty query, new Today tab on submit.
   - **Edit mode (Cmd+L)**: query pre-filled with the current tab's URL,
     fully selected; submit navigates the **current** tab. Evidence:
     `CommandBarEditPolicy`, `setEditPolicy(_:)`, placeholder view showing the
     current URL with lock icon (`CommandBarPlaceholderIconLockSecure` /
     `…Insecure`).
2. While a tab is focused and the command bar is closed, the sidebar top
   shows the **placeholder pill**: favicon/lock + current title/URL + copy
   buttons. Evidence: `CommandBarPlaceholderView`,
   `CommandBarPlaceholderButtonsView`, accessibility labels "opens site
   control center", "copies the current URL", "copies the current URL as a
   quote" (`strings:114042-114046`). Clicking the pill opens edit mode.
   Site Control Center itself: other agent.
3. Esc closes the command bar and returns focus to web content without
   changing the tab. Selecting a result closes it and focuses the target.
   Evidence: `CommandBar/ViewReducer`, `dismissCommandBar`,
   `didDismissCommandBarViaSelection`, View ▸ "Exit" pattern (**Guess** for
   Esc specifically — standard, verify).

### 4.2 Sources searched

4. The index covers these sources. Evidence: `SearchClient.indexSources`,
   `SearchClient.search`, `ContentPanelCommandBarQuerySource`, suggestion
   archetypes `chromiumSearchSuggestion`, `chromiumSearchHistory`,
   `chromiumSearchWhatYouTyped`, `chromiumSearchOtherEngine`,
   `chromiumSearchCalculatorAnswer`, `chromiumNavigateSuggestion`:
   - **Open tabs** in all Spaces/windows ("Switch to tab" results; caption
     variants "Switch to Split View" when the tab is in a Split).
   - **Pinned tabs and Favorites** (as switch-to or open actions).
   - **History** (Chromium history for the current Profile).
   - **Search-engine suggestions** for the query (see §4.5), labelled as web
     search results.
   - **"What you typed"**: navigate-to-URL if the text parses as a URL/host,
     otherwise search the default engine.
   - **Calculator / instant answers** (`chromiumSearchCalculatorAnswer`,
     `chromiumSpecialSearchFunction`).
   - **Browser actions/commands** (§4.4) via trigger phrases.
   - **Extensions**: "Action to use an extension's action",
     `extensionOmnibox` (extensions can register omnibox keywords).
   - **Site Search** scoped mode (§4.6) and, when enabled, **ChatGPT** scoped
     search (Max — out of scope, list only).
   Bookmarks as a separate Chromium bookmark source were **not** found;
   Arc's Pinned/Favorites replace bookmarks. (**Guess**: history covers old
   bookmarks after import. Do not add a bookmark source.)
5. Results from other Profiles are excluded. History, suggestions, and
   switch-to-tab respect the current window's Profile. (**Guess** — follows
   from Profile isolation §5; verify that open-tab results include tabs from
   other Spaces on the same Profile but never another Profile.)

### 4.3 Ranking

6. Ranking is a learned on-device ranker over candidates, not plain string
   match. Evidence: `LocalCommandBarRankingProvider`,
   `rankCommandBar(input:candidates:)`, `CommandBarRankingInput/Candidate/Result`,
   `CommandBarAdditionalRankingDataStoreClient` (`StorableCommandBarAdditionalRankingData`),
   debug UI "Command Bar Ranking Configuration" with per-feature and
   per-category scores (`perFeatureScores`, `perCategoryScores`,
   `ASE2/ScoreAndWeights.swift`, "Unsupported ranking features: Time spent
   features; historySearch, historyNavigation"). Open cannot clone the model.
   Implement a deterministic scorer that matches the observable order:
   exact/prefix title+host matches first, then open tabs, then pinned/
   favorites, then history by recency/frequency, then suggestions.
   Mark this whole rule **Guess** — tune against runtime examples.
7. Duplicate results for the same page are merged for known multi-page apps.
   Evidence: `ARC_CommandBar.bundle/.../command_bar_behavior.json` key
   `dedupByTitleAndHostList`: `figma.com`, `maps.google.com`, `notion.so`,
   `app.notion.com`, `zoom.us`, `opentable.com`, `zillow.com`, `github.com`,
   `app.mode.com`, `console.cloud.google.com`. Rule: for these hosts, dedupe
   candidates by (title, host). Ship the same host list as data.
8. Typing is debounced/state-machined (`TypeLetterInCommandBarStateMachine`,
   events `letterTyped`, `allResultsCollected`). Keep input responsive:
   local sources answer synchronously; network suggestions merge in when
   they arrive without moving the current selection (**Guess** selection
   stability — verify).

### 4.4 Built-in commands/actions

9. Typing natural-language trigger phrases surfaces browser actions. Proven
   action set (trigger + description strings `strings:131512-131633`,
   `133491-133500`; full list in `.re/features-core/extract-commandbar.txt`).
   Open must implement at least these command-bar actions:

| Action (user text) | Behavior |
|---|---|
| Air Traffic Control | Open link-routing settings (§6) |
| Manage search settings / Search Settings | Open search-engine settings |
| Manage Passwords | Open password manager (Profile) |
| New Tab / New Folder / Create New Folder | Create item (folder variant: "Command Bar suggestion title for creating a new folder with items.") |
| Duplicate Current Tab | §1.4 rule 18 |
| Rename Current Tab | §1.3 |
| Pin/Unpin; Move to Pinned in \<Space\>; Move to Today in \<Space\>; Move to Top Apps; Remove from Top Apps | §1.4 moves |
| Replace Pinned Tab with the Current Site; Reset tab | §3.2 |
| Expand All Folders; Collapse All Folders | §1.5 |
| Focus on \<Space\> ("Focus on <space>") | Switch Space |
| Mute all tabs; Unmute all tabs | §1.2 rule 10 |
| Toggle sidebar (show/hide/lock/anchor variants) | §1.7 |
| Join next meeting / Join next video conference | Open next calendar meeting link (needs calendar integration — **Guess** scope; string proven) |
| Extension by name ("Action to execute an extension by name") | Run extension action |
| New Google Doc etc. ("Action to create a new document") | Open the service's new-document URL (**Guess** URL table) |
| Split actions (Add/Convert/Flip split…) | Other agent — reserve phrases |
| Undo / Redo by name ("Action to undo an action by name") | Undo stack (**Guess**) |

   Trigger matching uses `triggerPhrases` + `minQueryLengthForMatch` +
   fuzzy confidence (`fuzzySearchConfidence`, `highFuzzySearchConfidence`).
   Implement prefix + fuzzy match over action titles and phrases.
10. Actions that do not apply now (for example "Replace Pin" on a Today tab)
    are hidden, not disabled. (**Guess**.)

### 4.5 Search engines

11. The default engine is **Google**. Evidence: `GoogleSearchEngine`,
    URL templates `https://www.google.com/search?q=%s` (plus `&tbm=isch` for
    images, `&tbm=nws` for news), `SearchEngineClient.swift`,
    `getDefaultSearchEngine`, `onSetDefaultSearchEngine`. Settings:
    "Default Search Engine", "Include search engine suggestions"
    (`searchSuggestEnabled`, `onSetSearchSuggestEnabled`), page
    `arc://settings/searchEngines` ("Manage your default search engine… in
    Profile Settings").
12. The engine list is user-manageable per Profile: add/remove custom engines
    (`addSearchEngine(_:)`, `removeSearchEngine(_:)`, "Add search engine
    error." / "Remove search engine error."), each with a keyword/URL template
    (`searchURLTemplate`, `SearchEngineOptions`, `WebSearchEngineOptions`).
    Which engines ship by default besides Google is **not** proven (a
    `duckDuckGo` provider string exists in WebSearch internals;
    `BraveSearchEngine` powers Ask/Browse-For-Me scraping, not necessarily
    the omnibox). **Guess**: Google, Bing, DuckDuckGo, Yahoo, Ecosia via
    Chromium's default set. Runtime check in Settings is required. Open v1:
    ship Google default + the Chromium default list + custom engines.
13. Suggestions privacy: before first use, a privacy notice explains that the
    engine receives keystrokes: "We talk to your search engine to help us
    suggest results." with "Learn more about your data on Arc" and a
    permanently-hide button. Evidence: `CommandBarSearchSuggestionsPrivacy`,
    `SearchSuggestionsPrivacyView`, key
    `commandBarSearchSuggestionsPrivacyHasBeenExplicitlyDismissed`. Implement
    the same one-time notice; suggestions can be turned off (rule 11).

### 4.6 Scoped search ("Search tabs", Site Search)

14. **Scoped search** narrows the command bar to one source. Evidence:
    `CommandBarScopedSearchType`, `scopedSearchType`, `isInScopedSearch`,
    `CommandBarInputScopedSearchPillView` (a pill in the input shows the
    active scope), "title for scoped search of browser actions in Arc".
    Proven scopes: **browser actions** (commands only), **Site Search**
    (search inside one site), **ChatGPT** (Max, out of scope). A dedicated
    "Search tabs only" scope is implied by "Caption for switch-to-tab
    results…" + `migratedToTabOnlySiteSearchTrigger` ("tab-only" trigger
    migration) — implement a Tabs scope; exact entry gesture is **Guess**.
15. Site Search: typing a known site's keyword/name then **Tab** or **Space**
    enters Site Search for that site ("Hint for using the Tab key to enter
    Site Search", "Hint for using the Space key to enter Site Search.",
    `siteSearchSpaceTriggerEnabled`, `keywordSearchSpaceTriggeringEnabled`).
    The input shows "\<Site\>" pill; placeholder "Site Search placeholder
    where the wildcard is the name of the site." Manage via "Change Site
    Search" submenu, "Remove \<Site\> Site Search", "Menu item to manage site
    searches." Seeded defaults exist (`seededPopularSiteSearches`,
    `onReseedDefaultSiteSearches`). Open: seed a small popular-site table
    (recreate; do not copy Arc's data file) + learn from history (**Guess**).
16. In scoped mode, Backspace on an empty query exits the scope
    (`latestInputAndDidBackspace`, `queryBeforeEnteringScopedSearch` —
    **Guess** binding; standard pattern, verify). The pill can be removed
    with its × ("Title for action to go back to the previous search state.").

### 4.7 Keyboard behavior and toasts

17. Keys (verify against the hotkeys report; command-bar-local behavior):
    Up/Down move selection (`commandBarUnselectedSuggestion`,
    `commandBarSelectedSuggestionOther/WebSearch/Assistant` view states),
    Enter opens the selection, Tab enters Site Search or the alternate
    action ("Hint for using the Tab key to enter an alternative action"),
    Esc closes (§4.1 rule 3). Mouse hover sets selection (**Guess**).
18. After **Copy URL** (shortcut or placeholder button), show a toast
    confirming the copy. Evidence: `copy-url` shortcut client, toast system
    `ToastController`, `URLCopiedSource`, analytics `url_copied`,
    `copy_url_keyboard_shortcut_used`, toast content types
    `ShortcutToastContentOptions`. Toasts auto-dismiss; Undoable toasts offer
    Undo (`UndoableToastContentOptions`) — use them for archive/clear actions.

---

## 5. Profiles

### 5.1 Model

1. A Profile is a Chromium browser profile plus Arc metadata (name, order).
   Evidence: `StorableProfiles.json`, `StorableProfileContainers.json`,
   `profileDirectoryBasename`, `defaultProfileDirectoryBasename`,
   "Default profile display name", `profileOrdering`, Chromium logs
   "Chromium has started restoring session for profile: ". One default
   Profile exists from first run; its display name was migrated to "Personal"
   (`didAttemptDefaultProfileNameMigrationToPersonal` — **Guess** that the
   default name is Personal; the migration key proves a rename happened).
2. Create via Profiles preferences or the Space profile picker ("Create a new
   Profile", "What do you want to call this Profile?", name must be unique:
   "A Profile with that name already exists.", invalid characters rejected:
   "Invalid Profile name."). Evidence: `ARC_ProfilesUI.bundle`,
   `CreateProfileDialog`, `CreateProfileView`, `existingProfileNames`.
   Creation flow: name → pick which Spaces use it ("Which Spaces should use
   this Profile?", "These Spaces will start fresh in your brand new Profile")
   → done. Selected Spaces switch to the new (empty) Profile.
3. Rename via Profiles preferences ("Rename your Profile", "This won't affect
   the names of any of the Spaces associated with this Profile."). Delete:
   only Profiles **not assigned to any Spaces** can be deleted; the Default
   Profile can never be deleted. Evidence: "Only Profiles not assigned to
   any Spaces can be deleted.", "The Default Profile cannot be deleted.",
   `DeleteProfileDialog`, `deleteUnusedProfilesButtonEnabled` ("Deleting
   unused Profiles will permanently remove any cookies, history, preferences,
   and logins that belong to those Profiles."). Deletion wipes that
   Profile's Chromium profile directory.

### 5.2 What is isolated per Profile

4. Separate per Profile (Proven): **cookies, history, logins/passwords,
   extensions**. Evidence (help string, `strings:132694-132695`): "Profiles
   help keep your data separate across Spaces — like history, logins,
   cookies, and extensions. You can use any Profile across one or more
   Spaces." Plus per-Profile: **Favorites/Top Apps** ("see different
   Favorites up top"), **auto-archive thresholds** (§3.3 rule 12),
   **ad-block lists** (`blockListsPerProfile`, `perProfileAdBlockers` —
   ad-blocking agent owns details), **download location**
   (`downloadPathForProfile`, "Download location"), **search engine +
   suggestions** (§4.5), **site permissions/preferences**
   (`domainToProfilePreferences`), **memory (saved info)**
   (`memoryEnabledPerProfile`).
5. Shared across Profiles (Proven/Guess): the Spaces list itself (a Space
   points at a Profile; Spaces are not inside a Profile), app-level settings
   (§7 "App" scope), and the Archive is filtered by Profile/Space but stored
   app-wide (**Guess** storage; filters proven in §3.6). Pinned tabs belong
   to the Space, so switching a Space's Profile changes which browser
   context its pinned URLs open with — the URLs stay, the logins change.
6. Implementation for Open: one CEF/Chromium browser context per Profile,
   created lazily ("Could not create hidden profile", `shouldLoadAllProfilesAtStartup`
   — **Guess**: only the focused Profile loads at launch; others load on
   first use). Incognito uses a hidden ephemeral Profile; its cookies are
   never seeded from the real Profile ("Hidden profile incognito should
   never have preexisting cookies.", `seedIncognitoBrowserWithCookies` is
   for a different "seed" flow — do not seed incognito).

### 5.3 Switching and indicators

7. There is no global "switch Profile" — you switch by focusing a Space on
   the desired Profile. The current Profile is indicated in the sidebar/
   Space header (`profileIndicator`, `ProfileIndicatorView`,
   `shouldShowProfileIndicators`, tooltip "an indicator displaying the
   current profile"). Little Arc windows can change Profile independently
   (`changeProfileInLittleWindow`, `profile_changed_in_little_browser`).
8. Missing-Profile guard: if a Space points at a Profile that does not exist
   on this machine, Arc falls back to the Default Profile and tells the
   user: "Looks like one or more of your Profiles is missing from this
   computer." / "Arc has reverted to using your Default profile for
   space(s):" / "Reset space(s) profile to default". Implement the same
   fallback (needed for Import from Arc with partial data).

### 5.4 Moving Spaces/tabs between Profiles

9. Changing a Space's Profile warns: "Each Profile has different browser
   data, so you might get logged out or lose your progress in…" /
   "…this webpage might look a little different." Two confirm modes exist
   (`shouldBypassConfirmInterProfileMoveDialog` = "don't ask again").
   Moving a single tab to another Profile uses the same warning
   (`moveToAnotherProfileTabContextMenuOption`, `ConfirmInterProfileMoveDecision`).
   Implement the confirm dialog with a "don't show again" option.

---

## 6. Air Traffic Control (link routing)

### 6.1 Model

1. Link Routing state = an ordered **rule list** + a **default destination**.
   Evidence: module `Frameworks/ARC/Sources/LinkRouting/` with
   `LinkRoutingClient` (`updateState`, `updateDefaultDestination`,
   `addRule`, `currentState`, `stateStream`), `LinkRoutingEditor`,
   persisted file `StorableLinkRouting.json`, failure string "Failed to
   persist Link Routing state." Open: persist the same shape (rules array +
   default) as JSON via the data-model agent's store.
2. A **rule** matches a URL and sends it to a destination. Match kinds are
   typed by `LinkRoutingURLMatchType`; destinations by
   `LinkRoutingWindowType`; edits by `LinkRoutingRuleChangeType`. The enum
   **case names are not in strings** — the following are **Guess** from the
   settings copy and editor strings, to verify at runtime:
   match = {URL contains text, domain equals, exact URL}; destination =
   {specific Space, Most Recent Space, Little Arc, Peek, Split View,
   new tab, new tab focused, new window}. Proven destination labels (editor
   strings, `strings:132162-132172`): "Open %@ in Little Arc",
   "Open %@ in Split View", "Open %@ in a new window", "Open %@ in a new tab
   and focus it", "Open %@ in a new tab", plus Peek ("explains a link opens
   in Peek mode"). Proven Space routing: settings copy "Routes let you
   choose where specific sites open inside Arc. For example, you can route
   Spotify links to always open inside your Personal space."
3. **Source** matching: `sourceComponents` field + `featuresForLinkRouting`
   suggest rules can also consider where the link came from (for example the
   app that opened it). **Guess**: rule = {urlMatch, optional source app,
   destination}. Runtime must check whether the editor exposes a source-app
   picker. Do not ship source-app rules until verified.
4. First matching rule wins (**Guess** ordering semantics; `addRule` +
   ordered state imply a list. Verify drag-to-reorder in the editor.)

### 6.2 Default behavior for external links

5. Links from **other apps** open per the Links preference: by default in
   **Little Arc** when "Links from other apps open in Little Arc" /
   `openExternalLinksInLittleBrowserEnabled` is on, else in the default
   destination Space ("Most Recent Space" is a named default option,
   `strings:132608`). Evidence: Links pane strings "Choose where links open
   inside Arc.", "Air Traffic Control", `onToggleOpensExternalLinksInLittleBrowser`,
   `updateDefaultDestination`. Which option is the factory default is
   **Guess: Little Arc ON for external links** (Arc's known behavior);
   verify on a fresh profile.
6. In-page link clicks (normal tabs) open in the same tab unless a rule,
   Peek preference, or modifier says otherwise. Related Links preferences
   (Proven strings, Links pane): "Open a Peek window when clicking on links
   to other sites" (note: "This only affects Favorites and Pinned tabs"),
   "Open a Peek window when clicking on links with Shift held",
   `disableShiftClickToOpenLinksInModal`. Peek internals: other agent.
7. Meeting links get special handling with a toast ("Toast accessory
   indicating that the user can choose which space to open Meet links in.",
   "Meet links now open in your current Space!"). Implement: detect
   Meet/Zoom/Teams hosts (**Guess** host list) and route like other links,
   with the same toast pattern. Full list: runtime check.

### 6.3 Settings UI

8. UI lives in Preferences ▸ **Links** ("Preferences pane title; Links",
   `LinksPreferenceViewController`) with an "Air Traffic Control" section
   and a rule editor dialog (`LinkRoutingDialog`,
   `PreferencesFeature/LinkRoutingDialog.swift`). Entry points: Preferences
   ▸ Links, and the command-bar action "Air Traffic Control" (trigger
   phrases "air traffic control", "air traffic controller",
   "link preferences"). Editor operations: add rule, edit match/destination,
   delete rule (`minus.circle.fill`), reorder (**Guess**). Also in the same
   pane: Little Arc preferences ("Little Arc Preferences",
   "Archive Little Arcs after:" + threshold picker — same threshold control
   as §3.3), Peek link preferences (rule 6).

---

## 7. Settings / Preferences: every pane and option

### 7.1 Panes

Proven panes (from "Preferences pane title;" strings +
`PreferencesFeature/*ViewController.swift`; raw list in
`.re/features-core/extract-prefs-panes.txt`). Window: `SettingsWindowController`,
`arc://settings` pages exist for sub-pages (for example
`arc://settings/searchEngines`).

| Pane (Arc title) | Controller evidence | Open scope |
|---|---|---|
| General | `GeneralPreferenceViewController` | Ship |
| Profiles | `ProfilePreferencesViewController` (+ "Profile Preferences") | Ship |
| Links | `LinksPreferenceViewController` (+ `LinkRoutingDialog`) | Ship (§6) |
| Shortcuts | `ShortcutsPreferenceViewController` ("Shortcuts Preferences") | Ship (hotkeys agent owns keys) |
| Advanced | `AdvancedPreferencesViewController` ("Advanced Preferences") | Ship |
| App Icon | `AppIconPreferencesViewController` | Optional (cosmetic; referral unlocks are account — skip unlocks) |
| Account | `AccountPreferencesViewController` | **Skip** (Arc account/sync; Open has none) |
| Max | `MaxPreferenceViewController` | **Skip** (Arc Max AI) |
| Staff | `StaffPreferenceViewController` ("Staff Preferences") | **Skip** (internal) |

### 7.2 Options with type and default

Type key: `Bool`, `Enum`, `String`, `URL/path`, `Threshold` (§3.3 list).
Default key: **Proven** / **Guess** / **Unknown** (must check at runtime).
"Scope": App = whole app, Profile = per Profile, Space = per Space.
Account/Max rows are marked SKIP and listed only so Open omits them on
purpose.

#### General

| Option | Type | Default | Scope | Evidence |
|---|---|---|---|---|
| Default Search Engine | Enum (engine list) | Google (**Proven** engine; list **Guess**) | Profile | §4.5 |
| Include search engine suggestions | Bool | **Guess** ON (privacy notice gates first use) | Profile | `searchSuggestEnabled` |
| Archive tabs after (auto-archive) | Threshold | **Unknown — verify** (§3.3 rule 11) | Profile | "Archive tabs after", `ThresholdPreferenceView` |
| Download location | URL/path | `~/Downloads` (**Guess**; string `~/Downloads` exists) | Profile | "Download location", `arc.promptForDownload`, `arc.folder` |
| Ask where to save (prompt for download) | Bool | **Unknown** | Profile | `arc.promptForDownload` vs `arc.other` (**Guess** meaning) |
| Warn before quitting | Bool | **Guess** ON | App | "Warn before quitting" |
| Automatically update my Arc | Bool | ON (**Proven-ish**: `SUAutomaticallyUpdate` + `SUEnableAutomaticChecks` in Info.plist; UI string "Automatically update my Arc") | App | Info.plist + `strings` near 132602 |
| Set as default browser prompt | Action | n/a | App | "is not your default web browser.", Arc ▸ "Set as Default Browser" |

#### Profiles pane

| Option | Type | Default | Scope | Evidence |
|---|---|---|---|---|
| Profile list (create/rename/delete) | Actions | Default Profile exists | App | §5 |
| Per-Profile search/download/auto-archive | (see General rows) | — | Profile | "Manage your default search engine, Auto-Archive, and downloads in Profile Settings." |
| Your Data and Settings: Clear Browsing Data | Action | n/a | Profile | "Clear Browsing Data", "Privacy and Security" |
| Default Document App (Notes type) | Enum | **Unknown** | Profile | "Creates a new note. Document types can be set in the Profiles tab." — Notes are out of scope; keep the row out of Open v1 |

#### Links pane

| Option | Type | Default | Scope | Evidence |
|---|---|---|---|---|
| External links open in Little Arc | Bool | **Guess** ON | App | `openExternalLinksInLittleBrowserEnabled`, §6.2 |
| Default link destination | Enum (Space / Most Recent Space / …) | **Guess** Most Recent Space | App | `defaultDestination`, "Most Recent Space" |
| Air Traffic Control rules | Rule list | Empty | App | §6 |
| Open Peek for links to other sites (Favorites/Pinned only) | Bool | **Unknown** | App | Links strings §6.2 rule 6 |
| Open Peek with Shift-click | Bool | **Unknown** | App | `disableShiftClickToOpenLinksInModal` (inverted key) |
| Open Little Arc hotkey behavior ("Open Little Arc when I press ⌘…") | Key + Bool | **Unknown** | App | Links strings; hotkeys agent |
| Archive Little Arcs after | Threshold | **Unknown** | App | "Archive Little Arcs after:", `autoArchiveLittleArcTimeThreshold` |

#### Advanced

| Option | Type | Default | Scope | Evidence |
|---|---|---|---|---|
| Restore windows on previous session ("When opening Arc, restore windows from previous session") | Bool | **Guess** ON | App | `strings:132555`, §3.7 |
| Enable Picture in Picture when you leave a video tab | Bool | ON (key `autoPipGloballyDisabled` is the inverse and is absent from the live defaults) | App | features-advanced PP-13 |
| Allow window dragging from the top of webpages | Bool | **Unknown** | App | `contentWindowDraggingEnabled`, `onToggleContentWindowDraggingEnabled` |
| Show full URL when Toolbar is enabled | Bool | **Unknown** | App | Advanced string near 132554 |
| Enable Boosts on websites you visit | Bool | n/a | App | SKIP detail (Boosts agent); row exists |
| Allow websites to get your theme data | Bool | **Unknown** | App | Advanced string near 132547 |
| Enable Shared Quotes when highlighting text | Bool | **Unknown** | App | "If disabled, you can still copy URL as a quote…" |
| Play Arc sound effects | Bool | **Unknown** | App | `speaker.wave.2.fill` row, `ARC_SoundEffects.bundle` |
| Haptic feedback when reordering tabs | Bool | **Guess** ON | App | §1.6 rule 33 |
| Reset Translated-site Prompts | Action | n/a | App | `UserDefaultsClient.resetTranslateSettings` (translation is Chromium-side; keep action) |
| More Settings → `arc://settings` | Link | n/a | App | "More Settings", "Button Label; Clicking opens arc://settings." |
| Developer-mode rows (ad-block advanced etc.) | Mixed | — | — | SKIP (other agents) |

#### Shortcuts pane (behavior only; keys in hotkeys report)

| Option | Type | Default | Evidence |
|---|---|---|---|
| Custom Shortcuts (rebind any action) | Key map | Arc defaults | "Change shortcuts for your favorite actions…" |
| Shortcut conflict priority (Arc wins / website wins / website-then-Arc on double-press) | Enum (3) | **Unknown** | "When shortcuts conflict, Arc wins." / "…the website wins." / "Press this shortcut once to use the website's shortcut. Press it twice to use Arc's shortcut." |
| Include Favorites in Go-to-Item numbering | Bool | **Unknown** | `excludeFavoritesInSwitchToNthTab` (inverted), "Include Favorites in ordering." |
| Switch to ninth tab/item enabled | Bool | **Unknown** | `switchToNinthSidebarItemEnabled`, "Switch to ninth tab." |
| Reset All Shortcuts / Reset Shortcut to Default | Actions | n/a | "Reset All Shortcuts", "Reset Shortcut to Default" |

#### SKIP: Account, Max, Staff (do not build)

- Account pane: sign-in, Display Name ("Change your Display Name",
  "Your Display Name is publicly visible when you share items like your
  Membership Card, Boosts, Folders or Spaces."), sync, Recovery Phrase,
  Delete Account (`ARC_DeleteAccountFeature.bundle`), referrals/App Icon
  unlocks ("Refer %d friends to unlock"). All account/sync — **out of scope**
  per AGENTS.md.
- Max pane: "ChatGPT in the Command Bar", "5-Second Previews", tidy tab
  renames, smart download renames, "Automatically enable future Arc Max
  features", "Enable AI Features". All Arc Max AI — **out of scope**.
  Command-bar ChatGPT scope (§4.2) is therefore also out of scope.

### 7.3 Storage notes for implementers

- Arc stores settings three ways: `UserDefaults` via `UserDefaultsClient`
  (typed `boolForSetting`/`stringForSetting`/… + `registerDefaults`),
  JSON stores (`Storable*.json`: sidebar, profiles, link routing, library,
  archive state), and Chromium profile prefs. Open: mirror the split —
  UserDefaults for app prefs, JSON for sidebar/link-routing, CEF prefs per
  Profile. Synced-preferences machinery (`SyncedPreferencesClient`,
  CloudKit/Firebase sidebar sync) is account sync — **skip**.

---

## 8. Window behavior

### 8.1 Windows and tabs

1. Multiple main windows are supported; each window has its own focused
   Space, sidebar state (mode/width), and active tab. Evidence:
   `MainWindowsManager`, `WindowsState`, `PersistedWindowsState`,
   `WindowState`, per-window `createWindow(_:source:sidebarMode:)`.
   Sidebar **content** (Spaces, pinned, favorites) is app/Profile data,
   shared across windows; sidebar **presentation** (open/compact/width) is
   per window (**Guess** split — verify with two windows).
2. File menu window commands (Proven from nib, `mainmenu-items.txt`):
   **New Window**, **Blank Window**, **New Incognito Window**,
   **New Little Arc Window** (other agent), **Close Window**,
   **New Profile** (creates a Profile, §5). "Creates a new window, blank
   window, or incognito window." is the combined shortcut description.
   Difference New Window vs. Blank Window (capture C10, 2026-11-12, Arc 1.172.2,
   replaces the earlier guess): **New Window** is a normal window on the current
   Space, with Favorites and Space dots. **Blank Window** is its own window kind
   (AX id prefix `standaloneBrowserWindow-`, normal windows `bigBrowserWindow-`):
   the same size as the source window, offset +29 / +29 pt; title "Space 1";
   sidebar header "This Window" over this window's tabs only (newest first), no
   Favorites grid, no Space dots, bottom bar with Library and "+" only; default
   theme colours. Both open with the command bar open. In a Blank Window the row
   menu is the ordinary Today-tab menu (with Move to ▸), ⌘W on the last tab
   closes the window with no prompt, and it was not restored at relaunch (with
   "restore windows" off). Not captured: tab drag between windows, ⇧⌘T after
   closing, the Archive entry of a closed tab.
   Verify.
3. **New Incognito Window** opens a window on the hidden incognito context
   (§5.2 rule 6): distinct sidebar header for its Today list, no history/
   cookies persist, extensions off by default ("can't be installed or used
   in Incognito Mode" for Boosts; Chromium extension incognito rules apply).
   Visual difference (darker/distinct theme, `bigIncognitoBrowserWindow`,
   `CommandBarPlaceholderIncognitoBackground`) — exact styling: design
   report + runtime. "Open Link in Incognito Window" exists as a link action
   (`onOpenLinkInIncognitoWindow`).
4. Closing the last window does not quit the app (**Guess**, standard macOS;
   no contradicting string). Quit warns when downloads run: "There are
   downloads in progress. Closing the application will cancel them." and,
   with the preference on, "Warn before quitting" (§7.2).

### 8.2 Full screen and toolbar

5. View ▸ "Enter/Exit Full Screen" toggles native full screen. In full
   screen the sidebar follows its mode (§1.7); the floating/compact sidebar
   overlays content. Evidence: `FullScreenState`, `FullscreenOverlayWrapper`,
   shortcut description "Makes your current Arc window fill the entire
   screen." Full-screen + hidden-sidebar edge reveal: **Guess**.
6. There is **no persistent top toolbar** by default. View ▸ "Show/Hide
   Toolbar" toggles an optional toolbar (`FakeToolbar`, `toggleToolbar`,
   Advanced option "Show full URL when Toolbar is enabled"). Default:
   **Guess** hidden. The URL lives at the top of the sidebar (§8.4), not in
   a toolbar.
   Update 2026-10-25: the toolbar is the 32 pt content top bar that Split
   View panes also use (remote setting `toolbar-display-height`, built-in
   default 32). It is per window, the menu title switches between "Show
   Toolbar" and "Hide Toolbar", and the URL pill menu offers "Show as
   Toolbar". See `commandbar-completion.md` §6 (CC-32…CC-38).
7. The title bar is hidden/merged: window chrome is the sidebar header +
   traffic lights over the Space theme background (`WindowFrameBackgroundView`,
   `WindowStandardButtons`, `ToolbarTitle` exists but the toolbar-less look
   is the default). Dragging works from the sidebar header and, when enabled,
   "from the top of webpages" (§7.2). Web content is inset with rounded
   corners over the themed background (**Guess** radius — design-tokens
   report owns the value; window types: `MovableWindow`,
   `WindowFrameBackgroundLayoutMode`, `contentOverBackgroundAppearance`).

### 8.3 URL display

8. The current tab's address shows in the sidebar-top placeholder pill
   (§4.1 rule 2): lock icon for secure pages, title/URL text, and hover
   buttons for Site Control Center and Copy URL. With the optional toolbar
   shown, the same field appears in the toolbar ("Show full URL when
   Toolbar is enabled" controls full-URL vs. trimmed display). Implement:
   trimmed (host + path summary) by default, full URL in edit mode.
   (**Guess** trimming rule — verify.)

---

## Appendix A. Type and file index (evidence)

| Area | Key types / files |
|---|---|
| Sidebar model | `SidebarData`, `SidebarItem`, `SidebarContainer(Type)`, `SidebarItemDataType`, `SidebarLocation`, `SidebarMode`, `SidebarPresentation`, `TopApps`, `StorableSidebar` (`ARC_StorableSidebar.bundle`) |
| Sidebar UI | `SidebarViewController`, `SidebarSpaceViewController`, `SidebarPagingContainerViewController`, `TablistView`, `UnpinnedSectionHeaderCellView`, `SidebarClearButton`, `SidebarTidyButton` |
| Spaces | `SidebarSpace`, `orderedSpaces`, `SpaceStyleEditor*`, `ARC_SpaceCreation.bundle`, `ARC_SpaceStyleEditor.bundle` |
| Archive | `ArchiveState`, `AutoArchiveType`, `AutoArchiveInactiveThreshold`, `ArchiveDataStoreClient` |
| Command bar | `CommandBar*` (Instance/Store/UI), `SearchClient`, `SearchEngineClient`, `LocalCommandBarRankingProvider`, `command_bar_behavior.json` |
| Profiles | `StorableProfiles.json`, `ARC_ProfilesUI.bundle`, `ProfilesUI/*Dialog*` |
| Link routing | `LinkRoutingClient/Editor`, `LinkRoutingURLMatchType`, `LinkRoutingWindowType`, `StorableLinkRouting.json` |
| Settings | `PreferencesFeature` (General/Profiles/Links/Shortcuts/Advanced/Account/Max/Staff/AppIcon), `arc://settings/searchEngines` |
| Windows | `MainWindowsManager`, `PersistedWindowsState`, `WindowTheme*`, `MovableWindow*` |

## Appendix B. Help-center URLs found in the binary (verify by hand)

- Spaces: `https://resources.arc.net/hc/en-us/articles/19228064149143-Spaces-Distinct-Browsing-Areas`
- Profiles: `https://resources.arc.net/hc/en-us/articles/19227964556183-Profiles-Separate-Work-Personal-Browsing`
- Pinned Tabs: `https://resources.arc.net/hc/en-us/articles/19231060187159-Pinned-Tabs-Tabs-you-want-to-stick-around`
- Auto-Archive: `https://resources.arc.net/hc/en-us/articles/19228855311127-Auto-Archive-Clean-as-you-go`
- Shortcuts: `https://resources.arc.net/hc/en-us/articles/20595231349911-Shortcuts`
- Site Search: `https://resources.arc.net/hc/en-us/articles/20855018192791-Site-Search-Directly-Search-any-Website`
- Previews: `https://resources.arc.net/hc/en-us/articles/19335284431639-Previews-Glance-Top-Sites`

## Appendix C. Open questions for runtime checks (priority order)

1. Auto-archive **default** threshold (fresh Profile) — blocks §3.3.
2. Default search-engine **list** and whether suggestions start on/off.
3. `SidebarMode` cases and exact compact/floating/hidden transitions,
   including full-screen edge reveal; confirm **no right-sidebar** option.
4. Pinned-tab affordances: back-to-pinned UI, Close-and-Keep-Pinned vs.
   close, Separate-From-Pinned semantics.
5. Drag rules: copy-vs-move for Pinned/Favorite drags, cross-Profile drag
   warning, folder-into-descendant feedback, New Tab row placement,
   bottom-bar exact order/badges.
6. Air Traffic Control editor: exact `LinkRoutingURLMatchType` cases,
   whether **source-app** matching exists, rule ordering, external-link
   factory default (Little Arc on/off), default destination.
7. New Window vs. Blank Window difference; last-window/quit behavior;
   per-window vs. shared sidebar presentation.
8. Folder max nesting depth; multi-select modifiers; incognito pinning.
9. Launch: restore-windows default; frozen-vs-discarded thresholds and
   Battery Saver effect; Space last-active-tab restore.
10. General/Advanced defaults marked **Unknown** in §7.2 (toolbar default,
    Peek toggles, sound effects, theme-data sharing, download prompt).
