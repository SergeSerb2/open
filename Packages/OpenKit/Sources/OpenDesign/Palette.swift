import Foundation

// Color tokens. Values are facts read from Arc 1.170.0 asset catalogs
// (docs/re/design-tokens.md §1) and checked against live captures
// (docs/re/runtime-observations.md §3, docs/design.md). Names follow the
// catalog names so a reader can trace each value.

private func pair(_ light: RGBA, _ dark: RGBA) -> DesignColor { DesignColor(light: light, dark: dark) }

/// Core text and background (`ARCClients_BaseAssets`).
public enum Core {
    public static let backgroundPrimary = pair(RGBA(hex: 0xFFFFFF), RGBA(hex: 0x000000))
    public static let basePrimary = pair(.black(1), .white(1))
    public static let baseSecondary = pair(.black(0.70), .white(0.70))
    public static let baseTertiary = pair(.black(0.30), .white(1))
    public static let baseQuaternary = pair(.black(0.15), .white(0.15))
    public static let foregroundPrimary = pair(RGBA(hex: 0x0E0F10, alpha: 0.90, .displayP3), .white(0.80))
    public static let foregroundSecondary = pair(.black(0.50), .white(0.50))
    public static let foregroundTertiary = pair(.black(0.30), .white(0.30))
    public static let brandBlue = DesignColor(RGBA(hex: 0x3139FB, .displayP3))
    public static let focusRing = DesignColor(RGBA(hex: 0x458AFF, .displayP3))
    public static let popoverBackground = pair(RGBA(hex: 0xFAFBFF, .displayP3), RGBA(hex: 0x151C30, .displayP3))
    public static let shadow = pair(.black(0.20), .black(0))
}

/// Sidebar rows and tab cells (`ARCClients_BaseAssets`, main `Assets.car`).
public enum SidebarColors {
    public static let foreground = pair(.black(0.30), .white(0.45))
    public static let foregroundDarker = pair(.black(0.45), .white(0.45))
    /// Resting fill for the URL field and favorite tiles; also the row hover fill.
    /// Measured: black ≈ 4.5–4.8 % over the gradient (light), white 10 % (dark).
    public static let itemBackground = pair(RGBA(hex: 0x0E0F10, alpha: 0.05, .displayP3), RGBA(hex: 0xFAFBFF, alpha: 0.10, .displayP3))
    public static let itemHoveredBackground = pair(RGBA(hex: 0x0E0F10, alpha: 0.10, .displayP3), RGBA(hex: 0xFAFBFF, alpha: 0.15, .displayP3))
    public static let separator = pair(.black(0.15), .white(0.15))
    /// Selected (current) tab. Measured white 20 % in a dark Space.
    public static let tabCurrent = pair(.white(0.85), RGBA(hex: 0xFAFBFF, alpha: 0.20, .displayP3))
    public static let tabContentVisible = pair(.white(0.70), RGBA(hex: 0xFAFBFF, alpha: 0.15, .displayP3))
    public static let tabPrevious = pair(.white(0.32), RGBA(hex: 0xFAFBFF, alpha: 0.08, .displayP3))
    public static let tabPreviousHovered = pair(.white(0.50), RGBA(hex: 0xFAFBFF, alpha: 0.12, .displayP3))
    public static let tabMultiselected = pair(.black(0.10), RGBA(hex: 0xFAFBFF, alpha: 0.10, .displayP3))
    public static let tabPressed = pair(RGBA(hex: 0x0E0F10, alpha: 0.06, .displayP3), RGBA(hex: 0xFAFBFF, alpha: 0.06, .displayP3))
    public static let tabChildBackground = pair(.black(0.07), .white(0.07))
    public static let tabShadowBackgroundSelected = pair(.white(0.90), .black(0))
    /// Only light content casts a selection shadow; the dark token is clear.
    public static let tabShadowSelected = pair(.black(0.20), .black(0))
    public static let tabSlash = pair(RGBA(hex: 0x000000, alpha: 0.30, .displayP3), RGBA(hex: 0xFFFFFF, alpha: 0.30, .displayP3))
    public static let border = DesignColor(.white(0.30))
    public static let tabListOverlapBorder = pair(.black(0.05), .white(0.05))
    public static let dragHint = pair(.black(0.20), .white(0.20))
    public static let dragHintHighlighted = pair(.black(0.50), .white(0.50))
    public static let newTabPulsingText = DesignColor(.black(0.30))
    public static let addSpacePlusDeactivated = pair(.black(0.45), .white(0.45))
}

