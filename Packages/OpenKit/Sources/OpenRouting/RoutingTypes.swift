import Foundation
import OpenModel

/// OS-provided source identity. Bundle ids use trimmed lowercase for matching.
public struct RoutingSource: Hashable, Sendable, Codable {
    public var bundleID: String?
    public var pid: Int32?
    public var displayName: String?

    public init(bundleID: String? = nil, pid: Int32? = nil, displayName: String? = nil) {
        let source = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.bundleID = source?.isEmpty == false ? source : nil
        self.pid = pid
        self.displayName = displayName
    }

    public var isKnown: Bool { bundleID != nil }
    public static let unknown = RoutingSource()
}

public struct RoutingRequest: Hashable, Sendable, Codable {
    public var url: URL
    public var source: RoutingSource
    public var receivedAt: Date

    public init(url: URL, source: RoutingSource = .unknown, receivedAt: Date = Date()) {
        self.url = url
        self.source = source
        self.receivedAt = receivedAt
    }

    /// Shared input convenience for the CLI and Settings. Explicit non-HTTP schemes
    /// parse here so the evaluator can explain their rejection.
    public static func parseURL(_ text: String) -> URL? {
        var input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains(where: \.isWhitespace) else { return nil }
        if URLComponents(string: input)?.scheme == nil, input.contains(".") {
            input = "https://" + input
        }
        guard let url = URL(string: input), let scheme = url.scheme, !scheme.isEmpty else { return nil }
        if ["http", "https"].contains(scheme.lowercased()), url.host()?.isEmpty != false { return nil }
        return url
    }
}

public struct RoutingSpaceSnapshot: Hashable, Sendable {
    public var id: SpaceID
    public var title: String
    public var profileID: ProfileID

    public init(id: SpaceID, title: String, profileID: ProfileID) {
        self.id = id; self.title = title; self.profileID = profileID
    }
}

public enum RoutingWindowKind: Hashable, Sendable { case standard, littleOpen }

public struct RoutingWindowSnapshot: Hashable, Sendable {
    public var id: WindowID
    public var kind: RoutingWindowKind
    public var focusedSpaceID: SpaceID

    public init(id: WindowID, kind: RoutingWindowKind, focusedSpaceID: SpaceID) {
        self.id = id; self.kind = kind; self.focusedSpaceID = focusedSpaceID
    }
}

/// Value inputs copied by the caller. The App must supply managed NSApp windows in
/// front-to-back order; BrowserModel.windows is not z-order. The CLI supplies standard
/// windows first in stored order, or a --most-recent override. Space ids must be unique;
/// evaluation uses the first occurrence if the caller supplies duplicates.
public struct RoutingSnapshot: Sendable {
    public var spaces: [RoutingSpaceSnapshot]
    public var windows: [RoutingWindowSnapshot]
    public var rules: [RoutingRule]
    public var defaultDestination: DefaultDestination
    public var externalLinksInLittleOpen: Bool
    /// Report context only; the caller must also order windows for this override.
    public var mostRecentOverride: SpaceID?

    public init(spaces: [RoutingSpaceSnapshot], windows: [RoutingWindowSnapshot],
                rules: [RoutingRule], defaultDestination: DefaultDestination,
                externalLinksInLittleOpen: Bool, mostRecentOverride: SpaceID? = nil) {
        self.spaces = spaces; self.windows = windows; self.rules = rules
        self.defaultDestination = defaultDestination
        self.externalLinksInLittleOpen = externalLinksInLittleOpen
        self.mostRecentOverride = mostRecentOverride
    }
}

public enum RoutingVia: Hashable, Sendable, Codable {
    case rule(index: Int, id: RuleID)
    case defaultDestination
    case fallbackMissingSpace(requested: SpaceID)
    case defaultSuppressedByToggle
    case noSpaces
    case rejectedNonHTTP(scheme: String?)
}

public enum ResolvedDestination: Hashable, Sendable, Codable {
    case space(spaceID: SpaceID, profileID: ProfileID)
    case littleOpen(profileHint: ProfileID?)
}

public struct RuleTrace: Hashable, Sendable, Codable {
    public var index: Int
    public var ruleID: RuleID
    public enum Outcome: Hashable, Sendable, Codable {
        case matched, hostMismatch, sourceMismatch, sourceUnknown, targetSpaceMissing
    }
    public var outcome: Outcome
    /// A value copy makes the shared formatter independent of mutable rule lists.
    public var rule: RoutingRule

    public init(index: Int, ruleID: RuleID, outcome: Outcome, rule: RoutingRule) {
        self.index = index; self.ruleID = ruleID; self.outcome = outcome; self.rule = rule
    }
}

public struct RoutingDecision: Sendable, Codable {
    public var request: RoutingRequest
    public var normalizedHost: String?
    public var traces: [RuleTrace]
    public var via: RoutingVia
    public var resolved: ResolvedDestination?
    public var evaluatedAt: Date
    /// Report inputs travel with the decision for identical CLI and Settings output.
    public var standardWindowCount: Int
    public var mostRecentOverride: SpaceID?

    public init(request: RoutingRequest, normalizedHost: String?, traces: [RuleTrace],
                via: RoutingVia, resolved: ResolvedDestination?, evaluatedAt: Date,
                standardWindowCount: Int = 0, mostRecentOverride: SpaceID? = nil) {
        self.request = request; self.normalizedHost = normalizedHost; self.traces = traces
        self.via = via; self.resolved = resolved; self.evaluatedAt = evaluatedAt
        self.standardWindowCount = standardWindowCount; self.mostRecentOverride = mostRecentOverride
    }
}
