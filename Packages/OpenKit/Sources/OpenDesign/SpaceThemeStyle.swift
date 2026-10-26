import Foundation
import OpenModel

/// The 12 role colors Arc stores per content appearance
/// (`semanticColorPalette.appearanceBased.{light,dark}`).
public struct SemanticPalette: Sendable, Hashable {
    public var background: RGBA
    public var backgroundExtra: RGBA
    public var title: RGBA
    public var subtitle: RGBA
    public var hover: RGBA
    public var focus: RGBA
    public var foregroundPrimary: RGBA
    public var foregroundSecondary: RGBA
    public var foregroundTertiary: RGBA
    public var minContrast: RGBA
    public var maxContrast: RGBA
    public var cutout: RGBA
}

/// Everything the background renderer and the sidebar need from a Space theme.
/// Built from `OpenModel.SpaceTheme`: the imported Arc `windowTheme` JSON when
/// present, else the mapped gradient stops, else the default theme.
public struct SpaceThemeStyle: Sendable, Hashable {
    public enum Fill: Sendable, Hashable {
        /// Arc `blendedGradient` (base 2 colors, overlay 2 colors) or
        /// `blendedSingleColor` (base 1 color, no overlay).
        case blended(base: [RGBA], overlay: [RGBA])
        /// Final on-screen corner colors (TL, TR, BL, BR), drawn as is. Used for the
        /// default theme, which we only know from captures.
        case corners([RGBA])
    }

    public enum Translucency: String, Sendable, Hashable { case light, dark }

    public var fill: Fill
    /// Grain amount, 0…1 (`modifiers.noiseFactor`).
    public var noiseFactor: Double
    /// `modifiers.intensityFactor`. Its effect is not yet known; see docs/design.md.
    public var intensityFactor: Double
    public var translucency: Translucency
    /// Text palette. `nil` follows the macOS appearance (default theme only).
    public var contentAppearance: ContentAppearance?
    public var isVibrant: Bool
    public var lightPalette: SemanticPalette?
    public var darkPalette: SemanticPalette?
    /// `primaryColorPalette.shaded`: the theme's strong accent. Nil for the default theme.
    public var accent: RGBA?
    public var shadedDarkAccent: RGBA?
    public var tintedLightAccent: RGBA?

    public init(fill: Fill, noiseFactor: Double = 0, intensityFactor: Double = 0.8, translucency: Translucency = .light,
                contentAppearance: ContentAppearance? = .light, isVibrant: Bool = true,
                lightPalette: SemanticPalette? = nil, darkPalette: SemanticPalette? = nil, accent: RGBA? = nil, shadedDarkAccent: RGBA? = nil, tintedLightAccent: RGBA? = nil) {
        self.fill = fill; self.noiseFactor = noiseFactor; self.intensityFactor = intensityFactor
        self.translucency = translucency; self.contentAppearance = contentAppearance; self.isVibrant = isVibrant
        self.lightPalette = lightPalette; self.darkPalette = darkPalette; self.accent = accent
        self.shadedDarkAccent = shadedDarkAccent; self.tintedLightAccent = tintedLightAccent
    }

    /// Content appearance after applying the system fallback.
    public func resolvedAppearance(system: ContentAppearance) -> ContentAppearance { contentAppearance ?? system }

    public func palette(for appearance: ContentAppearance) -> SemanticPalette? {
        appearance == .dark ? darkPalette : lightPalette
    }

    /// Tab and folder title color. Measured: fully covered title pixels equal the
    /// theme's `title` for the content appearance (#320E00 in Space 1). Without a
    /// theme: measured on the default dark Space (F0072), see `DefaultThemeText`.
    public func titleColor(_ appearance: ContentAppearance) -> RGBA {
        if let p = palette(for: appearance) { return p.title }
        return DefaultThemeText.title.resolved(appearance)
    }

    /// Split-row cell titles. Default theme: measured dimmer (F0079). Themes: guess, the title color.
    public func splitTitleColor(_ appearance: ContentAppearance) -> RGBA {
        if let p = palette(for: appearance) { return p.title }
        return DefaultThemeText.splitTitle.resolved(appearance)
    }

    /// Selected row and selected favorite tile fill. Light content: the theme's
    /// `light.background`, opaque (measured #F6EBE7 / #F7E8E2 against #F6EAE4; a
    /// white overlay does not fit, F0014, F0016). Dark content: white 0.20 (F0084, F0161).
    public func selectedFill(_ appearance: ContentAppearance) -> RGBA {
        if appearance == .light, let p = lightPalette { return p.background.withAlpha(1) }
        return SidebarRole.rowSelected.resolved(appearance)
    }

