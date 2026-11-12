import Foundation

/// The Gmail hover card (live-data §3.3; F2-report §4 and LEAD 11:05 Q5): unread mail of one
/// Gmail inbox, read from the Gmail Atom feed with the Profile's own Google session inside a
/// hidden page. No OAuth client, no server, nothing on disk (LEAD Q3: memory only).
public enum GmailGlance {
    /// Settings switch (CAL's Arc-import mapping: gmailPreviewEnabled → this key).
    public static let preferenceKey = "open.general.previewsGmail"
    /// Arc's strings (LD §3.3).
    public static let header = "Unread"
    public static let newLabel = "New Email"
    public static let emptyText = "No unread emails, you can exhale! 🍃"
    public static let signedOutText = "Sign in to your Email to see messages at a glance."
    /// Most rows a card shows (GUESS — capture pending, F2 item 9).
    public static let limit = 6
    public static let host = "mail.google.com"

    /// The inbox number of a Gmail tab (`/mail/u/<n>/…`, `/mail/…` = 0), or nil for other URLs.
    /// `extraHosts` are automation fixture hosts (empty in normal use).
    public static func account(of url: URL, extraHosts: Set<String> = []) -> Int? {
        guard let host = url.host?.lowercased(), host == Self.host || extraHosts.contains(host),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.first == "mail" else { return nil }
        if parts.count >= 3, parts[1] == "u", let n = Int(parts[2]), (0...9).contains(n) { return n }
        return 0
    }

    private static func origin(of tab: URL) -> String {
        var components = URLComponents()
        components.scheme = tab.scheme; components.host = tab.host; components.port = tab.port
        return components.string ?? "https://\(host)"
    }
    /// The Atom feed of inbox `account` (LD §3.5: path GUESS `/mail/u/<n>/feed/atom`).
    public static func feedURL(for tab: URL, account: Int) -> URL { URL(string: origin(of: tab) + "/mail/u/\(account)/feed/atom")! }
    /// "New Email" (LD §3.3: `https://mail.google.com/mail/u/<n>/#compose`).
    public static func composeURL(for tab: URL, account: Int) -> URL { URL(string: origin(of: tab) + "/mail/u/\(account)/#compose")! }

    /// Open's own script (Open isolated world) on the loaded feed page: refetches the feed text
    /// in the page (same origin, the session's cookies) and parses it. A sign-in redirect leaves
    /// the mail host: signed out.
    public static func extractionScript(expectedHost: String) -> String {
        let host = expectedHost.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "'", with: "")
        return """
        (async () => {
          if (location.hostname !== '\(host)') return {state: 'signedOut', items: []};
          let text = '';
          try { const r = await fetch(location.href, {credentials: 'include'}); if (r.status === 401 || r.status === 403) return {state: 'signedOut', items: []}; text = await r.text(); }
          catch (e) { return {state: 'unexpected', items: []}; }
          const doc = new DOMParser().parseFromString(text, 'application/xml');
          if (doc.getElementsByTagName('parsererror').length || !doc.getElementsByTagName('feed').length) return {state: 'unexpected', items: []};
          const tx = (e, n) => (e.getElementsByTagName(n)[0]?.textContent || '').trim();
          const items = [...doc.getElementsByTagName('entry')].slice(0, 50).map(e => ({
            title: tx(e, 'title'), author: tx(e, 'name'), date: tx(e, 'issued') || tx(e, 'modified'),
            url: e.getElementsByTagName('link')[0]?.getAttribute('href') || ''}));
          return {state: 'ok', items};
        })()
        """
    }

    public enum State: String, Sendable { case ok, signedOut, unexpected }

    /// Decodes the script's value; rows without a link are dropped, never guessed.
    public static func decode(_ value: Any) -> (State, [UnreadMail]) {
        guard let object = value as? [String: Any], let state = (object["state"] as? String).flatMap(State.init(rawValue:)) else { return (.unexpected, []) }
        let iso = ISO8601DateFormatter()
        let rows = (object["items"] as? [[String: Any]] ?? []).prefix(50).compactMap { row -> UnreadMail? in
            guard let raw = row["url"] as? String, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return nil }
            let title = (row["title"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(300)) } ?? "(no subject)"
            return UnreadMail(title: title, author: String((row["author"] as? String ?? "").prefix(120)),
                              date: (row["date"] as? String).flatMap(iso.date(from:)), url: url)
        }
        return (state, Array(rows))
    }
}

/// One unread mail row (memory only).
public struct UnreadMail: Equatable, Sendable {
    public var title: String
    public var author: String
    public var date: Date?
    public var url: URL
    public init(title: String, author: String, date: Date?, url: URL) { self.title = title; self.author = author; self.date = date; self.url = url }
}

/// What the App's mail source returns to the card.
public enum MailGlanceResult: Sendable {
    case mail([UnreadMail])
    case signedOut
    case failed
}
