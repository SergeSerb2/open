import Foundation
import OpenModel

public struct SpaceStylePreset: Sendable, Hashable {
    public var name: String
    public var style: SpaceStyle
}

/// Facts: docs/re/design-tokens.md §6.2. Page 2 is the lead's v1 choice.
public enum SpaceStylePresets {
    public static let pageCount = 5
    public static let swatchesPerPage = 9
    public static let all: [SpaceStylePreset] = {
        let brand: [RGBAColor] = [
            srgb(0xF2EAE4), srgb(0xF29BBB), srgb(0xA6729D), srgb(0xF25E6B), srgb(0xFF8558),
            p3(0xF2D66D), p3(0x73E59C), p3(0x7EB8D6), p3(0x666786),
        ]
        let pastel = [0xFDFBFA, 0xFBEAF3, 0xECD2EA, 0xF7CDD2, 0xFAE1D5, 0xFEF9E7, 0xE4FCEC, 0xE0F2FB, 0xC5C6E2].map { p3(UInt32($0)) }
        let drab = [0x4B3B58, 0x623856, 0x854444, 0xA77048, 0xD1B46A, 0xCDCCA8, 0x84A885, 0x34604B, 0x2D4468].map { p3(UInt32($0)) }
        let gray = [0xFFFFFF, 0xE5E5E5, 0xCCCCCC, 0xB2B2B2, 0x808080, 0x666666, 0x333333, 0x1A1A1A, 0x000000].map { p3(UInt32($0)) }
        let pages = [brand, brand, pastel, drab, gray]
        return pages.enumerated().flatMap { page, colors in
            colors.enumerated().map { i, color in
                let set = ["Brand", "Brand", "Pastel", "Drab", "Greyscale"][page]
                return SpaceStylePreset(name: "\(set) \(i + 1)" + (page == 1 ? " gradient" : ""),
                                        style: SpaceStyle(keyColor: color, colorCount: page == 1 ? 3 : 1))
            }
        }
    }()

    private static func srgb(_ hex: UInt32) -> RGBAColor { RGBA(hex: hex).modelColor }
    private static func p3(_ hex: UInt32) -> RGBAColor {
        let c = RGBA(hex: hex)
        return ThemeColorMath.toExtendedSRGB(P3(c.red, c.green, c.blue))
    }
}

extension SpaceStyle {
    /// Opening an editor seeds local state only. The caller writes on the first edit.
    public static func seed(from theme: SpaceTheme) -> SpaceStyle? {
        if let style = theme.style { return style }
        if let data = theme.importedArcThemeJSON,
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let single = (root["background"] as? [String: Any])?["single"] as? [String: Any],
           let payload = single["_0"] as? [String: Any],
           let style = payload["style"] as? [String: Any],
           let color = (style["color"] as? [String: Any])?["_0"] as? [String: Any] {
            func body(_ key: String) -> [String: Any]? {
                guard let value = color[key] as? [String: Any] else { return nil }
                return value["_0"] as? [String: Any] ?? value
            }
            let gradient = body("blendedGradient")
            let value = gradient ?? body("blendedSingleColor") ?? body("basicColor")
            let bases = gradient?["baseColors"] as? [[String: Any]]
            let overlay = gradient?["overlayColors"] as? [[String: Any]] ?? []
            if let value, let key = (bases?.first ?? value["color"] as? [String: Any]).flatMap(RGBA.init(arcColor:)) {
                let modifiers = value["modifiers"] as? [String: Any] ?? [:]
                let wheel = (value["wheel"] as? [String: Any])?.keys.contains("complimentary") == true
                    ? SpaceStyleWheel.complementary : .analogous
                let count = gradient == nil ? 1 : (overlay.count > 1 && (overlay[1]["alpha"] as? Double ?? 1) > 0 ? 3 : 2)
                var result = SpaceStyle(keyColor: key.modelColor, colorCount: count, wheel: wheel,
                                        noiseFactor: modifiers["noiseFactor"] as? Double ?? 0,
                                        texture: SpaceStyleTexture(rawValue: modifiers["overlay"] as? String ?? "grain") ?? .grain,
                                        intensityFactor: modifiers["intensityFactor"] as? Double ?? 0.8)
                let derived = SpaceThemeStyle(style: result, system: .light).contentAppearance
                if let stored = (payload["contentOverBackgroundAppearance"] as? String).flatMap(ContentAppearance.init(rawValue:)), stored != derived {
                    result.appearance = stored == .light ? .light : .dark
                }
                return result
            }
        }
        return theme.gradientStopsLight.sorted { $0.location < $1.location }.first.map { SpaceStyle(keyColor: $0.color) }
    }
}
