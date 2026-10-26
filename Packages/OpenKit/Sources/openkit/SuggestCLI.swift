import Foundation
import OpenModel
import OpenStore
import OpenSuggest

/// `openkit suggest` and `openkit suggest-check` entry point.
@MainActor
func runSuggestCommand(_ command: String, args: [String]) async {
    if command == "suggest-check" { await runSuggestCheck(args: args) } else { await runSuggest(args: args) }
}

private let suggestUsage = """
usage: openkit suggest --snapshot DIR [--history DB|DIR] [--offline] [--mode new-tab|edit|tabs]
                       [--current-url URL] [--site SITE_ID] [--engine ID] [--show-titles] [--redact-hosts] "query"
"""

/// `--history` takes a HistoryStore root (holding State/history.sqlite3) or the .sqlite3 file inside it.
func historyStore(at path: String) -> HistoryStore? {
    let url = URL(fileURLWithPath: path)
    if url.pathExtension == "sqlite3" {
        let state = url.deletingLastPathComponent()
        guard url.lastPathComponent == "history.sqlite3", state.lastPathComponent == "State" else { return nil }
        return HistoryStore(root: state.deletingLastPathComponent())
    }
    return HistoryStore(root: url)
}

@MainActor
func runSuggest(args: [String]) async {
    var snapshotDir: String?, historyPath: String?, currentURL: String?, site: String?, engineID: String?
    var offline = false, showTitles = false, redactHosts = false
    var mode = SuggestMode.newTab
    var words: [String] = []
    var i = 0
    func value() -> String {
        i += 1
        guard i < args.count else { FileHandle.standardError.write(Data((suggestUsage + "\n").utf8)); exit(2) }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--snapshot": snapshotDir = value()
        case "--history": historyPath = value()
        case "--offline": offline = true
        case "--show-titles": showTitles = true
        case "--redact-hosts": redactHosts = true
        case "--current-url": currentURL = value()
        case "--site": site = value()
        case "--engine": engineID = value()
        case "--mode":
            switch value() {
            case "new-tab": mode = .newTab
            case "edit": mode = .editCurrentURL
            case "tabs": mode = .searchTabs
            default: FileHandle.standardError.write(Data((suggestUsage + "\n").utf8)); exit(2)
            }
        default: words.append(args[i])
        }
        i += 1
    }
    guard let snapshotDir else { FileHandle.standardError.write(Data((suggestUsage + "\n").utf8)); exit(2) }
    let query = words.joined(separator: " ")

    let model: BrowserModel
    do {
        guard let loaded = try SnapshotStore(root: URL(fileURLWithPath: snapshotDir)).load() else {
            FileHandle.standardError.write(Data("error: no snapshot at \(snapshotDir)/State/browser.json\n".utf8))
            exit(1)
        }
        model = loaded
    } catch {
        FileHandle.standardError.write(Data("error loading snapshot: \(error)\n".utf8))
        exit(1)
    }
    var history: HistoryStore?
    if let historyPath {
        guard let store = historyStore(at: historyPath) else {
            FileHandle.standardError.write(Data("error: --history needs a root DIR or <root>/State/history.sqlite3\n".utf8))
            exit(2)
        }
        history = store
    }

    let window = model.windows.first
    let spaceID = window?.focusedSpaceID ?? model.spaces.first?.id
    let currentTabID = spaceID.flatMap { window?.selectedNodeBySpace[$0] }.flatMap { model.tab(id: $0)?.id }
    let context = SuggestContext(
        mode: mode, profileID: spaceID.flatMap { model.space(id: $0)?.profileID }, spaceID: spaceID,
        currentTabID: currentTabID, currentTabURL: currentURL.flatMap(URL.init(string:)) ?? currentTabID.flatMap { model.tab(id: $0)?.url },
        allowsRemoteSuggestions: !offline, searchEngineID: engineID, siteSearchID: site)
    let engine = SuggestEngine(model: model, history: history)
    engine.prewarm()

    let redactor = Redactor(showTitles: showTitles, redactHosts: redactHosts)
    print("query \(query.debugDescription) mode=\(mode.rawValue) engine=\(engineID ?? SearchEngines.defaultID) remote=\(!offline) history=\(history != nil)")
    print(String(format: "tab index: %d tabs, built in %.2f ms", engine.indexedTabCount, engine.lastIndexBuildMilliseconds))
    var count = 0
    for await snapshot in engine.query(query, context: context) {
        printSnapshot(snapshot, redactor: redactor)
        count += 1
    }
    print("done: \(count) snapshot(s)")
}

