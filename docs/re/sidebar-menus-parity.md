# Sidebar and Library menus: Arc 1.172.2 against Open (D2c inventory, 2026-11-12)

Scope: PARITY-HANDOFF §3.1 row "Sidebar / Downloads / History". Every context menu and toolbar menu of the sidebar
and of the Library sections. "Arc" is what a capture showed; "code" is what the binary builds (order not proven);
"—" is a separator; "▸" a submenu. Open is main d2a31857 (`OpenSidebar/SidebarMenus.swift`,
`OpenLibrary/LibraryPanelContent.swift`).

Evidence keys: **S3D** = capture session 3 Part D (Arc 1.172.2, `s9/15-menus` AX trees of the open NSMenu);
**S1L** = capture session 1 Library (`19c-downloads-more`, `20-archive-more`; `docs/re/library-overlay.md`);
**S4E** = capture session 4 Easel row menu (`C-measurements-s4` `e7-row-menu-ax`);
**MH** = `docs/re/menus-and-hotkeys.md` "Context menus" (code families; split-row menu from `0x102eccc9c`).

## 1. Sidebar

| Surface | Arc (order) | Open today | Gap |
|---|---|---|---|
| Today tab row (S3D) | Copy Link · Share ▸ · — · Change Icon… · Rename… · Mute · — · Open in Split View · Duplicate · Move to ▸ · — · Archive Tab · Archive Other Tabs · Archive Tabs Below · Archive Tabs Above | Copy Link · — · Open in Split View · Move to ▸ · — · Archive Tab · (⌥ alternate) Archive Other Tabs · Archive Tabs Below | Missing Share ▸, Change Icon…, Rename…, Mute, Duplicate, Archive Tabs Above; Archive Other Tabs is a plain item in Arc, not an ⌥ alternate |
| Pinned tab row (S3D) | Copy Link · Share ▸ · — · Change Icon… · Rename… · Mute · Edit Pinned Page ▸ · — · Open in Split View · Duplicate · Move to ▸ · — · Remove Pin | Copy Link · Share… · — · Change Icon… · Rename… · Mute · Customize Page… · Edit Pinned Page ▸ · — · Add Split View · Duplicate · Move to ▸ · — · Remove Pin | Share is a submenu in Arc; "Customize Page…" not in Arc; "Add Split View" → "Open in Split View" |
| Favourite tile (S3D) | the pinned menu, last item "Remove Favorite" | Copy Link · Share… · — · Change Icon… · Rename… · — · Remove from Favorites | Missing Mute, Edit Pinned Page ▸, Open in Split View, Duplicate, Move to ▸; title "Remove Favorite" |
| Folder row, empty (S3D) | Share Folder… · — · New Nested Folder… · Turn "‹name›" into Space · — · Change Icon… · Rename… · — · Duplicate · Move to ▸ · — · Delete | the same, plus Copy All Links · Copy All Links as Markdown after "Turn into Space" | Arc hides the Copy items on an empty folder; their place with tabs is not captured (C3 item 4) |
| Space menu: title, empty area, Clear row, Space dot (S3D) | Change Space Icon… · Rename Space… · Edit Theme Color… · Set Profile ▸ · — · New Folder · Live Folders ▸ · — · Share Space… · Export "‹name›" into Folder ▸ · — · Manage Spaces… · — · Delete Space | identical (Share Space… disabled: no account) | none in order; the Space title hover "…" button (AX "More") showed no menu on AXPress (C3 item 8) |
| Split row (MH, code) | Share Split View · — · Separate All Tabs · Add Tab… · Convert to … Split View · — · Tab Options · per-pane ▸ · — · Reset Name and Icon · Change Icon… · Rename… · — · Duplicate · — · Archive Item(s) · Archive Other Tabs · Below · Above · Move to ▸ | the code list without Share, Reset Name and Icon, Change Icon…, Rename… | Not captured in 1.172.2 (C3 item 5) |
| Multi-selection (MH families) | not captured | Copy Links · Copy links as Markdown · New Folder with N Items · Pin/Unpin Tabs · Duplicate · — · Archive Items · Delete | Not captured (C3 item 6) |
| Easel row (S4E) | Copy Link · — · Change Icon… · Rename… · — · Add Split View · Move to ▸ · — · Remove Easel from Sidebar · Delete Easel | adds "Save as Web Page…" after Copy Link | Open addition (lead ruling LEAD 04:05 S4); keep |
| URL field (S3D) | Copy URL · Share ▸ · Capture… · Capture Full Page · Capture in Portrait Mode · — · Show as Toolbar · Disable Shared Quotes | Show as Toolbar · — · Manage Extensions | Missing Copy URL, Share ▸, the three Capture items, Disable Shared Quotes; "Manage Extensions" not in Arc's field menu (it is in Arc's page menu family, MH) |
| Library button, right click (S3D) | Show media from: (disabled) · Documents · Desktop · Screenshots · Arc Captures · Downloads | the same ("Captures" for "Arc Captures") | none |
| Bottom-bar "+" (S3D) | a popover, not an NSMenu: New Space · New Folder · — · New Easel ⌃⇧E · New Boost · — · New Split ⌃⇧= · New Tab ⌘T | an NSMenu: New Tab · New Split View · New Folder · New Easel ⌃⇧E · — · New Space… | Popover form, order, "New Boost", "New Split" title and shortcuts (C3 item 7 for geometry) |

