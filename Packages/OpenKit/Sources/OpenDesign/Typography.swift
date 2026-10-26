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
    /// Tab title and folder title: SF Pro 14 Regular (NCC 0.992–0.994).
    public static let tabTitle = FontToken(14, .regular)
    /// "New Tab" label: 14 Regular.
    public static let newTab = FontToken(14, .regular)
    /// Space title in the header: 13 Semibold (NCC 0.994).
    public static let spaceTitle = FontToken(13, .semibold)
    /// URL field placeholder and host: 13 Medium (NCC 0.991).
    public static let urlField = FontToken(13, .medium)
    /// Pinned/Today divider "Clear" label. guess: 12 Semibold; verify.
    public static let dividerLabel = FontToken(12, .semibold)
    /// Bottom-bar emoji size for Space switcher icons. guess from 13–15 pt ink.
    public static let switcherEmoji = FontToken(14, .regular)
    /// Space header emoji (ink ≈ 18×17 in a 26 pt frame).
    public static let headerEmoji = FontToken(17, .regular)
}
