# Sidebar and Library menus: Arc 1.172.2 against Open (D2c inventory, refreshed 2026-11-12)

Scope: PARITY-HANDOFF §3.1 row "Sidebar / Downloads / History". Every context menu and toolbar menu of the sidebar
and of the Library sections. "Arc" is what a capture showed; "code" is what the binary builds (order not proven);
"—" is a separator; "▸" a submenu; "⌥" an option alternate (drawn only while ⌥ is held). Open is main 243b511a
(`OpenSidebar/SidebarMenus.swift`, `OpenLibrary/LibraryPanelContent.swift`). The first inventory (main d2a31857)
was built out in #432, #463–#468, #478, #482, #492 and #494.

Evidence keys: **S3D** = capture session 3 Part D (Arc 1.172.2, `s9/15-menus` AX trees of the open NSMenu);
**S8** = capture session 8 (`C-report-s8.md`, item numbers below; `.re/capture/s8-d2/m1/arc/v2…v13`);
**S1L** = capture session 1 Library (`19c-downloads-more`, `20-archive-more`; `docs/re/library-overlay.md`);
**S4E** = capture session 4 Easel row menu (`C-measurements-s4` `e7-row-menu-ax`);
**MH** = `docs/re/menus-and-hotkeys.md` "Context menus" (code families).

## 1. Sidebar

| Surface | Arc (order) | Open (main 243b511a) | Gap |
|---|---|---|---|
| Today tab row (S3D, S8 items 1, 3) | Copy Link · Share ▸ · — · Change Icon… · Rename… · Mute · — · Open in Split View · Duplicate · Move to ▸ · — · Archive Tab · Archive Tabs Below (⌥ Archive Other Tabs, Archive Tabs Above). Selected tab: Copy Link shows ⌘⇧C and "Add Split View" replaces "Open in Split View". Mute is disabled on a silent tab; "Unmute" on a muted one | the same | none. S8 saw "Customize Page…" after Mute in one run only (condition not established); Open does not show it |
| Pinned tab row (S3D, S8 item 1) | Copy Link · Share ▸ · — · Change Icon… · Rename… · Mute · Edit Pinned Page ▸ · — · Open in Split View · Duplicate · Move to ▸ · — · Remove Pin | the same | none (the "Customize Page…" note above applies) |
| Favourite tile (S3D, S8 item 1) | the pinned menu, last item "Remove Favorite" | the same; before it, Open's Live Calendar items and Top App switches (Show Meeting Link ▸, Meeting Reminder ▸, Show Unread Badge, Show Time to Next Meeting) for matching tiles | the place of the Live Calendar and Top App items is a GUESS (capture pending, F2 item 7) |
| Share ▸ (S8 item 1) | the Mac's share services (AirDrop · Mail · Messages · Notes · …), each with its icon; the same list in tab rows and the URL field | the same (`ShareServices`; Reading List left out) | none |
| Move to ▸ (S8 item 2) | one row per Space in dock order, current Space checked · — · New Space… | the same | Spaces of other Profiles: not established |
| Folder row (S3D, S8 item 4) | Share Folder… · — · New Nested Folder… · Turn "‹name›" into Space · Copy All Links · Copy All Links as Markdown · — · Change Icon… · Rename… · — · Duplicate · Move to ▸ · — · Delete; an empty folder has no Copy items | the same | none |
| Live Folder row (code, live-data §2.2) | not captured | header · Repositories · Single Sign-On ▸ · Refresh · — · Copy All Links · — · Delete Live Folder | order is a GUESS (F2 item 3) |
| Space menu: title, empty area, Clear row, Space dot, title "…" button (S3D, S8 item 8) | Change Space Icon… · Rename Space… · Edit Theme Color… · Set Profile ▸ · — · New Folder · Live Folders ▸ · — · Share Space… · Export "‹name›" into Folder ▸ · — · Manage Spaces… · — · Delete Space | the same (Share Space… disabled: no account) | none |
| Split row (S8 item 5) | Share Split View… · — · Separate All Tabs · Add Tab… · Convert to … Split View · — · Tab Options (disabled) · ‹pane› ▸ … · — · Change Icon… · Rename… · — · Duplicate · Move to ▸ · — · Archive Item · Archive Tabs Below (⌥ pair). Pane ▸: Separate from Split View · — · Share · Mute · Copy Link · Copy link as Markdown · — · Archive Item | the same without Change Icon… and Rename… | Change Icon… / Rename… need a split name and icon in the model (deferred, `docs/followups.md`) |
| Multi-selection (S8 item 6; S13 C13-D2-6) | tabs: Copy Links · Share N Items… · — · Change Icon… (disabled) · Mute · — · Open in Split View · Duplicate · Move to ▸ · New Folder with N Items · — · Archive Tabs (⌥ pair for Today tabs). Normal folder + Today tab: Copy Links · Share 2 Items… · — · Open in Split View (disabled) · Move to ▸ · New Folder with 2 Items · — · Delete · — | the same for the captured normal mixed case; Open adds ⌥ "Copy links as Markdown" and "Pin Tabs" / "Unpin Tabs" | Option, Manager, nested/split/Note/Easel and larger mixed selections remain uncaptured and keep their existing behavior |
| Easel row (S4E) | Copy Link · — · Change Icon… · Rename… · — · Add Split View · Move to ▸ · — · Remove Easel from Sidebar · Delete Easel | adds "Save as Web Page…" after Copy Link | Open addition (lead ruling LEAD 04:05 S4); keep |
| URL field (S3D, S8 item 1) | Copy URL · Share ▸ · Capture… · Capture Full Page · Capture in Portrait Mode · — · Show as Toolbar · Disable Shared Quotes | the same ("Enable Shared Quotes" when off) | none |
| Library button, right click (S3D) | Show media from: (disabled) · Documents · Desktop · Screenshots · Arc Captures · Downloads | the same ("Captures" for "Arc Captures") | none |
| Bottom-bar "+" (S8 item 7) | a popover, not an NSMenu: New Space · New Folder · — · New Easel ⌃⇧E · New Boost · — · New Split ⌃⇧= · New Tab ⌘T; New Tab highlighted at open; New Boost / New Split enabled only with a loaded http page | the same | none |

