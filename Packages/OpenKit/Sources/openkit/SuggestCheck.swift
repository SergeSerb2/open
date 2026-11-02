import Foundation
import Synchronization
import OpenModel
import OpenStore
import OpenSuggest

// `openkit suggest-check`: synthetic model + 100k-URL history, fixed scenarios through the real
// engine, a local HTTP suggest server for the network paths, and first-snapshot latency.
// Prints PASS/FAIL per scenario and exits non-zero on any failure.

extension Duration {
    fileprivate var milliseconds: Double {
        let c = components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
}

// MARK: - Recorder

@MainActor
private final class CheckLog {
    struct Row { let name: String; let pass: Bool; let detail: String }
    private(set) var rows: [Row] = []

    func check(_ name: String, _ pass: Bool, _ detail: @autoclosure () -> String) {
        let d = detail()
        rows.append(Row(name: name, pass: pass, detail: d))
        print("\(pass ? "PASS" : "FAIL")  \(name)  —  \(d)")
    }

    var failures: Int { rows.filter { !$0.pass }.count }

    func printTable() {
        print("\n| # | Result | Scenario |")
        print("|---|---|---|")
        for (i, r) in rows.enumerated() { print("| \(i + 1) | \(r.pass ? "PASS" : "FAIL") | \(r.name) |") }
    }
}

@MainActor
private func snapshots(_ engine: SuggestEngine, _ text: String, _ context: SuggestContext) async -> [SuggestionSnapshot] {
    var all: [SuggestionSnapshot] = []
    for await s in engine.query(text, context: context) { all.append(s) }
    return all
}

@MainActor
private func lastSnapshot(_ engine: SuggestEngine, _ text: String, _ context: SuggestContext) async -> SuggestionSnapshot? {
    await snapshots(engine, text, context).last
}

private func describe(_ s: Suggestion?) -> String {
    guard let s else { return "none" }
    return "\(s.kind.rawValue) \"\(s.title)\" \(s.url?.absoluteString ?? s.actionID ?? s.siteSearchID ?? "-") score=\(String(format: "%.1f", s.score))"
}

// MARK: - Fixture

@MainActor
private struct Fixture {
    let model: BrowserModel
    let profile: Profile, otherProfile: Profile
    let work: Space, personal: Space, elsewhere: Space
    let design: Tab, merged: Tab, news: Tab, cafe: Tab, splitLeft: Tab, splitRight: Tab, mail: Tab, secret: Tab

    init() {
        let now = Date()
        profile = Profile(name: "Check")
        otherProfile = Profile(name: "Other")
        work = Space(title: "Work", profileID: profile.id)
        personal = Space(title: "Personal", profileID: profile.id)
        elsewhere = Space(title: "Elsewhere", profileID: otherProfile.id)
        func tab(_ url: String, _ title: String, ago: TimeInterval, pinned: Bool = false) -> Tab {
            let u = URL(string: url)!
            return Tab(url: u, title: title, pinnedURL: pinned ? u : nil, lastActiveAt: now.addingTimeInterval(-ago))
        }
        design = tab("https://docs.example.com/d/design-review", "Design Review", ago: 600)
        merged = tab("https://example.com/merged/", "Merged Page", ago: 3_600)
        news = tab("https://news.example.com/latest", "Latest News", ago: 7_200, pinned: true)
        cafe = tab("https://cafe.example.com/menu", "Café Menu", ago: 86_400)
        splitLeft = tab("https://left.example.com/", "Split Left", ago: 120)
        splitRight = tab("https://right.example.com/", "Split Right", ago: 240)
        mail = tab("https://mail.example.com/inbox", "Mail Inbox", ago: 30, pinned: true)
        secret = tab("https://secret.example.com/plans", "Secret Plans", ago: 60)
        work.pinned = [.tab(news)]
        work.today = [.tab(design), .tab(merged), .split(Split(panes: [splitLeft, splitRight]))]
        personal.today = [.folder(Folder(title: "Food", children: [.tab(cafe)]))]
        elsewhere.today = [.tab(secret)]
        profile.favorites = [mail]
        model = BrowserModel(profiles: [profile, otherProfile], spaces: [work, personal, elsewhere],
                             windows: [BrowserWindowState(focusedSpaceID: work.id)])
    }

    /// New-tab context in Work with "Split Left" selected.
    func context(mode: SuggestMode = .newTab, current: Tab? = nil, remote: Bool = false, engine: String? = nil, site: String? = nil) -> SuggestContext {
        let tab = current ?? splitLeft
        return SuggestContext(mode: mode, profileID: profile.id, spaceID: work.id, currentTabID: tab.id, currentTabURL: tab.url,
                              allowsRemoteSuggestions: remote, searchEngineID: engine, siteSearchID: site)
    }
}

/// 100k synthetic URLs plus the pages the scenarios need.
private func makeHistory(at root: URL) async -> HistoryStore {
    let directories = ProfileDirectories(root: root)
    let dataRoot: OpenDataRoot.Preparation
    do { dataRoot = try await OpenDataRoot.prepare(root: root) }
    catch { profileCLIError("cannot prepare data root: \(error)") }
    defer { withExtendedLifetime(dataRoot) {} }
    try! directories.ensureProfileDirectories(dataDirectoryName: "Default")
    let history = HistoryStore(fileURL: directories.historyFileURL(dataDirectoryName: "Default"))
    let now = Date()
    var items: [(url: URL, title: String, time: Date)] = []
    items.reserveCapacity(100_000)
    for n in 0..<100_000 {
        items.append((URL(string: "https://site-\(n % 5000).example.org/article/\(n)")!, "Article number \(n) about topic \(n % 200)", now.addingTimeInterval(-Double(n * 30))))
    }
    var offset = 0
    while offset < items.count {
        await history.recordVisitsBulk(Array(items[offset..<min(offset + 10_000, items.count)]))
        offset += 10_000
    }
    let github = URL(string: "https://github.com/")!
    for _ in 0..<5 { await history.recordVisit(url: github, title: "GitHub", time: now.addingTimeInterval(-3_600), typed: true) }
    await history.recordVisit(url: URL(string: "https://github.com/explore")!, title: "Explore GitHub", time: now.addingTimeInterval(-86_400))
    for _ in 0..<2 { await history.recordVisit(url: URL(string: "http://www.example.com/merged#top")!, title: "Merged Page", time: now.addingTimeInterval(-7_200)) }
    for _ in 0..<3 { await history.recordVisit(url: URL(string: "https://www.youtube.com/watch?v=abc123")!, title: "A Video", time: now.addingTimeInterval(-600)) }
    await history.recordVisit(url: URL(string: "https://developer.apple.com/documentation")!, title: "Apple Developer Documentation", time: now)
    return history
}

// MARK: - Local suggest server

/// Minimal HTTP/1.1 server on 127.0.0.1 that answers OpenSearch JSON: `[q, [q+" one", q+" two", q+" three"]]`.
/// A query that starts with "slow" waits 800 ms first. Every query it receives is logged.
private final class LocalSuggestServer: Sendable {
    let port: UInt16
    private let listener: Int32
    private let log = Mutex<[String]>([])

    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa -> Bool in
                var len = size
                return bind(fd, sa, size) == 0 && listen(fd, 32) == 0 && getsockname(fd, sa, &len) == 0
            }
        }
        guard ok else { close(fd); return nil }
        listener = fd
        port = UInt16(bigEndian: addr.sin_port)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    var requests: [String] { log.withLock { $0 } }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            DispatchQueue.global().async { [self] in handle(client) }
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        var noSigPipe: Int32 = 1 // the client may hang up first (timeout check)
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var request: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        let end: [UInt8] = [13, 10, 13, 10]
        while request.count < 65_536 {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { return }
            request.append(contentsOf: buffer[0..<n])
            if request.count >= 4, request.indices.dropLast(3).contains(where: { Array(request[$0..<($0 + 4)]) == end }) { break }
        }
        let head = String(decoding: request, as: UTF8.self)
        guard let line = head.components(separatedBy: "\r\n").first?.split(separator: " "), line.count >= 2,
              let components = URLComponents(string: "http://127.0.0.1" + line[1]) else { return }
        let q = components.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
        log.withLock { $0.append(q) }
        if q.hasPrefix("slow") { usleep(800_000) }
        let body = (try? JSONSerialization.data(withJSONObject: [q, [q + " one", q + " two", q + " three"]])) ?? Data()
        let response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        _ = response.withUnsafeBytes { write(client, $0.baseAddress, response.count) }
    }
}

