import AppKit
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

public struct FaviconImage: Sendable {
    public let png32: Data
    public let png64: Data?
    public let iconURL: URL?
}

public struct FaviconStatistics: Sendable {
    public let ok: Int
    public let missing: Int
    public let failed: Int
    public let totalBytes: Int
    public var count: Int { ok + missing + failed }
}

public enum FaviconStoreError: Error, Sendable {
    case invalidURL, database, invalidImage
}

/// Canonical network origin, without credentials, path, query, or fragment.
enum FaviconOrigin {
    static func key(_ url: URL) -> String? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        parts.scheme = scheme
        parts.host = host
        parts.user = nil
        parts.password = nil
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.string
    }

    static func pageKey(_ url: URL) -> String {
        let path = url.path(percentEncoded: true)
        return path.isEmpty ? "/" : path
    }
}

/// Owns the connection and statements together so they can be finalized on actor teardown.
/// Like SQLiteDB, this holder is used only by its owning actor after initialization.
private final class FaviconStatements: @unchecked Sendable {
    let db: SQLiteDB
    let lookup: OpaquePointer
    let freshness: OpaquePointer
    let upsert: OpaquePointer
    let purge: OpaquePointer
    let count: OpaquePointer
    let stats: OpaquePointer

    init(databaseURL: URL) throws {
        guard databaseURL.isFileURL else { throw FaviconStoreError.invalidURL }
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let connection = try SQLiteDB(path: databaseURL.path)
        db = connection
        guard connection.exec("PRAGMA busy_timeout=3000;"), connection.exec("""
            CREATE TABLE IF NOT EXISTS favicons(
              origin TEXT NOT NULL, page_key TEXT NOT NULL, icon_url TEXT,
              png32 BLOB, png64 BLOB, fetched_at REAL NOT NULL,
              expires_at REAL NOT NULL, status INTEGER NOT NULL,
              PRIMARY KEY(origin, page_key));
            """) else { throw FaviconStoreError.database }
        var prepared: [OpaquePointer] = []
        func prepare(_ sql: String) throws -> OpaquePointer {
            guard let stmt = connection.prepare(sql) else {
                for previous in prepared { sqlite3_finalize(previous) }
                throw FaviconStoreError.database
            }
            prepared.append(stmt)
            return stmt
        }
        lookup = try prepare("SELECT png32,png64,icon_url FROM favicons WHERE origin=? AND page_key IN (?, '') AND status=0 AND png32 IS NOT NULL ORDER BY length(page_key) DESC LIMIT 1")
        freshness = try prepare("SELECT status FROM favicons WHERE origin=? AND page_key IN (?, '') AND expires_at>? ORDER BY length(page_key) DESC LIMIT 1")
        upsert = try prepare("""
            INSERT INTO favicons(origin,page_key,icon_url,png32,png64,fetched_at,expires_at,status)
            VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(origin,page_key) DO UPDATE SET
            icon_url=excluded.icon_url,png32=excluded.png32,png64=excluded.png64,
            fetched_at=excluded.fetched_at,expires_at=excluded.expires_at,status=excluded.status
            """)
        purge = try prepare("DELETE FROM favicons WHERE fetched_at<?")
        count = try prepare("SELECT count(*) FROM favicons")
        stats = try prepare("SELECT status,count(*),coalesce(sum(coalesce(length(png32),0)+coalesce(length(png64),0)),0) FROM favicons GROUP BY status")
    }

    deinit {
        for stmt in [lookup, freshness, upsert, purge, count, stats] { sqlite3_finalize(stmt) }
    }
}

