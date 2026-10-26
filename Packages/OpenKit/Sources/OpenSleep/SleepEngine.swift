import Foundation
import OpenModel

public struct SleepHistoryEnvelope: Sendable, Equatable {
    public var container: Data
    public var currentIndex: Int
    public var entryCount: Int
    public var currentURL: URL
    public var currentTitle: String
    public var faviconURL: URL?
    public var hasPageState: Bool
    public var containerVersion: Int
    public var chromiumTag: String
    public var capturedAt: Date

    public init(container: Data, currentIndex: Int, entryCount: Int, currentURL: URL,
                currentTitle: String, faviconURL: URL? = nil, hasPageState: Bool,
                containerVersion: Int = 1, chromiumTag: String, capturedAt: Date) {
        self.container = container; self.currentIndex = currentIndex; self.entryCount = entryCount
        self.currentURL = currentURL; self.currentTitle = currentTitle; self.faviconURL = faviconURL
        self.hasPageState = hasPageState; self.containerVersion = containerVersion
        self.chromiumTag = chromiumTag; self.capturedAt = capturedAt
    }
}

@MainActor
public protocol SleepHistoryStoring: AnyObject {
    /// Returns only after the history transaction commits. Failure must throw.
    func save(tabID: ItemID, envelope: SleepHistoryEnvelope) async throws
    /// Awaits all preceding writes and their durable commit before quit.
    func flush() async throws
    func sleepHistory(tabID: ItemID) async -> SleepHistoryEnvelope?
    func deleteSleepHistory(tabID: ItemID)
}

/// The app's OpenEngine adapter implements this boundary. No CEF types cross it.
///
/// HARD S6 ADAPTER REQUIREMENT: deliver tabDidCommit and tabAudioChanged for
/// EVERY tab commit/audio event, including background tabs and short events
/// between ticks. Sampling alone is forbidden. Update capture/PiP/download,
/// loading, DevTools, and form state on EVERY corresponding engine event.
/// Feed PiP and all auxiliary surfaces into SleepVisibilityProviding, and call
/// visibility hooks on window/surface changes. Report user interaction through
/// tabUserInteracted, and unload-handler changes through tabUnloadHandlersChanged.
/// Staggered queries are a fallback, never a replacement for event delivery.
@MainActor
public protocol SleepEngine: AnyObject {
    func createContent(tabID: ItemID, url: URL, history: SleepHistoryEnvelope?) async -> Bool
    func destroyContent(tabID: ItemID)
    func setVisible(tabID: ItemID, visible: Bool)
    func freeze(tabID: ItemID) -> Bool
    func discard(tabID: ItemID) async -> Bool
    func wasDiscarded(tabID: ItemID) -> Bool
    func captureHistory(tabID: ItemID) -> SleepHistoryEnvelope?
    func hasUnloadHandlers(tabID: ItemID) -> Bool
    func handleCriticalPressure()
}

/// One app-owned snapshot, read once at the start of each controller pass.
/// Missing or closed windows contribute no selected tabs. Auxiliary sets must
/// contain only tabs actually shown; PiP remains protected independently of windows.
public struct SleepVisibilitySnapshot: Sendable {
    public enum WindowState: Sendable { case visible, minimized, occluded, closed }
    public var windows: [WindowID: WindowState]
    public var peek: Set<ItemID>
    public var littleOpen: Set<ItemID>
    public var splitPanes: Set<ItemID>
    public var pictureInPicture: Set<ItemID>
    public var mediaControls: Set<ItemID>

    public init(windows: [WindowID: WindowState], peek: Set<ItemID> = [],
                littleOpen: Set<ItemID> = [], splitPanes: Set<ItemID> = [],
                pictureInPicture: Set<ItemID> = [], mediaControls: Set<ItemID> = []) {
        self.windows = windows; self.peek = peek; self.littleOpen = littleOpen
        self.splitPanes = splitPanes; self.pictureInPicture = pictureInPicture
        self.mediaControls = mediaControls
    }

