# Arc runtime observations (signed-in session)

This file is the measured spec for rebuilding Arc's main window. All values come from the running, signed-in Arc 1.170.0. We only read data: accessibility (AX) attributes, window screenshots, and copies of Arc's data files. We sent no input to Arc.

Personal data is not in this file. Space names, tab titles, and URLs are replaced by placeholders such as "Space A". Raw captures stay in `.re/runtime/` (git-ignored).

## 0. Capture conditions and method

| Item | Value |
|---|---|
| Date | 2026-10-24 |
| Display | One external display, 2560x1440 pt, backing scale 1.0 (1 px = 1 pt) |
| macOS appearance | Dark (`defaults read -g AppleInterfaceStyle` → `Dark`) |
| Arc window | One browser window, 1280x1394 pt. Arc was not the frontmost app, so the window was inactive. |
| Sidebar | `anchored`, width 228 (`StorableWindows.json` → `sidebarViewPreferences.sidebarWidth`) |
| Content | No tab was selected. The web content panel showed its empty state. No web page was loaded. |
| Current Space | 6 favorites, 10 pinned tabs, 0 Today (unpinned) tabs. 4 Spaces in total. |

Evidence files (local only):

- AX tree with window-relative frames: `.re/runtime/ax-frames2.json` (tool: `~/Library/Caches/OpenRE/scripts/axframes <pid>`). Outline view: `.re/runtime/ax-flat.txt`.
- Screenshot: `.re/runtime/shots/sc-5245.png` (`screencapture -x -o -l <windowID>`), sRGB copy `sc-5245-srgb.png`.
- Analysis scripts: `~/Library/Caches/OpenRE/scripts/analysis/` (see its `README.txt`).

Marks used below: **measured** (read from AX or pixels), **derived** (computed from measured values), **guess** (an inference; verify before use).

**Color warning.** The display's ICC profile ("Display", embedded in every screenshot) has very wide primaries (red xy 0.708/0.294, green 0.190/0.775, blue 0.129/0.047). Raw PNG values are in that space and look much paler than Arc's real colors. Every color in this file was converted to sRGB with the embedded profile (`analysis/arcimg.py`, PIL `ImageCms`). Do the same for future captures. Expect about ±2 levels of error per channel.

## 1. Window chrome layout

All frames are `[x, y, w, h]` in points, relative to the window's top-left corner (AX `rel` field). Source: `.re/runtime/ax-frames2.json` unless a row says "px".

```
x: 0    12 35 58  77    122 156 190   228                                   1270 1280
y:0 +-------------------------------+--------------------------------------------+
    | o  o  o  [=]    <-   ->   ⟳   |  10 pt margin                              |
 46 | [ (q) Search or Enter URL…  ] | +----------------------------------------+ |
 90 | [tile] [tile] [tile]          | |                                        | |
145 | [tile] [tile] [tile]          | |   web content panel                    | |
205 | (icon) Space title        ... | |   x 228..1270, y 10..1384              | |
239 | (fav)  Tab title    (row 41)  | |   radius ≈6, shadow 0 1 6 black 25%    | |
    | ...                           | |                                        | |
    | (+)    New Tab                | |                                        | |
1344| ----- bottom bar (50 pt) ---- | |                                        | |
1353| [Home] (sp)(sp)(sp)(sp)   [+] | +----------------------------------------+ |
1394+-------------------------------+--------------------------------------------+
```

### 1.1 Frames

