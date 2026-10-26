# Arc design tokens

Target: Arc 1.170.0 (build 89123) at `/Applications/Arc.app`.
Use these values to build the Open design-token Swift file.
Draw every icon and texture again. Do not copy Arc files.

## How to read this file

- `Light` means the catalog entry with no appearance. It applies in light mode.
- `Dark` means `NSAppearanceNameDarkAqua`.
- `same*` means the catalog stores no dark entry. The light value applies in both modes.
- Hex is `#RRGGBB/alpha`. Alpha `1.00` means opaque.
- The catalog stores float components. Hex rounds each float to the near byte.
- The full float values stay in `.re/design/`. See the raw files list at the end.
- No catalog stores a high-contrast color set. See Section 1.1.

Evidence key. Each section names its source file and command.

- Colors and images: `xcrun assetutil --info <Assets.car>`.
- Cross-check: `rea inspect-asset-catalog /Applications/Arc.app --format json`.
- Strings: `strings -a .re/bin/Arc-arm64`.
- Fonts: `fontTools` name table read. The script is in the session log.
- Audio: `afinfo <file>` and `ffprobe <file>`.
- Video: `ffprobe <file>`.
- Interface Builder: `rea decode-interface-builder /Applications/Arc.app --format json`.

## 1. Colors

### 1.1 Counts and appearance model

Source: every `Assets.car` under `/Applications/Arc.app` (46 catalogs, no ArcCore helper copies).

| Scope | Count | Note | Source |
|---|---|---|---|
| Catalogs | 46 | Resources plus DockTile plug-in | `find` plus `assetutil` |
| Distinct color names | 479 | Across all catalogs | `.re/design/all-colors.txt` |
| Distinct image names | 389 | Section 2 | `.re/design/image-names.txt` |
| Appearances | 2 | Light and Dark only | `assetutil` parse |

The parse finds only two appearance values: no appearance (light) and `NSAppearanceNameDarkAqua` (dark).
One image uses `NSAppearanceNameAqua`. It is `NewLittleBrowserImage` in `ARC_PreferencesFeature`.
No entry uses an increased-contrast appearance.
So Open needs light and dark only. Do not add a high-contrast token set from this build.

Main owners:

- `ARCClients_BaseAssets` holds the core system: 132 color names, 136 image names.
- `ARCUI_ARCUI` holds the gray and indigo scales and button colors: 89 color names.
- The main `Resources/Assets.car` holds window and command bar colors: 18 color names.
- `ARC_SpaceStyleEditor` repeats the 27 space picker colors. See Section 6.

The full list of 479 names with floats stays in `.re/design/all-colors.txt`.
This section prints the tokens an implementer needs first.

### 1.2 Core text, background, and accent

Owner: `ARCClients_BaseAssets` unless the table says else.
Source: `xcrun assetutil --info .../ARCClients_BaseAssets.bundle/Contents/Resources/Assets.car`.

| Token | Light | Dark | Space |
|---|---|---|---|
| BackgroundPrimary | #FFFFFF/1.00 | #000000/1.00 | srgb |
| FullOpacityBackgroundPrimary | #FFFFFF/1.00 | #000000/1.00 | srgb |
| BasePrimary | #000000/1.00 | #FFFFFF/1.00 | srgb |
| BaseSecondary | #000000/0.70 | #FFFFFF/0.70 | srgb |
| BaseTertiary | #000000/0.30 | #FFFFFF/1.00 | srgb |
| BaseQuaternary | #000000/0.15 | #FFFFFF/0.15 | srgb |
| FullOpacityForegroundPrimary | #000000/1.00 | #FFFFFF/1.00 | srgb |
| ForegroundPrimary | #0E0F10/0.90 | #FFFFFF/0.80 | p3 / srgb |
| ForegroundSecondary | #000000/0.50 | #FFFFFF/0.50 | srgb |
| ForegroundTertiary | #000000/0.30 | #FFFFFF/0.30 | srgb |
| BrandBlue | #3139FB/1.00 | same* | p3 |
| FocusRing | #458AFF/1.00 | same* | p3 |
| PopoverBackground | #FAFBFF/1.00 | #151C30/1.00 | p3 |
| Shadow | #000000/0.20 | #000000/0.00 | srgb |

Role read from names (fact: the name; guess: the exact widget):

- `ForegroundPrimary` is the main text token. `Secondary` and `Tertiary` step down by alpha.
- `BasePrimary` is pure black or white. Use it for icons that need full strength.
- `BrandBlue #3139FB` is the brand accent. The same value appears as `Accent`, `CheckboxColor`, and `PrimaryButtonFace` in other modules.
- `FocusRing #458AFF` is the keyboard focus ring (guess from the name).

More brand colors in the same catalog (light only, `p3` unless noted):

- `BrandRed #D74807`, `BrandGreen #107A00`, `BrandYellow #FFD435` (srgb), `BrandGray #7E7E7E`.
- `BrandLightBlue #00C7F3`, `BrandLightGreen #34E895`, `BrandMagenta #C0009F`.
- `BrandExtendedCream #F2EAE4` (srgb), `BrandExtendedLightPink #F29BBB` (srgb), `BrandExtendedOrange #FF8558`.
- `BrandExtendedPurple #A6729D`, `BrandExtendedTeal #6CBAD9`, `BrandExtendedNavy #1C3648`.
- `BrandExtendedBrown #8A5127`, `BrandExtendedBrownPink #C4836A`, `BrandExtendedBlueGray #666789` (srgb), `BrandExtendedVibrantRed #F53714`.

### 1.3 Sidebar and tab rows

Owner: `ARCClients_BaseAssets`. Source: same `assetutil` dump as Section 1.2.
This is the most important table for the sidebar look.

| Token | Light | Dark | Space |
|---|---|---|---|
| SidebarForeground | #000000/0.30 | #FFFFFF/0.45 | srgb |
| SidebarForegroundDarker | #000000/0.45 | #FFFFFF/0.45 | srgb |
| SidebarItemBackground | #0E0F10/0.05 | #FAFBFF/0.10 | p3 |
| SidebarItemHoveredBackground | #0E0F10/0.10 | #FAFBFF/0.15 | p3 |
| SidebarSeparator | #000000/0.15 | #FFFFFF/0.15 | srgb |
| TabCellBackgroundCurrent | #FFFFFF/0.85 | #FAFBFF/0.20 | srgb / p3 |
| TabCellBackgroundContentVisible | #FFFFFF/0.70 | #FAFBFF/0.15 | srgb / p3 |
| TabCellBackgroundPrevious | #FFFFFF/0.32 | #FAFBFF/0.08 | srgb / p3 |
| TabCellBackgroundPreviousHovered | #FFFFFF/0.50 | #FAFBFF/0.12 | srgb / p3 |
| TabCellBackgroundMutiselected | #000000/0.10 | #FAFBFF/0.10 | srgb / p3 |
| TabCellBackgroundPressed | #0E0F10/0.06 | #FAFBFF/0.06 | p3 |
| TabCellChildBackground | #000000/0.07 | #FFFFFF/0.07 | srgb |
| TabCellShadowBackgroundSelected | #FFFFFF/0.90 | #000000/0.00 | srgb |
| TabCellShadowSelected | #000000/0.20 | #000000/0.00 | srgb |
| TabCellSlash | #000000/0.30 | #FFFFFF/0.30 | p3 |

Read of the values (guess from names, the numbers are fact):

- The sidebar has no solid background color token here. The Space gradient shows through. See Section 6.
- A normal tab row uses `SidebarItemBackground` at 5% (light) or 10% (dark).
- Hover raises the fill to 10% (light) or 15% (dark).
- The current tab is a strong white fill in light mode (85%). In dark mode it is a 20% light fill.
- `ContentVisible` (70% light, 15% dark) likely marks the tab whose page is on screen in a split or preview (guess).
- `Previous` and `PreviousHovered` likely mark the prior tab in the back stack (guess).
- Only the selected tab casts a shadow, and only in light mode. Both shadow tokens are transparent in dark mode.

Main window colors. Owner: main `Resources/Assets.car`.
Source: `xcrun assetutil --info /Applications/Arc.app/Contents/Resources/Assets.car`.

| Token | Light | Dark | Space |
|---|---|---|---|
| SidebarBorderColor | #FFFFFF/0.30 | #FFFFFF/0.30 | srgb |
| TabListOverlapBorder | #000000/0.05 | #FFFFFF/0.05 | srgb |
| PreviewBackgroundColor | #FFFFFF/1.00 | #212222/1.00 | srgb |
| EaselBackground | #FFFFFF/0.85 | #000000/0.50 | srgb |
| NotesBackground | #FFFFFF/0.85 | #000000/0.50 | srgb |
| DragHint | #000000/0.20 | #FFFFFF/0.20 | srgb |
| DragHintHighlighted | #000000/0.50 | #FFFFFF/0.50 | srgb |
| NewTabButtonPulsingTextColor | #000000/0.30 | same* | srgb |

