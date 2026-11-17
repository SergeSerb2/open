import Foundation
import OpenModel

/// Nil optional keys are omitted on encode; both missing keys and explicit null decode.
/// Dates use secondsSince1970 on the file encoder/decoder, never deferredToDate.
public struct BoostFileDTO: Codable, Sendable {
    public var schemaVersion: Int
    public var profileID: String
    public var boosts: [Boost]
    public init(schemaVersion: Int = 1, profileID: String, boosts: [Boost]) {
        self.schemaVersion = schemaVersion; self.profileID = profileID; self.boosts = boosts
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, profileID, boosts }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        profileID = try c.decode(String.self, forKey: .profileID)
        boosts = try c.decode([Boost].self, forKey: .boosts)
    }
}

/// Call load once, before mutations; load must not race upsert or queued saves.
/// All mutable state is guarded by lock. File writes run only on queue.
public final class BoostStore: @unchecked Sendable {
    public let root: URL
    public let profileID: ProfileID
    public let fileURL: URL
    private let usesProfileLayout: Bool

    private let queue = DispatchQueue(label: "open.boosts", qos: .utility)
    private let lock = NSLock()
    private var pendingWork: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var boosts: [BoostID: Boost] = [:]
    private var sorted: [Boost]?
    private var loadedSchemaVersion = 1
    private var retired = false

    /// Pass ProfileDirectories.boostsFileURL(for:) for the current per-Profile layout.
    /// The nil default retains the original constructor for existing standalone callers.
    public init(root: URL? = nil, profileID: ProfileID, fileURL: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Open", isDirectory: true)
        self.profileID = profileID
        self.fileURL = fileURL ?? self.root.appendingPathComponent("Boosts/\(profileID.rawValue.uuidString).json")
        usesProfileLayout = fileURL != nil
    }

    public func load() -> [Boost] {
        guard !lock.withLock({ retired }) else { return [] }
        // The App's never-Boosted Profile needs one existence check, without
        // a directory scan, queue hop, file read or JSON decoder. Standalone
        // legacy stores retain abandoned-write cleanup even without a JSON file.
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        guard exists || !usesProfileLayout else {
            lock.withLock { boosts = [:]; sorted = nil; loadedSchemaVersion = 1 }
            return []
        }
        // load precedes mutation. Only our abandoned atomic-write files are removed.
        return queue.sync {
            guard !lock.withLock({ retired }) else { return [] }
            let directory = fileURL.deletingLastPathComponent(), prefix = fileURL.lastPathComponent + ".tmp-"
            let siblings = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? []
            for sibling in siblings where sibling.lastPathComponent.hasPrefix(prefix) {
                let values = try? sibling.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isRegularFile == true && values?.isSymbolicLink != true { try? FileManager.default.removeItem(at: sibling) }
            }
            guard exists else {
                lock.withLock { boosts = [:]; sorted = nil; loadedSchemaVersion = 1 }
                return []
            }
            do {
                let data = try Data(contentsOf: fileURL)
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
                let dto = try decoder.decode(BoostFileDTO.self, from: data)
                var loaded: [BoostID: Boost] = [:]
                for boost in dto.boosts { loaded[boost.id] = Self.normalized(boost) }
                #if DEBUG
                if dto.profileID != profileID.description { Self.log("BoostStore: profileID mismatch; using file name") }
                if loaded.count != dto.boosts.count { Self.log("BoostStore: duplicate IDs: \(dto.boosts.count - loaded.count)") }
                #endif
                lock.withLock { boosts = loaded; sorted = nil; loadedSchemaVersion = max(1, dto.schemaVersion) }
                return allBoosts()
            } catch {
                let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMddHHmmss"
                var corrupt = fileURL.appendingPathExtension("corrupt-\(formatter.string(from: Date()))")
                if FileManager.default.fileExists(atPath: corrupt.path) { corrupt.appendPathExtension(UUID().uuidString) }
                do {
                    try FileManager.default.moveItem(at: fileURL, to: corrupt)
                    #if DEBUG
                    Self.log("BoostStore: corrupt file moved aside: \(corrupt.lastPathComponent)")
                    #endif
                } catch { Self.log("BoostStore write failed: corrupt file could not be moved: \(error)") }
                lock.withLock { boosts = [:]; sorted = nil; loadedSchemaVersion = 1 }
                return []
            }
        }
    }

    public func allBoosts() -> [Boost] {
        lock.withLock {
            guard !retired else { return [] }
            if let sorted { return sorted }
            let result = boosts.values.sorted { $0.name == $1.name ? $0.id.description < $1.id.description : $0.name < $1.name }
            sorted = result
            return result
        }
    }
    public func boost(id: BoostID) -> Boost? { lock.withLock { retired ? nil : boosts[id] } }