| Element | Frame | Notes |
|---|---|---|
| Window | `[0, 0, 1280, 1394]` | AX role `AXWindow`, subrole `AXStandardWindow`, identifier `bigBrowserWindow-<window UUID>` |
| Close / minimize / zoom | `[12,16,16,16]`, `[35,16,16,16]`, `[58,16,16,16]` | Pitch 23. px: each visible circle is 12 pt in diameter and centered in its frame (centers at y = 24). |
| Sidebar toggle ("Hide sidebar") | `[77, 7, 32, 32]` | SwiftUI button in an `AXHostingView`. px: glyph ink 19x15, centered. |
| Back ("Go back") | `[122, 7, 32, 32]` | px: glyph 15x12 |
| Forward ("Go forward") | `[156, 7, 32, 32]` | px: glyph 15x12. Pitch back→forward→reload = 34. |
| Reload ("Reload this page") | `[190, 7, 32, 32]` | px: glyph 14x17. Right edge 222 = 6 pt from the sidebar edge. |
| Command/URL field | `[8, 46, 212, 36]` (px) | Not an AX element itself. px: fill edges at x 8..219, y 46..81. |
| Magnifier button | `[14, 52, 24, 24]` | px: glyph 12x12 at x 20..31, y 58..69 |
| Placeholder text | `[41, 55, 175, 18]` | AX id `commandBarPlaceholderTextField`. Text "Search or Enter URL…" (one ellipsis character; it matched better than three dots). |
| Sidebar scroll area | `[0, 82, 228, 1262]` | Ends at y = 1344, where the bottom bar starts. Holds an `AXCollectionList` 912 pt wide = 4 Spaces x 228. guess: one horizontal page per Space. |
| Favorites section | `[0, 82, 228, 118]` | AX id `sidebarFavoritesCollectionView` |
| Favorites grid | `[8, 90, 212, 102]` | Inset 8 on all sides. 3 columns. |
| Favorite tile | 65.33 x 47 at x = 8, 81.33, 154.67 and y = 90, 145 | derived: tile width = (212 − 2 x 8) / 3. Column gap 8, row gap 8. |
| Favorite icon | 18x18 frame, centered in the tile | px: 16x16 ink. Some known web apps get a larger "app tray" icon instead (AX desc pattern `…AppTrayIcon`, 42x42 frame). |
| Space section | starts at y = 200 | Holds the header and the tab list. |
| Space icon | `[13, 205, 26, 26]` | px: emoji ink about 18x17 at x 17, y 210 |
| Space title | `[41, 209, 170, 18]` | AX id `sidebarSpaceName` |
| Space "More" button | `[213, 205, 2, 26]` | AX id `sidebarSpaceEditButton`, desc "More". Collapsed to 2 pt wide; nothing is drawn. guess: it expands on hover. |
| Tab list | `[0, 236, 228, 1108]` | `AXOutline` (an `NSOutlineView`), id `sidebarAllTabList`, one column with id `Tabs`. |
| Spacer row | `[0, 236, 228, 3]` | First outline row. 3 pt tall, empty. |
| Tab row | `[0, 239 + 41·i, 228, 41]` | Row pitch 41. The row's button is `[0, y, 228, 40]`. Button AX title and AX identifier are both the display title. |
| Tab favicon | `[17, y+11, 18, 18]` | px: 16x16 ink at x 18..33 (1 pt inset) |
| Tab title | `[43, y+10, 168, 19]` | Right edge 211. px: baseline at y + 26. A second, empty `AXStaticText` sits at `[43, y+27, 2, 16]` (guess: a hidden subtitle line). |
| "New Tab" row | next row after the last pinned tab: `[0, 649, 228, 41]` | Plus glyph frame `[17, y+11, 18, 18]`, px ink 11x11 at x 20..30. Label `[43, y+10, 58, 19]`; the 58 pt width is the label's own width. |
| Pinned/Today divider | not drawn | px: a row-difference scan of the sidebar (y 84..1344) finds no line between the last pinned row and "New Tab". The Today section was empty. guess: the divider appears only when Today has tabs. |
| Bottom bar | `[0, 1344, 228, 50]` | derived from the frames below. Buttons sit 9 pt above the window bottom. |
| Home button | `[8, 1353, 32, 32]` | AX desc "Home". px: glyph 15x16. |
| Space switcher | scroll area `[42, 1344, 144, 50]`, section `[46, 1353, 136, 32]` | Items `[45 + 34·i, 1352, 36, 34]`, AX id `SidebarDockItem-<Space title>`. Pitch 34; frames overlap by 2. With 4 Spaces the strip is centered (4 pt each side). |
| Space switcher icon | emoji ink about 13–15 pt | The current Space shows its emoji in color. Other Spaces are drawn faded and desaturated (measured visually; the opacity fit failed, so no number). |
| Plus button | `[188, 1353, 32, 32]` | AX id `sidebarPlusButton`. px: glyph 14x14. |
| Hidden image | `[232, 684, 32, 27]` | AX desc "New Tab". px: nothing drawn. guess: a drag or drop placeholder. |
| Web content panel | `[228, 10, 1042, 1374]` (px) | See 1.2. |

General rules (derived): the sidebar column is 228 wide (= `sidebarWidth`). Sidebar content uses an 8 pt side inset (x 8..220). Favicons and the Space icon share the center line x = 26. Text starts at x ≈ 41–43 (ink at x ≈ 44).

### 1.2 Web content panel