## 2. Library sections

| Section | Arc | Open (main 243b511a) | Gap |
|---|---|---|---|
| Downloads, completed (S1L, S8 item 9) | More button "More Options": Open ‹kind› · Copy ‹kind› · Show in Finder · — · Hide from Arc · Move to Trash; ‹kind› is the file-kind word, else the extension; subtitle: the kind word, else "Download"; right-click opens no menu | the same ("Hide from Open") | a file with no extension: "Open" / "Copy" is a GUESS |
| Downloads, in progress / paused (S8 item 10) | Open ‹kind› · Copy (disabled) · Show in Finder (disabled) · — · Cancel Download · — · Hide | the same; Pause/Resume and Cancel stay as hover controls (Arc has no pause, resume or retry menu strings) | none |
| Downloads, failed / cancelled (S8 item 10; S12 C12-PB1-3) | Open, Copy, Show in Finder all disabled · — · Hide from Arc; a truncated transfer shows "Failed to Download" by 30 seconds and still at 60 and 90 seconds | the same; failed rows keep the Retry hover control | S12 failed-row menu still awaits capture; its relaunch behavior is tracked by PB1 |
| Archived Tabs (S8 item 11; S11 C-D2-2; S12 C12-D2-4) | right-click opens no menu; split Archive Item creates two tab rows with Trash + Restore on hover, no controls away, tail tooltip “Restore”; title click opens Peek; URL omits scheme | single-tab rows share S12 hover/Peek behavior at every width (Open design ruling 2026-11-13); Return still restores; layout and selected styling unchanged | S11 manual-tab observation differed; narrow layout, second selected row and actual Restore click remain uncaptured; see `library-session11.md` |
| Media captures (S11 C-D2-1) | Copy Image · Copy Source URL · Open Source URL · — · Send via iMessage · AirDrop · — · Delete; title tooltip on hover, no ellipsis button; saved captures appear without a folder grant | the same; native system share services; new captures retain the full source URL | older Open captures without a saved source URL disable its two source actions; folder-file order and separators remain GUESS |
| Easels (S4) | card menu: a single "Delete" | the same | none |
| Spaces (S8 item 13) | card header right-click and footer "…": the sidebar Space menu without "Manage Spaces…" and its separator; a tab row keeps the row menu | the same (`SidebarMenus.space(_:inLibrary:)`) | none |
| Boosts (S8 item 14) | the card has no right-click menu; a click opens the editor, whose title menu is Rename this Boost… · Shuffle · Reset all Edits · Delete this Boost · — · All Boosts… | no right-click menu; the More button keeps Edit Boost · Turn On/Off · — · Delete; the editor title menu adds Open's "— · Apply to ▸" (its only route to the scope menu) | card text: Arc shows the Boost name over its host, with no on/off text (`v13/33-boost-menu-delete/i14-boosts.png`); Open follows it with the D2c Boost card PR |
| History | not a Library category in Arc; ⌘Y opens the browser's own History page (S1L) | Open has a History section | Open addition; its menus are Open's own (no Arc parity target) |