/// Command bar and the URL field (`Resources/Assets.car`, `ARC_CommandBar`).
public enum CommandBarColors {
    public static let iconActiveBackground = pair(.white(1), RGBA(hex: 0x1A1A1A, .displayP3))
    public static let placeholderText = pair(.black(0.60), .white(0.60))
    public static let placeholderPlaceholderText = pair(.black(0.30), .white(0.30))
    public static let lockSecure = pair(RGBA(hex: 0x000000, .displayP3), RGBA(hex: 0xFFFFFF, .displayP3))
    public static let lockInsecure = pair(RGBA(hex: 0xF53714, .displayP3), RGBA(hex: 0xF25E6B, .displayP3))
    public static let textPrimary = pair(.black(0.80), .white(0.80))
    /// URL placeholder and the "New Tab" label (measured black ≈ 0.33).
    public static let textSecondary = pair(.black(0.33), .white(0.33))
    public static let rowHoverBackground = pair(.black(0.05), .white(0.05))
    public static let hairlineDivider = pair(.black(0.10), .white(0.10))
    public static let accessoryBackground = pair(.black(0.05), .white(0.05))
    public static let accessoryForeground = pair(.black(0.50), .white(0.66))
}

/// Gray, alpha-gray, and indigo scales (`ARCUI_ARCUI`). Use `GrayA` on the gradient.
public enum GrayScale {
    public static let gray: [DesignColor] = zip(
        [0xFCFCFC, 0xF8F8F8, 0xF3F3F3, 0xEDEDED, 0xE8E8E8, 0xE2E2E2, 0xDBDBDB, 0xC7C7C7, 0x8F8F8F, 0x858585, 0x6F6F6F, 0x171717] as [UInt32],
        [0x161616, 0x1C1C1C, 0x232323, 0x282828, 0x2E2E2E, 0x343434, 0x3E3E3E, 0x505050, 0x707070, 0x7E7E7E, 0xA0A0A0, 0xEDEDED] as [UInt32]
    ).map { pair(RGBA(hex: $0), RGBA(hex: $1)) }

    private static let lightA: [Double] = [0.01, 0.03, 0.05, 0.07, 0.09, 0.11, 0.14, 0.22, 0.44, 0.48, 0.56, 0.91]
    private static let darkA: [Double] = [1.00, 0.03, 0.06, 0.08, 0.10, 0.13, 0.17, 0.25, 0.39, 0.45, 0.59, 0.92]
    /// `GrayA1`…`GrayA12` at index 0…11. Dark `GrayA1` is stored as opaque black in
    /// the catalog (likely a placeholder); we keep the white ramp's 1 % instead.
    public static let grayA: [DesignColor] = (0..<12).map { i in
        pair(.black(lightA[i]), i == 0 ? .white(0.01) : .white(darkA[i]))
    }
    public static func a(_ step: Int) -> DesignColor { grayA[step - 1] }

    public static let indigo: [DesignColor] = zip(
        [0xFFFFFF, 0xF7F8FF, 0xF0F0FF, 0xE8E9FF, 0xD9DAFC, 0xC8CAFA, 0xAEB0F5, 0x8E91F0, 0x3138F9, 0x393ECC, 0x3438B2, 0x101245] as [UInt32],
        [0x141421, 0x16162E, 0x191A40, 0x1C1D4F, 0x1F215C, 0x22246E, 0x272A8A, 0x2E32B2, 0x3239FA, 0x5458E8, 0x8589FF, 0xEDEEFC] as [UInt32]
    ).map { pair(RGBA(hex: $0), RGBA(hex: $1)) }
}

/// Menus (`ARC_ArcMenu`). Open uses native NSMenu; these are for custom popovers.
public enum MenuColors {
    public static let background = pair(RGBA(hex: 0xFAFBFF), RGBA(hex: 0x393841))
    public static let text = pair(RGBA(hex: 0x494949), RGBA(hex: 0xEBEBEC))
    public static let textHover = pair(RGBA(hex: 0x151515), RGBA(hex: 0xFFFFFF))
    public static let hoverBackground = pair(RGBA(hex: 0xB7D1FF), RGBA(hex: 0x3970C5))
    public static let separator = DesignColor(RGBA(hex: 0xC4C4C4))
}

