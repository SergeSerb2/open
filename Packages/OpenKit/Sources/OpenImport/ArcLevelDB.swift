import Foundation
import Darwin

/// Read-only LevelDB format reader. No LevelDB API, lock, recovery, or write is used.
/// Limits bound decoded allocations too: the largest single byte buffer is 32 MiB;
/// at most 100k current records and 64 MiB of record payloads are retained.
enum ArcCacheError: Error, CustomStringConvertible {
    case invalid, limit, unsafeCopy
    var description: String {
        switch self {
        case .invalid: "Boost cache is malformed or incomplete."
        case .limit: "Boost cache exceeds the import size limit."
        case .unsafeCopy: "Boost cache could not be copied safely."
        }
    }
}

struct ArcBytes {
    let bytes: [UInt8]
    var offset = 0
    var remaining: Int { bytes.count - offset }
    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else { throw ArcCacheError.invalid }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }
    mutating func byte() throws -> UInt8 {
        guard remaining > 0 else { throw ArcCacheError.invalid }
        defer { offset += 1 }; return bytes[offset]
    }
    mutating func fixed(_ count: Int) throws -> UInt64 {
        guard (1...8).contains(count) else { throw ArcCacheError.invalid }
        var value: UInt64 = 0
        for i in 0..<count { value |= UInt64(try byte()) << (8 * i) }
        return value
    }
    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<10 {
            let b = try byte()
            guard i < 9 || b <= 1 else { throw ArcCacheError.invalid }
            value |= UInt64(b & 127) << (7 * i)
            if b < 128 { return value }
        }
        throw ArcCacheError.invalid
    }
    mutating func count(limit: Int) throws -> Int {
        let n = try varint()
        guard n <= UInt64(limit) else { throw ArcCacheError.limit }
        return Int(n)
    }
    mutating func blob(limit: Int) throws -> [UInt8] { try take(count(limit: limit)) }
}

enum ArcLevelDB {
    static let maxFile = 32 * 1024 * 1024, maxTotal = 64 * 1024 * 1024
    static let maxBlock = 8 * 1024 * 1024, maxRecords = 100_000, maxKey = 4096
    struct Record { let sequence: UInt64; let value: [UInt8]? }

    /// The caller passes a private copy, never the original Firestore directory.
    static func read(copy: URL) throws -> [Data: Record] {
        let current = try file(copy.appendingPathComponent("CURRENT"), limit: 256)
        guard let raw = String(bytes: current, encoding: .utf8), raw.hasSuffix("\n") else { throw ArcCacheError.invalid }
        let manifest = String(raw.dropLast())
        guard manifest.hasPrefix("MANIFEST-"), !manifest.dropFirst(9).isEmpty,
              manifest.dropFirst(9).allSatisfy(\.isNumber) else { throw ArcCacheError.invalid }
        var tables: Set<UInt64> = [], logNumber: UInt64 = 0, previousLog: UInt64 = 0
        for record in try logRecords(file(copy.appendingPathComponent(manifest), limit: maxFile)) {
            var c = ArcBytes(bytes: record)
            while c.remaining > 0 {
                switch try c.varint() {
                case 1:
                    guard String(bytes: try c.blob(limit: 128), encoding: .utf8) == "leveldb.BytewiseComparator" else { throw ArcCacheError.invalid }
                case 2: logNumber = try c.varint()
                case 3, 4: _ = try c.varint()
                case 5: _ = try c.varint(); _ = try c.blob(limit: maxKey + 8)
                case 6: _ = try c.varint(); tables.remove(try c.varint())
                case 7:
                    _ = try c.varint(); let number = try c.varint(); _ = try c.varint()
                    _ = try c.blob(limit: maxKey + 8); _ = try c.blob(limit: maxKey + 8)
                    tables.insert(number)
                    guard tables.count <= 1024 else { throw ArcCacheError.limit }
                case 9: previousLog = try c.varint()
                default: throw ArcCacheError.invalid
                }
            }
        }
        var records: [Data: Record] = [:], retained = 0, visited = 0
        func apply(_ key: [UInt8], _ value: [UInt8]?, sequence: UInt64) throws {
            visited += 1
            guard visited <= 500_000, key.count <= maxKey else { throw ArcCacheError.limit }
            let id = Data(key)
            if let old = records[id], old.sequence >= sequence { return }
            retained -= records[id]?.value?.count ?? 0
            retained += value?.count ?? 0
            guard retained <= maxTotal, records.count < maxRecords || records[id] != nil else { throw ArcCacheError.limit }
            records[id] = Record(sequence: sequence, value: value)
        }
        var totalRead = 0
        for number in tables.sorted() {
            let base = String(format: "%06llu", number)
            let ldb = copy.appendingPathComponent(base + ".ldb")
            let url = FileManager.default.fileExists(atPath: ldb.path) ? ldb : copy.appendingPathComponent(base + ".sst")
            let bytes = try file(url, limit: maxFile); totalRead += bytes.count
            guard totalRead <= maxTotal else { throw ArcCacheError.limit }
            try table(bytes) { key, value in
                guard key.count >= 8 else { throw ArcCacheError.invalid }
                var tag = ArcBytes(bytes: Array(key.suffix(8)))
                let sequence = try tag.fixed(8), kind = sequence & 255
                guard kind <= 1 else { throw ArcCacheError.invalid }
                try apply(Array(key.dropLast(8)), kind == 0 ? nil : value, sequence: sequence)
            }
        }
        let files = try FileManager.default.contentsOfDirectory(at: copy, includingPropertiesForKeys: nil)
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "log" {
            guard let number = UInt64(url.deletingPathExtension().lastPathComponent), number >= logNumber || number == previousLog else { continue }
            let bytes = try file(url, limit: maxFile); totalRead += bytes.count
            guard totalRead <= maxTotal else { throw ArcCacheError.limit }
            for batch in try logRecords(bytes, allowTruncatedTail: true) {
                var c = ArcBytes(bytes: batch)
                let sequence = try c.fixed(8), count = try c.fixed(4)
                guard count <= UInt64(maxRecords), sequence <= (UInt64.max >> 8) - count else { throw ArcCacheError.limit }
                for index in 0..<count {
                    let kind = try c.byte(), key = try c.blob(limit: maxKey)
                    guard kind <= 1 else { throw ArcCacheError.invalid }
                    let value = kind == 1 ? try c.blob(limit: maxBlock) : nil
                    try apply(key, value, sequence: ((sequence + index) << 8) | UInt64(kind))
                }
                guard c.remaining == 0 else { throw ArcCacheError.invalid }
            }
        }
        return records
    }