Add-space colors. Same owner and source. The `+` button that adds a Space.

| Token | Light | Dark | Space |
|---|---|---|---|
| AddSpacePlusBackgroundColor | #FFFFFF/1.00 | #000000/1.00 | srgb |
| AddSpacePlusIconTintColor | #2702C2/1.00 | #FFFFFF/1.00 | p3 / srgb |
| AddSpacePlusProgressColor | #2702C2/1.00 | #FFFFFF/1.00 | p3 / srgb |
| AddSpacePlusIconActivatedTintColor | #FFFFFF/1.00 | #000000/1.00 | srgb |
| AddSpacePlusIconDeactivatedColor | #000000/0.45 | #FFFFFF/0.45 | srgb |

### 1.4 Command bar

Owner: main `Resources/Assets.car` and `ARC_CommandBar`. Same `assetutil` command.

| Token | Light | Dark | Space |
|---|---|---|---|
| CommandBarIconActiveBackground | #FFFFFF/1.00 | #1A1A1A/1.00 | srgb / p3 |
| CommandBarPlaceholderText | #000000/0.60 | #FFFFFF/0.60 | srgb |
| CommandBarPlaceholderPlaceholderText | #000000/0.30 | #FFFFFF/0.30 | srgb |
| CommandBarPlaceholderIconLockSecure | #000000/1.00 | #FFFFFF/1.00 | p3 |
| CommandBarPlaceholderIconLockInsecure | #F53714/1.00 | #F25E6B/1.00 | p3 |
| CommandBarTextPrimaryColor | #000000/0.80 | #FFFFFF/0.80 | srgb |
| CommandBarTextSecondaryColor | #000000/0.33 | #FFFFFF/0.33 | srgb |
| CommandBarRowHoverBackgroundColor | #000000/0.05 | #FFFFFF/0.05 | srgb |
| CommandBarHairlineDividerColor | #000000/0.10 | #FFFFFF/0.10 | srgb |
| CommandBarAccessoryBackgroundColor | #000000/0.05 | #FFFFFF/0.05 | srgb |
| CommandBarAccessoryForegroundColor | #000000/0.50 | #FFFFFF/0.66 | srgb |
| CommandBarBannerBackground | #FDFDFE/1.00 | #161616/1.00 | srgb |
| SecondaryWindowInputBackground | #FAFBFF/1.00 | #0E0F10/1.00 | p3 |
| SecondaryWindowInputBorder | #0E0F10/0.10 | #FAFBFF/0.20 | p3 |

### 1.5 Gray, alpha gray, and indigo scales

Owner: `ARCUI_ARCUI`. Source: `xcrun assetutil --info .../ARCUI_ARCUI.bundle/Contents/Resources/Assets.car`.
Use `Gray` for solid fills. Use `GrayA` for overlays on the Space gradient.

| Token | Light | Dark | Space |
|---|---|---|---|
| Gray1 | #FCFCFC/1.00 | #161616/1.00 | srgb |
| Gray2 | #F8F8F8/1.00 | #1C1C1C/1.00 | srgb |
| Gray3 | #F3F3F3/1.00 | #232323/1.00 | srgb |
| Gray4 | #EDEDED/1.00 | #282828/1.00 | srgb |
| Gray5 | #E8E8E8/1.00 | #2E2E2E/1.00 | srgb |
| Gray6 | #E2E2E2/1.00 | #343434/1.00 | srgb |
| Gray7 | #DBDBDB/1.00 | #3E3E3E/1.00 | srgb |
| Gray8 | #C7C7C7/1.00 | #505050/1.00 | srgb |
| Gray9 | #8F8F8F/1.00 | #707070/1.00 | srgb |
| Gray10 | #858585/1.00 | #7E7E7E/1.00 | srgb |
| Gray11 | #6F6F6F/1.00 | #A0A0A0/1.00 | srgb |
| Gray12 | #171717/1.00 | #EDEDED/1.00 | srgb |

| Token | Light | Dark | Space |
|---|---|---|---|
| GrayA1 | #000000/0.01 | #000000/1.00 | srgb |
| GrayA2 | #000000/0.03 | #FFFFFF/0.03 | srgb |
| GrayA3 | #000000/0.05 | #FFFFFF/0.06 | srgb |
| GrayA4 | #000000/0.07 | #FFFFFF/0.08 | srgb |
| GrayA5 | #000000/0.09 | #FFFFFF/0.10 | srgb |
| GrayA6 | #000000/0.11 | #FFFFFF/0.13 | srgb |
| GrayA7 | #000000/0.14 | #FFFFFF/0.17 | srgb |
| GrayA8 | #000000/0.22 | #FFFFFF/0.25 | srgb |
| GrayA9 | #000000/0.44 | #FFFFFF/0.39 | srgb |
| GrayA10 | #000000/0.48 | #FFFFFF/0.45 | srgb |
| GrayA11 | #000000/0.56 | #FFFFFF/0.59 | srgb |
| GrayA12 | #000000/0.91 | #FFFFFF/0.92 | srgb |

Note: dark `GrayA1` stores opaque black. Every other dark `GrayA` step uses white.
Treat dark `GrayA1` as a stored placeholder (guess). Test it before use.

| Token | Light | Dark | Space |
|---|---|---|---|
| Indigo1 | #FFFFFF/1.00 | #141421/1.00 | srgb |
| Indigo2 | #F7F8FF/1.00 | #16162E/1.00 | srgb |
| Indigo3 | #F0F0FF/1.00 | #191A40/1.00 | srgb |
| Indigo4 | #E8E9FF/1.00 | #1C1D4F/1.00 | srgb |
| Indigo5 | #D9DAFC/1.00 | #1F215C/1.00 | srgb |
| Indigo6 | #C8CAFA/1.00 | #22246E/1.00 | srgb |
| Indigo7 | #AEB0F5/1.00 | #272A8A/1.00 | srgb |
| Indigo8 | #8E91F0/1.00 | #2E32B2/1.00 | srgb |
| Indigo9 | #3138F9/1.00 | #3239FA/1.00 | srgb |
| Indigo10 | #393ECC/1.00 | #5458E8/1.00 | srgb |
| Indigo11 | #3438B2/1.00 | #8589FF/1.00 | srgb |
| Indigo12 | #101245/1.00 | #EDEEFC/1.00 | srgb |

Gradient tokens in the same catalog (light only):

- `GradientBlue #0047FF/1.00` (p3), `GradientPeach #FF9999/1.00` (p3).
- `Gradient2 #1B46F5/1.00` (srgb), `Gradient1 #F19E9C/0.20` (srgb).

### 1.6 Menus, popovers, and buttons

Owners: `ARC_ArcMenu`, `ARCUI_ARCUI`, `ARCClients_BaseAssets`. Same `assetutil` command.
Values are `#RRGGBB/alpha`, `srgb` unless noted.

Menus (`ARC_ArcMenu`):

- `MenuBackground`: light `#FAFBFF/1.00`, dark `#393841/1.00`.
- `MenuText`: light `#494949/1.00`, dark `#EBEBEC/1.00`. `MenuTextHover`: light `#151515/1.00`, dark `#FFFFFF/1.00`.
- `MenuHoverBackground`: light `#B7D1FF/1.00`, dark `#3970C5/1.00`.
- `MenuSeparator #C4C4C4/1.00` (light only). `MenuDisabledText`: light `#ABABAB/1.00`, dark `#797881/1.00`.
- `MenuSubtitle`: light `#ABABAB/1.00`, dark `#797881/1.00`.

Buttons (`ARCUI_ARCUI`). Primary uses the brand blue:

- `PrimaryButtonFace #3139FB/1.00`, `PrimaryButtonForeground #FFFFFF/1.00` (light only set).
- `PrimaryButtonHovered #2C33E2/1.00`, `PrimaryButtonPressed #2A30D5/1.00`.
- `NeutralButtonFace`: light `#FFFFFF/1.00`, dark `#302F63/1.00`.
- `NeutralButtonHovered`: light `#F2F2F2/1.00`, dark `#454473/1.00`.
- `NeutralButtonPressed`: light `#E5E5E5/1.00`, dark `#2B2A59/1.00`.
- `DestructiveButtonFace #F53714/1.00`, `DestructiveButtonHovered #DD3112/1.00`, `DestructiveButtonPressed #D02F11/1.00` (light only set).