/// Role-based tokens the sidebar actually paints, mapped to the catalog tokens
/// above by measurement (docs/re/runtime-observations.md §3.2,
/// docs/re/interaction-states.md §3–§6). One place to change a role.
/// Theme-driven roles (tab title, selected fill, tooltip) live on `SpaceThemeStyle`.
public enum SidebarRole {
    /// Guess: unread dots use the Space accent (sidebar completion §2.7).
    public static func unreadDot(style: SpaceThemeStyle, appearance: ContentAppearance) -> RGBA { style.accentColor(appearance) }
    /// Space title. Light: black 0.45 → `SidebarForegroundDarker` (fitted on F0001;
    /// 0.48 / `GrayA10` gave ΔE 1.8). Dark: white 0.55, fitted on the default dark Space (F0079).
    public static let spaceTitle = DesignColor(light: SidebarColors.foregroundDarker.light, dark: .white(0.55))
    /// "New Tab" label. Light: black 0.30 → `SidebarForeground` (F0001). Dark: white 0.45 (F0079).
    public static let secondaryText = SidebarColors.foreground
    /// URL placeholder. Light: black 0.30 (F0001). Dark: white 0.30 over the field fill (F0079); darker than "New Tab".
    public static let placeholder = DesignColor(light: SidebarColors.foreground.light, dark: .white(0.30))
    /// "New Tab" plus glyph. Light: peak black 0.48 → `GrayA10`. Dark: white 0.51 (F0079).
    public static let newTabGlyph = DesignColor(light: GrayScale.a(10).light, dark: .white(0.51))
    /// URL field magnifier: core pixels black ≈ 0.38 (F0001). No catalog token fits
    /// our SF glyph's stroke; 0.40 is fitted. Dark: guess, white at the same alpha.
    public static let magnifier = DesignColor(light: .black(0.40), dark: .white(0.40))
    /// URL field host text once a page is loaded. guess: `CommandBarPlaceholderText` (black 0.60).
    public static let urlText = CommandBarColors.placeholderText
    /// Toolbar glyphs when the button is disabled: measured peak black 0.22 → `GrayA8`.
    public static let toolbarGlyphDisabled = GrayScale.a(8)
    /// Toolbar glyphs when enabled, and the sidebar toggle always: core pixels
    /// black ≈ 0.56 on F0001 → `GrayA11` (Arc's AX reports the toggle disabled, but it draws enabled).
    public static let toolbarGlyph = GrayScale.a(11)
    /// Toolbar and bottom-bar hover plate: measured black ≈ 0.067–0.07 → `GrayA4`.
    public static let buttonHover = GrayScale.a(4)
    public static let buttonPressed = GrayScale.a(6)
    /// URL field and favorite tile resting fill: measured black 0.045 → `SidebarItemBackground`.
    public static let fieldFill = SidebarColors.itemBackground
    /// URL field under the pointer: F0033 `#CF8B6F` over `#E49978` = black 0.10 → `SidebarItemHoveredBackground`.
    public static let fieldHover = SidebarColors.itemHoveredBackground
    /// guess: tiles darken like rows on hover (not captured).
    public static let tileHover = SidebarColors.itemHoveredBackground
    /// Row and Space header hover: measured black 0.048 (light), white 0.10 (dark).
    public static let rowHover = SidebarColors.itemBackground
    /// Selected row in dark content: measured white 0.20 → `TabCellBackgroundCurrent` dark.
    /// Light content uses the theme's `light.background` (see `SpaceThemeStyle.selectedFill`).
    public static let rowSelected = SidebarColors.tabCurrent
    public static let rowMultiselected = SidebarColors.tabMultiselected
    public static let rowSelectedShadow = SidebarColors.tabShadowSelected
    public static let rowPressed = SidebarColors.tabPressed
    /// Pinned/Today divider line: measured black 0.15 → `SidebarSeparator`.
    public static let divider = SidebarColors.separator
    /// "Clear" label and arrow: measured black ≈ 0.3 → `SidebarForeground`.
    public static let dividerLabel = SidebarColors.foreground
    public static let dividerLabelHover = SidebarColors.foregroundDarker
    /// Close (×) and unload (−) glyphs on a hovered or selected row: core pixels
    /// black ≈ 0.56 (F0013, F0015) → `GrayA11`.
    public static let rowAccessory = GrayScale.a(11)
    /// Bottom-bar plus: core pixels black ≈ 0.55 (F0001) → `GrayA11`. Dark: white 0.62 (F0079).
    public static let bottomGlyph = DesignColor(light: GrayScale.a(11).light, dark: .white(0.62))
    /// Bottom-bar glyphs while the window is inactive: peak black ≈ 0.28 on the
    /// inactive capture → `SidebarForeground` (0.30). Dark: guess.
    public static let bottomGlyphInactive = DesignColor(light: SidebarColors.foreground.light, dark: .white(0.30))
    /// Home glyph while the window is inactive: fitted for our filled glyph (inactive capture). Dark: guess.
    public static let homeGlyphInactive = DesignColor(light: .black(0.26), dark: .white(0.26))
    /// Bottom-bar Home (Library): core pixels black ≈ 0.52 (F0001), fitted for our
    /// own glyph shape. Dark: guess, white at the same alpha.
    public static let homeGlyph = DesignColor(light: .black(0.52), dark: .white(0.52))
    /// Space switcher icons that are not current: grayscale (Rec. 709 luma) at
    /// opacity 0.55. A two-channel fit on an inactive emoji gives ≈ 0.48 for full
    /// coverage; 0.55 matches the darkest-pixel levels of our 12 pt rendering (F0001).
    public static let switcherInactiveOpacity: Double = 0.55
    /// The "navigated away from the pinned URL" slash.
    public static let pinnedSlash = SidebarColors.tabSlash
    /// Pane cells inside a selected split row: white 0.07 over the selected card in
    /// both cells (F0081 `#5D5C6A` on `#50505F`) → `TabCellChildBackground`.
    /// F0081 shows no extra mark on the focused pane's cell.
    public static let splitCellFill = SidebarColors.tabChildBackground
    /// Peek badge plate: white ≈ 0.075 over the row (F0101), 0.07 over the row fill (F0090) → `TabCellChildBackground`.
    public static let peekBadgePlate = SidebarColors.tabChildBackground
    /// The source row while its Peek is on screen: white 0.10 instead of the 0.20
    /// selected fill (F0090, F0102: `#232234` over `#0A0A1D`) → `SidebarItemBackground`. guess: the token.
    public static let peekSourceFill = SidebarColors.itemBackground
    /// Toolbar row and bottom bar opacity while a Peek is on screen: they sit under the
    /// Peek's dim. Fitted per bar on F0090 glyph cores over the dimmed background (toggle,
    /// reload; Home, plus). Arc's dim is not a plain opacity, so one value cannot fit both bars.
    public static let peekToolbarOpacity: CGFloat = 0.43
    public static let peekBottomBarOpacity: CGFloat = 0.52
    /// Drop target line while dragging rows.
    public static let dropLine = Core.brandBlue
}

