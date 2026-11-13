import Foundation
import Observation

// MARK: - Runtime-only tab state (never persisted)

public enum SleepPhase: Sendable { case placeholder, live, frozen, sleeping }

@MainActor
@Observable
public final class TabLiveState {
    /// Engine-owned: true only while this tab has live web content. Never persisted.
    public var hasWebContent: Bool = false
    public var sleepPhase: SleepPhase = .placeholder
    public var isCapturing: Bool = false
    public var devToolsOpen: Bool = false
    public var lastFormInteractionAt: Date?
    /// The tab's origin has notification permission Allow in its profile (page-platform §4.5.6).
    /// The App refreshes it on every commit and permission change. Blocks freeze and timer discard.
    public var notificationsAllowed: Bool = false
    public var isLoading: Bool = false
    public var progress: Double = 0
    public var isAudible: Bool = false
    public var isCrashed: Bool = false
    public var canGoBack: Bool = false
    public var canGoForward: Bool = false
    public var faviconPNG: Data?

    public init() {}
}

// MARK: - Tab

/// One Live Folder row's pull request facts (C-LF-1; fields from live-data §2.3).
public struct LiveItemInfo: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable, CaseIterable { case open, draft, merged, closed }
    public var status: Status
    public var number: Int
    /// "owner/name".
    public var repository: String
    public var author: String
    /// The PR asks for my review (found by the review-requested search).
    public var awaitingMyReview: Bool
    public init(status: Status, number: Int, repository: String, author: String, awaitingMyReview: Bool) {
        self.status = status; self.number = number; self.repository = repository; self.author = author
        self.awaitingMyReview = awaitingMyReview
    }
}

@MainActor
@Observable
public final class Tab {
    public let id: ItemID
    public var url: URL
    public var title: String
    public var customTitle: String?
    /// Set when the tab is pinned or a favorite. Nil for plain today tabs.
    public var pinnedURL: URL?
    /// Emoji or SF Symbol name.
    public var customIcon: String?
    public var iconOverride: SpaceIcon?
    public var createdAt: Date
    public var lastActiveAt: Date
    public var isMuted: Bool
    public var openerID: ItemID?
    public var isUnread: Bool
    /// The pull request a Live Folder row stands for (LF L2); nil for normal tabs. A refresh
    /// matches, adds and removes only rows that carry it, never a user's own tab.
    public var liveItemURL: URL?
    /// What the Live Folder row shows about its pull request: status glyph and hover card
    /// (C-LF-1, Open's design, live-data §8). Persisted, so the glyph shows before the next refresh.
    public var liveItem: LiveItemInfo?

    public let live = TabLiveState()

    public var displayTitle: String { customTitle ?? TidyTitles.tidy(title: title, url: url) }

    public init(
        id: ItemID = ItemID(), url: URL, title: String = "",
        customTitle: String? = nil, pinnedURL: URL? = nil, customIcon: String? = nil, iconOverride: SpaceIcon? = nil,
        createdAt: Date = Date(), lastActiveAt: Date = Date(),
        isMuted: Bool = false, openerID: ItemID? = nil, isUnread: Bool = false
    ) {
        self.id = id; self.url = url; self.title = title
        self.customTitle = customTitle; self.pinnedURL = pinnedURL
        self.customIcon = customIcon; self.createdAt = createdAt
        self.iconOverride = iconOverride
        self.lastActiveAt = lastActiveAt; self.isMuted = isMuted
        self.openerID = openerID; self.isUnread = isUnread
    }
}

// MARK: - Folder

public enum FolderExpansion: Equatable, Sendable {
    case expanded, collapsed, peeked(ItemID)
}

@MainActor
@Observable
public final class Folder {
    public let id: ItemID
    public var title: String
    public var isExpanded: Bool
    public var peekedChildID: ItemID?

    public var expansion: FolderExpansion {
        if isExpanded { return .expanded }
        return peekedChildID.map { .peeked($0) } ?? .collapsed
    }

    /// Normalizes stale persisted/undo values without inventing a child.
    public func applyExpansion(_ value: FolderExpansion) {
        switch value {
        case .expanded: isExpanded = true; peekedChildID = nil
        case .collapsed: isExpanded = false; peekedChildID = nil
        case .peeked(let id):
            isExpanded = false
            peekedChildID = children.contains { $0.id == id && $0.folder == nil } ? id : nil
        }
    }
    public var customIcon: String?
    public var iconOverride: SpaceIcon?
    public var children: [SidebarNode]
    /// Set on a Live Folder (LF L2, live-data §2.7); nil for every normal folder.
    public var live: LiveFolderConfig?

    public init(id: ItemID = ItemID(), title: String = "Folder", isExpanded: Bool = true, customIcon: String? = nil, iconOverride: SpaceIcon? = nil, children: [SidebarNode] = [], peekedChildID: ItemID? = nil) {
        self.id = id; self.title = title; self.isExpanded = isExpanded
        self.customIcon = customIcon; self.children = children
        self.iconOverride = iconOverride
        self.peekedChildID = nil
        applyExpansion(isExpanded ? .expanded : peekedChildID.map { .peeked($0) } ?? .collapsed)
    }
}

// MARK: - Split

public enum SplitOrientation: String, Codable, Sendable {
    case horizontal, vertical
}

@MainActor
@Observable
public final class Split {
    public let id: ItemID
    public var orientation: SplitOrientation
    /// One fraction per pane, normalized to sum 1. Empty means equal panes.
    public var fractions: [Double]
    public var panes: [Tab]
    public var focusedPaneID: ItemID?

    public init(id: ItemID = ItemID(), orientation: SplitOrientation = .horizontal, fractions: [Double] = [], panes: [Tab] = [], focusedPaneID: ItemID? = nil) {
        self.id = id; self.orientation = orientation; self.fractions = fractions
        self.panes = panes; self.focusedPaneID = focusedPaneID
    }
}

// MARK: - SidebarNode

@MainActor
public enum SidebarNode {
    case tab(Tab)
    case folder(Folder)
    case split(Split)

    public var id: ItemID {
        switch self {
        case .tab(let t): return t.id
        case .folder(let f): return f.id
        case .split(let s): return s.id
        }
    }

    public var tab: Tab? { if case .tab(let t) = self { return t }; return nil }
    public var folder: Folder? { if case .folder(let f) = self { return f }; return nil }
    public var split: Split? { if case .split(let s) = self { return s }; return nil }
}