| Property | Value | Mark |
|---|---|---|
| Frame | x 228..1269, y 10..1383 (inclusive) → `[228, 10, 1042, 1374]` | measured (px scan of rows and columns, `sc-5245.png`) |
| Insets | left 0 from the sidebar edge (x = `sidebarWidth`), top 10, right 10, bottom 10 | derived. guess for other sizes: `[sidebarWidth, 10, W − sidebarWidth − 10, H − 20]` |
| Gap to sidebar items | 8 pt (items end at x 220) | derived |
| Corner radius | ≈ 6 pt | measured. Corner pixel coverage fits a 6 pt circle row by row (insets 3.6, 2.0, 1.1, 0.55, 0.2 px). Circular vs continuous cannot be told apart at 1x. |
| Border | none visible at 1x | measured: the edge falls off smoothly, with no 1 px line |
| Shadow | black, opacity ≈ 0.25, Gaussian σ ≈ 3 pt, offset y ≈ +1 pt (down). CSS: `0 1px 6px rgba(0,0,0,.25)`. CALayer guess: `shadowRadius 3`, `shadowOpacity 0.25`, offset 1 pt down. | measured: least-squares fit of 4 edge profiles, RMS error 0.0012 |
| Empty-state fill | white at ≈ 10% over the window gradient (the gradient shows through) | measured: panel vs margin pixels, G and B channels give 0.10–0.11 |

Edge darkening profiles used for the fit (1 − pixel/background, from the edge outward):

| Edge | d = 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|
| left | .106 | .076 | .050 | .030 | .016 | .007 |
| right | .108 | .078 | .050 | .032 | .016 | .010 |
| top | .079 | .051 | .030 | .019 | .010 | .006 |
| bottom | .140 | .107 | .077 | .048 | .030 | .016 |

### 1.3 Other radii

| Element | Radius | Mark |
|---|---|---|
| Window corners | about 16 pt, continuous (squircle) curve | measured from the alpha channel: the curve runs 24 px along each edge. Drawn by the system, not by Arc. |
| Command/URL field and favorite tiles | the same shape on both. Equal to a circle of r ≈ 11, or a continuous corner of about 8–9. | measured: row-by-row edge insets 5.7, 4.2, 3.2, 2.3, 1.6, 1.0, 0.7, 0.5 px. Re-measure on a 2x display. |

## 2. Typography

Method: we cut each label from the screenshot and converted it to ink coverage. We drew the same string with `NSFont.systemFont(ofSize:weight:)` at 1x for each candidate size and weight, at subpixel offsets 0, ¼, ½, ¾ (`analysis/textcov.swift`). Then we kept the candidate with the best normalized cross-correlation (NCC) (`analysis/match.py`). The winning matches all landed on whole-pixel offsets.

| Element | Font | Size | Weight | NCC | Next best |
|---|---|---|---|---|---|
| Tab title (4 strings tested) | SF Pro (system) | 14 | Regular | 0.992–0.994 | 14 Medium or 13.5 Medium, 0.74–0.88 |
| "New Tab" label | SF Pro | 14 | Regular | 0.992 | 14 Medium, 0.89 |
| Space title | SF Pro | 13 | Semibold | 0.994 | 13 Medium, 0.97 |
| URL placeholder | SF Pro | 13 | Medium | 0.991 | 13.5 Regular, 0.84 |

Vertical placement (measured from ink): tab title baseline = row y + 26 (frame y + 16). Space title baseline = frame y + 14. Placeholder baseline = frame y + 14. Text frames are 19 pt tall at 14 pt and 18 pt tall at 13 pt. That is the `NSTextField` height for these sizes (guess).

Text colors (sRGB; `analysis/textcolor.py`). "Black a" means black drawn at opacity a over the gradient. The red, green, and blue ratios to the background were equal within 1%, so the color is neutral black, not a tint.

| Element | Color | Closest static token (from `design-tokens.md`) |
|---|---|---|
| Tab title | the Space theme color `semanticColorPalette.light.title`, opaque. Fully covered pixels equal `#320E00`, the stored value. | — (theme driven) |
| Space title | black a ≈ 0.48 | `GrayA10` light = black 0.48 |
| URL placeholder | black a ≈ 0.33 | `CommandBarTextSecondaryColor` = black 0.33 |
| "New Tab" label | black a ≈ 0.33 | same as above |

## 3. Colors and theme

### 3.1 Window background gradient (current Space, sRGB)

The sidebar has no fill of its own. The window gradient fills the sidebar column and the 10 pt margins around the panel. Under the panel we rebuilt it by removing the measured 10% white. Each sample is a 9x9 average.

| Where | Color |
|---|---|
| Top-left (sidebar, y 6) | `#F2A686` |
| Top-center (margin) | `#EDB882` |
| Top-right (margin) | `#EDCA83` |
| Left-middle (sidebar) | `#F6A58D` |
| Center (under the panel) | `#F3B48C` |
| Right-middle (margin) | `#EDBE88` |
| Bottom-left (sidebar, y 1340) | `#FB9192` |
| Bottom-center (margin) | `#F5998F` |
| Bottom-right (margin) | `#F4988E` |

Mapping to the stored theme of this Space (3.3):

