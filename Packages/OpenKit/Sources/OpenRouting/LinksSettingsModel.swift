import Foundation
import Observation
import OpenModel

public struct SpaceOption: Hashable, Sendable, Identifiable {
    public var id: SpaceID
    public var title: String
    public var profileID: ProfileID
    public init(id: SpaceID, title: String, profileID: ProfileID) {
        self.id = id; self.title = title; self.profileID = profileID
    }
}

public struct RoutingProfileOption: Hashable, Sendable, Identifiable {
    public var id: ProfileID
    public var name: String
    public init(id: ProfileID, name: String) { self.id = id; self.name = name }
}

/// The native pop-up and preview checks use the same ordered entries.
public enum RoutingDestinationMenuEntry: Hashable, Sendable {
    case destination(String, RoutingDestination)
    case section(String)
    case separator
}

public struct RuleDraft: Hashable, Sendable, Identifiable {
    public var id: RuleID
    public enum MatchKind: String, CaseIterable, Sendable { case hostContains, hostEquals, urlPrefix }
    public var matchKind: MatchKind
    public var pattern: String
    public enum DestinationKind: String, CaseIterable, Sendable { case space, mostRecentSpace, littleOpen }
    public var destinationKind: DestinationKind
    public var spaceID: SpaceID?
    public var profileID: ProfileID?
    public var sourceBundleID: String