// MARK: - Scenarios

@MainActor
func runSuggestCheck(args: [String]) async {
    let log = CheckLog()
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("openkit-suggest-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let pslStart = ContinuousClock.now
    let rules = PublicSuffixList.shared.ruleCount
    print(String(format: "public suffix list: %d ICANN rules (%@), loaded in %.2f ms", rules,
                 PublicSuffixList.shared.version ?? "no version line", (ContinuousClock.now - pslStart).milliseconds))
    print("building history (100k URLs)…")
    let historyStart = ContinuousClock.now
    let history = await makeHistory(at: tmp)
    print(String(format: "history ready: %d URLs in %.0f ms", await history.urlCount(), (ContinuousClock.now - historyStart).milliseconds))

    let fx = Fixture()
    let engine = SuggestEngine(model: fx.model, history: history, fetcher: nil)
    let ctx = fx.context()

    // 1. "gith" → GitHub (history) is the top hit.
    if let s = await lastSnapshot(engine, "gith", ctx) {
        let top = s.topHit
        log.check("\"gith\" → GitHub history is the top hit",
                  top?.kind == .history && top?.url.map(TextMatching.displayHost) == "github.com",
                  "top=\(describe(top)) rule=\(s.topHitRule.rawValue)")
    }

    // 2. "localhost:3000" → navigate.
    if let s = await lastSnapshot(engine, "localhost:3000", ctx) {
        log.check("\"localhost:3000\" → navigate", s.topHit?.kind == .navigate && s.topHit?.url?.absoluteString == "http://localhost:3000/",
                  "top=\(describe(s.topHit)) rule=\(s.topHitRule.rawValue)")
    }

    // 3. "2+2*3" → 8.
    if let s = await lastSnapshot(engine, "2+2*3", ctx) {
        log.check("\"2+2*3\" → calculator 8", s.topHit?.kind == .calculator && s.topHit?.title == "8", "top=\(describe(s.topHit))")
    }

    // 4. "split" → Add Split View.
    if let s = await lastSnapshot(engine, "split", ctx) {
        log.check("\"split\" → Split View action is the top hit", s.topHit?.actionID == "add-split-view",
                  "top=\(describe(s.topHit)) rule=\(s.topHitRule.rawValue)")
    }

    // 5. Exact open-tab title → Switch to Tab, with its Space.
    if let s = await lastSnapshot(engine, "Design Review", ctx) {
        let top = s.topHit
        log.check("exact tab title → Switch to Tab (with Space)",
                  top?.kind == .switchToTab && top?.tabID == fx.design.id && top?.spaceID == fx.work.id && top?.spaceTitle == "Work",
                  "top=\(describe(top)) space=\(top?.spaceTitle ?? "nil") rule=\(s.topHitRule.rawValue)")
    }

    // 6. "youtube.com/watch" → navigate.
    if let s = await lastSnapshot(engine, "youtube.com/watch", ctx) {
        log.check("\"youtube.com/watch\" → navigate", s.topHit?.kind == .navigate && s.topHit?.url?.absoluteString == "https://youtube.com/watch",
                  "top=\(describe(s.topHit)) rule=\(s.topHitRule.rawValue)")
    }

    // 7. Open tab + history for one page → one merged Switch to Tab row.
    if let s = await lastSnapshot(engine, "Merged", ctx) {
        let rows = s.suggestions.filter { $0.url.map(TextMatching.urlKey) == "example.com/merged" }
        log.check("open tab + history (http/www/#/slash variants) → one Switch to Tab row",
                  rows.count == 1 && rows[0].kind == .switchToTab && rows[0].providers.contains("history"),
                  "rows=\(rows.count) kind=\(rows.first?.kind.rawValue ?? "-") providers=\(rows.first?.providers ?? [])")
    }

    // 8. Empty query.
    let empty = await snapshots(engine, "", ctx)
    if let s = empty.last {
        let kinds = Set(s.suggestions.map(\.kind))
        // The current tab is a row in Cmd+T (commandbar-completion §4.1.3, F0063); scenario 39 checks both modes.
        // Arc's empty Cmd+T (S2 18/0008, 18/0044 AX): up to four open tabs, then the help action; no history.
        let tabRows = s.suggestions.prefix { $0.kind == .switchToTab }.count
        log.check("empty query → no top hit; up to 4 open tabs, then Contact the Team; no history",
                  !s.hasTopHit && s.isFinal && kinds.isSubset(of: [.switchToTab, .action]) && tabRows <= 4
                    && s.suggestions.dropFirst(tabRows).map(\.actionID) == (s.suggestions.contains { $0.kind == .action } ? ["contact-team"] : [])
                    && s.suggestions.count == tabRows + s.suggestions.filter { $0.kind == .action }.count,
                  "snapshots=\(empty.count) rows=\(s.suggestions.count) kinds=\(kinds.map(\.rawValue).sorted()) rule=\(s.topHitRule.rawValue)")
    }
    let blank = await lastSnapshot(engine, "   ", fx.context(mode: .searchTabs))
    log.check("whitespace query in search-tabs mode → tabs by recency, no top hit",
              blank.map { !$0.hasTopHit && !$0.suggestions.isEmpty && $0.suggestions.allSatisfy { $0.kind == .switchToTab } } ?? false,
              "rows=\(blank?.suggestions.count ?? -1)")

    // 9. What-you-typed table.
    let urlCases: [(String, String?)] = [
        ("localhost:3000", "http://localhost:3000/"), ("github.com", "https://github.com/"),
        ("youtube.com/watch", "https://youtube.com/watch"), ("Example.CO.UK/Path", "https://example.co.uk/Path"),
        ("192.168.1.1", "http://192.168.1.1/"), ("[::1]:8080", "http://[::1]:8080/"),
        ("intranet/", "http://intranet/"), ("myserver:8080", "http://myserver:8080/"), ("app.test", "http://app.test/"),
        ("https://example.com/a b", "https://example.com/a%20b"), ("about:blank", "about:blank"),
        ("~/Downloads", URL(filePath: NSHomeDirectory() + "/Downloads").absoluteString),
        ("co.uk", nil), ("node.js", nil), ("3.14", nil), ("what is github.com", nil),
        ("user@example.com", nil), ("javascript:alert(1)", nil), ("999.1.1.1", nil), ("foo:bar", nil),
    ]
    var urlFailures: [String] = []
    for (input, expected) in urlCases {
        guard let s = await lastSnapshot(engine, input, ctx) else { urlFailures.append(input); continue }
        let got = s.topHit
        let ok = expected.map { got?.kind == .navigate && got?.url?.absoluteString == $0 } ?? (got?.kind == .search && got?.title == input)
        if !ok { urlFailures.append("\(input) → \(describe(got))") }
    }
    log.check("what-you-typed table (\(urlCases.count) inputs: schemes, hosts, PSL, IPs, ports, paths, searches)",
              urlFailures.isEmpty, urlFailures.isEmpty ? "all match" : urlFailures.joined(separator: "; "))

    // 10. Calculator table.
    let calcCases: [(String, String?)] = [
        ("2+2*3", "8"), ("(1+2)^3 \u{2212} 4 \u{00F7} 2", "25"), ("200*15%", "30"), ("100+10%", "110"), ("-2^2", "-4"),
        ("10 % 3", "1"), ("2^-1", "0.5"), (".5*4", "2"), ("0.1+0.2", "0.3"), ("7 \u{00D7} 6", "42"),
        ("1/0", nil), ("42", nil), ("-5", nil), ("2+", nil), ("2**10", "1024"),
    ]
    var calcFailures: [String] = []
    for (input, expected) in calcCases {
        let s = await lastSnapshot(engine, input, ctx)
        let calc = s?.suggestions.first { $0.kind == .calculator }
        let ok = expected.map { calc?.title == $0 && s?.topHit?.kind == .calculator } ?? (calc == nil)
        if !ok { calcFailures.append("\(input) → \(calc?.title ?? "none")") }
    }
    log.check("calculator table (\(calcCases.count) inputs: precedence, unicode ops, percent, modulo, errors)",
              calcFailures.isEmpty, calcFailures.isEmpty ? "all match" : calcFailures.joined(separator: "; "))

    // 11. Typed host absorbs its history title.
    if let s = await lastSnapshot(engine, "github.com", ctx) {
        log.check("\"github.com\" → navigate, merged with its history row",
                  s.topHit?.kind == .navigate && s.topHit?.subtitle == "GitHub" && s.suggestions.filter { $0.url.map(TextMatching.urlKey) == "github.com" }.count == 1,
                  "top=\(describe(s.topHit)) subtitle=\(s.topHit?.subtitle ?? "")")
    }

    // 12. Query encoding.
    if let s = await lastSnapshot(engine, "c++ & rust", ctx) {
        log.check("search URL encodes + & and spaces", s.topHit?.url?.absoluteString == "https://www.google.com/search?q=c%2B%2B%20%26%20rust",
                  "url=\(s.topHit?.url?.absoluteString ?? "nil")")
    }
    if let s = await lastSnapshot(engine, "rust lifetimes", fx.context(engine: "duckduckgo")) {
        log.check("engine choice: DuckDuckGo search URL", s.topHit?.url?.host() == "duckduckgo.com", "url=\(s.topHit?.url?.absoluteString ?? "nil")")
    }

    let searchTab = fx.model.newTab(in: fx.work.id, url: URL(string: "https://www.google.com/search?q=open%20browser")!, title: "open browser - Google Search")
    if let s = await lastSnapshot(engine, "open browser", ctx) {
        log.check("typed search equal to an open tab's search page → that tab is the top hit (no duplicate)",
                  s.topHit?.tabID == searchTab.id && s.topHit?.isWhatYouTyped == true && !s.suggestions.contains { $0.kind == .search },
                  "top=\(describe(s.topHit)) rule=\(s.topHitRule.rawValue)")
    }

    // 13. Case and diacritics.
    let cafeExact = await lastSnapshot(engine, "cafe menu", ctx)
    let cafeUpper = await lastSnapshot(engine, "CAFÉ", ctx)
    log.check("case- and diacritic-insensitive (\"cafe menu\", \"CAFÉ\" → Café Menu)",
              cafeExact?.topHit?.tabID == fx.cafe.id && cafeExact?.topHitRule == .exactTab
                && (cafeUpper?.suggestions.contains { $0.tabID == fx.cafe.id } ?? false),
              "cafe menu top=\(describe(cafeExact?.topHit)); CAFÉ has tab=\(cafeUpper?.suggestions.contains { $0.tabID == fx.cafe.id } ?? false)")

    // 14. Profile isolation.
    let own = await lastSnapshot(engine, "secret plans", ctx)
    let otherCtx = SuggestContext(profileID: fx.otherProfile.id, spaceID: fx.elsewhere.id, allowsRemoteSuggestions: false)
    let theirs = await lastSnapshot(engine, "secret plans", otherCtx)
    log.check("tabs of another Profile never appear",
              !(own?.suggestions.contains { $0.tabID == fx.secret.id } ?? true) && (theirs?.suggestions.contains { $0.tabID == fx.secret.id } ?? false),
              "own profile has it=\(own?.suggestions.contains { $0.tabID == fx.secret.id } ?? true); other profile has it=\(theirs?.suggestions.contains { $0.tabID == fx.secret.id } ?? false)")

    // 15. Search-tabs mode.
    if let s = await lastSnapshot(engine, "news", fx.context(mode: .searchTabs)) {
        log.check("search-tabs mode → only tab rows, best tab on top",
                  s.suggestions.allSatisfy { $0.kind == .switchToTab } && s.topHit?.tabID == fx.news.id && s.topHitRule == .bestTab,
                  "kinds=\(Set(s.suggestions.map(\.kind.rawValue)).sorted()) top=\(describe(s.topHit))")
    }

    // 16. Edit mode (Cmd+L) on the current URL.
    if let s = await lastSnapshot(engine, fx.design.url.absoluteString, fx.context(mode: .editCurrentURL, current: fx.design)) {
        log.check("edit mode: current URL → navigate it; the current tab is not offered",
                  s.topHit?.kind == .navigate && s.topHit?.url == fx.design.url && !s.suggestions.contains { $0.tabID == fx.design.id },
                  "top=\(describe(s.topHit))")
    }

    // 17. Action availability follows the selected tab.
    let onPinned = await lastSnapshot(engine, "pin", fx.context(current: fx.news))
    let onToday = await lastSnapshot(engine, "pin", fx.context(current: fx.design))
    let pinnedIDs = Set(onPinned?.suggestions.compactMap(\.actionID) ?? [])
    let todayIDs = Set(onToday?.suggestions.compactMap(\.actionID) ?? [])
    log.check("actions hide when they do not apply (Pin vs Unpin)",
              pinnedIDs.contains("unpin-tab") && !pinnedIDs.contains("pin-tab") && todayIDs.contains("pin-tab") && !todayIDs.contains("unpin-tab"),
              "pinned tab → \(pinnedIDs.sorted()); today tab → \(todayIDs.sorted())")
    if let s = await lastSnapshot(engine, "clear today", ctx) {
        log.check("Search alias \"clear today\" → Clear Unpinned Tabs", s.topHit?.actionID == "clear-unpinned-tabs", "top=\(describe(s.topHit))")
    }

    // 18. Focus on <Space>.
    if let s = await lastSnapshot(engine, "personal", ctx) {
        let focus = s.suggestions.first { $0.actionID == ActionRegistry.focusSpaceActionID }
        log.check("\"personal\" → Focus on Personal (dynamic Space action)", focus?.spaceID == fx.personal.id, "row=\(describe(focus))")
    }

    // 19. Site Search.
    let ytSpace = await lastSnapshot(engine, "yt cats", ctx)
    let ytHint = await lastSnapshot(engine, "you", ctx)
    let ytScoped = await lastSnapshot(engine, "cats", fx.context(site: "youtube"))
    let spaceRow = ytSpace?.suggestions.first { $0.kind == .siteSearch }
    let hintRow = ytHint?.suggestions.first { $0.kind == .siteSearchHint }
    log.check("Site Search: \"yt cats\" row, \"you\" Tab hint, scoped query, Tab target",
              spaceRow?.url?.absoluteString == "https://www.youtube.com/results?search_query=cats"
                && hintRow?.siteSearchID == "youtube"
                && ytScoped?.topHit?.kind == .siteSearch && ytScoped?.topHitRule == .siteSearchScope
                && ytScoped?.topHit?.url?.absoluteString == "https://www.youtube.com/results?search_query=cats"
                && !(ytScoped?.suggestions.contains { $0.kind == .search } ?? true)
                && engine.siteSearchTrigger(for: "ddg")?.id == "engine-duckduckgo",
              "space row=\(describe(spaceRow)); hint=\(hintRow?.siteSearchID ?? "nil"); scoped top=\(describe(ytScoped?.topHit)); ddg → \(engine.siteSearchTrigger(for: "ddg")?.id ?? "nil")")

    // 20. Index invalidation through Observation.
    let builds0 = engine.indexBuildCount
    _ = await lastSnapshot(engine, "design", ctx)
    let builds1 = engine.indexBuildCount
    fx.model.renameNode(id: fx.design.id, title: "Quarterly Zebra Plan")
    let renamed = await lastSnapshot(engine, "zebra plan", ctx)
    let builds2 = engine.indexBuildCount, patched = engine.lastIndexFoldedCount
    fx.merged.url = URL(string: "https://example.com/moved-elsewhere")!
    let moved = await lastSnapshot(engine, "moved elsewhere", ctx)
    let fresh = fx.model.newTab(in: fx.personal.id, url: URL(string: "https://fresh.example.com/")!, title: "Fresh Okapi Notes")
    let added = await lastSnapshot(engine, "okapi", ctx)
    let builds3 = engine.indexBuildCount, refolded = engine.lastIndexFoldedCount
    log.check("tab index: cached between keystrokes; title/URL change patches 1 tab; new tab rebuilds, re-folding only it",
              builds1 == builds0 && renamed?.suggestions.contains { $0.tabID == fx.design.id } == true && builds2 == builds1 && patched == 1
                && moved?.suggestions.contains { $0.tabID == fx.merged.id } == true
                && added?.suggestions.contains { $0.tabID == fresh.id } == true && builds3 == builds2 + 1 && refolded == 1,
              "builds: \(builds0) → query \(builds1) → rename \(builds2) (patched \(patched)) → new tab \(builds3) (re-folded \(refolded))")

    let gmail = fx.model.newTab(in: fx.work.id, url: URL(string: "https://mail.google.com/mail/#inbox")!,
                                title: "Inbox (3) - accountneedle@example.invalid - Gmail")
    let gmailResult = await lastSnapshot(engine, "accountneedle", fx.context(mode: .searchTabs))
    gmail.title = "Inbox (4) - secondneedle@example.invalid - Gmail"
    let updatedGmail = await lastSnapshot(engine, "secondneedle", fx.context(mode: .searchTabs))
    fx.model.renameNode(id: gmail.id, title: "Named Inbox")
    let customGmail = await lastSnapshot(engine, "Named Inbox", fx.context(mode: .searchTabs))
    let hiddenRaw = await lastSnapshot(engine, "secondneedle", fx.context(mode: .searchTabs))
    log.check("tidy Gmail matches raw title, displays Inbox, and patches raw/custom title changes",
              gmailResult?.suggestions.contains { $0.tabID == gmail.id && $0.title == "Inbox" } == true
                && updatedGmail?.suggestions.contains { $0.tabID == gmail.id && $0.title == "Inbox" } == true
                && customGmail?.suggestions.contains { $0.tabID == gmail.id && $0.title == "Named Inbox" } == true
                && hiddenRaw?.suggestions.contains { $0.tabID == gmail.id } == false,
              "raw-only account text remains searchable until replaced by a custom title")

    // 21. Remote suggestions against a local HTTP server.
    await remoteChecks(log: log, fx: fx)

    // 32–40. Inline completion (commandbar-completion §4.1, §5.1).
    await completionChecks(log: log, tmp: tmp)
    await splitChecks(log: log, tmp: tmp)
    await scopeChecks(log: log, engine: engine, fx: fx)

    // 22, 44. Latency, with and without inline completion.
    await latencyCheck(log: log, history: history)

    log.printTable()
    print("\nsuggest-check: \(log.rows.count - log.failures)/\(log.rows.count) passed")
    if log.failures > 0 { exit(1) }
}

@MainActor
private func remoteChecks(log: CheckLog, fx: Fixture) async {
    guard let server = LocalSuggestServer() else {
        log.check("remote: local test server", false, "could not bind 127.0.0.1")
        return
    }
    let local = SearchEngine(id: "local", name: "Local", searchURLTemplate: "https://search.invalid/?q=%s",
                             suggestURLTemplate: "http://127.0.0.1:\(server.port)/suggest?q=%s")
    let engine = SuggestEngine(model: fx.model, historyStore: nil, fetcher: HTTPSuggestionFetcher(),
                               searchEngines: SearchEngines.all + [local])
    let ctx = fx.context(remote: true, engine: "local")

    // Merge: rows arrive in a later snapshot and never move the top hit.
    let merged = await snapshots(engine, "remote alpha", ctx)
    let first = merged.first, last = merged.last
    let remoteRows = last?.suggestions.filter { $0.kind == .searchSuggestion } ?? []
    log.check("remote: suggestions merge in a later snapshot; top hit stays the typed search",
              merged.count >= 2 && !(first?.suggestions.contains { $0.kind == .searchSuggestion } ?? true)
                && remoteRows.map(\.title) == ["remote alpha one", "remote alpha two", "remote alpha three"]
                && first?.topHit?.id == last?.topHit?.id && last?.topHit?.kind == .search,
              String(format: "snapshots=%d remote rows=%d at %.0f ms; top=%@", merged.count, remoteRows.count, last?.elapsedMilliseconds ?? -1, describe(last?.topHit)))

    // Cache: the same query again answers in the first snapshot with no request.
    let before = server.requests.count
    let cached = await snapshots(engine, "remote alpha", ctx)
    log.check("remote: repeated query is served from cache in snapshot 0 (no request)",
              cached.count == 1 && (cached.first?.suggestions.filter { $0.kind == .searchSuggestion }.count ?? 0) == 3 && server.requests.count == before,
              "snapshots=\(cached.count) requests +\(server.requests.count - before)")

    // Carry-over: the next keystroke keeps matching rows until the new answer arrives.
    let carried = await snapshots(engine, "remote alpha o", ctx)
    log.check("remote: next keystroke carries over still-matching rows in snapshot 0",
              carried.first?.suggestions.contains { $0.title == "remote alpha one" } == true
                && carried.last?.suggestions.contains { $0.title == "remote alpha o one" } == true,
              "snapshot0=\(carried.first?.suggestions.filter { $0.kind == .searchSuggestion }.map(\.title) ?? []) final=\(carried.last?.suggestions.filter { $0.kind == .searchSuggestion }.map(\.title) ?? [])")

    // Port: the test server binds port 0, so concurrent runs get distinct ephemeral ports.
    let secondServer = LocalSuggestServer()
    log.check("remote: local test servers use distinct ephemeral ports",
              server.port != 0 && secondServer != nil && secondServer!.port != server.port,
              "ports \(server.port) and \(secondServer?.port ?? 0)")

    // Timeout logic, not wall clock: the provider is configured with an 80 ms debounce and a
    // 300 ms timeout, and a server that needs 800 ms is dropped — the stream still ends final
    // without remote rows even though the request went out.
    let remoteProvider = engine.providers.compactMap { $0 as? RemoteSuggestionsProvider }.first
    let slow = await snapshots(engine, "slow beta", ctx)
    log.check("remote: 300 ms timeout (server takes 800 ms) → stream ends without remote rows",
              remoteProvider?.debounce == .milliseconds(80) && remoteProvider?.timeout == .milliseconds(300)
                && slow.last?.isFinal == true && !(slow.last?.suggestions.contains { $0.kind == .searchSuggestion } ?? true)
                && server.requests.contains("slow beta"),
              "configured debounce=\(remoteProvider.map { "\($0.debounce)" } ?? "nil") timeout=\(remoteProvider.map { "\($0.timeout)" } ?? "nil"); server received slow beta=\(server.requests.contains("slow beta"))")

    // The one real wall-clock check for this timer family, with the original <600 ms budget.
    // Machine load can stretch one run, so allow up to 3 attempts; each prints its lateness
    // past debounce+timeout (380 ms) and the load average.
    var slowAttempts: [String] = []
    var slowRealtimeOK = false
    for attempt in 1...3 {
        let attemptStart = ContinuousClock.now
        let attemptSlow = await snapshots(engine, "slow rt\(attempt)", ctx)
        let attemptMs = (ContinuousClock.now - attemptStart).milliseconds
        let attemptOK = attemptSlow.last?.isFinal == true
            && !(attemptSlow.last?.suggestions.contains { $0.kind == .searchSuggestion } ?? true) && attemptMs < 600
        slowAttempts.append(String(format: "attempt %d stream ended after %.0f ms (lateness %+.0f ms past 380), load %@", attempt, attemptMs, attemptMs - 380, loadAverage()))
        print("  .. remote real-time \(slowAttempts.last!)")
        if attemptOK { slowRealtimeOK = true; break }
    }
    log.check("remote: real-time slow-server stream ends within 600 ms (debounce 80 + timeout 300)",
              slowRealtimeOK, slowAttempts.joined(separator: "; "))

    // Cancel: keystrokes inside the debounce window send only the last query.
    let mark = server.requests.count
    let s1 = engine.query("cancel g", context: ctx)
    let s2 = engine.query("cancel ga", context: ctx)
    let s3 = await snapshots(engine, "cancel gam", ctx)
    var ended = 0
    for await _ in s1 {}; ended += 1
    for await _ in s2 {}; ended += 1
    let sent = Array(server.requests[mark...])
    log.check("remote: each keystroke cancels the previous request (debounce)",
              sent == ["cancel gam"] && ended == 2 && s3.last?.suggestions.contains { $0.title == "cancel gam one" } == true,
              "server received \(sent)")

    // Privacy: no request when remote is off, for URL input, or for the current URL in edit mode.
    let mark2 = server.requests.count
    _ = await snapshots(engine, "private words", fx.context(remote: false, engine: "local"))
    _ = await snapshots(engine, "example.com/secret-path", ctx)
    _ = await snapshots(engine, fx.design.url.absoluteString, SuggestContext(
        mode: .editCurrentURL, profileID: fx.profile.id, spaceID: fx.work.id, currentTabID: fx.design.id,
        currentTabURL: fx.design.url, allowsRemoteSuggestions: true, searchEngineID: "local"))
    _ = await snapshots(engine, "12*7", ctx)
    log.check("remote: nothing sent when off, for URLs, for the current URL, for arithmetic",
              server.requests.count == mark2, "requests +\(server.requests.count - mark2)")
}

// MARK: - Latency

private struct SuggestRNG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
}

