import Foundation
import OpenModel

/// One open pull request as a Live Folder row (live-data §2.3; the subset Open shows).
public struct PRSnapshot: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case open, draft, merged, closed }
    public var url: URL
    public var title: String
    public var number: Int
    /// "owner/name".
    public var repository: String
    public var author: String
    public var status: Status
    public var updatedAt: Date?
    /// Which searches found it (createdByMe, reviewRequested, …).
    public var kinds: Set<LiveFolderConfig.Kind>
    public init(url: URL, title: String, number: Int, repository: String, author: String, status: Status,
                updatedAt: Date?, kinds: Set<LiveFolderConfig.Kind>) {
        self.url = url; self.title = title; self.number = number; self.repository = repository
        self.author = author; self.status = status; self.updatedAt = updatedAt; self.kinds = kinds
    }
}

extension PRSnapshot {
    /// The row's stored facts (C-LF-1). "Awaiting my review" = found by the review-requested search.
    public var liveItemInfo: LiveItemInfo {
        LiveItemInfo(status: LiveItemInfo.Status(rawValue: status.rawValue) ?? .open, number: number, repository: repository,
                     author: author, awaitingMyReview: kinds.contains(.reviewRequested))
    }
}

/// GitHub searches, one per kind (live-data §2.4, query fragments are facts from Arc's strings).
public enum GitHubQuery {
    /// Most rows a Live Folder keeps (memory and row budget: F2-report §6, ≤ 200 per Profile).
    public static let maxItems = 50
    public static let defaultOrigin = URL(string: "https://github.com")!

    public static func query(_ kind: LiveFolderConfig.Kind, teamReviews: Bool) -> String {
        let base = "is:pr is:open sort:updated-desc"
        switch kind {
        case .createdByMe: return base + " author:@me involves:@me"
        case .reviewRequested: return base + (teamReviews ? " review-requested:@me" : " user-review-requested:@me involves:@me")
        case .approved: return base + " review:approved involves:@me"
        case .changesRequested: return base + " review:changes_requested involves:@me"
        }
    }

    /// The pulls search page for one kind. `origin` is github.com, or a fixture origin in automation.
    public static func url(_ kind: LiveFolderConfig.Kind, teamReviews: Bool, origin: URL = defaultOrigin) -> URL {
        var components = URLComponents(url: origin.appendingPathComponent("pulls"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query(kind, teamReviews: teamReviews))]
        return components.url!
    }

