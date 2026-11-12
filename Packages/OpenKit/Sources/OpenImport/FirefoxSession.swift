import Foundation
import Compression

/// One open tab in the source browser's last session (I-6). Only the current history entry is kept.
public struct ImportedOpenTab: Sendable, Equatable {
    public var url: URL
    public var title: String
    public var isPinned: Bool
    public var lastAccessed: Date?
    /// 0-based window index in the session, for grouping.
    public var window: Int
}

public struct ImportedOpenTabsReport: Sendable, Equatable {
    public var windows = 0
    public var sourceTabs = 0
    public var kept = 0
    public var skippedUnsupportedURL = 0
    public var skippedEmpty = 0
    public init() {}
    public var accounted: Int { kept + skippedUnsupportedURL + skippedEmpty }
}

/// Firefox session store: `sessionstore-backups/recovery.jsonlz4` (running or crashed) or
/// `sessionstore.jsonlz4` (clean quit). Format: magic `mozLz40\0`, little-endian u32 decoded size,
/// then one LZ4 block (docs/re/browser-import.md §4.3, DISK). JSON: `windows[].tabs[]` with `entries[]`,
/// 1-based `index`, `pinned`, `lastAccessed` (ms), `hidden`. Our own LZ4 block decoder (public format).
public struct FirefoxSessionReader: Sendable {
    public let profileDirectory: URL
    public static let maxCompressedBytes = 64 << 20
    public static let maxDecodedBytes = 256 << 20
    public init(profileDirectory: URL) { self.profileDirectory = profileDirectory }

    /// The newest session file that exists.
    public var sessionFile: URL? {
        let candidates = [profileDirectory.appendingPathComponent("sessionstore-backups/recovery.jsonlz4"),
                          profileDirectory.appendingPathComponent("sessionstore.jsonlz4")]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
            .max { (Self.mtime($0) ?? .distantPast) < (Self.mtime($1) ?? .distantPast) }
    }

    static func mtime(_ url: URL) -> Date? { (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }

    public func read() throws -> (tabs: [ImportedOpenTab], report: ImportedOpenTabsReport) {
        guard let file = sessionFile else { throw FirefoxImportError.missingFile("sessionstore") }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber,
              size.intValue <= Self.maxCompressedBytes, let data = try? Data(contentsOf: file) else { throw FirefoxImportError.unreadable("sessionstore") }
        guard let json = Self.decodeMozLz4(data),
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw FirefoxImportError.schemaMismatch("sessionstore") }
        return Self.tabs(from: root)
    }

    static func tabs(from root: [String: Any]) -> (tabs: [ImportedOpenTab], report: ImportedOpenTabsReport) {
        var report = ImportedOpenTabsReport(), result: [ImportedOpenTab] = []
        let windows = (root["windows"] as? [[String: Any]]) ?? []
        report.windows = windows.count
        for (w, window) in windows.enumerated() {
            for tab in (window["tabs"] as? [[String: Any]]) ?? [] {
                report.sourceTabs += 1
                let entries = (tab["entries"] as? [[String: Any]]) ?? []
                let index = ((tab["index"] as? NSNumber)?.intValue ?? entries.count) - 1
                guard entries.indices.contains(index), let raw = entries[index]["url"] as? String else { report.skippedEmpty += 1; continue }
                guard let url = URL(string: raw), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else {
                    report.skippedUnsupportedURL += 1; continue
                }
                let ms = (tab["lastAccessed"] as? NSNumber)?.doubleValue ?? 0
                result.append(ImportedOpenTab(url: url, title: entries[index]["title"] as? String ?? "", isPinned: (tab["pinned"] as? Bool) ?? false,
                                              lastAccessed: ms > 0 ? validatedImportDate(unixSeconds: ms / 1000) : nil, window: w))
                report.kept += 1
            }
        }
        return (result, report)
    }

    static let magic: [UInt8] = Array("mozLz40\0".utf8)

    /// mozLz4 container → decoded bytes. Refuses a bad magic, an oversize claim, and any size mismatch.
    static func decodeMozLz4(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, Array(bytes[0..<8]) == magic else { return nil }
        let size = Int(bytes[8]) | Int(bytes[9]) << 8 | Int(bytes[10]) << 16 | Int(bytes[11]) << 24
        guard size >= 0, size <= maxDecodedBytes else { return nil }
        return lz4Block(Array(bytes[12...]), decodedSize: size).map { Data($0) }
    }

    /// LZ4 block format (public spec): sequences of literals + (offset, match length).
    static func lz4Block(_ input: [UInt8], decodedSize: Int) -> [UInt8]? {
        var out = [UInt8](); out.reserveCapacity(decodedSize)
        var i = 0
        while i < input.count {
            let token = Int(input[i]); i += 1
            var literals = token >> 4
            if literals == 15 {
                while true { guard i < input.count else { return nil }; let b = Int(input[i]); i += 1; literals += b; if b != 255 { break } }
            }
            guard literals <= input.count - i, out.count + literals <= decodedSize else { return nil }
            out.append(contentsOf: input[i..<(i + literals)]); i += literals
            if i == input.count { break } // The last sequence has literals only.
            guard i + 2 <= input.count else { return nil }
            let offset = Int(input[i]) | Int(input[i + 1]) << 8; i += 2
            guard offset > 0, offset <= out.count else { return nil }
            var length = (token & 15) + 4
            if token & 15 == 15 {
                while true { guard i < input.count else { return nil }; let b = Int(input[i]); i += 1; length += b; if b != 255 { break } }
            }
            guard out.count + length <= decodedSize else { return nil }
            let start = out.count - offset
            for k in 0..<length { out.append(out[start + k]) } // Overlapping copies are allowed.
        }
        return out.count == decodedSize ? out : nil
    }

    /// A real LZ4 block from Apple's encoder (`COMPRESSION_LZ4_RAW` is the raw block format), for synthetic fixtures.
    static func encodeMozLz4(_ data: Data) -> Data? {
        var buffer = [UInt8](repeating: 0, count: data.count + data.count / 255 + 64)
        let n = data.withUnsafeBytes { src in
            compression_encode_buffer(&buffer, buffer.count, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZ4_RAW)
        }
        guard n > 0 else { return nil }
        let size = data.count
        return Data(magic + [UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24 & 0xFF)] + buffer[0..<n])
    }
}
