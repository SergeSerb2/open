# Easels and Notes in Arc 1.172.2 (capture session 4)

Observed in unmodified Arc 1.172.2 (90755) on the M1 built-in display at 2×, window 1280×800 pt, sidebar 366 pt,
2026-11-11. Our own observations only: no Arc assets, images or user content. Evidence names refer to the private
`s4-easels-notes/m1/arc/<series>/<block>/` captures. All test Easels and Spaces were deleted afterwards.

## Easel surface

| Fact | Evidence |
|---|---|
| New Easel (menu, ⌃⇧E, "+" popover) adds an Easel row (Easel glyph) to the current Space and selects it. The page area becomes a blank canvas with a centred bold title field "Untitled Easel" (AX text area 546 × 66 pt at the top). The sidebar URL field shows a lock and "Share". | `t0/00-setup/e1-new-easel` |
| A floating white toolbar sits at the canvas's bottom-left: seven 36 × 36 pt buttons at a 38 pt pitch, 26 pt above the window bottom — Pointer (default), Image, Text, Ellipse, Rectangle, Arrow, Freehand — then a divider and a split button. An invite button ("Share or Invite Collaborator") sits at the bottom-right. | same |
| Hovering a tool shows a light plate and a single-letter shortcut hint at the icon's corner (Image i, Text t, Ellipse o, Rectangle r, Arrow a, Freehand p); there is no tooltip. | `t2/01-easel-tools/e1-hover-*` |
| Shapes draw on drag and stay selected: a thin blue outline with four small round corner handles, and a colour popover above with two rows of swatches (the current one checked). | `t2/…/e2-*-selected` |
| Ten pressable swatches gave these fills on a rectangle: `#FEFEFE`, `#FFAD73`, `#F9634C`, `#00F0A4`, `#4E9442`, `#323232`, `#C8C8C8`, `#CF45B3`, `#00D6F9`, `#5A60FC`. | `t12/13-palette-zoom-web/p-swatch-click-*` |
| The Text tool places a 280 × 28 pt box with the placeholder "Start typing to enter text" and a "+ / Aa / −" size control at its left. | `t2/…/e2-text-*` |
| Object menu: Bring to Front, Send to Back, Delete, Cut, Copy, Paste, Duplicate. Canvas menu: Paste, Color Palette ▸, Use Alignment Guides (on by default). | `t2/…/e3-*-menu-ax` |
| Moving an object near another shows alignment guides; corner handles resize; Send to Back reorders. | `t3/02-easel-edit/e4-*` |
| ⌘− zooms out in steps (≈ 74 %, ≈ 50 %) to a minimum of ≈ 33 %; ⌘0 resets; ⌘= zooms in; the wheel scrolls the page vertically. | `t13/15-zoom-web/z-*`, `t3/…/e5-scrolled` |
| View › Appearance Dark turns the canvas dark. | `t3/…/e1-dark` |
| The split button opens a Split beside the Easel with a focused command bar ("Search or Enter URL…"). | `t13/15-zoom-web/w-add-button` |

## Sidebar row, Library, capture

| Fact | Evidence |
|---|---|
| Easel row menu: Copy Link, Change Icon…, Rename…, Add Split View, Move to ▸, Remove Easel from Sidebar, Delete Easel. Rename is inline in the row. Delete asks "Are you sure you want to delete this Easel?" / "Doing so will delete the Easel permanently." | `t3/03-easel-row/e7-row-menu-ax`, `t5/03c-rename-split`, `t8/09-cleanup` |
| Deleting a Space keeps its Easels: they stay in Library › Easels. A Library card's context menu has one item, "Delete". | `t12/14-cleanup`, `t14/17-library-delete` |
| Library › Easels shows a card "Your Easels are yours to keep" ("Winding down Arc doesn't mean losing your work. Save all your Easels as web pages you can open anywhere, share, or host yourself.") with "Export All Easels →", which opens a macOS save sheet for an archive "Arc Easels - ‹date time›". Empty state: "Click the + sign in the Sidebar to create a new Easel." | `t6/07-library-capture/e8-*`, `t14/…/lz-after` |
| File › Capture… shows a hint toast ("Next time, hold ⇧⌘ and drag your mouse to capture any time.") and a bottom pill "Click or drag to capture a portion of this page". After a drag a menu offers Send To…, Save to Library, Copy, Save…, Send via iMessage…, Edit, Retake, New Easel and each Easel; choosing an Easel opens it in a Peek-style overlay with the capture as a card. | `t6/…/e6-*`, `t8/08-capture-to-easel/e6-in-easel` |

## Notes

Notes cannot be created in 1.172.2: no "New Note" in any menu, the command bar or the "+" popover, and ⌃⇧N / ⌃⌥N do
nothing. Help › Export Arc Notes shows "We've phased out Arc Notes" / "Don't worry, you can still export them!" with
[Cancel] [Export]; Export then reports "No Notes found to export." Settings › Profiles › New documents (Default
Document App) offers ——, Confluence Page, Google Doc, Notion Page, Word Doc. Evidence: `t3/04-note-discovery`,
`t4/05-notes`, `t5/06-export-library-capture`, `t9/10-doc-app`.

Not captured: the image tool (needs a file dialog), a web card from a URL and its live flip, the Color Palette
submenu, the zoom-in maximum, and the Export All Easels archive (the save sheet was closed without saving).
