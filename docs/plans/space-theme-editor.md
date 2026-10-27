# Space creation, Space editing, and the theme editor — implementation plan for Open

Status: plan (2026-10-25). Base: `main` at `724e35d`. Implementer: a coding
agent with no other context. Follow this file literally. Where this file
says "Open choice", the choice is final for v1; do not re-derive it. Where
it cites an RE fact, the citation is the evidence. A value marked **guess**
ships as written until §15 or a capture changes it. Do not copy Arc assets,
icons, sounds, Lottie files, or text that names the Arc brand (`AGENTS.md`
rule 1). Draw every asset yourself; SF Symbols are allowed.

Read first, in this order:

1. `AGENTS.md` (rules 1–10).
2. `docs/re/design-tokens.md` §6 (preset colors, textures, and §6.5 — the
   decoded theme math this plan implements).
3. `docs/re/interaction-states.md` §14 (the measured editor) and §15 (menus).
4. `docs/re/features-core.md` §2.2–§2.3, items 4–16.
5. `docs/re/runtime-observations.md` §3 (stored theme shape and the 4 sample
   themes) and `docs/re/data-model.md` §2.3 (enum cases).
6. `docs/design.md` §3 (theme rendering), §6–§8 (harness, compare method,
   targets).
7. `docs/model.md` (commands, undo rules, snapshot DTOs).
8. `docs/plans/app-shell.md` §4.1 (who handles sidebar intents) and
   `docs/plans/profiles.md` (Profile picker and change-Profile warning).

## Goal

Ship every way to create and edit a Space in Arc's look and behavior:

1. **New Space** form: name, icon or emoji, theme, Profile, then create.
2. **Rename**, **change icon**, **change theme**, **change Profile** for an
   existing Space.
3. The **theme editor**: color pad with up to 3 harmony colors, Light / Dark /
   Automatic modes, 45 presets, intensity slider, noise dial with 4 textures,
   live preview in every window that shows the Space, and undo.
4. One **icon picker** (Emoji and Icons pages) for Spaces, tabs, and folders.
5. Every entry point: menu bar, context menus, plus menu, command bar.

## Success criteria

- Every entry point in §8 opens the right surface. No entry point is a dead
  item. `new-space`, `rename-space`, `edit-theme`, `change-profile`, and the
  new `change-space-icon` command run from the menu bar and the command bar.
- The theme editor panel matches F0137 / F0138 within 1 pt for every control
  frame and ΔE00 ≤ 2 for opaque control colors (§12.3).
- Theme math reproduces the 4 stored Arc themes: primary palette within
  1/255, semantic palette within 0.003, harmony hues within 0.1° (§12.2 M1–M2).
- A knob drag updates the background and sidebar of every window that shows
  the Space in the same display frame. One drag is one undo step named
  "Update Theme". Undo and redo also move the knob when the editor is open.
- A new Space created from the form has the typed name, icon, theme, and
  Profile, is focused, and undoes in one step ("New Space").
- Icon picks persist for Spaces, tabs, and folders and survive relaunch.
  Snapshots written before this plan load with the same look (§3.4).
- Performance: drag tick p95 ≤ 4 ms main-thread time with 2 windows open;
  no work while the editor is closed; idle CPU unchanged (§12.4 B1).
- No unit tests (`AGENTS.md` rule 6). All checks are harness or app e2e.

## Non-goals

- "Share Space…" (needs an Arc account), Easels, Notes, sync (`AGENTS.md`
  v1 scope).
- The Space Manager ("Manage Spaces…"). It keeps its current intent; a
  separate plan owns it.
- Exposing the theme to web pages (`--arc-background-gradient-color`, the
  Advanced setting "Allow websites to get your theme data"). Separate plan.
- Arc's onboarding ("Unboxing") theme step (`SpaceStyleEditorView.Presentation.setup`).
  The first-run plan may reuse §5 later.
- Arc's looping Lottie icons for the mode buttons. We use SF Symbols with
  symbol effects (§5.4).
- A Profile editor. "New Profile…" uses the existing profiles flow
  (`SpaceCreationProfilePickerModel`, profiles plan).

## 0. Locked decisions (do not revisit)

| # | Decision | Evidence / reason |
|---|---|---|
| D-1 | Open stores only the editor **inputs** in a new `SpaceStyle` value (key color, color count, wheel, appearance mode, noise, texture, intensity, math version). Palettes, harmony colors, and content appearance are derived at render time and never stored. | `design-tokens.md` §6.5: every stored Arc output (16 primary + 48 semantic values, 3 harmony sets) is a pure function of these inputs. `docs/model.md`: stored values never change meaning; a `mathVersion` field pins the derivation. |
| D-2 | Theme color math runs in Display P3 HSL with WCAG luminance, exactly as decoded. No OKLab, no HSB for the editor math. (The existing OKLab gradient interpolation in `ThemeField` is a renderer fit and stays.) | §6.5: P3 model error 0/255 vs up to 15/255 in sRGB. |
| D-3 | The editor, the icon picker, and the creation form are AppKit + Core Animation in a new library target `OpenSpaceEditor`. No SwiftUI. | `AGENTS.md`: SwiftUI only where cheap; the pad drag must hold 120 Hz; the sidebar is AppKit (`docs/design.md`). Arc's SwiftUI choice is an implementation detail, not a look. |
| D-4 | The theme editor is a borderless child panel (no arrow) with the system popover material, 382 × 534 pt, left edge on the sidebar's trailing edge, top 35 pt below the window top. | `interaction-states.md` §14: AX `[500, 35, 382, 534]`, content inset 13, no visible arrow. `NSPopover` cannot hide its arrow with public API. |
| D-5 | Live preview writes the model directly (`previewSpaceTheme`, no undo, no save). A gesture end commits one undo step and schedules one save. | `features-core.md` §2.3 item 11 (all windows update); item 12 (editor `undoStack` + `registerUndo`); `docs/model.md` undo rules (one command = one step). |
| D-6 | New Space uses a form page inside the sidebar column, not a sheet or window. | guess (strong): `features-core.md` item 14 — width breakpoints 190 / 227 pt, inline-or-anchored submit button, host type next to the sidebar paging controller. See §15 Q6. |
| D-7 | One icon picker serves Spaces, tabs, and folders. Icons store `SpaceIcon.named(<Arc identifier>)` from `NamedSpaceIcons`; emoji store `.emoji(String)`. Tabs and folders gain a typed `iconOverride: SpaceIcon?`; the legacy `customIcon: String?` keeps its current meaning. | `features-core.md` item 15 (`CustomInfoPicker`, `tabAndSpacePicker`, `folderPicker`). `OpenModel/NamedSpaceIcons.swift`. Today `customIcon` is untyped (`OpenSidebar/Controls.swift` draws it as SF Symbol else emoji). |
| D-8 | Textures (`grain`, `sand`, `denim`, `tweed`) are our own procedural tiles. Grain keeps today's `Grain.tile` (100 pt period). The others use Arc's tile periods (96, 300, 128 pt) as facts, with our own patterns. | `design-tokens.md` §6.3; `docs/design.md` §3.6; `AGENTS.md` rule 1. |
| D-9 | No default keyboard shortcuts are added. Arc defines none for these actions. | `menus-and-hotkeys.md` "Spaces (9 items)": only Next / Previous Space have keys. |
| D-10 | Command ids never change. Existing: `new-space`, `rename-space`, `edit-theme`, `change-profile`. New: `change-space-icon` (code-only, no menu bar item). | `docs/commands.md`: never rename a shipped id. Arc's Spaces menu has no icon item (`menus-and-hotkeys.md`). |
| D-11 | Undo action names: "Update Theme", "Customize Space", "Customize Tab", "Customize Folder", "New Space", "Rename Space". The window controller sets them; the model stays free of UI strings. | `features-core.md` items 12, 14, 15 (Arc literals "Update Theme", "Customize Space", "Customize Tab", "New Space"). "Customize Folder" and "Rename Space" are Open choices. |
| D-12 | No new code dependency. The emoji table is data generated by our own script (§7.4, §15 Q1). | `AGENTS.md` code conventions. |

## 1. Current state (verified at `724e35d`; re-verify before you edit)

Run `git log --oneline -3` and read each file before you change it.

