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

    /// "owner/name" of a pull request URL (`/owner/name/pull/N`), or nil.
    public static func repository(of url: URL) -> String? {
        let parts = url.path.split(separator: "/")
        guard parts.count >= 4, parts[2] == "pull" else { return nil }
        return parts[0] + "/" + parts[1]
    }
    /// Arc's folder header text for a failed state (live-data §2.2, `S:112394–112396`).
    public var stateMessage: String? {
        switch lastFetch?.outcome {
        case .signedOut?: return "Sign back in to GitHub."
        case .needsSSO?: return "Login with SSO to unlock this folder"
        case .failed?: return "We’re having trouble connecting to GitHub; click here to see your Pull Requests."
        default: return nil
        }
    }
}
