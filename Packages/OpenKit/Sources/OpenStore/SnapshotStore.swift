import Foundation
import OpenModel

/// Versioned JSON snapshot at <root>/State/browser.json.
/// Writes are atomic (temp file + rename) on a background queue, debounced 1 s.
public final class SnapshotStore: @unchecked Sendable {
    public let root: URL
    public var fileURL: URL { root.appendingPathComponent("State/browser.json") }

    private let queue = DispatchQueue(label: "open.snapshot", qos: .utility)
    private var pendingWork: DispatchWorkItem?
    private let lock = NSLock()
    private var dataRootLock: DataRootLock?
    @MainActor private var dirtyModel: BrowserModel?
    @MainActor private var saveGeneration = 0
    @MainActor public private(set) var captureCount = 0
    @MainActor public private(set) var scheduleCount = 0
    @MainActor public var isDirty: Bool { dirtyModel != nil }
    /// The first unsaved change since the last capture, in system uptime seconds (monotonic, so a
    /// clock change cannot stretch the wait; bug sweep r7 Z-06: the maximum wait).
    @MainActor private var dirtySince: TimeInterval?
    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    /// A change waits at most this long for its save, even while later changes keep arriving.
    public static let maximumSaveWait: TimeInterval = 10
    /// The model of the last debounced capture: a failed write marks it dirty again.
    @MainActor private weak var capturedModel: BrowserModel?
    /// Called on the main actor once for each run of failed saves (a full disk, a read-only folder);
    /// a later successful write ends the run (bug sweep r7 Z-05). Return false when nobody was told
    /// (no window to show it in): the next failure calls again.
    @MainActor public var onSaveFailure: ((String) -> Bool)?
    /// Guarded by `lock` (review r2 of #670). `lastWriteFailed`: the latest write failed; set on the
    /// write queue itself, so `flush()` sees the first failure. `failureReported`: the App was told
    /// about this run of failures. A successful write clears both.
    private var lastWriteFailed = false
    private var failureReported = false

    private func holdRootLock() throws {
        try lock.withLock {
            if dataRootLock == nil { dataRootLock = try DataRootLock.acquire(root: root) }
        }
    }

    /// The model (weak: a later model can reuse its address) and Profile folder set the last
    /// full prepare covered.
    @MainActor private weak var preparedModel: BrowserModel?
    @MainActor private var preparedDirectories: Set<String> = []
    /// Full data-root prepares (automation evidence: unchanged Profiles skip the disk work).
    @MainActor public private(set) var prepareCount = 0

    @MainActor
    private func prepare(model: BrowserModel) throws {
        try holdRootLock()
        // The folder listings, retired-name read and per-Profile mkdirs run on the main actor.
        // Repeat them only for another model or a changed set of Profile folders.
        let directories = Set(model.profiles.map(\.dataDirectoryName))
        if preparedModel === model, preparedDirectories == directories { return }
        _ = try OpenDataRoot.prepare(root: root, model: model)
        prepareCount += 1
        preparedModel = model; preparedDirectories = directories
    }