private let benchWords = ["design", "review", "quarterly", "planning", "docs", "inbox", "calendar", "dashboard", "pull request",
                          "issue", "release notes", "budget", "roadmap", "meeting", "notes", "recipe", "weather", "flight",
                          "hotel", "invoice", "café", "résumé", "team", "sync", "launch", "metrics", "onboarding", "travel",
                          "music", "video", "photos", "shopping", "news", "school", "health", "finance", "jobs", "api", "guide"]
private let benchHosts = ["github.com", "docs.google.com", "mail.google.com", "youtube.com", "figma.com", "notion.so", "linear.app",
                          "slack.com", "stackoverflow.com", "developer.apple.com", "en.wikipedia.org", "reddit.com", "amazon.com",
                          "nytimes.com", "bbc.co.uk", "calendar.google.com", "drive.google.com", "x.com", "medium.com", "vercel.com"]

/// 5,000 tabs over 10 Spaces (folders, splits, pinned, today) plus 100 favorites.
@MainActor
private func makeBenchModel() -> (BrowserModel, Profile, [Space]) {
    var rng = SuggestRNG(state: 42)
    let profile = Profile(name: "Bench")
    let now = Date()
    var n = 0
    func tab() -> Tab {
        n += 1
        let host = rng.int(4) == 0 ? "site-\(rng.int(800)).example.net" : rng.pick(benchHosts)
        let title = "\(rng.pick(benchWords).capitalized) \(rng.pick(benchWords)) \(n)"
        return Tab(url: URL(string: "https://\(host)/\(rng.pick(benchWords).replacingOccurrences(of: " ", with: "-"))/\(n)")!,
                   title: title, lastActiveAt: now.addingTimeInterval(-Double(rng.int(30 * 86_400))))
    }
    var spaces: [Space] = []
    for s in 0..<10 {
        let space = Space(title: "Space \(s)", profileID: profile.id)
        var pinned: [SidebarNode] = [], today: [SidebarNode] = []
        for _ in 0..<5 { pinned.append(.folder(Folder(title: "Folder", children: (0..<10).map { _ in .tab(tab()) }))) }
        for _ in 0..<50 { pinned.append(.tab(tab())) }
        for _ in 0..<5 { today.append(.folder(Folder(title: "Folder", children: (0..<10).map { _ in .tab(tab()) }))) }
        for _ in 0..<50 { today.append(.split(Split(panes: [tab(), tab()]))) } // 500 two-pane splits in all (plan §5.4)
        for _ in 0..<240 { today.append(.tab(tab())) }
        space.pinned = pinned
        space.today = today
        spaces.append(space)
    }
    profile.favorites = (0..<100).map { _ in tab() }
    let model = BrowserModel(profiles: [profile], spaces: spaces, windows: [BrowserWindowState(focusedSpaceID: spaces[0].id)])
    return (model, profile, spaces)
}

