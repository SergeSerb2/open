import Foundation
import Observation
import OpenModel

public struct SpaceOption: Hashable, Sendable, Identifiable {
    public var id: SpaceID
    public var title: String
    public init(id: SpaceID, title: String) { self.id = id; self.title = title }
}

public struct RuleDraft: Hashable, Sendable, Identifiable {
    public var id: RuleID
    public enum MatchKind: String, CaseIterable, Sendable { case hostContains, hostEquals, urlPrefix }
    public var matchKind: MatchKind
    public var pattern: String
    public enum DestinationKind: String, CaseIterable, Sendable { case space, mostRecentSpace, littleOpen }
    public var destinationKind: DestinationKind
    public var spaceID: SpaceID?
    public var sourceBundleID: String

    public init(from rule: RoutingRule) {
        id = rule.id
        switch rule.match {
        case .hostContains(let value): matchKind = .hostContains; pattern = value
        case .hostEquals(let value): matchKind = .hostEquals; pattern = value
        case .urlPrefix(let value): matchKind = .urlPrefix; pattern = value
        }
        switch rule.destination {
        case .space(let id): destinationKind = .space; spaceID = id
        case .mostRecentSpace: destinationKind = .mostRecentSpace; spaceID = nil
        case .littleOpen: destinationKind = .littleOpen; spaceID = nil
        }
        sourceBundleID = rule.sourceBundleID ?? ""
    }

    /// Checks the draft's own errors. The model also checks deleted Space ids
    /// against its current Space list before including a rule in currentRouting().
    public func makeRule() -> RoutingRule? {
        guard !validationIssues().contains(where: \.isError) else { return nil }
        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let match: RoutingMatch
        switch matchKind {
        case .hostContains: match = .hostContains(pattern)
        case .hostEquals: match = .hostEquals(pattern)
        case .urlPrefix: match = .urlPrefix(pattern)
        }
        let destination: RoutingDestination
        switch destinationKind {
        case .space:
            guard let spaceID else { return nil }
            destination = .space(spaceID)
        case .mostRecentSpace: destination = .mostRecentSpace
        case .littleOpen: destination = .littleOpen
        }
        return RoutingRule(id: id, match: match, destination: destination, sourceBundleID: sourceBundleID)
    }

    fileprivate func validationIssues(spaces: [SpaceOption]? = nil) -> [RuleIssue] {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        var issues: [RuleIssue] = []
        if trimmed.isEmpty { issues.append(.emptyPattern(ruleID: id)) }
        if pattern.contains(" ") { issues.append(.patternHasSpaces(ruleID: id)) }
        if matchKind == .urlPrefix, trimmed.contains("://"),
           URL(string: trimmed)?.host()?.isEmpty != false {
            issues.append(.prefixNotParseable(ruleID: id))
        }
        if destinationKind == .space,
           spaceID == nil || spaces.map({ options in !options.contains(where: { $0.id == spaceID }) }) == true {
            issues.append(.missingSpace(ruleID: id))
        }
        if matchKind == .hostContains { issues.append(.containsIsSubstring(ruleID: id)) }
        return issues
    }

    fileprivate var canonicalPattern: String {
        matchKind == .urlPrefix ? HostNormalizer.canonicalPrefixPattern(pattern) : HostNormalizer.canonicalPattern(pattern)
    }

    fileprivate func duplicates(_ other: RuleDraft) -> Bool {
        matchKind == other.matchKind && canonicalPattern == other.canonicalPattern
            && destinationKind == other.destinationKind
            && (destinationKind != .space || spaceID == other.spaceID)
            && RoutingSource(bundleID: sourceBundleID).bundleID == RoutingSource(bundleID: other.sourceBundleID).bundleID
    }
}

public enum RuleIssue: Hashable, Sendable {
    case emptyPattern(ruleID: RuleID)
    case patternHasSpaces(ruleID: RuleID)
    case prefixNotParseable(ruleID: RuleID)
    case missingSpace(ruleID: RuleID)
    case duplicateOf(ruleID: RuleID, otherIndex: Int)
    /// Matches any host containing the text, including unrelated hosts.
    case containsIsSubstring(ruleID: RuleID)

    public var isError: Bool {
        switch self {
        case .emptyPattern, .patternHasSpaces, .prefixNotParseable, .missingSpace: return true
        case .duplicateOf, .containsIsSubstring: return false
        }
    }
}

/// Links-pane data only. The App owns persistence and per-profile setting hydration.
@MainActor
@Observable
public final class LinksSettingsModel {
    public var drafts: [RuleDraft]
    public var defaultDestinationKind: RuleDraft.DestinationKind
    public var defaultSpaceID: SpaceID?
    public var externalLinksInLittleOpen: Bool
    public var littleOpenHotkeyEnabled: Bool
    public var optionCommandClickLittleOpen: Bool
    public var littleOpenAutoArchiveAfter: AutoArchiveInterval
    public var spaces: [SpaceOption]
    public var isDefaultBrowser: Bool
    public var testURLString = ""
    public var testSourceBundleID = ""
    public var testMostRecentSpaceID: SpaceID?
    public private(set) var testDecision: RoutingDecision?
    @ObservationIgnored private let snapshotSpaces: [RoutingSpaceSnapshot]
    /// Stable identity for the synthetic default-destination validation draft.
    public static let defaultDestinationIssueID = RuleID(uuidString: "00000000-0000-0000-0000-000000000000")