- `baseColors` = [`#FF8558` orange, `#F0E941` yellow]: the orange-to-yellow change runs left to right along the top. The exact angle is a guess.
- `overlayColors` = [black at alpha 0, `#FF5598` pink at alpha 1]: the pink grows from top to bottom and dominates the bottom edge. guess: the overlay is a vertical fade from `overlayColors[0]` at the top to `overlayColors[1]` at the bottom.
- Every observed color is much lighter than the stored stops. Example at top-left: about 27% white mixed into `#FF8558`. guess: this comes from `translucencyStyle: "light"`, `intensityFactor: 0.8`, and/or the vibrancy layer. `noiseFactor` is 0 here, so no grain was visible.
- Design note: `design-tokens.md` says "The web view stays solid." That is true for loaded pages (guess). In the empty state the panel is see-through (white at 10%).

### 3.2 Overlays and glyphs (window inactive)

| Element | Measured | Closest token |
|---|---|---|
| Favorite tile fill | black a ≈ 0.045 (3 tiles, ratio 0.95–0.96 on all channels) | `GrayA3` light = black 0.05 |
| Command/URL field fill | black a ≈ 0.045–0.047 | `GrayA3` |
| Content panel (empty state) | white a ≈ 0.10 | — |
| Content panel shadow | black 0.25, σ 3, y +1 | — |
| Toolbar glyphs (all four buttons report `AXEnabled = false`) | peak black a ≈ 0.22 | `GrayA8` light = black 0.22 |
| Traffic lights (inactive window) | black a ≈ 0.10, drawn by the system | system |
| Magnifier glyph | peak black a ≈ 0.39 | thin stroke, so peak < true alpha (guess) |
| "New Tab" plus glyph | peak black a ≈ 0.48 | `GrayA10` (guess) |
| Home and plus glyphs (bottom bar) | peak black a ≈ 0.28 | thin strokes; true alpha is likely higher (guess) |

"Peak" means the darkest 12 pixels. A 1x glyph stroke rarely covers a full pixel, so peak values are lower bounds. Re-measure glyph opacity on a 2x display.

### 3.3 Space theme object (`customInfo.windowTheme`)

Shape from all 3 themed Spaces in `StorableSidebar.json`. The default personal Space has no `windowTheme`. Notation is ours (TypeScript-like).

```ts
interface WindowTheme {
  primaryColorPalette: { midTone: Color; shaded: Color; shadedDark: Color; tintedLight: Color };
  semanticColorPalette: { appearanceBased: { light: SemanticColors; dark: SemanticColors } };
  background: {
    single: { _0: {                                   // enum case "single"; other cases unknown
      style: { color: { _0: { blendedGradient: { _0: {
        baseColors: Color[];                          // 2 here
        overlayColors: Color[];                       // 2 here; [0] = black alpha 0 in all 3 Spaces
        modifiers: { overlay: "grain"; noiseFactor: number /* 0 or 0.35 */; intensityFactor: number /* 0.8 or 1 */ };
        translucencyStyle: "light";                   // only value seen
        wheel: { analogous: {} };                     // only value seen; enum, empty payload
      } } } } };
      contentOverBackgroundAppearance: "light";       // only value seen; picks the text palette
      isVibrant: boolean;                             // true in all 3
    } };
  };
}
interface SemanticColors {                            // the same 12 keys in light and dark
  background; backgroundExtra; title; subtitle; hover; focus;
  foregroundPrimary; foregroundSecondary; foregroundTertiary;
  minContrastColor; maxContrastColor; cutoutColor;    // each a Color
}
interface Color { red: number; green: number; blue: number; alpha: number; colorSpace: "extendedSRGB" }
```

Facts from the real values (measured, all 3 themed Spaces):

- Components go outside 0…1 (seen: −0.32 to 1.019). They are extended sRGB. Clamp them or keep an extended color space.
- Only 15 values are independent. The rest repeat the four `primaryColorPalette` colors:
  - `light.foregroundPrimary` = `dark.foregroundTertiary` = `shaded`
  - `light.foregroundSecondary` = `dark.foregroundSecondary` = `midTone`
  - `light.foregroundTertiary` = `light.minContrastColor` = `light.cutoutColor` = `dark.foregroundPrimary` = `dark.maxContrastColor` = `tintedLight`
  - `light.maxContrastColor` = `dark.minContrastColor` = `dark.cutoutColor` = `shadedDark`
  - `dark.background` = `light.title`
- In dark, `hover` alpha is 0.48 and `focus` alpha is 0.8075 in every Space. Everything else is opaque. So Arc derives the palette with a formula (guess). `midTone` equals `baseColors[0]` in only 1 of 3 Spaces.
- The text palette follows `contentOverBackgroundAppearance`, not the macOS appearance. macOS was in Dark mode, yet tab titles used `light.title`. This is the stored result of the "Space contrast rule" that `design-tokens.md` §9 item 8 asks about.

