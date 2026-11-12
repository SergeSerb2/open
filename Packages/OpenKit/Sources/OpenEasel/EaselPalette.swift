import AppKit

/// Colour names of Arc's Easel model (findings §3.3). The stored value is the name, so a
/// palette switch recolours every object.
public enum EaselColor: String, Codable, Sendable, CaseIterable {
    case white, yellow, pink, red, lightGreen, darkGreen, black, gray, purple, lightBlue, darkBlue

    /// Popover order, two rows (capture s4 `e2-*-selected`: white, yellow, orange, red,
    /// green, dark green / black, grey, purple, cyan, blue).
    public static let rows: [[EaselColor]] = [[.white, .yellow, .pink, .red, .lightGreen, .darkGreen],
                                              [.black, .gray, .purple, .lightBlue, .darkBlue]]
}

public enum EaselPalette: String, Codable, Sendable, CaseIterable {
    case vibrant, chill
    public var title: String { self == .vibrant ? "Vibrant" : "Chill" }

    /// Hex values: findings §3.4 table (CAR + export viewer). The capture s4 swatch centres
    /// (`p-swatch-click-*`, `e2-rect-selected`) match Vibrant: #F8D558, #F19E5D, #E2492C,
    /// #34E895, #377820, #BBBBBB, #B0249A, #00C7F3, #3339F1 (display profile).
    public func color(_ c: EaselColor, dark: Bool) -> NSColor {
        let hex: UInt32
        switch c {
        case .white: return dark ? NSColor(white: 0, alpha: 1) : NSColor(white: 1, alpha: 1)
        case .black: return dark ? NSColor(white: 1, alpha: 1) : NSColor(white: 0, alpha: 1)
        case .gray: hex = 0xBBBBBB
        case .darkBlue: hex = 0x3139FB
        case .pink: hex = self == .vibrant ? 0xFF994E : 0xF2C2AC
        case .red: hex = self == .vibrant ? 0xF53714 : 0xD74807
        case .yellow: hex = self == .vibrant ? 0xFFD335 : 0xC2A12A
        case .lightGreen: return self == .vibrant ? Self.p3(0x34E895) : Self.p3(0xD0D87F)
        case .darkGreen: hex = self == .vibrant ? 0x107A00 : 0x1D5914
        case .lightBlue: return self == .vibrant ? Self.p3(0x00C7F3) : Self.p3(0x55A2BD)
        case .purple: hex = self == .vibrant ? 0xC0009F : 0xA6729D
        }
        return Self.srgb(hex)
    }

    static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    static func p3(_ hex: UInt32) -> NSColor {
        NSColor(displayP3Red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Fixed Easel chrome colours (findings §3.4 CAR values; capture s4 for the toolbar).
enum EaselStyle {
    static func dark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
    /// `EaselSelectionColor`; capture `e2-rect-selected` outline #7FB8D6.
    static let selection = EaselPalette.srgb(0x6CBAD9)
    /// Tool glyphs. Capture s4 toolbar: #272FFB light (`e1-new-easel`), #ECEDFE dark (`e2-dark-select`).
    static func toolIcon(dark: Bool) -> NSColor { dark ? EaselPalette.srgb(0xECEDFE) : EaselPalette.srgb(0x2930FB) }
    /// Selected tool plate: #9095FB light, #3F45D2 dark (same frames).
    static func toolPlate(dark: Bool) -> NSColor { dark ? EaselPalette.srgb(0x3F45D2) : EaselPalette.srgb(0x9095FB) }
    static func toolHover(dark: Bool) -> NSColor { dark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.05) }
    /// Floating bar: #FFFFFF light; #050625 dark (`e2-dark-select`).
    static func floating(dark: Bool) -> NSColor { dark ? EaselPalette.srgb(0x050625) : NSColor(white: 1, alpha: 1) }
    /// Divider in the toolbar: #E4E4E6 light, #1E1E3A dark.
    static func divider(dark: Bool) -> NSColor { dark ? EaselPalette.srgb(0x1E1E3A) : EaselPalette.srgb(0xE4E4E6) }
    /// Page: #FDFBFC light (`e1-new-easel`), #16121B dark (`e2-dark-select`).
    static func canvas(dark: Bool) -> NSColor { dark ? EaselPalette.srgb(0x16121B) : EaselPalette.srgb(0xFDFCFD) }
    /// Alignment guide line: #EBEBEB light (`e4-move-guides`); dark GUESS — capture pending.
    static func guide(dark: Bool) -> NSColor { dark ? NSColor(white: 1, alpha: 0.16) : EaselPalette.srgb(0xEBEBEB) }
    /// `EaselTitleText` #101118 80 % / white 80 %.
    static func title(dark: Bool) -> NSColor { dark ? NSColor(white: 1, alpha: 0.8) : EaselPalette.srgb(0x101118).withAlphaComponent(0.8) }
    static func text(dark: Bool) -> NSColor { dark ? NSColor(white: 1, alpha: 0.92) : EaselPalette.srgb(0x101118) }
    static func placeholder(dark: Bool) -> NSColor { dark ? NSColor(white: 1, alpha: 0.35) : NSColor(white: 0, alpha: 0.3) }
}
