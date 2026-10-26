import Foundation

public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
}

public struct GradientStop: Codable, Hashable, Sendable {
    public var location: Double
    public var color: RGBAColor
    public init(location: Double, color: RGBAColor) { self.location = location; self.color = color }
}

public enum SpaceStyleWheel: String, Codable, Sendable, CaseIterable {
    case analogous, complementary
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .analogous
    }
}

public enum SpaceStyleAppearance: String, Codable, Sendable, CaseIterable {
    case automatic, light, dark
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .automatic
    }
}

public enum SpaceStyleTexture: String, Codable, Sendable, CaseIterable {
    case grain, sand, denim, tweed
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .grain
    }
}

/// Editor inputs. Derived palettes are not persisted. A math version never changes meaning.
public struct SpaceStyle: Codable, Hashable, Sendable {
    public static let currentMathVersion = 1
    public var mathVersion: Int
    public var keyColor: RGBAColor { didSet { keyColor.alpha = 1 } }
    public var colorCount: Int { didSet { colorCount = min(3, max(1, colorCount)) } }
    public var wheel: SpaceStyleWheel
    public var appearance: SpaceStyleAppearance
    public var noiseFactor: Double { didSet { noiseFactor = min(1, max(0, noiseFactor)) } }
    public var texture: SpaceStyleTexture
    public var intensityFactor: Double { didSet { intensityFactor = min(1, max(0, intensityFactor)) } }

    public init(keyColor: RGBAColor, colorCount: Int = 1, wheel: SpaceStyleWheel = .analogous,
                appearance: SpaceStyleAppearance = .automatic, noiseFactor: Double = 0,
                texture: SpaceStyleTexture = .grain, intensityFactor: Double = 0.8,
                mathVersion: Int = SpaceStyle.currentMathVersion) {
        self.mathVersion = mathVersion
        self.keyColor = RGBAColor(red: keyColor.red, green: keyColor.green, blue: keyColor.blue)
        self.colorCount = min(3, max(1, colorCount)); self.wheel = wheel; self.appearance = appearance
        self.noiseFactor = min(1, max(0, noiseFactor)); self.texture = texture
        self.intensityFactor = min(1, max(0, intensityFactor))
    }

    private enum CodingKeys: String, CodingKey {
        case mathVersion, keyColor, colorCount, wheel, appearance, noiseFactor, texture, intensityFactor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keyColor: try c.decode(RGBAColor.self, forKey: .keyColor),
                  colorCount: try c.decode(Int.self, forKey: .colorCount),
                  wheel: try c.decode(SpaceStyleWheel.self, forKey: .wheel),
                  appearance: try c.decode(SpaceStyleAppearance.self, forKey: .appearance),
                  noiseFactor: try c.decode(Double.self, forKey: .noiseFactor),
                  texture: try c.decode(SpaceStyleTexture.self, forKey: .texture),
                  intensityFactor: try c.decode(Double.self, forKey: .intensityFactor),
                  mathVersion: try c.decode(Int.self, forKey: .mathVersion))
    }
}

/// Generic Space theme. Holds mapped palette values plus the raw Arc theme JSON.
public struct SpaceTheme: Codable, Hashable, Sendable {
    public var lightBackground: RGBAColor?
    public var darkBackground: RGBAColor?
    public var lightForeground: RGBAColor?
    public var darkForeground: RGBAColor?
    public var accent: RGBAColor?
    public var gradientStopsLight: [GradientStop]
    public var gradientStopsDark: [GradientStop]
    public var importedArcThemeJSON: Data?
    public var style: SpaceStyle?

    public init(
        lightBackground: RGBAColor? = nil, darkBackground: RGBAColor? = nil,
        lightForeground: RGBAColor? = nil, darkForeground: RGBAColor? = nil,
        accent: RGBAColor? = nil,
        gradientStopsLight: [GradientStop] = [], gradientStopsDark: [GradientStop] = [],
        importedArcThemeJSON: Data? = nil, style: SpaceStyle? = nil
    ) {
        self.lightBackground = lightBackground; self.darkBackground = darkBackground
        self.lightForeground = lightForeground; self.darkForeground = darkForeground
        self.accent = accent
        self.gradientStopsLight = gradientStopsLight; self.gradientStopsDark = gradientStopsDark
        self.importedArcThemeJSON = importedArcThemeJSON
        self.style = style
    }
}

public enum SpaceIcon: Codable, Hashable, Sendable {
    case emoji(String)
    case symbol(String)
    case named(String)
}
