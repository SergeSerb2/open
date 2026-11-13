# Library capture menus and Archive hover state

Evidence: Arc 1.172.2, C3 capture session 11, C-D2-1 and C-D2-2.
The capture menu is visible in
`.re/capture/s11/m1/arc/v16/d3-media-menus/m1-card-right-w-101791.png`.
Media before a folder grant is visible in
`.re/capture/s11/m1/arc/v15/d1-media-capture/d1-media.png`.
Archive hover observations are in
`.re/capture/s11/m1/arc/v14/d2-archive-hover/d2-row0-left-window-101722.png`,
`d2-row1-right-window-101722.png` and `d2-selected-right.png` in the same folder.
These observations replace the earlier menu-order guess for saved captures.
Folder-file menus remain outside this finding: C3 could not capture them without
a folder grant.

A capture saved to the Library appears in Media before folder access is granted.
Its right-click menu is Copy Image, Copy Source URL, Open Source URL, separator,
Send via iMessage, AirDrop, separator, Delete. There is no ellipsis button on
hover; the card shows its title tooltip. iMessage and AirDrop use the native
`NSSharingService` services `composeMessage` and `sendViaAirDrop` in Open.

Open stores the original page URL with each new capture. The field is optional
so existing indexes remain readable. Older captures without it disable the two
Source URL actions. Open does not reconstruct an address from a hostname. The
URL field is limited to 8192 bytes; the complete index retains its 16 MiB limit.

Manually archived tab rows showed no Delete or Restore glyphs on hover, including
when selected and with the pointer over either half of the row. Only the title
tooltip appeared. Activating the row restored the tab and closed the Library.
The glyph condition reported in session 1 was not reproduced; other archived
item kinds and automatic archives were not settled by this capture.

Session 12 revises the split-origin case. “Archive Item” on a two-pane split
creates two ordinary single-tab Archive rows. Each row shows Trash and Restore
on title/left and tail hover, hides them away, and uses “Restore” as the tail
tooltip. A title click opens Peek above Library and leaves the record archived.
Evidence: `.re/capture/s12/m1/arc/v25/131-d2-archive-fresh/`,
`archive-split-{baseline,menu,sidebar,away}`, `D2-Archive-S{1,2}-{left,right}`
and `archived-split-selected-final` PNG/AX pairs; C-report-s12 §C12-D2-4.

Open follows that behavior for every single-tab Archive row, including both
split panes, at every width (lead ruling 2026-11-13 00:55). That shared behavior
is an Open design ruling; session 12 did not establish it for every origin.
Existing row geometry and selected styling stay unchanged. Return keeps its
existing Restore action. Folder rows keep their existing behavior. Narrow-width
layout, the second selected row and an actual Restore click remain unobserved
in Arc; the ruling adds no width or row-position branches.

`tools/e2e/archive_split_rows.py` verifies the real split Archive Item path,
ownership, both ordinary rows, tracking hover, native title/button clicks, Peek
without restoration, keyboard routing and empty Archive. `library_content.py`
retains the capture pipeline, source URL bounds and Archive keyboard checks.
