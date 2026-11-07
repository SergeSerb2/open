import Foundation
import Darwin

/// Only the remote_document keyspace is consumed. Targets, mutations, and index
/// metadata are never interpreted as Boosts, even if their bytes contain a path.
struct ArcFirestoreDocument {
    var id: String
    var fields: [String: ArcFirestoreValue]
    var createdAt: Date?
    var updatedAt: Date?
}
indirect enum ArcFirestoreValue {
    case string(String), integer(Int64), number(Double), bool(Bool), null
    case map([String: ArcFirestoreValue]), array([ArcFirestoreValue]), timestamp(Date), unsupported
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var number: Double? {
        switch self { case .number(let n): n; case .integer(let n): Double(n); default: nil }
    }
    var date: Date? { if case .timestamp(let d) = self { return d }; return nil }
    var map: [String: ArcFirestoreValue]? { if case .map(let m) = self { return m }; return nil }
}
struct ArcFirestoreRead {
    var documents: [ArcFirestoreDocument] = []
    var deleted = 0, unknown = 0, otherCollections = 0, malformed = 0
}

enum ArcFirestore {
    static let documentLimit = 2 * 1024 * 1024, stringLimit = 1024 * 1024
    struct Field {
        let number: UInt64, wire: UInt64
        var bytes: [UInt8] = []
        var numberValue: UInt64 = 0
    }
    static func fields(_ bytes: [UInt8]) throws -> [Field] {
        var c = ArcBytes(bytes: bytes), result: [Field] = []
        while c.remaining > 0 {
            let tag = try c.varint(), wire = tag & 7, number = tag >> 3
            guard number > 0, number < 1 << 29 else { throw ArcCacheError.invalid }
            var f = Field(number: number, wire: wire)
            switch wire {
            case 0: f.numberValue = try c.varint()
            case 1: f.numberValue = try c.fixed(8)
            case 2: f.bytes = try c.blob(limit: documentLimit)
            case 5: f.numberValue = try c.fixed(4)
            default: throw ArcCacheError.invalid
            }
            result.append(f)
            guard result.count <= 4096 else { throw ArcCacheError.limit }
        }
        return result
    }
    static func string(_ f: Field?, limit: Int = stringLimit) throws -> String {
        guard let f, f.wire == 2, f.bytes.count <= limit,
              let s = String(bytes: f.bytes, encoding: .utf8) else { throw ArcCacheError.invalid }
        return s
    }
    static func timestamp(_ bytes: [UInt8]) throws -> Date {
        let parts = try fields(bytes)
        guard parts.filter({ $0.number == 1 || $0.number == 2 }).allSatisfy({ $0.wire == 0 }) else { throw ArcCacheError.invalid }
        let seconds = Int64(bitPattern: parts.last { $0.number == 1 }?.numberValue ?? 0)
        let nanos = parts.last { $0.number == 2 }?.numberValue ?? 0
        guard nanos < 1_000_000_000, (-62_135_596_800...253_402_300_799).contains(seconds) else { throw ArcCacheError.invalid }
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1e9)
    }
    static func value(_ bytes: [UInt8], depth: Int) throws -> ArcFirestoreValue {
        guard depth < 16 else { throw ArcCacheError.limit }
        let items = try fields(bytes)
        guard items.count == 1, let f = items.first else { throw ArcCacheError.invalid }
        switch (f.number, f.wire) {
        case (17, 2): return .string(try string(f))
        case (1, 0): guard f.numberValue <= 1 else { throw ArcCacheError.invalid }; return .bool(f.numberValue == 1)
        case (2, 0): return .integer(Int64(bitPattern: f.numberValue))
        case (3, 1):
            let number = Double(bitPattern: f.numberValue)
            return number.isFinite ? .number(number) : .unsupported
        case (6, 2): return .map(try map(f.bytes, fieldNumber: 1, depth: depth + 1))
        case (9, 2):
            let entries = try fields(f.bytes)
            guard entries.count <= 1024, entries.allSatisfy({ $0.number == 1 && $0.wire == 2 }) else { throw ArcCacheError.limit }
            return .array(try entries.map { try value($0.bytes, depth: depth + 1) })
        case (10, 2): return .timestamp(try timestamp(f.bytes))
        case (11, 0): return .null
        default: return .unsupported
        }
    }
    static func map(_ bytes: [UInt8], fieldNumber: UInt64, depth: Int) throws -> [String: ArcFirestoreValue] {
        var result: [String: ArcFirestoreValue] = [:]
        for f in try fields(bytes) where f.number == fieldNumber {
            guard f.wire == 2, result.count < 128 else { throw ArcCacheError.limit }
            let parts = try fields(f.bytes)
            let key = try string(parts.last { $0.number == 1 }, limit: 256)
            guard let payload = parts.last(where: { $0.number == 2 }), payload.wire == 2, result[key] == nil else { throw ArcCacheError.invalid }
            result[key] = try value(payload.bytes, depth: depth)
        }
        return result
    }
    static func read(copy: URL) throws -> ArcFirestoreRead {
        let records = try ArcLevelDB.read(copy: copy)
        let prefix = Data([0x85] + Array("remote_document".utf8) + [0, 1])
        var result = ArcFirestoreRead()
        for (key, record) in records where key.starts(with: prefix) {
            guard let bytes = record.value else { continue }
            do {
                guard bytes.count <= documentLimit else { throw ArcCacheError.limit }
                let wrapper = try fields(bytes)
                let variants = wrapper.filter { (1...3).contains($0.number) }
                guard variants.count == 1, let variant = variants.first, variant.wire == 2 else { throw ArcCacheError.invalid }
                let contents = try fields(variant.bytes)
                let name = try string(contents.last { $0.number == 1 }, limit: 4096)
                let path = name.components(separatedBy: "/")
                guard path.count >= 7, path[0] == "projects", path[1] == "bcny-arc-server",
                      path[2] == "databases", path[3] == "(default)", path[4] == "documents" else { throw ArcCacheError.invalid }
                guard path.count == 7, path[5] == "boosts" else { result.otherCollections += 1; continue }
                guard !path[6].isEmpty, path[6].utf8.count <= 256 else { throw ArcCacheError.invalid }
                if variant.number == 1 { result.deleted += 1; continue }
                if variant.number == 3 { result.unknown += 1; continue }
                func documentTime(_ number: UInt64) throws -> Date? {
                    guard let field = contents.last(where: { $0.number == number }) else { return nil }
                    guard field.wire == 2 else { throw ArcCacheError.invalid }
                    return try timestamp(field.bytes)
                }
                let created = try documentTime(3), updated = try documentTime(4)
                let document = ArcFirestoreDocument(id: path[6], fields: try map(variant.bytes, fieldNumber: 2, depth: 0), createdAt: created, updatedAt: updated)
                guard result.documents.count < 4096 else { throw ArcCacheError.limit }
                result.documents.append(document)
            } catch { result.malformed += 1 }
        }
        return result
    }

    /// Copy the entire flat cache directory. Original files are O_RDONLY and
    /// O_NOFOLLOW. No lock or database API ever sees their original URLs.
    static func privateCopy<T>(_ source: URL, read: (URL) throws -> T) throws -> T {
        let fm = FileManager.default
        let info = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw ArcCacheError.unsafeCopy }
        let temporary = fm.temporaryDirectory.appendingPathComponent("open-boost-cache-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let files = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        guard files.count <= 256 else { throw ArcCacheError.limit }
        var total = 0
        for file in files {
            guard !Task.isCancelled else { throw CancellationError() }
            let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ArcCacheError.unsafeCopy }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var before = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw ArcCacheError.unsafeCopy }
            guard before.st_size >= 0, before.st_size <= ArcLevelDB.maxFile else { throw ArcCacheError.limit }
            total += Int(before.st_size)
            guard total <= ArcLevelDB.maxTotal else { throw ArcCacheError.limit }
            let destination = temporary.appendingPathComponent(file.lastPathComponent)
            guard fm.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ArcCacheError.unsafeCopy }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var remaining = Int(before.st_size)
            while remaining > 0 {
                guard !Task.isCancelled else { throw CancellationError() }
                guard let data = try handle.read(upToCount: min(65536, remaining)), !data.isEmpty else { throw ArcCacheError.unsafeCopy }
                try output.write(contentsOf: data); remaining -= data.count
            }
            try output.close()
            var after = stat()
            guard fstat(fd, &after) == 0, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw ArcCacheError.unsafeCopy }
        }
        return try read(temporary)
    }
}
