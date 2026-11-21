import Foundation

/// One open tab in a Chromium-family browser's last session.
public struct ChromiumOpenTab: Sendable, Hashable {
    public var url: URL
    public var title: String
    public var pinned: Bool
    public var window: Int
    public var index: Int
}

/// Reads the newest clear session file `<profile>/Sessions/Session_<time>` (SNSS) that holds a marker.
/// Format facts come from Chromium 156 `components/sessions/core` (our own reading, not copied code):
/// - header: int32 signature 0x53534E53 ("SNSS"), int32 version. Version 3 is clear text. Version 5 is
///   encrypted with OSCrypt and lives in `Sessions_Encrypted`; Chromium 156's default stage still writes the
///   clear file too ("write_both_read_only_clear"), so Open reads only version 3 and needs no key.
///   Versions 1 and 2 are "No longer supported" by Chromium itself (`command_storage_backend.cc`).
/// - each command: uint16 size (little endian), then `size` bytes = uint8 id + payload. Id 255 is the
///   initial-state marker: Chromium reads the newest file that has one (`FindLastSessionFile`), because a
///   newer file without it is still being written. Open does the same, and reads the newest version 3
///   file when none has a marker.
/// - id 0 SetTabWindow {int32 window, int32 tab}; 2 SetTabIndexInWindow {int32 tab, int32 index};
///   5 TabNavigationPathPrunedFromBack {int32 tab, int32 index}; 6 UpdateTabNavigation (Pickle: uint32
///   payload size; int32 tab, int32 index, string url, string16 title, …); 7 SetSelectedNavigationIndex
///   {int32 tab, int32 index}; 9 SetWindowType {int32 window, int32 type, 0 = normal};
///   11 TabNavigationPathPrunedFromFront {int32 tab, int32 count}; 12 SetPinnedState {int32 tab, bool};
///   16 TabClosed {int32 tab, int64 time}; 17 WindowClosed {int32 window, int64 time};
///   24 TabNavigationPathPruned {int32 tab, int32 index, int32 count} (`session_service_commands.cc`).
public struct ChromiumSessionReader: Sendable {
    public let profileDirectory: URL
    public init(profileDirectory: URL) { self.profileDirectory = profileDirectory }

    public enum ReadError: Error { case missing, unsupported, tooLarge, invalid }

    /// Hard limits. A 1,000-tab session file is a few MiB; navigation commands are at most 64 KiB each.
    /// The worst single allocation is one file buffer (32 MiB); files are read one at a time.
    public static let maxFileBytes = 32 << 20
    public static let maxCommands = 1_000_000
    public static let maxTabs = 5_000
    /// Session files tried, newest first. Chromium keeps two (the last and the current).
    static let maxCandidates = 8