/// CPU time of the calling thread. The first snapshot is built on the main thread, so this is its
/// compute cost without time lost to other processes.
private func threadCPUMilliseconds() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
    return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1e6
}

private func loadAverage() -> String {
    var loads = [Double](repeating: 0, count: 3)
    _ = getloadavg(&loads, 3)
    return String(format: "%.1f %.1f %.1f on %d cores", loads[0], loads[1], loads[2], ProcessInfo.processInfo.activeProcessorCount)
}

private func percentile(_ sorted: [Double], _ p: Double) -> Double {
    sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
}

@MainActor
private func latencyCheck(log: CheckLog, history: HistoryStore) async {
    let (model, profile, spaces) = makeBenchModel()
    let engine = SuggestEngine(model: model, history: history, fetcher: nil)
    let ctx = SuggestContext(profileID: profile.id, spaceID: spaces[0].id, allowsRemoteSuggestions: false)
    engine.prewarm()
    print(String(format: "\nlatency model: %d tabs indexed, index build %.2f ms", engine.indexedTabCount, engine.lastIndexBuildMilliseconds))

    var rng = SuggestRNG(state: 7)
    let classes = ["word prefix 1-4 chars", "two words", "host prefix", "word + number", "URL-like", "arithmetic",
                   "action words", "random 3 letters", "uppercase word", "history title (\"article N\")"]
    func randomQuery() -> (Int, String) {
        let c = rng.int(10)
        switch c {
        case 0: return (c, String(rng.pick(benchWords).prefix(1 + rng.int(4))))
        case 1: return (c, rng.pick(benchWords) + " " + String(rng.pick(benchWords).prefix(2 + rng.int(3))))
        case 2: return (c, String(rng.pick(benchHosts).prefix(2 + rng.int(8))))
        case 3: return (c, "\(rng.pick(benchWords)) \(rng.int(5000))")
        case 4: return (c, "site-\(rng.int(800)).example.net/\(rng.pick(benchWords))")
        case 5: return (c, "\(rng.int(100))*\(rng.int(100))+\(rng.int(10))")
        case 6: return (c, rng.pick(["split", "pin", "new sp", "toggle s", "copy url", "archive", "history", "space 3"]))
        case 7: return (c, String((0..<3).map { _ in Character(UnicodeScalar(UInt8(97 + rng.int(26)))) }))
        case 8: return (c, rng.pick(benchWords).uppercased())
        default: return (c, "article \(rng.int(99_999))")
        }
    }
    // Warm-up.
    for _ in 0..<20 { _ = await snapshots(engine, randomQuery().1, ctx) }

    var first: [Double] = [], firstCPU: [Double] = [], second: [Double] = []
    var byClass: [Int: (first: [Double], history: [Double])] = [:]
    first.reserveCapacity(1000); firstCPU.reserveCapacity(1000); second.reserveCapacity(1000)
    print("load average: \(loadAverage())")
    for _ in 0..<1000 {
        let (c, q) = randomQuery()
        let c0 = threadCPUMilliseconds()
        let t0 = ContinuousClock.now
        var sawFirst = false
        for await snap in engine.query(q, context: ctx) {
            if !sawFirst {
                first.append((ContinuousClock.now - t0).milliseconds)
                firstCPU.append(threadCPUMilliseconds() - c0)
                byClass[c, default: ([], [])].first.append(first.last!)
                sawFirst = true
            } else if snap.timings.contains(where: { $0.provider == "history" && $0.isAsync }) && second.count < first.count {
                second.append(snap.elapsedMilliseconds)
                byClass[c, default: ([], [])].history.append(snap.elapsedMilliseconds)
            }
        }
    }
    first.sort(); firstCPU.sort(); second.sort()
    print(String(format: "first snapshot (local providers) over %d queries, wall: p50 %.3f ms  p95 %.3f ms  max %.3f ms",
                 first.count, percentile(first, 0.5), percentile(first, 0.95), first.last ?? 0))
    print(String(format: "first snapshot, main-thread CPU:           p50 %.3f ms  p95 %.3f ms  max %.3f ms",
                 percentile(firstCPU, 0.5), percentile(firstCPU, 0.95), firstCPU.last ?? 0))
    print(String(format: "history snapshot over %d queries: p50 %.3f ms  p95 %.3f ms  max %.3f ms",
                 second.count, percentile(second, 0.5), percentile(second, 0.95), second.last ?? 0))

    print("  by query class (wall ms)          first p50 / p95     history p50 / p95")
    for c in byClass.keys.sorted() {
        let f = byClass[c]!.first.sorted(), h = byClass[c]!.history.sorted()
        print("  " + classes[c].padding(toLength: 32, withPad: " ", startingAt: 0) + String(format: " %6.3f / %6.3f    %7.3f / %7.3f",
                     percentile(f, 0.5), percentile(f, 0.95), h.isEmpty ? 0 : percentile(h, 0.5), h.isEmpty ? 0 : percentile(h, 0.95)))
    }

    // Cold path: the first query after a change pays the index rebuild.
    var cold: [Double] = [], rebuild: [Double] = []
    var folded = 0
    for i in 0..<50 {
        if i % 2 == 0 {
            model.renameNode(id: spaces[i % 10].today.last!.id, title: "Renamed \(i)") // a tab title changes
        } else {
            model.newTab(in: spaces[i % 10].id, url: URL(string: "https://new-\(i).example.com/")!, title: "Opened \(i)") // structure changes
        }
        let t0 = ContinuousClock.now
        for await _ in engine.query(randomQuery().1, context: ctx) { cold.append((ContinuousClock.now - t0).milliseconds); break }
        rebuild.append(engine.lastIndexBuildMilliseconds)
        if i < 6 { print(String(format: "  change %d (%@): index %.3f ms, %d re-folded, first snapshot %.3f ms", i, i % 2 == 0 ? "title" : "new tab", engine.lastIndexBuildMilliseconds, engine.lastIndexFoldedCount, cold.last!)) }
        folded = max(folded, engine.lastIndexFoldedCount)
    }
    cold.sort(); rebuild.sort()
    print(String(format: "first snapshot right after a model change (50 changes, rebuild included): p50 %.3f ms  p95 %.3f ms  max %.3f ms",
                 percentile(cold, 0.5), percentile(cold, 0.95), cold.last ?? 0))
    print(String(format: "  index rebuild: p50 %.3f ms  max %.3f ms; at most %d tab(s) re-folded per rebuild",
                 percentile(rebuild, 0.5), rebuild.last ?? 0, folded))
    print("load average: \(loadAverage())")
    // 44 (completion half): the same 1,000 random queries with inline completion allowed, as the bar sends
    // them while typing at the end. Also times the completion check itself: every row of the first snapshot
    // through `InlineCompletion.text` (the T3a loop stops at the first eligible row, so this is an upper bound).
    rng = SuggestRNG(state: 7)
    let completionCtx = SuggestContext(profileID: profile.id, spaceID: spaces[0].id, allowsRemoteSuggestions: false, allowsInlineCompletion: true)
    var firstCPUCompletion: [Double] = [], checkCPU: [Double] = []
    var completions = 0
    for _ in 0..<1000 {
        let q = randomQuery().1
        let c0 = threadCPUMilliseconds()
        for await snap in engine.query(q, context: completionCtx) {
            firstCPUCompletion.append(threadCPUMilliseconds() - c0)
            if snap.inlineCompletion != nil { completions += 1 }
            let k0 = threadCPUMilliseconds()
            for row in snap.suggestions.prefix(12) { if let u = row.url { _ = InlineCompletion.text(typed: q, url: u) } }
            checkCPU.append(threadCPUMilliseconds() - k0)
            break
        }
    }
    firstCPUCompletion.sort(); checkCPU.sort()
    let plainP95 = percentile(firstCPU, 0.95), completionP95 = percentile(firstCPUCompletion, 0.95)
    print(String(format: "first snapshot with inline completion allowed, main-thread CPU: p50 %.3f ms  p95 %.3f ms (plain p95 %.3f); %d of 1000 snapshots completed",
                 percentile(firstCPUCompletion, 0.5), completionP95, plainP95, completions))
    print(String(format: "completion check over the snapshot rows, CPU: p50 %.4f ms  p95 %.4f ms  max %.4f ms", percentile(checkCPU, 0.5), percentile(checkCPU, 0.95), checkCPU.last ?? 0))
    log.check("44: first snapshot with inline completion p95 < 5 ms CPU (5,000 tabs incl. 500 two-pane splits); completion check p95 ≤ 0.05 ms",
              completionP95 < 5 && percentile(checkCPU, 0.95) <= 0.05 && completions > 0,
              String(format: "first p95 %.3f ms (plain %.3f); check p95 %.4f ms; %d completions; load %@", completionP95, plainP95, percentile(checkCPU, 0.95), completions, loadAverage()))
    log.check("first snapshot p95 < 5 ms main-thread CPU (1,000 random queries, 5,000 tabs, 100k history)", percentile(firstCPU, 0.95) < 5,
              String(format: "CPU p50=%.3f p95=%.3f ms; wall p50=%.3f p95=%.3f ms; history snapshot wall p50=%.3f p95=%.3f ms",
                     percentile(firstCPU, 0.5), percentile(firstCPU, 0.95), percentile(first, 0.5), percentile(first, 0.95),
                     percentile(second, 0.5), percentile(second, 0.95)))
}

