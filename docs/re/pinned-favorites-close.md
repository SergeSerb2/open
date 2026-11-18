# Pinned tabs and Favorites: close, unload, reset, select

Lane PINFAV, 2026-11-17. Runtime capture of Arc **1.172.2** on the M1, under the
screen lock, with the session-13 capture harness (AX-resolved pointer clicks and approved keys, LEAD 19:30 and
23:45 rulings). Synthetic loopback pages only (`http://127.0.0.1:39191/PF*`, titles `Open-capture page /PF*`),
in a throwaway Space that the last block deleted.

**Version difference:** the reference build is Arc **1.170.0** (build 89123, `/Applications/Arc.app` on the M5), but the M1, the only machine where Arc may be driven, has 1.172.2 (`CFBundleShortVersionString`). These facts are from 1.172.2; no change in this area between the two versions is known, but none was checked against 1.170.0 at runtime. Raw evidence (AX dumps, PNGs, session logs) stays in
`.re/pinfav/out/s1`–`s4` (git-ignored). Each row names the block and frame.

## Pinned rows

| ID | Fact | Evidence |
|---|---|---|
| P1 | A hovered pinned row that is **not** selected shows "×" (AX id `closeButton`, 26 × 26 at the row's right end). This holds while its page is loaded (the row was visited seconds before) and after it was unloaded. Clicking "×" removes the row from the sidebar; it is not moved to Today. | Block 1 `p1-hover-a-loaded` (PNG: "×" on row /PFA; AX `closeButton` `[344, 306, 26, 26]`), `p1-after-a-accessory` (/PFA gone from the outline, Today unchanged). Block 5 `u1-hover-b-unloaded` → `u1-after-b-x` (unloaded /PFB, same result). |
| P2 | The **selected** pinned row shows "−" in the same slot, at its pinned URL and after it navigated away. | Block 2 `c0-b-selected` and `c2-navigated` (PNG crops: "—" glyph; AX `closeButton` present). Matches F0014 (`interaction-states.md`). |
| P3 | Cmd-W on the selected pinned tab keeps the row in Pinned. | Block 2 `c1-cmdw-pinned-at-url` (/PFB still the first outline row). |
| P4 | Cmd-W on a pinned tab that navigated away puts the row back on its pinned URL: the row title returns to the pinned page's title at once, and selecting the row again loads the pinned URL. The "/" mark between icon and title shows while it is away (`c2-navigated`). | Block 2 `c2-navigated` (row "Lisbon weather", window title "Lisbon weather") → `c3-cmdw-navigated` (row "Open-capture page /PFB") → `c4-reselected` (window title "Open-capture page /PFB"). |
| P5 | After Cmd-W on a pinned tab, Arc selects the tab that was selected before it. With no earlier tab in this window's session (right after a relaunch) **no tab** is selected: the window title becomes the Space name and no outline row is selected. | Block 2 `c1-cmdw-pinned-at-url` (relaunch, select /PFB, Cmd-W: no selected `AXRow`, window title "PF Pin"). `c5-double-cmdw`: history /PFT then /PFB; Cmd-W on /PFB selected /PFT, so the second Cmd-W archived /PFT. |
| P6 | Closing a Today tab that was the last row selected the row above it (/PFU). Arc's rule for other Today positions was not captured; Open keeps its strip-neighbour rule for Today tabs. | Block 2 `c5-double-cmdw` (second Cmd-W). |
| P7 | After a relaunch, no tab is selected and pinned rows are unloaded. | Block 2 `c0-relaunch`. |

## Favorites

| ID | Fact | Evidence |
|---|---|---|
| F1 | The command-bar action "Favorite Tab" moves the selected Today tab into Favorites; it stays selected. (Typing "Add to Favorites" only offers a web search.) | Block 6 `q-favorite-tab` (selected result "Favorite Tab"), `h1-fav-added`. Block 5 `g0-query` (search row only). Action name also in session 12 `v22/113-d2-favorite-survey`. |
| F2 | A hovered Favorite tile shows **no** close or unload button, selected or not, loaded or not. The selected tile has its accent ring; a hovered unselected tile has the darker fill. | Block 6 `h2-hover-fav-selected`, `h4-hover-fav-unselected` (PNG crops; no `closeButton` anywhere in the AX tree). |
| F3 | Cmd-W on the selected Favorite keeps the tile and selects the tab selected before it (/PFV). | Block 6 `h3-cmdw-fav` (tile present; window title "Open-capture page /PFV"; /PFV row selected). |
| F4 | A Favorite that navigated away shows the new page's title; Cmd-W puts it back on its saved URL and title. | Block 6 `h6-fav-navigated` (tile "Lisbon weather") → `h7-cmdw-fav-navigated` (tile "Open-capture page /PFG"). |

## Not captured

- Middle-click on a row or tile: the capture pointer tool posts left and right clicks only. Open has no middle-click action on sidebar rows and keeps none.
- Drag between Favorites, Pinned and Today: the synthetic drag from a Today row toward the Favorites grid moved the Arc window instead of the tab (block 3 `stop-dialog-21.98`, window frame moved from `[20, 60]` to `[130, 76]`). Open's existing drop rules stay.
- What "×" on a pinned row does to the Archive (archive versus delete): the row left the sidebar; the Library was not opened. Open archives it, like "×" on a Today row (`features-core.md` §1.2 r11 tooltip text).
- The pinned row menu's "Remove Pin" result.

## Open's implementation (lane PINFAV)

- `OpenSidebar/SidebarRows.swift` `TabCellView.showsUnload`: "−" only on the selected pinned row (P2); "×" on other pinned rows sends `.archiveNodes` (P1). The generic `.close` intent still keeps pinned tabs (Cmd-W, keyboard Delete, `chrome.tabs.remove`).
- `OpenSidebar/FavoritesView.swift`: no tile button (F2).
- `App/WebContent/EngineWebContentHostFactory.swift` `finishClosingTab`: a closed pinned tab or Favorite returns to its pinned URL and title (P4, F4) and the window selects the node selected before it in this launch, or none (P5, F3).