// MARK: - Printing

/// Hides personal data: tab and history titles and URL paths unless `--show-titles`; hosts too with
/// `--redact-hosts` (each host becomes host-N, stable within one run).
@MainActor
final class Redactor {
    let showTitles: Bool
    let redactHosts: Bool
    private var hostNames: [String: String] = [:]

    init(showTitles: Bool, redactHosts: Bool) {
        self.showTitles = showTitles
        self.redactHosts = redactHosts
    }

    func host(_ h: String) -> String {
        guard redactHosts, !h.isEmpty else { return h }
        if let n = hostNames[h] { return n }
        let n = "host-\(hostNames.count + 1)"
        hostNames[h] = n
        return n
    }

    func isPersonal(_ s: Suggestion) -> Bool {
        s.kind == .switchToTab || s.kind == .history || (s.kind == .navigate && !s.isWhatYouTyped && s.providers.first != "remote")
    }

    func line(_ s: Suggestion) -> String {
        let target: String
        if let url = s.url {
            let h = TextMatching.displayHost(url)
            target = showTitles ? url.absoluteString : (isPersonal(s) ? (h.isEmpty ? "•••" : host(h) + "/•••") : url.absoluteString)
        } else if let action = s.actionID {
            target = "action:\(action)"
        } else if let site = s.siteSearchID {
            target = "site:\(site)"
        } else {
            target = "-"
        }
        let title = showTitles || !isPersonal(s) ? s.title : "•••"
        var subtitle = showTitles || !isPersonal(s) ? s.subtitle : host(s.subtitle)
        if s.kind == .navigate && s.isWhatYouTyped && !showTitles && s.providers.count > 1 { subtitle = "•••" }
        var extra = ""
        if let space = s.spaceTitle { extra += " space=\(showTitles ? space : "•••")" }
        if let loc = s.tabLocation { extra += " in=\(loc.rawValue)" }
        if s.providers.count > 1 { extra += " merged=\(s.providers.joined(separator: "+"))" }
        let d = s.scoreDetail
        let detail = String(format: "q%.0f×%.2f+f%.1f+b%.1f", d.quality, d.weight, d.frecency, d.boost)
        return "\(title)\(subtitle.isEmpty ? "" : " — \(subtitle)")  → \(target)  [\(detail)]\(extra)"
    }
}

@MainActor
func printSnapshot(_ snap: SuggestionSnapshot, redactor: Redactor) {
    let input: String
    switch snap.input {
    case .empty: input = "empty"
    case .text: input = "text"
    case .url(let url, let reason): input = "url(\(reason.rawValue)) \(redactor.showTitles ? url.absoluteString : TextMatching.displayHost(url))"
    }
    let pending = snap.pendingProviders.isEmpty ? "" : " pending=[\(snap.pendingProviders.joined(separator: ","))]"
    print(String(format: "snapshot %d  %.2f ms  final=%@  input=%@  top=%@%@", snap.sequence, snap.elapsedMilliseconds,
                 snap.isFinal ? "yes" : "no", input, snap.topHitRule.rawValue, pending))
    let timings = snap.timings.map { String(format: "%@%@ %.3f", $0.provider, $0.isAsync ? "(async)" : "", $0.milliseconds) }
    print("  providers ms: " + timings.joined(separator: ", "))
    if snap.suggestions.isEmpty { print("  (no rows)") }
    for (n, s) in snap.suggestions.enumerated() {
        let mark = n == 0 && snap.hasTopHit ? "*" : " "
        print(String(format: "  %2d%@ %-16@ %6.1f  ", n + 1, mark, s.kind.rawValue as NSString, s.score) + redactor.line(s))
    }
}