// MARK: - Inline completion (scenarios 32–40)

/// Scenarios 42–43 (commandbar-completion §4.3): the Actions scope and the scope keywords.
@MainActor
private func scopeChecks(log: CheckLog, engine: SuggestEngine, fx: Fixture) async {
    let order = ActionRegistry.arcDefaults.actions.map(\.id)
    var wrong: [String] = []
    // 42. Empty query: available actions in seed order, only action rows, no top hit, up to 12.
    let empty = await lastSnapshot(engine, "", fx.context(mode: .searchActions))
    let ids = empty?.suggestions.compactMap(\.actionID) ?? []
    let kinds = Set(empty?.suggestions.map(\.kind) ?? [])
    let seeded = order.filter { ids.contains($0) }
    if ids.isEmpty || ids.count > 12 || kinds != [.action] || ids != seeded || empty?.hasTopHit != false {
        wrong.append("empty: \(ids.count) rows \(kinds.map(\.rawValue)) top \(empty?.hasTopHit ?? true) in seed order \(ids == seeded)")
    }
    // "side" → Show/Hide Sidebar is the top hit (T2a); one letter already matches (no 2-character minimum).
    let side = await lastSnapshot(engine, "side", fx.context(mode: .searchActions))
    if side?.topHit?.actionID != "toggle-sidebar" || side?.topHitRule != .bestAction || side?.suggestions.contains(where: { $0.kind != .action }) == true {
        wrong.append("side: top \(describe(side?.topHit)) rule \(side?.topHitRule.rawValue ?? "-")")
    }
    let one = await lastSnapshot(engine, "s", fx.context(mode: .searchActions))
    if (one?.suggestions.count ?? 0) == 0 { wrong.append("one letter gave no rows") }
    // Requirements still hide: on a pinned tab, "pin" offers Unpin Tab and not Pin Tab.
    let pin = await lastSnapshot(engine, "pin", fx.context(mode: .searchActions, current: fx.news))
    let pinIDs = pin?.suggestions.compactMap(\.actionID) ?? []
    if !pinIDs.contains("unpin-tab") || pinIDs.contains("pin-tab") { wrong.append("pin on a pinned tab: \(pinIDs)") }
    // No typed, history, remote, calculator, or Site Search rows; no inline completion.
    let math = await lastSnapshot(engine, "2+2", fx.context(mode: .searchActions))
    if math?.suggestions.contains(where: { $0.kind != .action }) == true || math?.inlineCompletion != nil { wrong.append("2+2 gave non-action rows") }
    log.check("42: Actions scope: empty → available actions in seed order, no top hit; \"side\" → Show/Hide Sidebar (T2a); requirements still hide; only action rows",
              wrong.isEmpty, wrong.isEmpty ? "\(ids.count) actions for the empty query" : wrong.joined(separator: "; "))

    // 43. Scope keywords: exact words only, a scope wins over a site, Space never enters a scope.
    var keys: [String] = []
    for (text, expected) in [("actions", SiteSearch.actionsScopeID), ("action", SiteSearch.actionsScopeID), ("commands", SiteSearch.actionsScopeID),
                             ("tabs", SiteSearch.tabsScopeID), ("tab", SiteSearch.tabsScopeID), ("TABS", SiteSearch.tabsScopeID)] {
        if engine.siteSearchTrigger(for: text)?.id != expected { keys.append("\(text) → \(engine.siteSearchTrigger(for: text)?.id ?? "nil")") }
    }
    for text in ["act", "actio", "tab vs", "tabs vs spaces"] where engine.siteSearchTrigger(for: text)?.isScope == true { keys.append("\(text) gave a scope") }
    if engine.siteSearchTrigger(for: "yt")?.id != "youtube" { keys.append("yt lost its site hint") }
    let spaces = await lastSnapshot(engine, "tabs vs spaces", fx.context())
    if spaces?.suggestions.contains(where: { $0.kind == .siteSearch }) == true { keys.append("\"tabs vs spaces\" made a scope search row") }
    log.check("43: scope keywords: \"actions\"/\"action\"/\"commands\" and \"tabs\"/\"tab\" give scope hints; \"act\" and \"tab vs\" do not; a site keyword keeps its hint",
              keys.isEmpty, keys.isEmpty ? "all as expected" : keys.joined(separator: "; "))
}

