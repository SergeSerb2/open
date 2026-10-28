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
    case invalidURL, database, databaseTooLarge, invalidImage
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
        // One actor serializes reads/writes, so this cache does not need WAL.
        // Cap growth before schema writes. A rollback journal contains at most
        // one copy of each database page: database + journal stay below 34 MiB.
        guard connection.exec("PRAGMA busy_timeout=3000; PRAGMA journal_mode=TRUNCATE; PRAGMA page_size=4096; PRAGMA max_page_count=4096; PRAGMA journal_size_limit=0;"),
              let pageSize = connection.prepare("PRAGMA page_size") else { throw FaviconStoreError.database }
        let normalPages = sqlite3_step(pageSize) == SQLITE_ROW && connection.columnInt(pageSize, 0) == 4096
        sqlite3_finalize(pageSize)
        guard normalPages, connection.exec("""
            CREATE TABLE IF NOT EXISTS favicons(
              origin TEXT NOT NULL, page_key TEXT NOT NULL, icon_url TEXT,
              png32 BLOB, png64 BLOB, fetched_at REAL NOT NULL,
              expires_at REAL NOT NULL, status INTEGER NOT NULL,
              PRIMARY KEY(origin, page_key));
            CREATE INDEX IF NOT EXISTS favicon_age ON favicons(fetched_at);
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
        lookup = try prepare("SELECT png32,png64,icon_url FROM favicons WHERE origin=? AND page_key IN (?, '') AND status=0 AND png32 IS NOT NULL AND length(png32)<=32768 AND coalesce(length(png64),0)<=32768 ORDER BY length(page_key) DESC LIMIT 1")
        freshness = try prepare("SELECT status FROM favicons WHERE origin=? AND page_key='' AND expires_at>?")
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
    public static let maximumInputBytes = 512 * 1024
    public static let maximumDimension = 1024
    public static let maximumEntries = 4096
    public static let maximumStoredBytes = 8 * 1024 * 1024
    public static let maximumDatabaseBytes = 16 * 1024 * 1024
    private let databaseURL: URL
    private var connection: FaviconStatements?

    /// No file access here: callers may construct the actor on the main thread.
    public init(databaseURL: URL) throws {
        guard databaseURL.isFileURL else { throw FaviconStoreError.invalidURL }
        self.databaseURL = databaseURL
    }

    private func open() throws -> FaviconStatements {
        if let connection { return connection }
        // Refuse oversized existing input before SQLite opens it. Do not run
        // VACUUM: its temporary database would escape the cache's disk budget.
        let size = (try? FileManager.default.attributesOfItem(atPath: databaseURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maximumDatabaseBytes else { throw FaviconStoreError.databaseTooLarge }
        let opened = try FaviconStatements(databaseURL: databaseURL)
        try enforceLimits(opened, legacy: true)
        connection = opened
        return opened
    }

    public static func cacheKey(_ url: URL) -> String? {
        guard url.absoluteString.utf8.count <= 8192, let origin = FaviconOrigin.key(url) else { return nil }
        return origin + "\n" + FaviconOrigin.pageKey(url)
    }

    /// ImageIO decoding finishes on this actor. The UI only wraps a 64 px bitmap.
    public func decodedIcon(for url: URL) -> CGImage? {
        guard let icon = icon(for: url) else { return nil }
        let data = icon.png64 ?? icon.png32
        return try? Self.decode(data)
    }

    /// Prefer a page-specific image; keep stale images visible while a refresh is due.
    public func icon(for pageURL: URL) -> FaviconImage? {
        guard Self.cacheKey(pageURL) != nil, let origin = FaviconOrigin.key(pageURL), let statements = try? open() else { return nil }
        let stmt = statements.lookup
        defer { reset(stmt) }
        statements.db.bindText(stmt, 1, origin)
        statements.db.bindText(stmt, 2, FaviconOrigin.pageKey(pageURL))
        guard sqlite3_step(stmt) == SQLITE_ROW, let png32 = blob(stmt, 0) else { return nil }
        return FaviconImage(png32: png32, png64: blob(stmt, 1), iconURL: statements.db.columnText(stmt, 2).flatMap(URL.init(string:)))
    }

    public func ingest(imageData: Data, iconURL: URL?, for pageURL: URL, pageSpecific: Bool) throws {
        guard Self.cacheKey(pageURL) != nil, let origin = FaviconOrigin.key(pageURL), (iconURL?.absoluteString.utf8.count ?? 0) <= 8192 else { throw FaviconStoreError.invalidURL }
        guard imageData.count <= Self.maximumInputBytes else { throw FaviconStoreError.invalidImage }
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

    /// Prefetch freshness is origin-only; page-specific images do not cover other pages.
    public func needsFetch(_ pageURL: URL, now: Date = .now) -> Bool {
        cachedStatus(for: pageURL, now: now) == nil
    }

    public func purge(olderThan: Date) -> Int {
        guard let statements = try? open() else { return 0 }
        let stmt = statements.purge
        defer { reset(stmt) }
        statements.db.bindDouble(stmt, 1, olderThan.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        return Int(statements.db.changes)
    }

    public func count() -> Int {
        guard let statements = try? open() else { return 0 }
        let stmt = statements.count
        defer { reset(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(statements.db.columnInt(stmt, 0)) : 0
    }

    public func statistics() -> FaviconStatistics {
        guard let statements = try? open() else { return FaviconStatistics(ok: 0, missing: 0, failed: 0, totalBytes: 0) }
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
        guard let origin = FaviconOrigin.key(pageURL), let statements = try? open() else { return nil }
        let stmt = statements.freshness
        defer { reset(stmt) }
        statements.db.bindText(stmt, 1, origin)
        statements.db.bindDouble(stmt, 2, now.timeIntervalSince1970)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(statements.db.columnInt(stmt, 0)) : nil
    }

    func markError(for pageURL: URL) {
        guard let origin = FaviconOrigin.key(pageURL) else { return }
        try? write(origin: origin, pageKey: "", status: 2, lifetime: 86400)
    }

    private func write(origin: String, pageKey: String, iconURL: URL? = nil, png32: Data? = nil,
                       png64: Data? = nil, status: Int, lifetime: TimeInterval) throws {
        guard origin.utf8.count <= 8192, pageKey.utf8.count <= 8192 else { throw FaviconStoreError.invalidURL }
        let statements = try open(), stmt = statements.upsert, db = statements.db
        guard db.exec("BEGIN IMMEDIATE") else { throw FaviconStoreError.database }
        var committed = false
        defer { reset(stmt); if !committed { db.exec("ROLLBACK") } }
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
        reset(stmt)
        try enforceLimits(statements)
        guard db.exec("COMMIT") else { throw FaviconStoreError.database }
        committed = true
    }

    private func enforceLimits(_ statements: FaviconStatements, legacy: Bool = false) throws {
        let db = statements.db
        // Cap legacy counts in one SQL operation before the bounded byte loop.
        if legacy, !db.exec("DELETE FROM favicons WHERE rowid NOT IN (SELECT rowid FROM favicons ORDER BY fetched_at DESC,rowid DESC LIMIT \(Self.maximumEntries))") { throw FaviconStoreError.database }
        guard let usage = db.prepare("SELECT count(*),coalesce(sum(length(CAST(origin AS BLOB))+length(CAST(page_key AS BLOB))+coalesce(length(CAST(icon_url AS BLOB)),0)+coalesce(length(png32),0)+coalesce(length(png64),0)),0) FROM favicons") else { throw FaviconStoreError.database }
        defer { sqlite3_finalize(usage) }
        // At most 4096 iterations, including keys/URLs as UTF-8 bytes.
        for _ in 0...Self.maximumEntries {
            guard sqlite3_step(usage) == SQLITE_ROW else { throw FaviconStoreError.database }
            let count = Int(db.columnInt(usage, 0)), bytes = Int(db.columnInt(usage, 1))
            reset(usage)
            if count <= Self.maximumEntries && bytes <= Self.maximumStoredBytes { return }
            guard db.exec("DELETE FROM favicons WHERE rowid=(SELECT rowid FROM favicons ORDER BY fetched_at,rowid LIMIT 1)") else { throw FaviconStoreError.database }
        }
        throw FaviconStoreError.database
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
           CGImageSourceGetCount(source) > 0, CGImageSourceGetCount(source) <= 32 {
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
            // Read the selected frame's dimensions before asking ImageIO to decode it.
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  let depth = properties[kCGImagePropertyDepth] as? NSNumber, (1...8).contains(depth.intValue),
                  (1...Double(maximumDimension)).contains(width.doubleValue), (1...Double(maximumDimension)).contains(height.doubleValue) else {
                throw FaviconStoreError.invalidImage
            }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                          kCGImageSourceThumbnailMaxPixelSize: 64]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) { return image }
        }
        // Reject unsupported/vector input before AppKit can rasterize it.
        // Largest accepted source bitmap: 1024 * 1024 * 4 = 4 MiB;
        // our explicit output allocation is 64 * 64 * 4 = 16 KiB.
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
