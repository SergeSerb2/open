import CoreGraphics

// Layout metrics in points. Frames are `[x, y, w, h]` from the window's top-left
// corner (y grows down), measured on Arc 1.170.0 at sidebar width 228
// (docs/re/runtime-observations.md §1). Values marked `guess` were not measured.

/// Window chrome above the Space list.
public enum ChromeMetrics {
    /// Traffic lights: 16 pt frames at x 12 / 35 / 58, y 16 (system draws 12 pt circles).
    public static let trafficLightFrames: [CGRect] = [
        CGRect(x: 12, y: 16, width: 16, height: 16),
        CGRect(x: 35, y: 16, width: 16, height: 16),
        CGRect(x: 58, y: 16, width: 16, height: 16),
    ]
    public static let trafficLightPitch: CGFloat = 23
    /// Toolbar buttons are 32×32 at y 7.
    public static let toolbarButtonSize = CGSize(width: 32, height: 32)
    public static let toolbarButtonY: CGFloat = 7
    /// Sidebar toggle x. The other three buttons hang off the right edge.
    public static let sidebarToggleX: CGFloat = 77
    /// Back, forward, reload x at sidebar width 228 (pitch 34, right edge 6 pt in).
    public static let backX: CGFloat = 122
    public static let forwardX: CGFloat = 156
    public static let reloadX: CGFloat = 190
    public static let navButtonPitch: CGFloat = 34
    public static let reloadTrailingInset: CGFloat = 6
    /// Glyph ink sizes measured at 1x: toggle 19×15, back/forward 15×12, reload 14×17.
    public static let sidebarToggleGlyph = CGSize(width: 19, height: 15)
    public static let arrowGlyph = CGSize(width: 15, height: 12)
    public static let reloadGlyph = CGSize(width: 14, height: 17)
}

/// Command / URL field.
public enum URLFieldMetrics {
    public static let frame = CGRect(x: 8, y: 46, width: 212, height: 36)
    /// Same shape as favorite tiles: a circle of r ≈ 11 or a continuous corner of 8–9.
    public static let cornerRadius: CGFloat = 10
    public static let magnifierFrame = CGRect(x: 14, y: 52, width: 24, height: 24)
    public static let magnifierGlyph = CGSize(width: 12, height: 12)
    public static let textFrame = CGRect(x: 41, y: 55, width: 175, height: 18)
    /// Text baseline sits 14 pt below the text frame top.
    public static let textBaselineOffset: CGFloat = 14
}

/// Favorites grid ("Top Apps").
public enum FavoritesMetrics {
    public static let sectionTop: CGFloat = 82
    public static let inset: CGFloat = 8
    public static let columns = 3
    public static let tileHeight: CGFloat = 47
    public static let columnGap: CGFloat = 8
    public static let rowGap: CGFloat = 8
    public static let cornerRadius: CGFloat = URLFieldMetrics.cornerRadius
    public static let iconFrameSize: CGFloat = 18
    public static let iconInkSize: CGFloat = 16
    /// Known web apps get a larger tray icon (42 pt frame).
    public static let appTrayIconSize: CGFloat = 42

    /// Tile width for a sidebar width: (W − 2·inset − (columns − 1)·gap) / columns.
    public static func tileWidth(sidebarWidth: CGFloat, columns: Int = columns) -> CGFloat {
        (sidebarWidth - 2 * inset - CGFloat(columns - 1) * columnGap) / CGFloat(columns)
    }

    /// Section height for `count` favorites: the grid plus the 8 pt inset on each side.
    public static func sectionHeight(count: Int, columns: Int = columns) -> CGFloat {
        guard count > 0 else { return 0 }
        let rows = (count + columns - 1) / columns
        return 2 * inset + CGFloat(rows) * tileHeight + CGFloat(rows - 1) * rowGap
    }
}

