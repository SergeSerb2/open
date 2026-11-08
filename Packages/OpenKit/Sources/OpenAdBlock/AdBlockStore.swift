import Foundation
import OpenModel
import Darwin

/// Values only. OpenEngine binds these events to its own controller; no engine type enters Swift.
public enum AdBlockEngineEvent: Sendable {
    case configure(profile: ProfileID, listDirectory: URL, enabled: Bool, excludedDomains: [String])
    case enabled(Bool)
    case exclusions(profile: ProfileID, domains: [String])
    case reload(profile: ProfileID, listDirectory: URL)
    case closed(profile: ProfileID)
}

private struct GlobalSettings: Codable {
    var nativeAdBlockEnabled = true
}

private final class DirectoryLease {
    let descriptor: Int32
    init(root: URL) throws {
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let opened = Darwin.open(root.appendingPathComponent(".adblock-lock").path, O_CREAT | O_RDWR, 0o600)
        guard opened >= 0 else { throw AdBlockError("cannot open settings lock") }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(opened)
            throw AdBlockError("adblock directory is already open by another process")
        }
        descriptor = opened
    }
    deinit { Darwin.close(descriptor) }
}

private final class TemporaryRoot {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("open-adblock-private-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Main-actor configuration store for a browser session. Files and downloads are handled by an IO
/// actor. Call openProfile before creating its engine context, then bind onEngineEvent to OpenEngine.
/// Mutations throw so the UI cannot claim a change that failed to persist.
@MainActor
public final class AdBlockStore {
    public static let didChange = Notification.Name("OpenAdBlockStoreDidChange")
    public let root: URL
    public let catalog: AdBlockCatalog
    public var onScheduledUpdate: (@MainActor (_ outcome: String, _ nextDelay: TimeInterval) -> Void)?
    public var onEngineEvent: (@MainActor (AdBlockEngineEvent) -> Void)?
    public private(set) var isEnabled: Bool
    public private(set) var lastUpdateResults: [ProfileID: [AdBlockUpdateResult]] = [:]
    private var states: [ProfileID: AdBlockProfileState] = [:]
    private var exclusions: [ProfileID: Set<String>] = [:]
    private var busy = Set<ProfileID>()
    private var directories: [ProfileID: URL] = [:]
    private var retired = Set<ProfileID>()
    private var operations: [ProfileID: Task<Void, any Error>] = [:]
    private var retirements: [ProfileID: Task<Void, Never>] = [:]
    private var schedules: [ProfileID: Task<Void, Never>] = [:]
    private let repository: ListRepository
    private let lease: DirectoryLease
    private let temporaryRoot: TemporaryRoot?

    deinit { for task in schedules.values { task.cancel() } }

    /// root is the Open application-data directory, NOT a list directory. Incognito substitutes a
    /// unique temporary root, never reads persisted settings, and removes it at close/session end.
    /// Supply the app's Resources/AdBlock directory for offline first-run default seeding.
    public init(root: URL, bundledDefaultsDirectory: URL? = nil, incognito: Bool = false,
                policy: AdBlockDownloadPolicy = .init(), proxy: URL? = nil) throws {
        guard !incognito || bundledDefaultsDirectory != nil else {
            throw AdBlockError("incognito requires bundled defaults for offline seeding")
        }
        let temporary = incognito ? try TemporaryRoot() : nil
        self.temporaryRoot = temporary
        self.root = temporary?.url ?? root
        self.lease = try DirectoryLease(root: self.root)
        self.catalog = try AdBlockCatalog.load()
        self.repository = try ListRepository(policy: policy, proxy: proxy, bundle: bundledDefaultsDirectory, ephemeral: incognito)
        self.isEnabled = try readJSON(GlobalSettings.self, at: self.root.appendingPathComponent("adblock-settings.json"),
                                     fallback: GlobalSettings()).nativeAdBlockEnabled
        _ = AdBlockSites.shared // Load the PSL once, outside navigation lookup timing.
    }

    public func directory(for profile: ProfileID) throws -> URL {
        try checkActive(profile)
        guard let directory = directories[profile] else { throw AdBlockError("profile is not open") }
        return directory
    }

    public func listDirectory(for profile: ProfileID) throws -> URL {
        try directory(for: profile).appendingPathComponent("lists", isDirectory: true)
    }

    public func isRetired(_ profile: ProfileID) -> Bool { retired.contains(profile) }
    public func isProfileOpen(_ profile: ProfileID) -> Bool { states[profile] != nil && !retired.contains(profile) }
    public func isUpdating(_ profile: ProfileID) -> Bool { busy.contains(profile) }

    /// The caller supplies ProfileDirectories.adBlockDirectory, including its dataDirectoryName.
    /// Private sessions substitute their own temporary directory and never read the supplied path.
    public func openProfile(_ profile: ProfileID, directory requested: URL, scheduleUpdates: Bool = true) async throws {
        try checkActive(profile)
        if states[profile] != nil { return }
        // Settings and after-paint startup can open the same Profile together.
        // With no state yet, its only possible operation is the initial open.
        if let opening = operations[profile] {
            try await opening.value
            try checkActive(profile)
            return
        }
        let directory = temporaryRoot.map { $0.url.appendingPathComponent(profile.description).appendingPathComponent("AdBlock") } ?? requested
        let lists = directory.appendingPathComponent("lists", isDirectory: true)
        try await perform(profile) {
            if self.temporaryRoot == nil {
                try await self.repository.migrate(from: self.root.appendingPathComponent("Profiles/\(profile.rawValue.uuidString)/adblock"), to: directory)
            }
            let state = try await self.repository.open(directory: lists, catalog: self.catalog)
            try self.checkActive(profile)
            // Preserve the legacy AdBlock/exclusions.json read, including an exclusions-only Profile.
            let domains = try readJSON([String].self, at: directory.appendingPathComponent("exclusions.json"), fallback: [])
            let normalized = try Set(domains.map { try AdBlockSites.shared.registrableDomain($0) })
            self.directories[profile] = directory
            self.states[profile] = state; self.exclusions[profile] = normalized
            self.onEngineEvent?(.configure(profile: profile, listDirectory: lists,
                                          enabled: self.isEnabled, excludedDomains: normalized.sorted()))
        }
        try checkActive(profile)
        NotificationCenter.default.post(name: Self.didChange, object: self)
        if scheduleUpdates {
            let scale = Double(ProcessInfo.processInfo.environment["OPEN_ADBLOCK_DEBUG_SCHEDULE_SCALE"] ?? "1") ?? 1
            guard scale.isFinite, scale > 0, scale <= 1 else { throw AdBlockError("invalid debug schedule scale") }
            schedules[profile] = Task { [weak self] in
                var delay: TimeInterval = 60
                var failures = 0
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(delay * scale))
                        try Task.checkCancellation()
                        guard self != nil else { return }
                        let outcome: String
                        do {
                            try await self?.updateListsNow(profile: profile)
                            failures = 0; delay = 24 * 60 * 60; outcome = "ok"
                        } catch {
                            if Task.isCancelled { return }
                            outcome = (error as? AdBlockError)?.description == "profile operation is in progress" ? "busy" : "failed"
                            delay = [60.0, 300, 1800, 86400][min(failures, 3)]
                            failures += 1
                        }
                        self?.onScheduledUpdate?(outcome, delay)
                    }
                } catch { /* session/profile closed */ }
            }
        }
    }

    public func closeProfile(_ profile: ProfileID) throws {
        if retired.contains(profile) { return }
        guard !busy.contains(profile) else { throw AdBlockError("profile operation is in progress") }
        let directory = directories.removeValue(forKey: profile)
        schedules.removeValue(forKey: profile)?.cancel()
        states.removeValue(forKey: profile); exclusions.removeValue(forKey: profile)
        lastUpdateResults.removeValue(forKey: profile)
        onEngineEvent?(.closed(profile: profile))
        if temporaryRoot != nil, let directory {
            let path = directory.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        }
    }

    /// A permanent barrier: cancel and drain all IO before ProfileTeardown removes the folder.
    /// Repeated callers await the same barrier, including for Profiles never opened here.
    public func retireProfile(_ profile: ProfileID) async {
        if let task = retirements[profile] { await task.value; return }
        guard retired.insert(profile).inserted else { return }
        schedules.removeValue(forKey: profile)?.cancel()
        let operation = operations[profile]
        operation?.cancel()
        let task = Task { @MainActor in
            _ = await operation?.result
            self.states.removeValue(forKey: profile)
            self.exclusions.removeValue(forKey: profile)
            self.directories.removeValue(forKey: profile)
            self.lastUpdateResults.removeValue(forKey: profile)
            self.onEngineEvent?(.closed(profile: profile))
        }
        retirements[profile] = task
        await task.value
        retirements.removeValue(forKey: profile)
    }

    public func setEnabled(_ enabled: Bool) throws {
        if temporaryRoot == nil {
            try writeJSON(GlobalSettings(nativeAdBlockEnabled: enabled), to: root.appendingPathComponent("adblock-settings.json"))
        }
        isEnabled = enabled
        onEngineEvent?(.enabled(enabled))
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    public func enabledListIDs(for profile: ProfileID) -> [String] {
        states[profile]?.enabledBlockLists ?? catalog.defaultIDs
    }

    public func listReceipt(_ id: String, profile: ProfileID) -> AdBlockListReceipt? { states[profile]?.lists[id] }

    public func excludedDomains(for profile: ProfileID) -> [String] { exclusions[profile, default: []].sorted() }

    public func siteSnapshot(for profile: ProfileID) -> AdBlockSiteSnapshot {
        AdBlockSiteSnapshot(isEnabled: isEnabled, excludedDomains: exclusions[profile, default: []])
    }

    public func setExcluded(_ domain: String, excluded: Bool, profile: ProfileID) throws {
        try checkActive(profile)
        guard states[profile] != nil else { throw AdBlockError("profile is not open") }
        let site = try AdBlockSites.shared.registrableDomain(domain)
        var domains = exclusions[profile, default: []]
        if excluded { domains.insert(site) } else { domains.remove(site) }
        if temporaryRoot == nil {
            try writeJSON(domains.sorted(), to: directory(for: profile).appendingPathComponent("exclusions.json"))
        }
        exclusions[profile] = domains
        onEngineEvent?(.exclusions(profile: profile, domains: domains.sorted()))
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    public func setListEnabled(_ id: String, _ on: Bool, profile: ProfileID) async throws {
        try checkActive(profile)
        let list = try catalog.list(id)
        guard !on || !list.urls.isEmpty else { throw AdBlockError("\(id): no public upstream source") }
        guard let state = states[profile] else { throw AdBlockError("profile is not open") }
        if state.enabledBlockLists.contains(id) == on { return }
        let directory = try listDirectory(for: profile)
        try await perform(profile) {
            do {
                let (next, results) = try await self.repository.setEnabled(id, on: on, directory: directory, state: state, catalog: self.catalog)
                try self.checkActive(profile)
                self.states[profile] = next
                self.lastUpdateResults[profile] = results
                self.onEngineEvent?(.reload(profile: profile, listDirectory: directory))
            } catch { try await self.recordFailure(error, state: state, profile: profile, directory: directory) }
        }
    }

    /// Reset the UI choices through the same verified list-generation path.
    public func resetListChoices(profile: ProfileID) async throws {
        try checkActive(profile)
        guard let state = states[profile] else { throw AdBlockError("profile is not open") }
        let directory = try listDirectory(for: profile)
        try await perform(profile) {
            do {
                let next = try await self.repository.resetChoices(directory: directory, state: state, catalog: self.catalog)
                try self.checkActive(profile)
                self.states[profile] = next
                self.onEngineEvent?(.reload(profile: profile, listDirectory: directory))
            } catch { try await self.recordFailure(error, state: state, profile: profile, directory: directory) }
        }
    }

    /// One reload after a changed batch. No reload for 304. A failed batch retains all old lists.
    public func updateListsNow(profile: ProfileID) async throws {
        try checkActive(profile)
        guard let state = states[profile] else { throw AdBlockError("profile is not open") }
        let directory = try listDirectory(for: profile)
        try await perform(profile) {
            do {
                if let raw = ProcessInfo.processInfo.environment["OPEN_ADBLOCK_DEBUG_UPDATE_DELAY_SECONDS"],
                   let delay = Double(raw), delay.isFinite, delay > 0, delay <= 60 {
                    try await Task.sleep(for: .seconds(delay))
                }
                let (next, results) = try await self.repository.updateBatch(catalog: self.catalog, directory: directory, state: state)
                try self.checkActive(profile)
                self.states[profile] = next; self.lastUpdateResults[profile] = results
                if results.contains(where: \.changed) {
                    self.onEngineEvent?(.reload(profile: profile, listDirectory: directory))
                }
            } catch { try await self.recordFailure(error, state: state, profile: profile, directory: directory) }
        }
    }

    private func recordFailure(_ error: any Error, state: AdBlockProfileState, profile: ProfileID, directory: URL) async throws {
        // Cancellation and deletion must never save a failure receipt or restore dropped state.
        try checkActive(profile)
        var failed = state
        failed.lastError = (error as? AdBlockError)?.description ?? "list operation failed"
        try await repository.save(failed, directory: directory)
        try checkActive(profile)
        states[profile] = failed; lastUpdateResults[profile] = []
        throw error
    }

    /// Build-time/offline seeds have immutable release pins. Runtime list updates instead verify
    /// local files against their last successful receipt, so upstream updates need no app release.
    public func prepareBundledDefaults(at destination: URL) async throws -> [AdBlockUpdateResult] {
        try await repository.repairBundle(catalog: catalog, destination: destination)
    }

    public func lastError(for profile: ProfileID) -> String? { states[profile]?.lastError }

    public func debugInfo(profile: ProfileID) -> String {
        var lines = ["catalog_version=\(catalog.version)", "enabled=\(isEnabled)",
                     "enabled_lists=\(enabledListIDs(for: profile).joined(separator: ","))"]
        lines.append("resources=\((try? BundledResources.revision().prefix(12)).map(String.init) ?? "unavailable")")
        for id in enabledListIDs(for: profile) {
            guard let receipt = states[profile]?.lists[id] else { continue }
            lines.append("\(id) bytes=\(receipt.bytes) sha256=\(receipt.sha256) etags=\(receipt.sources.map { $0.etag ?? "-" }.joined(separator: ","))")
        }
        lines.append("last_error=\(states[profile]?.lastError ?? "none")")
        // Deliberately omit hosts, profile paths, page URLs and list contents from copyable debug info.
        return lines.joined(separator: "\n")
    }

    private func checkActive(_ profile: ProfileID) throws {
        guard !retired.contains(profile) else { throw AdBlockError("This Profile was deleted.") }
        try Task.checkCancellation()
    }

    /// Track the task that actually performs IO, rather than only the caller's busy bit.
    /// Cancellation propagates to URLSession and every repository publication boundary.
    private func perform(_ profile: ProfileID, operation: @escaping @MainActor () async throws -> Void) async throws {
        try checkActive(profile)
        guard busy.insert(profile).inserted else { throw AdBlockError("profile operation is in progress") }
        let task = Task { try self.checkActive(profile); try await operation() }
        operations[profile] = task
        defer { operations.removeValue(forKey: profile); busy.remove(profile) }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try checkActive(profile)
    }
}
