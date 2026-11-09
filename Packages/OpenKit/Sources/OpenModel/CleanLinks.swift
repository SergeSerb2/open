import Foundation

extension URLCleaner {
    /// Arc's clean-link toast for `count` copied links: singular or plural.
    public static func cleanedTitle(count: Int) -> String { count == 1 ? cleanedTitle : cleanedLinksTitle }

    /// `[title](url)` with `\`, `[` and `]` escaped in the title, for every Markdown link copy.
    public static func markdownLink(title: String, url: URL) -> String {
        let escaped = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(escaped)](\(url.absoluteString))"
    }
}

/// The text a sidebar Copy Link / Copy Links / Copy All Links writes, one clean link per line.
public struct CleanLinkPayload: Sendable {
    public var text: String
    public var count: Int
    public var removedTrackers: Bool
    /// The clean-link toast title, or nil when no tracker was removed.
    public var toastTitle: String? { removedTrackers ? URLCleaner.cleanedTitle(count: count) : nil }
}

extension BrowserModel {
    /// Clean links for the sidebar nodes `ids`, in order. A selected folder or split covers its
    /// descendants; each tab appears once. Nil when the selection holds no tab.
    public func cleanLinkPayload(ids: [ItemID], markdown: Bool) -> CleanLinkPayload? {
        var seen = Set<ItemID>(), lines: [String] = [], removedTrackers = false
        func append(_ node: SidebarNode) {
            guard seen.insert(node.id).inserted else { return }
            switch node {
            case .tab(let tab):
                let (clean, removed) = URLCleaner.clean(tab.url)
                removedTrackers = removedTrackers || !removed.isEmpty
                lines.append(markdown ? URLCleaner.markdownLink(title: tab.displayTitle, url: clean) : clean.absoluteString)
            case .folder(let folder): folder.children.forEach(append)
            case .split(let split): split.panes.forEach { append(.tab($0)) }
            }
        }
        // Selected containers cover their descendants, even if a child also appears
        // earlier in the payload. Preserve the displayed order of top-level nodes.
        let selected = Set(ids)
        for id in ids {
            var parent = self.parent(of: id), covered = false
            while let current = parent {
                switch current {
                case .folder(let ancestor), .splitPane(let ancestor):
                    if selected.contains(ancestor) { covered = true }
                    parent = self.parent(of: ancestor)
                default: parent = nil
                }
            }
            if !covered, let node = node(id: id) { append(node) }
        }
        guard !lines.isEmpty else { return nil }
        return CleanLinkPayload(text: lines.joined(separator: "\n"), count: lines.count, removedTrackers: removedTrackers)
    }
}