Other modules keep local copies of the same hues. Examples (fact from the dumps):

- `ARC_AdBlocking CheckboxColor`: light `#3139FB/1.00`, dark `#B0B3FF/1.00`.
- `ARC_AskArc AccentColor`: light `#3139FB/1.00`, dark `#5585FF/1.00` (p3).
- `ARC_AuthFeature Accent #3139FB/1.00` (light only).

For the other 400-plus local colors (auth flow, boosts editor, easel, preferences, capture, import), use `.re/design/all-colors.txt`.
Each line there gives the module, appearance, color space, and float components.

### 1.7 Swift token sketch

```swift
// Light / dark pairs from Section 1.3. Alpha is the last number.
static let tabCurrentLight = Color(.sRGB, red: 1.00, green: 1.00, blue: 1.00, opacity: 0.85)
static let tabCurrentDark  = Color(.displayP3, red: 0.98, green: 0.984, blue: 1.00, opacity: 0.20)
static let sidebarItemLight = Color(.displayP3, red: 0.055, green: 0.059, blue: 0.063, opacity: 0.05)
static let sidebarItemDark  = Color(.displayP3, red: 0.98, green: 0.984, blue: 1.00, opacity: 0.10)
static let brandBlue = Color(.displayP3, red: 0.192, green: 0.224, blue: 0.984, opacity: 1.0)
```

Keep the color space per token. Do not convert `p3` tokens to `srgb`. The values shift.

## 2. Images and icons

Source: `xcrun assetutil --info <Assets.car>` for each catalog.
Rendition detail stays in `.re/design/images-clean.txt` (1,042 rows).
The row key is name, module, type, pixel size, scale, template mode, gamut.

### 2.1 Counts

| Kind | Renditions | Meaning | Redraw note |
|---|---|---|---|
| Image (bitmap) | 700 rows | Full-color bitmap | Redraw as bitmap or vector |
| Template image | 225 rows | One-color mask | Draw as template, tint in code |
| Vector (PDF) | 234 rows | Vector PDF in catalog | Redraw as vector |
| PackedImage | Rest | Packed sheet parts | Ignore; system packing |

Counts mix rows and names. Use names for the work list:

- 389 distinct image names need review. Many are favicons for known sites. See Section 2.3.
- Template mode `automatic` means the catalog does not force a tint. Code sets the tint.
- Template mode `template` (225 renditions) means the image is a mask. The fill color comes from code.
- A name with a `Vector` rendition scales without loss. A name with only `Image` renditions needs `@1x` and `@2x`.

Per-module image names (distinct names, colors in parentheses):

- `ARCClients_BaseAssets`: 136 images (132 colors). The main icon set.
- `ARC_EaselUI`: 56 images (18 colors). Easel tools and avatars.
- `ARCUI_ARCUI`: 31 images (89 colors). Logos, orbs, and blobs.
- Main `Assets.car`: 29 images (18 colors). App icon and window art.
- `ARC_ContextMenus`: 21 images (0 colors). Context menu icons.
- `ARC_MembershipCard`: 16 images. Card art. `ARC_AuthFeature`: 15 images.
- All other bundles hold 1 to 13 image names each. Full counts stay in `.re/design/assetutil-summary.txt`.

### 2.2 Key sizes (fact from `assetutil`)

| Asset | Size @1x | Scales | Mode |
|---|---|---|---|
| AppIcon (main) | 16 to 512 pt | @1x, @2x to 1024 px | Full color |
| Grain texture `grain` | 155x155 px | @1x, @2x | Full color |
| `denim` / `sand` / `tweed` | 300 / 96 / 128 px | @1x, @2x | Full color |
| Metal grain `*_metal` | 100x100 px class | @1x, @2x | Full color |
| Theme knobs (editor) | 56x56 px | @1x, @2x (112 px) | Full color |
| DotGrid (editor) | 400x401 px | @1x, @2x | Template |
| LinearIconTemplate | 24x24 px | @1x, @2x | Template |
| OpenAIIconTemplate | 320x320 px | @1x, @2x | Template |
| Prefs icons | 24x24 px | @1x, @2x | Template |
| App tray badges | 32x32 px class | @1x, @2x | Full color |

Point size equals pixel size divided by scale. Example: `DenimKnob` is 56 px at @1x and 112 px at @2x, so 56 pt.

### 2.3 Full name list (389 names)

Grouped by role. The grouping is a guess from the name. The names are fact.
Redraw each name. `ZZZZPackedAsset-*` names are system packing. Skip them.

App and brand (redraw first):

`AppIcon`, `AppIconBorderless`, `AppIconBorderlessSmall`, `AppLogo`, `ArcLogoOutline`, `ArcUpdatesArcLogo`, `WelcomeLogo`, `BrowserCompany`, `logoIcon`, `icon-arc`, `arcOutlineIcon`, `LoadingArcLogoBlur`, `LogoWithBackdrop`, `GradientBackdrop`, `OneBoxGradient`, `ArcCaptureWatermark`, `window-screenshot-icon`, `window-screenshot-watermark-on`, `window-screenshot-watermark-off`.

Alternate app icons (user picks one in settings; each has a `*Preview` at 64 px and a full icon to 1024 px):

`AppIconCanary`, `AppIconCandy`, `AppIconColorful`, `AppIconDev`, `AppIconEarlyBirds`, `AppIconFilled`, `AppIconFlutedGlass`, `AppIconHologram`, `AppIconNeon`, `AppIconOriginal`, `AppIconSchoolbook`, `DiaAppIcon`, `DiaAppIconBeta`, `DiaAppIconCanary`, `DiaAppIconDev`, `DiaAppIconPro`, `DiaAppIconPrototype`. Previews: add `Preview` to the base name. `AppIconPreviewDisabled` is the disabled state.

Sidebar, split, and window chrome:

`add-space`, `add-tab`, `tab`, `space`, `folder`, `ArchiveIcon`, `BoostIcon`, `BoostLarge`, `boost`, `boost_legacy`, `ExtensionsIcon`, `LibraryIcon`, `library-icon`, `SidebarMobileIcon`, `SidebarMobileIconFill`, `SettingsIcon`, `ShareIcon`, `ShareIconChecked`, `ShareIconUnchecked`, `GoBack`, `GoForward`, `SmallCloseButton`, `GutterButton`, `Movable`, `Movable-Fill`, `Moving`, `Moving-Fill`, `Interactable-Down`, `Interactable-Down-Fill`, `Interactable-Hover`, `Interactable-Hover-Fill`, `ResizeNESW`, `ResizeNWSE`, `Arrow`, `Circle`, `Circle-Fill`, `CircleCutout`, `CircleCutoutRounded`, `CellDropShadow`, `Lines`, `Shape`, `Shape-Fill`, `Shape1`, `Shape2`, `Shape3`, `Shape4`, `triangle`, `circle`, `box`, `star`, `giftIcon`, `Spark`, `squiggle-mask`, `squiggle-thin`, `SquigglyFooter`, `stamp`, `signature`, `note`, `easel`, `share`, `copy-url`, `cmd-t`, `heart-ripple`, `glow`, `glow-video`.

Split view set (`icon-split-*` and `split-*`):

`icon-split-add-bottom`, `icon-split-add-left`, `icon-split-add-right`, `icon-split-add-top`, `icon-split-close`, `icon-split-horizontal`, `icon-split-vertical`, `icon-split-move-bottom`, `icon-split-move-left`, `icon-split-move-right`, `icon-split-move-top`, `icon-split-puzzle`, `icon-split-share-horizontal`, `icon-split-share-vertical`, `icon-split-x`, `icon-separate-from-split`, `icon-separate-from-split-menu-bottom`, `icon-separate-from-split-opaque`, `split-add-bottom`, `split-add-right`, `icon-window-control-puzzle`.

Navigation and dialog icons:

`icon-browser-navigation-clear-cookies`, `icon-browser-navigation-force-reload`, `icon-browser-navigation-reload`, `icon-browser-navigation-sidebar`, `icon-control-center`, `icon-control-center-fill`, `icon-dialog-easel`, `icon-dialog-note`, `icon-dialog-share`, `icon-archie`, `icon-archie-add`, `icon-archie-delete`, `icon-archie-move`, `icon-archie-question`, `icon-archie-space`, `archie`, `Archie`, `ArchieDialogIcon`, `EarlyBirdsDialogIcon`.

Easel tools:

