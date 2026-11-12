import AppKit

/// The bottom-bar "+" popover (capture session 8 item 7, Arc 1.172.2, `v4/26-d2-items-7-8-5a/i7-*`;
/// pixel edges at 2×, colours converted from the display ICC to sRGB).
public enum PlusPopoverMetrics {
    /// Drawn body 210 × 290 (the AX window 222 × 308 adds a 6 pt margin and the arrow).
    public static let bodyWidth: CGFloat = 210
    /// Rows 194 × 40, 8 pt inside the body on every side.
    public static let rowSize = CGSize(width: 194, height: 40)
    public static let rowInset: CGFloat = 8
    /// 17 pt between groups; the 1 pt line sits 8 pt under the row above, 12 pt inside the body.
    public static let groupGap: CGFloat = 17
    public static let separatorOffset: CGFloat = 8
    public static let separatorInset: CGFloat = 12
    /// Icon centred 20 pt into the row; label at +39 pt; shortcut ends 7 pt before the row's right edge.
    public static let iconCenterX: CGFloat = 20
    public static let labelX: CGFloat = 39
    public static let shortcutTrailing: CGFloat = 7
    /// guess from pixel edges: body radius 14, row highlight radius 10.
    public static let bodyRadius: CGFloat = 14
    public static let rowRadius: CGFloat = 10
    /// Arrow under the body, its tip at the "+" button. guess: 14 × 7.
    public static let arrowSize = CGSize(width: 14, height: 7)
    /// The body's right edge sits 8 pt inside the sidebar (body x 162…372 in a sidebar ending at 380).
    public static let trailingInset: CGFloat = 8
    /// Room around the body for the shadow.
    public static let margin: CGFloat = 6
    @MainActor public static var labelFont: NSFont { .systemFont(ofSize: 14, weight: .semibold) }
    @MainActor public static var shortcutFont: NSFont { .systemFont(ofSize: 13, weight: .medium) }

    public static func bodyHeight(rows: Int, groups: Int) -> CGFloat {
        2 * rowInset + CGFloat(rows) * rowSize.height + CGFloat(max(0, groups - 1)) * groupGap
    }
}

/// Colours of the "+" popover. Measured on the default theme in Light and Dark window appearance.
/// A themed Space takes the same roles from its palette (guess: not captured on a coloured theme).
public struct PlusPopoverColors: Sendable, Hashable {
    public var fill: RGBA
    public var highlight: RGBA
    public var separator: RGBA
    public var label: RGBA
    public var disabled: RGBA
    public var shortcut: RGBA

    /// `system`: the macOS appearance, used by imported themes (they store no window scheme).
    public init(style: SpaceThemeStyle, system: ContentAppearance) {
        let dark = (style.usesLegacyIntensity ? system : style.windowColorScheme) == .dark
        // Fill = the theme's `backgroundExtra` (default theme: #FDFDFF / #050627, exactly the measured fill).
        fill = style.miniPlayerFill(dark ? .dark : .light)
        if let palette = style.palette(for: dark ? .dark : .light) {
            highlight = palette.hover.withAlpha(1)   // guess for coloured themes
        } else {
            highlight = dark ? RGBA(hex: 0x2E3391) : RGBA(hex: 0xD3D4FF)
        }
        separator = highlight   // the line measures the highlight colour
        label = dark ? .white(1) : .black(1)
        disabled = dark ? RGBA(hex: 0x797881) : RGBA(hex: 0xABABAB)
        shortcut = dark ? RGBA(hex: 0x767780) : RGBA(hex: 0xA5AAFF)
    }
}
