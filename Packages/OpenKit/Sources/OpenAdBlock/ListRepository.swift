import Foundation

public struct AdBlockListReceipt: Codable, Sendable, Equatable {
    public var sha256: String
    public var bytes: Int
    public var sources: [AdBlockSourceReceipt]
    public var lastCheck: Date
}

public struct AdBlockSourceReceipt: Codable, Sendable, Equatable {
    public var etag: String?
    public var lastModified: String?
    public var sha256: String
    public var bytes: Int
}

public struct AdBlockProfileState: Codable, Sendable, Equatable {
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

    private var storage: GenerationStorage { GenerationStorage(maximumBytes: max(64 * 1024 * 1024, policy.maximumListBytes), ephemeral: ephemeral) }

    /// Build the new layout beside its destination, then publish with one same-volume rename.
    /// Until publication succeeds the old folder is read-only, so a failed copy loses no data.
    func migrate(from old: URL, to directory: URL) throws {
        let files = FileManager.default
        try Task.checkCancellation()
        guard files.fileExists(atPath: old.path) else { return }
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".adblock-migration-\(UUID().uuidString)")
        defer { try? files.removeItem(at: staging) }
        do {
            let values = try old.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return }
            // ProfileDirectories may already have made an empty AdBlock/lists directory.
            let entries = files.fileExists(atPath: directory.path) ? try files.contentsOfDirectory(atPath: directory.path) : []
            guard entries.allSatisfy({ $0 == "lists" }) else { return }
            let existingLists = directory.appendingPathComponent("lists")
            if files.fileExists(atPath: existingLists.path),
               !(try files.contentsOfDirectory(atPath: existingLists.path)).isEmpty { return }
            try Task.checkCancellation()
            try files.createDirectory(at: staging.appendingPathComponent("lists"), withIntermediateDirectories: true)
            for name in try files.contentsOfDirectory(atPath: old.path) {
                try Task.checkCancellation()
                let parent = ["exclusions.json", "catalog-state.json"].contains(name) ? staging : staging.appendingPathComponent("lists")
                try files.copyItem(at: old.appendingPathComponent(name), to: parent.appendingPathComponent(name))
            }
            try Task.checkCancellation()
            // Removing only empty directories preserves the no-state condition checked above.
            let lists = directory.appendingPathComponent("lists")
            if files.fileExists(atPath: lists.path) { try files.removeItem(at: lists) }
            if files.fileExists(atPath: directory.path) { try files.removeItem(at: directory) }
            try Task.checkCancellation()
            try files.moveItem(at: staging, to: directory)
        } catch {
            try Task.checkCancellation()
            // Opening the untouched destination now seeds bundled defaults instead.
            return
        }
        // The transaction has committed. Cleanup cannot invalidate the new complete copy.
        try Task.checkCancellation()
        try? files.removeItem(at: old)
        let parent = old.deletingLastPathComponent()
        if (try? files.contentsOfDirectory(atPath: parent.path).isEmpty) == true { try? files.removeItem(at: parent) }
    }

    func open(directory: URL, catalog: AdBlockCatalog) async throws -> AdBlockProfileState {
        // Migrate settings only from the former layout. Legacy list directories are never inputs.
        try Task.checkCancellation()
        let legacy = directory.deletingLastPathComponent()
        let empty = AdBlockProfileState(catalogVersion: catalog.version, enabledBlockLists: catalog.defaultIDs)
        var state = empty
        var report: String?
        let settings = legacy.appendingPathComponent("catalog-state.json")
        do {
            if FileManager.default.fileExists(atPath: settings.path) {
                state = try readJSON(AdBlockProfileState.self, at: settings, fallback: empty)
            }
        } catch { report = "catalog-state invalid; reconciled from committed generation or defaults" }
        let pointer: CurrentGeneration?
        do { pointer = try storage.current(in: directory) }
        catch { pointer = nil; report = "current.json invalid; reseeded/refetched enabled lists" }
        if let pointer {
            var verified: AdBlockProfileState?
            do { verified = try storage.verify(pointer.live, directory: directory, catalog: catalog).state }
            catch {
                let reason = (error as? AdBlockError)?.description ?? "invalid generation manifest"
                try storage.quarantine(pointer.live, directory: directory)
                report = "generation \(pointer.live.generation) quarantined: \(reason)"
            }
            if var restored = verified {
                restored.lastError = report ?? state.lastError
                if restored != state { try save(restored, directory: directory) }
                storage.cleanup(keeping: [pointer.live.generation, pointer.previous?.generation].compactMap { $0 }, directory: directory)
                return restored
            }
            if let previous = pointer.previous {
                do { verified = try storage.verify(previous, directory: directory, catalog: catalog).state }
                catch {
                    try storage.quarantine(previous, directory: directory)
                    report! += "; previous generation invalid"
                }
                if var restored = verified {
                    restored.lastError = "\(report!); fell back to generation \(previous.generation)"
                    try save(restored, directory: directory)
                    try storage.activate(previous, previous: nil, directory: directory)
                    return restored
                }
            }
            // Never derive new inputs from a rejected generation's receipts.
            state = AdBlockProfileState(catalogVersion: catalog.version, enabledBlockLists: catalog.defaultIDs)
        }
        guard state.catalogVersion == catalog.version else { throw AdBlockError("unsupported catalog-state version") }
        state.enabledBlockLists = catalog.lists.filter {
            state.enabledBlockLists.contains($0.id) && !$0.urls.isEmpty
        }.map(\.id)
        state.lists = [:]
        state.lastError = report.map { $0 + "; reseeded/refetched enabled lists" }
        let staging = try makeStaging(directory)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            for id in state.enabledBlockLists {
                let list = try catalog.list(id)
                if list.bundled, let bundle {
                    let data = try verifiedSeed(id: id, bundle: bundle)
                    try atomicWrite(data, to: staging.appendingPathComponent("lists/\(id).txt"))
                    state.lists[id] = AdBlockListReceipt(sha256: digest(data), bytes: data.count, sources: [], lastCheck: .distantPast)
                } else {
                    state.lists[id] = try await update(list, directory: staging, previous: nil).0
                }
            }
            try publishCaches(staging: staging, directory: directory, state: state)
            _ = try storage.publish(state: state, inputs: staging.appendingPathComponent("lists"), directory: directory, previous: nil)
        } catch {
            throw AdBlockError([report, (error as? AdBlockError)?.description ?? "generation preparation failed"].compactMap { $0 }.joined(separator: "; "))
        }
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
        try storage.save(state, directory: directory)
    }

    private func makeStaging(_ directory: URL) throws -> URL {
        let staging = directory.appendingPathComponent(".update-\(UUID().uuidString)")
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("lists"), withIntermediateDirectories: true)
        return staging
    }

    private func stageCurrent(directory: URL, staging: URL, catalog: AdBlockCatalog) throws -> GenerationReference {
        guard let reference = try storage.current(in: directory)?.live else { throw AdBlockError("no current generation") }
        let manifest = try storage.verify(reference, directory: directory, catalog: catalog)
        for file in manifest.files {
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: storage.path(reference, in: directory).appendingPathComponent(file.file),
                                            to: staging.appendingPathComponent("lists/\(file.file)"))
        }
        for file in manifest.files {
            for index in manifest.state.lists[file.listID]?.sources.indices ?? 0..<0 {
                let relative = "downloads/\(file.listID)/\(index).body"
                if let data = boundedData(directory.appendingPathComponent(relative), maximum: policy.maximumSourceBytes) {
                    try atomicWrite(data, to: staging.appendingPathComponent(relative))
                }
            }
        }
        return reference
    }

    private func publishCaches(staging: URL, directory: URL, state: AdBlockProfileState) throws {
        for id in state.enabledBlockLists {
            for index in state.lists[id]?.sources.indices ?? 0..<0 {
                let relative = "downloads/\(id)/\(index).body"
                guard let data = boundedData(staging.appendingPathComponent(relative), maximum: policy.maximumSourceBytes) else {
                    throw AdBlockError("\(id): missing staged source cache")
                }
                try atomicWrite(data, to: directory.appendingPathComponent(relative))
            }
        }
    }

    /// Every successful update publishes a complete generation, including all-304 checks.
    /// Reload remains unnecessary when the input hashes did not change.
    func updateBatch(catalog: AdBlockCatalog, directory: URL, state: AdBlockProfileState)
        async throws -> (AdBlockProfileState, [AdBlockUpdateResult]) {
        let staging = try makeStaging(directory)
        defer { try? FileManager.default.removeItem(at: staging) }
        let previous = try stageCurrent(directory: directory, staging: staging, catalog: catalog)
        var next = state, results: [AdBlockUpdateResult] = []
        for id in state.enabledBlockLists {
            let list = try catalog.list(id)
            let (receipt, result) = try await update(list, directory: staging, previous: state.lists[id])
            next.lists[id] = receipt; results.append(result)
        }
        try Task.checkCancellation()
        next.lastError = nil
        try publishCaches(staging: staging, directory: directory, state: next)
        _ = try storage.publish(state: next, inputs: staging.appendingPathComponent("lists"), directory: directory, previous: previous)
        return (next, results)
    }

    /// Reset is one generation transaction, so a failed default download keeps all old choices.
    func resetChoices(directory: URL, state: AdBlockProfileState, catalog: AdBlockCatalog) async throws -> AdBlockProfileState {
        let staging = try makeStaging(directory)
        defer { try? FileManager.default.removeItem(at: staging) }
        let previous = try stageCurrent(directory: directory, staging: staging, catalog: catalog)
        var next = state
        for id in catalog.defaultIDs where next.lists[id] == nil {
            next.lists[id] = try await update(catalog.list(id), directory: staging, previous: nil).0
        }
        next.enabledBlockLists = catalog.defaultIDs
        next.lists = next.lists.filter { catalog.defaultIDs.contains($0.key) }
        next.lastError = nil
        try Task.checkCancellation()
        try publishCaches(staging: staging, directory: directory, state: next)
        _ = try storage.publish(state: next, inputs: staging.appendingPathComponent("lists"), directory: directory, previous: previous)
        return next
    }

    func setEnabled(_ id: String, on: Bool, directory: URL, state: AdBlockProfileState, catalog: AdBlockCatalog)
        async throws -> (AdBlockProfileState, [AdBlockUpdateResult]) {
        let staging = try makeStaging(directory)
        defer { try? FileManager.default.removeItem(at: staging) }
        let previous = try stageCurrent(directory: directory, staging: staging, catalog: catalog)
        var next = state, results: [AdBlockUpdateResult] = []
        if on {
            let (receipt, result) = try await update(catalog.list(id), directory: staging, previous: nil)
            next.lists[id] = receipt; results = [result]
            next.enabledBlockLists.append(id)
        } else {
            next.enabledBlockLists.removeAll { $0 == id }
            next.lists.removeValue(forKey: id)
        }
        next.lastError = nil
        try Task.checkCancellation()
        try publishCaches(staging: staging, directory: directory, state: next)
        _ = try storage.publish(state: next, inputs: staging.appendingPathComponent("lists"), directory: directory, previous: previous)
        return (next, results)
    }

    /// A failed source cannot replace a list: fetch and validate every component before publishing.
    func update(_ list: BlockList, directory: URL, previous: AdBlockListReceipt?) async throws -> (AdBlockListReceipt, AdBlockUpdateResult) {
        let start = Date()
        let target = directory.appendingPathComponent("lists/\(list.id).txt")
        let existing = boundedData(target, maximum: policy.maximumListBytes)
        let intact = existing.map { $0.count == previous?.bytes && digest($0) == previous?.sha256 } ?? false
        let repaired = existing != nil && !intact
        var combined = Data(), receipts: [AdBlockSourceReceipt] = [], bodies: [Data] = []
        var statuses: [Int] = [], attempts = 0, downloaded = 0
        for (index, url) in list.urls.enumerated() {
            let cache = directory.appendingPathComponent("downloads/\(list.id)/\(index).body")
            let old = previous?.sources.indices.contains(index) == true ? previous?.sources[index] : nil
            let cached = intact ? boundedData(cache, maximum: policy.maximumSourceBytes) : nil
            let validCache = cached.map { $0.count == old?.bytes && digest($0) == old?.sha256 } ?? false
            let response: DownloadResponse
            let count: Int
            do {
                (response, count) = try await downloader.fetch(url: url, etag: validCache ? old?.etag : nil,
                    modified: validCache ? old?.lastModified : nil, redirectHosts: list.redirectHosts ?? [])
            } catch let error as AdBlockError { throw AdBlockError("\(list.id): \(error.description)") }
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
            let (response, attempts) = try await downloader.fetch(url: list.urls[0], etag: nil, modified: nil, redirectHosts: list.redirectHosts ?? [])
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

}