Example: the current Space (sRGB hex after clamping).

| Key | light | dark |
|---|---|---|
| background | `#F6EAE4` | `#320E00` |
| backgroundExtra | `#FEFDFC` | `#190700` |
| title | `#320E00` | `#F2E0D7` |
| subtitle | `#DCAC94` | `#807571` |
| hover | `#EDD5C9` | `#BF673C` a 0.48 |
| focus | `#D39779` | `#B85727` a 0.8075 |
| primary: midTone / shaded / tintedLight / shadedDark | `#FF8558` / `#FF8558` / `#FFEAE3` / `#A72E00` | |

`hover` and `focus` were not visible (nothing was hovered or selected). guess: they paint the hovered row and the selected tab. Capture this with the checklist in §7.

## 4. Data files as found on disk

Source: `~/Library/Application Support/Arc/*.json`, read-only. Copies are in `.re/runtime/appsupport/`. The full redacted schema dump is `.re/runtime/schema-sidebar-raw.txt` (`analysis/schema.py`). This section adds runtime checks to `data-model.md`. It does not repeat that file.

### 4.1 Encoding rules (measured)

- Swift `Codable` output. Enums are single-key objects, and payloads sit under `_0`, `_1` (example: `{"urlMatch": {"_0": {"contains": {}}, "_1": "<host>"}}`).
- Ordered dictionaries are flat alternating arrays `[key, value, key, value…]`. Keys can be strings or enum objects. `sidebar.containers` is `[{"global":{}}, {...}]`.
- Times in Storable files are seconds since 2001-01-01. Chromium times are microseconds since 1601 (`13437374059733323`). `firebaseSyncState.syncData.orderedSpaceIDs.lastChangeDate` holds −63114076800, which is Swift `Date.distantPast` used as a "never" marker.
- IDs are upper-case UUIDs, except seeded IDs: `thebrowser.company.defaultPersonalSpaceID`, `…PinnedContainerID`, `…UnpinnedContainerID`, `thebrowser.company.arcBasicsFolderID`, `thebrowser.company.arcBasics.splitViewID`, `thebrowser.company.arcGettingStarted`, and short words such as `arcResources` or `sameEnergy`.

### 4.2 Files

| File | Redacted shape | Notes |
|---|---|---|
| `StorableSidebar.json` | `{version:1, sidebar:{containers:[{global:{}}, {items:[id,Item…], spaces:[id,Space…], topAppsContainerIDs:[{default:true}, id]}]}, sidebarSyncState:{…}, firebaseSyncState:{…}}` | 46 items, 4 Spaces. See 4.3. |
| `StorableWindows.json` | `{version:1, lastFocusedSpaceID, sidebarViewPreferences:{sidebarMode:"anchored", sidebarWidth:228}, windows:[{id, style:{standard:{sidebarContext:{global:{}}}}, focusedSpaceID, stayOnTop:false, sidebarMode, sidebarWidth, spacesWithCollapsedPinnedSections:[], expandedItems:[], itemCreatedDates:[], itemLastActiveDates:[], contents:{windowContents:[id,{id}], splitViewState:{windowContentIDs:[id], focusedContentID}, windowContentSidebarItemMap:{keysToValues:[]}}}]}` | `windows[].id` = the UUID in the AX window identifier `bigBrowserWindow-<id>` (measured match). |
| `StorableLinkRouting.json` | `{version:1, rules:[{id, destination:{space:{_0:{mostRecent:{}}}}, sourceComponents:[{id, componentType:{urlMatch:{_0:{contains:{}}, _1:<host>}}}]}], defaultDestination:{littleArc:{_0:{mostRecent:{}}}}}` | One rule. guess: Arc created it (defaults flag `didSetDefaultGoogleMeetRoute = 1`). |
| `StorableArchive.json` | `{version:1, autoArchiveStartTime}` | No archived items yet. |
| `StorableHome.json` | `{version:1, preferences:{dataSourcePreferences:["documents",true,"screenshot",true,"desktop",true,"download",true,"capture",true]}, isOnboardedToMediaPage:false, permissions:{folderToPermissions:[<file URL>,{hasPermissions:true}…]}}` | Media/Library sources. Do not import. |
| `StorablePreviewsDataClient.json` | `{version:1, data:[{previewType:{gcalendar:true}, profile:{default:true}}, {lastRefreshed, metadata:{gcalendar:{currentDate, accounts:{}}}}]}` | Calendar preview cache. This file changed during the session. |
| `StorableKeyBindings.json` | `{version:1, userOverrides:[]}` | No custom shortcuts. |
| `StorableCommandBarAdditionalRanking.json` | `{version:2, dataByProfile:{}}` | |
| `StorableLiveData.json` | `{version:1, liveDataPerProfile:[]}` | |
| `StorableDefaultBrowserPrompts.json` | `{version:1, displayHistory:{elements:[]}}` | |
| `StorableAuthState.json` | `{version:1, session:{user:{name,email,id,avatarUrl,createdAt}, wasExistingUser, finishedOnboarding}}` | Account data. Never import or log. |
| `StorableFirebaseEncryptionKey.json` | `{version:1, encryptionKeysByID:{<hex64>:[32 ints]}, hashedPassword:[32 ints]}` | Secrets. Never import or log. |

