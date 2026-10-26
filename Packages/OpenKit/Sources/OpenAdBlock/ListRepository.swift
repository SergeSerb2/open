import Foundation

public struct AdBlockListReceipt: Codable, Sendable {
    public var sha256: String
    public var bytes: Int
    public var sources: [AdBlockSourceReceipt]
    public var lastCheck: Date
}

public struct AdBlockSourceReceipt: Codable, Sendable {
    public var etag: String?
    public var lastModified: String?
    public var sha256: String
    public var bytes: Int
}

public struct AdBlockProfileState: Codable, Sendable {
    public var catalogVersion: Int
    public var enabledBlockLists: [String]
    public var lists: [String: AdBlockListReceipt] = [:]
    public var lastError: String?
}

public struct AdBlockUpdateResult: Sendable {
    public let id: String
    public let changed: Bool
    public let repaired: Bool
    public let bytes: Int
    public let downloadedBytes: Int
    public let sha256: String
    public let etags: [String]
    public let statuses: [Int]
    public let attempts: Int
    public let duration: TimeInterval
}

/// Owns list IO off the main actor. The store serializes operations for each Profile.
actor ListRepository {
    let policy: AdBlockDownloadPolicy
    let downloader: ListDownloader
    let pins: [String: String]
    let bundle: URL?
    let ephemeral: Bool

    init(policy: AdBlockDownloadPolicy, proxy: URL?, bundle: URL?, ephemeral: Bool) throws {
        try policy.validate()
        self.policy = policy; self.downloader = ListDownloader(policy: policy, proxy: proxy)
        self.pins = try AdBlockCatalog.bundledPins(); self.bundle = bundle; self.ephemeral = ephemeral
    }

    /// Small settings documents can load without an executor hop. Seeding and all large list IO
    /// remain actor-isolated; a warm Profile open never rehashes or copies its lists.
    nonisolated func readState(directory: URL, catalog: AdBlockCatalog) throws -> AdBlockProfileState {
        var state = try readJSON(AdBlockProfileState.self, at: directory.appendingPathComponent("catalog-state.json"),
            fallback: AdBlockProfileState(catalogVersion: catalog.version, enabledBlockLists: catalog.defaultIDs))
        guard state.catalogVersion == catalog.version else { throw AdBlockError("unsupported catalog-state version") }
        // Imported/future unknown IDs do not become file paths.
        let knownIDs = catalog.lists.filter { state.enabledBlockLists.contains($0.id) && !$0.urls.isEmpty }.map(\.id)
        state.enabledBlockLists = knownIDs
        return state
    }

    nonisolated func needsPreparation(directory: URL, state: AdBlockProfileState, catalog: AdBlockCatalog) -> Bool {
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("catalog-state.json").path) { return true }
        return bundle != nil && catalog.lists.contains { list in
            list.bundled && state.enabledBlockLists.contains(list.id) &&
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent("lists/\(list.id).txt").path)
        }
    }

    func prepare(directory: URL, state: AdBlockProfileState, catalog: AdBlockCatalog) throws -> AdBlockProfileState {
        var state = state
        if let bundle {
            for list in catalog.lists where list.bundled && state.enabledBlockLists.contains(list.id) {
                let destination = directory.appendingPathComponent("lists/\(list.id).txt")
                guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
                let data = try verifiedSeed(id: list.id, bundle: bundle)
                try atomicWrite(data, to: destination)
                state.lists[list.id] = AdBlockListReceipt(sha256: digest(data), bytes: data.count, sources: [], lastCheck: .distantPast)
            }
        }
        try save(state, directory: directory)
        return state
    }

    private func verifiedSeed(id: String, bundle: URL) throws -> Data {
        let filename = id.lowercased() + ".txt"
        let url = bundle.appendingPathComponent(filename)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= policy.maximumSourceBytes else { throw AdBlockError("\(id): bundled size limit exceeded") }
        let data = try Data(contentsOf: url)
        try checkedList(data, id: id, limit: policy.maximumSourceBytes)
        guard digest(data) == pins[filename] else { throw AdBlockError("\(id): bundled SHA-256 pin mismatch; run adblock bundle to repair") }
        return data
    }

    func save(_ state: AdBlockProfileState, directory: URL) throws {
        guard !ephemeral else { return }
        try writeJSON(state, to: directory.appendingPathComponent("catalog-state.json"))
    }

    /// Network/validation failures discard the whole batch. The live engine inputs do not change
    /// until all enabled lists succeed. engine.dat and resources.txt are never copied or written.
    func updateBatch(catalog: AdBlockCatalog, directory: URL, state: AdBlockProfileState)
        async throws -> (AdBlockProfileState, [AdBlockUpdateResult]) {
        let staging = directory.appendingPathComponent(".update-\(UUID().uuidString)")
        let files = FileManager.default
        try files.createDirectory(at: staging.appendingPathComponent("lists"), withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        let enabled = catalog.lists.filter { state.enabledBlockLists.contains($0.id) }
        for list in enabled {
            for relative in ["lists/\(list.id).txt", "downloads/\(list.id)"] {
                let source = directory.appendingPathComponent(relative)
                if files.fileExists(atPath: source.path) {
                    let destination = staging.appendingPathComponent(relative)
                    try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try files.copyItem(at: source, to: destination)
                }
            }
        }
        var next = state, results: [AdBlockUpdateResult] = []
        for list in enabled {
            do {
                let (receipt, result) = try await update(list, directory: staging, previous: state.lists[list.id])
                next.lists[list.id] = receipt; results.append(result)
            } catch {
                let detail = (error as? AdBlockError)?.description ?? "file operation failed"
                throw AdBlockError("\(list.id): \(detail)")
            }
        }
        try Task.checkCancellation()
        next.lastError = nil
        // Cache publication can never invalidate a live list: every cache is receipt-hash checked.
        for list in enabled {
            for index in list.urls.indices {
                let relative = "downloads/\(list.id)/\(index).body"
                try atomicWrite(Data(contentsOf: staging.appendingPathComponent(relative)),
                                to: directory.appendingPathComponent(relative))
            }
        }
        var originals: [(URL, Data?)] = []
        do {
            for result in results where result.changed {
                let relative = "lists/\(result.id).txt"
                let target = directory.appendingPathComponent(relative)
                let old = boundedData(target, maximum: policy.maximumListBytes)
                originals.append((target, old))
                try atomicWrite(Data(contentsOf: staging.appendingPathComponent(relative)), to: target)
            }
            try save(next, directory: directory)
        } catch {
            for (target, old) in originals.reversed() {
                if let old { try atomicWrite(old, to: target) }
                else if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
            }
            throw AdBlockError("list batch: atomic publication failed")
        }
        return (next, results)
    }

    func setEnabled(_ id: String, on: Bool, directory: URL, state: AdBlockProfileState) throws -> AdBlockProfileState {
        var next = state
        let file = directory.appendingPathComponent("lists/\(id).txt")
        let removed = !on ? boundedData(file, maximum: policy.maximumListBytes) : nil
        if on {
            if !next.enabledBlockLists.contains(id) { next.enabledBlockLists.append(id) }
        } else {
            next.enabledBlockLists.removeAll { $0 == id }
            // Engine enumerates *.txt, so disabled lists MUST leave that directory.
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            next.lists.removeValue(forKey: id)
        }
        do { try save(next, directory: directory) }
        catch {
            if let removed { try atomicWrite(removed, to: file) }
            else if on && FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            throw AdBlockError("\(id): settings publication failed")
        }
        return next
    }

    /// A failed source cannot replace a list: fetch and validate every component before publishing.
    func update(_ list: BlockList, directory: URL, previous: AdBlockListReceipt?) async throws -> (AdBlockListReceipt, AdBlockUpdateResult) {
        let start = Date()
        let target = directory.appendingPathComponent("lists/\(list.id).txt")
        let existing = boundedData(target, maximum: policy.maximumListBytes)
        let intact = existing.map { digest($0) == previous?.sha256 } ?? false
        let repaired = existing != nil && !intact
        var combined = Data(), receipts: [AdBlockSourceReceipt] = [], bodies: [Data] = []
        var statuses: [Int] = [], attempts = 0, downloaded = 0
        for (index, url) in list.urls.enumerated() {
            let cache = directory.appendingPathComponent("downloads/\(list.id)/\(index).body")
            let old = previous?.sources.indices.contains(index) == true ? previous?.sources[index] : nil
            let cached = intact ? boundedData(cache, maximum: policy.maximumSourceBytes) : nil
            let validCache = cached.map { digest($0) == old?.sha256 } ?? false
            let (response, count) = try await downloader.fetch(url: url, etag: validCache ? old?.etag : nil,
                                                             modified: validCache ? old?.lastModified : nil)
            attempts += count; statuses.append(response.status)
            let body: Data
            let receipt: AdBlockSourceReceipt
            if response.status == 304 {
                guard validCache, let cached, let old else { throw AdBlockError("\(list.id): 304 without a verified local source") }
                body = cached; receipt = old
            } else {
                body = response.data; downloaded += body.count
                try checkedList(body, id: list.id, limit: policy.maximumSourceBytes)
                receipt = AdBlockSourceReceipt(etag: response.etag, lastModified: response.modified,
                                               sha256: digest(body), bytes: body.count)
            }
            let separator = index == 0 ? 0 : 1
            guard body.count + separator <= policy.maximumListBytes - combined.count else {
                throw AdBlockError("\(list.id): combined size limit exceeded")
            }
            if separator == 1 { combined.append(10) }
            combined.append(body); bodies.append(body); receipts.append(receipt)
        }
        try Task.checkCancellation()
        let hash = digest(combined)
        let changed = !intact || hash != previous?.sha256
        // Cache and list use independent atomic writes. A crash can lose conditional-GET caching,
        // but receipts always hash-check both cache and final file before reuse.
        for (index, body) in bodies.enumerated() where statuses[index] != 304 {
            try atomicWrite(body, to: directory.appendingPathComponent("downloads/\(list.id)/\(index).body"))
        }
        if changed { try atomicWrite(combined, to: target) }
        let receipt = AdBlockListReceipt(sha256: hash, bytes: combined.count, sources: receipts, lastCheck: Date())
        return (receipt, AdBlockUpdateResult(id: list.id, changed: changed, repaired: repaired, bytes: combined.count,
            downloadedBytes: downloaded, sha256: hash, etags: receipts.map { $0.etag ?? "-" }, statuses: statuses,
            attempts: attempts, duration: Date().timeIntervalSince(start)))
    }

    func repairBundle(catalog: AdBlockCatalog, destination: URL) async throws -> [AdBlockUpdateResult] {
        var results: [AdBlockUpdateResult] = []
        for list in catalog.lists where list.bundled {
            let start = Date()
            var repaired = false
            if FileManager.default.fileExists(atPath: destination.appendingPathComponent(list.id.lowercased() + ".txt").path) {
                do {
                    let data = try verifiedSeed(id: list.id, bundle: destination)
                    results.append(AdBlockUpdateResult(id: list.id, changed: false, repaired: false, bytes: data.count,
                        downloadedBytes: 0, sha256: digest(data), etags: [], statuses: [], attempts: 0, duration: Date().timeIntervalSince(start)))
                    continue
                } catch { repaired = true }
            }
            let (response, attempts) = try await downloader.fetch(url: list.urls[0], etag: nil, modified: nil)
            try checkedList(response.data, id: list.id, limit: policy.maximumSourceBytes)
            let hash = digest(response.data)
            guard hash == pins[list.id.lowercased() + ".txt"] else { throw AdBlockError("\(list.id): downloaded bundle SHA-256 pin mismatch") }
            try atomicWrite(response.data, to: destination.appendingPathComponent(list.id.lowercased() + ".txt"))
            results.append(AdBlockUpdateResult(id: list.id, changed: true, repaired: repaired, bytes: response.data.count,
                downloadedBytes: response.data.count, sha256: hash, etags: [response.etag ?? "-"], statuses: [response.status],
                attempts: attempts, duration: Date().timeIntervalSince(start)))
        }
        return results
    }

    private func boundedData(_ url: URL, maximum: Int) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximum else { return nil }
        return try? Data(contentsOf: url)
    }
}