    public init(root: URL? = nil) {
        if let root { self.root = root }
        else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.root = base.appendingPathComponent("Open", isDirectory: true)
        }
    }

    /// Debounced save. Call from the main actor after any command.
    @MainActor
    public func scheduleSave(model: BrowserModel) {
        // Scheduling never walks the model or opens files. Frame drags can
        // mark dirty repeatedly; only the final debounced turn captures a DTO.
        let now = Self.uptime
        // Each change restarts the 1 s wait, up to `maximumSaveWait` after the first unsaved change.
        // Past that, a pending save is kept, not replaced: it runs within 1 s and captures this change
        // too, so a page whose address or title keeps changing cannot hold the save back until quit.
        if let since = dirtySince, now - since >= Self.maximumSaveWait,
           lock.withLock({ pendingWork.map { !$0.isCancelled } ?? false }) {
            dirtyModel = model; scheduleCount += 1
            return
        }
        if dirtyModel == nil || dirtySince == nil { dirtySince = now }
        dirtyModel = model; saveGeneration += 1; scheduleCount += 1
        let generation = saveGeneration
        lock.lock()
        pendingWork?.cancel()
        let work = DispatchWorkItem { @Sendable [weak self] in
            Task { @MainActor [weak self] in self?.capturePending(generation: generation) }
        }
        pendingWork = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
    /// Only a page title changed (a background tab's unread count, a ticking clock): saved within
    /// 10 s of the first such change, not 1 s after each one. A pending save takes it along, a later
    /// structural change still saves after 1 s, and quit flushes it (the model stays dirty). Each
    /// title change used to restart the 1 s save, so a title that ticked every 1-2 s rewrote the
    /// whole snapshot that often (bug sweep r6, PERF-06).
    @MainActor
    public func scheduleMetadataSave(model: BrowserModel) {
        dirtyModel = model; metadataScheduleCount += 1
        lock.lock()
        guard pendingWork == nil else { lock.unlock(); return }
        saveGeneration += 1
        let generation = saveGeneration
        let work = DispatchWorkItem { @Sendable [weak self] in
            Task { @MainActor [weak self] in self?.capturePending(generation: generation) }
        }
        pendingWork = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + Self.metadataSaveDelay, execute: work)
    }
    public static let metadataSaveDelay: TimeInterval = 10
    @MainActor public private(set) var metadataScheduleCount = 0
    @MainActor
    private func capturePending(generation: Int) {
        guard generation == saveGeneration, let model = dirtyModel else { return }
        // This work item has run: a failed prepare must not leave it "pending", or every later
        // title-only save, and the maximum wait of `scheduleSave`, would wait for it forever
        // (review of #665, #7; bug sweep r7 Z-06).
        lock.withLock { pendingWork = nil }
        do {
            try prepare(model: model)
            let dto = SnapshotMapper.dto(from: model); captureCount += 1
            dirtyModel = nil; dirtySince = nil; capturedModel = model
            lock.withLock { pendingWork = nil }
            queue.async { [weak self] in self?.writeReportingFailure(dto: dto, generation: generation) }
        } catch {
            FileHandle.standardError.write(Data("SnapshotStore prepare failed: \(error)\n".utf8))
            // The model stays dirty; the user is told as for a failed write (review r1 of #670).
            reportFailure(error.localizedDescription)
        }
    }

    /// The first failure of a run tells the App; a failure nobody saw does not start the run.
    @MainActor private func reportFailure(_ message: String) {
        let first = lock.withLock { () -> Bool in defer { failureReported = true }; return !failureReported }
        guard first, let onSaveFailure, !onSaveFailure(message) else { return }
        lock.withLock { failureReported = false }
    }
    private func writeSucceeded() { lock.withLock { lastWriteFailed = false; failureReported = false } }

    /// Synchronous save (also used by flush and the CLI).
    @MainActor
    public func saveNow(model: BrowserModel) throws {
        saveGeneration += 1
        lock.withLock { pendingWork?.cancel(); pendingWork = nil }
        try prepare(model: model)
        let dto = SnapshotMapper.dto(from: model); captureCount += 1; dirtyModel = nil; dirtySince = nil
        do {
            try queue.sync { try write(dto: dto) }
            writeSucceeded()
        } catch {
            // Still unsaved: a later change, flush or quit tries again.
            dirtyModel = model; dirtySince = Self.uptime
            throw error
        }
    }

    /// Captures dirty state synchronously, then waits for writes already queued.
    /// For quit-time use, prefer saveNow(model:) so the latest state is captured.
    @MainActor public func flush() {
        if let model = dirtyModel {
            do { try saveNow(model: model) }
            catch { FileHandle.standardError.write(Data("SnapshotStore flush failed: \(error)\n".utf8)) }
        } else {
            queue.sync {}
            // A background write that just failed has not marked the model dirty again yet: retry it
            // now (review r1 of #670).
            if lock.withLock({ lastWriteFailed }), dirtyModel == nil, let model = capturedModel {
                do { try saveNow(model: model) }
                catch { FileHandle.standardError.write(Data("SnapshotStore flush failed: \(error)\n".utf8)) }
            }
        }
    }

    private func writeReportingFailure(dto: SnapshotFileDTO, generation: Int) {
        do {
            try write(dto: dto)
            writeSucceeded()
        } catch {
            FileHandle.standardError.write(Data("SnapshotStore write failed: \(error)\n".utf8))
            lock.withLock { lastWriteFailed = true }
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The captured state never reached the disk: keep it unsaved, so the next change,
                // flush or quit writes it again. A newer schedule or save already covers it.
                if generation == self.saveGeneration, self.dirtyModel == nil, let model = self.capturedModel {
                    self.dirtyModel = model; self.dirtySince = Self.uptime
                }
                // A save that succeeded since then makes this failure stale: no toast.
                if self.lock.withLock({ self.lastWriteFailed }) { self.reportFailure(message) }
            }
        }
    }

    private func write(dto: SnapshotFileDTO) throws {
        if ProcessInfo.processInfo.environment["OPENKIT_DEBUG_SNAPSHOT_WRITE_FAIL"] == "1" {
            throw NSError(domain: NSPOSIXErrorDomain, code: 28, userInfo: [NSLocalizedDescriptionKey: "snapshot write failed: simulated disk full"])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DurableFiles.write(encoder.encode(dto), to: fileURL)
    }

    public func loadData() throws -> SnapshotFileDTO? {
        try holdRootLock()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(SnapshotFileDTO.self, from: data)
    }

    @MainActor
    public func load() throws -> BrowserModel? {
        guard let dto = try loadData() else {
            try OpenDataRoot.prepare(root: root)
            return nil
        }
        let model = SnapshotMapper.model(from: dto)
        try OpenDataRoot.prepare(root: root, model: model)
        return model
    }
}