## 3. Status

The build order of the first inventory is done: sidebar row menus, URL field, "+" popover, then the Library sections
(one PR each). Open items: the two C3 captures above (C-D2-1 Media menus, C-D2-2 Archive hover glyphs), the deferred
items in `docs/followups.md` (split Change Icon / Rename, Media Source URL), and the GUESS rows marked in the tables.

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

The saved-capture order and separators are now measured by session 11 C-D2-1:
Copy Image · Copy Source URL · Open Source URL · — · Send via iMessage · AirDrop · — · Delete.
Evidence and the optional source-URL field are recorded in [library-session11.md](library-session11.md).
Open's folder-file menu remains Open in Preview · Send via iMessage · AirDrop · Copy ‹Image|Video› ·
Show in Finder · — · Hide from Open. Its order and separators remain a guess; the folder-grant capture is still open.

## 5. Failed-download subtitle (session 12 C12-PB1-3)

Arc 1.172.2 shows "Failed to Download" after a loopback transfer advertises 2 MiB, sends 512 KiB and closes the
connection. The first frame still shows progress; the 30-, 60- and 90-second frames show the failure text.
Evidence: `.re/capture/s12/m1/arc/v9/34-failure-verified-90/failure-at-{30,60,90}.{png,ax.json}`;
the request times are in that block's `session.jsonl`. The first scheduled 5-second frame ran late while the
Library opened, so these captures do not establish an exact failure delay. The subtitle follows this measurement;
this change does not alter transfer retries or persistence. The failed-row menu remains unmeasured. The final
C12-PB1-3 report separately records that this failed row was absent after relaunch, including an exact-name search
showing "No results found" (`.re/capture/s12/m1/arc/v11/36-failure-relaunch/failed-after-relaunch.{png,ax.json}`).
The PB1 lane tracks that relaunch behavior; this change covers the subtitle.

## 6. Mixed folder and Today-tab Delete (session 13 C13-D2-6)

Session 13 C13-D2-6 selects an ordinary folder with two direct tab children and a separate Today
tab, then invokes the normal menu's Delete. The confirmation reads **Delete your “C13 Folder”
folder?**, **Deleting this folder will archive the tabs inside it.**, with Cancel and Delete Folder.
After confirmation the folder and the three tabs leave the sidebar; Archive has three individual
tab rows and no folder record. Normal quit/relaunch preserves that result. Evidence:
`.re/capture/s13/m1/arc/v8/210-mixed-delete/mixed-{sidebar-baseline,archive-baseline,delete-menu,delete-confirmation,delete-sidebar,delete-archive}.{png,ax.json}`
and `v8/211-mixed-relaunch/mixed-relaunch-{sidebar,archive}.{png,ax.json}`.

Open applies that result to the normal sidebar menu for one nonempty ordinary folder of direct
tabs and one separate Today tab. The existing confirmation guard, Cancel path and one-step Undo
remain. Keyboard deletion, held-Option menus, Manager menus, nested folders, splits, Notes,
Easels, empty folders and larger mixed selections retain their existing behavior because this
capture does not settle them. Existing folder-only deletion still creates a folder Archive record.
