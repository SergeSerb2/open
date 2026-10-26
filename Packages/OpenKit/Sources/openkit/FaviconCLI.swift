import Foundation
import ImageIO
import OpenModel
import OpenStore
import UniformTypeIdentifiers

private let faviconUsage = """
usage: openkit favicons fetch --snapshot DIR --db PATH [--limit N]
       openkit favicons get URL --db PATH --out FILE.png [--size 32|64]
       openkit favicons stats --db PATH
       openkit favicons bench --db PATH
"""

/// All errors from this command are redacted, including Foundation/SQLite errors.
func runFavicons(args: [String]) async throws {
    do {
        try await faviconCommand(args)
    } catch {
        FileHandle.standardError.write(Data("favicons: command failed (details redacted)\n".utf8))
        exit(1)
    }
}

private func faviconCommand(_ args: [String]) async throws {
    guard let command = args.first, ["fetch", "get", "stats", "bench"].contains(command) else { faviconUsageExit() }
    var options: [String: String] = [:], positional: [String] = [], index = 1
    let allowed: Set<String>
    switch command {
    case "fetch": allowed = ["--snapshot", "--db", "--limit"]
    case "get": allowed = ["--db", "--out", "--size"]
    default: allowed = ["--db"]
    }
    while index < args.count {
        let argument = args[index]
        if argument.hasPrefix("--") {
            guard allowed.contains(argument), options[argument] == nil, index + 1 < args.count,
                  !args[index + 1].hasPrefix("--") else { faviconUsageExit() }
            options[argument] = args[index + 1]
            index += 2
        } else {
            positional.append(argument)
            index += 1
        }
    }
    guard let dbPath = options["--db"], positional.count == (command == "get" ? 1 : 0) else { faviconUsageExit() }
    let store = try FaviconStore(databaseURL: URL(fileURLWithPath: dbPath))
    switch command {
    case "fetch":
        guard let snapshotPath = options["--snapshot"] else { faviconUsageExit() }
        var limit: Int?
        if let value = options["--limit"] {
            guard let parsed = Int(value), parsed >= 0 else { faviconUsageExit() }
            limit = parsed
        }
        let urls = try await MainActor.run {
            guard let model = try SnapshotStore(root: URL(fileURLWithPath: snapshotPath)).load() else {
                throw FaviconStoreError.invalidURL
            }
            return faviconURLs(model, limit: limit)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let report = await FaviconFetcher(store: store, session: session).prefetch(urls)
        print(String(format: "requested=%d alreadyCached=%d fetched=%d missing=%d failed=%d durationMs=%.3f",
                     report.requested, report.alreadyCached, report.fetched, report.missing, report.failed, report.durationMs))
        for result in report.origins {
            print(String(format: "origin-%d  %@  %.3f ms", result.index, result.status.rawValue, result.durationMs))
        }
    case "get":
        guard let page = URL(string: positional[0]), let output = options["--out"],
              ["32", "64"].contains(options["--size"] ?? "32") else { faviconUsageExit() }
        guard let icon = await store.icon(for: page),
              let data = (options["--size"] == "64" ? icon.png64 : icon.png32) else {
            print("absent")
            exit(1)
        }
        try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        print("ok bytes=\(data.count)")
    case "stats":
        let stats = await store.statistics()
        print("ok=\(stats.ok) missing=\(stats.missing) failed=\(stats.failed) count=\(stats.count) totalBytes=\(stats.totalBytes)")
    case "bench":
        try await faviconBench(store)
    default: faviconUsageExit()
    }
}

@MainActor
private func faviconURLs(_ model: BrowserModel, limit: Int?) -> [URL] {
    var urls: [URL] = []
    func tab(_ tab: Tab) {
        urls.append(tab.url)
        if let pinned = tab.pinnedURL { urls.append(pinned) }
    }
    func walkNodes(_ nodes: [SidebarNode]) {
        for node in nodes {
            switch node {
            case .tab(let value): tab(value)
            case .folder(let folder): walkNodes(folder.children)
            case .split(let split): for pane in split.panes { tab(pane) }
            }
        }
    }
    for profile in model.profiles { for favorite in profile.favorites { tab(favorite) } }
    for space in model.spaces { walkNodes(space.pinned); walkNodes(space.today) }
    // Limit origins, not tabs: duplicates must not consume the requested limit.
    var seen = Set<String>(), result: [URL] = []
    for url in urls {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = parts.host else { continue }
        parts.scheme = scheme; parts.host = host.lowercased(); parts.user = nil; parts.password = nil
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) { parts.port = nil }
        parts.path = ""; parts.query = nil; parts.fragment = nil
        guard let origin = parts.string, seen.insert(origin).inserted else { continue }
        if let limit, result.count >= limit { break }
        result.append(url)
    }
    return result
}

/// Real actor/SQLite/image pipeline benchmark. Writes only synthetic .invalid URLs.
private func faviconBench(_ store: FaviconStore) async throws {
    let prefix = "https://favicon-bench-\(UUID().uuidString.lowercased()).invalid/"
    let urls = (0..<1000).map { URL(string: prefix + String($0))! }
    let ingestStart = ContinuousClock.now
    for (index, url) in urls.enumerated() {
        let data = try syntheticFavicon(index)
        try await store.ingest(imageData: data, iconURL: nil, for: url, pageSpecific: true)
    }
    let ingestMs = faviconMilliseconds(ingestStart)
    // Prime the statements and filesystem pages before collecting 10k lookups.
    for url in urls { guard await store.icon(for: url) != nil else { throw FaviconStoreError.database } }
    var samples: [Double] = []
    for _ in 0..<10 {
        for url in urls {
            let start = ContinuousClock.now
            guard let image = await store.icon(for: url), !image.png32.isEmpty, image.png64 != nil else { throw FaviconStoreError.database }
            samples.append(faviconMilliseconds(start))
        }
    }
    samples.sort()
    print(String(format: "ingested=1000 lookups=%d ingestMs=%.3f p50Ms=%.6f p95Ms=%.6f count=%d",
                 samples.count, ingestMs, samples[samples.count / 2], samples[samples.count * 95 / 100], await store.count()))
}

private func syntheticFavicon(_ seed: Int) throws -> Data {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FaviconStoreError.invalidImage }
    context.setFillColor(CGColor(red: CGFloat(seed % 251) / 250, green: 0.4, blue: 0.8, alpha: 0.75))
    context.fill(CGRect(x: 8, y: 8, width: 48, height: 48))
    guard let image = context.makeImage() else { throw FaviconStoreError.invalidImage }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw FaviconStoreError.invalidImage }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw FaviconStoreError.invalidImage }
    return data as Data
}

private func faviconMilliseconds(_ start: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: .now).components
    return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
}

private func faviconUsageExit() -> Never {
    FileHandle.standardError.write(Data((faviconUsage + "\n").utf8))
    exit(2)
}