| Area | State today | Evidence |
|---|---|---|
| Space model | `Space { id, title?, icon: SpaceIcon?, theme: SpaceTheme, profileID, pinned, today, isPinnedCollapsed }`. `SpaceIcon` = `.emoji / .symbol / .named`. | `OpenModel/Containers.swift:106`, `OpenModel/Theme.swift` |
| Theme model | `SpaceTheme { light/dark background and foreground, accent, gradientStopsLight/Dark, importedArcThemeJSON }`. No editor inputs. Stored as-is in `SpaceDTO.theme`. | `OpenModel/Theme.swift`, `OpenStore/SnapshotDTOs.swift:92` |
| Commands | `createSpace(title:profileID:icon:theme:)` appends and registers undo. `updateSpace(id:title:icon:theme:profileID:)` is one undo step for all four values. `moveSpace(id:toProfile:)`, `deleteSpace`, `moveSpace(id:to:)` exist. No theme preview, no icon command for tabs/folders. | `OpenModel/BrowserModel.swift:923–1035` |
| Profile picker | `SpaceCreationProfilePickerModel` (choices, `isCreatingProfile`, `createSpace(in:title:icon:theme:)`) and `ChangeProfileRequest` (warning text, don't-show-again key) exist. | `OpenModel/ProfilesSettingsModel.swift:81–147` |
| Theme render | `SpaceThemeStyle` parses Arc `windowTheme` JSON (`blendedGradient`, `blendedSingleColor`), else stops, else the default theme. `ThemeField` draws the fitted gradient (alpha 0.64, OKLab mix). `Grain` has one procedural texture. `ThemeBackgroundView` cross-fades and coalesces rebuilds with a display link. | `OpenDesign/SpaceThemeStyle.swift`, `ThemeField.swift`, `Grain.swift`, `ThemeBackgroundView.swift`, `docs/design.md` §3 |
| Propagation | `SidebarView.syncTheme()` tracks the focused Space's theme and cross-fades the window background on any change (animated). `StyleCache` caches styles by value (64 entries). | `OpenSidebar/SidebarView.swift:117–126`, `SidebarContext.swift:188` |
| Menus | Space menu: Change Space Icon…, Rename Space… (inline), Edit Theme Color…, Set Profile ▸ (Profiles, New Profile…), New Folder, Share Space…, Export into Folder ▸, Manage Spaces…, Delete Space. Plus menu: New Space…. Tab menu: Move to ▸ New Space…, Change Icon…. Folder menu: Change Icon…, Turn into Space. | `OpenSidebar/SidebarMenus.swift` |
| Intents | `newSpace`, `changeSpaceIcon`, `renameSpace`, `editSpaceTheme`, `setSpaceProfile`, `newProfile`, `changeIcon`, `moveToNewSpace`, `turnFolderIntoSpace` exist. `ModelSidebarActions` handles only `renameSpace` and `setSpaceProfile`. `OpenFeatures.BrowserWindowController` handles split and navigation only; the rest return `false`. | `OpenSidebar/SidebarIntent.swift`, `ModelSidebarActions.swift`, `OpenFeatures/BrowserWindowController.swift:144–170` |
| Command registry | `new-space`, `rename-space`, `edit-theme`, `change-profile` registered in the Spaces menu with aliases and command-bar symbols. No handler. | `OpenCommands/CommandRegistry.swift:205–223`, `SuggestAdapter.swift:119` |
| Icons | `NamedSpaceIcons.symbols`: a dictionary of 55 Arc identifiers → SF Symbols (written in Arc's raw-value order, but a dictionary has no order at run time). `SpaceIconView` draws emoji, named, symbol, and a code-drawn planet for "no icon". Tab and folder `customIcon: String?`. | `OpenModel/NamedSpaceIcons.swift`, `OpenSidebar/SpacePageView.swift:772`, `OpenModel/LiveNodes.swift:40,73` |
| Import | Arc `windowTheme` JSON → `importedArcThemeJSON`. Tab icon → `customIcon` string (emoji or the raw Arc name). | `OpenImport/ArcImport.swift:340` |
| App | `App/BrowserWindowController.swift` is still the M1 window. App-shell Step B (adopt `OpenFeatures.BrowserWindowController`) is pending. Automation has `space-create` and `space`. | `docs/plans/app-shell.md` §1, §7; `App/Automation/AutomationController.swift:77–94` |
| Harness | `sidebar-render`, `commandbar-render`, `features-render`, `settings-preview` (offscreen renders, `compare`). `verify-all.sh` lists its checks in `NAMES`; results at the base commit are in the PR. | `tools/verify-all.sh` |

## 2. Spec inputs (facts; use as-is)

The decoded math is in `design-tokens.md` §6.5. This section restates only
what the implementation needs, in implementation terms.

### 2.1 Color math (all in Display P3, components clamped to 0…1)

```text
toP3(c)          extended-sRGB RGBA → Display P3 RGBA, clamp RGB to 0…1
hsl(c)           standard RGB → HSL (h in 0..<1)
rgb(h,s,l)       standard HSL → RGB
lum(c)           WCAG: lin(x) = x ≤ 0.03928 ? x/12.92 : ((x+0.055)/1.055)^2.4
                 lum = 0.2126·lin(r) + 0.7152·lin(g) + 0.0722·lin(b)
contrast(a,b)    (max(La,Lb) + 0.05) / (min(La,Lb) + 0.05)
rotate(c, deg)   hsl with h' = fract(h + deg/360)
raise(c, t)      while lum < t: l = min(1, l + 0.01)
lower(c, t)      while lum > t: l = max(0, l − 0.01)
band(c, lo, hi)  lum < lo ? raise(c, lo) : lum > hi ? lower(c, hi) : c
fromP3(c)        Display P3 → extended sRGB (store and render this)
```

Primary palette (input `k` = key color):
`tintedLight = band(k, 0.85, 0.95)`, `midTone = band(k, 0.30, 0.50)`,
`shaded = band(k, 0, 0.50)`, `shadedDark = band(k, 0, 0.10)`.

Semantic palette: the table in `design-tokens.md` §6.5 (sD over white or
black at fixed alphas). Aliases: `runtime-observations.md` §3.3.

Harmony colors for count `n` and wheel `w`: `analogous` → `[k, +40°, −40°]`
(first `n`); `complementary` → `n = 2: [k, +180°]`, `n = 3: [k, +150°, +210°]`.

Add transition (lead, 2026-10-26 11:57 America/Vancouver): when count is
exactly 1, Add sets `wheel = .complementary` and count 2. A second Add keeps
that mode and gives +150°/+210°. At count ≥2, Add preserves the stored
wheel (including a page-2 analogous style reduced to two colors). Count and
mode change in one undoable command; undo restores both. Do not change the
harmony function or rewrite stored styles. Evidence: session 2 item 17,
frames 0065/0067/0069, page-1 Brand 8, +180° then +150°/+210°.

Background layout: `n = 1` → single color; `n = 2` → base `[c0, c1]`, no
overlay; `n = 3` → base `[c0, c1]`, overlay `[clear, c2]`. Translucency is
always `light` (all 4 stored themes, including the dark-content one).

Content appearance: `dark` when
`contrast(k, dark.title) + bias ≥ contrast(k, light.title)`. Here
`dark.title` is the light text that dark content uses, and `light.title` is
the dark text that light content uses (both from the semantic palettes). Bias: Automatic
`ThemeTuning.automaticBias` (= 0.0, guess, §15 Q3), Light −21, Dark +21.

### 2.2 Pad mapping

**Superseded by §17.1 (decoded 2026-10-26).** The range below is the empty-editor case only.

**Provisional, not a parity gate:** capture session 2 contradicts this
linear radius law. See the dated lead amendment and mandatory Step 9 gate
below. Keep current stored styles and mathVersion semantics until that work
is implemented with an explicit compatibility decision.

Unit disc, y down, angle clockwise from 3 o'clock. Lightness range by mode:
Automatic `0.01…0.97`, Light `0.575…0.97`, Dark `0.01…0.425`.

```text
color → knob:  t = clamp((l − Lmin)/(Lmax − Lmin), 0, 1);  r = 0.99·t
               knob = (cos(2πh)·r, sin(2πh)·r)
knob → color:  h = fract(atan2(y, x)/2π + 1);  t = min(hypot(x, y)/0.99, 1)
               l = Lmin + t·(Lmax − Lmin);  s = saturation;  color = rgb(h, s, l)
saturation  =  max(hsl(key).s, 0.01)   (default 0.8 when no color exists)
mode change =  keep t, set l = newLmin + t·(newLmax − newLmin)
```

The mode-change remap is decoded for Light and Dark (`0x1017aa86c`). Using the
same remap when the user returns to Automatic is a **guess**.

Pad radius on screen: 170 pt (half the pad side). Check: F0137 knob offset
(32.5, 31.5) pt ↔ hue 44.1°, t = 0.272 (`interaction-states.md` §14).

### 2.3 Presets (45 swatches, 5 pages of 9)

| Page | Swatches | Key color | Count | Wheel |
|---|---|---|---|---|
| 1 | Brand 1–9 | `design-tokens.md` §6.2 (Brand5 = `#FF8558` sRGB) | 1 | analogous |
| 2 | Brand 1–9 again | same | 3 | analogous (**guess**, §15 Q5) |
| 3 | Pastel 1–9 | §6.2 (P3) | 1 | analogous |
| 4 | Drab 1–9 | §6.2 (P3) | 1 | analogous |
| 5 | Greyscale 1–9 | §6.2 (P3) | 1 | analogous |

Page order is a fact (AX order in F0137). The page-2 count and wheel are a
strong guess: 2 of 3 stored gradient Spaces are Brand5 / Brand6 with exactly
3 analogous colors (`design-tokens.md` §6.5), and Arc's pill style has an
`addComplimentary` flag (`features-core.md` item 12).

## 3. Data model and persistence

### 3.1 New model types (`OpenModel/Theme.swift`)

```swift
public enum SpaceStyleWheel: String, Codable, Sendable, CaseIterable { case analogous, complementary }
public enum SpaceStyleAppearance: String, Codable, Sendable, CaseIterable { case automatic, light, dark }
public enum SpaceStyleTexture: String, Codable, Sendable, CaseIterable { case grain, sand, denim, tweed }

/// Editor inputs. Everything else is derived (docs/re/design-tokens.md §6.5).
public struct SpaceStyle: Codable, Hashable, Sendable {
    public static let currentMathVersion = 1
    public var mathVersion: Int            // derivation rules; never reinterpret an old version
    public var keyColor: RGBAColor         // extended sRGB, alpha 1
    public var colorCount: Int             // 1...3
    public var wheel: SpaceStyleWheel      // default .analogous
    public var appearance: SpaceStyleAppearance  // default .automatic
    public var noiseFactor: Double         // 0...1, default 0
    public var texture: SpaceStyleTexture  // default .grain
    public var intensityFactor: Double     // 0...1, default 0.8
    public init(keyColor: RGBAColor, colorCount: Int = 1, wheel: SpaceStyleWheel = .analogous,
                appearance: SpaceStyleAppearance = .automatic, noiseFactor: Double = 0,
                texture: SpaceStyleTexture = .grain, intensityFactor: Double = 0.8,
                mathVersion: Int = SpaceStyle.currentMathVersion)
}
```

`SpaceTheme` gains one stored property: `public var style: SpaceStyle?`
(synthesized `Codable`: missing key → `nil`; `nil` is not encoded).

Validation on decode and on every write: clamp `colorCount` to 1…3, noise and
intensity to 0…1, `keyColor.alpha` to 1. Unknown enum strings decode as the
default case (write a custom `init(from:)` for the three enums; synthesized
`Codable` would throw) and are written as that default on the next save (Open
has no released users; `docs/model.md` precedent). Add `style: SpaceStyle? = nil`
to `SpaceTheme.init`.

Lead review amendment (2026-10-26, Step 1 round 1): fields inside `style`
decode with `decodeIfPresent` and their documented defaults. Wrongly typed
optional inputs also use those defaults. An unusable optional style (no
valid key color or invalid object shape) is nil, so it cannot fail the
whole snapshot. The legacy theme fields keep their original decode rules.

### 3.2 Rendering precedence and write rules

`SpaceThemeStyle(theme:system:)` resolves, in order:

1. `theme.style` (new resolver, §4.2).
2. `theme.importedArcThemeJSON` (today's parser, unchanged).
3. `theme.gradientStopsLight` (unchanged).
4. The default theme (unchanged).

Write rules:

- The editor writes `SpaceTheme(style: s)` with every legacy field empty.
  The old value lives only in the undo step. Nothing is reinterpreted.
- "Remove color" at count 1 writes `SpaceTheme()` (all empty). The Space
  shows the default theme. Undo restores the full previous value.
- Import from Arc is unchanged: it keeps writing `importedArcThemeJSON` and
  never writes `style`. Imported Spaces keep Arc's stored palettes and
  appearance byte for byte.
- When the editor opens on a Space without `style`, it seeds its state from
  the current value (§4.3) and writes nothing until the first change.

### 3.3 Typed icons for tabs and folders

- `Tab.iconOverride: SpaceIcon?` and `Folder.iconOverride: SpaceIcon?` (live,
  `@Observable`). DTO key `iconOverride` (`SpaceIconDTO?`) on `TabDTO` and
  `FolderDTO`.
- Draw precedence: `iconOverride` → legacy `customIcon` (today's rule: SF
  Symbol if one resolves, else emoji) → favicon / folder glyph.
- `setNodeIcon` (§10.1) writes `iconOverride` and sets `customIcon = nil` in
  the same step. Undo restores both.
- Import from Arc writes `iconOverride` (`.emoji` for `emoji_v2`/`emoji`,
  `.named` for `icon`) for new imports. Old snapshots keep `customIcon` and
  its meaning.
- Space icons keep `Space.icon: SpaceIcon?` (already typed).

### 3.4 Snapshot schema

`schemaVersion` stays 1. All changes are additive optional keys:
`SpaceDTO.theme.style`, `TabDTO.iconOverride`, `FolderDTO.iconOverride`.
Older builds ignore them (JSON decoding skips unknown keys) and render the
legacy fields, which the editor clears on write. That loss in older builds is
accepted (no released users; same policy as `docs/model.md` §Snapshot).

Acceptance (Step 1): a snapshot written before Step 1 renders the same PNG
(byte-identical `sidebar-render render` output) after this plan's Step 2.

## 4. Theme engine (`OpenDesign`)

### 4.1 `ThemeColorMath.swift` (new)

Pure functions from §2.1 and §2.2 on a small `P3` value type (`r, g, b`
doubles). Use `CGColorSpace.displayP3` ↔ `extendedSRGB` conversion through
`CGColor.converted(to:intent:options:)` once per input color, then pure
math. Never call AppKit color APIs in the per-pixel or per-tick path.

```swift
public enum ThemeColorMath {
    public static func toP3(_ c: RGBAColor) -> P3
    public static func toExtendedSRGB(_ c: P3) -> RGBAColor
    public static func hsl(_ c: P3) -> (h: Double, s: Double, l: Double)
    public static func rgb(h: Double, s: Double, l: Double) -> P3
    public static func luminance(_ c: P3) -> Double
    public static func contrast(_ a: P3, _ b: P3) -> Double
    public static func rotate(_ c: P3, degrees: Double) -> P3
    public static func band(_ c: P3, _ lo: Double, _ hi: Double) -> P3     // 0.01 steps
    public static func harmony(key: P3, count: Int, wheel: SpaceStyleWheel) -> [P3]
    public static func primaryPalette(key: P3) -> PrimaryPalette             // 4 roles
    public static func semanticPalettes(_ p: PrimaryPalette) -> (light: SemanticPalette, dark: SemanticPalette)
    public static func contentAppearance(key: P3, light: SemanticPalette, dark: SemanticPalette, bias: Double) -> ContentAppearance
    public static func lightnessRange(_ mode: SpaceStyleAppearance) -> ClosedRange<Double>
    public static func knob(for color: P3, range: ClosedRange<Double>) -> CGPoint     // unit disc
    public static func color(at knob: CGPoint, saturation: Double, range: ClosedRange<Double>) -> P3
}
public enum ThemeTuning {
    public static let automaticBias: Double = 0.0   // guess; data allows −0.78..<1.60 (§15 Q3)
    public static let forcedBias: Double = 21
}
```

### 4.2 `SpaceThemeStyle(style:system:)` (extend `SpaceThemeStyle.swift`)

Build every field from `SpaceStyle`:

| Field | Value |
|---|---|
| `fill` | `.blended(base:overlay:)` per §2.1 layout (convert each color to extended sRGB `RGBA`) |
| `noiseFactor`, `intensityFactor` | from the style |
| `texture` (new field, default `.grain`) | from the style; imported JSON reads `modifiers.overlay` |
| `translucency` | `.light` |
| `contentAppearance` | §2.1 rule with the mode's bias |
| `isVibrant` | `true` |
| `lightPalette`, `darkPalette` | §2.1 semantic palettes |
| `accent` | `shaded` |

Cache: `StyleCache` already caches by `SpaceTheme` value. Keep it. Raise the
cap from 64 to 256 entries, because a drag creates one entry per frame; clear
the oldest half, not the whole cache, when full.

### 4.3 Seeding the editor from an existing theme

`SpaceStyle.seed(from theme: SpaceTheme) -> SpaceStyle?`:

1. `theme.style` → return it.
2. Arc JSON → key color = `baseColors[0]` or `color`; count = 1 (single), 2
   (gradient without overlay color), 3 (gradient with `overlayColors[1]`);
   wheel from `wheel` (Arc spells `complimentary`); noise, texture
   (`modifiers.overlay`), intensity from `modifiers`; appearance: compute the
   §2.1 Automatic result; if it equals the stored
   `contentOverBackgroundAppearance`, use `.automatic`, else force the stored
   value (`.light` / `.dark`).
3. Stops → key color = first stop, count 1, defaults.
4. Nothing → `nil` (the editor opens in its empty state, §5.8).

### 4.4 Textures (`ThemeTexture.swift`, replaces direct `Grain` use)

```swift
public enum ThemeTexture {
    public static func period(_ t: SpaceStyleTexture) -> CGFloat   // grain 100, sand 96, denim 300, tweed 128 pt
    public static func tile(_ t: SpaceStyleTexture, noiseFactor: Double, scale: CGFloat) -> CGImage?
    public static func knobPreview(_ t: SpaceStyleTexture, diameter: CGFloat, scale: CGFloat) -> CGImage
}
```

All four are black tiles with darkness in alpha (the `Grain` scheme from
`docs/design.md` §3.6), pattern-mark peak alpha `noiseFactor × 0.1`, and the
same mean darkness as grain within 10 %. Our own patterns, seeded and deterministic:

| Texture | Pattern (Open design) |
|---|---|
| grain | today's hashed white noise (no change) |
| sand | sparse speckle: 18 % of pixels, 1–2 px dots, random alpha 0.4–1.0 |
| denim | 45° twill: lines 3 pt apart, 1 pt wide, alpha modulated by 1D value noise along the line |
| tweed | short orthogonal dashes (4–7 pt) on a 3 pt grid, random orientation, slight jitter |

Lead amendment, user message **2026-10-25 23:58:10 America/Vancouver**, on
§4.4: keep equal mean darkness so a texture switch does not change the
Space's overall brightness. At tile-build time, at the same noise factor,
compute `base = max(0, grainMean − patternMean)` for sand, denim, and tweed.
Composite each pattern mark over the uniform base:
`alpha = base + mark × (1 − base)`. The mark's own peak remains
`noiseFactor × 0.1`; the composited pixel can exceed it. Grain never gains
a base. The cache key remains (texture, noise bucket, scale), since the base
is derived from those inputs. This is **Open design**, to calibrate against
the editor capture in Step 9.

The `space-editor-render` texture check (M5) asserts every texture's mean is
within 10% of grain at noise factors 0.25, 0.5, and 1.0, at 1x and 2x. For
sand at noise 1, the mean alpha of peak marks minus the base must be at
least 0.03. Peak marks are the marks in the top 10% of the prescribed mark
alpha range.

Tiles are generated lazily on first use, cached per (texture, noise bucket of
0.05, scale), shared by all windows. `ThemeLayer` uses `ThemeTexture` instead
of `Grain`. Cross-fades already cover texture changes (two layers).

Review R1: the tile cache caps at 32 entries and evicts its oldest half.
Grain image/mean pairs cache per (bucket, scale), bounded at 64 entries;
normalized denim patterns are reused across buckets, bounded at four scales.
The harness gates cold 2x tile generation at a loose 500 ms and a 64×64
field rebuild per preset style at 250 ms; strict B1 stays in Step 5.

Lead design decision (2026-10-26): D-8 keeps grain strength and monochrome
bytes unchanged. F0139's noise-0.45 strength gap and per-channel grain are
Step 9 calibration items. No strength or chromatic adjustment lands here.
New editor-style fill colors clamp to sRGB 0…1 at render time; legacy
imports/stops keep their original extended-color and exact-noise grain
render path to satisfy §3.4. Stored extended keys
and primary/semantic palette derivation remain unchanged. F0139 is checked
with `compare --spec theme-window` over six background-only regions.

### 4.5 Intensity

**Superseded by §17.2 (decoded 2026-10-26):** `a = 0.2 + 0.55 × intensity` with a dark wash.

`ThemeField.layerAlpha` becomes `ThemeField.layerAlpha(intensity:)`. Ship the
provisional law `alpha = 0.8 × intensity` (0.64 at the default 0.8, so every
existing fit and capture compare is unchanged at 0.8). Imported themes with
intensity 1.0 change from 0.64 to 0.80: record the F0069 compare before and
after in the PR. If its ΔE00 worsens past 2, keep 0.64 for imported themes
(`style == nil`) until §15 Q4 is calibrated, and state it in the PR.

## 5. Theme editor (`OpenSpaceEditor`)

### 5.1 Container

| Property | Value | Evidence |
|---|---|---|
| Type | `ThemeEditorPanel: NSPanel`, borderless, `isFloatingPanel = false`, child of the browser window (`addChildWindow(_:ordered: .above)`), `canBecomeKey = true`, `hasShadow = true`, clear background | D-4 |
| Material | `NSVisualEffectView`, `.popover`, `.behindWindow`, `.active`, only in body `(13,13,356,508)`, continuous corner radius 20; outer 13 pt band transparent | Opus R1 F0137 corner fit SSE 0.009; replaces the full-frame radius-16 guess |
| Outer size | 382 × 534 pt | §14 AX |
| Content inset | 13 pt each side → content 356 × 508 | §14 AX |
| Position | left = sidebar trailing edge in window coordinates (anchored sidebar: `sidebarWidth`; floating card: card frame `maxX`); top = window top + 35 pt. Clamp inside the screen's `visibleFrame` with 8 pt margins; if clamped horizontally, keep it fully on screen. | §14 (x 500 = sidebar width, y 35) |
| Opened from the creation form | top aligned with the Theme card's top, same left edge (**guess**) | §6 |
| Appearance | forced Space Light/Dark overrides the system live; Automatic follows the system; tokens in §5.9 | Session 2 0158–0163, lead round 3 supersedes Q9 |
| One per window | Opening an editor for any Space closes the open one first (commit is already done per gesture). | Open choice |
| Close triggers | Esc; mouse down in any app window outside the panel (local event monitor); the app deactivates (`NSApplication.didResignActiveNotification`); the browser window closes or switches Space; the edited Space is deleted | Arc `didKeyDownEscape`; transient popover behavior |

### 5.2 Layout (content coordinates, origin top-left, pt)

R1: screen clamping keeps the material **body** 8 pt inside `visibleFrame`,
not the transparent outer band. Model-backed editor sessions use the model's
single undo manager (defaulting to the owner's manager when unassigned).
Remove/Add both use 16 pt Semibold and `glyph`; the cool `addGlyph` token is
removed. Light `glyphSelected` is black 0.50 (session 2). Empty copy stays exactly
"Tap to pick a color for this space"; AX percentages have no space.

| Element | Frame | Notes |
|---|---|---|
| Pad plate | `(8, 8, 340, 340)` | radius 4 (**guess**, visual ≈ 3) |
| Pad center / radius | `(178, 178)`, R = 170 | §2.2 |
| Mode buttons | `(122, 32, 32, 32)`, `(162, 32, …)`, `(202, 32, …)` | Automatic, Light, Dark |
| Remove / Add | `(142, 300, 32, 32)`, `(182, 300, 32, 32)` | inside the pad |
| Previous page | `(9, 364, 32, 32)` | |
| Swatch viewport | `(48, 364, 260, 32)`, clips; swatch `i` of page `p` at x = `48 + 265.5·(p − page) + 29.5·i`, y 368, 24 × 24 | constants 24, 5.5, 260, 265.5 |
| Next page | `(315, 364, 32, 32)` | |
| Intensity slider | hit `(18, 424, 224, 56)`; track capsule `(18, 444, 224, 16)` | |
| Noise dial | hit `(258, 412, 84, 80)`; art center `(298, 452)` | F0137/F0138 calibration; unchanged AX hit frame |

### 5.3 Pad and knobs

Drawing (layers, no `draw(_:)` per frame):

| Part | Spec |
|---|---|
| Plate | fill `ThemeEditorColors.padFill` |
| Dot grid | our own tile: 1.0 pt dots, pitch 4.25 pt, `ThemeEditorColors.dot`; one cached `CGImage` pattern per scale |
| Primary knob | 44 pt circle: 5 pt ring `ThemeEditorColors.knobRing` (white), 34 pt disc filled with the key color (P3 `CGColor`). Downward shadow y +2, radius 2, white 0.06 in dark / black 0.06 in light; no normal light outline (session 2, fit). |
| Harmony knobs | 27 pt circle: 3 pt pure white ring, 21 pt disc. Scale to about 30 pt with hover/drag; not draggable. Draw secondary knobs first and the primary last, so coincident grey knobs stay underneath. Session 2 0050–0064 and 0067–0080 supersedes Q10. |
| Knob hover | primary ×1.09, secondary about 30/27, over 0.12 s ease-out (session 2 0076) |
| Knob drag | primary ×1.136, secondary about 30/27 (session 2 0077–0080); returns to 1.0 on mouse up over 0.2 s spring |
| Empty state | text "Tap to pick a color for this space", 13 pt Semibold (weight fit), `secondaryText` white 0.90 / light black 0.74, one line at max width 220; center the actual label height on the pad, not a top-aligned 40 pt wrapping frame (session 2 0010) |

Interaction:

1. Mouse down on the primary knob (hit circle radius 26): relative drag. The
   knob moves by the pointer delta from its position at drag start
   (Arc `_knobPositionAtDragBegin`).
2. Mouse down elsewhere in the pad: the primary knob jumps to the pointer,
   then drags (**guess**). With no color, this creates the first color
   (count 1) at that point.
3. Position clamps to unit radius 0.99 (rim).
4. Every pointer move: new key color = `color(at:saturation:range:)`. Send at
   most one preview per display frame (§9.1).
5. Mouse up: commit (§9.2). A click without movement is a commit of the jump.
6. Harmony knobs follow the primary at the rotated angles (same radius).

Keyboard (pad focused): ←/→ hue ∓/± 5° (Shift: 20°); ↑/↓ radius ± 0.03
(Shift: 0.1). Each key press is one commit. Focus ring: system focus ring
around the pad plate.

### 5.4 Mode buttons (Automatic, Light, Dark)

| Property | Value |
|---|---|
| Glyphs | SF Symbols `sparkles`, `sun.max.fill`, `moon.stars.fill`, 15 pt medium |
| Glyph color | selected `ThemeEditorColors.glyphSelected`, unselected `glyph` (white ≈ 0.5 measured) |
| Selected plate | 32 × 32, radius 8, `ThemeEditorColors.selectedPlate` (white ≈ 0.10 measured) |
| Hover plate | alpha 0.11 in both modes; source-over selected plate when selected, combined alpha 0.199 |
| Hover effect | `NSImageView.addSymbolEffect(.bounce)` once on hover enter (our replacement for Arc's looping Lottie) |
| Tooltips | "Automatic Appearance", "Light Appearance", "Dark Appearance" |
| Action | set `appearance`; remap lightness (§2.2); commit one step |

### 5.5 Remove and Add

32 × 32 buttons, glyphs `minus` / `plus` 16 pt Semibold, `glyph` color, hover
plate radius 8. Tooltips "Remove color" / "Add color". Add is enabled when
count < 3. Remove is enabled when count ≥ 1. Remove at count 1 clears the
theme (§3.2) and shows the empty state. Both buttons stay visible and disabled in the empty
state (session 2 0010; supersedes the hidden-button guess). Each click is one commit.

### 5.6 Presets strip

| Property | Value |
|---|---|
| Arrows | `chevron.left` / `chevron.right` 16 pt Semibold, 1 pt lower, `glyph` color; disabled factor 0.32 at the first / last page (review R3, 0010/0027). |
| Swatch | 24 pt circle; 2 pt black 0.10 rim inset 1 pt, darkening the local fill; origins snapped to backing pixels (review R3). |
| Page 2 swatch | own 3-stop diagonal sRGB gradient, no disc; stops re-sampled inside the rim at diagonal t = −9/0/+9 from session 2 0016; endpoints (0.235,0.235) and (0.765,0.765), locations 0/0.5/1; five-point t = −8/−4/0/4/8 gate at ΔE00 ≤2, using the same 2×2 pt mean on both images |
| Hover | scale 1.1 over 0.12 s; press scale 0.9 (constants 0.9 / 0.85 in the picker code, **guess** for their role) |
| Paging | horizontal slide of the strip by 265.5 pt, spring `Motion.spaceSwitch`; trackpad horizontal scroll pages too |
| Selection | no visible selected state (none in F0137) |
| Action | set key color, count, and wheel from §2.3; keep the mode; saturation from the color; the knob shows at the clamped position (the color is stored as is); commit one step |
| Accessibility | buttons "Set Space color to Brand 1" … "Greyscale 9"; page 2: "Set Space color to Brand 1 gradient" |

### 5.7 Intensity slider

| Property | Value |
|---|---|
| Track | capsule 224 × 16, `ThemeEditorColors.trackFill` (white ≈ 0.08) |
| Wave | slider-local `y = 28 − 14.8·value·sin(2π(x − 7.8)/37.9)`, x 7.8…216.2. Flat at value 0. Stroke 4.5 pt round caps. Left of thumb `waveActive`, right `waveInactive`, with disjoint masks. Empty state: default value 0.8, all inactive. |
| Thumb | white capsule, rest sizes interpolated through value 0: 12.2×44.4, 0.8: 24.4×56.0, 1: 27.05×59.15 pt. At 0 the measured hovered 13.25×48.4 is unscaled by 1.09 to get the rest fit. Hover/press ×1.09. Downward y +2 / radius 2 / alpha 0.06 shadow: white in dark, black in light. No normal outline or top halo. Empty: no thumb. |
| Value | 0…1; thumb center panel x = `38.8 + 208.4·value`, content x = `25.8 + 208.4·value`, slider-local x = `7.8 + 208.4·value`; input uses the same mapping |
| Interaction | mouse down on the track jumps the thumb, then drags; scroll wheel ± 0.02 per line; keys ←/→ ± 0.05 |
| Label / tooltip | "Intensity" |
| Live | preview per frame; commit on mouse up. Scroll phase plus momentum is one undo step, finished at momentum end; an 80 ms phase-end grace allows momentum to begin. Phase-free wheel mice finish after 150 ms idle. |

Historical calibration decision, **superseded by round 3 below** (2026-10-26 01:43:21 and 01:43:54
America/Vancouver): F0137 and F0138 place the 24 × 56 pt thumb at panel
`(193,437)`, hence content center x = 192 at value 0.8. The earlier
`30 + 200·value` mapping was a guess and drew it 2 pt too far left.
That historical fit used `32 + 200·value` and 200 pt travel. Round 3
replaces drawing and input together with the wave-span law in the table
above; track capsule and AX hit frame remain fixed.

### 5.8 Noise dial

F0137/F0138 calibration, per the same lead decision: draw the dial around
content `(298,452)` inside the unchanged `(258,412,84,80)` AX hit frame.
The earlier `(300,452)` art center was a guess based on the AX center;
it drew the tick 2 pt too far right. Ring, tick, center preview, and angle
input all use the calibrated art center.

| Property | Value |
|---|---|
| Ring | 20 dot slots at an 18° pitch, radius 32.0, dot 5.0 pt. Unlit `dotUnlit` (white ≈ 0.15), lit `dotLit` (white ≈ 0.5). Slot `k` (0…19, clockwise from 12 o'clock) is lit when `k·18° ≤ noise·360°`. Hide only the nearest slot using non-wrapping distance over 0…342° and a 9° tolerance. At noise 0.98 hide none; at exactly 1 hide coincident slot 0. Lead decision 2026-10-26 09:56:38 America/Vancouver. |
| Tick | white capsule 8×16 pt, center snapped to the backing pixel grid; angle `noise×360°` clockwise from 12 o'clock. No normal light outline. Downward y +2 / radius 2 / alpha 0.06 shadow, on an unrotated layer with a rotated path. Empty: no tick, all 20 dots unlit. |
| Center | 40 pt disc. Noise 0: 1 pt ring, no fill or composition. Grain preview: source gray about 91 at alpha 0.29, raw top/bottom shade ±19 (about ±5.5 after composition). Sand/denim/tweed: nearly opaque mean gray 139/147/127, own procedural art, target standard deviation about 7.7/5.0/4.9. Tweed preview is a soft mottle; Space tiles remain Step 9 work. |
| Click center | none → grain → sand → denim → tweed → none. Each texture sets noise exactly 0.80; none sets 0 and retains the last texture internally. One undo restores both texture and noise. Tooltip "Cycle noise texture". |
| Drag on ring | noise = angle / 360°, clamped 0…1; a jump of more than 0.5 between ticks clamps to the nearer end (no wrap); input within 1e−6 of zero snaps to exact none |
| Click a dot | inside a 3 pt radius, noise snaps to `k × 0.05`; between dots, keep the pressed angle continuous |
| Scroll wheel | ± 0.01 per line (**guess**); phase and momentum commit once per gesture, with the same wheel idle fallback as the slider |
| Trackpad rotate | `rotation` degrees / 360 (Arc `NoiseFactorGesture.rotation`) |
| Keys | ←/→ ± 0.05 |
| Label | "Noise" |

Session 2 supersedes the R1 alpha-0.35 guess: empty controls use normal
track/dot intensity, with the thumb and tick absent and no input mutation.
Light harness renders use FCFBFC. AX hit frames and the dial art center stay fixed.

### 5.9 Color tokens (`OpenDesign/ThemeEditorTokens.swift`, new)

Dark values use F0137 and session 2. Light values are calibrated from
session 2 item 20 frame 0027 and item 17 frames 0158–0159. Harness backdrops
are `2E3237` (dark session 2) and `FCFBFC` (light); private captures stay local.

| Token | Dark | Light |
|---|---|---|
| `padFill` | white 0.04 | black 0.055 |
| `dot` | white 0.20 | black 0.14 |
| `knobRing` | white 1.0 | white 1.0; no normal outline |
| `glyph` | white 0.50 | black 0.50 |
| `glyphSelected` | white 0.50 | black 0.50 |
| `selectedPlate` | white 0.10 | black 0.10 |
| `hoverPlate` | white 0.11 | black 0.11 |
| `secondaryText` | white 0.90 | black 0.74 |
| `trackFill` | white 0.08 | black 0.085 |
| `waveActive` | white 0.53 | black 0.40 |
| `waveInactive` | white 0.15 | black 0.15 |

| `thumb` | white 1.0 | white 1.0; no normal outline |
| `dotUnlit` / `dotLit` | white 0.15 / 0.50 | black 0.15 / 0.40 |

### 5.10 Motion (PROVISIONAL tokens in `Motion`)

| Token | Value | Evidence |
|---|---|---|
| `editorOpen` | scale 0.66 → 1 from the panel's leading-top corner, spring response 0.25, damping 0.85; alpha 0 → 1 over 0.12 s | A0465 → A0466 (66 % one frame before full) |
| `editorClose` | alpha → 0 over 0.12 s, scale → 0.96 | **guess** |
| `themeLive` | no animation (instant) during a drag | Open choice (§9.1) |
| `themeDiscrete` | `Motion.themeCrossfade` (0.21 s linear) for preset, mode, add/remove, texture, undo/redo | existing token |
| `presetPage` | `Motion.spaceSwitch` | **guess** |
| Reduce Motion | open/close become a 0.12 s fade; preset paging is instant; knob scales are off | macOS setting |

### 5.11 Keyboard

| Key | Action |
|---|---|
| Esc | close the panel |
| Cmd+Z / Shift+Cmd+Z | undo / redo through the browser window's undo manager (the panel forwards `undo:` / `redo:`) |
| Tab / Shift+Tab | focus order: mode buttons → pad → Remove → Add → previous → swatches → next → slider → dial center → dial |
| Space / Return | activate the focused button or swatch |
| Arrows | §5.3, §5.7, §5.8 |

### 5.12 Accessibility

- Panel role `popover`, label "Edit Theme".
- Mode buttons: a radio group "Appearance" with "Automatic", "Light", "Dark".
- Pad: adjustable element "Color", value "Hue 44°, lightness 27 %";
  increment / decrement change hue by 5°.
- Knob count is announced on Add / Remove ("2 colors").
- Slider "Intensity" and dial "Noise": `AXSlider` with percent values; the
  dial center is a button "Cycle noise texture" with value = texture name.
- Swatches: §5.6. Increase Contrast: rims and plates gain a 1 pt
  `glyph`-colored stroke.

## 6. New Space form

### 6.1 Placement and lifecycle

1. Entry (§8) asks `BrowserWindowController.beginSpaceCreation(options:)`.
2. The sidebar pager appends a temporary trailing page that hosts
   `SpaceCreationView` and slides to it (`Motion.spaceSwitch`). The bottom
   switcher shows no new dot until the Space exists.
3. The window background shows the draft theme (live, §9). Other windows do
   not change (the draft is not in the model).
4. Create → §6.4. Cancel or Esc → slide back to the previous Space; the
   background cross-fades back; nothing changes in the model.
5. A second entry while a form is open focuses the existing form.

`SpaceCreationOptions` (Open): `insertionIndex: Int?` (default: end; §15 Q7),
`moving: [ItemID]` (tab menu "Move to ▸ New Space…" and folder "Turn into
Space"), `prefillTitle: String?` (the folder name for "Turn into Space").

### 6.2 Layout

Width class from the sidebar width `W` (content width `W − 16`):
compact `< 190`, medium `190 ..< 227`, full `≥ 227` (Arc breakpoints).
Values below are for full; compact and medium changes follow the table.
Vertical layout starts 16 pt below the URL field (**guess**) and scrolls when
taller than the page.

| Element | Spec (full) | Compact / medium |
|---|---|---|
| Header cards | 3 fanned cards, 80 × 80 primary (radius 20) showing the chosen icon (emoji 36 pt or symbol 32 pt; placeholder: our own smiley glyph); 2 back cards 60 × 60 rotated −16° and +20°, offset (−15, −3) and (+18, −6) (constants ±0.279 rad, ±0.349 rad, −15, −18, −3, −6; mapping **guess**) | medium: back cards hidden; compact: primary 60 × 60 |
| Title | "Create a Space", 17 pt Semibold, the draft theme's `title` color for its content appearance (**guess**) | 15 pt |
| Subtitle | "Separate your tabs for life, work, projects, and more.", 13 pt Regular, secondary text; uses the two-line variant ("…for life,\nwork, projects, and more.") | same |
| Name card | height 44, radius 10, fill `SidebarRole.fieldFill`; icon button 32 × 32 at x 6 (opens §7); text field 14 pt, placeholder "Space name" | same |
| Theme card | height 44, label "Choose a Theme" 13 pt Medium; trailing 24 pt preview swatch (single color, or the page-2 swatch art for 2–3 colors); click opens §5 | same |
| Profile card | label "Profile" 13 pt Medium; `info.circle` 12 pt with tooltip "You can use a Profile to give this Space its own logins, history, and browsing data."; trailing pop-up: Profile name + `chevron.down`. Menu: Profiles · separator · "New Profile…" | info button hidden in compact |
| Card gap | 8 pt; side insets 8 pt | 6 pt |
| Create button | "Create Space", height 32, radius 8, fill = draft theme `semantic.light.focus` (dark content: `dark.focus`), title 13 pt Semibold; press scale 0.98 | same |
| Cancel | "Cancel", plain text button 13 pt, secondary text | same |
| Submit placement | inline under the cards when it fits; otherwise pinned to the page bottom 12 pt above the bottom bar (Arc `VisibileSubmitButton`) | same |

Card entrance: stagger 0.03 s per card (header, name, theme, profile,
buttons), each fading in and rising 6 pt over 0.2 s ease-out (constants
0.03 / 0.06 / 0.09 / 0.12 in the module; role **guess**).

### 6.3 Behavior

- The name field has focus on appear. Return creates. Esc cancels.
- An empty or all-space name creates an untitled Space ("Space N", existing
  `displayTitle`).
- Draft defaults: no icon; no theme (`SpaceTheme()`, `style == nil`) unless
  the user picks a color in the New Space form (§15 Q2, capture session 2).
  Profile = the focused Space's Profile (`SpaceCreationProfilePickerModel`
  default).
- "New Profile…" switches the Profile card into the existing inline
  create-Profile mode of `SpaceCreationProfilePickerModel` (name field +
  validation messages from `ProfileNameIssue.message`).
- The theme editor opened from the form edits the draft, not the model. Its
  undo stack is the form's local undo (Cmd+Z inside the form), discarded on
  cancel.

### 6.4 Create

1. `model.createSpace(title:profileID:icon:theme:at:moving:)` (§10.1), one
   undo step; the controller names it "New Space".
2. Splash: a circle filled with the draft `midTone` grows from the Create
   button's center to cover the sidebar column over 0.5 s ease-out while its
   opacity goes 1 → 0 in the last 0.2 s (Arc `SplashView`: color, blur, opacity;
   timing **guess**). Reduce Motion: a 0.2 s cross-fade.
3. The temporary page is replaced by the new Space's page; the window focuses
   the new Space; the bottom switcher shows its dot.
4. Undo deletes the Space and refocuses the previous one (existing
   `deleteSpace` undo semantics).

## 7. Icon and emoji picker

### 7.1 Container

Same panel class and material as §5.1. Anchored below the clicked icon
(Space header icon, creation icon button, tab or folder row icon), leading
edges aligned, 6 pt gap; flips above when there is no room. Size: width
`2·10 + 7·28 + 6·5 = 246` pt (7 columns, constant 7 in the module, **guess**),
height 300 pt (**guess**).

### 7.2 Header and pages

- Segmented control at the top, 8 pt inset: "Emoji" | "Icons". Default page:
  Emoji for Spaces and tabs, Icons for folders (**guess**).
- "Remove icon" text button at the bottom-leading corner when the target has
  an icon (Arc `canRemoveIcon`).

### 7.3 Icons page

Grid of the 55 `NamedSpaceIcons` identifiers in a new
`NamedSpaceIcons.order: [String]` array that lists them in the source
file's order. That order follows Arc's raw-value strings in the binary
(`design-tokens.md` "Named Space icons"). The positions of `bookmark`,
`server`, `folder`, `document`, `chatBubbleEllipses`, `video`, `github`,
`linear`, and `figma` are **guesses** (the linker merged those strings).
Cell 28 × 28, glyph 17 pt medium, spacing 5, side insets 10. Glyph color: `SidebarRole.spaceTitle`. Hover: radius 6 plate
`SidebarRole.rowHover`. Selected: radius 6 plate `SidebarRole.rowSelected`.
Folders use the same set (§15 Q8). Click stores `.named(id)`.

### 7.4 Emoji page

| Part | Spec |
|---|---|
| Search | `NSSearchField`, placeholder "Search", 8 pt insets; filters by name and keywords, debounce 80 ms |
| Grid | `NSCollectionView`, flow layout: item 28 × 28, item gap 5, line gap 2, side insets 10; emoji 20 pt in `AppleColorEmoji` |
| Categories | bottom bar 28 pt with a 1 pt top hairline: Smileys & People, Animals & Nature, Food & Drink, Activities, Travel & Places, Objects, Symbols, Flags; our own SF Symbol buttons; click scrolls to the section; the visible section is highlighted |
| Skin tones | press and hold 0.4 s (or Control-click) on an emoji with variants opens a small panel with 6 tones in a row; pick stores the toned string |
| Data | `OpenSpaceEditor/Resources/emoji-index.json`, generated by `tools/gen-emoji-index.py` from Unicode `emoji-test.txt` (fully-qualified only), version and SHA-256 pinned in the script (§15 Q1). Never copy Arc's `emojis.json`. |

### 7.5 Apply

- Space: `model.setSpaceIcon(id:icon:)`; action name "Customize Space".
- Tab: `model.setNodeIcon(id:icon:)`; "Customize Tab". Folder: same;
  "Customize Folder".
- The picker closes on pick. "Remove icon" sets `nil`.

## 8. Entry points

| Entry | Where | Opens / does |
|---|---|---|
| Spaces ▸ New Space… (`new-space`) | menu bar, command bar | §6 in the key window |
| Plus button ▸ New Space… | bottom bar | §6 |
| Tab ▸ Move to ▸ New Space… (`moveToNewSpace`) | tab context menu | §6 with `moving: [tab]` |
| Folder ▸ Turn "<folder>" into Space (`turnFolderIntoSpace`) | folder context menu | §6 with `moving: folder children`, `prefillTitle: folder title`; on create the empty folder is removed in the same undo step |
| Spaces ▸ Rename Space (`rename-space`) | menu bar, command bar | inline header rename when the sidebar is visible; otherwise a dialog with a text field and "Rename" / "Cancel" (§15 Q11) |
| Space menu ▸ Rename Space… | Space context menu | inline header rename (exists) |
| Spaces ▸ Edit Theme… (`edit-theme`) | menu bar, command bar | §5 for the focused Space |
| Space menu ▸ Edit Theme Color… (`editSpaceTheme`) | Space context menu, switcher context menu | §5 for that Space (focus it first if it is not focused) |
| Space menu ▸ Change Space Icon… (`changeSpaceIcon`) | Space context menu | §7 anchored to the header icon |
| `change-space-icon` (new, code-only, aliases "Space Icon", "Change Icon", "Emoji") | command bar | §7 for the focused Space |
| Tab / folder ▸ Change Icon… (`changeIcon`) | row context menus | §7 anchored to the row icon |
| Spaces ▸ Change Profile (`change-profile`) | menu bar, command bar | a Profile menu at the Space header (Profiles, separator, "New Profile…"); a pick runs the existing `ChangeProfileRequest` warning flow |
| Space menu ▸ Set Profile ▸ | Space context menu | exists (`setSpaceProfile`) + the same warning flow |
| Bottom-bar Space icon, right-click | Space switcher | the Space context menu for that Space (**guess**; not captured) |

All menu items for a Space other than the focused one act on that Space.
`isCommandEnabled`: all always enabled except `rename-space`, `edit-theme`,
`change-space-icon`, `change-profile` with no focused Space (never in a
normal window).

## 9. Live propagation, persistence, and undo

### 9.1 Live preview

- `ThemeEditSession` (one per open editor) holds `spaceID`, `baseline:
  SpaceTheme` (value before the current gesture), and `draft: SpaceStyle`.
- Each change sets `draft`, then requests a frame. On the next display-link
  tick (the panel's `CADisplayLink`), it calls
  `model.previewSpaceTheme(id:theme:)` once with `SpaceTheme(style: draft)`.
  At most one model write per frame.
- `previewSpaceTheme` assigns `space.theme` without undo and without a tree
  event. Observation reaches every `SidebarView` that shows the Space.
- `SidebarView.syncTheme()` gains a non-animated path: when
  `context.isLiveThemePreview(spaceID)` is true (set by the window
  controller through a shared `ThemePreviewRegistry` keyed by Space id), it
  calls `crossfade(to:animated: false)`. `ThemeBackgroundView` already
  coalesces the field rebuild to one per display frame.
- Windows on other Spaces do nothing: they never read that Space's theme.
- The form (§6) previews only its own window: it sets the window's
  background style directly and never writes the model.

### 9.2 Commit and undo

- Gesture end (mouse up, key press, preset, mode, add / remove, texture
  click): `model.commitSpaceTheme(id:from: baseline)` registers one undo step
  from `baseline` to the current value; the controller sets the action name
  "Update Theme"; the app's existing debounced `scheduleSave()` runs. Then
  `baseline` = current value.
- Undo / redo while the panel is open restores the exact paired in-session
  state: style, knob, lightness range, and saturation (Step 9 lead decision,
  2026-10-26 17:14). Other external theme changes reseed the state (§4.3).
  Knobs do not animate; the background uses `themeDiscrete`. The range is
  never written to disk. Reopening derives it from the key per §17.1.
- Closing the panel mid-drag (Esc during a drag) commits first.
- App quit with the panel open: `applicationWillTerminate` closes panels,
  which commits.

### 9.3 Performance budget

| Item | Budget |
|---|---|
| Drag tick, main thread, 2 windows on the Space | p95 ≤ 4 ms (palette derivation + field rebuild + sidebar invalidation) |
| Palette derivation | ≤ 0.2 ms (≤ 3 × 100 band steps of pure math) |
| Field rebuild | existing 64 × 64 image, once per frame per window |
| Texture tile | generated once per (texture, noise bucket, scale); never during a drag tick except the first use |
| Editor closed | zero timers, zero display links |

## 10. API

### 10.1 `BrowserModel` (OpenModel) additions

```swift
/// Live value for an open editor. No undo, no event, no save.
public func previewSpaceTheme(id: SpaceID, theme: SpaceTheme)
/// One undo step from `baseline` to the current theme. False (no step) when equal or missing.
@discardableResult public func commitSpaceTheme(id: SpaceID, from baseline: SpaceTheme) -> Bool
/// One undo step. Same-value: no step.
public func setSpaceIcon(id: SpaceID, icon: SpaceIcon?)
/// Tabs and folders. Writes iconOverride, clears legacy customIcon. One undo step. False when not a tab or folder.
@discardableResult public func setNodeIcon(id: ItemID, icon: SpaceIcon?) -> Bool
/// Empty or whitespace-only → nil (untitled). One undo step.
public func renameSpace(id: SpaceID, title: String)
/// Extends createSpace: insertion index (nil = end) and nodes moved into the new Space's
/// pinned section in order (folders keep their children). One undo step for all of it.
@discardableResult public func createSpace(title: String, profileID: ProfileID, icon: SpaceIcon?,
    theme: SpaceTheme, at index: Int?, moving nodeIDs: [ItemID]) -> Space?
```

Lead amendment (2026-10-25): creation with moves is all or nothing. Before
any mutation, validate that every moving node exists, is not a split pane,
occurs only once, and satisfies the placement rules in `docs/model.md`
(including no move into its own descendant). An explicit insertion index
must be in `0...spaces.count`. On any refusal return nil: no Space, moves,
undo, TreeChange, or snapshot dirty state. After validation, create and move
the nodes as one undo step. An empty moving list with a valid index and a
live Profile ID never fails.

Lead review amendment (2026-10-26, Step 1 round 1): refuse a moving list
that includes both an ancestor and its descendant. If any relocation fails
after insertion, reverse the earlier moves and remove the inserted Space,
then return nil. Buffer structural events until success, so a rollback emits
none. The real CLI exercises a forced late failure and checks snapshot
bytes, undo depth, and the index. Success emits one `.move` per node, no
source-parent reload, and has byte-identical undo and redo snapshots.

Lead review decision (2026-10-26 09:36 America/Vancouver): unknown Profile
IDs refuse the failable overload before any mutation, undo, event, or save.
The existing nonoptional `createSpace(title:profileID:icon:theme:)` requires
a live Profile ID, delegates with `at: nil, moving: []`, and treats nil as
a programmer error with a precondition naming the bad ID. Data/import/
automation/restored-state callers use the failable overload. The caller
audit changed the Settings selector, profiles CLI, and automation boundary;
the remaining callers obtain IDs from live model objects or synthetic
fixtures. Rollback fault injection is DEBUG-only, absent in production.
Step 7's
`moveToNewSpace` and `turnFolderIntoSpace` likewise return false or nil on
refusal and change nothing.

Step 1 acceptance adds refused create-with-moves rows to
`openkit commands-demo`: both a split pane and a missing ID leave the
snapshot byte-identical and the undo stack depth unchanged. Model rules
from `docs/model.md` apply to every refusal.

### 10.2 `OpenSpaceEditor` (new library)

```swift
@MainActor public final class ThemeEditorController {
    public init(model: BrowserModel, spaceID: SpaceID, window: NSWindow,
                anchor: ThemeEditorAnchor)
    public init(draft: SpaceStyle?, window: NSWindow, anchor: ThemeEditorAnchor,
                onChange: @escaping @MainActor (SpaceStyle?) -> Void)   // creation form
    public func show()
    public func close()
    public var onClose: (@MainActor () -> Void)?
}
public enum ThemeEditorAnchor { case sidebarTrailingEdge(sidebarFrameInWindow: CGRect), card(CGRect) }

@MainActor public final class IconPickerController {
    public init(target: IconTarget, current: SpaceIcon?, window: NSWindow, anchor: CGRect,
                onPick: @escaping @MainActor (SpaceIcon?) -> Void)
    public func show(); public func close()
}
public enum IconTarget { case space, tab, folder }

@MainActor public final class SpaceCreationController {
    public init(model: BrowserModel, windowID: WindowID, options: SpaceCreationOptions)
    public var view: NSView { get }                       // hosted as a sidebar page
    public var onFinish: (@MainActor (Space?) -> Void)?   // nil = cancelled
    public var onDraftStyle: (@MainActor (SpaceThemeStyle) -> Void)?
}
public struct SpaceCreationOptions: Sendable { public var insertionIndex: Int?; public var moving: [ItemID]; public var prefillTitle: String? }

/// The editor's state machine; views render it. Pure, so the harness can drive it.
public struct ThemeEditorState: Equatable, Sendable {
    public var style: SpaceStyle?            // nil = empty state
    public var presetPage: Int                // 0...4
    public var isGestureInProgress: Bool
    public mutating func apply(_ action: ThemeEditorAction)
}
public enum ThemeEditorAction: Equatable, Sendable {
    case dragKnob(to: CGPoint, relative: Bool), endDrag
    case selectPreset(index: Int), setPresetPage(Int)
    case addColor, removeColor
    case setAppearance(SpaceStyleAppearance)
    case setIntensity(Double, final: Bool)
    case setNoise(Double, final: Bool), cycleTexture
    case keyboardHue(Double), keyboardRadius(Double)
}
```

### 10.3 `OpenSidebar` additions

```swift
extension SidebarView {
    public func beginSpaceCreation(page: NSView)          // appends and slides to a temporary page
    public func endSpaceCreation(focus: SpaceID?)         // removes it; slides to `focus` or back
    public func headerIconFrame(for space: SpaceID) -> CGRect?  // window coordinates, for anchoring
    public func rowIconFrame(for node: ItemID) -> CGRect?
}
extension SidebarContext { public var livePreviewSpaces: Set<SpaceID> }  // set by the window controller
```

### 10.4 `OpenFeatures.BrowserWindowController` additions

Handle the intents and commands in §8; own at most one
`ThemeEditorController`, one `IconPickerController`, one
`SpaceCreationController`; set undo action names (D-11).

### 10.5 Automation (`App/Automation/AutomationController.swift`)

| Command | Arguments | Returns |
|---|---|---|
| `theme-get` | `space` | stored `style` JSON (or null), derived palette hex, `contentAppearance` |
| `theme-set` | `space`, `style` JSON | applies through the session path (one undo step) |
| `editor-open` | `kind`: `theme` / `icon` / `create`, `space` or `node` | `true` |
| `editor-act` | `action` (`drag` with `from`/`to` in content pt, `click` at a named control, `key`) | `true`; synthesized `NSEvent`s sent through `NSApplication.sendEvent` to the panel (never the desktop) |
| `editor-close` | — | `true` |
| `command` | `id` | runs `performCommand(id)` on the key window, the same path as the menu item; `false` when disabled |
| `snapshot` (extend) | `window: "editor"` | PNG of the open panel |

## 11. Files

Create:

```text
Packages/OpenKit/Sources/OpenDesign/ThemeColorMath.swift
Packages/OpenKit/Sources/OpenDesign/ThemeTexture.swift
Packages/OpenKit/Sources/OpenDesign/ThemeEditorTokens.swift
Packages/OpenKit/Sources/OpenDesign/SpaceStylePresets.swift          // 45 presets, §2.3
Packages/OpenKit/Sources/OpenSpaceEditor/ThemeEditorState.swift
Packages/OpenKit/Sources/OpenSpaceEditor/ThemeEditorController.swift
Packages/OpenKit/Sources/OpenSpaceEditor/ThemeEditorPanel.swift      // also used by the icon picker
Packages/OpenKit/Sources/OpenSpaceEditor/ColorPadView.swift
Packages/OpenKit/Sources/OpenSpaceEditor/AppearanceModeBar.swift
Packages/OpenKit/Sources/OpenSpaceEditor/PresetStripView.swift
Packages/OpenKit/Sources/OpenSpaceEditor/SineSliderView.swift
Packages/OpenKit/Sources/OpenSpaceEditor/NoiseDialView.swift
Packages/OpenKit/Sources/OpenSpaceEditor/ThemeEditSession.swift
Packages/OpenKit/Sources/OpenSpaceEditor/IconPickerController.swift
Packages/OpenKit/Sources/OpenSpaceEditor/EmojiGridView.swift
Packages/OpenKit/Sources/OpenSpaceEditor/IconGridView.swift
Packages/OpenKit/Sources/OpenSpaceEditor/EmojiIndex.swift
Packages/OpenKit/Sources/OpenSpaceEditor/Resources/emoji-index.json
Packages/OpenKit/Sources/OpenSpaceEditor/SpaceCreationController.swift
Packages/OpenKit/Sources/OpenSpaceEditor/SpaceCreationView.swift
Packages/OpenKit/Sources/space-editor-render/main.swift              // harness, §12
Packages/OpenKit/Sources/space-editor-render/Checks.swift
Packages/OpenKit/Sources/space-editor-render/Compare.swift
Packages/OpenKit/Sources/space-editor-render/Scenes.swift
tools/gen-emoji-index.py
```

Edit: `Package.swift` (target `OpenSpaceEditor` → `OpenModel`, `OpenDesign`,
resource `emoji-index.json`; `OpenFeatures` adds `OpenSpaceEditor`;
executable `space-editor-render` → `OpenModel`, `OpenStore`, `OpenDesign`,
`OpenSidebar`, `OpenSpaceEditor`), `OpenModel/Theme.swift`,
`OpenModel/LiveNodes.swift`, `OpenModel/BrowserModel.swift`,
`OpenStore/SnapshotDTOs.swift`, `OpenImport/ArcImport.swift`,
`OpenDesign/SpaceThemeStyle.swift`, `ThemeField.swift`,
`ThemeBackgroundView.swift`, `Motion.swift`, `OpenModel/NamedSpaceIcons.swift`
(`order` array), `OpenSidebar/SidebarView.swift`,
`SpacePagerView.swift`, `SidebarContext.swift`, `Controls.swift` (icon
precedence), `SidebarRows.swift` (Step 1: folder and tab icon resolution;
lead-approved addition), `SpacePageView.swift`, `OpenCommands/CommandRegistry.swift`
(`change-space-icon`), `SuggestAdapter.swift` (its symbol `face.smiling`),
`OpenFeatures/BrowserWindowController.swift`,
`App/Automation/AutomationController.swift`, `tools/e2e/engine_e2e.py`,
`tools/verify-all.sh` (add `space-editor`), `docs/release/licenses.md` (emoji data row, Step 6), `docs/model.md`,
`docs/design.md` (new §: editor), `docs/commands.md`.

Step 1 review additions: `sidebar-render/OffscreenRenderer.swift` synchronizes
render and readback on one Metal queue for P1. `Fixtures/space-schema1/`
holds the frozen synthetic schema-1 snapshot and its three pre-change PNGs;
the `space-legacy` entry in `tools/verify-all.sh` and
`tools/verification/check.py` gate their round trip and byte equality.

## 12. Verification (no unit tests)

### 12.1 Harness `space-editor-render` (offscreen, `sidebar-render` style)

Same method as `docs/design.md` §6: offscreen borderless windows, never
shown, layer tree rendered by `CARenderer`, PNG out.

```text
space-editor-render editor   --out FILE.png [--scale 1|2] [--appearance dark|light]
                             [--style JSON] [--page N] [--hover CONTROL] [--backdrop RRGGBB]
space-editor-render window   --out FILE.png --snapshot DIR|--synthetic [--space N] [--style JSON]
                             [--size 2216x1394] [--width 228]           # sidebar + background with a style
space-editor-render create   --out FILE.png [--width 180|200|228|300|500] [--appearance dark|light]
space-editor-render picker   --out FILE.png --page emoji|icons [--target space|tab|folder]
space-editor-render math     [--arc-json FILE]   # derived vs stored palettes, prints max errors
space-editor-render compare  --arc CAPTURE.png --ours RENDER.png --spec editor|window --out DIR
space-editor-render check    # all checks below; exit ≠ 0 on any failure
space-editor-render bench    # B1
```

`tools/verify-all.sh` gains `space-editor` = `space-editor-render check`.

### 12.2 Checks (`space-editor-render check`)

| ID | Check |
|---|---|
| M1 | The committed fixture is the example theme in `runtime-observations.md` §3.3 (key `#FF8558`): our primary palette within 1/255 and both semantic palettes within 0.003 of the listed values. With `--arc-json FILE` (a local read-only copy of `StorableSidebar.json`, never committed) the same check runs over every stored theme and prints only counts and max errors. |
| M2 | Harmony: analogous and complementary, n = 1…3, hue offsets within 0.1°, S and L unchanged. |
| M3 | Pad round trip: 2,000 seeded random colors inside each mode's range: color → knob → color within 1/255. |
| M4 | Appearance: forced Light / Dark always win for 500 random keys. Automatic with bias 0 gives light, light, light, dark for the key colors `#FF8558`, `#2F83E4`, `#F8D558`, `#926400` (extended sRGB; the 4 stored samples, colors only). |
| E1 | Editor layout: every control frame equals §5.2 within 0.5 pt at 1x and 2x. |
| E2 | Drag: synthesized mouse down / drags / up on the pad: knob follows (relative on the knob, jump elsewhere), previews ≤ 1 per frame, one undo step on mouse up; undo restores the theme and moves the knob; redo repeats. |
| E3 | Add / remove: 1 → 2 → 3 (Add disabled at 3); background layout per §2.1; remove to 0 → theme = `SpaceTheme()`, empty state shown; undo restores the full old value. |
| E4 | Presets: 5 pages, arrows disabled at the ends, a click sets key / count / wheel per §2.3, page 2 gives 3 analogous colors. |
| E5 | Modes: Dark → range 0.01…0.425, knob radius kept, content appearance dark; Light → 0.575…0.97; Automatic → the §2.1 rule. |
| E6 | Slider and dial: value ↔ geometry, texture cycle order, dot-click snap to 0.05 steps, no wrap past the ends, scroll steps. |
| E7 | Live propagation: 2 window scenes on the same Space and 1 on another; a drag changes both same-Space backgrounds and sidebar title colors in the same frame; the third is unchanged; no cross-fade animation during the drag; one cross-fade on a preset click. |
| E8 | Close triggers: Esc, outside click, Space switch, Space delete. Esc mid-drag commits. |

**Step 5 hard gate:** do not ship `edit-theme` wiring until E8 verifies
outside click, app deactivation, Space switch, and Space delete all close
the panel. These triggers remain deferred here, not waived.
| C1 | Form at widths 180 / 200 / 228 / 300 / 500: width class, card frames, submit placement. Return creates (title, icon, style, Profile, focus); Esc cancels with no model change and no undo step; undo of create removes the Space. "Move to ▸ New Space…" moves the tab; "Turn into Space" moves children and removes the folder in one step. |
| I1 | Picker: pages, search filter, a pick stores `.emoji` / `.named`, "Remove icon" stores nil, folder default page Icons. |
| P1 | Persistence: snapshot round trip with `style` and `iconOverride`; a fixture snapshot written before Step 1 decodes and renders byte-identical PNGs (`window` scene) before and after this plan. |
| B1 | Bench: 240 drag ticks with 2 window scenes: main-thread time per tick p95 ≤ 4 ms; field rebuilds ≤ 1 per frame per window; zero texture tile generations after the first tick. |

### 12.3 Render comparison against Arc captures

Captures (local only, `.re/`; contain personal data; view, never commit, never
crop into the repo): F0137 (editor, one olive color, Automatic, noise 0),
F0138 (noise 0.45, sand-like preview), F0139 / F0141 (the Space after the
edit), the `analysis-20261024/c-theme.png` sheet (the same frames).

Method (`docs/design.md` §7): render `editor` with the captured state
(`--style` = the session1 Space 4 values: key `#926400`, count 1, Automatic,
noise 0 or 0.45, intensity 0.8, texture grain), scale 1, and
`--backdrop 797979` (the measured material color over the captured page;
the offscreen renderer cannot reproduce behind-window blur). Crop the panel
from the capture at AX `[500, 35, 382, 534]`.

| Element | Target | Note |
|---|---|---|
| Control frames (mode buttons, pad, knob, Remove / Add, arrows, 9 swatches, slider thumb, dial tick) | ≤ 1 pt | from AX and ink bounds |
| Knob disc, knob ring, swatch fills, thumb, dial tick, dial center fill, dial dots | ΔE00 ≤ 2 | controls; dial uses the stricter limit per the Step 4 lead decision |
| Pad plate, mode plate, dot grid, wave | ΔE00 ≤ 3 | translucent over material; the 3 is stated in the PR |
| Dial tick angle (F0138) | ± 2° | 162° expected |
| Lit dot count (F0138) | exact (9) | |
| Window background + sidebar after edit (F0139 / F0141) | `docs/design.md` §8 targets (≤ 1 pt, ΔE00 ≤ 2) | via `space-editor-render window` with the stored style |

R1 follow-up (2026-10-26): compare the inset material body edges and
continuous corner contours as well as the existing controls. The slider
wave rises first and its dim layer starts at the thumb center. The dial
uses non-wrapping dot suppression (no hidden dot at 0.98), per the lead's
09:56:38 decision. F0138 still masks the animated Automatic glyph; F0137
remains its calibration reference. No approved control geometry is reopened.

The creation form, the icon picker, 2–3 knobs, forced modes, page 2, and the
light appearance have no capture yet. Their checks are geometry-only until
the capture session in §15 lands; the PR lists them as "no capture".

Lead amendment, user message **2026-10-26 01:20:22 America/Vancouver**:
replacement glyph shape is exempt from the shape and edge comparison.
Mask glyph ink in those comparisons, as `docs/design.md` masks favicons and
tile icons. Rule 1 forbids copying Arc's art; SF Symbols have different
outlines. Glyph tokens still require calibration: tune point size and weight
until each ink bounding-box center and height are within 1 pt of F0137.
Compare core ink color at ΔE00 ≤ 2, changing the token when needed and citing
the capture. Report old and new tokens and measured errors in the Step 3
PR. Button frames, plates, and fills retain their normal limits.

Lead Step 4 amendment, user messages **2026-10-26 01:43:21** and
**01:43:54 America/Vancouver**: the thumb and dial are controls, so their
frames and opaque fills retain ≤ 1 pt / ΔE00 ≤ 2 limits. Calibrate their
geometry tokens to F0137 and F0138, using our own art, and report old and
new tokens and measured errors. The approved mappings are in §5.7 and
§5.8. Exclude the Automatic glyph from the F0138 comparison because that
capture catches it mid-animation; F0137 remains its glyph calibration
reference. All other F0138 controls remain compared.

Step 4 calibration, measured by `space-editor-render compare --spec editor`
against the local F0137/F0138 captures (own art only):

| Token | Old | New | F0137 error old → new | F0138 error old → new |
|---|---|---|---|---|
| Thumb center x, content pt | `30 + 200·value` | `32 + 200·value`; matching input mapping | 2 → 0 pt | 2 → 0 pt |
| Thumb start inset inside the hit frame | 12 pt | 14 pt | same thumb measurement | same thumb measurement |
| Dial art center, content pt | `(300,452)` | `(298,452)`; AX hit frame unchanged | tick 2 → 1 pt | tick 2 → 1 pt |
| Dial preview base, sRGB gray | 0.78 (guess) | 0.46 | no fill at noise 0 | core ΔE00 19.89 → 1.16 |

Thumb size remains 24 × 56 pt and travel 200 pt; dial tick remains
7.5 × 15.5 pt. Thumb and tick core ΔE00 are 0.00 in both frames. F0138's
tick angle is 162.04° in the capture and 161.92° in Open, with exactly nine
lit dots in each. Previous/Next glyphs use 16 pt Medium instead of 13 pt:
height error 3 → 0 pt, center error ≤ 1 pt, F0137 core ΔE00 1.07 / 0.58.
The procedural preview base changes only the dial art, not Space textures
or their mean-darkness/cache rules. All remaining translucent colors use
the stated ΔE00 ≤ 3 bound (largest: active wave 2.13).

R1 design correction: the body is `(13,13,356,508)` with continuous radius
20 and a transparent outer band. The editor comparison now includes body
edges and four corner contours (normal distance, not horizontal distance
near a tangent). F0137 body edges are exact; corner normal error is 0.4 pt.
Remove/Add share 16 pt Semibold and `glyph`, with no Add-specific tint.
Glyph core ΔE compensates the local captured material before comparison
with the fixed gray harness backdrop, because the blue tint behind Add in
F0137 belongs to the blur, not the glyph. Raw cores stay listed in the
table. Add's raw ΔE is 2.02; material-compensated ΔE is 0.36.

Initial F0137 calibration (Step 3, before the session-2 R3 review; sizes are SF point sizes):

This table preserves the initial comparison. R3 supersedes its Remove/Add
tokens with Semibold 16 pt in the shared `glyph` color, and sets the light
glyph alpha to 0.50 with disabled factor 0.32. See the corrected R3 sampling
entry below for the current tokens and result.

| Glyph | Old token | Calibrated token | Center error x/y (pt) | Height error (pt) | Core ΔE00 old → new |
|---|---|---|---|---|---|
| Automatic | 15 pt; y offset 0; white 0.90 | 15 pt; y offset −1; white 0.50 | −0.5 / +0.5 | +1 | 9.49 → 0.61 |
| Light | 15 pt; white 0.50 | unchanged | −0.5 / +0.5 | −1 | 0.62 → 0.62 |
| Dark | 15 pt; white 0.50 | 16 pt; white 0.50 | 0 / +0.5 | −1 | 0.98 → 1.20 |
| Remove | 13 pt; white 0.50 | unchanged | +0.5 / −0.5 | −1 | 0.30 → 0.30 |
| Add | 13 pt; white 0.50 | 17 pt; sRGB (0.98, 0.98, 1), alpha 0.54 | +0.5 / −0.5 | +1 | 3.06 → 0.58 |

Historical fit, superseded by the shared glyph token: the Add tint fitted F0137's core `#C1C1C4` over the fixed
offscreen material. Light appearance remains uncalibrated. These calibrated
values supersede the corresponding values in §5.4, §5.5, and §5.9.

The `#926400` swatch above is a clipped display shorthand. The session's
extended-sRGB key is `(0.570741951, 0.392751396, −0.130948484)`, not
`(146/255, 100/255, 0)`. Retaining its negative blue component gives the
documented P3 hue 44.1186° and lightness 0.272203. The harness's default
editor scene uses those stored components. Evidence: `space-editor-render
math --arc-json <local-session1-StorableSidebar.json>` palette round trip
has zero error, and the F0137 ring box is identical at `(202,201,44,44)` in
the panel crop. No capture pixels are committed.

### 12.4 App e2e (`tools/e2e/engine_e2e.py --only space-editor`)

Runs after app-shell Step B (the real window). Fresh data dir, automation
socket only, no desktop input.

| ID | Check |
|---|---|
| A1 | `command id=edit-theme` opens the panel; `snapshot window=editor` PNG compares within §12.3 on a Space set to the F0137 style with `theme-set`. |
| A2 | Two windows on one Space: `editor-act drag` changes a background pixel sample in both window snapshots; a third window on another Space is unchanged. |
| A3 | Cmd+Z (`key route=app`) restores the previous style (`theme-get`); Shift+Cmd+Z re-applies it. |
| A4 | Quit and relaunch: `theme-get` returns the same `style`; background pixel sample within ΔE00 1. |
| A5 | `new-space` → type a name (`type`), Return → `spaces` lists it with the name, Profile, and style; undo removes it. |
| A6 | Icon picker on a tab: pick an emoji; `tabs` shows `iconOverride`; relaunch keeps it. |
| A7 | Change Profile from the Space menu shows the warning, confirm moves the Space (`spaces` Profile id changes). |

## 13. Implementation order (files + acceptance per step)

Work in order. Each step is one PR unless the table says otherwise. Before
each PR: merge `origin/main`, run `tools/verify-all.sh`, paste the summary
(`AGENTS.md` rule 10). Build: `nice -n 10 swift build -c release -j 6` in
`Packages/OpenKit`.

| Step | Work | Files | Acceptance |
|---|---|---|---|
| 1 | Model and DTOs: `SpaceStyle` and enums, `SpaceTheme.style`, `iconOverride` on tabs and folders, §10.1 commands, import writes `iconOverride`, icon draw precedence. | §11 OpenModel, OpenStore, OpenImport, `Controls.swift`, `docs/model.md` | `openkit roundtrip` PASS with the new keys; `openkit commands-demo` gains create-with-moves, preview/commit, icon steps (each: one undo step, refusals register none); P1 fixture renders byte-identical. |
| 2 | Theme engine: `ThemeColorMath`, `SpaceThemeStyle(style:)`, seeding, presets, `ThemeTexture` (4 textures), `layerAlpha(intensity:)`, `StyleCache` cap. Harness skeleton with `math`, `window`, and M1–M4, P1. | §11 OpenDesign, `space-editor-render`, `verify-all.sh` | M1–M4 PASS; `sidebar-render check` and its compare numbers unchanged (F0069 before/after recorded, §4.5). |
| 3 | Editor shell: panel, pad, knobs, mode bar, Remove / Add, empty state, `ThemeEditorState`, keyboard, accessibility. | §11 OpenSpaceEditor (panel, pad, mode, state) | E1 (those controls), E2, E3, E5 PASS; F0137 compare for pad, knob, mode buttons within §12.3. |
| 4 | Presets strip, intensity slider, noise dial, textures in the dial. | `PresetStripView`, `SineSliderView`, `NoiseDialView` | E1 (all), E4, E6 PASS; F0137 and F0138 compares within §12.3. |
| 5 | Live propagation and undo: `ThemeEditSession`, `previewSpaceTheme` path, `livePreviewSpaces` in the sidebar, window controller wiring for `edit-theme` / `editSpaceTheme`, close triggers. | `ThemeEditSession`, `SidebarView`, `SidebarContext`, `OpenFeatures/BrowserWindowController.swift` | E7, E8, B1 PASS. |
| 6 | Icon picker: panel, Emoji page (`gen-emoji-index.py`, index JSON), Icons page, Remove; `changeSpaceIcon`, `changeIcon`, `change-space-icon`. | picker files, `CommandRegistry`, `SuggestAdapter`, `BrowserWindowController` | I1 PASS; `commands-dump` exit 0 with the new id. |
| 7 | New Space form: sidebar page, cards, Profile card (+ New Profile…), theme card → editor (draft mode), splash, `moveToNewSpace`, `turnFolderIntoSpace`, rename dialog, Change Profile menu. | creation files, `SidebarView`, `SpacePagerView`, `BrowserWindowController` | C1 PASS; `create` renders at all 5 widths in both appearances. |
| 8 | App: automation commands (§10.5), e2e suite `space-editor`. Starts after app-shell Step B. | `AutomationController.swift`, `engine_e2e.py` | A1–A7 PASS. |
| 9 | Calibration: **§17 pad, intensity, and texture law (spec ready; lands before or with Step 5)**; then harmony knob art, page-2 swatch art, creation layout and timing, light appearance tokens, automatic bias. | `ThemeColorMath`, `ThemeEditorState`, `ThemeField`, `ThemeTuning`, `ThemeTexture`, views | §17.4 table PASS; §12.3 targets met on the new captures; each changed value cites its frame. |

## 14. Risks

| Risk | Mitigation |
|---|---|
| The automatic bias default (remote flag) differs from 0, so some new themes pick the other text palette than Arc would. | Data bounds it to [−0.78, 1.60). Keep it one constant (`ThemeTuning.automaticBias`); calibrate in Step 9 with a mid-luminance capture. Imported themes are not affected (they keep Arc's stored appearance). |
| The provisional intensity law worsens the F0069 compare. | §4.5 fallback: keep 0.64 for imported themes until calibrated. |
| Live preview at 120 Hz floods Observation and redraws large sidebars. | One model write per frame (§9.1); the sidebar redraws only rows whose colors changed (title, hover, selection layers). B1 enforces the budget. |
| The creation form placement guess (sidebar page) is wrong. | The form is a plain `NSView`; moving it into a sheet is a container change only. Capture first (§15 Q6) if the lead wants certainty before Step 7. |
| Emoji data licensing or size. | Generated JSON from Unicode data; a `docs/release/licenses.md` row and the license text land with Step 6; size target ≤ 400 KB; loaded lazily on first picker open. |
| P3 conversion differences between our matrices and the system converter. | Use the system `CGColor` conversion for inputs; M1 tolerance 1/255. |
| Older builds lose themes written by the editor (they ignore `style` and the legacy fields are cleared). | Accepted (no released users), stated in `docs/model.md`. |

## 15. Open questions (need a lead decision; the default ships until then)

| # | Question | Recommendation |
|---|---|---|
| Q1 | Emoji data source for the picker. | Generate `emoji-index.json` from Unicode `emoji-test.txt` (Unicode License V3, pinned version + SHA-256) with our script, and add a row for it to `docs/release/licenses.md` in the same PR. Not the macOS Character Viewer (not Arc's look) and never Arc's `emojis.json`. |
| Q2 | Which theme a brand-new Space starts with. | **Answered by capture session 2 (2026-10-26):** no theme. A new Space keeps the default theme (no stored `windowTheme`) unless the user picks a color in the New Space form. Evidence: both test Spaces made in session 2 had no `windowTheme` until the theme editor gave one a color (`docs/re/interaction-states.md` §20.0, §20.8; `appsupport/s2-final/StorableSidebar.json`; `docs/re/capture-session-2-results.md` C10). Replaces the Brand preset `spaces.count mod 9` recommendation. |
| Q3 | Automatic-mode bias (`sidebar-dark-mode-bias` is a remote flag). | 0.0. All 4 stored themes agree for any value in [−0.78, 1.60). |
| Q4 | Intensity effect. | **Answered (§17.2):** opacity `0.2 + 0.55 × intensity` (0.2 tint at 0), plus a dark wash of black 0.35 × `min(opacity, 0.5)` under it. |
| Q4 review capture detail | Intensity zero. | Capture intensity **0** explicitly and determine whether Arc keeps a visible tint. Keep Open's current gray-at-zero result and provisional law until Step 9. |
| Q5 | Page 2 of the presets. | Brand 1–9 with 3 analogous colors. Evidence: 2 of 3 stored gradients are Brand5 / Brand6 with exactly ±40°. |
| Q6 | New Space form placement. | Sidebar page (code evidence: 190 / 227 pt width breakpoints). Ask the user for a 30 s capture of "New Space…" before Step 7 if certainty is needed. |
| Q7 | Where a new Space is inserted. | At the end of the Space list for every entry point. Arc supports "after Space X"; we can switch to "after the focused Space" with one parameter. |
| Q8 | Folder icon set (`folderPicker` contents unknown). | Same 55 icons, Icons page first. |
| Q9 | Editor colors in macOS Light. | Follow the system appearance with the §5.9 light guesses; confirm with a light-mode capture. |
| Q10 | Look and drag rules of the 2nd and 3rd knobs. | Smaller (30 pt), not draggable, they follow the primary. Confirm with a capture of a 3-color theme in the editor. |
| Q11 | Spaces ▸ Rename Space behavior. | Inline header edit when the sidebar is visible; the "Rename" / "Cancel" dialog only when the sidebar is hidden. |

Capture request (one user session, recorder from `runtime-observations.md`
§7, `-i 0.2 -A` for motion): New Space form at sidebar widths 228 and 500;
the editor with 2 and 3 colors; Light and Dark modes; preset pages 2–5;
intensity at 0, 0.5, 1.0; noise textures sand, denim, tweed; the icon picker
on both pages; the same editor in macOS Light.

## 16. Verification log (fill in as steps land)

| Step | Date | Result |
|---|---|---|
| 1 | 2026-10-26 | PR #68, review round 1 fixes: commands-demo 163/163; roundtrip PASS; sidebar-render 125/125. Automated `space-legacy` gate: all original snapshot semantic fields unchanged (only main's additive `keepAliveSites: []` default is added), encoded DTO roundtrip byte-identical, all 3 committed pre-change PNGs byte-identical. Metal readback synchronization fixed; 24/24 repeated renders match the unchanged baselines. Full verify-all after merging `origin/main` at `bfef13c`: 17 PASS, no SKIP. |
| 2 | 2026-10-26 | M1–M5 and P1: 36/36. Four private stored themes: primary and semantic max error 0.000000. F0069 final PNG/table and 13 sidebar scene PNGs byte-identical to Step 1 head `2eedbfc`; sidebar-render output unchanged at 125/125. Provisional imported opacity 0.80 worsened worst ΔE00 2.38 → 2.93, so §4.5's imported 0.64 fallback stays. Lead's §4.4 base-alpha rule recorded above. Merged main at `005e065`, retaining media targets/checks and Space editor targets/checks; full verify-all 19 PASS, no SKIP; commands-demo 199/199. Main's new duplication path now preserves typed tab/folder/pane icon overrides. |
| 3 | 2026-10-26 | M1–M5, P1, E1 (shell), E2, E3, E5: 64/64. F0137: pad/mode plate/knob frames 0 pt error; glyph center/height ≤ 1 pt and core ΔE00 ≤ 1.20 under the lead's §12.3 amendment; disc 0.72, ring 0.00, translucent max 1.90. Main merged at `4ef33e9`; full verify-all 18 PASS plus opt-in `import-arc` PASS (19 checks, no SKIP). Five Open-only renders attached; designer review pending with the lead. |
| 4 | 2026-10-26 | Harness 92/92 including all E1, E4, E6. Lead geometry decision recorded in §5.7/§5.8/§12.3. F0137 and F0138 compare PASS after the main/media merge: thumb 0 pt, dial tick 1 pt, controls ΔE00 ≤ 1.20, other translucent max 2.13; F0138 Automatic excluded as mid-animation, F0137 remains its reference. Merged main `eceb683`; full verify-all with read-only Arc import: 19 PASS, no SKIP, build zero warnings/errors, commands-demo 216/216, sidebar-render 147/147 (main adds media checks), frozen schema-1 PNGs unchanged. Kept main's archive-migration gate and added typed-icon preservation through its new folder archive path. Nine Open-only renders attached for review. Steps 5–8 deferred. |
| 2 R3 | 2026-10-26 | Main `c768c38` included; release build and editor checks 48/48. Legacy field and exact-grain paths restored: all 13 sidebar capture tables byte-identical to main, zero metric drift. F0139 six-region max ΔE00 0.84. |
| 3 R3 | 2026-10-26 | Editor checks 96/96, including one-color complementary Add/undo, grey knob overlap, and forced appearance. Historical peak-method fit 0.50850 was refused; review R3 below invalidates that measurement and sets 0.50 with dot-masked, hover-matched sampling. |
| 4 R3 | 2026-10-26 | Full code head `cbac12b`: plain verify-all through heavy.sh, 20 PASS, import-arc not selected without per-run opt-in. Editor 151/151; sidebar 429/429; 13 capture tables byte-identical and CU5 2/2. F0137/F0138 and session-2 slider/page-two/preview compares PASS. Final fit check confirms zero changed pixels outside glyph host frames, but Light 0159 crosses ΔE00 1.75→4.36; candidate refused as required. Only Open render refreshes and this log follow the code gate; Steps 5–8 remain deferred. |
| 5 | | |
| 6 | | |
| 7 | | |
| 8 | | |
| 9 | 2026-10-26 | §17: 29/29 session2-pad rows; color max ΔE00 1.034, preset raster max 1 pt, texture L* sd errors ≤0.042. Editor 172/172, including exact range/saturation/knob undo and redo. Break proofs: old laws fail 31 native and 26 capture rows; missing paired undo fails the existing redo-knob and new state-restoration rows; restored source passes. Merged focused build, space-legacy, space-editor, sidebar-render, and all 13 byte-identical sidebar tables PASS. F0069 legacy/diagnostic 2.38/2.29, legacy retained; F0139 editor-style diagnostic 0.84→1.89 reported below. Full verification and review-checklist receipts are in the PR body. Steps 5–8 remain deferred. |

## 17. Step 9 calibration — decoded Arc pad, intensity, and texture law (2026-10-26)

Evidence: `docs/re/features-core.md` §2.3 item 17 (addresses, constants,
capture fit). This section is the implementation spec. It replaces the
provisional §2.2 range rule, the §4.5 opacity law, and the §4.4 / D-8
equal-darkness rule. Step 9 lands it as one PR. It must land before or
together with Step 5 (`edit-theme` wiring), per the round-3 gate. Values
are decoded facts unless marked **fit** (our fit to captures) or **guess**.

### 17.1 Pad law (`ThemeColorMath`, `ThemeEditorState`)

The lightness range and the saturation become editor state. They are not
stored in `SpaceStyle`, and they are not a function of the mode alone. Arc
does not store them either; it rebuilds them each time the editor opens.

```text
autoRange(l)   = max(0.01, l − 0.25) … min(0.97, l + 0.25)
forcedRange    = Light 0.575…0.97, Dark 0.01…0.425
widen(R, l)    = min(R.lo, l) … max(R.hi, l)
sat(key)       = max(0.01, hsl(key).s)          (P3 HSL)
```

| Event | `range` | `saturation` |
|---|---|---|
| Editor opens, no style | 0.01…0.97 | 1.0 (was 0.8: a defect, 0.8 is the default intensity) |
| Editor opens on a style, Automatic | `autoRange(l)` | `sat(key)` |
| Editor opens on a style, forced Light / Dark | `widen(forcedRange, l)` | `sat(key)` |
| `selectPreset`, Automatic | `autoRange(l of the preset key)` | `sat(preset key)` |
| `selectPreset`, forced | unchanged | `sat(preset key)` |
| `setAppearance(.light / .dark)` | `forcedRange`; key `l' = lo' + t·(hi' − lo')` with `t = clamp((l − lo)/(hi − lo))` from the **current** range; hue and saturation kept | unchanged |
| `setAppearance(.automatic)` | unchanged, key unchanged (**guess**: Arc handles it outside the reducer; no re-centering code exists) | unchanged |
| Drag, keyboard, add, remove, intensity, noise, texture | unchanged | unchanged |
| `removeColor` at count 1 (empty) | 0.01…0.97 | 1.0 |

Knob → color and color → knob keep today's formulas
(`color(at:saturation:range:)`, `knob(for:range:)`), with the state's
`range` and `saturation`. Keyboard hue keeps `l`.

Code changes:

1. `ThemeColorMath.swift`: add `autoRange(lightness:)`,
   `forcedRange(_ mode:)`, `widen(_:_:)`, and
   `editorRange(key: P3?, mode:) -> ClosedRange<Double>` for the open rule.
   Keep `lightnessRange(_:)` only as `forcedRange` for `.light` / `.dark`.
   Remove the `.automatic` constant from call sites.
2. `ThemeEditorState.swift`: store `range` and `saturation` as `var`s. Set
   them in `init(style:)` with the open rule. Update them in `.selectPreset`
   and `.setAppearance` as in the table above. Reset them when the style
   becomes `nil`. `setAppearance` computes `t` with the old stored range.
   The empty-state default `saturation` becomes 1.0.
   Lead clarification (2026-10-26 17:14 America/Vancouver): in-session undo
   snapshots include the style, range, and saturation. Undo/redo restore the
   exact earlier knob and editor state, without reconstructing a range from
   the restored key. Reopening the editor still uses the open rule above.
   None of these transient range/saturation values are written to disk.
3. `ColorPadView.swift` / `PresetStripView.swift`: read the range from the
   state, not from the mode.
4. No stored-value or `mathVersion` change: the key color is still the only
   stored output, and rendering does not read the range.

### 17.2 Sidebar opacity, wash, and compositing (`ThemeField`, `ThemeTuning`)

```text
a(i)        = 0.2 + 0.55 · clamp(i, 0, 1)                    theme layer opacity
w(i)        = 0.35 · min(a(i), 0.5)                          dark wash, black
underlay(i) = U0 · (1 − w(i)) / (1 − 0.35·0.5)               U0 = today's fitted gray
pixel       = a · key + (1 − a) · underlay                   gamma-encoded Display P3
```

- `ThemeField.layerAlpha(intensity:)` returns `a(i)`. It equals 0.64 at
  0.8, so every intensity-0.8 fit and compare is unchanged.
- `U0` keeps `lightUnderlayActive` 0.694 and `lightUnderlayInactive` 0.83.
  Dividing by 0.825 keeps both values exact at intensity ≥ 0.55. This is
  equivalent to a material of 0.8412 (active) under Arc's wash (**fit**; this
  capture's material is 0.8246; every §17.4 sidebar row passes with either value).
  Inactive scaling by the same wash is a **guess**.
- The black wash applies when the window's color scheme is Dark. The
  capture is macOS Dark with `translucencyStyle: light`. In Light, Arc's
  other branch is a white wash at `min(a, 0.5)`. It is not captured over a
  theme, so in Light keep today's underlays without a wash (**guess**).
- Composite editor styles in gamma-encoded Display P3: convert the key to P3
  (it already is, from `ThemeColorMath`), mix with the gray underlay, then
  convert the result to extended sRGB for the field image. The pad-center
  frame fits at ΔE00 1.23 in P3 and 2.55 in sRGB (**fit**). For gradients,
  convert the OKLab result to P3 before the final mix with the underlay.
- Legacy imports and mapped stops (`usesLegacyIntensity`): keep 0.64 and the
  sRGB path in this PR. Run F0069 (stored intensity 1.0) with `a = 0.75` and
  the P3 mix. Switch legacy themes only if F0069's worst ΔE00 stays ≤ 2.38
  (today's value). Record both numbers in the PR either way.

Add to `ThemeTuning`:

```swift
public static let intensityAlphaFloor = 0.2       // 0x101532458
public static let intensityAlphaSlope = 0.55      // 0x101532444
public static let darkWashAlpha = 0.35            // 0x101532414
public static let washOpacityCap = 0.5            // 0x101532464
public static let textureNoiseScale: [SpaceStyleTexture: Double] =
    [.grain: 0.80, .sand: 0.15, .denim: 0.60, .tweed: 0.40]   // 0x10153258c
public static let textureTileDarkness: [SpaceStyleTexture: Double] =
    [.grain: 0.060, .sand: 0.316, .denim: 0.122, .tweed: 0.262] // fit, §17.3
```

### 17.3 Textures (`ThemeTexture`)

The §4.4 equal-mean-darkness rule and its base-alpha layer are removed. The
lead's round-3 note already supersedes them. Each texture draws its own
black tile (Open's own pattern) at layer opacity
`noise × textureNoiseScale[t]`.

- Tile mean alpha: `textureTileDarkness[t]`. Then the mean darkening is
  `noise × k × D`: at noise 0.8, grain 0.0386, sand 0.0379, denim 0.0586,
  tweed 0.0838 (multiplicative, encoded values).
- Contrast: tune each pattern's alpha spread so the sidebar L* standard
  deviation over x 30–200, y 820–1020 at noise 0.8, intensity 1 is grain
  2.02, sand 1.53, denim 1.28, tweed 0.92 (±0.3). Tweed must be the
  smoothest: a soft mottle, not sharp dashes.
- Monochrome: no per-channel tint. Arc's darkening differs by ≤ 0.001
  between channels. The F0139 per-channel grain note stays open, because
  this session shows none.
- Grain: rescale today's `Grain.tile` alpha so its mean is 0.060 at layer
  opacity 1. Keep its pattern. Check F0139 (noise 0.45): it must stay
  ≤ 0.84 ΔE00, or report the change.
- Cache key unchanged (texture, noise bucket, scale). The tile no longer
  depends on noise; only layer opacity does. One tile per (texture, scale)
  is enough.

### 17.4 Acceptance (`space-editor-render compare --spec session2-pad`, new)

Inputs: the local session 2 item 17 frames (never committed). Colors: convert
the capture's embedded display profile to Display P3. Sidebar sample: mean of
x 30–200, y 820–1020 of the main-window image (`win-70352`). Render Open's
window with the key from Open's own pad math at Arc's knob position and
Arc's intensity and noise. Brand 8 state: P3 HSL h 200.5°, s 0.5176,
l 0.6667, range 0.4167…0.9167.

| Check | Arc input (unit knob position, intensity) | Target |
|---|---|---|
| Knob, Greyscale 1–9 (0027–0045) | preset tap, Automatic | ≤ 1.5 pt each (decoded ≤ 0.9) |
| Knob, Brand 8 (0065) | preset tap, Automatic | ≤ 1.5 pt (decoded 0.7; today 30.6) |
| Key, pad center (0092) | r 0.004, hue from Arc's knob 337.1°, 0.8 | ΔE00 ≤ 2 vs knob P3 (163, 53, 95) (decoded 0.39) |
| Key, mid radius (0093) | (0.485, −0.003), 0.8 | ΔE00 ≤ 2 vs (213, 125, 126) (decoded 0.37) |
| Key, edge at rest (0098) | (0.932, −0.004), 0 | ΔE00 ≤ 2 vs (242, 213, 213) (decoded 0.40) |
| Sidebar, center (0092) | as above, 0.8 | ΔE00 ≤ 2 (decoded 0.94 with `U0`; today 29.8) |
| Sidebar, mid (0093) | as above, 0.8 | ΔE00 ≤ 2 (0.35; today 13.7) |
| Sidebar, edge (0095) | key of 0098, 0.8 | ΔE00 ≤ 2 (0.22; today 2.5) |
| Sidebar, intensity 0 / 0.5 / 1 (0098 / 0100 / 0102) | key of 0098; 0, 0.495, 1 | ΔE00 ≤ 2 each (0.82 / 0.51 / 0.32; today 6.98 / 2.49 / 2.60) |
| Sidebar, Brand 8 (0065) | preset, 0.8 | ΔE00 ≤ 2 (0.55) |
| Textures (0112 / 0114 / 0116 / 0118) | key of 0098, 1, noise 0.8 | mean ΔE00 ≤ 2 vs Arc; L* sd within ±0.3 of §17.3 |
| Mode remap | Brand 8, Dark then Light | Dark: `l' = 0.01 + 0.415·t`; Light: `0.575 + 0.395·t`, with `t` from 0.4167…0.9167 |
| Empty open | no style | range 0.01…0.97, saturation 1.0; F0137 knob at 45.98 pt (Arc 45.26) |

Also run `sidebar-render check`, the F0069 compare (§17.2), F0139, and the
existing editor checks. Frame 0091 is not a gate frame: its second window
image is mid-drag, and there the sidebar lags the knob. Use 0092, which has
the same knob at rest.

Remaining unknowns, not gates: the Metal renderer's own config fill (the
capture fits the SwiftUI law), the light-mode wash, the inactive-window
material, and Automatic-return behavior.

Implementation notes (Step 9):

- `compare --spec session2-pad --capture-root SESSION17 --out .re/DIR`
  measures the **main-window `win-70352`** images in Display P3. The extra
  window image can lag a preset tap; F0039 and F0041 both show Greyscale 7
  in the main image. Open's preset positions are measured from its rendered
  white ring, not from the state formula. The Brand-8 mode expectation uses
  the independent decoded range 0.4167…0.9167.
- Neutral P3 presets canonicalize an undefined hue to zero when round-trip
  channel spread is below 0.000001 (less than 0.001 of an 8-bit level).
  This prevents numerical ColorSync noise rotating grey knobs off the axis.
- Cached ColorSync linear-primary matrices and the shared transfer curve
  implement the encoded-P3 mix without allocating a CGColor per field pixel.
  The three-color field rebuild measured about 1 ms instead of 21 ms on
  this machine; this is a harness measurement, not the Step 5 B1 acceptance.
- Texture contrast is an Open fit: alpha spreads 0.167 / 0.0353 / 0.0371
  for sand / denim / tweed; grain's existing hashed marks receive a 1.25
  contrast stretch and mean normalization to 0.060. There is no separate
  base-alpha layer or per-channel tint. Noise changes only the layer opacity.
- The F0069 diagnostic measured worst ΔE00 **2.38 legacy / 2.29 decoded**.
  This PR retains the legacy opacity, sRGB path, and exact grain bytes so
  the 13 stored/imported capture tables can remain byte-identical. The
  qualifying diagnostic is not an automatic migration of stored themes.
- **F0139 editor-style diagnostic changes from 0.84 to 1.89 ΔE00** (worst
  of six regions). The new encoded-P3 fill and calibrated grain replace the
  prior sRGB-clamped fit. This is the §17.3 report-change branch; it is not
  described as preserving the old 0.84 fit or as changing the legacy tables.
- The private compare input is bounded to 512 root entries, 64 MiB per PNG,
  4096×4096 pixels, 4096 chunks, and a 128 MiB decoded source. The synthetic
  CLI boundary driver is `Fixtures/space-editor-step9/check-inputs.py` in
  OpenKit. It includes the accepted limits, one-over refusals, and trailing
  data/unknown-option refusals. Capture pixels remain local and uncommitted.

## Appendix — Lead decisions (2026-10-25)

- Approved as the Space creation, editing, and theme editor plan. Implementation starts after the plan merges. It can run in parallel with the app-shell work, because Steps that touch only OpenKit come first.
- Q1 Emoji data: generate it with our own script from Unicode `emoji-test.txt`, and keep the license row in `docs/release/licenses.md` (already added).
- Q2 A new Space starts with no stored theme unless the user picks a color (capture session 2; supersedes the original Brand-preset guess).
- Q3 The Automatic text-color bias is 0.0.
- Q4 Intensity uses the provisional `alpha = 0.8 × intensity`. Calibrate it from the theme-editor capture when it arrives.
- Q5 Presets page 2: Brand 1–9 with 3 colors 40° apart.
- Q6 The New Space form is a page in the sidebar.
- Q7 A new Space goes at the end of the list.
- Q8 Folders use the same 55-icon set as Spaces. The sidebar completion plan reuses this picker for Change Icon… on folders and pinned tabs.
- Q9 The editor follows the system appearance and uses the guessed light colors, until a macOS Light capture confirms them.
- Q10 The 2nd and 3rd color knobs are 30 pt, not draggable, and move with the main knob.
- Q11 Spaces ▸ Rename Space edits the name in the sidebar header. A dialog appears only when the sidebar is hidden.
- The capture request goes into the user's single combined Arc capture session.
- 2026-10-26 (capture session 2): Q2 superseded. A new Space starts with **no** theme (the default theme) unless a color is picked in the New Space form (C10).


### Lead round-3 overrides — 2026-10-26

Evidence: `theme-design-r2.md`, capture session 2 item 17
(`20261026-104045-17-theme-editor`) and item 20
(`20261026-103516-20-light-mode`); private frames remain local under `.re/`.

- **Harmony / N5:** the 11:57 lead clarification supersedes the earlier
  suggestion to alter the harmony function. Add switches a one-color style
  to complementary, in one undo step; Add at two colors preserves its mode.
  No preset or persisted style is rewritten. Frames 0065/0067/0069 prove the
  page-1 complementary offsets. The editor wiring lands in Step 3, where
  `ThemeEditorState` exists; Step 2 keeps and gates both harmony modes.
- **Step 9 is a hard written acceptance gate, not optional polish.** Decode
  Arc's knob-radius ↔ color function before claiming pad parity. Frames
  0027–0049 show shared radii for mid greys; 0091–0097 show a deep color at
  the center (lightness about 0.45), not black. Do not decode it in this
  review pass. Current M3 proves an internal round trip only.
- **Q4 / intensity:** Step 9 must reproduce the tint at intensity zero.
  Frames 0098/0100/0111: Arc keeps a tint at 0 (current Open ΔE00 7.30),
  and the measured intensity-1 alpha is about 0.75. The provisional law is
  not a verified Arc law. Preserve these capture values as the calibration
  acceptance inputs; no stored-value meaning changes in this review pass.
- **D-8 / equal mean darkness:** the earlier equal-darkness requirement is
  superseded as an Arc parity target. Step 9 must calibrate per-texture
  darkness and contrast from 0112/0114/0116/0118 at noise 0.8. Arc tweed is
  darkest and smoothest, with mean (209.6,184.8,185.8) and L standard
  deviation 2.53, versus no-texture (228.9,201.9,202.7). Grain, sand, denim,
  and tweed do not share one mean. Keep existing procedural Space tiles and
  current compatibility checks until Step 9 replaces this provisional fit;
  they are regression checks, not a claim that Arc uses equal darkness.
  Grain strength and per-channel calibration belong to this same gate.

- **Q9 / appearance override:** session 2 frames 0158–0163 prove forced
  Light/Dark changes the editor even under the opposite system mode.
  Automatic inherits the system. This supersedes the original Q9 decision.
  Light tokens and the FCFBFC harness backdrop are calibrated from item 20
  0027 and item 17 0158–0159; no outline on the knob, thumb, or tick.
- **Empty state / N4:** frame 0010 replaces the hidden-button and dimmed
  controls guesses: bright centered label, visible disabled Remove/Add.
  Step 4 hides the thumb and tick, leaves the wave inactive at its default
  amplitude, and draws only unlit dial dots.
- **Secondary knobs / N6:** frames 0067–0080 give 27 pt at rest, pure white
  rings, about 30 pt on hover/drag, with the primary on top. Grey knobs in
  0050–0064 coincide rather than forming a visible bullseye.
- **Hover / N13:** 0016/0020 and 0066–0068 give alpha 0.11; selected plus
  hover stacks to about 0.20. Minus glyph is pixel-aligned and shifted 1 pt
  down, preserving the button frame (0081–0085).

Session-2 glyph comparisons mask the pad-dot lattice and use the median stroke
plateau (≥95% of the upper-half stroke median, excluding antialiased edges). They report normalized and raw core color separately. Half-peak
boxes still report center/height; empty-label measurements remain separate.
The light moon uses 17 pt (16 pt in dark) to retain the captured height in
item 20 frame 0027.

- **Thumb lock lifted / N1–N3:** round-3 lead decision supersedes the
  01:43 `32 + 200·value` lock. Session 2 0098/0100/0063/0111 fixes panel
  center x to `38.8 + 208.4·value`, with matching input. Amplitude is about
  `14.8·value`, including a straight line at zero. Rest size interpolates
  between the measured low/default/high points in §5.7; hover/press is
  ×1.09. The former one-frame fixed size and amplitude were guesses.
- **N8 / shadows:** session 2 0098–0111 and light 0159 supersede the R1
  outline and symmetric halo advice: use a faint downward shadow only.
- **Dial / N10–N11/N17:** 0112–0122 proves a five-state cycle with none and
  exact noise 0.80 for every texture. 0137/0145/0148 fixes an 8×16 pt tick.
  Preview brightness is calibrated now, separately from Step 9 Space-tile
  calibration: translucent grain fits both dark/light backdrops; the other
  previews are light and almost opaque. All art is Open's own procedure.
- **Page 2 / N12:** 0016 shows three muted diagonal color stops and no disc.
  The captured RGB stop numbers are facts, used in an original gradient.

Round-3 comparison extends §12.3 with `--spec session2-editor` and states
`empty`, `empty-light`, `slider --value V`, `preview`, and `page-two`.
It reports real raster thumb geometry, fitted wave centroid amplitude,
preview mean/contrast, and five diagonal colors per page-2 swatch. Session 2 private pixels
are read only by this command; outputs stay under ignored `.re/`.
The F0137/F0138 Automatic animation exemption and glyph-shape exemption
remain. Raw new-capture color measurements are reported separately from
formal native flow checks and from the unresolved Step 9 parity gate.

### Review R3 — corrected glyph sampling (2026-10-26)

Lead decision after `theme-design-r3.md` F1/F4: light `glyph` and
`glyphSelected` are black **0.50**, with disabled glyph factor **0.32** in
both modes. Remove and Add use SF Symbols **Semibold 16 pt**, matching
Arc's approximately 2.0 px strokes (item 17 frames 0069/0158).

The earlier refused alpha fit was a **measurement error**, not evidence
for 0.55. The ≥99%-of-peak selector preferred pad dots under glyph strokes,
and the 0158/0159 comparison used a rest Light plate where Arc was hovered.
Those historical numbers and their refusal do not establish token parity.
The corrected harness excludes the 4.25 pt pad-dot lattice, samples the
median stroke plateau, and renders Light hovered in item 17 0158–0159.
It reports raw core color and a separate token comparison. The latter uses
Arc's local background and SF coverage measured with a unit-black reference
render of the same glyph. Some thin SF diagonals have no fully covered pixel
at 1x; this measures their paint alpha without changing product opacity or
adding per-glyph alpha adjustments. All item 20 0027–0034 frames are included but are
identified as repeated samples of the same static state, not eight distinct
states. The corrected numeric result is recorded with the Step 4 harness.

Corrected `fit-light-glyphs` result: **70 glyph instances / 1546 dot-free
core pixels**, median capture alpha **0.49956**. Per-instance estimates are
**0.49633–0.51952**, maximum offset from the corpus median **0.01996**
(within ±0.05). The authored alpha is **0.50**; disabled factor is **0.32**.
Maximum coverage/background-normalized token error is **ΔE00 1.06**.

| Glyph | Core pixels | Median capture alpha | Token ΔE00 range | Raw core ΔE00 range |
|---|---|---|---|---|
| Automatic | 154 | 0.49971 | 0.06–0.37 | 0.71–1.46 |
| Light | 356 | 0.49633 | 0.49–0.76 | 1.30–1.37 |
| Dark | 500 | 0.49808 | 0.28–0.35 | 1.03–1.49 |
| Remove | 160 | 0.50961 | 0.49–0.60 | 1.41–2.54 |
| Add | 128 | 0.50904 | 0.36–0.63 | 1.68–1.75 |
| Previous | 128 | 0.51937 | 0.44–0.52 | 0.69–1.41 |
| Next | 120 | 0.51161 | 0.62–1.06 | 3.60–5.44 |

The raw SF chevron pixel residual remains visible in this table; the token
gate does not claim that different glyph shapes or coverage are identical.
No text, track, dot, thumb, or dial fill token changed in the alpha fit.
The earlier refusal and its apparent hovered-Light regression are invalid.

Round-3 compatibility correction: main's new paired sidebar capture gate
exposed two accidental legacy-path changes: the editor fill clamp reached
imported extended colors, and the texture cache quantized imported noise
to 0.05 buckets. Legacy (`style == nil`) themes now retain their original
field inputs, 0.64 opacity, and exact `Grain.tile` path. Editor styles keep
the F0139 clamp and bounded texture cache. This enforces §3.4's byte-identical
legacy rendering requirement without changing any stored value or gate.


Review R3 control corrections: the grown thumb's overhang is hit-testable
inside the existing panel, and hover follows its grown frame. Empty Intensity,
Noise, and Cycle-noise report AX enabled, while actions preserve the empty
theme. Dots are 5 pt on radius 32; the tick uses that same orbit. Wave slope
is 14.8. Sand preview uses Open's own short horizontal dashes; mean/contrast
remain 139/7.7. Page-2 art is selected by page, not by color count. These
changes do not implement Step 5 wiring or change stored style meaning.

R3 page-2 result: **45/45** diagonal samples pass, maximum **ΔE00 1.34**.
Stop facts use a single bilinear sample at t = −9/0/+9, away from the rim.
The gate uses a uniform 2×2 pt mean at t = −8/−4/0/4/8 to suppress capture
dithering; its support stays inside the rim. The ΔE00 ≤2 limit is unchanged.
F0137/F0138 remain at maximum **1 pt / ΔE00 1.94**. Session-2 slider frames
0098/0100/0111/0114 remain within **1 pt**. Preview mean-color error is at
most **ΔE00 1.31** across 0112/0114/0116/0118/0159.


### Step 5 implementation — live sessions (2026-10-26)

`ThemeEditSession` owns the current model baseline and draft. The panel's
single display link writes one preview per frame. The shared
`ThemePreviewRegistry` publishes after that write, in the same transaction;
each matching sidebar swaps and rebuilds its field before presentation.
Other Spaces are not invalidated. Leases are scoped to editor gestures, so
preset/mode/add/remove/texture and undo/redo keep the discrete 0.21 s fade.

The browser window owns one controller. Both `edit-theme` and
`editSpaceTheme` use it; the latter focuses its target first without adding
an undo step. A gesture commit schedules one debounced save. Its undo relay
keeps the store independently of the original window, so undo/redo still
save after that window closes. Esc flushes a pending frame before closing.
Outside mouse down, app deactivation, Space switch/delete, owner close, and
app termination close the editor. The existing final save after the engine
message loop follows the termination notification; no new app shutdown
path is added. Backing-scale changes follow the owner window.

`App/MainMenu.swift` adds only the theme command's feature ownership and a
small key-window lookup for the panel. Existing generic automation drives
the real windows in `engine_e2e.py --only theme-live`; Step 8's dedicated
`editor-*` / `theme-*` APIs, creation form, and icon picker remain deferred.
The already-landed thumb-overhang `hitTest` path is retained and checked
through the native panel path.