## 2. Library sections

| Section | Arc | Open today | Gap |
|---|---|---|---|
| Downloads, completed item, More button (S1L) | Open ‹…› · Copy ‹…› · Show in Finder · — · Hide from Arc · Move to Trash | Open · Copy · Show in Finder · — · Hide from Open · Move to Trash | Arc's first two titles carry the file (S1L reads "Open txt", "Copy txt"); exact form not established (C3 item 9) |
| Downloads, in progress / failed | not captured | Pause/Resume · Cancel · Show in Finder / Retry · Hide from Open | C3 item 10 |
| Downloads, right click on a row | not captured (S1L used the More button only) | the same menu as More | C3 item 9 |
| Archived Tabs (S1L; session 8 item 11, `v10/29`, `v12/29a`) | right-click opens no menu; hover shows a tooltip with the tab title; rows show the title and the URL without its scheme; the Trash and Undo glyphs of S1L did not show in session 8 (condition not established) | the same; hover Delete / Restore kept | glyph condition unknown |
| Media | not captured (Media stayed at its first-use card) | Open · Copy · Show in Finder · Save As… · — · Delete (captures); Open · Copy · Show in Finder · — · Hide from Library (folder files) | C3 item 12 |
| Easels (S4) | card menu: a single "Delete" | a single "Delete" | none |
| Spaces (session 8 item 13, `v13/34-item-13`) | card header right-click and footer "…": the sidebar Space menu without "Manage Spaces…" and its separator; a tab row keeps the row menu | the same (`SidebarMenus.space(_:inLibrary:)`) | none |
| Boosts | not captured | Edit Boost · Turn On/Off · — · Delete | C3 item 14 |
| History | not a Library category in Arc; ⌘Y opens the browser's own History page (S1L) | Open has a History section | Open addition; its menus are Open's own (no Arc parity target) |

## 3. Build order (one PR per section, branch prefix `design/d2c-`)
1. Sidebar row menus (Today, pinned, favourite, folder): evidence complete in S3D.
2. URL field menu: evidence complete in S3D (Share ▸ contents from C3 item 1).
3. Bottom-bar "+" popover: item list from S3D; geometry from C3 item 7.
4. Library Downloads titles and the other Library sections: after C3 items 9–14.

## 4. Library file menus from Arc's code (2026-11-12, Arc 1.172.2 build 90755)

Method: `xcrun llvm-objdump -d --no-show-raw-insn --arch=arm64 /Applications/Arc.app/Contents/MacOS/Arc`, filtered to
`mov`/`movk` immediates and decoded as Swift small strings (titles of ≤ 15 bytes are immediates, not `__cstring`
data; raw table in `.re/d2c/imm-strings.tsv`). A title longer than 8 bytes shows as two halves at neighbouring
addresses. Order below is address order inside each builder; **menu order = code order is a guess**.

| Builder (address range) | Titles in code order | Notes |
|---|---|---|
| Library › Media (`HomeButton/MediaReducer.swift`, 0x102804e74 … 0x102806608) | Open in Preview · AirDrop · "Copy " + ‹kind› · Show in Finder · Hide from Arc · Open Source URL · Copy Source URL · Delete | plus the long string "Send via iMessage" (comment "Menu item title to show a send via iMessage for capture."). Comments name which item belongs to which kind: "delete Capture from Arc", "hide a screenshot from Arc" |
| Item preview (`HomeBadging/ItemPreviewPresenter.swift`, 0x10270f2e8 … 0x10270fd8c) | Open in Preview · AirDrop · Open Source URL · Copy Source URL · Show in Finder | |
| Shared capture / download items (0x1026b9aa8 … 0x1026bb378) | Copy Image · AirDrop · Open Source URL · Copy Source URL · Delete; "Copy " + ‹ext› · AirDrop; Show in Finder · Hide from Arc · Move to Trash · "Open " + ‹ext›; Cancel Download | confirms the download titles "Open ‹ext›" / "Copy ‹ext›" and "Cancel Download" |

Open builds: captures: Open in Preview · Send via iMessage · AirDrop · Copy Image · Show in Finder · Save As… (Open's own)
· — · Delete; folder files: Open in Preview · Send via iMessage · AirDrop · Copy ‹Image|Video› · Show in Finder · — ·
Hide from Open. Not built: Open Source URL / Copy Source URL (Open's capture index stores the source host only).
Separators are a guess. No populated Media menu was captured (C3 session 8 item 12 skipped).
