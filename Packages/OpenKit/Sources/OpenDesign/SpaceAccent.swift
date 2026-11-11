import CoreGraphics
import Foundation

/// The Space accent for selections and tints (command card, inline address editor,
/// Site Control panel). One function, so the theme pass (D2) changes only this file.
///
/// Provisional rule (plan D3 §2.6), fitted on Arc's golden Space (sidebar `#B9A35F` → `#A8904D`,
/// C-measurements-s2 Arc08): accent `#BBA872`, dark accent `#7F6623`.
/// - accent = the sidebar's top colour mixed `accentWhiteMix` toward white (gold: ΔE00 1.84), at most
///   `accentMaxLightness` light;
/// - dark accent = the top colour's hue at `darkLightness` lightness, saturation × `darkSaturationScale`
///   (gold: ΔE00 1.21).
/// - Open's default theme (no stored theme, "Night") uses the lead's mock-up values `#6F66D9` / `#5148C4`:
///   its near-neutral dark sidebar has no hue for the rule to keep.
/// The tints are fitted on the same capture (Arc08 input row 18 pt from the left edge: Light `#F5EFDE`
/// over `#F9F9F9` → ΔE00 0.39; Dark `#292213` over `#30302E` → ΔE00 1.66).
public struct SpaceAccent: Sendable, Hashable {
    /// Selection fill in Light appearance; selection text highlight base.
    public var accent: RGBA
    /// Selection fill in Dark appearance; key cap glyph; Site Control setting circle.
    public var darkAccent: RGBA
    /// Horizontal tint at the left edge of a card (fades to clear), per appearance.
    public var lightTint: RGBA
    public var darkTint: RGBA

    public static let accentWhiteMix = 0.08
    /// White text must stay readable on the selection: a light (pastel) sidebar's accent keeps its hue and
    /// saturation at this HSL lightness at most. Gold (0.59) is below it and unchanged. D3 addition, not in plan §2.6.
    public static let accentMaxLightness = 0.62
    public static let darkLightness = 0.32
    public static let darkSaturationScale = 1.4
    /// Tint colour: the accent hue at a fixed lightness, saturation scaled from the accent's.
    public static let lightTintLightness = 0.77, lightTintSaturationScale = 1.98, lightTintAlpha = 0.33
    public static let darkTintLightness = 0.07, darkTintSaturationScale = 2.72, darkTintAlpha = 0.65

    public static let night = SpaceAccent(accent: RGBA(hex: 0x6F66D9), darkAccent: RGBA(hex: 0x5148C4))

    public init(accent: RGBA, darkAccent: RGBA) {
        self.accent = accent; self.darkAccent = darkAccent
        let (h, _, s) = Self.hls(accent)
        lightTint = Self.rgb(h: h, l: Self.lightTintLightness, s: min(1, s * Self.lightTintSaturationScale)).withAlpha(Self.lightTintAlpha)
        darkTint = Self.rgb(h: h, l: Self.darkTintLightness, s: min(1, s * Self.darkTintSaturationScale)).withAlpha(Self.darkTintAlpha)
    }

    /// The accent for a Space theme (nil: Open's default theme).
    public init(style: SpaceThemeStyle?) {
        guard let style, !style.isDefaultTheme else { self = .night; return }
        let field = ThemeField.Evaluator(style: style, windowSize: CGSize(width: 1280, height: 800), isActive: true)
        // The sidebar's top: the URL field row, centred in a 366 pt sidebar.
        let (r, g, b) = field.color(u: 183.0 / 1280, v: 64.0 / 800)
        let top = RGBA(min(1, max(0, r)), min(1, max(0, g)), min(1, max(0, b)))
        self.init(top: top)
    }

    /// The provisional rule from the sidebar's top colour.
    public init(top: RGBA) {
        let m = Self.accentWhiteMix
        var accent = RGBA(top.red + (1 - top.red) * m, top.green + (1 - top.green) * m, top.blue + (1 - top.blue) * m)
        let (ah, al, asat) = Self.hls(accent)
        if al > Self.accentMaxLightness { accent = Self.rgb(h: ah, l: Self.accentMaxLightness, s: asat) }
        let (h, _, s) = Self.hls(top)
        let dark = Self.rgb(h: h, l: Self.darkLightness, s: min(1, s * Self.darkSaturationScale))
        self.init(accent: accent, darkAccent: dark)
    }

    /// Selected row fill: Light uses the accent, Dark the dark accent.
    public func selection(dark: Bool) -> RGBA { dark ? darkAccent : accent }
    public func tint(dark: Bool) -> RGBA { dark ? darkTint : lightTint }

    static func hls(_ c: RGBA) -> (h: Double, l: Double, s: Double) {
        let r = c.red, g = c.green, b = c.blue
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2
        guard mx != mn else { return (0, l, 0) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h /= 6
        return (h, l, s)
    }

    static func rgb(h: Double, l: Double, s: Double) -> RGBA {
        guard s > 0 else { return RGBA(l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
        func f(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return RGBA(f(h + 1.0 / 3), f(h), f(h - 1.0 / 3))
    }
}

extension SpaceThemeStyle {
    /// True for a Space without a stored theme (`defaultTheme(system:)`).
    public var isDefaultTheme: Bool {
        if case .corners = fill, contentAppearance == nil, lightPalette == nil, darkPalette == nil { return true }
        return false
    }
}