    /// Open's own extraction script (Open isolated world). Reads the search page the hidden page
    /// loaded and returns `{state, items[]}`: state is "ok", "signedOut", "needsSSO" or "unexpected".
    /// Prefers rows in the DOM that link to pull requests; never sends anything anywhere.
    public static let extractionScript = #"""
    (() => {
      const path = location.pathname;
      if (path.startsWith('/login') || path.startsWith('/session') || document.querySelector('form[action="/session"]'))
        return {state: 'signedOut', items: []};
      const banner = document.querySelector("[data-testid='global-sso-banner']");
      if (banner) {
        const link = Array.from(banner.querySelectorAll('a[href]')).slice(0, 20).map(a => {
          try { return new URL(a.getAttribute('href'), location.href); } catch { return null; }
        }).find(u => u && u.origin === location.origin && /^\/orgs\/[^/]+\/sso\/?$/.test(u.pathname));
        return {state: 'needsSSO', items: [], ssoURL: link?.href || null};
      }
      const seen = new Set(), items = [];
      for (const link of document.querySelectorAll('a[href*="/pull/"]')) {
        const href = new URL(link.getAttribute('href'), location.href);
        const m = href.pathname.match(/^\/([^/]+)\/([^/]+)\/pull\/(\d+)\/?$/);
        if (!m || seen.has(href.pathname)) continue;
        const title = (link.textContent || '').trim();
        if (!title || /^#?\d+$/.test(title)) continue;
        seen.add(href.pathname);
        const row = link.closest('[data-pr-row], li, [role="listitem"], .js-issue-row, div') || link;
        const state = (row.getAttribute('data-pr-state') || row.querySelector('[data-pr-state]')?.getAttribute('data-pr-state')
          || (row.querySelector('.octicon-git-pull-request-draft') ? 'draft' : row.querySelector('.octicon-git-merge') ? 'merged'
          : row.querySelector('.octicon-git-pull-request-closed') ? 'closed' : 'open'));
        const author = row.getAttribute('data-pr-author') || row.querySelector('[data-hovercard-type="user"]')?.textContent?.trim() || '';
        const time = row.querySelector('relative-time, time')?.getAttribute('datetime') || '';
        items.push({url: location.origin + href.pathname, title, number: Number(m[3]), repository: m[1] + '/' + m[2], author, status: state, updatedAt: time});
        if (items.length >= 100) break;
      }
      if (!items.length && !document.querySelector('.blankslate, [data-testid="empty-state"], [data-empty-state]')) return {state: 'unexpected', items: []};
      return {state: 'ok', items};
    })()
    """#

    public enum PageState: String, Sendable { case ok, signedOut, needsSSO, unexpected }

    /// The organization's SSO action, from the last banner only (C-LF-3). A page cannot
    /// turn the menu into an arbitrary link: require this origin and a bounded GitHub org
    /// slug, and build the canonical path ourselves. Query/fragment data is not retained.
    public static func ssoURL(from value: Any, origin: URL = defaultOrigin) -> URL? {
        guard let object = value as? [String: Any], object["state"] as? String == PageState.needsSSO.rawValue,
              let raw = object["ssoURL"] as? String, raw.utf8.count <= 2048, let url = URL(string: raw),
              url.scheme == origin.scheme, url.host?.lowercased() == origin.host?.lowercased(),
              url.port == origin.port, url.user == nil, url.password == nil else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4 || (parts.count == 5 && parts[4].isEmpty), parts[0].isEmpty,
              parts[1] == "orgs", parts[3] == "sso" else { return nil }
        let slug = parts[2], bytes = slug.utf8
        guard (1...39).contains(bytes.count), bytes.first != 45, bytes.last != 45,
              bytes.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else { return nil }
        return origin.appendingPathComponent("orgs").appendingPathComponent(String(slug)).appendingPathComponent("sso")
    }

    /// Decodes the script's value. Unknown or malformed rows are dropped, never guessed.
    public static func decode(_ value: Any, kind: LiveFolderConfig.Kind) -> (PageState, [PRSnapshot]) {
        guard let object = value as? [String: Any], let state = (object["state"] as? String).flatMap(PageState.init(rawValue:)) else { return (.unexpected, []) }
        let rows = (object["items"] as? [[String: Any]] ?? []).prefix(100)
        let iso = ISO8601DateFormatter()
        let items: [PRSnapshot] = rows.compactMap { row in
            guard let raw = row["url"] as? String, let url = URL(string: raw), let title = row["title"] as? String, !title.isEmpty,
                  let number = (row["number"] as? NSNumber)?.intValue, let repository = row["repository"] as? String else { return nil }
            let status = (row["status"] as? String).flatMap(PRSnapshot.Status.init(rawValue:)) ?? .open
            return PRSnapshot(url: url, title: String(title.prefix(300)), number: number, repository: repository,
                              author: row["author"] as? String ?? "", status: status,
                              updatedAt: (row["updatedAt"] as? String).flatMap(iso.date(from:)), kinds: [kind])
        }
        return (state, items)
    }

    /// Merges the per-kind results: one row per PR, kinds united, active PRs only, newest first.
    public static func merge(_ lists: [[PRSnapshot]], config: LiveFolderConfig) -> [PRSnapshot] {
        var byURL: [URL: PRSnapshot] = [:]
        for item in lists.joined() {
            if var known = byURL[item.url] { known.kinds.formUnion(item.kinds); byURL[item.url] = known } else { byURL[item.url] = item }
        }
        return byURL.values
            .filter { ($0.status == .open || $0.status == .draft) && !config.hiddenRepositories.contains($0.repository)
                && !config.hiddenItems.contains($0.url.absoluteString) }
            .sorted { ($0.updatedAt ?? .distantPast, $1.url.absoluteString) > ($1.updatedAt ?? .distantPast, $0.url.absoluteString) }
            .prefix(maxItems).map { $0 }
    }
}

/// What a refresh does to a Live Folder's rows. Only rows with `liveItemURL` are touched.
public struct LiveFolderDiff: Equatable, Sendable {
    public var add: [PRSnapshot]
    public var remove: [ItemID]
    /// Existing rows whose title changed: (row, new title).
    public var retitle: [ItemID: String]
    public var isEmpty: Bool { add.isEmpty && remove.isEmpty && retitle.isEmpty }

    @MainActor
    public static func make(folder: Folder, fresh: [PRSnapshot]) -> LiveFolderDiff {
        let rows: [(ItemID, URL, String)] = folder.children.compactMap { node in
            guard case .tab(let tab) = node, let url = tab.liveItemURL else { return nil }
            return (tab.id, url, tab.title)
        }
        let wanted = Dictionary(fresh.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        let known = Set(rows.map(\.1))
        var retitle: [ItemID: String] = [:]
        for (id, url, title) in rows { if let item = wanted[url], item.title != title { retitle[id] = item.title } }
        return LiveFolderDiff(add: fresh.filter { !known.contains($0.url) },
                              remove: rows.filter { wanted[$0.1] == nil }.map(\.0), retitle: retitle)
    }
}