`EaselIconArrow`, `EaselIconEllipse`, `EaselIconFreehand`, `EaselIconImage`, `EaselIconLine`, `EaselIconPointer`, `EaselIconRectangle`, `EaselIconShapes`, `EaselIconText`, `EaselIconTriangle`, `EaselFavicon`, `EaselLoadingStateSquiggle`, `EaselPreviewThumbnail`, `Cursor`, `Cursor-Fill`, `cursor`, `camera-cursor`, `camera-cross-cursor`, `capture-full-page`, `broom-stick`, `PaintBucketIcon`, `Pencil`, `Pencil-Fill`, `Pencil-Down`, `Pencil-Down-Fill`, `Text`, `OrderedList`, `UnorderedList`, `FontIcon`.

Boosts editor:

`AnalogousColorScheme`, `ComplementaryColorScheme`, `HueRing`, `FontSizeBody`, `FontSizeH1`, `FontSizeH2`, `FontSizeIcon`, `FontStyleFancy`, `FontStyleHip`, `FontStyleMono`, `FontStyleSystem`.

Theme editor and membership:

`DenimKnob`, `GrainKnob`, `SandKnob`, `TweedKnob`, `DotGrid`, `denim`, `denim_metal`, `grain`, `grain_metal`, `sand`, `sand_metal`, `tweed`, `tweed_metal`, `grain-1`, `grain-2`, `grain-3`, `grain-4`, `grain-no-blend`, `AnimatingCardBlob`, `animatingOrbBlob1`, `animatingOrbBlob2`, `MaxBanner`, `MaxFlower`, `MaxFlowerBackground`, `MaxFlowerCenter`, `MaxFlowerIcon`, `maxFeatureBannerIcon`, `fallback-gradient-1` to `fallback-gradient-8`, `gradient`.

People and onboarding (photos and illustrations; replace with own art):

`Adena`, `Alexandra`, `Hursh`, `Josh`, `Kristina`, `Molly`, `Nate`, `Samir`, `bliss`, `archibald+arcenio`, `ContentIntro1`, `ContentIntro2`, `AskOnPagePreview`, `ChatGPTSiteSearchPreview`, `HoverCardPreview`, `IncognitoTabPreviewThumbnail`, `InstantLinksPreview`, `NotePreviewThumbnail`, `SharedObjectPreviewThumbnail`, `TidyTabsPreview`, `RenameTabTitlesPreview`, `DownloadRenamePreview`, `InterstitialIcon`, `SadTab`, `SharedObject`, `SharedObjectIcon`, `smiley`, `newArcIconUnlockedIcon`, `onboarding-empty-state-arrow`, `LittleArcHeroImage`, `NewLittleBrowserImage`, `LinksPrefPaneIcon`, `PrefsGeneral`, `MoonDark`, `MoonLight`, `SunDark`, `SunLight`, `meet-pip-chat-selected`, `meet-pip-chat-unselected`, `password-import-prompt-icon`, `windowsBuddyDayIcon`, `SafariKeychainImportMonterey`, `SafariKeychainImportVentura`, `SystemPreferencesMonterey`, `SystemPreferencesVentura`, `Image`, `DocumentFaviconLeft`, `DocumentFaviconRight`, `FolderEllipsesDark`, `FolderEllipsesLight`.

Site favicons and app tray icons (third-party logos; ship generic art or fetch at run time):

`AmplitudeIcon`, `ArtBlocksFavicon`, `AsanaIcon`, `AshbyIcon`, `AtlassianIcon`, `BitbucketFavicon`, `Brave`, `CanvaIcon`, `ChromeLogo`, `ConfluenceIcon`, `DropboxIcon`, `Edge`, `FigmaIcon`, `figma`, `FirefoxLogo`, `GCalFavicon`, `GettingStartedFavicon`, `GithubFavicon`, `GmailAppTrayIcon`, `gmail`, `gmailIcon`, `Google`, `GoogleCalendarLight`, `GoogleDocsFavicon`, `GoogleDriveFavicon`, `GoogleFavicon`, `GoogleFormsFavicon`, `GoogleMeetIcon`, `GoogleSlidesFavicon`, `GranolaIcon`, `gsheets`, `gcal`, `HackernewsFavicon`, `ImportFavicon`, `JiraDark`, `JiraIcon`, `JiraLight`, `LinearFavicon`, `LinearIcon`, `LinkedinFavicon`, `LoomIcon`, `MusicSprite1`, `MusicSprite2`, `NotionArcResourcesFavicon`, `NotionFavicon`, `NotionIcon`, `notion`, `Opera`, `OperaGX`, `OutlookIcon`, `outlook`, `ResourcesFavicon`, `RetoolIcon`, `SafariLogo`, `SalesforceIcon`, `SharePointIcon`, `ShopifyIcon`, `SlackLight`, `slack`, `SpotifyAppTrayIcon`, `SpotifyFavicon`, `SpotifyFaviconLight`, `spotify`, `StripeIcon`, `SubstackFavicon`, `teams`, `TrelloIcon`, `TwitterAppTrayIcon`, `TwitterFavicon`, `twitter`, `Vivaldi`, `WeatherDotComFavicon`, `WelcomeToArcFavicon`, `WhatsAppAppTrayIcon`, `WhatsAppFaviconLight`, `WikipediaFavicon`, `WordleAppTrayIcon`, `WorkdayIcon`, `youtube`, `YouTubeAppTrayIcon`, `YouTubeFavicon`, `ZendeskIcon`, `ZoomFavicon`, `ZoomIcon`, `linear`, `googleChat`, `Arc Mail`, `ArcASettings`, `ArcFavicon`, `ArcResourcesFavicon`, `ArcShortcutsFavicon`, `ArcTemplateIcon`, `EmptyFavicon`, `FaviconBackground`.

Custom glyphs that look like SF names but are Arc assets (fact: they live in `Assets.car`):

`boost.fill`, `boost.sparkle`, `boost.sparkle.fill`. Do not map them to SF Symbols.

### 2.4 SF Symbols

Source: `strings -a .re/bin/Arc-arm64`. The filter keeps names with SF form.
The full candidate file is `.re/design/sf-symbols-filtered.txt` (91 lines).
Single-word symbols also appear as plain strings. The list below merges both.
Feature use is a guess from the name unless noted.

Arrows and navigation:

`arrow.backward.to.line`, `arrow.counterclockwise`, `arrow.clockwise` (string present), `arrow.down.and.line.horizontal.and.arrow.up`, `arrow.up.and.line.horizontal.and.arrow.down`, `arrow.down.circle`, `arrow.down.circle.fill`, `arrow.down.doc.fill`, `arrow.left.arrow.right`, `arrow.turn.down.right`, `arrow.turn.right.down`, `arrow.up.forward`, `arrow.up.left.and.arrow.down.right`, `arrow.uturn.backward`, `arrow.uturn.forward`, `arrow.uturn.left`, `arrowtriangle.down.fill`, `backward.end.fill`, `forward.end.fill`, `chevron.backward`, `chevron.down.circle.fill`.

Controls and status:

`checkmark.circle`, `checkmark.circle.fill`, `checkmark.icloud.fill`, `checkmark.shield.fill`, `xmark` (plain string), `xmark.circle.fill`, `xmark.octagon.fill`, `plus` (plain string), `minus` (plain string), `plus.square.on.square`, `minus.circle.fill`, `multiply.circle.fill`, `exclamationmark.triangle` (plain string), `exclamationmark.circle.fill`, `exclamationmark.triangle.fill`, `exclamationmark.arrow.circlepath`, `exclamationmark.arrow.triangle.2.circlepath`, `info.circle.fill`, `questionmark.circle`, `lock.shield.fill`.

Content and tools:

`folder.badge.plus`, `person.badge.plus`, `person.crop.square.filled.and.at.rectangle`, `doc.on.clipboard`, `list.clipboard.fill`, `rectangle.and.pencil.and.ellipsis`, `rectangle.inset.filled.and.person.filled`, `rectangle.portrait.on.rectangle.portrait.angled`, `rectangle.split.2x1`, `rectangle.topthird.inset.filled`, `square.split.1x2`, `square.split.2x1`, `square.and.arrow.down`, `square.and.arrow.down.fill`, `square.and.arrow.up`, `square.badge.plus`, `square.on.square.dashed`, `pencil.and.outline`, `paintbrush.pointed.fill`, `paintpalette.fill`, `puzzlepiece.extension.fill`, `wrench.and.screwdriver.fill`, `text.bubble.fill`, `quote.bubble.fill`, `character.bubble.fill`, `photo.on.rectangle`, `photo.on.rectangle.angled`, `play.circle.fill`, `play.rectangle`, `speaker.wave.1.fill`, `speaker.wave.2.fill`, `speaker.wave.3.fill`, `speaker.slash.fill`, `video.slash.fill`, `hand.thumbsup.fill`, `hand.thumbsdown.fill`, `heart.circle.fill`, `star.circle.fill`, `bolt.circle.fill`, `bubbles.and.sparkles.fill`, `command.circle.fill`, `ellipsis.rectangle`, `line.3.horizontal.decrease.circle`, `externaldrive.fill`, `shippingbox.fill`.

