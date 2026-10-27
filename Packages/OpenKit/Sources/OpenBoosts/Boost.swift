import Foundation

public struct BoostID: Hashable, Codable, Sendable, CustomStringConvertible {
    public var rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init(uuidString: String) { self.rawValue = UUID(uuidString: uuidString) ?? UUID() }
    public var description: String { rawValue.uuidString }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        rawValue = UUID(uuidString: try c.decode(String.self)) ?? UUID()
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue.uuidString)
    }
}

public struct SiteMatch: Codable, Hashable, Sendable {
    public var domain: String
    public var pathPrefix: String?

    public init(domain: String, pathPrefix: String? = nil) {
        var host = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("*.") { host.removeFirst(2) }
        if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
        host = String(host.prefix { !"/?#".contains($0) })
        // Preserve IPv6 literals; a colon here is not a port separator.
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") {
            host = String(host[host.index(after: host.startIndex)..<end])
        } else if host.filter({ $0 == ":" }).count < 2 {
            host = String(host.prefix { $0 != ":" })
        }
        if host.hasSuffix(".") { host.removeLast() }
        self.domain = host
        let parts = (pathPrefix ?? "").split(separator: "/", omittingEmptySubsequences: true)
        self.pathPrefix = host.isEmpty || parts.isEmpty ? nil : "/" + parts.joined(separator: "/")
    }

    public static func normalized(domain: String, pathPrefix: String?) -> SiteMatch {
        SiteMatch(domain: domain, pathPrefix: pathPrefix)
    }

    public func matches(host: String, path: String) -> Bool {
        guard !domain.isEmpty, host == domain || (!Self.isIP(host) && host.hasSuffix("." + domain)) else { return false }
        guard let pathPrefix else { return true }
        return path == pathPrefix || path.hasPrefix(pathPrefix + "/")
    }

    public var targetsIPAddress: Bool { Self.isIP(domain) }

    static func isIP(_ host: String) -> Bool {
        if host.contains(":") || host.hasPrefix("[") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private enum CodingKeys: String, CodingKey { case domain, pathPrefix }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(domain: try c.decode(String.self, forKey: .domain), pathPrefix: try c.decodeIfPresent(String.self, forKey: .pathPrefix))
    }
}

public struct ColorAdjustment: Codable, Hashable, Sendable {
    public var hueRotateDegrees: Double
    public var saturation: Double
    public var brightness: Double
    public var contrast: Double
    public var invert: Double

    public init(hueRotateDegrees: Double = 0, saturation: Double = 1, brightness: Double = 1, contrast: Double = 1, invert: Double = 0) {
        self.hueRotateDegrees = hueRotateDegrees; self.saturation = saturation
        self.brightness = brightness; self.contrast = contrast; self.invert = invert
    }
    public static var identity: ColorAdjustment { ColorAdjustment() }
    public var isIdentity: Bool {
        let c = clamped()
        return abs(c.hueRotateDegrees) < 1e-9 && abs(c.saturation - 1) < 1e-9 && abs(c.brightness - 1) < 1e-9 && abs(c.contrast - 1) < 1e-9 && abs(c.invert) < 1e-9
    }
    public func clamped() -> ColorAdjustment {
        func clamp(_ v: Double, _ upper: Double, _ identity: Double) -> Double {
            v.isNaN ? identity : min(upper, max(0, v))
        }
        let h = hueRotateDegrees.isFinite ? hueRotateDegrees.truncatingRemainder(dividingBy: 360) : 0
        return ColorAdjustment(hueRotateDegrees: h < 0 ? h + 360 : h,
                               saturation: clamp(saturation, 3, 1), brightness: clamp(brightness, 3, 1),
                               contrast: clamp(contrast, 3, 1), invert: clamp(invert, 1, 0))
    }
}

/// Editor inputs. Runtime filters are derived by BoostStore's normalization.
public struct BoostColorWheel: Codable, Hashable, Sendable {
    /// Zero at 3 o’clock, increasing clockwise on screen; runtime math is unchanged.
    public var hue: Double
    public var intensity: Double
    public var baseHue: Double?
    public var invertLightness: Bool
    public var brightness: Double
    public var contrast: Double
    public var originalSaturation: Double

