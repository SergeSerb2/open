import AppKit
import Observation

/// App-wide sidebar cache. A draw reads one observable entry; one worker does
/// store access and decoding on FaviconStore's actor. No disk I/O on scroll.
@MainActor
public final class StoredFaviconCache {
    public static let capacity = 1024 // 1024 * 64 * 64 * 4 = 16 MiB decoded pixels.
    public static let maximumPendingReports = 32 // At most 16 MiB encoded input.
    @Observable final class Entry {
        var image: NSImage?
        let url: URL
        var revision = 0
        init(_ url: URL) { self.url = url }
    }
    private struct Report { let key: String; let url: URL; let data: Data; let revision: Int; let entry: Entry }
    private let store: FaviconStore
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var cursor = 0
    private var reads: [(String, Entry)] = []
    private var reports: [Report] = []
    private var worker: Task<Void, Never>?
    public private(set) var rejectedReports = 0
    public private(set) var completedReports = 0
    public var cachedCount: Int { entries.count }
    public var isIdle: Bool { worker == nil }

    public init(store: FaviconStore) { self.store = store }

    public func image(for url: URL) -> NSImage? {
        guard let key = FaviconStore.cacheKey(url) else { return nil }
        if let entry = entries[key] { return entry.image }
        let entry = entry(for: key, url: url)
        // Evicted queued reads do not retain images or callbacks without a bound.
        reads.removeAll { entries[$0.0] !== $0.1 }
        reads.append((key, entry))
        startWorker()
        return entry.image
    }

    /// Coalesce repeated reports for a page. Refuse oversized or excess input
    /// before retaining it; callers keep the existing placeholder on failure.
    @discardableResult
    public func report(_ data: Data, for url: URL) -> Bool {
        guard data.count <= FaviconStore.maximumInputBytes, let key = FaviconStore.cacheKey(url) else {
            rejectedReports += 1; return false
        }
        let existing = reports.firstIndex { $0.key == key }
        guard existing != nil || reports.count < Self.maximumPendingReports else {
            rejectedReports += 1; return false
        }
        let entry = entry(for: key, url: url)
        entry.revision += 1
        let report = Report(key: key, url: url, data: data, revision: entry.revision, entry: entry)
        if let existing { reports[existing] = report } else { reports.append(report) }
        startWorker()
        return true
    }

    private func entry(for key: String, url: URL) -> Entry {
        if let entry = entries[key] { return entry }
        if order.count == Self.capacity {
            entries[order[cursor]] = nil
            order[cursor] = key
            cursor = (cursor + 1) % Self.capacity
        } else { order.append(key) }
        let entry = Entry(url); entries[key] = entry
        return entry
    }

    /// Await accepted reports on quit; the App closes engine hosts first.
    public func flush() async { await worker?.value }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.worker = nil }
            while !self.reports.isEmpty || !self.reads.isEmpty {
                if !self.reports.isEmpty {
                    let report = self.reports.removeFirst()
                    do {
                        try await self.store.ingest(imageData: report.data, iconURL: nil, for: report.url, pageSpecific: true)
                        let bitmap = await self.store.decodedIcon(for: report.url)
                        if let entry = self.entries[report.key], entry === report.entry, entry.revision == report.revision {
                            entry.image = bitmap.map { NSImage(cgImage: $0, size: NSSize(width: 16, height: 16)) }
                        }
                        self.completedReports += 1
                    } catch { self.rejectedReports += 1 }
                } else {
                    let (key, entry) = self.reads.removeFirst()
                    guard self.entries[key] === entry else { continue }
                    let revision = entry.revision
                    let bitmap = await self.store.decodedIcon(for: entry.url)
                    guard self.entries[key] === entry, entry.revision == revision else { continue }
                    entry.image = bitmap.map { NSImage(cgImage: $0, size: NSSize(width: 16, height: 16)) }
                }
            }
        }
    }
}
