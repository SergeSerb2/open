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
        profileDirectory(profile).appendingPathComponent("lists", isDirectory: true)
    }

    private func profileDirectory(_ profile: ProfileID) -> URL {
        root.appendingPathComponent("Profiles/\(profile.rawValue.uuidString)/AdBlock", isDirectory: true)
    }

    public func openProfile(_ profile: ProfileID, scheduleUpdates: Bool = true) async throws {
        if states[profile] != nil { return }
        try begin(profile)
        defer { busy.remove(profile) }
        let directory = profileDirectory(profile)
        var state = try repository.readState(directory: directory, catalog: catalog)
        if repository.needsPreparation(directory: directory, state: state, catalog: catalog) {
            state = try await repository.prepare(directory: directory, state: state, catalog: catalog)
        }
        let domains = try readJSON([String].self, at: directory.appendingPathComponent("exclusions.json"), fallback: [])
        let normalized = try Set(domains.map { try AdBlockSites.shared.registrableDomain($0) })
        if !FileManager.default.fileExists(atPath: listDirectory(for: profile).path) {
            try FileManager.default.createDirectory(at: listDirectory(for: profile), withIntermediateDirectories: true)
        }
        states[profile] = state; exclusions[profile] = normalized
        onEngineEvent?(.configure(profile: profile, listDirectory: listDirectory(for: profile),
                                 enabled: isEnabled, excludedDomains: normalized.sorted()))
        if scheduleUpdates {
            schedules[profile] = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(60))
                    while !Task.isCancelled {
                        try Task.checkCancellation()
                        // Weak self is held only during each update, never during the 24-hour sleep.
                        try? await self?.updateListsNow(profile: profile)
                        try await Task.sleep(for: .seconds(24 * 60 * 60))
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
        var next = state
        if on {
            // Download first. A failure leaves both the enabled set and engine inputs unchanged.
            let (receipt, result) = try await repository.update(list, directory: profileDirectory(profile), previous: state.lists[id])
            next.lists[id] = receipt
            lastUpdateResults[profile] = [result]
        }
        next = try await repository.setEnabled(id, on: on, directory: profileDirectory(profile), state: next)
        states[profile] = next
        onEngineEvent?(.reload(profile: profile, listDirectory: listDirectory(for: profile)))
    }

    /// One reload after a changed batch. No reload for 304. A failed batch retains all old lists.
    public func updateListsNow(profile: ProfileID) async throws {
        guard var state = states[profile] else { throw AdBlockError("profile is not open") }
        try begin(profile)
        defer { busy.remove(profile) }
        let results: [AdBlockUpdateResult]
        do {
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