/// Persistent sidebar icons. Decoding, drawing, and SQLite access stay on this actor.
public actor FaviconStore {
    private let statements: FaviconStatements

    public init(databaseURL: URL) throws {
        statements = try FaviconStatements(databaseURL: databaseURL)
    }

    /// Prefer a page-specific image; keep stale images visible while a refresh is due.
    public func icon(for pageURL: URL) -> FaviconImage? {
        guard let origin = FaviconOrigin.key(pageURL) else { return nil }
        let stmt = statements.lookup
        defer { reset(stmt) }
        statements.db.bindText(stmt, 1, origin)
        statements.db.bindText(stmt, 2, FaviconOrigin.pageKey(pageURL))
        guard sqlite3_step(stmt) == SQLITE_ROW, let png32 = blob(stmt, 0) else { return nil }
        return FaviconImage(png32: png32, png64: blob(stmt, 1), iconURL: statements.db.columnText(stmt, 2).flatMap(URL.init(string:)))
    }

    public func ingest(imageData: Data, iconURL: URL?, for pageURL: URL, pageSpecific: Bool) throws {
        guard let origin = FaviconOrigin.key(pageURL) else { throw FaviconStoreError.invalidURL }
        let pngs = try autoreleasepool { () throws -> (Data, Data) in
            let image = try Self.decode(imageData)
            return (try Self.png(image, size: 32), try Self.png(image, size: 64))
        }
        try write(origin: origin, pageKey: pageSpecific ? FaviconOrigin.pageKey(pageURL) : "",
                  iconURL: iconURL, png32: pngs.0, png64: pngs.1, status: 0, lifetime: 7 * 86400)
    }

    public func markMissing(for pageURL: URL) {
        guard let origin = FaviconOrigin.key(pageURL) else { return }
        try? write(origin: origin, pageKey: "", status: 1, lifetime: 86400)
    }

    public func needsFetch(_ pageURL: URL, now: Date = .now) -> Bool {
        cachedStatus(for: pageURL, now: now) == nil
    }

    public func purge(olderThan: Date) -> Int {
        let stmt = statements.purge
        defer { reset(stmt) }
        statements.db.bindDouble(stmt, 1, olderThan.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        return Int(statements.db.changes)
    }

    public func count() -> Int {
        let stmt = statements.count
        defer { reset(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(statements.db.columnInt(stmt, 0)) : 0
    }

    public func statistics() -> FaviconStatistics {
        let stmt = statements.stats
        defer { reset(stmt) }
        var counts = [0, 0, 0], bytes = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let status = Int(statements.db.columnInt(stmt, 0))
            if counts.indices.contains(status) { counts[status] = Int(statements.db.columnInt(stmt, 1)) }
            bytes += Int(statements.db.columnInt(stmt, 2))
        }
        return FaviconStatistics(ok: counts[0], missing: counts[1], failed: counts[2], totalBytes: bytes)
    }

    func cachedStatus(for pageURL: URL, now: Date = .now) -> Int? {
        guard let origin = FaviconOrigin.key(pageURL) else { return nil }
        let stmt = statements.freshness
        defer { reset(stmt) }
        statements.db.bindText(stmt, 1, origin)
        statements.db.bindText(stmt, 2, FaviconOrigin.pageKey(pageURL))
        statements.db.bindDouble(stmt, 3, now.timeIntervalSince1970)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(statements.db.columnInt(stmt, 0)) : nil
    }

    func markError(for pageURL: URL) {
        guard let origin = FaviconOrigin.key(pageURL) else { return }
        try? write(origin: origin, pageKey: "", status: 2, lifetime: 86400)
    }

    private func write(origin: String, pageKey: String, iconURL: URL? = nil, png32: Data? = nil,
                       png64: Data? = nil, status: Int, lifetime: TimeInterval) throws {
        let stmt = statements.upsert, db = statements.db
        defer { reset(stmt) }
        let now = Date().timeIntervalSince1970
        db.bindText(stmt, 1, origin)
        db.bindText(stmt, 2, pageKey)
        db.bindText(stmt, 3, iconURL?.absoluteString)
        bindBlob(stmt, 4, png32)
        bindBlob(stmt, 5, png64)
        db.bindDouble(stmt, 6, now)
        db.bindDouble(stmt, 7, now + lifetime)
        db.bindInt(stmt, 8, Int64(status))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw FaviconStoreError.database }
    }

    private func reset(_ stmt: OpaquePointer) {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    private func bindBlob(_ stmt: OpaquePointer, _ index: Int32, _ data: Data?) {
        guard let data else { sqlite3_bind_null(stmt, index); return }
        _ = data.withUnsafeBytes {
            sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    private func blob(_ stmt: OpaquePointer, _ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, index)))
    }

    private static func decode(_ data: Data) throws -> CGImage {
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(source) > 0 {
            var index = 0
            if CGImageSourceGetType(source).map({ UTType($0 as String)?.conforms(to: .ico) == true }) == true {
                var best = Int.max
                for candidate in 0..<CGImageSourceGetCount(source) {
                    let properties = CGImageSourceCopyPropertiesAtIndex(source, candidate, nil) as? [CFString: Any]
                    let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
                    let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
                    let distance = abs(max(width, height) - 64)
                    if distance < best { best = distance; index = candidate }
                }
            }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                          kCGImageSourceThumbnailMaxPixelSize: 64]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) { return image }
        }
        // AppKit's SVG decoder is optional. Its objects stay local to this actor call.
        if let text = String(data: data.prefix(4096), encoding: .utf8), text.range(of: "<svg", options: .caseInsensitive) != nil,
           let image = NSImage(data: data) {
            var rect = CGRect(x: 0, y: 0, width: 64, height: 64)
            if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) { return cgImage }
        }
        throw FaviconStoreError.invalidImage
    }

    private static func png(_ image: CGImage, size: Int) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FaviconStoreError.invalidImage
        }
        context.interpolationQuality = .high
        let side = CGFloat(size), scale = side / CGFloat(max(image.width, image.height))
        let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(image, in: CGRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height))
        guard let result = context.makeImage() else { throw FaviconStoreError.invalidImage }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw FaviconStoreError.invalidImage
        }
        CGImageDestinationAddImage(destination, result, nil)
        guard CGImageDestinationFinalize(destination) else { throw FaviconStoreError.invalidImage }
        return data as Data
    }
}