### 4.3 How the sidebar tree forms (verified against the live AX tree)

1. **Space order** = the order of `containers[1].spaces`. It equals `sidebarSyncState.container.value.orderedSpaceIDs` and the left-to-right order of the bottom Space switcher (measured, all 4 match).
2. Each Space has `containerIDs` = `["unpinned", <id>, "pinned", <id>]` and `newContainerIDs` = `[{pinned:{}}, <id>, {unpinned:{_0:{shared:{}}}}, <id>]` (the order varies per Space). Each id points to an `itemContainer` item with `containerType.spaceItems._0` = the Space id.
3. **Pinned rows** = the pinned container's `childrenIds`, in order. In the current Space the 10 children matched the 10 sidebar rows in order (measured).
4. **Row label** = `item.title ?? item.data.tab.savedTitle`. Measured: the 8 rows with a non-null `title` show `title`. The 2 rows with `title: null` show `savedTitle`.
5. **Favorites** = children of the `topApps` container named by `topAppsContainerIDs[1]` (key `{default:true}`). Order matched the grid, row by row (measured). Tile AX titles equal `savedTitle` (5 of 6). The sixth tile (a web app with an app-tray icon) shows a name that matches neither `title` nor `savedTitle`. guess: a built-in app name.
6. **Folders** = `data: {list: {}}`. **Split views** = `data: {splitView: {layoutOrientation:"horizontal", itemWidthFactors:[], focusItemID:null, customInfo:null, timeLastActiveAt:null}}`. Both nest through `parentID` / `childrenIds`. The only folder and split are in the untitled default Space and were not on screen (§7).
7. **Untitled Space**: the default personal Space has no `title`. The switcher calls it "Space 4", which is its 1-based position (measured). guess: Arc always uses "Space <position>".
8. **Window title** = the focused Space's title (measured: `AXWindow.title` = the Space title).
9. `sidebarSyncState.items` / `.spaceModels` wrap each item as `{value: <same object as in sidebar>, encodedCKRecordFields: <base64>}`. This is a CloudKit mirror. Ignore it.

What Import from Arc must read: `StorableSidebar.json` → `sidebar.containers[1]` (spaces, items, topAppsContainerIDs), each Space's `customInfo.iconType` and `customInfo.windowTheme`, and `StorableWindows.json` (sidebar width and mode, focused Space, window list). Optional: `StorableLinkRouting.json` (Air Traffic Control rules). Never read `StorableAuthState.json` or `StorableFirebaseEncryptionKey.json`.

### 4.4 Differences from `data-model.md`

| `data-model.md` says | The real file shows |
|---|---|
| `semanticColorPalette.appearanceBased`: `light`, "dark inferred" | Both `light` and `dark` exist in all 3 themes, with the same 12 keys. The list in `data-model.md` lacks `background`, `subtitle`, and `maxContrastColor`. |
| `primaryColorPalette: unknown`, `background: unknown` | Full shape in §3.3. |
| Display title rule `title ?? savedTitle ?? host` is **inferred** | `title ?? savedTitle` confirmed on 10 live rows. The `host` fallback is still unverified. |
| Color values (implied 0…1) | Extended sRGB, with components below 0 and above 1. |
| — | `spaces` order = `orderedSpaceIDs` = switcher order. An untitled Space shows as "Space N". |

## 5. Preferences

### 5.1 `company.thebrowser.Browser` defaults (live = snapshot `.re/runtime/defaults.txt`)

