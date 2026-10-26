import AppKit

/// A font token: system font (SF Pro) size and weight, matched against live
/// captures by normalized cross-correlation (docs/re/runtime-observations.md §2).
public struct FontToken: Sendable, Hashable {
    public var size: CGFloat
    public var weight: Weight

    public enum Weight: Sendable, Hashable {
        case regular, medium, semibold, bold
        var nsWeight: NSFont.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }
    }

    public init(_ size: CGFloat, _ weight: Weight) { self.size = size; self.weight = weight }

    @MainActor public var font: NSFont { FontCache.font(for: self) }
}

@MainActor
enum FontCache {
    private static var cache: [FontToken: NSFont] = [:]
    static func font(for token: FontToken) -> NSFont {
        if let f = cache[token] { return f }
        let f = NSFont.systemFont(ofSize: token.size, weight: token.weight.nsWeight)
        cache[token] = f
        return f
    }
}

public enum Typography {
    /// Tab title: SF Pro 14 Regular (NCC 0.992–0.994).
    public static let tabTitle = FontToken(14, .regular)
    /// Folder title: 14 Semibold (ink width 70 = SF 14 Semibold, F0079).
    public static let folderTitle = FontToken(14, .semibold)
    /// "New Tab" label: 14 Regular.
    public static let newTab = FontToken(14, .regular)
    /// Space title in the header: 13 Semibold (NCC 0.994).
    public static let spaceTitle = FontToken(13, .semibold)
    /// URL field placeholder: 13 Medium (NCC 0.991).
    public static let urlField = FontToken(13, .medium)
    /// URL field host once a page is loaded: 13 Regular (ink width 59 vs 61 for Medium, F0015).
    public static let urlHost = FontToken(13, .regular)
    /// Pinned/Today "Clear": ink 27×8 → about 11 Semibold.
    public static let clearLabel = FontToken(11, .semibold)
    /// Tooltip label: AX text frame 15 pt tall → 13 pt. guess: Medium.
    public static let tooltip = FontToken(13, .medium)
    /// Tooltip second line ("Double-click to rename"): 14 pt frame → 12 pt. guess: Regular.
    public static let tooltipSubtitle = FontToken(12, .regular)
    /// Keycap glyphs in tooltips. guess.
    public static let keycap = FontToken(12, .medium)
    /// Command bar input and placeholder: 18 Medium. Row title and subtitle: 13 Medium.
    public static let commandBarInput = FontToken(18, .medium)
    public static let commandBarRow = FontToken(13, .medium)
    /// Bottom-bar Space switcher emoji (font size). NCC fit on F0001: 12 pt, 1 pt above center (0.983).
    public static let switcherEmoji = FontToken(12, .regular)
    /// Space header emoji (font size). Fitted by NCC on F0001: 14 pt, 1 pt above center (0.988).
    public static let headerEmoji = FontToken(14, .regular)
}

extension Typography {
    /// Media plan §4: provisional until captures; system SF Pro, no copied fonts.
    public static let miniPlayerTitle = FontToken(13, .medium)
    public static let pipPill = FontToken(12, .semibold)
    public static let pipPrecision = FontToken(11, .medium)
    public static let documentPiPHost = FontToken(12, .medium)
}