    /// `Session_<number>` files, newest first by their numeric timestamp.
    func sessionFiles() throws -> [URL] {
        let directory = profileDirectory.appendingPathComponent("Sessions", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { throw ReadError.missing }
        let candidates = names.compactMap { name -> (UInt64, String)? in
            guard name.hasPrefix("Session_"), let stamp = UInt64(name.dropFirst("Session_".count)) else { return nil }
            return (stamp, name)
        }
        guard !candidates.isEmpty else { throw ReadError.missing }
        return candidates.sorted { $0.0 > $1.0 }.prefix(Self.maxCandidates).map { directory.appendingPathComponent($0.1) }
    }

    public func openTabs() throws -> [ChromiumOpenTab] {
        var fallback: [ChromiumOpenTab]?, firstError: (any Error)?
        for file in try sessionFiles() {
            let parsed: (tabs: [ChromiumOpenTab], marker: Bool)
            do {
                let data: Data
                do { data = try readBoundedFile(file, maxBytes: Self.maxFileBytes) }
                catch BoundedFileReadError.tooLarge { throw ReadError.tooLarge }
                catch BoundedFileReadError.missing { throw ReadError.missing }
                catch { throw ReadError.invalid }
                parsed = try Self.scan([UInt8](data))
            } catch {
                if firstError == nil { firstError = error }
                continue
            }
            if parsed.marker { return parsed.tabs }
            if fallback == nil { fallback = parsed.tabs }
        }
        if let fallback { return fallback }
        throw firstError ?? ReadError.missing
    }

    struct TabState { var window: Int32?; var index: Int32 = 0; var selected: Int32?; var pinned = false
        var navigations: [Int32: (url: String, title: String)] = [:]
        /// Chromium `ProcessTabNavigationPathPrunedCommand`. Int arithmetic: `index + count` can overflow Int32.
        mutating func prune(from start: Int, count: Int) {
            if let current = selected.map(Int.init) {
                if current >= start && current < start + count { selected = Int32(clamping: start - 1) }
                else if current >= start + count { selected = Int32(clamping: current - count) }
            }
            var kept: [Int32: (url: String, title: String)] = [:]
            for (key, value) in navigations {
                let index = Int(key)
                if index < start { kept[key] = value } else if index >= start + count { kept[Int32(clamping: index - count)] = value }
            }
            navigations = kept
        }
    }

    static func parse(_ bytes: [UInt8]) throws -> [ChromiumOpenTab] { try scan(bytes).tabs }

    /// The open tabs, and whether the file holds the initial-state marker (id 255).
    static func scan(_ bytes: [UInt8]) throws -> (tabs: [ChromiumOpenTab], marker: Bool) {
        func int32(_ at: Int) -> Int32? {
            guard at >= 0, at + 4 <= bytes.count else { return nil }
            return Int32(bitPattern: UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24)
        }
        guard bytes.count >= 8, int32(0) == 0x53534E53 else { throw ReadError.invalid }
        guard int32(4) == 3 else { throw ReadError.unsupported }
        var tabs: [Int32: TabState] = [:]
        var windowTypes: [Int32: Int32] = [:]
        var closedWindows = Set<Int32>()
        var position = 8, commands = 0, marker = false
        func tab(_ id: Int32, _ change: (inout TabState) -> Void) throws {
            if tabs[id] == nil { guard tabs.count < maxTabs else { throw ReadError.tooLarge }; tabs[id] = TabState() }
            change(&tabs[id]!)
        }
        while position + 2 <= bytes.count {
            commands += 1
            guard commands <= maxCommands else { throw ReadError.tooLarge }
            let size = Int(bytes[position]) | Int(bytes[position + 1]) << 8
            let start = position + 2
            // An incomplete last command means the browser was writing; Chromium also stops there.
            guard size >= 1, start + size <= bytes.count else { break }
            let id = bytes[start], payload = start + 1, length = size - 1
            position = start + size
            func pair() -> (Int32, Int32)? {
                guard length >= 8, let a = int32(payload), let b = int32(payload + 4) else { return nil }
                return (a, b)
            }
            switch id {
            case 0: if let (window, tabID) = pair() { try tab(tabID) { $0.window = window } }
            case 2: if let (tabID, index) = pair() { try tab(tabID) { $0.index = index } }
            // Back/forward entries removed. Chromium: 5 drops every entry from `index` on; 11 removes
            // `count` entries from the front; 24 removes `count` entries from `index`. Later entries move down.
            case 5: if let (tabID, index) = pair() { try tab(tabID) { state in state.navigations = state.navigations.filter { entry in entry.key < index } } }
            case 11: if let (tabID, count) = pair(), count > 0 { try tab(tabID) { $0.prune(from: 0, count: Int(count)) } }
            case 24:
                if length >= 12, let tabID = int32(payload), let index = int32(payload + 4), let count = int32(payload + 8), index >= 0, count > 0 {
                    try tab(tabID) { $0.prune(from: Int(index), count: Int(count)) }
                }
            case 255: marker = true
            case 7: if let (tabID, index) = pair() { try tab(tabID) { $0.selected = index } }
            case 9: if let (window, type) = pair() { windowTypes[window] = type }
            case 12: if length >= 5, let tabID = int32(payload) { let pinned = bytes[payload + 4] != 0; try tab(tabID) { $0.pinned = pinned } }
            case 16: if let tabID = int32(payload), length >= 4 { tabs[tabID] = nil }
            case 17: if let window = int32(payload), length >= 4 { closedWindows.insert(window) }
            case 6:
                guard let entry = navigation(bytes, payload, length) else { continue }
                try tab(entry.tab) { $0.navigations[entry.index] = (entry.url, entry.title) }
            default: continue
            }
        }
        var result: [ChromiumOpenTab] = []
        for state in tabs.values {
            guard let window = state.window, !closedWindows.contains(window), (windowTypes[window] ?? 0) == 0 else { continue }
            // Chromium's rule: the first entry at or after the selected index (none selected: -1), else the last.
            let entries = state.navigations.sorted { $0.key < $1.key }
            let selected = Int(state.selected ?? -1)
            let current = (entries.first { Int($0.key) >= selected } ?? entries.last)?.value
            guard let current, let url = URL(string: current.url), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "file"].contains(scheme) else { continue }
            result.append(ChromiumOpenTab(url: url, title: current.title, pinned: state.pinned, window: Int(window), index: Int(state.index)))
        }
        return (result.sorted { ($0.window, $0.index) < ($1.window, $1.index) }, marker)
    }

    /// Pickle: uint32 payload size, then int32 tab, int32 index, string url, string16 title. Fields are 4-byte aligned.
    static func navigation(_ bytes: [UInt8], _ start: Int, _ length: Int) -> (tab: Int32, index: Int32, url: String, title: String)? {
        let end = start + length
        var at = start + 4 // the Pickle header
        func int32() -> Int32? {
            guard at + 4 <= end else { return nil }
            defer { at += 4 }
            return Int32(bitPattern: UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24)
        }
        func data(unit: Int) -> [UInt8]? {
            guard let count = int32(), count >= 0, count <= 65_536 else { return nil }
            let byteCount = Int(count) * unit
            guard at + byteCount <= end else { return nil }
            defer { at += (byteCount + 3) & ~3 }
            return Array(bytes[at..<at + byteCount])
        }
        guard length >= 16, let tab = int32(), let index = int32(), let url = data(unit: 1), let title = data(unit: 2) else { return nil }
        let units = stride(from: 0, to: title.count, by: 2).map { UInt16(title[$0]) | UInt16(title[$0 + 1]) << 8 }
        return (tab, index, String(decoding: url, as: UTF8.self), String(decoding: units, as: UTF16.self))
    }
}