    public init(from rule: RoutingRule) {
        id = rule.id
        switch rule.match {
        case .hostContains(let value): matchKind = .hostContains; pattern = value
        case .hostEquals(let value): matchKind = .hostEquals; pattern = value
        case .urlPrefix(let value): matchKind = .urlPrefix; pattern = value
        }
        profileID = nil
        switch rule.destination {
        case .space(let id): destinationKind = .space; spaceID = id
        case .mostRecentSpace(let profile): destinationKind = .mostRecentSpace; spaceID = nil; profileID = profile
        case .littleOpen(let profile): destinationKind = .littleOpen; spaceID = nil; profileID = profile
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
        guard let destination else { return nil }
        return RoutingRule(id: id, match: match, destination: destination, sourceBundleID: sourceBundleID)
    }

    public var destination: RoutingDestination? {
        get {
            switch destinationKind {
            case .space: return spaceID.map(RoutingDestination.space)
            case .mostRecentSpace: return .mostRecentSpace(profile: profileID)
            case .littleOpen: return .littleOpen(profile: profileID)
            }
        }
        set {
            guard let newValue else { return }
            switch newValue {
            case .space(let id): destinationKind = .space; spaceID = id; profileID = nil
            case .mostRecentSpace(let profile): destinationKind = .mostRecentSpace; spaceID = nil; profileID = profile
            case .littleOpen(let profile): destinationKind = .littleOpen; spaceID = nil; profileID = profile
            }
        }
    }

    fileprivate func validationIssues(spaces: [SpaceOption]? = nil, profiles: [RoutingProfileOption]? = nil) -> [RuleIssue] {
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
        if destinationKind != .space, let profileID, let profiles {
            if !profiles.contains(where: { $0.id == profileID }) {
                issues.append(.missingProfile(ruleID: id, hasNoSpaces: false))
            } else if spaces?.contains(where: { $0.profileID == profileID }) == false {
                issues.append(.missingProfile(ruleID: id, hasNoSpaces: true))
            }
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
            && (destinationKind == .space || profileID == other.profileID)
            && RoutingSource(bundleID: sourceBundleID).bundleID == RoutingSource(bundleID: other.sourceBundleID).bundleID
    }
}

public enum RuleIssue: Hashable, Sendable {
    case emptyPattern(ruleID: RuleID)
    case patternHasSpaces(ruleID: RuleID)
    case prefixNotParseable(ruleID: RuleID)
    case missingSpace(ruleID: RuleID)
    case missingProfile(ruleID: RuleID, hasNoSpaces: Bool)
    case duplicateOf(ruleID: RuleID, otherIndex: Int)
    /// Matches any host containing the text, including unrelated hosts.
    case containsIsSubstring(ruleID: RuleID)

    public var isError: Bool {
        switch self {
        case .emptyPattern, .patternHasSpaces, .prefixNotParseable, .missingSpace, .missingProfile: return true
        case .duplicateOf, .containsIsSubstring: return false
        }
    }
    public var ruleID: RuleID {
        switch self {
        case .emptyPattern(let id), .patternHasSpaces(let id), .prefixNotParseable(let id),
             .missingSpace(let id), .missingProfile(let id, _), .duplicateOf(let id, _), .containsIsSubstring(let id): return id
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
    public var defaultProfileID: ProfileID?
    public var externalLinksInLittleOpen: Bool
    public var littleOpenHotkeyEnabled: Bool
    public var optionCommandClickLittleOpen: Bool
    public var littleOpenAutoArchiveAfter: AutoArchiveInterval
    public var spaces: [SpaceOption]
    public var profiles: [RoutingProfileOption]
    public var isDefaultBrowser: Bool
    public var testURLString = ""
    public var testSourceBundleID = ""
    public var testMostRecentSpaceID: SpaceID?
    public private(set) var testDecision: RoutingDecision?
    @ObservationIgnored private let initialSnapshot: RoutingSnapshot
    @ObservationIgnored public var snapshotProvider: (@MainActor () -> RoutingSnapshot)?
    /// Stable identity for the synthetic default-destination validation draft.
    public static let defaultDestinationIssueID = RuleID(uuidString: "00000000-0000-0000-0000-000000000000")

    public init(snapshot: RoutingSnapshot, spaces: [SpaceOption], profiles: [RoutingProfileOption], isDefaultBrowser: Bool, defaults: UserDefaults = .standard, snapshotProvider: (@MainActor () -> RoutingSnapshot)? = nil) {
        drafts = snapshot.rules.map(RuleDraft.init)
        defaultProfileID = nil
        switch snapshot.defaultDestination {
        case .space(let id): defaultDestinationKind = .space; defaultSpaceID = id
        case .mostRecentSpace(let profile): defaultDestinationKind = .mostRecentSpace; defaultSpaceID = nil; defaultProfileID = profile
        case .littleOpen(let profile): defaultDestinationKind = .littleOpen; defaultSpaceID = nil; defaultProfileID = profile
        }
        externalLinksInLittleOpen = snapshot.externalLinksInLittleOpen
        littleOpenHotkeyEnabled = defaults.object(forKey: "open.links.littleOpenHotkeyEnabled") as? Bool ?? true
        optionCommandClickLittleOpen = defaults.object(forKey: "open.links.optionCommandClickLittleOpen") as? Bool ?? true
        littleOpenAutoArchiveAfter = .sixHours
        self.spaces = spaces
        self.isDefaultBrowser = isDefaultBrowser
        self.profiles = profiles
        initialSnapshot = snapshot
        self.snapshotProvider = snapshotProvider
        testMostRecentSpaceID = nil
    }

    public func issues() -> [RuleIssue] {
        issues(in: drafts)
    }

    /// Validate a sheet draft with the same rules as Save, without publishing an edit.
    public func issues(replacing draft: RuleDraft) -> [RuleIssue] {
        var proposed = drafts
        if let index = proposed.firstIndex(where: { $0.id == draft.id }) { proposed[index] = draft }
        else { proposed.append(draft) }
        return issues(in: proposed)
    }

    private func issues(in drafts: [RuleDraft]) -> [RuleIssue] {
        var result: [RuleIssue] = []
        for (index, draft) in drafts.enumerated() {
            result += draft.validationIssues(spaces: spaces, profiles: profiles)
            if let earlier = drafts[..<index].firstIndex(where: { draft.duplicates($0) }) {
                result.append(.duplicateOf(ruleID: draft.id, otherIndex: earlier))
            }
        }
        // Use the same validator so deleted default destinations remain visible.
        var defaultDraft = RuleDraft(from: RoutingRule(id: Self.defaultDestinationIssueID,
            match: .hostEquals("example.com"), destination: .mostRecentSpace(profile: nil)))
        defaultDraft.destinationKind = defaultDestinationKind
        defaultDraft.spaceID = defaultSpaceID
        defaultDraft.profileID = defaultProfileID
        result += defaultDraft.validationIssues(spaces: spaces, profiles: profiles)
        return result
    }

    public func addRule() {
        drafts.append(RuleDraft(from: RoutingRule(match: .hostEquals(""), destination: .mostRecentSpace(profile: nil))))
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
            guard !draft.validationIssues(spaces: spaces, profiles: profiles).contains(where: \.isError) else { return nil }
            return draft.makeRule()
        }
        let destination: DefaultDestination
        switch defaultDestinationKind {
        case .space:
            if let id = defaultSpaceID, spaces.contains(where: { $0.id == id }) { destination = .space(id) }
            else { destination = .mostRecentSpace(profile: nil) }
        case .mostRecentSpace: destination = .mostRecentSpace(profile: defaultProfileID)
        case .littleOpen: destination = .littleOpen(profile: defaultProfileID)
        }
        return (rules, destination)
    }

    public var defaultRoutingDestination: RoutingDestination? {
        get {
            switch defaultDestinationKind {
            case .space: return defaultSpaceID.map(RoutingDestination.space)
            case .mostRecentSpace: return .mostRecentSpace(profile: defaultProfileID)
            case .littleOpen: return .littleOpen(profile: defaultProfileID)
            }
        }
        set {
            guard let newValue else { return }
            switch newValue {
            case .space(let id): defaultDestinationKind = .space; defaultSpaceID = id; defaultProfileID = nil
            case .mostRecentSpace(let profile): defaultDestinationKind = .mostRecentSpace; defaultSpaceID = nil; defaultProfileID = profile
            case .littleOpen(let profile): defaultDestinationKind = .littleOpen; defaultSpaceID = nil; defaultProfileID = profile
            }
        }
    }

    public var destinationEntries: [RoutingDestinationMenuEntry] {
        var entries: [RoutingDestinationMenuEntry] = [
            .destination("Little Open", .littleOpen(profile: nil)),
            .destination("Most Recent Space", .mostRecentSpace(profile: nil))]
        if profiles.count < 2 {
            entries.append(.separator)
            entries += spaces.map { .destination($0.title, .space($0.id)) }
        } else {
            for profile in profiles {
                entries += [.separator, .section(profile.name),
                    .destination("Little Open – \(profile.name)", .littleOpen(profile: profile.id)),
                    .destination("Most Recent Space – \(profile.name)", .mostRecentSpace(profile: profile.id))]
                entries += spaces.filter { $0.profileID == profile.id }.map { .destination($0.title, .space($0.id)) }
            }
        }
        return entries
    }

    public func destinationLabel(_ destination: RoutingDestination?) -> String {
        switch destination {
        case .space(let id): return spaces.first { $0.id == id }?.title ?? "Choose Space"
        case .littleOpen(let profile): return "Little Open" + profileSuffix(profile)
        case .mostRecentSpace(let profile): return "Most Recent Space" + profileSuffix(profile)
        case nil: return "Choose Space"
        }
    }

    private func profileSuffix(_ id: ProfileID?) -> String {
        id.map { id in " – " + (profiles.first { $0.id == id }?.name ?? "Missing Profile") } ?? ""
    }

    public var testInputIsValid: Bool { RoutingRequest.parseURL(testURLString) != nil }

    public func runTest() {
        guard let url = RoutingRequest.parseURL(testURLString) else { testDecision = nil; return }
        let routing = currentRouting()
        // Automatic uses a fresh App snapshot on each click, including real z-order.
        var snapshot = snapshotProvider?() ?? initialSnapshot
        snapshot.spaces.removeAll { value in !spaces.contains(where: { $0.id == value.id }) }
        snapshot.rules = routing.rules
        snapshot.defaultDestination = routing.defaultDestination
        snapshot.externalLinksInLittleOpen = externalLinksInLittleOpen
        snapshot.mostRecentOverride = testMostRecentSpaceID
        if let focused = testMostRecentSpaceID {
            snapshot.windows.insert(RoutingWindowSnapshot(id: WindowID(), kind: .standard, focusedSpaceID: focused), at: 0)
        }
        testDecision = RoutingEvaluator().evaluate(RoutingRequest(url: url,
            source: RoutingSource(bundleID: testSourceBundleID)), in: snapshot)
    }
}