| Key | Value | Meaning (guess unless obvious) |
|---|---|---|
| `NSQuitAlwaysKeepsWindows` | 1 | System window restoration on |
| `arc_quitAlwaysKeepsWindows` | 0 | Arc's own "keep windows on quit" setting |
| `nativeAdBlockEnabled` | 0 | Built-in ad blocking off |
| `tidyTabsEnabled` | 0 | Tidy Tabs (AI) off |
| `instantLinksEnabled` | 0 | Instant Links (AI) off |
| `arcMaxAutoOptInEnabled` | 0 | Arc Max off |
| `disableHistoryClusters` | 1 | Chromium history clusters off |
| `chromiumDisabledFeatures` | `CATransactionV2` | Chromium feature switch passed at launch |
| `currentAppIconName` | `arc.original` | Alternate app icon |
| `availableAppIconNames` | original, candy, neon, flutedGlass, schoolbook, colorful | Unlocked icons |
| `didSetDefaultGoogleMeetRoute` | 1 | Arc created the default Meet routing rule (§4.2) |
| `shouldSkipUnboxingVideo`, `hasLaunchedBefore`, `SUHasLaunchedBefore` | 1 | Onboarding and Sparkle flags |
| `NSAppSleepDisabled` | 1 | App Nap disabled |
| `NSWindow Frame Optional("company.thebrowser.Browser").mainWindowAutosaveFrame` | `"x y w h  sx sy sw sh"` | Window autosave. The key name contains a Swift `Optional(...)` string by accident. |
| `SidebarAnalytics.storage` | JSON `{spaceFocusTimes:{}, lastSnapshotDate}` | Local analytics |
| `KronosStableTime`, `com.launchDarkly.*`, `ldGeneratedContextKey:ld_device`, `machineID`, `SUUpdateGroupIdentifier` | (ids redacted) | NTP clock, LaunchDarkly feature flags, Sparkle. Not needed. |

`company.thebrowser.browser.helper.plist` holds only `KronosStableTime`.

### 5.2 Chromium profile (`User Data/`)