    public init(snapshot: RoutingSnapshot, spaces: [SpaceOption], isDefaultBrowser: Bool) {
        drafts = snapshot.rules.map(RuleDraft.init)
        switch snapshot.defaultDestination {
        case .space(let id): defaultDestinationKind = .space; defaultSpaceID = id
        case .mostRecentSpace: defaultDestinationKind = .mostRecentSpace; defaultSpaceID = nil
        case .littleOpen: defaultDestinationKind = .littleOpen; defaultSpaceID = nil
        }
        externalLinksInLittleOpen = snapshot.externalLinksInLittleOpen
        littleOpenHotkeyEnabled = UserDefaults.standard.object(forKey: "open.links.littleOpenHotkeyEnabled") as? Bool ?? true
        optionCommandClickLittleOpen = UserDefaults.standard.object(forKey: "open.links.optionCommandClickLittleOpen") as? Bool ?? true
        littleOpenAutoArchiveAfter = .sixHours
        self.spaces = spaces
        self.isDefaultBrowser = isDefaultBrowser
        snapshotSpaces = snapshot.spaces
        testMostRecentSpaceID = spaces.first?.id
    }

    public func issues() -> [RuleIssue] {
        var result: [RuleIssue] = []
        for (index, draft) in drafts.enumerated() {
            result += draft.validationIssues(spaces: spaces)
            if let earlier = drafts[..<index].firstIndex(where: { draft.duplicates($0) }) {
                result.append(.duplicateOf(ruleID: draft.id, otherIndex: earlier))
            }
        }
        // Use the same validator so deleted default destinations remain visible.
        var defaultDraft = RuleDraft(from: RoutingRule(id: Self.defaultDestinationIssueID,
            match: .hostEquals("example.com"), destination: .mostRecentSpace))
        defaultDraft.destinationKind = defaultDestinationKind
        defaultDraft.spaceID = defaultSpaceID
        result += defaultDraft.validationIssues(spaces: spaces)
        return result
    }

    public func addRule() {
        drafts.append(RuleDraft(from: RoutingRule(match: .hostEquals(""), destination: .mostRecentSpace)))
    }

    public func deleteRule(id: RuleID) { drafts.removeAll { $0.id == id } }

    /// `to` is the final list index; count means the end of the list.
    public func moveRule(from: Int, to: Int) {
        guard drafts.indices.contains(from), (0...drafts.count).contains(to) else { return }
        let draft = drafts.remove(at: from)
        drafts.insert(draft, at: min(to, drafts.count))
    }

    public func currentRouting() -> (rules: [RoutingRule], defaultDestination: DefaultDestination) {
        let rules = drafts.compactMap { draft -> RoutingRule? in
            guard !draft.validationIssues(spaces: spaces).contains(where: \.isError) else { return nil }
            return draft.makeRule()
        }
        let destination: DefaultDestination
        switch defaultDestinationKind {
        case .space:
            if let id = defaultSpaceID, spaces.contains(where: { $0.id == id }) { destination = .space(id) }
            else { destination = .mostRecentSpace }
        case .mostRecentSpace: destination = .mostRecentSpace
        case .littleOpen: destination = .littleOpen
        }
        return (rules, destination)
    }

    public var testInputIsValid: Bool { RoutingRequest.parseURL(testURLString) != nil }

    public func runTest() {
        guard let url = RoutingRequest.parseURL(testURLString) else { testDecision = nil; return }
        let routing = currentRouting()
        // Profile identity comes from the imported snapshot, never invented from a title.
        // Recreate this model when the App adds Spaces with new profile assignments.
        let currentSpaces = spaces.compactMap { option -> RoutingSpaceSnapshot? in
            guard let original = snapshotSpaces.first(where: { $0.id == option.id }) else { return nil }
            return RoutingSpaceSnapshot(id: option.id, title: option.title, profileID: original.profileID)
        }
        let focused = testMostRecentSpaceID ?? currentSpaces.first?.id
        let windows = focused.map { [RoutingWindowSnapshot(id: WindowID(), kind: .standard, focusedSpaceID: $0)] } ?? []
        let snapshot = RoutingSnapshot(spaces: currentSpaces, windows: windows, rules: routing.rules,
            defaultDestination: routing.defaultDestination, externalLinksInLittleOpen: externalLinksInLittleOpen,
            mostRecentOverride: focused)
        testDecision = RoutingEvaluator().evaluate(RoutingRequest(url: url,
            source: RoutingSource(bundleID: testSourceBundleID)), in: snapshot)
    }
}