    public init(hue: Double = 0, intensity: Double = 0, baseHue: Double? = nil, invertLightness: Bool = false,
                brightness: Double = 1, contrast: Double = 1, originalSaturation: Double = 1) {
        self.hue = hue; self.intensity = intensity; self.baseHue = baseHue; self.invertLightness = invertLightness
        self.brightness = brightness; self.contrast = contrast; self.originalSaturation = originalSaturation
    }
    private enum CodingKeys: String, CodingKey { case hue, intensity, baseHue, invertLightness, brightness, contrast, originalSaturation }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(hue: try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0,
                  intensity: try c.decodeIfPresent(Double.self, forKey: .intensity) ?? 0,
                  baseHue: try c.decodeIfPresent(Double.self, forKey: .baseHue),
                  invertLightness: try c.decodeIfPresent(Bool.self, forKey: .invertLightness) ?? false,
                  brightness: try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 1,
                  contrast: try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1,
                  originalSaturation: try c.decodeIfPresent(Double.self, forKey: .originalSaturation) ?? 1)
    }
    public func clamped() -> BoostColorWheel {
        func bounded(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
            value.isNaN ? fallback : min(range.upperBound, max(range.lowerBound, value))
        }
        func angle(_ value: Double) -> Double {
            guard value.isFinite else { return 0 }
            let wrapped = value.truncatingRemainder(dividingBy: 360)
            return wrapped < 0 ? wrapped + 360 : wrapped
        }
        return BoostColorWheel(hue: angle(hue), intensity: bounded(intensity, 0...1, fallback: 0),
            baseHue: baseHue.flatMap { $0.isFinite ? angle($0) : nil }, invertLightness: invertLightness,
            brightness: bounded(brightness, 0.5...1.5, fallback: 1), contrast: bounded(contrast, 0.5...1.5, fallback: 1),
            originalSaturation: bounded(originalSaturation, 0...2, fallback: 1))
    }
    public var isIdentity: Bool {
        let w = clamped()
        return w.intensity < 0.02 && !w.invertLightness && w.brightness == 1 && w.contrast == 1 && w.originalSaturation == 1
    }
    public var adjustment: ColorAdjustment? {
        let w = clamped()
        guard !w.isIdentity else { return nil }
        let delta = (w.hue - (w.baseHue ?? 0) + 540).truncatingRemainder(dividingBy: 360) - 180
        var rotation = w.intensity * delta + (w.invertLightness ? 180 : 0)
        rotation = rotation.truncatingRemainder(dividingBy: 360)
        if rotation < 0 { rotation += 360 }
        return ColorAdjustment(hueRotateDegrees: rotation, saturation: min(3, max(0, w.originalSaturation * (1 + 0.5*w.intensity))),
                               brightness: w.brightness, contrast: w.contrast, invert: w.invertLightness ? 1 : 0)
    }
}

public struct ZappedElement: Codable, Hashable, Sendable {
    public var selector: String
    public var label: String
    public var createdAt: Date
    public init(selector: String, label: String = "", createdAt: Date = Date()) {
        self.selector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        self.label = label; self.createdAt = createdAt
    }
}

public struct Boost: Codable, Hashable, Sendable, Identifiable {
    public var id: BoostID
    public var name: String
    public var siteMatch: SiteMatch
    public var isEnabled: Bool
    public var css: String
    public var js: String
    public var colorAdjustment: ColorAdjustment?
    public var colorWheel: BoostColorWheel?
    public var fontFamily: String?
    // Optional Codable fields accept missing keys from files written before text controls.
    public var textZoom: Double?
    public var textTransform: String?
    public var zaps: [ZappedElement]
    public var createdAt: Date
    public var updatedAt: Date
    public var forkedFromID: BoostID?

    public init(id: BoostID = BoostID(), name: String = "", siteMatch: SiteMatch, isEnabled: Bool = true,
                css: String = "", js: String = "", colorAdjustment: ColorAdjustment? = nil, colorWheel: BoostColorWheel? = nil,
                fontFamily: String? = nil, textZoom: Double? = nil, textTransform: String? = nil,
                zaps: [ZappedElement] = [], createdAt: Date = Date(), updatedAt: Date = Date(), forkedFromID: BoostID? = nil) {
        self.id = id; self.name = name; self.siteMatch = siteMatch; self.isEnabled = isEnabled
        self.css = css; self.js = js; self.colorAdjustment = colorAdjustment; self.colorWheel = colorWheel; self.fontFamily = fontFamily
        self.textZoom = textZoom; self.textTransform = textTransform; self.zaps = zaps
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.forkedFromID = forkedFromID
    }
    public var containsJS: Bool { !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var isEmpty: Bool {
        css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !containsJS &&
        (colorAdjustment?.isIdentity ?? true) && (colorWheel?.isIdentity ?? true) && (fontFamily?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) &&
        textZoom == nil && textTransform == nil && zaps.isEmpty
    }
    @discardableResult public mutating func appendZap(_ zap: ZappedElement) -> Bool {
        var zap = zap
        zap.selector = zap.selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !zap.selector.isEmpty, !zaps.contains(where: { $0.selector == zap.selector }) else { return false }
        zaps.append(zap)
        return true
    }
    @discardableResult public mutating func removeZap(selector: String) -> Bool {
        let selector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = zaps.count
        zaps.removeAll { $0.selector == selector }
        return count != zaps.count
    }
}
