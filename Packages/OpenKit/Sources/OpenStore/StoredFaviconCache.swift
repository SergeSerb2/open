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
        var isResident = true
        var displayedImage: NSImage? { isResident ? image : nil }
        let url: URL
        var revision = 0
        init(_ url: URL) { self.url = url }
    }
    private enum Operation {
        case image(Data, URL?, UUID?)
        case removeCopy(UUID)
    }
    private struct Report { let key: String; let url: URL; let operation: Operation; let revision: Int; let entry: Entry }
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
        if let entry = entries[key] { return entry.displayedImage }
        let entry = entry(for: key, url: url)
        // Evicted queued reads do not retain images or callbacks without a bound.
        reads.removeAll { entries[$0.0] !== $0.1 }
        reads.append((key, entry))
        startWorker()
        return entry.displayedImage
    }

    /// Coalesce repeated reports for a page. Refuse oversized or excess input
    /// before retaining it; callers keep the existing placeholder on failure.
    @discardableResult
    public func report(_ data: Data, for url: URL, iconURL: URL? = nil, copyToken: UUID? = nil) -> Bool {
        guard data.count <= FaviconStore.maximumInputBytes, (iconURL?.absoluteString.utf8.count ?? 0) <= 8192 else {
            rejectedReports += 1; return false
        }
        return enqueue(.image(data, iconURL, copyToken), for: url)
    }

    @discardableResult
    public func removeCopy(for url: URL, token: UUID) -> Bool {
        enqueue(.removeCopy(token), for: url)
    }

    private func enqueue(_ operation: Operation, for url: URL) -> Bool {
        guard let key = FaviconStore.cacheKey(url) else {
            rejectedReports += 1; return false
        }
        let existing = reports.firstIndex { $0.key == key }
        guard existing != nil || reports.count < Self.maximumPendingReports else {
            rejectedReports += 1; return false
        }
        let entry = entry(for: key, url: url)
        entry.revision += 1
        let report = Report(key: key, url: url, operation: operation, revision: entry.revision, entry: entry)
        if let existing { reports[existing] = report } else { reports.append(report) }
        startWorker()
        return true
    }

    private func entry(for key: String, url: URL) -> Entry {
        if let entry = entries[key] { return entry }
        var evicted: Entry?
        if order.count == Self.capacity {
            evicted = entries.removeValue(forKey: order[cursor])
            order[cursor] = key
            cursor = (cursor + 1) % Self.capacity
        } else { order.append(key) }
        let entry = Entry(url); entries[key] = entry
        // Invalidate even a nil-image entry. Its existing observers must redraw
        // and bind to the replacement mapping; retain no evicted decoded image.
        evicted?.isResident = false; evicted?.image = nil
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
                        switch report.operation {
                        case let .image(data, iconURL, token):
                            try await self.store.ingest(imageData: data, iconURL: iconURL, for: report.url, pageSpecific: true, copyToken: token)
                        case let .removeCopy(token):
                            try await self.store.removeCopy(for: report.url, token: token)
                        }
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
