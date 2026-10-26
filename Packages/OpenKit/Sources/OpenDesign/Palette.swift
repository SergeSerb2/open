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
/// above by measurement. One place to change a role.
public enum SidebarRole {
    /// Space title: measured black 0.48 → `GrayA10`.
    public static let spaceTitle = GrayScale.a(10)
    /// URL placeholder, "New Tab" label and its plus glyph.
    public static let secondaryText = CommandBarColors.textSecondary
    /// Toolbar glyphs when the button is disabled: measured peak black 0.22 → `GrayA8`.
    public static let toolbarGlyphDisabled = GrayScale.a(8)
    /// Toolbar glyphs when enabled. guess: `GrayA11`; verify on a 2x capture.
    public static let toolbarGlyph = GrayScale.a(11)
    /// Toolbar button hover/press plate. guess from the same family as row hover.
    public static let toolbarHover = SidebarColors.itemBackground
    /// URL field and favorite tile resting fill.
    public static let fieldFill = SidebarColors.itemBackground
    public static let tileHover = SidebarColors.itemHoveredBackground
    public static let rowHover = SidebarColors.itemBackground
    public static let rowSelected = SidebarColors.tabCurrent
    public static let rowSelectedShadow = SidebarColors.tabShadowSelected
    public static let rowPressed = SidebarColors.tabPressed
    /// Pinned/Today divider line and the "Clear" label.
    public static let divider = SidebarColors.separator
    public static let dividerLabel = SidebarColors.foreground
    /// Close (×) and unload (−) glyphs on a hovered or selected row.
    public static let rowAccessory = Core.foregroundSecondary
    /// Space switcher icons that are not current. Measured visually as faded.
    public static let switcherInactiveOpacity: Double = 0.45
}
