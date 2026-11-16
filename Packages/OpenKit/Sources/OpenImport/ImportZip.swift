import Foundation
import Compression

/// Minimal read-only ZIP for user-picked export archives (Safari "Export Browsing Data").
/// Stored (0) and deflate (8) members only; no encryption, no ZIP64, bounded sizes.
/// The format is public (PKWARE APPNOTE). Our own implementation.
public struct ImportZipArchive: Sendable {
    public struct Member: Sendable { public var name: String; var method: UInt16; var compressedSize: Int; var size: Int; var localOffset: Int; var crc: UInt32 }
    public enum ZipError: Error, Equatable { case unreadable, notZip, unsupported, tooLarge, corrupt }

    public static let maxArchiveBytes = 512 << 20
    public static let maxMemberBytes = 256 << 20
    private let data: Data
    public let members: [Member]

    public init(url: URL) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue else { throw ZipError.unreadable }
        guard size <= Self.maxArchiveBytes else { throw ZipError.tooLarge }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw ZipError.unreadable }
        try self.init(data: data)
    }

    public init(data: Data) throws {
        self.data = data
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> UInt16 { UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
        guard bytes.count >= 22 else { throw ZipError.notZip }
        // End of central directory: last 22 bytes plus up to 64 KiB of comment.
        var eocd = -1
        var o = bytes.count - 22
        while o >= max(0, bytes.count - 22 - 0xFFFF) {
            if u32(o) == 0x0605_4B50 { eocd = o; break }
            o -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        let count = Int(u16(eocd + 10)), cdSize = Int(u32(eocd + 12)), cdOffset = Int(u32(eocd + 16))
        guard count < 0xFFFF, cdOffset < 0xFFFF_FFFF, cdOffset + cdSize <= eocd else { throw ZipError.unsupported }
        var members: [Member] = []
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(p) == 0x0201_4B50 else { throw ZipError.corrupt }
            let flags = u16(p + 8), method = u16(p + 10), crc = u32(p + 16)
            let csize = Int(u32(p + 20)), usize = Int(u32(p + 24))
            let nameLength = Int(u16(p + 28)), extraLength = Int(u16(p + 30)), commentLength = Int(u16(p + 32))
            let local = Int(u32(p + 42))
            guard p + 46 + nameLength <= bytes.count else { throw ZipError.corrupt }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            p += 46 + nameLength + extraLength + commentLength
            guard flags & 1 == 0 else { throw ZipError.unsupported }
            if name.hasSuffix("/") { continue }
            members.append(Member(name: name, method: method, compressedSize: csize, size: usize, localOffset: local, crc: crc))
        }
        self.members = members
    }

    /// The first member whose file name (ignoring folders and case) matches.
    public func member(where match: (String) -> Bool) -> Member? {
        members.first { member in
            let base = (member.name as NSString).lastPathComponent
            return !base.hasPrefix("._") && !member.name.hasPrefix("__MACOSX/") && match(base.lowercased())
        }
    }

    public func extract(_ member: Member) throws -> Data {
        guard member.size <= Self.maxMemberBytes, member.compressedSize <= Self.maxArchiveBytes else { throw ZipError.tooLarge }
        let o = member.localOffset
        guard o + 30 <= data.count else { throw ZipError.corrupt }
        let header = [UInt8](data[o..<(o + 30)])
        guard header[0] == 0x50, header[1] == 0x4B, header[2] == 3, header[3] == 4 else { throw ZipError.corrupt }
        let start = o + 30 + (Int(header[26]) | Int(header[27]) << 8) + (Int(header[28]) | Int(header[29]) << 8)
        guard start + member.compressedSize <= data.count else { throw ZipError.corrupt }
        let body = data[start..<(start + member.compressedSize)]
        let out: Data
        switch member.method {
        case 0: out = Data(body)
        case 8:
            guard member.size > 0 else { return Data() }
            // A truncated or hand-made archive can claim bytes with an empty body; an empty
            // buffer has no base address.
            guard !body.isEmpty else { throw ZipError.corrupt }
            var buffer = [UInt8](repeating: 0, count: member.size)
            let written = body.withUnsafeBytes { source in
                compression_decode_buffer(&buffer, member.size, source.bindMemory(to: UInt8.self).baseAddress!, body.count, nil, COMPRESSION_ZLIB)
            }
            guard written == member.size else { throw ZipError.corrupt }
            out = Data(buffer)
        default: throw ZipError.unsupported
        }
        guard out.count == member.size, Self.crc32(out) == member.crc else { throw ZipError.corrupt }
        return out
    }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// Writes a ZIP (synthetic fixtures only). `deflate` members use raw deflate.
    static func write(_ entries: [(name: String, data: Data, deflate: Bool)], to url: URL) throws {
        var out = Data(), central = Data()
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
        for entry in entries {
            var body = entry.data
            if entry.deflate {
                var buffer = [UInt8](repeating: 0, count: entry.data.count + 1024)
                let n = entry.data.withUnsafeBytes { src in
                    compression_encode_buffer(&buffer, buffer.count, src.bindMemory(to: UInt8.self).baseAddress!, entry.data.count, nil, COMPRESSION_ZLIB)
                }
                guard n > 0 else { throw ZipError.corrupt }
                body = Data(buffer[0..<n])
            }
            let crc = crc32(entry.data), name = Array(entry.name.utf8), offset = UInt32(out.count)
            let method = entry.deflate ? 8 : 0
            out.append(contentsOf: le32(0x0403_4B50) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0x21)
                       + le32(crc) + le32(UInt32(body.count)) + le32(UInt32(entry.data.count)) + le16(name.count) + le16(0) + name)
            out.append(body)
            central.append(contentsOf: le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0x21)
                           + le32(crc) + le32(UInt32(body.count)) + le32(UInt32(entry.data.count)) + le16(name.count)
                           + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + name)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.append(contentsOf: le32(0x0605_4B50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
                   + le32(UInt32(central.count)) + le32(cdOffset) + le16(0))
        try out.write(to: url)
    }
}
