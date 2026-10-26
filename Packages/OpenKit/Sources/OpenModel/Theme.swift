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

    public init(
        lightBackground: RGBAColor? = nil, darkBackground: RGBAColor? = nil,
        lightForeground: RGBAColor? = nil, darkForeground: RGBAColor? = nil,
        accent: RGBAColor? = nil,
        gradientStopsLight: [GradientStop] = [], gradientStopsDark: [GradientStop] = [],
        importedArcThemeJSON: Data? = nil
    ) {
        self.lightBackground = lightBackground; self.darkBackground = darkBackground
        self.lightForeground = lightForeground; self.darkForeground = darkForeground
        self.accent = accent
        self.gradientStopsLight = gradientStopsLight; self.gradientStopsDark = gradientStopsDark
        self.importedArcThemeJSON = importedArcThemeJSON
    }
}

public enum SpaceIcon: Codable, Hashable, Sendable {
    case emoji(String)
    case symbol(String)
    case named(String)
}
