# Library overlay behavior and geometry

Observed in unmodified Arc 1.172.2 (90755) on the M1 built-in display at 2×. The standard browser window was 1280×800 points. Narrow captures used 900×850. This file contains our observations only. It contains no Arc assets, captured images, titles, URLs or profile data.

Evidence names below refer to the private `s1-library/m1/arc/` capture blocks. Each accepted still retains its PNG, native AX tree, window/display metadata and source action receipt. The private C1 report records failed attempts and missing coverage separately.

## Behavior

| Observation | Evidence |
|---|---|
| Library appears inside the browser window. Its six categories are Media, Downloads, Easels, Spaces, Boosts and Archived Tabs. | `02-priority-clear/s1-SECTION-rest` PNG/AX |
| Clicking the sidebar Downloads badge with the New Tab command bar closed opens the full Library at Downloads. This path did not open a separate popover or fan. | `28-downloads-quick-pointer/s1-downloads-quick-click-result-before`, `s1-downloads-quick-click-result`, `s1-downloads-quick-open`; one passing CG ownership check and one fresh AX-resolved click |
| Clicking a Downloads item title opens the file. No selected-item preview state was established. | `18b-downloads-click` action receipt: the synthetic file opened in TextEdit and the next event stopped on foreign focus |
| Hovering a Downloads item reveals More. Clicking More opens Open txt, Copy txt, Show in Finder, Hide from Arc and Move to Trash, with a separator before the final two items. | `19c-downloads-more/s1-downloads-item-context-window-38400.png`; native popup captured separately; only Esc sent |
| Archive row hover exposes Trash and Undo. Neither action was exercised. | `20-archive-more/s1-archive-item-hover` PNG/AX |
| Filter opens an inline editor in the list column. Archive rows move below that editor. | `10-filter-bottom/s1-downloads-filter-open`, `11-archive-from-spaces/s1-archive-filter-open` |
| A Spaces row selected through AX navigates to that tab and leaves Library. | `02-priority-clear/s1-spaces-row-select-result` |
| The second bottom rail button opens a referral modal. No link was copied or shared. | `10-filter-bottom/s1-library-bottom-second-result` |
| The right-hand region can show the current browser page without an Archive row selection. It is not evidence of an item preview. | `11-archive-from-spaces/s1-archive-populated` |

History was not one of the six Library categories. Earlier M5 menu evidence identifies View History, Cmd+Y, opening the browser's internal History tab. Evidence: `s1-library/arc/02-library-sections/s1-history-app.ax.json`, `s1-history-rest.ax.json` and the action receipt. No separate Notes category was observed. Media was left at its first-use card; Show Media was not pressed.

## Geometry

All frames are `[x,y,width,height]` in points from the window's top-left. AX glyph bounds do not establish full hit targets. Text bounds do not establish font size.

| Component | Measured value | Evidence |
|---|---|---|
| Category rail | Width112; six targets97×80 at x8 | Arc02 section AX |
| Category vertical layout | Tops105/205/305/405/505/605; interval100, gap20 | Arc02 AX; interval/gap derived |
| Standard left group | Width417 including rail | Arc02 AXGroup; content allocation305 derived |
| Populated Downloads/Archive viewport | `[112,56,304,744]` | Arc05 and Arc11 AXScrollArea |
| Item interval | 56 | Repeated title/icon y positions in Arc05/11; not an AXRow height |
| Download icon and text | Icon24×24; title17 high; subtitle15 high | Arc05 AX |
| Download title x | 164 completed;172 in progress | Arc05 and Arc08b AX |
| Search text field | Downloads/Archive `[164,19.5,159,17]`; other searchable categories235 wide | Arc02 AX; excludes surrounding rounded background |
| Filter button | `[336,10,73,36]` | Arc10/11 AX |
| Archive filtered viewport | `[112,282,304,518]` | Arc11 AX |
| Spaces cards | 240×704, horizontal gap24 | Arc02 partial AX; offscreen cards included |
| Spaces standard tab rows | Height41 | Arc02 AXRow; spacer allocations excluded |
| Bottom rail controls | `[8,760,32,32]`, `[73,760,32,32]` | Arc02/10 AX |
| Archive hover glyphs | Trash `[339.5,103.5,13.5,15.5]`; Undo `[373.5,104.5,13.5,13.5]` | Arc20 AXImage; glyphs, not complete hit areas |

Selected tile corner radius is an approximate12 points from pixel edge fits. Residuals were0.39–0.46 pixels. Gradients and continuous corners limit this estimate. Labels are centered below icons and appear bold; AX did not expose their font family, weight or point size. Evidence: Arc02 lossless frames and derived measurement sheets.

## Appearance and motion limits

Light and Dark were captured at both window sizes. Colors depend on the Space theme. Private sheets retain named pixel positions and embedded PNG ICC→sRGB conversion; no universal palette is inferred. Evidence: Arc13 Light and Arc27 Dark section frames. Arc27 verifies Dark before capture and Automatic after restoration.

Arc12 native movies supplied92 closing frames over2.020s at45.05effectivefps and81 opening frames over1.386667s at57.69effectivefps. Tracking one visible pane boundary gave about51 points of travel. The best tested edge model was ease-out-cubic: closing about0.20s with0.38pt RMS residual; opening about0.10s with1.30pt RMS residual. These are pixel-edge guesses, not exact component durations, opacity, spring parameters, input latency or physical scanout measurements. Evidence: `12-library-movie/s1-library-{opening,closing}-movie/position.measure.json` and preserved movie PTS.

Arc27's Downloads→Archive movie has76 decoded frames at34.40effectivefps. Its whole-image fit mixes selection, position and content changes; its fitted duration/curve is not accepted as a component animation. Compressed movie frames do not qualify exact colors.

## Coverage limits

In-Library item preview, Archive selection/context, item action execution, resize-handle behavior, exhaustive keyboard/focus routes, populated Media/Easels/Boosts and all sidebar interaction states remain uncaptured. The owned drag image and cancellation were recorded; Arc's thin drop-target rails were not driven further, per the lead's C1 ruling. These observations do not establish untested behavior.