    static func file(_ url: URL, limit: Int) throws -> [UInt8] {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ArcCacheError.unsafeCopy }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ArcCacheError.unsafeCopy }
        guard info.st_size >= 0, info.st_size <= limit else { throw ArcCacheError.limit }
        // Bound the read itself, including the live enablement file. A file
        // growing after fstat must not cause an unbounded Foundation allocation.
        let size = Int(info.st_size)
        let data = try handle.read(upToCount: size) ?? Data()
        let extra = try handle.read(upToCount: 1) ?? Data()
        guard data.count == size, extra.isEmpty else { throw ArcCacheError.invalid }
        return Array(data)
    }

    static func crc(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0x82f6_3b78 : 0) }
        }
        return ~crc
    }
    static func validCRC(_ data: [UInt8], _ masked: UInt64) -> Bool {
        let c = crc(data), expected = ((c >> 15) | (c << 17)) &+ 0xa282_ead8
        return UInt64(expected) == masked
    }

    static func logRecords(_ bytes: [UInt8], allowTruncatedTail: Bool = false) throws -> [[UInt8]] {
        var c = ArcBytes(bytes: bytes), fragments: [UInt8]? = nil, result: [[UInt8]] = []
        while c.remaining > 0 {
            let blockRemaining = 32768 - c.offset % 32768
            if blockRemaining < 7 {
                let padding = try c.take(min(blockRemaining, c.remaining))
                guard padding.allSatisfy({ $0 == 0 }) else { throw ArcCacheError.invalid }; continue
            }
            if c.remaining < 7 {
                if allowTruncatedTail { break }; throw ArcCacheError.invalid
            }
            let checksum = try c.fixed(4), length = Int(try c.fixed(2)), kind = try c.byte()
            if length == 0 && kind == 0 {
                let padding = try c.take(min(blockRemaining - 7, c.remaining))
                guard checksum == 0, padding.allSatisfy({ $0 == 0 }) else { throw ArcCacheError.invalid }; continue
            }
            guard length <= blockRemaining - 7 else { throw ArcCacheError.invalid }
            if length > c.remaining {
                if allowTruncatedTail { break }; throw ArcCacheError.invalid
            }
            let payload = try c.take(length)
            guard validCRC([kind] + payload, checksum) else { throw ArcCacheError.invalid }
            switch kind {
            case 1: guard fragments == nil else { throw ArcCacheError.invalid }; result.append(payload)
            case 2: guard fragments == nil else { throw ArcCacheError.invalid }; fragments = payload
            case 3, 4:
                guard fragments != nil, fragments!.count + payload.count <= maxBlock else { throw ArcCacheError.invalid }
                fragments! += payload
                if kind == 4 { result.append(fragments!); fragments = nil }
            default: throw ArcCacheError.invalid
            }
            guard result.count <= maxRecords else { throw ArcCacheError.limit }
        }
        guard fragments == nil || allowTruncatedTail else { throw ArcCacheError.invalid }
        return result
    }

    private static func table(_ bytes: [UInt8], visit: ([UInt8], [UInt8]) throws -> Void) throws {
        guard bytes.count >= 48 else { throw ArcCacheError.invalid }
        var footer = ArcBytes(bytes: Array(bytes.suffix(48)))
        _ = try footer.varint(); _ = try footer.varint()
        let indexOffset = try footer.count(limit: bytes.count), indexSize = try footer.count(limit: maxBlock)
        footer.offset = 40
        guard try footer.fixed(8) == 0xdb47_7524_8b80_fb57 else { throw ArcCacheError.invalid }
        func block(_ offset: Int, _ size: Int) throws -> [UInt8] {
            guard size <= maxBlock, offset <= bytes.count - 48, size + 5 <= bytes.count - 48 - offset else { throw ArcCacheError.invalid }
            var c = ArcBytes(bytes: Array(bytes[offset..<offset + size + 5]))
            let payload = try c.take(size), kind = try c.byte(), checksum = try c.fixed(4)
            guard validCRC(payload + [kind], checksum) else { throw ArcCacheError.invalid }
            switch kind {
            case 0: return payload
            case 1: return try snappy(payload)
            default: throw ArcCacheError.invalid
            }
        }
        try blockEntries(block(indexOffset, indexSize)) { _, value in
            var handle = ArcBytes(bytes: value)
            let offset = try handle.count(limit: bytes.count), size = try handle.count(limit: maxBlock)
            guard handle.remaining == 0 else { throw ArcCacheError.invalid }
            try blockEntries(block(offset, size), visit: visit)
        }
    }

    private static func blockEntries(_ bytes: [UInt8], visit: ([UInt8], [UInt8]) throws -> Void) throws {
        guard bytes.count >= 4 else { throw ArcCacheError.invalid }
        var trailer = ArcBytes(bytes: Array(bytes.suffix(4)))
        let restarts = Int(try trailer.fixed(4))
        guard restarts > 0, restarts <= (bytes.count - 4) / 4 else { throw ArcCacheError.invalid }
        let end = bytes.count - 4 - restarts * 4
        var restartCursor = ArcBytes(bytes: Array(bytes[end..<bytes.count - 4])), restartOffsets: Set<Int> = [], previous = -1
        for _ in 0..<restarts {
            let offset = Int(try restartCursor.fixed(4))
            guard offset > previous, offset < end || (end == 0 && offset == 0) else { throw ArcCacheError.invalid }
            restartOffsets.insert(offset); previous = offset
        }
        guard restartOffsets.contains(0) else { throw ArcCacheError.invalid }
        var c = ArcBytes(bytes: Array(bytes.prefix(end))), key: [UInt8] = [], count = 0
        while c.remaining > 0 {
            let start = c.offset, shared = try c.count(limit: maxKey + 8), suffix = try c.count(limit: maxKey + 8), size = try c.count(limit: maxBlock)
            guard shared <= key.count, shared + suffix <= maxKey + 8,
                  !restartOffsets.contains(start) || shared == 0 else { throw ArcCacheError.invalid }
            restartOffsets.remove(start)
            key = Array(key.prefix(shared)) + (try c.take(suffix))
            try visit(key, c.take(size)); count += 1
            guard count <= maxRecords else { throw ArcCacheError.limit }
        }
        guard restartOffsets.isEmpty || end == 0 else { throw ArcCacheError.invalid }
    }

    static func snappy(_ bytes: [UInt8]) throws -> [UInt8] {
        var c = ArcBytes(bytes: bytes)
        let size = try c.count(limit: maxBlock)
        var output: [UInt8] = []; output.reserveCapacity(size)
        while c.remaining > 0 {
            let tag = try c.byte(), kind = tag & 3
            var length = Int(tag >> 2), distance = 0
            if kind == 0 {
                if length < 60 { length += 1 }
                else { length = Int(try c.fixed(length - 59)) + 1 }
                guard length <= size - output.count else { throw ArcCacheError.invalid }
                output += try c.take(length)
            } else {
                switch kind {
                case 1: length = 4 + Int((tag >> 2) & 7); distance = Int(tag & 224) << 3 | Int(try c.byte())
                case 2: length += 1; distance = Int(try c.fixed(2))
                default: length += 1; distance = Int(try c.fixed(4))
                }
                guard distance > 0, distance <= output.count, length <= size - output.count else { throw ArcCacheError.invalid }
                for _ in 0..<length { output.append(output[output.count - distance]) }
            }
        }
        guard output.count == size else { throw ArcCacheError.invalid }
        return output
    }
}
