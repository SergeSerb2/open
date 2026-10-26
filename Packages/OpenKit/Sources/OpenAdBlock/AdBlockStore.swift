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
    public let root: URL
    public let catalog: AdBlockCatalog
    public var onScheduledUpdate: (@MainActor (_ outcome: String, _ nextDelay: TimeInterval) -> Void)?
    public var onEngineEvent: (@MainActor (AdBlockEngineEvent) -> Void)?
    public private(set) var isEnabled: Bool
    public private(set) var lastUpdateResults: [ProfileID: [AdBlockUpdateResult]] = [:]
    private var states: [ProfileID: AdBlockProfileState] = [:]
    private var exclusions: [ProfileID: Set<String>] = [:]
    private var busy = Set<ProfileID>()
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

    public func listDirectory(for profile: ProfileID) -> URL {
        profileDirectory(profile)
    }

    private func profileDirectory(_ profile: ProfileID) -> URL {
        root.appendingPathComponent("Profiles/\(profile.rawValue.uuidString)/adblock", isDirectory: true)
    }

    public func openProfile(_ profile: ProfileID, scheduleUpdates: Bool = true) async throws {
        if states[profile] != nil { return }
        try begin(profile)
        defer { busy.remove(profile) }
        let directory = profileDirectory(profile)
        let state = try await repository.open(directory: directory, catalog: catalog)
        let legacy = directory.deletingLastPathComponent().appendingPathComponent("AdBlock/exclusions.json")
        let domains = try readJSON([String].self, at: directory.appendingPathComponent("exclusions.json"),
                                  fallback: readJSON([String].self, at: legacy, fallback: []))
        let normalized = try Set(domains.map { try AdBlockSites.shared.registrableDomain($0) })
        states[profile] = state; exclusions[profile] = normalized
        onEngineEvent?(.configure(profile: profile, listDirectory: listDirectory(for: profile),
                                 enabled: isEnabled, excludedDomains: normalized.sorted()))
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
        guard !busy.contains(profile) else { throw AdBlockError("profile operation is in progress") }
        schedules.removeValue(forKey: profile)?.cancel()
        states.removeValue(forKey: profile); exclusions.removeValue(forKey: profile)
        lastUpdateResults.removeValue(forKey: profile)
        onEngineEvent?(.closed(profile: profile))
        if temporaryRoot != nil {
            let path = profileDirectory(profile).deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if temporaryRoot == nil {
            try writeJSON(GlobalSettings(nativeAdBlockEnabled: enabled), to: root.appendingPathComponent("adblock-settings.json"))
        }
        isEnabled = enabled
        onEngineEvent?(.enabled(enabled))
    }

    public func enabledListIDs(for profile: ProfileID) -> [String] {
        states[profile]?.enabledBlockLists ?? catalog.defaultIDs
    }

    public func excludedDomains(for profile: ProfileID) -> [String] { exclusions[profile, default: []].sorted() }

    public func siteSnapshot(for profile: ProfileID) -> AdBlockSiteSnapshot {
        AdBlockSiteSnapshot(isEnabled: isEnabled, excludedDomains: exclusions[profile, default: []])
    }

    public func setExcluded(_ domain: String, excluded: Bool, profile: ProfileID) throws {
        guard states[profile] != nil else { throw AdBlockError("profile is not open") }
        let site = try AdBlockSites.shared.registrableDomain(domain)
        var domains = exclusions[profile, default: []]
        if excluded { domains.insert(site) } else { domains.remove(site) }
        if temporaryRoot == nil {
            try writeJSON(domains.sorted(), to: profileDirectory(profile).appendingPathComponent("exclusions.json"))
        }
        exclusions[profile] = domains
        onEngineEvent?(.exclusions(profile: profile, domains: domains.sorted()))
    }

    public func setListEnabled(_ id: String, _ on: Bool, profile: ProfileID) async throws {
        let list = try catalog.list(id)
        guard !on || !list.urls.isEmpty else { throw AdBlockError("\(id): no public upstream source") }
        guard let state = states[profile] else { throw AdBlockError("profile is not open") }
        if state.enabledBlockLists.contains(id) == on { return }
        try begin(profile)
        defer { busy.remove(profile) }
        do {
            let (next, results) = try await repository.setEnabled(id, on: on, directory: profileDirectory(profile), state: state, catalog: catalog)
            states[profile] = next
            lastUpdateResults[profile] = results
            onEngineEvent?(.reload(profile: profile, listDirectory: listDirectory(for: profile)))
        } catch {
            var failed = state
            failed.lastError = (error as? AdBlockError)?.description ?? "list update failed"
            try await repository.save(failed, directory: profileDirectory(profile))
            states[profile] = failed
            throw error
        }
    }

    /// Reset the UI choices through the same verified list-generation path.
    public func resetListChoices(profile: ProfileID) async throws {
        guard states[profile] != nil else { throw AdBlockError("profile is not open") }
        for id in enabledListIDs(for: profile) where !catalog.defaultIDs.contains(id) {
            try await setListEnabled(id, false, profile: profile)
        }
        for id in catalog.defaultIDs { try await setListEnabled(id, true, profile: profile) }
        guard var state = states[profile] else { return }
        state.lastError = nil
        try await repository.save(state, directory: profileDirectory(profile))
        states[profile] = state
    }

    /// One reload after a changed batch. No reload for 304. A failed batch retains all old lists.
    public func updateListsNow(profile: ProfileID) async throws {
        guard var state = states[profile] else { throw AdBlockError("profile is not open") }
        try begin(profile)
        defer { busy.remove(profile) }
        let results: [AdBlockUpdateResult]
        do {
            if let raw = ProcessInfo.processInfo.environment["OPEN_ADBLOCK_DEBUG_UPDATE_DELAY_SECONDS"],
               let delay = Double(raw), delay.isFinite, delay > 0, delay <= 60 {
                try await Task.sleep(for: .seconds(delay))
            }
            (state, results) = try await repository.updateBatch(catalog: catalog, directory: profileDirectory(profile), state: state)
        } catch {
            let message = (error as? AdBlockError)?.description ?? "list batch: file operation failed"
            state.lastError = message
            try await repository.save(state, directory: profileDirectory(profile))
            states[profile] = state; lastUpdateResults[profile] = []
            if Task.isCancelled { throw CancellationError() }
            throw AdBlockError(message)
        }
        states[profile] = state; lastUpdateResults[profile] = results
        if results.contains(where: \.changed) {
            onEngineEvent?(.reload(profile: profile, listDirectory: listDirectory(for: profile)))
        }
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
        for id in enabledListIDs(for: profile) {
            guard let receipt = states[profile]?.lists[id] else { continue }
            lines.append("\(id) bytes=\(receipt.bytes) sha256=\(receipt.sha256) etags=\(receipt.sources.map { $0.etag ?? "-" }.joined(separator: ","))")
        }
        lines.append("last_error=\(states[profile]?.lastError ?? "none")")
        // Deliberately omit hosts, profile paths, page URLs and list contents from copyable debug info.
        return lines.joined(separator: "\n")
    }

    private func begin(_ profile: ProfileID) throws {
        guard busy.insert(profile).inserted else { throw AdBlockError("profile operation is in progress") }
    }
}
