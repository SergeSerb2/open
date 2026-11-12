import CoreGraphics
import Foundation
import OpenModel

/// The sidebar's colour rule set (plan D2 §2; capture session 3, Arc 1.172.2,
/// `C-measurements-s3.json`, 45 theme cases). Only two roles take the Space hue:
/// the drawn background and the primary tab title. Every other role is plain black
/// (light content) or plain white (dark content) at a fixed opacity.
///
/// Views read a `SidebarRoles` value and compute no colour themselves. A role set is
/// built once per theme change (`SpaceThemeStyle.roles(_:increaseContrast:)` behind
/// the sidebar's style cache); nothing here runs per row or per frame.
public enum SidebarThemeRules {
    /// §6.5 content appearance bias for every Space mode. 1.172.2's sun and moon do not
    /// force text polarity (Part A §3). Fit: 0.05 ≤ b < 0.35 predicts all 24 pad
    /// observations and the 38 coloured cases (C-report-s3 Part C (2)); 0.2 is the middle.
    public static let polarityBias = 0.2
    /// The fill clamps the key's HSL lightness (P3) into the pad's range: Greyscale1
    /// `#FFFFFF` draws `#EBEAE8`, not `#F6F6F6` (c6-lightest; D2-report-t0 §3).
    public static let fillLightness: ClosedRange<Double> = 0.01...0.97
    /// Light window scheme: the key at α over a gray, mixed in encoded sRGB.
    /// Fit on 38 Light/Automatic shots: mean ΔE00 0.58, max 2.0 (D2-report-t0 §3).
    public static let lightUnderlay = 0.91
    /// Below α 0.5 the light gray darkens (intensity minimum: 0.847).
    public static let lightUnderlaySlope = 0.177
    /// Dark window scheme: today's wash law (encoded P3) with this gray at α ≥ 0.5.
    /// Fit on 19 Dark shots: mean ΔE00 0.58, max 1.6.
    public static let darkUnderlay = 0.67

    /// Gray of the active row plate on light content, drawn at `activePlateOpacity` over
    /// the background: per-channel fit plate = 0.084 · bg + 222.5 over 30 light-content
    /// shots, max ΔE00 1.8 (D2-report-t0 §4).
    public static let activePlateLight = RGBA(hex: 0xF3F3F3, alpha: 0.916)
    /// Lead decision (plan §2.8): with macOS Increase Contrast the primary title keeps
    /// its hue and moves in lightness to at least this contrast against the background.
    public static let increasedTitleContrast = 4.5
}

/// Every sidebar colour for one Space theme and one content appearance.
public struct SidebarRoles: Sendable, Hashable {
    /// Light content takes dark text.
    public var content: ContentAppearance
    /// Primary tab and folder title (inactive, hover and active rows alike).
    public var title: RGBA
    public var subtitle: RGBA
    public var spaceTitle: RGBA
    public var newTabLabel: RGBA
    public var newTabGlyph: RGBA
    public var placeholder: RGBA
    public var urlText: RGBA
    public var bottomGlyph: RGBA
    public var toolbarGlyphDisabled: RGBA
    public var separator: RGBA
    public var fieldFill: RGBA
    public var fieldHover: RGBA
    public var tileFill: RGBA
    public var rowHover: RGBA
    /// Selected row: a layer over the background (translucent), not an opaque tint.
    public var activePlate: RGBA
    /// The last `SidebarRoles.edgeBandWidth` pt at the sidebar's right edge.
    public var edgeBand: RGBA?

    public static let edgeBandWidth: CGFloat = 3

    /// A coloured theme's fixed-opacity role as an appearance pair, for tokens that
    /// resolve against the view's content appearance.
    public static func token(_ role: KeyPath<SidebarRoles, RGBA>) -> DesignColor {
        DesignColor(light: SidebarRoles(content: .light, title: .black(1), isDefaultTheme: false)[keyPath: role],
                    dark: SidebarRoles(content: .dark, title: .white(1), isDefaultTheme: false)[keyPath: role])
    }

    /// Fixed opacities (plan §2.2, measured ± 0.01).
    static func ink(_ content: ContentAppearance, light: Double, dark: Double) -> RGBA {
        content == .dark ? .white(dark) : .black(light)
    }