    /// Folder glyph and other accent marks. Default theme: measured #1E29FF on
    /// the default dark Space (F0079) → `BrandBlue`. Themes: guess `shaded`.
    public func accentColor(_ appearance: ContentAppearance) -> RGBA {
        accent ?? Core.brandBlue.resolved(appearance)
    }

    /// Guess pending C5/C6: preserve the Space accent if it meets the target,
    /// then try the theme's darker accent, then the title color. Folder glyphs
    /// retain their separately measured accent role. Callers with a solid card
    /// supply its actual background; rows conservatively cover the gradient.
    public func contrastAccent(_ appearance: ContentAppearance, against background: RGBA? = nil, minimumContrast: Double = 3) -> RGBA {
        let backgrounds: [RGBA]
        if let background { backgrounds = [background] }
        else {
            let field = ThemeField.Evaluator(style: self, windowSize: CGSize(width: 1000, height: 1000), isActive: true)
            backgrounds = [0.0, 0.5, 1.0].flatMap { u in
                [0.0, 0.5, 1.0].map { v in
                    let (r, g, b) = field.color(u: u, v: v)
                    return RGBA(r, g, b)
                }
            }
        }
        func luminance(_ color: RGBA) -> Double {
            func linear(_ value: Double) -> Double {
                let x = min(1, max(0, value))
                return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            return linear(color.red) * 0.2126 + linear(color.green) * 0.7152 + linear(color.blue) * 0.0722
        }
        for candidate in [accentColor(appearance), shadedDarkAccent].compactMap({ $0 }) {
            let ink = luminance(candidate)
            if backgrounds.allSatisfy({ base in
                let background = luminance(base)
                return (max(ink, background) + 0.05) / (min(ink, background) + 0.05) >= minimumContrast
            }) { return candidate.withAlpha(1) }
        }
        return titleColor(appearance).withAlpha(1)
    }

    /// Tooltip capsule fill: the theme's `light.title`, opaque (exact match, F0021–F0033).
    /// Without a theme (the default theme): `#0A0D4F`, its `light.title` equivalent,
    /// measured exact after display-profile → sRGB conversion in capture session 2
    /// (default dark theme: S2 14b/0024, 03/0010, 03/0014, 19/0025; the same capsule
    /// color as the link status bubble, S2 04/0021). No default-theme tooltip was
    /// captured in macOS Light (S2 item 20 has no tooltip window), so applying the
    /// same value there follows the `light.title` role. guess for that case.
    public var tooltipFill: RGBA { lightPalette?.title.withAlpha(1) ?? RGBA(hex: 0x0A0D4F) }
    /// Tooltip text: light and tinted. guess: the theme's `light.background`.
    public var tooltipText: RGBA { lightPalette?.background.withAlpha(1) ?? RGBA(hex: 0xF4F4F6) }
    /// Keycap plate inside a tooltip. guess: tooltip text at 18 %.
    public var tooltipKeycap: RGBA { tooltipText.withAlpha(0.18) }

    // MARK: Default theme

    /// The look of a Space without a stored theme. Measured in dark mode
    /// (active window corners, sRGB): TL #252538, TR #322438, BL #2C2437, BR #342237.
    /// The light variant is a guess (no light-mode capture yet).
    public static func defaultTheme(system: ContentAppearance) -> SpaceThemeStyle {
        let corners: [RGBA] = system == .dark
            ? [RGBA(hex: 0x252538), RGBA(hex: 0x322438), RGBA(hex: 0x2C2437), RGBA(hex: 0x342237)]
            : [RGBA(hex: 0xEDEDF1), RGBA(hex: 0xEDEBF1), RGBA(hex: 0xEAE9EF), RGBA(hex: 0xEAE8EF)]
        return SpaceThemeStyle(fill: .corners(corners), noiseFactor: 0, translucency: system == .dark ? .dark : .light,
                               contentAppearance: nil, isVibrant: true)
    }

    // MARK: From the model

    public init(theme: SpaceTheme, system: ContentAppearance) {
        if let data = theme.importedArcThemeJSON, let parsed = SpaceThemeStyle(arcWindowThemeJSON: data) {
            self = parsed
            return
        }
        if theme.gradientStopsLight.count >= 1 {
            let stops = theme.gradientStopsLight.sorted { $0.location < $1.location }.map { RGBA(rgba: $0.color) }
            self.init(fill: .blended(base: Array(stops.prefix(2)), overlay: []), contentAppearance: nil)
            return
        }
        self = .defaultTheme(system: system)
    }

    /// Parses Arc's `customInfo.windowTheme` object (schema in
    /// docs/re/runtime-observations.md §3.3). Returns nil for unknown shapes.
    public init?(arcWindowThemeJSON data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let background = root["background"] as? [String: Any],
              let single = (background["single"] as? [String: Any])?["_0"] as? [String: Any],
              let style = single["style"] as? [String: Any],
              let color = (style["color"] as? [String: Any])?["_0"] as? [String: Any] else { return nil }

        var fill: Fill
        var modifiers: [String: Any] = [:]
        var translucency = Translucency.light
        if let g = (color["blendedGradient"] as? [String: Any])?["_0"] as? [String: Any] {
            let base = (g["baseColors"] as? [[String: Any]] ?? []).compactMap(RGBA.init(arcColor:))
            let overlay = (g["overlayColors"] as? [[String: Any]] ?? []).compactMap(RGBA.init(arcColor:))
            guard !base.isEmpty else { return nil } // "BlendedGradientConfiguration has no colors."
            fill = .blended(base: Array(base.prefix(2)), overlay: overlay.count >= 2 ? Array(overlay.prefix(2)) : [])
            modifiers = g["modifiers"] as? [String: Any] ?? [:]
            translucency = Translucency(rawValue: g["translucencyStyle"] as? String ?? "light") ?? .light
        } else if let s = (color["blendedSingleColor"] as? [String: Any])?["_0"] as? [String: Any],
                  let c = (s["color"] as? [String: Any]).flatMap(RGBA.init(arcColor:)) {
            fill = .blended(base: [c], overlay: [])
            modifiers = s["modifiers"] as? [String: Any] ?? [:]
            translucency = Translucency(rawValue: s["translucencyStyle"] as? String ?? "light") ?? .light
        } else {
            return nil
        }

        func palette(_ key: String) -> SemanticPalette? {
            guard let semantic = root["semanticColorPalette"] as? [String: Any],
                  let based = semantic["appearanceBased"] as? [String: Any],
                  let p = based[key] as? [String: Any] else { return nil }
            func c(_ k: String) -> RGBA? { (p[k] as? [String: Any]).flatMap(RGBA.init(arcColor:)) }
            guard let background = c("background"), let title = c("title") else { return nil }
            return SemanticPalette(
                background: background, backgroundExtra: c("backgroundExtra") ?? background, title: title,
                subtitle: c("subtitle") ?? title, hover: c("hover") ?? background, focus: c("focus") ?? background,
                foregroundPrimary: c("foregroundPrimary") ?? title, foregroundSecondary: c("foregroundSecondary") ?? title,
                foregroundTertiary: c("foregroundTertiary") ?? title, minContrast: c("minContrastColor") ?? background,
                maxContrast: c("maxContrastColor") ?? title, cutout: c("cutoutColor") ?? background)
        }

        let appearance = (single["contentOverBackgroundAppearance"] as? String).flatMap(ContentAppearance.init(rawValue:))
        let primary = root["primaryColorPalette"] as? [String: Any]
        let shaded = (primary?["shaded"] as? [String: Any]).flatMap(RGBA.init(arcColor:))
        self.init(fill: fill,
                  noiseFactor: (modifiers["noiseFactor"] as? NSNumber)?.doubleValue ?? 0,
                  intensityFactor: (modifiers["intensityFactor"] as? NSNumber)?.doubleValue ?? 0.8,
                  translucency: translucency,
                  contentAppearance: appearance ?? .light,
                  isVibrant: single["isVibrant"] as? Bool ?? true,
                  lightPalette: palette("light"), darkPalette: palette("dark"), accent: shaded,
                  shadedDarkAccent: (primary?["shadedDark"] as? [String: Any]).flatMap(RGBA.init(arcColor:)),
                  tintedLightAccent: (primary?["tintedLight"] as? [String: Any]).flatMap(RGBA.init(arcColor:)))
    }
}

extension RGBA {
    /// Arc color object: `{red, green, blue, alpha, colorSpace: "extendedSRGB"}`.
    init?(arcColor d: [String: Any]) {
        func v(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        guard let r = v("red"), let g = v("green"), let b = v("blue") else { return nil }
        self.init(r, g, b, v("alpha") ?? 1, .extendedSRGB)
    }

    init(rgba c: RGBAColor) { self.init(c.red, c.green, c.blue, c.alpha, .extendedSRGB) }
}

/// Text colors for Spaces without a stored theme (they follow the macOS appearance).
public enum DefaultThemeText {
    /// Tab title. Dark: lavender #DDDEFF, from core pixels #D9DAFA on F0079 corrected
    /// for anti-aliasing. Light: guess (no light-mode capture).
    public static let title = DesignColor(light: RGBA(hex: 0x0E0F10, alpha: 0.9, .displayP3), dark: RGBA(hex: 0xDDDEFF))
    /// Split-row titles: dimmer and neutral. Dark: white 0.80 (`ForegroundPrimary`), F0079.
    public static let splitTitle = Core.foregroundPrimary
}