    @discardableResult public func upsert(_ boost: Boost) -> Boost {
        var value = Self.normalized(boost); value.updatedAt = Date()
        lock.withLock { if !retired { boosts[value.id] = value; sorted = nil } }
        scheduleSave()
        return value
    }
    @discardableResult public func delete(id: BoostID) -> Bool {
        let changed = lock.withLock { guard !retired else { return false }; let old = boosts.removeValue(forKey: id); sorted = nil; return old != nil }
        if changed { scheduleSave() }
        return changed
    }
    @discardableResult public func setEnabled(id: BoostID, enabled: Bool) -> Bool {
        mutate(id) { boost in
            guard boost.isEnabled != enabled else { return false }
            boost.isEnabled = enabled; return true
        }
    }
    @discardableResult public func appendZap(boostID: BoostID, zap: ZappedElement) -> Bool {
        mutate(boostID) { $0.appendZap(zap) }
    }
    @discardableResult public func removeZap(boostID: BoostID, selector: String) -> Bool {
        mutate(boostID) { $0.removeZap(selector: selector) }
    }
    private func mutate(_ id: BoostID, _ action: (inout Boost) -> Bool) -> Bool {
        let changed = lock.withLock {
            guard !retired, var boost = boosts[id], action(&boost) else { return false }
            boost.updatedAt = Date(); boosts[id] = boost; sorted = nil
            return true
        }
        if changed { scheduleSave() }
        return changed
    }

    public func scheduleSave() {
        lock.lock()
        guard !retired else { lock.unlock(); return }
        pendingWork?.cancel(); generation &+= 1
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let dto: BoostFileDTO? = self.lock.withLock {
                guard !self.retired, self.generation == token else { return nil }
                self.pendingWork = nil
                return self.snapshotLocked()
            }
            if let dto { self.write(dto) }
        }
        pendingWork = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 1, execute: work)
    }
    /// Off-queue only (the app calls this on quit). Captures the latest DTO on the write queue.
    public func saveNow() {
        lock.withLock { pendingWork?.cancel(); pendingWork = nil; generation &+= 1 }
        queue.sync {
            let dto: BoostFileDTO? = lock.withLock { retired ? nil : snapshotLocked() }
            if let dto { write(dto) }
        }
    }
    /// A mutation's debounced write has not run yet (quit must call saveNow).
    public var hasPendingSave: Bool { lock.withLock { !retired && pendingWork != nil } }
    /// Drains in-flight writes. An asyncAfter debounce that has not fired is not flushed.
    /// Call saveNow on quit. Must be called off the private store queue.
    public func flush() { queue.sync {} }

    /// Permanently discard this store, including deferred writes. Off-queue only.
    /// Mark closed before draining: an in-flight write finishes before this returns;
    /// later calls, even from a retained editor or quit handler, cannot write again.
    public func retire() {
        lock.withLock {
            retired = true
            pendingWork?.cancel(); pendingWork = nil; generation &+= 1
            boosts = [:]; sorted = nil
        }
        queue.sync {}
        lock.withLock { boosts = [:]; sorted = nil }
    }

    private func snapshotLocked() -> BoostFileDTO {
        BoostFileDTO(schemaVersion: loadedSchemaVersion, profileID: profileID.description,
                     boosts: boosts.values.sorted { $0.id.description < $1.id.description })
    }
    /// Normalize an in-memory preview through the same writer as persistence.
    /// This does not mutate the store, schedule a save, or acquire its lock.
    public static func normalizedForPreview(_ input: Boost) -> Boost { normalized(input) }

    private static func normalized(_ input: Boost) -> Boost {
        var b = input
        b.siteMatch = .normalized(domain: b.siteMatch.domain, pathPrefix: b.siteMatch.pathPrefix)
        if let wheel = b.colorWheel?.clamped() {
            b.colorAdjustment = wheel.adjustment
            b.colorWheel = wheel.isIdentity ? nil : wheel
        } else { b.colorAdjustment = b.colorAdjustment?.clamped() }
        if b.fontFamily?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { b.fontFamily = nil }
        if let zoom = b.textZoom { b.textZoom = zoom.isNaN ? 1 : min(2, max(0.5, zoom)) }
        if let transform = b.textTransform, !["none", "uppercase", "lowercase", "capitalize"].contains(transform) { b.textTransform = nil }
        let zaps = b.zaps; b.zaps = []
        for zap in zaps { b.appendZap(zap) }
        return b
    }
    private func write(_ dto: BoostFileDTO) {
        guard !lock.withLock({ retired }) else { return }
        let tmp = fileURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]; encoder.dateEncodingStrategy = .secondsSince1970
            try encoder.encode(dto).write(to: tmp)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            } else { try FileManager.default.moveItem(at: tmp, to: fileURL) }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            Self.log("BoostStore write failed: \(error)")
        }
    }
    private static func log(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
}