    @MainActor
    public func visibleTabIDs(in model: BrowserModel) -> Set<ItemID> {
        var ids = peek.union(littleOpen).union(splitPanes).union(pictureInPicture).union(mediaControls)
        for window in model.windows where windows[window.id] == .visible {
            guard let id = window.selectedNodeBySpace[window.focusedSpaceID],
                  let node = model.index[id] else { continue }
            if let split = node.split { ids.formUnion(split.panes.map(\.id)) }
            else if node.tab != nil { ids.insert(id) }
        }
        return ids
    }
}

@MainActor
public protocol SleepVisibilityProviding: AnyObject {
    func sleepVisibility() -> SleepVisibilitySnapshot
}

/// Open's v1 packing contract. Payloads remain opaque; this does not decode Chromium pickles.
/// The future OpenEngine bridge must use the same validation at its CEF boundary.
public struct SleepHistoryContainer: Sendable, Equatable {
    public static let maximumBytes = 2 * 1024 * 1024
    public static let maximumEntries = 512
    public let entries: [Data]
    public let currentIndex: Int
    public let hasPageState: Bool

    public enum Invalid: Error { case header, count, index, length, tooLarge }

    public init(entries: [Data], currentIndex: Int, hasPageState: Bool) throws {
        guard (1...Self.maximumEntries).contains(entries.count) else { throw Invalid.count }
        guard entries.indices.contains(currentIndex) else { throw Invalid.index }
        guard entries.allSatisfy({ !$0.isEmpty }) else { throw Invalid.length }
        guard 20 + entries.count * 4 + entries.reduce(0, { $0 + $1.count }) <= Self.maximumBytes else { throw Invalid.tooLarge }
        self.entries = entries; self.currentIndex = currentIndex; self.hasPageState = hasPageState
    }

    public func encoded() -> Data {
        var bytes = Data([0x4f, 0x50, 0x4e, 0x48])
        func append(_ value: Int) {
            let n = UInt32(value)
            bytes.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) })
        }
        append(1); append(entries.count); append(currentIndex)
        bytes.append(contentsOf: [hasPageState ? 1 : 0, 0, 0, 0])
        for entry in entries { append(entry.count); bytes.append(entry) }
        return bytes
    }

    public init(data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw Invalid.tooLarge }
        // Copy once, so slices with nonzero startIndex are safe too. No unaligned loads.
        let bytes = [UInt8](data)
        guard bytes.count >= 20, Array(bytes[0..<4]) == [0x4f, 0x50, 0x4e, 0x48],
              bytes[16] & 0xfe == 0, bytes[17...19].allSatisfy({ $0 == 0 }) else { throw Invalid.header }
        func read(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | (Int(bytes[offset + $1]) << ($1 * 8)) }
        }
        guard read(4) == 1 else { throw Invalid.header }
        let count = read(8), index = read(12)
        guard (1...Self.maximumEntries).contains(count) else { throw Invalid.count }
        guard index < count else { throw Invalid.index }
        var offset = 20
        var entries: [Data] = []
        for _ in 0..<count {
            guard bytes.count - offset >= 4 else { throw Invalid.length }
            let length = read(offset); offset += 4
            guard length > 0, length <= Self.maximumBytes, length <= bytes.count - offset else { throw Invalid.length }
            entries.append(Data(bytes[offset..<(offset + length)])); offset += length
        }
        guard offset == bytes.count else { throw Invalid.length }
        try self.init(entries: entries, currentIndex: index, hasPageState: bytes[16] == 1)
    }

    /// S0 simulation seam for the capture size retry. The adapter must rebuild entries
    /// using EXCLUDE_PAGE_STATE, never truncate the first serialization.
    public static func capture(currentIndex: Int, defaultEntries: () -> [Data],
                               excludingPageState: () -> [Data]) throws -> Self {
        do { return try Self(entries: defaultEntries(), currentIndex: currentIndex, hasPageState: true) }
        catch Invalid.tooLarge {
            return try Self(entries: excludingPageState(), currentIndex: currentIndex, hasPageState: false)
        }
    }
}