/// Scenario 41 (commandbar-completion §4.2.1): one row per Split View.
@MainActor
private func splitChecks(log: CheckLog, tmp: URL) async {
    let now = Date()
    let profile = Profile(name: "Splits")
    let space = Space(title: "Main", profileID: profile.id)
    let alpha = Tab(url: URL(string: "https://alpha.example.com/notes")!, title: "Alpha Notes", lastActiveAt: now.addingTimeInterval(-900))
    let beta = Tab(url: URL(string: "https://beta.example.com/board")!, title: "Beta Board", lastActiveAt: now.addingTimeInterval(-60))
    let lone = Tab(url: URL(string: "https://gamma.example.com/")!, title: "Gamma Home", lastActiveAt: now.addingTimeInterval(-30))
    let split = Split(orientation: .vertical, panes: [alpha, beta], focusedPaneID: alpha.id)
    space.today = [.tab(lone), .split(split)]
    let model = BrowserModel(profiles: [profile], spaces: [space], windows: [BrowserWindowState(focusedSpaceID: space.id)])
    let history = HistoryStore(fileURL: tmp.appendingPathComponent("split-history.sqlite3"))
    for _ in 0..<3 { await history.recordVisit(url: URL(string: "https://beta.example.com/board")!, title: "Beta Board", time: now.addingTimeInterval(-3_600), typed: true) }
    let engine = SuggestEngine(model: model, history: history, fetcher: nil)
    func ctx(_ mode: SuggestMode = .newTab, current: Tab) -> SuggestContext {
        SuggestContext(mode: mode, profileID: profile.id, spaceID: space.id, currentTabID: current.id, currentTabURL: current.url, allowsRemoteSuggestions: false)
    }
    let splitRow = "split:\(split.id.rawValue.uuidString)"
    var wrong: [String] = []
    func rows(_ s: SuggestionSnapshot?) -> String { s?.suggestions.map { "\($0.kind.rawValue):\($0.title)" }.joined(separator: ", ") ?? "none" }
    // Either pane's words find the one split row; it targets the matching pane.
    let byBeta = await lastSnapshot(engine, "beta", ctx(current: lone)), byAlpha = await lastSnapshot(engine, "alpha", ctx(current: lone))
    let betaSplits = byBeta?.suggestions.filter { $0.split != nil } ?? []
    if betaSplits.count != 1 || betaSplits.first?.id != splitRow || betaSplits.first?.tabID != beta.id { wrong.append("beta: \(rows(byBeta))") }
    if byAlpha?.suggestions.first(where: { $0.split != nil })?.tabID != alpha.id { wrong.append("alpha: \(rows(byAlpha))") }
    if byBeta?.suggestions.contains(where: { $0.tabID == beta.id && $0.split == nil }) == true { wrong.append("a pane row besides the split row") }
    // The row: titles in pane order, orientation, location, no pane-level rows.
    if let r = betaSplits.first, r.split?.paneTitles != ["Alpha Notes", "Beta Board"] || r.split?.isVertical != true || r.tabLocation != .splitPane || r.title != "Alpha Notes | Beta Board" {
        wrong.append("row fields \(String(describing: r.split))")
    }
    // History for a pane URL folds into the split row (open-tab precedence).
    let all = byBeta?.suggestions ?? []
    if all.contains(where: { $0.kind == .history && $0.url.map(TextMatching.urlKey) == TextMatching.urlKey(beta.url) }) { wrong.append("history row for a pane URL stayed: \(rows(byBeta))") }
    if !(betaSplits.first?.providers.contains("history") ?? false) { wrong.append("split row did not absorb history (providers \(betaSplits.first?.providers ?? []))") }
    // An exact pane title makes the split row the T5 top hit.
    let exact = await lastSnapshot(engine, "Beta Board", ctx(current: lone))
    if exact?.topHitRule != .exactTab || exact?.topHit?.id != splitRow { wrong.append("exact: top=\(describe(exact?.topHit)) rule=\(exact?.topHitRule.rawValue ?? "-")") }
    // Empty query: one row per split, targeting the focused pane.
    let empty = await lastSnapshot(engine, "", ctx(current: lone))
    let emptySplits = empty?.suggestions.filter { $0.split != nil } ?? []
    if emptySplits.count != 1 || emptySplits.first?.tabID != alpha.id { wrong.append("empty: \(rows(empty))") }
    // Edit mode with the current tab in the split: the split row is left out, also when the other pane matched.
    let edit = await lastSnapshot(engine, "beta", ctx(.editCurrentURL, current: alpha))
    if edit?.suggestions.contains(where: { $0.split != nil }) == true { wrong.append("edit mode kept the current split: \(rows(edit))") }
    // Caps: the split row counts as one switchToTab row; search tabs mode shows it too.
    let tabsMode = await lastSnapshot(engine, "a", ctx(.searchTabs, current: lone))
    if tabsMode?.suggestions.filter({ $0.split != nil }).count != 1 { wrong.append("search tabs: \(rows(tabsMode))") }
    log.check("41: split → one row (either pane matches, targets it); exact pane title → T5; pane history folds in; empty query → focused pane; edit mode leaves out the current split",
              wrong.isEmpty, wrong.isEmpty ? "all as expected" : wrong.joined(separator: "; "))
}

