import Foundation
import OpenAdBlock
import OpenModel
import OpenStore

@MainActor
func runAdBlock(args: [String]) async throws {
    var positional: [String] = [], options: [String: String] = [:]
    var index = 0
    let valued: Set<String> = ["--dir", "--profile", "--bundled-dir", "--proxy", "--timeout", "--max-bytes", "--seconds"]
    while index < args.count {
        let arg = args[index]
        if valued.contains(arg) {
            index += 1
            guard index < args.count else { throw AdBlockError("missing value for \(arg)") }
            options[arg] = args[index]
        } else if arg == "--incognito" { options[arg] = "true" }
        else if arg.hasPrefix("--") { throw AdBlockError("unknown option \(arg)") }
        else { positional.append(arg) }
        index += 1
    }
    guard let action = positional.first else {
        throw AdBlockError("usage: openkit adblock <catalog|update|reset|bundle|status|allowlist|toggle|list|perf|schedule> [--dir ROOT] [--profile UUID]")
    }
    if action == "catalog" {
        let catalog = try AdBlockCatalog.load()
        print("catalog version=\(catalog.version) lists=\(catalog.lists.count) default_on=\(catalog.defaultIDs.joined(separator: ","))")
        for list in catalog.lists {
            print("\(list.id) | \(list.displayName) | category=\(list.category) default_on=\(list.defaultEnabled) bundled=\(list.bundled) info=\(list.infoURL.absoluteString)")
            for url in list.urls { print("  \(url.absoluteString)") }
            if let reason = list.unavailableReason { print("  unavailable: \(reason)") }
        }
        return
    }
    guard let path = options["--dir"] else { throw AdBlockError("--dir ROOT is required") }
    let root = URL(fileURLWithPath: path, isDirectory: true)
    let profile: ProfileID
    if let value = options["--profile"] {
        guard let uuid = UUID(uuidString: value) else { throw AdBlockError("--profile must be a UUID") }
        profile = ProfileID(rawValue: uuid)
    } else { profile = ProfileID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!) }
    var policy = AdBlockDownloadPolicy()
    if let value = options["--timeout"] {
        guard let seconds = Double(value), seconds > 0, seconds <= 300 else { throw AdBlockError("invalid timeout") }
        policy.requestTimeout = seconds; policy.resourceTimeout = seconds
    }
    if let value = options["--max-bytes"] {
        guard let bytes = Int(value), bytes > 0 else { throw AdBlockError("invalid size limit") }
        policy.maximumSourceBytes = bytes; policy.maximumListBytes = bytes
    }
    let proxy: URL?
    if let value = options["--proxy"] {
        guard let parsed = URL(string: value), parsed.scheme == "http", parsed.host() != nil, parsed.port != nil else {
            throw AdBlockError("proxy must be an HTTP host with a port")
        }
        proxy = parsed
    } else { proxy = nil }
    let bundle = options["--bundled-dir"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    let store = try AdBlockStore(root: root, bundledDefaultsDirectory: bundle,
                                incognito: options["--incognito"] != nil, policy: policy, proxy: proxy)
    var reloads = 0
    store.onEngineEvent = { event in
        if case .reload = event { reloads += 1 }
        if case .configure = event { print("configure_verified=true") }
    }
    if action == "bundle" {
        for result in try await store.prepareBundledDefaults(at: root) { printAdBlockResult(result) }
        return
    }
    store.onScheduledUpdate = { outcome, delay in
        print("scheduled_update=\(outcome) next_delay_seconds=\(Int(delay))")
    }
    try await store.openProfile(profile, directory: ProfileDirectories(root: root).adBlockDirectory(dataDirectoryName: profile.description), scheduleUpdates: action == "schedule")
    defer { try? store.closeProfile(profile) }
    if let warning = store.lastError(for: profile) { print("open_warning=\(warning)") }
    switch action {
    case "schedule":
        guard let raw = options["--seconds"], let seconds = Double(raw), seconds.isFinite, seconds > 0, seconds <= 120 else {
            throw AdBlockError("schedule --seconds <1...120>; debug scale/delay are set via OPEN_ADBLOCK_DEBUG_* environment variables")
        }
        // The real manual update owns the same busy gate as the scheduled update.
        let manual = Task { try await store.updateListsNow(profile: profile) }
        try await Task.sleep(for: .seconds(seconds))
        manual.cancel()
        _ = await manual.result
    case "update":
        do { try await store.updateListsNow(profile: profile) }
        catch {
            for result in store.lastUpdateResults[profile] ?? [] { printAdBlockResult(result) }
            throw error
        }
        for result in store.lastUpdateResults[profile] ?? [] { printAdBlockResult(result) }
        print("reload_events=\(reloads)")
    case "status":
        print(store.debugInfo(profile: profile))
        print("list_directory=\(try store.listDirectory(for: profile).path)")
    case "reset":
        try await store.resetListChoices(profile: profile)
        print("enabled_lists=\(store.enabledListIDs(for: profile).joined(separator: ",")) reload_events=\(reloads)")
    case "toggle":
        guard positional.count == 2, ["on", "off"].contains(positional[1]) else { throw AdBlockError("toggle <on|off>") }
        try store.setEnabled(positional[1] == "on")
        print("global_enabled=\(store.isEnabled)")
    case "list":
        guard positional.count == 3, ["on", "off"].contains(positional[2]) else { throw AdBlockError("list <ID> <on|off>") }
        try await store.setListEnabled(positional[1], positional[2] == "on", profile: profile)
        print("enabled_lists=\(store.enabledListIDs(for: profile).joined(separator: ",")) reload_events=\(reloads)")
    case "allowlist":
        guard positional.count >= 2 else { throw AdBlockError("allowlist <add|remove|list|check> [HOST]") }
        switch positional[1] {
        case "list":
            for domain in store.excludedDomains(for: profile) { print(domain) }
        case "add", "remove":
            guard positional.count == 3 else { throw AdBlockError("allowlist add/remove requires a host") }
            try store.setExcluded(positional[2], excluded: positional[1] == "add", profile: profile)
            print("allowlist=\(store.excludedDomains(for: profile).joined(separator: ","))")
        case "check":
            guard positional.count == 3 else { throw AdBlockError("allowlist check requires a host") }
            let snapshot = store.siteSnapshot(for: profile)
            let input = positional[2]
            let host = input.contains("://") ? URL(string: input)?.host() : input
            guard let host else { throw AdBlockError("invalid URL host") }
            print("allowlisted=\(try snapshot.isAllowlisted(host: host)) should_block=\(try snapshot.shouldBlock(host: host))")
        default: throw AdBlockError("unknown allowlist action")
        }
    case "perf":
        // Real persisted model load + 10,000 lookups through the caller's immutable snapshot.
        // Each measured group includes a fresh on-disk settings load; no seeded-list IO is timed.
        try store.closeProfile(profile)
        // Use a persisted model in an isolated directory; never alter a user's allowlist or copy
        // their browsing data. Each timed group reopens it through the public store interface.
        let benchRoot = FileManager.default.temporaryDirectory.appendingPathComponent("open-adblock-perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: benchRoot) }
        do {
            let seed = try AdBlockStore(root: benchRoot)
            try await seed.openProfile(profile, directory: ProfileDirectories(root: benchRoot).adBlockDirectory(dataDirectoryName: profile.description), scheduleUpdates: false)
            try seed.setEnabled(true)
            try seed.setExcluded("example.com", excluded: true, profile: profile)
            try seed.setExcluded("bücher.de", excluded: true, profile: profile)
            try seed.closeProfile(profile)
        }
        let hosts = (0..<1000).map { index in
            ["news.example.com", "notexample.com", "bücher.de", "example.org"][index % 4]
        }
        var times: [Double] = [], loads: [Double] = [], lookups: [Double] = [], matches = 0
        for _ in 0..<10 {
            let start = DispatchTime.now().uptimeNanoseconds
            let loaded = try AdBlockStore(root: benchRoot)
            try await loaded.openProfile(profile, directory: ProfileDirectories(root: benchRoot).adBlockDirectory(dataDirectoryName: profile.description), scheduleUpdates: false)
            let snapshot = loaded.siteSnapshot(for: profile)
            let loadedAt = DispatchTime.now().uptimeNanoseconds
            for host in hosts { if snapshot.isAllowlisted(normalizedHost: host) { matches += 1 } }
            let end = DispatchTime.now().uptimeNanoseconds
            let duration = Double(end - start) / 1_000_000
            times.append(duration)
            loads.append(Double(loadedAt - start) / 1_000_000)
            lookups.append(Double(end - loadedAt) / 1_000_000)
            try loaded.closeProfile(profile)
        }
        // Two budgets (lead decision 2026-10-25): per-lookup cost is what pages pay; profile open
        // includes the mandatory SHA-256 integrity scan of the live list generation and runs once,
        // off the main thread, so it gets its own, larger budget.
        func p95(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
        }
        let lookupP95 = p95(lookups), loadP95 = p95(loads), totalP95 = p95(times)
        print(String(format: "lookups_1000 p95_ms=%.4f budget_ms=1 groups=10 lookups=10000 matches=%d", lookupP95, matches))
        print(String(format: "profile_open_with_integrity_scan p95_ms=%.4f budget_ms=10", loadP95))
        print(String(format: "combined p95_ms=%.4f (informational)", totalP95))
        print("groups_ms=\(times.map { String(format: "%.4f", $0) }.joined(separator: ","))")
        guard lookupP95 < 1, loadP95 < 10, matches == 5000 else { throw AdBlockError("performance budget or match check failed") }
    default: throw AdBlockError("unknown adblock action")
    }
}

func printAdBlockResult(_ result: AdBlockUpdateResult) {
    let status = result.statuses.isEmpty ? "pinned-local" : result.statuses.map(String.init).joined(separator: ",")
    let integrity = result.repaired ? "failed-local-integrity;refetched" : "verified"
    print(String(format: "%@ status=%@ changed=%@ integrity=%@ bytes=%d downloaded_bytes=%d sha256=%@ etag=%@ duration_ms=%.2f attempts=%d",
        result.id, status, String(result.changed), integrity, result.bytes, result.downloadedBytes, result.sha256,
        result.etags.joined(separator: ","), result.duration * 1000, result.attempts))
    if let url = result.seedURL { print("\(result.id) seed_url=\(url.absoluteString)") }
}