/// Space header and the tab list.
public enum SpaceListMetrics {
    /// Header band: icon `[13, 205, 26, 26]`, title `[41, 209, 170, 18]` when the
    /// section starts at y 200. Offsets below are relative to the section top.
    public static let headerHeight: CGFloat = 36
    public static let headerIconFrame = CGRect(x: 13, y: 5, width: 26, height: 26)
    public static let headerTitleFrame = CGRect(x: 41, y: 9, width: 170, height: 18)
    public static let headerTitleBaselineOffset: CGFloat = 14
    /// "More" button collapsed to 2 pt at x 213; guess: expands on hover to a
    /// 26 pt square ending at the title's right edge.
    public static let headerMoreFrame = CGRect(x: 191, y: 5, width: 26, height: 26)
    /// First outline row is an empty 3 pt spacer.
    public static let spacerRowHeight: CGFloat = 3
    public static let rowHeight: CGFloat = 41
    /// The row's button is 40 pt tall; the fill sits inside it.
    public static let rowButtonHeight: CGFloat = 40
    /// Hover/selected fill: x 8…220, 36 pt tall, 2 pt below the row top (measured bbox).
    public static let rowFillInsetX: CGFloat = 8
    public static let rowFillInsetTop: CGFloat = 2
    public static let rowFillHeight: CGFloat = 36
    public static let rowFillCornerRadius: CGFloat = 10
    public static let faviconX: CGFloat = 17
    public static let faviconSize: CGFloat = 18
    public static let faviconInkInset: CGFloat = 1
    public static let faviconOffsetY: CGFloat = 11
    public static let titleX: CGFloat = 43
    /// Title frame right edge at x 211 → 17 pt from the sidebar edge.
    public static let titleTrailingInset: CGFloat = 17
    /// Title baseline sits 26 pt below the row top (frame y + 16).
    public static let titleBaselineOffset: CGFloat = 26
    /// Row accessory (close × / unload −) button, right-aligned in the fill. guess size.
    public static let accessorySize: CGFloat = 24
    public static let accessoryTrailingInset: CGFloat = 12
    /// Folder child indent per depth level. guess, verify with the folder capture.
    public static let indentPerLevel: CGFloat = 12
    /// Pinned/Today divider row.
    public static let dividerRowHeight: CGFloat = 30
    public static let dividerLineX: CGFloat = 18
    public static let dividerLabelTrailingInset: CGFloat = 19
    /// "New Tab" plus glyph: 11×11 ink at x 20…30.
    public static let newTabGlyphInk: CGFloat = 11
}

/// Bottom bar: Home, Space switcher, plus.
public enum BottomBarMetrics {
    public static let height: CGFloat = 50
    /// Buttons sit 9 pt above the window bottom.
    public static let buttonBottomInset: CGFloat = 9
    public static let buttonSize = CGSize(width: 32, height: 32)
    public static let homeX: CGFloat = 8
    /// Plus button right edge is 8 pt from the sidebar edge (x 188 at width 228).
    public static let plusTrailingInset: CGFloat = 8
    /// Switcher items are 36×34 at a 34 pt pitch (frames overlap by 2), y 1352
    /// with a 1394 window → 8 pt above the bottom.
    public static let switcherItemSize = CGSize(width: 36, height: 34)
    public static let switcherPitch: CGFloat = 34
    public static let switcherBottomInset: CGFloat = 8
    /// Switcher strip spans x 42…186 at width 228.
    public static let switcherLeading: CGFloat = 42
    public static let switcherTrailing: CGFloat = 42
    public static let switcherEmojiSize: CGFloat = 14
}

/// Web content panel next to the sidebar.
public enum PanelMetrics {
    /// Panel frame: `[sidebarWidth, 10, W − sidebarWidth − 10, H − 20]`.
    public static let topInset: CGFloat = 10
    public static let trailingInset: CGFloat = 10
    public static let bottomInset: CGFloat = 10
    public static let cornerRadius: CGFloat = 6
    /// CSS `0 1px 6px rgba(0,0,0,.25)` → CALayer radius 3, offset 1 down.
    public static let shadowOpacity: Float = 0.25
    public static let shadowRadius: CGFloat = 3
    public static let shadowOffsetY: CGFloat = 1
    /// Empty panel (no page): white ≈ 10 % over the gradient.
    public static let emptyFillWhiteAlpha: Double = 0.10

    public static func frame(windowSize: CGSize, sidebarWidth: CGFloat) -> CGRect {
        CGRect(x: sidebarWidth, y: topInset, width: windowSize.width - sidebarWidth - trailingInset,
               height: windowSize.height - topInset - bottomInset)
    }
}

/// Window-level values.
public enum WindowMetrics {
    public static let defaultSidebarWidth: CGFloat = 228
    /// System window corner: continuous, about 16 pt.
    public static let cornerRadius: CGFloat = 16
}
