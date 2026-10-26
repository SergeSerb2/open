import Foundation
import OpenModel

public struct ResolvedBoost: Codable, Sendable, Equatable {
    public var boostID: BoostID
    public var name: String
    public var css: String
    public var js: String
    public var zaps: [String]
    public init(boostID: BoostID, name: String, css: String, js: String, zaps: [String]) {
        self.boostID = boostID; self.name = name; self.css = css; self.js = js; self.zaps = zaps
    }
}

/// Engine-independent structured input. The applier builds CSS after validating selectors.
public struct InjectionPlan: Sendable, Equatable {
    public var planID: String
    public var url: URL
    public var profileID: ProfileID
    public var boosts: [ResolvedBoost]
    public var colorAdjustment: ColorAdjustment?
    public var fontFamily: String?
    public var textZoom: Double?
    public var textTransform: String?
    public var combinedJS: String
    public var containsJS: Bool
    public var bridgeVersion: Int
    public var isEmpty: Bool { boosts.isEmpty }

    public init(planID: String, url: URL, profileID: ProfileID, boosts: [ResolvedBoost],
                colorAdjustment: ColorAdjustment? = nil, fontFamily: String? = nil,
                textZoom: Double? = nil, textTransform: String? = nil, combinedJS: String = "", bridgeVersion: Int = 1) {
        self.planID = planID; self.url = url; self.profileID = profileID; self.boosts = boosts
        self.colorAdjustment = colorAdjustment; self.fontFamily = fontFamily
        self.textZoom = textZoom; self.textTransform = textTransform
        self.combinedJS = combinedJS; self.containsJS = !combinedJS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.bridgeVersion = bridgeVersion
    }
}

public enum BoostInjectionPlanner {
    public enum PlanContext: Sendable { case normal, incognito }

    public static func plan(url: URL, profileID: ProfileID, matcher: BoostMatcher,
                            boostsGloballyEnabled: Bool, context: PlanContext = .normal) -> InjectionPlan {
        // Q4: same policy in both contexts. Keep the parameter for the future App adapter.
        let matched = boostsGloballyEnabled ? matcher.matching(url: url) : []
        guard !matched.isEmpty else { return InjectionPlan(planID: "empty", url: url, profileID: profileID, boosts: []) }
        var color: ColorAdjustment?, font: String?, zoom: Double?, transform: String?
        let resolved = matched.map { boost in
            if let c = boost.colorAdjustment?.clamped(), !c.isIdentity { color = c }
            if let f = boost.fontFamily, !f.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if f.rangeOfCharacter(from: CharacterSet(charactersIn: ";{}\"\n\r")) == nil { font = f }
                else {
                    #if DEBUG
                    FileHandle.standardError.write(Data("BoostPicker: rejected unsafe font component for \(boost.id)\n".utf8))
                    #endif
                }
            }
            if let z = boost.textZoom { zoom = z.isNaN ? 1 : min(2, max(0.5, z)) }
            if let t = boost.textTransform, ["none", "uppercase", "lowercase", "capitalize"].contains(t) { transform = t }
            var seen: Set<String> = []
            let zaps = boost.zaps.map { $0.selector.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
            return ResolvedBoost(boostID: boost.id, name: boost.name, css: boost.css, js: boost.js, zaps: zaps)
        }
        let js = matched.map(\.js).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n;\n")
        var content = resolved.map { "\($0.boostID)\0\($0.css)\0\($0.js)\0" + $0.zaps.joined(separator: "\0") }.joined(separator: "\0")
        let colorText = color.map { [ $0.hueRotateDegrees, $0.saturation, $0.brightness, $0.contrast, $0.invert ].map { String($0) }.joined(separator: ",") } ?? ""
        content += "\0" + colorText + "\0" + (font ?? "") + "\0" + (zoom.map { String($0) } ?? "") + "\0" + (transform ?? "")
        var hash: UInt64 = 14695981039346656037
        for byte in content.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let hex = String(hash, radix: 16)
        let planID = "\(resolved.count)-" + String(repeating: "0", count: 16 - hex.count) + hex
        return InjectionPlan(planID: planID, url: url, profileID: profileID, boosts: resolved,
                             colorAdjustment: color, fontFamily: font, textZoom: zoom, textTransform: transform, combinedJS: js)
    }
}

public enum BoostResources {
    public static let applierJS: String = load("boost-applier")
    public static let pickerJS: String = load("zap-picker")

    private final class ResourceAnchor {}
    private static let resourceBundle: Bundle? = {
        // SwiftPM's generated Bundle.module traps if the entire bundle is missing.
        // Preflight its normal locations so a packaging error stays a recoverable error.
        var roots = [Bundle.main.resourceURL, Bundle(for: ResourceAnchor.self).resourceURL, Bundle.main.bundleURL]
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"] ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            roots.insert(URL(fileURLWithPath: path), at: 0)
        }
        #endif
        guard roots.compactMap({ $0 }).contains(where: { Bundle(url: $0.appendingPathComponent("OpenKit_OpenBoosts.bundle")) != nil }) else { return nil }
        return Bundle.module
    }()

    private static func load(_ name: String) -> String {
        do {
            guard let url = resourceBundle?.url(forResource: name, withExtension: "js") else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("BoostStore: missing resource \(name): \(error)\n".utf8))
            return ""
        }
    }
}
