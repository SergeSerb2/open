import Foundation
import OpenModel

public enum RoutingDecisionFormatter {
    public static func oneLine(_ decision: RoutingDecision, spaceTitles: [SpaceID: String]) -> String {
        let target = destination(decision, titles: spaceTitles)
        let detail: String
        if case .rule(let index, _) = decision.via,
           let trace = decision.traces.first(where: { $0.index == index }) {
            detail = " (\(matchKind(trace.rule.match)))"
        } else { detail = "" }
        return "\(decision.request.url.absoluteString) → \(target) via \(via(decision.via))\(detail)"
    }

    public static func report(_ decision: RoutingDecision, spaces: [RoutingSpaceSnapshot]) -> String {
        var titles: [SpaceID: String] = [:]
        for space in spaces where titles[space.id] == nil { titles[space.id] = space.title }
        let source = decision.request.source
        var lines = ["url: \(decision.request.url.absoluteString)", "host: \(decision.normalizedHost ?? "—")"]
        if let bundleID = source.bundleID {
            lines.append("source: \(bundleID) (pid \(source.pid.map(String.init) ?? "—"))")
        } else { lines.append("source: unknown") }
        let windowContext: String
        if let id = decision.mostRecentOverride {
            windowContext = "most-recent override: \(titles[id] ?? String(id.description.prefix(8)))"
        } else { windowContext = "frontmost = stored order" }
        lines.append("windows: \(decision.standardWindowCount) standard (\(windowContext))")
        if decision.traces.isEmpty {
            lines.append("rules: (none)")
        } else {
            lines.append("rules:")
            for trace in decision.traces {
                let rule = trace.rule
                let outcome: String
                switch trace.outcome {
                case .matched: outcome = "matched"
                case .hostMismatch: outcome = "host mismatch"
                case .sourceMismatch: outcome = "source mismatch"
                case .sourceUnknown: outcome = "source unknown (rule needs \(rule.sourceBundleID ?? "—"))"
                case .targetSpaceMissing: outcome = "target Space missing — skipped"
                case .targetProfileMissing: outcome = "target Profile missing or has no Spaces — skipped"
                }
                lines.append("  #\(trace.index + 1) \(matchDescription(rule.match)) [source: \(rule.sourceBundleID ?? "any")] -> \(ruleDestination(rule.destination, titles: titles)) … \(outcome)")
            }
        }
        lines.append("decision: \(destination(decision, titles: titles))")
        lines.append("via: \(via(decision.via))")
        return lines.joined(separator: "\n")
    }

    private static func space(_ id: SpaceID, titles: [SpaceID: String]) -> String {
        titles[id].map { "Space “\($0)”" } ?? "Space \(id.description.prefix(8))"
    }

    private static func destination(_ decision: RoutingDecision, titles: [SpaceID: String]) -> String {
        switch decision.resolved {
        case .space(let id, _): return space(id, titles: titles)
        case .littleOpen(let hint):
            return "Little Open" + (hint.map { " (profile hint: \($0.description.prefix(8)))" } ?? "")
        case nil:
            if case .rejectedNonHTTP = decision.via { return "rejected" }
            return "none"
        }
    }

    private static func ruleDestination(_ destination: RoutingDestination, titles: [SpaceID: String]) -> String {
        switch destination {
        case .space(let id): return space(id, titles: titles)
        case .littleOpen(let profile): return "Little Open" + (profile.map { " – Profile \($0.description.prefix(8))" } ?? "")
        case .mostRecentSpace(let profile): return "Most Recent Space" + (profile.map { " – Profile \($0.description.prefix(8))" } ?? "")
        }
    }

    private static func via(_ value: RoutingVia) -> String {
        switch value {
        case .rule(let index, _): return "rule #\(index + 1)"
        case .defaultDestination: return "default destination"
        case .fallbackMissingSpace: return "fallback (target Space is gone)"
        case .fallbackMissingProfile: return "fallback (target Profile missing or has no Spaces)"
        case .defaultSuppressedByToggle: return "default (Little Open off → most recent Space)"
        case .noSpaces: return "no Spaces"
        case .rejectedNonHTTP: return "rejected (not http/https)"
        }
    }

    private static func matchKind(_ match: RoutingMatch) -> String {
        switch match {
        case .hostEquals: return "hostEquals"
        case .hostContains: return "hostContains"
        case .urlPrefix: return "urlPrefix"
        }
    }

    private static func matchDescription(_ match: RoutingMatch) -> String {
        let pattern: String
        switch match {
        case .hostEquals(let value), .hostContains(let value), .urlPrefix(let value): pattern = value
        }
        return "\(matchKind(match))(\(pattern))"
    }
}