    /// `isDefaultTheme`: a Space with no colour. Its light hover plate is black 0.046
    /// against 0.08 on coloured themes (C-report-s3 Part C (1)).
    public init(content: ContentAppearance, title: RGBA, isDefaultTheme: Bool, increaseContrast: Bool = false) {
        let ic = increaseContrast
        self.content = content
        self.title = title
        subtitle = Self.ink(content, light: ic ? 0.75 : 0.50, dark: ic ? 0.75 : 0.50)
        spaceTitle = Self.ink(content, light: ic ? 0.75 : 0.45, dark: ic ? 0.75 : 0.45)
        newTabLabel = Self.ink(content, light: ic ? 0.60 : 0.30, dark: ic ? 0.60 : 0.45)
        newTabGlyph = Self.ink(content, light: 0.50, dark: 0.50)
        placeholder = Self.ink(content, light: 0.30, dark: 0.30)
        urlText = Self.ink(content, light: 0.60, dark: 0.60)
        // The bottom-bar plus: medians over 30 / 15 shots (session 3 `bottom_plus`); the
        // Library icon measures 0.552 / 0.588 and Home keeps its own glyph fit.
        bottomGlyph = Self.ink(content, light: 0.565, dark: 0.60)
        toolbarGlyphDisabled = Self.ink(content, light: 0.22, dark: 0.25)
        separator = Self.ink(content, light: ic ? 0.30 : 0.15, dark: ic ? 0.30 : 0.15)
        fieldFill = Self.ink(content, light: 0.043, dark: 0.10)
        fieldHover = Self.ink(content, light: 0.09, dark: 0.15)
        tileFill = Self.ink(content, light: 0.045, dark: 0.10)
        rowHover = Self.ink(content, light: isDefaultTheme ? 0.046 : 0.08, dark: isDefaultTheme ? 0.10 : 0.08)
        activePlate = content == .dark ? .white(0.20) : SidebarThemeRules.activePlateLight
        // Light content: measured black 0.05–0.10 (start 0.07). Dark: not measured, none.
        edgeBand = content == .dark ? nil : .black(0.07)
    }
}

extension SpaceThemeStyle {
    /// The sidebar's role set. Cheap without Increase Contrast (constant selection);
    /// with it, one 3 × 3 field sample for the title. Callers cache per theme change.
    public func roles(_ appearance: ContentAppearance, increaseContrast: Bool = false) -> SidebarRoles {
        var title = titleColor(appearance).withAlpha(1)
        if increaseContrast { title = Self.raised(title, against: fieldSamples(), dark: appearance == .dark) }
        return SidebarRoles(content: appearance, title: title, isDefaultTheme: isDefaultTheme, increaseContrast: increaseContrast)
    }

    /// Content appearance with macOS Increase Contrast (lead decision Q2, 2026-11-12): keep the
    /// theme's polarity when the raised primary title reaches `increasedTitleContrast`;
    /// otherwise the Space takes the other polarity for every role. Callers cache it.
    public func increasedContrastAppearance(system: ContentAppearance) -> ContentAppearance {
        let base = resolvedAppearance(system: system)
        let samples = fieldSamples()
        let raised = Self.raised(titleColor(base).withAlpha(1), against: samples, dark: base == .dark)
        guard Self.worstContrast(raised, samples) < SidebarThemeRules.increasedTitleContrast else { return base }
        return base == .dark ? .light : .dark
    }

    /// The active window's background at 3 × 3 points over the window.
    func fieldSamples() -> [RGBA] {
        let field = ThemeField.Evaluator(style: self, windowSize: CGSize(width: 1000, height: 1000), isActive: true)
        return [0.0, 0.5, 1.0].flatMap { u in
            [0.0, 0.5, 1.0].map { v in
                let (r, g, b) = field.color(u: u, v: v)
                return RGBA(r, g, b)
            }
        }
    }

    /// Moves `color`'s HSL lightness (light text up, dark text down) until its WCAG
    /// contrast against every background reaches `increasedTitleContrast`.
    static func luminance(_ c: RGBA) -> Double {
        func linear(_ value: Double) -> Double {
            let x = min(1, max(0, value))
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
    }

    /// The lowest WCAG contrast of `color` against the backgrounds.
    static func worstContrast(_ color: RGBA, _ backgrounds: [RGBA]) -> Double {
        let ink = luminance(color)
        return backgrounds.map { b in
            let l = luminance(b)
            return (max(ink, l) + 0.05) / (min(ink, l) + 0.05)
        }.min() ?? 21
    }

    /// Moves `color`'s HSL lightness (light text up, dark text down) until its WCAG
    /// contrast against every background reaches `increasedTitleContrast`, or the end.
    static func raised(_ color: RGBA, against backgrounds: [RGBA], dark: Bool) -> RGBA {
        func worst(_ c: RGBA) -> Double { worstContrast(c, backgrounds) }
        let target = SidebarThemeRules.increasedTitleContrast
        guard worst(color) < target else { return color }
        let p3 = ThemeColorMath.toP3(color.modelColor)
        let hsl = ThemeColorMath.hsl(p3)
        var l = hsl.l, result = color
        for _ in 0..<100 where worst(result) < target {
            l = dark ? min(1, l + 0.01) : max(0, l - 0.01)
            result = RGBA(rgba: ThemeColorMath.toExtendedSRGB(ThemeColorMath.rgb(h: hsl.h, s: hsl.s, l: l)))
            if l == 0 || l == 1 { break }
        }
        return result.withAlpha(1)
    }
}