- One profile directory, `Default`. `profile.name` = "Your Arc" (Arc's default name).
- The Chromium profile is new (`profile.created_by_version` 156.0.8078.48, `in_product_help.session_number` 2). It holds almost no settings yet. `profile.exit_type` = `Crashed`.
- `vertical_tabs.uncollapsed_width = 240`, `vertical_tabs.collapsed_state = false`. These are Chromium's own vertical-tabs keys, not Arc's sidebar (Arc's width is 228).
- `arc.dnt_disabled_migration_done = true` is the only `arc.*` key.
- No extensions are installed (no `extensions.settings`, no `Extensions/` folder).
- `Default/Sessions_Encrypted/` exists next to `Sessions/` (guess: an Arc or Chromium 156 encrypted session store).
- Local State: `tab_stats.window_count_max = 1`, `hardware_acceleration_mode_previous = true`. Nothing else is Arc-specific.

## 6. Window and display behavior (observed without input)

- One browser window. `AXWindow.title` = the focused Space title. AX identifier = `bigBrowserWindow-<StorableWindows.windows[].id>`.
- The window sat at x = 2559 on a display that is 2560 pt wide, so it was almost fully off-screen. Arc restored a frame from an earlier multi-display layout and did not clamp it (guess). Window capture still works.
- Height 1394 on a 1440 display with a 30 pt menu bar: the top is 8 pt below the menu bar and the bottom is 8 pt above the screen edge (`mainWindowAutosaveFrame` y = 8). guess: Arc's default frame or zoom insets the visible frame by 8.
- Arc owns 5 more windows, none on screen: four `2560x30` at (0,0) and one `500x500` at (0,940), all untitled, layer 0. guess: menu-bar-height helper windows and one pre-made hidden panel (command bar or Little Arc).
- The sidebar is an AppKit collection view. Its content is 912 = 4 x 228 wide (measured), and the AX tree holds a 228-wide page only for the current Space. guess: one page per Space, paged sideways, with only the current page loaded. Favorites are a separate collection view. Tabs are an `NSOutlineView`. Toolbar and bottom buttons are SwiftUI (`AXHostingView`). This supports a horizontal-slide Space switch (guess).
- AX reports all four toolbar buttons as disabled, the sidebar toggle included. Back, forward, and reload are expected to be off with no page loaded. The disabled sidebar toggle is unexplained (guess: the window is inactive, or no tab is selected).

## 7. States not observed and how to capture them

These states need input, which only the user may give. Use the recorder:

```sh
~/Library/Caches/OpenRE/scripts/capture-loop.sh -i 1 -l <label>      # AX + screenshots every 1 s, Ctrl-C to stop
~/Library/Caches/OpenRE/scripts/capture-loop.sh -i 0.2 -A -l <label> # screenshots only, about 4 frames/s, for transitions
~/Library/Caches/OpenRE/scripts/axflat.py <session>/<frame>/ax.json   # read a frame's AX tree
```

Output: `.re/runtime/sessions/<timestamp>-<label>/<frame>/{ax.json, windows.tsv, win-<id>.png}` plus `displays.tsv` and `session.txt`. Every on-screen Arc window is captured, including menus, popovers, Peek, and Little Arc windows. Identical frames are de-duplicated.

Before you start:

1. Move the Arc window fully onto a display (it is at x = 2559 now).
2. If you can, put it on a 2x (Retina) display. Glyph opacity and corner shapes need 2x. `displays.tsv` records the scale.
3. Click into Arc once so the window is active, then start the recorder.
4. Hold each state for at least 2 seconds.

| # | State | What it gives us | Steps for the user (label) |
|---|---|---|---|
| 1 | Active window | Traffic light colors, glyph opacity when active | Click Arc's sidebar background. Wait 3 s. (`active`) |
| 2 | Selected tab | Selected row fill (theme `focus`?), radius, inset, shadow | Click a pinned tab. Then click a favorite tile. (`selected`) |
| 3 | Hover states | Row hover fill (`hover`?), close "x" button, tile hover, toolbar button hover, Space "More" button | Hover over a tab row, a tile, each toolbar button, the Space title, and each bottom-bar item, 2 s each. (`hover`) |
| 4 | Loaded web page | Real panel radius and shadow over page content, and whether the panel is solid | Open any neutral page (for example a public docs site) in the current Space. (`webpage`) |
| 5 | Today section | Pinned/Today divider, "Clear" button, Today row style, section gaps | Press Cmd+T, type a neutral URL, press Return. Do this 3 times. (`today`) |
| 6 | Folders and split row | Folder row, chevron, indent step, expanded vs collapsed, split-view row | Switch to the untitled 4th Space (it has a folder with a split). Collapse and expand the folder. (`folders`) |
| 7 | Command bar | Panel frame, row height, fonts, selection fill | Press Cmd+T, wait, type 3 letters, wait, press Esc. Repeat with Cmd+L. (`command-bar`) |
| 8 | Space switch | Slide direction, duration, gradient cross-fade | Use `-i 0.2 -A`. Press Ctrl+1 then Ctrl+2, or click the switcher icons. (`space-switch`) |
| 9 | Split View | Divider width, pane gap, pane radius | Drag a tab onto the web content, or use the split shortcut from `menus-and-hotkeys.md`. (`split`) |
| 10 | Peek | Peek window frame, chrome, shadow | From a pinned tab, open a link to another domain. (`peek`) |
| 11 | Little Arc | Window size and chrome | Press Cmd+Opt+N, or open a link from another app. (`little-arc`) |
| 12 | Context menus | Menu items and order | Right-click a tab, a favorite, the Space title, a folder, and empty sidebar space, one at a time. (`menus`) |
| 13 | Sidebar hidden and reveal | Collapsed layout, hover-reveal overlay | Press Cmd+S. Move the pointer to the left edge. Press Cmd+S again. (`sidebar-toggle`) |
| 14 | Sidebar width limits | Minimum and maximum width | Drag the sidebar edge to its narrowest, then its widest stop. (`sidebar-resize`) |
| 15 | Theme editor | Picker layout, knobs, how `noiseFactor` and `intensityFactor` change | Right-click the Space title and choose the theme or color item. Change color, grain, and intensity. (`theme-editor`) |
| 16 | Light/dark and a dark Space | When `contentOverBackgroundAppearance` flips | Switch macOS to Light, then back to Dark. Set one Space to a dark color. (`appearance`) |
| 17 | Settings window | Tabs, layout, fonts | Press Cmd+, and click each tab. (`settings`) |
| 18 | Library / Home | The Home button target | Click the bottom-left Home button. (`library`) |
| 19 | Toasts and Site Control Center | Toast style, Site Control popover | Press Cmd+Shift+C (copy URL) on a page. Then open the site controls from the URL field (hover it to find the control). (`toasts`) |
| 20 | Second window | Multi-window titles, `StorableWindows` with 2 windows | Press Cmd+N, then switch Space in the new window. (`two-windows`) |

After each session, copy `StorableWindows.json` and `StorableSidebar.json` again (read-only) into `.re/runtime/appsupport/<label>/` to see what changed.

## 8. Tools (local, outside the repo)

| Tool | Purpose |
|---|---|
| `~/Library/Caches/OpenRE/scripts/axframes` (`.swift`) | AX dump with screen frames, window-relative `rel` frames, and state flags (`selected`, `focused`, `expanded`, `disabled`, `main`, `minimized`). Read-only. |
| `~/Library/Caches/OpenRE/scripts/arcwins` (`.swift`) | Window list (`<pid>`) and display list (`--screens`) with scale. |
| `~/Library/Caches/OpenRE/scripts/capture-loop.sh` | Recorder from §7. |
| `~/Library/Caches/OpenRE/scripts/axflat.py` | Prints an AX dump as an outline. |
| `~/Library/Caches/OpenRE/scripts/analysis/` | Color conversion, text matching, schema and redaction helpers used for this file. |