Plain single-word strings that match SF base names (presence is fact; SF use is a guess):

`star`, `folder`, `globe`, `lock`, `heart`, `bookmark`, `ellipsis`, `link`, `calendar`, `clock`, `photo`, `moon`, `cloud`, `bolt`, `wifi`, `pencil`, `flag`, `location`, `book`, `printer`, `message`, `phone`, `video`, `gift`, `keyboard`, `display`, `network`, `grid`, `leaf`, `snowflake`.

Notes:

- No `sidebar.left` string exists in the main binary. The sidebar toggle likely uses a custom asset or a drawn control (guess). Check at run time.
- `boost.fill` and `boost.sparkle.fill` in this binary match the custom assets in Section 2.3. Treat them as Arc art first.
- `SFSymbolEmojiLookupTable.json` in `ARCFoundation_ARCFoundationBase` maps SF names to emoji. It does not prove UI use. Ignore it for the icon list.
- Icon fonts exist as a second icon path. See Section 3.3.

### Named Space icons

Evidence: `strings -a .re/bin/Arc-arm64`, the contiguous `CustomIcon`
raw-value names between `AllCases`, `emoji`, `icon`, `symbol` and `emojiInt`
(the same group includes `planet`, `colorPallete`, and `fileTrayFull`). The
sidebar schema stores these under `customInfo.iconType.icon`; see
[data-model.md](data-model.md#26-spaces). These are identifiers, not SF Symbol names.

Open preserves them as `SpaceIcon.named`. The complete recreated mapping table
is [NamedSpaceIcons.swift](../../Packages/OpenKit/Sources/OpenModel/NamedSpaceIcons.swift).
The map uses SF Symbols; brand and unmatched pictograms use generic equivalents.
Unknown identifiers retain their value, draw `circle.dotted`, and increment the
import report's unknown count. `sidebar-render check` calls
`NSImage(systemSymbolName:accessibilityDescription:)` for every mapped symbol
and the neutral fallback on macOS 26.

Live sidebar counts on 2026-10-25: `planet=1`, unknown named icons `0`.
Evidence: `openkit import-arc --arc-dir <temporary JSON copy> --out <temporary root>`,
`namedSpaceIcon planet count=1`. No Space titles, URLs, or profile data are included here.

## 3. Fonts

### 3.1 Where the fonts live

Fact: `Info.plist` sets `ATSApplicationFontsPath` to `Fonts`.
Command: `plutil -p /Applications/Arc.app/Contents/Info.plist`.
Fact: no `Resources/Fonts` folder exists. Command: `ls /Applications/Arc.app/Contents/Resources/Fonts` fails.
The fonts live in `ARCClients_FontsManager.bundle/Contents/Resources/` (83 font files).
Code loads them at run time. Strings name `FontsManager/Fonts.swift` and `FontsManager/FontManagerClient.swift`.
Open must bundle its own fonts or use system fonts. Do not copy these files. Several are paid test fonts (names end in `Test`).

### 3.2 Font files (family, file, weight class)

Source: `fontTools` name table. Weight class is the `OS/2` value. `1000` units per em unless noted.
Use the family name in code. The file name is the evidence.

| Family | Files (weight) | Use hint |
|---|---|---|
| ABC Favorit | Regular 400, Bold 700, Regular Italic 400 | UI text (guess) |
| ABC Favorit Lining | Medium 500, Bold 700 | Lining figures (guess) |
| ABC Favorit Mono | Regular 400, Medium 500, Bold 700, plus italics | Mono UI (guess) |
| ABC Oracle Book | Book 350 | Reading text (guess) |
| EB Garamond | Variable Regular 400, Variable Italic 400 | Notes / Easel serif (guess) |
| GT Ultra VF | Variable 250; GT Ultra Ultra VF 1000 | Display (guess) |
| Inconsolata | Light 300, Regular 400, Medium 500, Bold 700 | Code / mono option |
| Inter | Regular 400, Medium 500, SemiBold 600, Bold 700; 2816 upm | UI fallback (guess) |
| Marlin Soft / Marlin Soft SQ | Medium 500 to Black 900, SQ to ExtraBold 800 | Brand display (guess) |
| National 2 Test | Light 350, Regular 400, Bold 700 | Test font; replace |
| Nunito | ExtraLight 200 to Black 900, plus italics | Rounded UI (guess) |
| Pitch / Pitch Sans | Light 300 to Semibold / Bold 700 | Easel / editor options |
| Sohne Test / Sohne Breit | Leicht 300 to Extrafett 900 | Test font; replace |
| Space Mono | Regular 400, Bold 700, plus italics | Mono option |

Full file list (83 files). Source: `.re/design/font-families.txt`.

- ABC: `ABCFavorit-Bold.otf`, `ABCFavorit-Regular.otf`, `ABCFavorit-RegularItalic.otf`, `ABCFavoritLining-Bold.otf`, `ABCFavoritLining-Medium.otf`, `ABCFavoritMono-Bold.otf`, `ABCFavoritMono-BoldItalic.otf`, `ABCFavoritMono-Medium.otf`, `ABCFavoritMono-MediumItalic.otf`, `ABCFavoritMono-Regular.otf`, `ABCFavoritMono-RegularItalic.otf`, `ABCOracle-Book.otf`.
- Serif and display: `EBGaramond-VariableFont_wght.ttf`, `EBGaramond-Italic-VariableFont_wght.ttf`, `GT-Ultra-VF.ttf`, `GT-Ultra-Ultra-VF.ttf`, `MarlinBold.otf`, `MarlinSoft-Medium.otf`, `MarlinSoftSQ-Black.otf`, `MarlinSoftSQ-Bold.otf`, `MarlinSoftSQ-BoldItalic.otf`, `MarlinSoftSQ-ExtraBold.otf`, `MarlinSoftSQ-ExtraBoldItalic.otf`, `MarlinSoftSQ-Medium.otf`, `MarlinSoftSQ-Regular.otf`.
- Sans: `Inter-Bold.ttf`, `Inter-Medium.ttf`, `Inter-Regular.ttf`, `Inter-SemiBold.ttf`, `Nunito-*.ttf` (14 files, ExtraLight to Black with italics), `National2Test-Bold.otf`, `National2Test-Light.otf`, `National2Test-Regular.otf`, `SoehneTest-Buch.otf`, `SoehneTest-Halbfett.otf`, `SoehneTest-Leicht.otf`, `SohneBreit-*.ttf` (6 files, Buch to Extrafett with Kursiv).
- Mono and editor: `Inconsolata-Bold.ttf`, `Inconsolata-Light.ttf`, `Inconsolata-Medium.ttf`, `Inconsolata-Regular.ttf`, `SpaceMono-Bold.ttf`, `SpaceMono-BoldItalic.ttf`, `SpaceMono-Italic.ttf`, `SpaceMono-Regular.ttf`, `PitchApp-*.ttf` (10 files), `PitchSansApp-*.ttf` (10 files).

String evidence (fact): the binary stores every PostScript name, for example `ABCFavorit-Regular`, `EBGaramond-Regular`, `MarlinSoftSQ-Bold`, `National2-BoldTest`.
It also stores `Helvetica Neue` and web stacks (`system-ui`, `-apple-system`). Those serve web content, not the chrome (guess).

### 3.3 Icon fonts

Source: `fontTools` glyph count.

| Font | File | Glyphs | Note |
|---|---|---|---|
| icomoon | `ARCClients_Icons.bundle/.../icomoon.ttf` | 286 | Custom icon font (guess) |
| ionicons | `ARCClients_Icons.bundle/.../ionicons.ttf` | 1181 | Ionicons set (guess) |

Strings name `Icons/Fonts.swift`, `IconFontIcon`, and `IconFontImageCache`.
Open should prefer SF Symbols plus drawn assets. Do not ship these font files.

### 3.4 What size and weight each UI uses

Static data does not give the map. Strings prove only the mechanism:

- `systemFontOfSize:`, `systemFontOfSize:weight:`, `monospacedSystemFontOfSize:weight:`, `boldSystemFontOfSize:`, `preferredFontForTextStyle:options:` (fact from `strings`).
- Types: `FontManagerClient.setFont`, `EaselFontFamily`, `BoostFont`, `TextEditorFontConstants`, `FontSizeBody`, `FontSizeH1`, `FontSizeH2` (fact from `strings`).

So the sidebar, tab row, and command bar font sizes need a run-time read or a decompiled read. See Section 9.
Best static guess: the chrome uses a Favorit or system font near 12 to 13 pt. Mark this as a guess. Do not ship it as a token.

## 4. Motion

### 4.1 Lottie animations (fact)

Source: JSON header in each file (`v`, `fr`, `ip`, `op`, `w`, `h`, `nm`).
Duration equals `(op - ip) / fr`. All files use Lottie `5.9.4`.
Purpose is a guess from the bundle and the file name.

| File (bundle) | Canvas, rate | Duration | Purpose (guess) |
|---|---|---|---|
| `logo-wave.json` (ARCUI) | 225x225, 60 fps | 3.00 s | Logo wave, splash |
| `archive.json` (HomeButton) | 128x128, 60 fps | 2.00 s | Archive hover |
| `boosts.json` (HomeButton) | 128x128, 60 fps | 1.00 s | Boosts hover |
| `downloads.json` (HomeButton) | 128x128, 60 fps | 1.00 s | Downloads hover |
| `easels.json` (HomeButton) | 128x128, 60 fps | 1.00 s | Easels hover |
| `screenshots.json` (HomeButton) | 128x128, 60 fps | 1.00 s | Capture hover |
| `spaces.json` (HomeButton) | 128x128, 60 fps | 1.00 s | Spaces hover |
| `smiley.json` (Preferences) | 100x100, 30 fps | 5.00 s | Preferences smiley |
| `update-heart-animation.json` (SidebarBanner) | 350x350, 60 fps | 2.00 s | Update banner heart |
| `automatic.json` (SpaceStyleEditor) | 500x500, 60 fps | 1.50 s | Auto theme icon |
| `moon.json` (SpaceStyleEditor) | 500x500, 60 fps | 1.50 s | Dark theme icon |
| `sun.json` (SpaceStyleEditor) | 500x500, 60 fps | 1.00 s | Light theme icon |

Redraw these as code animation or new Lottie files. Do not copy the JSON.

### 4.2 Video loops (fact)

Source: `ffprobe` on each file.

| File (bundle) | Size, codec | Duration | Purpose (guess) |
|---|---|---|---|
| `background.mp4` (ARCUI) | 100x100, H.264 | 8.00 s | Gradient loop |
| `orb.mp4` (ARCUI) | 100x100, H.264 | 6.00 s | Orb loop |
| `demo.mov` (AuthFeature) | 1920x1280, HEVC | 18.27 s | Onboarding demo |
| `static-bg.png` (AuthFeature) | 2880x1800, PNG | Still | Onboarding back |
| `intro-music.mp3` (AuthFeature) | Stereo, MP3 | 21.34 s | Onboarding music |

The app links `Lottie.framework`. Source: `ls /Applications/Arc.app/Contents/Frameworks/`.

### 4.3 Springs, curves, and durations in code

Strings prove these SwiftUI values exist (fact):

- `Animation.spring()`, `Animation.interactiveSpring()`, `Animation.easeIn`, `Animation.easeOut`, `Animation.easeInOut`, `Animation.linear`.
- Types and storage: `ContentPanelSpringManager`, `$__lazy_storage_$_presentationSpring`, `$__lazy_storage_$_scaleSpringAnimation`, `CAMediaTimingFunction`.

Strings do not store the numbers. `spring()` in strings has no `response`, `dampingFraction`, `stiffness`, or `damping` value.
The numbers live in compiled code. They need a decompiled read of the saved Ghidra project or a run-time trace.
Do not guess spring numbers for the token file. List them as open items in Section 9.

Web CSS in strings shows `--rounded-lg: 12px`, `--rounded-md: 6px`, `--rounded-sm: 4px`.
That CSS serves web views (fact: the string). Do not use it as the chrome radius.

## 5. Sounds

Source: `ls` on `ARC_SoundEffects.bundle`, then `afinfo` per file.
Code path (fact from `strings`): `SoundEffects/Sounds.swift`, `SoundEffectClient.play`, `SoundEffectClient.preload`, `SoundEffectClient.isEnabled`.
Types use `NSSound` and `AVAudioPlayer`.

| File (bundle) | Format | Duration | Event (guess) |
|---|---|---|---|
| `capture.wav` (SoundEffects) | WAV, stereo 48 kHz, 24-bit | 0.63 s | Capture shutter |
| `event.m4a` (SoundEffects) | AAC, stereo 44.1 kHz | 3.52 s | Notice chime |
| `intro-music.mp3` (AuthFeature) | MP3, stereo 48 kHz, 320 kbps | 21.34 s | Onboarding music |

The event map is a guess. `capture` fits the Capture feature name. No string links a file name to an event.
The exact trigger for `event.m4a` needs a decompiled read of `Sounds.swift` call sites.
Open must record its own sounds. Do not copy these files.
Add a mute switch. `SoundEffectClient.isEnabled` proves Arc has one (fact).

## 6. Space theming

Sources: `assetutil` on `ARCClients_BaseAssets`, `ARC_SpaceStyleEditor`, and `ARC_WindowThemeUI`.
Strings give the editor and render types. The Metal file gives the shader entry points.

### 6.1 How a Space theme works (fact, with reads marked)

- A Space theme is a gradient plus a noise overlay. The sidebar shows the gradient. The web view stays solid.
- Code types (fact from `strings`): `WindowTheme`, `BlendedGradientConfiguration`, `GradientLayer`, `AnimatedGradientView`, `AnimatedGrainView`, `GrainView`.
- Editor types (fact): `SpaceStyleColorPadView`, `SpaceStyleDialView`, `SpaceStyleEditorState`, `SpaceStyleEditorColorSet`.
- Editor actions (fact): `didTapNoiseKnob`, `didUpdateNoiseFactor`, `noiseFactor`, `Cycle noise texture`.
- Render path (fact): `ARC_WindowThemeUI` holds `default.metallib` (32 KB). Entry points are `gradientVertex` / `gradientFragment`, `overlayVertex` / `overlayFragment`, `renderVertex` / `renderFragment`.
- Metal inputs (fact from `strings` on the metallib): `GradientRenderConfiguration` with `colors`, `gradients`, `layerCount`; `OverlayRenderConfiguration` with `fromOverlay`, `toOverlay`, `progress`; textures `gradientTexture` and `overlayTexture`; `overlayRepetitions`.
- CSS output (fact): `--arc-background-gradient-color` and `--arc-background-gradient-overlay-color`. Web pages can read the theme.
- Error string (fact): `BlendedGradientConfiguration has no colors.` A theme needs at least one color.

Read (guess from the names): the pad sets hue. The dial sets the second stop or the angle. `noiseFactor` sets grain strength. The overlay cross-fades on theme change (`progress`).

### 6.2 Preset palettes (fact, light only, opaque)

Owner: `ARCClients_BaseAssets`. The editor bundle repeats the Drab, Greyscale, and Pastel sets.
All values are single-stop picks. The gradient pairs two picks in code (guess).

Brand set (`p3` unless noted):

| Token | Value | Token | Value |
|---|---|---|---|
| ColorPickerBrand1 | #F2EAE4/1.00 srgb | ColorPickerBrand6 | #F2D66D/1.00 |
| ColorPickerBrand2 | #F29BBB/1.00 srgb | ColorPickerBrand7 | #73E59C/1.00 |
| ColorPickerBrand3 | #A6729D/1.00 srgb | ColorPickerBrand8 | #7EB8D6/1.00 |
| ColorPickerBrand4 | #F25E6B/1.00 srgb | ColorPickerBrand9 | #666786/1.00 |
| ColorPickerBrand5 | #FF3C19/1.00 ext. linear | — | — |

Correction (2026-10-25): the `#FF3C19` value of `ColorPickerBrand5` is in linear light. Encoded as sRGB it is `#FF8558`. Evidence: the editor swatch for Brand5 measures `#FF8558` in F0137 (sRGB-converted capture), and Space 1 stores `baseColors[0]` = `#FF8558` (`runtime-observations.md` §3.3). Use `#FF8558` (sRGB) as the token value.

Drab set (`p3`):

| Token | Value | Token | Value |
|---|---|---|---|
| ColorPickerDrab1 | #4B3B58/1.00 | ColorPickerDrab6 | #CDCCA8/1.00 |
| ColorPickerDrab2 | #623856/1.00 | ColorPickerDrab7 | #84A885/1.00 |
| ColorPickerDrab3 | #854444/1.00 | ColorPickerDrab8 | #34604B/1.00 |
| ColorPickerDrab4 | #A77048/1.00 | ColorPickerDrab9 | #2D4468/1.00 |
| ColorPickerDrab5 | #D1B46A/1.00 | — | — |

Pastel set (`p3`):

| Token | Value | Token | Value |
|---|---|---|---|
| ColorPickerPastel1 | #FDFBFA/1.00 | ColorPickerPastel6 | #FEF9E7/1.00 |
| ColorPickerPastel2 | #FBEAF3/1.00 | ColorPickerPastel7 | #E4FCEC/1.00 |
| ColorPickerPastel3 | #ECD2EA/1.00 | ColorPickerPastel8 | #E0F2FB/1.00 |
| ColorPickerPastel4 | #F7CDD2/1.00 | ColorPickerPastel9 | #C5C6E2/1.00 |
| ColorPickerPastel5 | #FAE1D5/1.00 | — | — |

Greyscale set (`p3`): step 1 `#FFFFFF`, 2 `#E5E5E5`, 3 `#CCCCCC`, 4 `#B2B2B2`, 5 `#808080`, 6 `#666666`, 7 `#333333`, 8 `#1A1A1A`, 9 `#000000`. All alpha `1.00`.
Names are `ColorPickerGreyscale1` to `ColorPickerGreyscale9`.

Easel color sets in the same catalog (fact; full floats in `.re/design/all-colors.txt`):

- `Chill.Easel*` (muted) and `Vibrant.Easel*` (bright) each give Black, White, Grey, Red, DarkBlue, LightBlue, DarkGreen, LightGreen, Pink, Purple, Yellow.
- Chill dark blue is `#3139FB`-class blue. Vibrant red is `#F53714`-class red. Use Chill for the default Easel palette (guess).

### 6.3 Grain and noise textures (fact)

Owner: `ARC_WindowThemeUI` for the fill textures. Owner: `ARC_SpaceStyleEditor` for the knob art.
Draw new seamless tiles at these sizes. Do not copy the tiles.

| Texture | Tile @1x | Tile @2x | Editor knob |
|---|---|---|---|
| `grain` | 155x155 px | 310x310 px | `GrainKnob` 56 pt |
| `sand` | 96x96 px | 192x192 px | `SandKnob` 56 pt |
| `denim` | 300x300 px | 600x600 px | `DenimKnob` 56 pt |
| `tweed` | 128x128 px | 256x256 px | `TweedKnob` 56 pt |
| `*_metal` set | 100x100 px | 200x200 px | Metal shader input |

Note: `grain_metal` stores 200x200 px at @1x and 100x100 px at @2x. The other metal tiles store 100 px at @1x and 200 px at @2x. Treat the grain pair as swapped renditions (guess). Draw one 200 px master and scale it.

Four grain styles exist: grain, sand, denim, tweed. `Cycle noise texture` steps through them (fact: the string).
`ARCUI` also holds `grain-1` to `grain-4` and `grain-no-blend` images. Count and role need a look at run time (guess: blend variants).
The editor shows a `DotGrid` (400x401 px, template) behind the pad (guess from the name and mode).

### 6.4 Light, dark, and text contrast

Fact: the 36 picker colors store no dark variant. The same pick serves both modes.
Fact: sidebar text tokens flip by alpha, not by hue (Section 1.3). On a light Space, text is black at 30 to 90%. On a dark Space, text is white at 30 to 90%.
Strings name `sidebar-dark-mode-bias` (fact). The theme likely biases text toward the Space lightness (guess).
No numeric contrast rule, threshold, or luminance formula appears in strings or catalogs.
The exact rule (when the sidebar flips from dark text to light text) needs run-time tests with light, mid, and dark Spaces. See Section 9.
Safe start for Open (guess, test it): compute the gradient mean luminance. Use dark text above 0.5 and light text below 0.5. Tune on device.

Fallback art (fact): `fallback-gradient-1` to `fallback-gradient-8` images exist in the catalogs. Use them when a Space has no custom theme (guess).

Update 2026-10-25: §6.5 replaces the "safe start" guess above with the decoded rule.

### 6.5 Theme math (decoded 2026-10-25)

Sources: the arm64 slice `.re/bin/Arc-arm64`, read with `llvm-objdump -d` at the addresses below, plus a read-only Ghidra run on the shared project (`-readOnly -noanalysis`). Swift type and field names come from the `__swift5_types` / `__swift5_fieldmd` reflection records (our own parser, output in `.re/theme/fields.txt`). Every formula below was checked against the 4 stored themes in a read-only copy of `StorableSidebar.json` (session1) with a small Python model (`.re/theme/tools/model.py`, `model_p3.py`). The values are facts unless marked.

**Color space.** All theme color math runs in Display P3. Components are clamped to 0…1 in P3 before the math. Results are stored as extended sRGB, which is why stored values contain negative components. Evidence: the HSL helper (`0x1009a5a3c`) converts with `colorUsingColorSpace:` before it reads components. The P3 model reproduces all 16 stored primary-palette values (4 Spaces × 4 roles) with 0/255 error; the same model in sRGB leaves errors up to 15/255.

**HSL.** Standard RGB↔HSL (`0x1009a5a3c` reads, `0x1009a7d88` writes; constants 1/3, 1/6, 2/3, 6). Lighten and darken (`0x1009a5fa8`, `0x1009a60ac`) add or subtract a step from HSL lightness and clamp to 0…1. Hue rotation (`0x1009a5cd8`): `h' = fract(h + degrees/360)`.

**Luminance.** WCAG 2.0 relative luminance on the P3 components: linearize with the 0.03928 knee (`c/12.92` below it, `((c+0.055)/1.055)^2.4` above), then `0.2126 R + 0.7152 G + 0.0722 B` (`0x1009a7768`; constants 0.03928, 12.92, 0.055, 1.055, 2.4, 0.0722). Contrast is `(Lhi + 0.05)/(Llo + 0.05)` (`0x10094f2ec`).

**Band clamp.** `raise(c, to: t)` steps HSL lightness up by 0.01 until luminance ≥ t (`0x1009a7ba4`). `lower(c, to: t)` steps down by 0.01 until luminance ≤ t (`0x1009a7c38`).

**Primary palette** (`0x100d80500`, input: the key color). Each role clamps the key color's luminance into a band:

| Role | Band (luminance) |
|---|---|
| `tintedLight` | 0.85…0.95 |
| `midTone` | 0.30…0.50 |
| `shaded` | 0…0.50 |
| `shadedDark` | 0…0.10 |

**Semantic palette** (`0x100d80aac`, called by `themeSemanticColorPalette(primaryPalette:)`). Each role is `shadedDark` (or `tintedLight`) at a fixed alpha, composited source-over on white or black. All 24 values match the 4 stored themes within 0.003.

| Role | light | dark |
|---|---|---|
| `backgroundExtra` | sD @0.01 over white | sD @0.15 over black |
| `background` | sD @0.10 over white | sD @0.30 over black |
| `hover` | sD @0.20 over white | sD @0.35 over white @0.20 (result alpha 0.48) |
| `focus` | sD @0.50 over white | sD @0.65 over white @0.45 (result alpha 0.8075) |
| `subtitle` | sD @0.40 over white | tL @0.50 over black |
| `title` | sD @0.30 over black | sD @0.15 over white |

sD = `shadedDark`, tL = `tintedLight`. The other 6 roles are aliases of the primary palette (see `runtime-observations.md` §3.3).

**Harmony colors** (`0x100d807dc`, inputs: key color, count n, wheel). Pure HSL hue rotations; saturation and lightness stay the same.

| n | `analogous` | `complimentary` |
|---|---|---|
| 1 | key | key |
| 2 | key, +40° | key, +180° |
| 3 | key, +40°, −40° | key, +150°, +210° |
| ≥ 4 | key + k·360°/n | same |

Check: the 3 stored gradient Spaces all use `analogous`. In P3 HSL their colors are exactly key, +40.0°, −40.0° with equal S and L.

**Background layout.** One color → `blendedSingleColor`. Three colors → `blendedGradient` with `baseColors = [c0, c1]` and `overlayColors = [clear, c2]` (all 3 stored gradient Spaces). Two colors → `blendedGradient` with `baseColors = [c0, c1]`; the overlay content was not decoded (guess: empty). Builder: `0x1017a8b54`.

**Content appearance** (`0x100d722c0` → `0x10094f040`). Inputs: a background color from the palette, the two text colors (one per appearance), and a bias `b`. Result: dark content when `contrast(bg, darkAppearanceText) + b ≥ contrast(bg, lightAppearanceText)`; light otherwise; "unknown" when there is no color. The editor passes `b = +21` when Dark is forced and `b = −21` when Light is forced (WCAG contrast spans 1…21, so a forced mode always wins). Automatic passes the remote flag `sidebar-dark-mode-bias` (`0x1017a8844`; constants ±21.0). With `bg` = the key color (or `shaded`) and the `title` roles as text, the 4 stored themes agree for any bias in [−0.78, 1.60). With `bg` = `midTone` no bias fits, so `midTone` is not the reference. guess: `bg` = the key color, `b` = 0.

**Pad mapping** (`0x1017a6f28` color → knob, `0x1017a7248` knob → color). The pad is a disc in unit coordinates, y down. Angle (clockwise from 3 o'clock) = HSL hue. Radius `r = 0.99 · clamp((L − Lmin)/(Lmax − Lmin), 0, 1)`, so the center is the darkest color and the rim the lightest. Saturation comes from the editor state (default 0.8; when a color is loaded, its own HSL saturation, floor 0.01). Lightness range per appearance mode (`0x1017a80f0`): Automatic 0.01…0.97, Light 0.575…0.97, Dark 0.01…0.425. Forcing a mode keeps the knob's relative radius and remaps its lightness into the new range (`0x1017aa86c`; spans 0.395 and 0.415). Capture check: F0137 knob offset (32, 31) pt from the pad center at 44.1°, and the stored color's P3 hue is 44.1°.

**Other ranges.** A helper builds a lightness range of ±0.25 around a color's lightness, clamped to 0.01…0.97 (`0x1017a9414`; guess: used when a preset is chosen).

**Enums** (reflection records). `WindowTheme.Background.Style.ColorType`: `basicColor`, `blendedSingleColor`, `blendedGradient`. `TranslucencyStyle`: `light`, `dark`, `auto`. `Overlay` (the texture): `grain`, `sand`, `denim`, `tweed`. `BlendedGradientConfiguration.Wheel`: `complimentary`, `analogous`. `WindowTheme` also has an optional `windowAppearance`. Editor state (`SpaceStyleEditor.State`): `primaryColor`, `numberOfColors`, `noiseFactor`, `overlay`, `intensityFactor`, `wheel`, `saturation`, `lightnessRange`, `currentPresetPage`, `darkModeBiasSetting` (`value(Double)` or `forceAppearance`), `undoStack`, `isGestureInProgress`. Noise gestures: `slider`, `rotation`, `dialClick`, `scrollWheel`, `drag`.

## 7. Layout metrics

### 7.1 What static data proves

Interface Builder: `rea decode-interface-builder` finds 6 documents. Only `Base.lproj/MainMenu.nib` belongs to Arc (678 objects).
The main window, sidebar, and tabs are code-built. No nib holds their sizes (fact from the decode).
Strings prove these symbols exist (fact): `sidebarWidth`, `sidebarWidthOnBeginResize`, `effectiveSidebarWidth`, `updateSidebarWidth`, `assistantOverlayPreferredRightSidebarWidth`, `windowTrafficLightRegion`, `cornerRadius`, `rowHeight`.
No number sits next to them in strings. Compiled code holds the numbers.

Image-implied sizes (fact from `assetutil`):

| Element (guess) | Size | Evidence |
|---|---|---|
| Theme knob hit size | 56 pt | Knob images 56 px @1x |
| Color pad backdrop | 400 pt wide | `DotGrid` 400x401 px @1x |
| Settings icon cell | 24 pt | `PrefsGeneral` 24 px @1x |
| Favicon cell class | 32 px | Tray icons 32x32 px |
| Lottie hover cell | 128 pt canvas | HomeButton JSON `w/h` |

### 7.2 Needs run-time measurement (do not guess these into tokens)

Measure each item in Arc with the user signed in. Record light and dark, and hover and rest states.

- Sidebar default width, min width, max width. Drag the divider to both stops.
- Tab row height (rest, hover, current). Include the row gap and the section gap.
- Favorites tile size, gap, and grid count at the default sidebar width.
- Folder row height and indent step. Pinned tab row height if it differs.
- Corner radii: tab row, favorites tile, command bar, popover, web view clip.
- Web view inset on each side and the gap between sidebar and web view (the rounded web content look).
- Traffic light position: x and y from the window corner, and button gap. Note the custom `WindowControlButton` type.
- Top bar height. Space switcher size and gap. Plus button size.
- Command bar width, top offset, row height, and corner radius.

## 8. App icon specs (reference only)

Do not copy the art. Draw a new icon at the same sizes.

File icon: `/Applications/Arc.app/Contents/Resources/AppIcon.icns` (49,907 bytes).
Command: `iconutil -c iconset AppIcon.icns`. It holds 4 PNGs.

| File in set | Pixels | Points (guess) | File bytes |
|---|---|---|---|
| `icon_16x16.png` | 16x16 | 16 pt @1x | 746 |
| `icon_16x16@2x.png` | 32x32 | 16 pt @2x | 2,073 |
| `icon_128x128.png` | 128x128 | 128 pt @1x | 12,703 |
| `icon_128x128@2x.png` | 256x256 | 128 pt @2x | 34,227 |

Raw `icns` chunks (fact from a byte read): `ic13` 34,223 bytes, `ic07` 12,699 bytes, `ic11` 2,073 bytes, `ic04` 904 bytes.

Catalog icon: main `Assets.car` `AppIcon` gives 16, 32, 32@2x, 64@2x, 128, 256, 256@2x, 512, 512@2x, 1024@2x px (fact from `assetutil`).
Alternate icons (Section 2.3) ship a 1024 px master (512 px for `AppIconDev` at 256 px, `AppIconEarlyBirds` and `AppIconHologram` at 512 px) plus a 64 px preview.
Dock tile: `DockTilePlugIn` catalog holds the 10 alternate icons at the sizes above (fact).

## 9. Open items for the signed-in session

The user will sign in to Arc later. Measure these items then. Each item blocks a token.

1. Sidebar widths (default, min, max) and tab row heights. Blocks all layout tokens.
2. Favorites tile size and gaps. Blocks the favorites grid.
3. Corner radii and web view insets. Blocks the rounded web content look.
4. Traffic light offsets. Blocks the title bar.
5. Chrome font family, size, and weight per element (sidebar, tab, command bar, menus). Blocks all type tokens.
6. Spring numbers (`response`, `dampingFraction`) and ease durations per animation. Blocks motion tokens. A decompiled read can also give these numbers.
7. Sound triggers: which event plays `capture.wav` and `event.m4a`. Blocks the sound map.
8. Space contrast rule: the lightness point where sidebar text flips. Test light, mid, and dark Spaces in both system modes. Decoded 2026-10-25 (§6.5): a WCAG contrast comparison with a bias. Still open: the remote default of `sidebar-dark-mode-bias`.
9. Which icon path each button uses: SF Symbol, custom asset, or icon font. Blocks the icon map. No `sidebar.left` string exists, so check the sidebar toggle by hand.
10. Grain blend: how `grain-1` to `grain-4` and `grain-no-blend` differ, and the default `noiseFactor`.
11. Default Space gradient stops for a new Space (two colors, angle, stop positions). The catalog gives single picks only. Partly decoded 2026-10-25 (§6.5): extra colors are HSL hue rotations of the key color. Still open: which theme a brand-new Space starts with.
12. Dark `GrayA1` (opaque black). Confirm the UI never paints it, or find its real use.

## Raw files (local only, in `.re/design/`)

Do not commit these files. They hold Arc-derived data.

| File | Content | Command |
|---|---|---|
| `all-colors.txt` | 479 colors with floats | `assetutil` parse script |
| `all-images.txt` | 1,338 image rows, with helpers | `assetutil` per catalog |
| `images-clean.txt` | 1,042 rows, no helpers | `assetutil` per catalog |
| `image-names.txt` | 389 sorted names | `assetutil` parse |
| `assetutil_*.json` | Per-catalog dumps (52) | `xcrun assetutil --info` |
| `rea-all-assets.json` | Catalog index, 48 catalogs | `rea inspect-asset-catalog` |
| `ib-decode.json` | MainMenu graph, 1,591 nodes | `rea decode-interface-builder` |
| `arc-strings.txt` | 270,339 strings | `strings -a .re/bin/Arc-arm64` |
| `sf-symbols-filtered.txt` | 91 SF candidates | `grep` on strings |
| `font-families.txt` | 83 fonts with weights | `fontTools` name table |
| `fonts-bundle-files.txt` | Font bundle file list | `find` on the bundle |
| `assetutil-summary.txt` | Per-catalog counts | `assetutil` loop |




