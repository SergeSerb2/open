import AppKit

/// Color space a token was authored in. Keep the space per token: converting a
/// Display P3 token to sRGB shifts the value (see docs/re/design-tokens.md §1.7).
public enum TokenColorSpace: Sendable, Hashable {
    case sRGB
    case displayP3
    /// Extended-range sRGB. Arc theme colors use it; components may leave 0…1.
    case extendedSRGB

    var cgColorSpace: CGColorSpace {
        switch self {
        case .sRGB: CGColorSpace(name: CGColorSpace.sRGB)!
        case .displayP3: CGColorSpace(name: CGColorSpace.displayP3)!
        case .extendedSRGB: CGColorSpace(name: CGColorSpace.extendedSRGB)!
        }
    }
}

/// One color value. Plain data, so it is `Sendable` and cheap to store in tokens.
public struct RGBA: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    public var space: TokenColorSpace

    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1, _ space: TokenColorSpace = .sRGB) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha; self.space = space
    }

    /// `RGBA(hex: 0x0E0F10, alpha: 0.05, .displayP3)`.
    public init(hex: UInt32, alpha: Double = 1, _ space: TokenColorSpace = .sRGB) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha, space)
    }

    public static func white(_ alpha: Double) -> RGBA { RGBA(1, 1, 1, alpha) }
    public static func black(_ alpha: Double) -> RGBA { RGBA(0, 0, 0, alpha) }
    public static let clear = RGBA(0, 0, 0, 0)

    public func withAlpha(_ alpha: Double) -> RGBA { var c = self; c.alpha = alpha; return c }

    public var cgColor: CGColor {
        CGColor(colorSpace: space.cgColorSpace, components: [red, green, blue, alpha].map { CGFloat($0) })!
    }

    public var nsColor: NSColor { NSColor(cgColor: cgColor)! }
}

/// Light and dark pair. "Light" and "dark" follow the content appearance the
/// sidebar runs in. In Arc that is the Space's `contentOverBackgroundAppearance`,
/// not the macOS setting (docs/re/runtime-observations.md §3.3).
public struct DesignColor: Sendable, Hashable {
    public var light: RGBA
    public var dark: RGBA

    public init(light: RGBA, dark: RGBA) { self.light = light; self.dark = dark }
    public init(_ both: RGBA) { light = both; dark = both }

    public func resolved(_ appearance: ContentAppearance) -> RGBA { appearance == .dark ? dark : light }
    public func cgColor(_ appearance: ContentAppearance) -> CGColor { resolved(appearance).cgColor }

    /// Dynamic `NSColor` that resolves against the drawing appearance.
    public var nsColor: NSColor {
        let pair = self
        return NSColor(name: nil) { appearance in
            pair.resolved(ContentAppearance(appearance)).nsColor
        }
    }
}

/// Which text palette the sidebar uses. Light content means dark text.
public enum ContentAppearance: String, Sendable, Hashable {
    case light, dark

    public init(_ appearance: NSAppearance) {
        self = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    public var nsAppearance: NSAppearance { NSAppearance(named: self == .dark ? .darkAqua : .aqua)! }
}

extension NSView {
    /// The content appearance this view resolves tokens against.
    public var contentAppearance: ContentAppearance { ContentAppearance(effectiveAppearance) }
}