extension SidebarRole {
    public static let miniPlayerFill = SidebarColors.itemBackground
    public static let miniPlayerHoverFill = SidebarColors.itemHoveredBackground
    public static let mediaControlGlyph = CommandBarColors.accessoryForeground
    /// Provisional: use the existing insecure-lock pair until S9 (§4.1).
    public static let recordingIndicator = CommandBarColors.lockInsecure
}

public enum PiPRole {
    public static let glyph = DesignColor(light: .white(1), dark: .white(1))
    public static let plate = DesignColor(light: .black(0.4), dark: .black(0.4))
    public static let plateHover = DesignColor(light: .black(0.55), dark: .black(0.55))
    public static let platePressed = DesignColor(light: .black(0.7), dark: .black(0.7))
    public static let plateHighContrast = DesignColor(light: .black(0.6), dark: .black(0.6))
    public static let hangUp = DesignColor(light: RGBA(hex: 0xF53714), dark: RGBA(hex: 0xF53714))
    public static let scrubberTrack = DesignColor(light: .white(0.3), dark: .white(0.3))
    public static let scrubberFill = DesignColor(light: .white(0.9), dark: .white(0.9))
    public static let secondaryText = DesignColor(light: .white(0.85), dark: .white(0.85))
    /// Catalog facts, both appearances, sRGB (RE design-tokens §1.8).
    public static let documentTopBar = DesignColor(light: RGBA(hex: 0x212123), dark: RGBA(hex: 0x212123))
    public static let documentHairline = DesignColor(light: .white(0.2), dark: .white(0.2))
    public static let topScrim = DesignColor(light: .black(0.5), dark: .black(0.5))
    public static let bottomScrim = DesignColor(light: .black(0.6), dark: .black(0.6))
}

/// PreviewBackgroundColor, SC §7: measured catalog values, no copied assets.
public enum PreviewColors {
    public static let background = DesignColor(light: RGBA(hex: 0xFFFFFF), dark: RGBA(hex: 0x212222))
}
