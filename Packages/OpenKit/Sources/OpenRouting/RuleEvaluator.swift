import Foundation
import OpenModel

public struct RoutingEvaluator: Sendable {
    public var logger: (any RoutingLogging)?
    public init(logger: (any RoutingLogging)? = nil) { self.logger = logger }

    public func evaluate(_ request: RoutingRequest, in snapshot: RoutingSnapshot) -> RoutingDecision {
        // Normalize again at entry because public value properties and decoded data can change.
        var request = request
        request.source = RoutingSource(bundleID: request.source.bundleID, pid: request.source.pid,
                                       displayName: request.source.displayName)
        let scheme = request.url.scheme?.lowercased()
        let host = HostNormalizer.canonicalHost(of: request.url)
        func finish(_ via: RoutingVia, _ resolved: ResolvedDestination?, _ traces: [RuleTrace]) -> RoutingDecision {
            let decision = RoutingDecision(request: request, normalizedHost: host, traces: traces,
                via: via, resolved: resolved, evaluatedAt: request.receivedAt,
                standardWindowCount: snapshot.windows.reduce(0) { $0 + ($1.kind == .standard ? 1 : 0) },
                mostRecentOverride: snapshot.mostRecentOverride)
            logger?.record(decision)
            return decision
        }
        guard scheme == "http" || scheme == "https" else {
            return finish(.rejectedNonHTTP(scheme: scheme), nil, [])
        }
        let mostRecent = mostRecentSpace(in: snapshot)
        var traces: [RuleTrace] = []
        for (index, original) in snapshot.rules.enumerated() {
            var rule = original
            rule.sourceBundleID = RoutingSource(bundleID: rule.sourceBundleID).bundleID
            func trace(_ outcome: RuleTrace.Outcome) -> RuleTrace {
                RuleTrace(index: index, ruleID: rule.id, outcome: outcome, rule: rule)
            }
            if let required = rule.sourceBundleID {
                guard let actual = request.source.bundleID else { traces.append(trace(.sourceUnknown)); continue }
                guard required == actual else { traces.append(trace(.sourceMismatch)); continue }
            }
            guard matches(rule.match, url: request.url, host: host) else { traces.append(trace(.hostMismatch)); continue }
            if case .space(let id) = rule.destination, space(id, in: snapshot) == nil {
                traces.append(trace(.targetSpaceMissing))
                continue
            }
            traces.append(trace(.matched))
            let target = resolve(rule.destination, in: snapshot, mostRecent: mostRecent)
            return finish(target == nil ? .noSpaces : .rule(index: index, id: rule.id), target, traces)
        }
        var via: RoutingVia = .defaultDestination
        let target: ResolvedDestination?
        switch snapshot.defaultDestination {
        case .space(let id):
            if let destination = space(id, in: snapshot) {
                target = resolvedSpace(destination)
            } else {
                target = mostRecent.map(resolvedSpace)
                // This missing default target actually requires a fallback.
                // Skipped stale rules explain themselves in their traces.
                via = .fallbackMissingSpace(requested: id)
            }
        case .mostRecentSpace:
            target = mostRecent.map(resolvedSpace)
        case .littleOpen:
            if snapshot.externalLinksInLittleOpen {
                target = .littleOpen(profileHint: mostRecent?.profileID)
            } else {
                target = mostRecent.map(resolvedSpace)
                via = .defaultSuppressedByToggle
            }
        }
        if target == nil { via = .noSpaces }
        return finish(via, target, traces)
    }
}

private func space(_ id: SpaceID, in snapshot: RoutingSnapshot) -> RoutingSpaceSnapshot? {
    snapshot.spaces.first { $0.id == id }
}

private func mostRecentSpace(in snapshot: RoutingSnapshot) -> RoutingSpaceSnapshot? {
    for window in snapshot.windows where window.kind == .standard {
        if let found = space(window.focusedSpaceID, in: snapshot) { return found }
    }
    return snapshot.spaces.first
}

private func resolvedSpace(_ space: RoutingSpaceSnapshot) -> ResolvedDestination {
    .space(spaceID: space.id, profileID: space.profileID)
}

private func resolve(_ destination: RoutingDestination, in snapshot: RoutingSnapshot,
                     mostRecent: RoutingSpaceSnapshot?) -> ResolvedDestination? {
    switch destination {
    case .space(let id): return space(id, in: snapshot).map(resolvedSpace)
    case .mostRecentSpace: return mostRecent.map(resolvedSpace)
    case .littleOpen: return .littleOpen(profileHint: mostRecent?.profileID)
    }
}

private func matches(_ match: RoutingMatch, url: URL, host: String?) -> Bool {
    switch match {
    case .hostContains(let raw):
        // IPv6 stays intact in reports but is outside host-rule matching.
        let pattern = HostNormalizer.canonicalPattern(raw)
        return !pattern.isEmpty && host?.contains(":") == false && host?.contains(pattern) == true
    case .hostEquals(let raw):
        let pattern = HostNormalizer.canonicalPattern(raw)
        return !pattern.isEmpty && host?.contains(":") == false && host == pattern
    case .urlPrefix(let raw):
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let pattern = HostNormalizer.canonicalPrefixPattern(raw, scheme: url.scheme)
        var candidate = HostNormalizer.canonicalURLString(url)
        if !raw.contains("://"), let separator = candidate.range(of: "://") {
            candidate = String(candidate[separator.upperBound...])
        }
        return !pattern.isEmpty && candidate.hasPrefix(pattern)
    }
}