/// A small model and history for the completion table of commandbar-completion §4.1.3 and §5.1.
@MainActor
private func completionChecks(log: CheckLog, tmp: URL) async {
    let now = Date()
    let profile = Profile(name: "Completion")
    let space = Space(title: "Main", profileID: profile.id)
    let google = Tab(url: URL(string: "https://www.google.com/")!, title: "Google", lastActiveAt: now.addingTimeInterval(-300))
    let admin = Tab(url: URL(string: "http://localhost:3000/admin")!, title: "Admin Panel", lastActiveAt: now.addingTimeInterval(-600))
    let current = Tab(url: URL(string: "https://news.example.org/today")!, title: "Today News", lastActiveAt: now)
    space.today = [.tab(current), .tab(google), .tab(admin)]
    let model = BrowserModel(profiles: [profile], spaces: [space], windows: [BrowserWindowState(focusedSpaceID: space.id)])
    let history = HistoryStore(fileURL: tmp.appendingPathComponent("completion-history.sqlite3"))
    for _ in 0..<5 { await history.recordVisit(url: URL(string: "https://github.com/")!, title: "GitHub", time: now.addingTimeInterval(-3_600), typed: true) }
    for _ in 0..<2 { await history.recordVisit(url: URL(string: "https://github.com/openai")!, title: "OpenAI", time: now.addingTimeInterval(-7_200), typed: true) }
    let engine = SuggestEngine(model: model, history: history, fetcher: nil)
    func ctx(_ completion: Bool, mode: SuggestMode = .newTab, site: String? = nil) -> SuggestContext {
        SuggestContext(mode: mode, profileID: profile.id, spaceID: space.id, currentTabID: current.id, currentTabURL: current.url,
                       allowsRemoteSuggestions: false, siteSearchID: site, allowsInlineCompletion: completion)
    }
    func last(_ text: String, _ c: SuggestContext) async -> SuggestionSnapshot? { await lastSnapshot(engine, text, c) }
    func show(_ s: SuggestionSnapshot?) -> String {
        guard let s else { return "no snapshot" }
        let c = s.inlineCompletion.map { "\"\($0.fieldText)\" typed \($0.typedLength) row \($0.rowID)" } ?? "none"
        return "top=\(describe(s.topHit)) rule=\(s.topHitRule.rawValue) completion=\(c)"
    }
    let googleRow = "tab:\(google.id.rawValue.uuidString)"

    // 32. "googl" + an open tab on that host, completion on → T3a, the host, typed length 5 (F0043).
    let s32 = await last("googl", ctx(true))
    log.check("32: \"googl\" + tab on google.com → T3a, completion \"google.com\" (typed 5), row 1",
              s32?.topHitRule == .inlineCompletion && s32?.topHit?.id == googleRow && s32?.inlineCompletion == InlineCompletion(rowID: googleRow, fieldText: "google.com", typedLength: 5),
              show(s32))
    // 33. Same text with completion off: no completion, the old rules pick the top hit.
    let s33 = await last("googl", ctx(false))
    log.check("33: \"googl\" with completion off → no completion, top hit by T7", s33?.inlineCompletion == nil && s33?.topHitRule == .bestEligible, show(s33))
    // 34. The text equals the tab title → T5, completion in the candidate's (lower) case (F0062, CC-6).
    let s34 = await last("Google", ctx(true))
    log.check("34: \"Google\" = tab title → T5, completion \"google.com\" in lower case (typed 6)",
              s34?.topHitRule == .exactTab && s34?.inlineCompletion?.fieldText == "google.com" && s34?.inlineCompletion?.typedLength == 6, show(s34))
    // 35. URL-like text: T3a with completion on, T3 typed URL with it off (after Backspace).
    let s35 = await last("google.co", ctx(true)), s35off = await last("google.co", ctx(false))
    log.check("35: \"google.co\" → T3a \"google.com\" (typed 9); completion off → T3 typed URL, none",
              s35?.topHitRule == .inlineCompletion && s35?.inlineCompletion?.fieldText == "google.com" && s35?.inlineCompletion?.typedLength == 9
                && s35off?.topHitRule == .typedURL && s35off?.inlineCompletion == nil,
              "on: \(show(s35)); off: \(show(s35off))")
    // 36. The whole host: T5 matches it, so T3a is skipped; T3, no completion (F0061).
    let s36 = await last("google.com", ctx(true))
    log.check("36: whole host \"google.com\" → T3, no completion (F0061)", s36?.topHitRule == .typedURL && s36?.inlineCompletion == nil, show(s36))
    // 37. Path rule, port, and lead.
    var table: [(String, String?)] = []
    for (text, expected) in [("github.com/op", "github.com/openai"), ("gith", "github.com"), ("github.com", nil), ("localhost:30", "localhost:3000"),
                             ("https://goo", "https://google.com"), ("www.goo", "www.google.com"), ("HTTPS://WWW.GOO", "HTTPS://WWW.google.com")] as [(String, String?)] {
        let s = await last(text, ctx(true))
        let got = s?.inlineCompletion?.fieldText
        let typedOK = s?.inlineCompletion.map { $0.typedLength == text.utf16.count && $0.rowID == s?.topHit?.id } ?? true
        if got != expected || !typedOK { table.append((text, got)) }
    }
    log.check("37: path → full URL, host-only otherwise, whole host none, port kept, scheme and www. kept as typed",
              table.isEmpty, table.isEmpty ? "7 inputs as expected" : "wrong: \(table)")
    // 38. Never: arithmetic, whitespace, Site Search scope, search-tabs mode, non-web URLs, remote rows.
    var never: [String] = []
    if await last("2+2", ctx(true))?.inlineCompletion != nil { never.append("2+2") }
    if await last("goo gle", ctx(true))?.inlineCompletion != nil { never.append("whitespace") }
    if await last("goo ", ctx(true))?.inlineCompletion != nil { never.append("trailing space") }
    if await last("goo", ctx(true, site: "youtube"))?.inlineCompletion != nil { never.append("site scope") }
    if await last("goo", ctx(true, mode: .searchTabs))?.inlineCompletion != nil { never.append("search tabs") }
    if InlineCompletion.text(typed: "/Users/a", url: URL(string: "file:///Users/a/notes.txt")!) != nil { never.append("file URL") }
    if InlineCompletion.text(typed: "goo", url: URL(string: "ftp://google.com/")!) != nil { never.append("ftp URL") }
    // Text that only a typed URL or search row matches: navigate and search rows never complete.
    if await last("zzqx.org", ctx(true))?.inlineCompletion != nil { never.append("typed URL row") }
    if await last("zzqxv", ctx(true))?.inlineCompletion != nil { never.append("typed search row") }
    // Length cap: a field text of exactly `maxFieldLength` UTF-16 units completes; one more does not.
    let cap = InlineCompletion.maxFieldLength
    let atCap = URL(string: "https://example.com/" + String(repeating: "a", count: cap - "example.com/".count))!
    let overCap = URL(string: "https://example.com/" + String(repeating: "a", count: cap - "example.com/".count + 1))!
    let atCapText = InlineCompletion.text(typed: "example.com/a", url: atCap)
    if atCapText?.fieldText.utf16.count != cap { never.append("at cap refused (\(atCapText?.fieldText.utf16.count ?? 0))") }
    if InlineCompletion.text(typed: "example.com/a", url: overCap) != nil { never.append("over cap \(cap + 1) completed") }
    log.check("38: no completion for arithmetic, whitespace, scopes, search tabs, non-web URLs, typed URL or search rows; field text ≤ 2,048 (at the cap yes, one over no)", never.isEmpty, never.isEmpty ? "none completed; \(cap) accepted, \(cap + 1) refused" : "completed: \(never)")
    // 39. The current tab: offered in Cmd+T, absent in Cmd+L.
    let s39 = await last("Today News", ctx(false)), s39edit = await last("Today News", ctx(false, mode: .editCurrentURL))
    let emptyRows = await last("", ctx(false))
    log.check("39: current tab offered in new-tab mode (also for an empty query), absent in edit mode",
              s39?.suggestions.contains { $0.tabID == current.id } == true && s39edit?.suggestions.contains { $0.tabID == current.id } == false
                && emptyRows?.suggestions.contains { $0.tabID == current.id } == true,
              "new tab \(s39?.suggestions.contains { $0.tabID == current.id } ?? false), edit \(s39edit?.suggestions.contains { $0.tabID == current.id } ?? true)")
    // 40. History carry-over: "gi" answered, then "git": snapshot 0 already holds GitHub and completes it.
    _ = await last("gi", ctx(true))
    var first40: SuggestionSnapshot?
    for await s in engine.query("git", context: ctx(true)) { first40 = s; break }
    log.check("40: \"gi\" → \"git\": snapshot 0 carries the history row over and already completes \"github.com\"",
              first40?.sequence == 0 && first40?.suggestions.contains { $0.kind == .history && $0.url?.host() == "github.com" } == true
                && first40?.inlineCompletion?.fieldText == "github.com",
              "snapshot \(first40?.sequence ?? -1): \(show(first40))")
}
