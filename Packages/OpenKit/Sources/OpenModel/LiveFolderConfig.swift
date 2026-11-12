import Foundation

/// Live Folder settings stored on a sidebar folder (live-data §2.7; Arc `automaticLiveFolderData`).
/// Lives in OpenModel so `Folder` and the snapshot DTO can hold it; logic is in OpenLiveData.
public struct LiveFolderConfig: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable { case github }
    /// Arc `GitHubClient.FetchType` (LD §2.4).
    public enum Kind: String, Codable, CaseIterable, Sendable { case createdByMe, reviewRequested, approved, changesRequested }
    public enum Outcome: String, Codable, Sendable { case success, signedOut, needsSSO, failed }
    public struct LastFetch: Codable, Hashable, Sendable {
        public var date: Date
        public var outcome: Outcome
        public init(date: Date, outcome: Outcome) { self.date = date; self.outcome = outcome }
    }
    public var source: Source
    public var kinds: Set<Kind>
    public var teamReviews: Bool
    public var hiddenRepositories: Set<String>
    /// PR URLs the user deleted by hand; never re-added (LD §2.7).
    public var hiddenItems: Set<String>
    public var lastFetch: LastFetch?
    public init(source: Source = .github, kinds: Set<Kind> = Set(Kind.allCases), teamReviews: Bool = true,
                hiddenRepositories: Set<String> = [], hiddenItems: Set<String> = [], lastFetch: LastFetch? = nil) {
        self.source = source; self.kinds = kinds; self.teamReviews = teamReviews
        self.hiddenRepositories = hiddenRepositories; self.hiddenItems = hiddenItems; self.lastFetch = lastFetch
    }
}
