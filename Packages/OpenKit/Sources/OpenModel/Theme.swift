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
        guard let key = try c.decodeIfPresent(RGBAColor.self, forKey: .keyColor) else {
            throw DecodingError.keyNotFound(CodingKeys.keyColor, .init(codingPath: c.codingPath,
                debugDescription: "A Space style needs a key color"))
        }
        self.init(keyColor: key,
                  colorCount: (try? c.decodeIfPresent(Int.self, forKey: .colorCount)) ?? 1,
                  wheel: (try? c.decodeIfPresent(SpaceStyleWheel.self, forKey: .wheel)) ?? .analogous,
                  appearance: (try? c.decodeIfPresent(SpaceStyleAppearance.self, forKey: .appearance)) ?? .automatic,
                  noiseFactor: (try? c.decodeIfPresent(Double.self, forKey: .noiseFactor)) ?? 0,
                  texture: (try? c.decodeIfPresent(SpaceStyleTexture.self, forKey: .texture)) ?? .grain,
                  intensityFactor: (try? c.decodeIfPresent(Double.self, forKey: .intensityFactor)) ?? 0.8,
                  mathVersion: (try? c.decodeIfPresent(Int.self, forKey: .mathVersion)) ?? SpaceStyle.currentMathVersion)
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

    private enum CodingKeys: String, CodingKey {
        case lightBackground, darkBackground, lightForeground, darkForeground, accent
        case gradientStopsLight, gradientStopsDark, importedArcThemeJSON, style
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Legacy fields retain their original decode contract. An unusable optional
        // editor style falls back to nil, rather than losing the whole snapshot.
        self.init(lightBackground: try c.decodeIfPresent(RGBAColor.self, forKey: .lightBackground),
                  darkBackground: try c.decodeIfPresent(RGBAColor.self, forKey: .darkBackground),
                  lightForeground: try c.decodeIfPresent(RGBAColor.self, forKey: .lightForeground),
                  darkForeground: try c.decodeIfPresent(RGBAColor.self, forKey: .darkForeground),
                  accent: try c.decodeIfPresent(RGBAColor.self, forKey: .accent),
                  gradientStopsLight: try c.decode([GradientStop].self, forKey: .gradientStopsLight),
                  gradientStopsDark: try c.decode([GradientStop].self, forKey: .gradientStopsDark),
                  importedArcThemeJSON: try c.decodeIfPresent(Data.self, forKey: .importedArcThemeJSON),
                  style: try? c.decodeIfPresent(SpaceStyle.self, forKey: .style))
    }

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
