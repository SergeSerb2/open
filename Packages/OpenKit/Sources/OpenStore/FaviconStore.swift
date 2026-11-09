import AppKit
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

public enum FaviconSourceKind: String, Codable, Sendable {
    case appleTouch = "apple-touch", manifest, link, favicon = "favicon.ico"
}

public struct FaviconImageInfo: Codable, Sendable {
    public var sourceKind: FaviconSourceKind?
    public let width: Int
    public let height: Int
    public let opaque: Bool
}

public struct FaviconImage: Sendable {
    public let png32: Data
    public let png64: Data?
    public let iconURL: URL?
    public let info: FaviconImageInfo?
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
        // A copy owns only its own row. Ordinary engine reports clear this tag.
        guard let columns = connection.prepare("PRAGMA table_info(favicons)") else { throw FaviconStoreError.database }
        var hasCopyToken = false, hasImageInfo = false
        while sqlite3_step(columns) == SQLITE_ROW {
            if connection.columnText(columns, 1) == "copy_token" { hasCopyToken = true }
            if connection.columnText(columns, 1) == "image_info" { hasImageInfo = true }
        }
        sqlite3_finalize(columns)
        guard hasCopyToken || connection.exec("ALTER TABLE favicons ADD COLUMN copy_token TEXT") else { throw FaviconStoreError.database }
        guard hasImageInfo || connection.exec("ALTER TABLE favicons ADD COLUMN image_info TEXT") else { throw FaviconStoreError.database }
        var prepared: [OpaquePointer] = []
        func prepare(_ sql: String) throws -> OpaquePointer {
            guard let stmt = connection.prepare(sql) else {
                for previous in prepared { sqlite3_finalize(previous) }
                throw FaviconStoreError.database
            }
            prepared.append(stmt)
            return stmt
        }
        lookup = try prepare("SELECT png32,png64,icon_url,CASE WHEN length(image_info)<=512 THEN image_info END FROM favicons WHERE origin=? AND page_key IN (?, '') AND status=0 AND png32 IS NOT NULL AND length(png32)<=32768 AND coalesce(length(png64),0)<=32768 ORDER BY length(page_key) DESC LIMIT 1")
        freshness = try prepare("SELECT status FROM favicons WHERE origin=? AND page_key='' AND expires_at>?")
        upsert = try prepare("""
            INSERT INTO favicons(origin,page_key,icon_url,png32,png64,fetched_at,expires_at,status,copy_token,image_info)
            VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(origin,page_key) DO UPDATE SET
            icon_url=excluded.icon_url,png32=excluded.png32,png64=excluded.png64,
            fetched_at=excluded.fetched_at,expires_at=excluded.expires_at,status=excluded.status,copy_token=excluded.copy_token,image_info=excluded.image_info
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
    // Each codec memo has one entry: <=512 KiB encoded input plus 32/64 px
    // outputs, and one decoded 64 px bitmap (16 KiB). Identical reports for a
    // new page key reuse normalization and decoded pixels without ImageIO work.
    private var normalized: (input: Data, minimum: Int, png32: Data, png64: Data, info: FaviconImageInfo)?
    private var decoded: (data: Data, image: CGImage)?

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
        if let decoded, decoded.data == data { return decoded.image }
        guard let image = try? Self.decode(data) else { return nil }
        decoded = (data, image)
        return image
    }

    /// Prefer a page-specific image; keep stale images visible while a refresh is due.
    public func icon(for pageURL: URL) -> FaviconImage? {
        guard Self.cacheKey(pageURL) != nil, let origin = FaviconOrigin.key(pageURL), let statements = try? open() else { return nil }
        let stmt = statements.lookup
        defer { reset(stmt) }
        statements.db.bindText(stmt, 1, origin)
        statements.db.bindText(stmt, 2, FaviconOrigin.pageKey(pageURL))
        guard sqlite3_step(stmt) == SQLITE_ROW, let png32 = blob(stmt, 0) else { return nil }
        let info = statements.db.columnText(stmt, 3).flatMap { try? JSONDecoder().decode(FaviconImageInfo.self, from: Data($0.utf8)) }.flatMap { value in
            (1...Self.maximumDimension).contains(value.width) && (1...Self.maximumDimension).contains(value.height) ? value : nil
        }
        return FaviconImage(png32: png32, png64: blob(stmt, 1), iconURL: statements.db.columnText(stmt, 2).flatMap(URL.init(string:)), info: info)
    }

    @discardableResult public func ingest(imageData: Data, iconURL: URL?, for pageURL: URL, pageSpecific: Bool, copyToken: UUID? = nil,
                                         minimumDimension: Int = 1, sourceKind: FaviconSourceKind? = nil) throws -> FaviconImageInfo {
        guard Self.cacheKey(pageURL) != nil, let origin = FaviconOrigin.key(pageURL), (iconURL?.absoluteString.utf8.count ?? 0) <= 8192 else { throw FaviconStoreError.invalidURL }
        guard imageData.count <= Self.maximumInputBytes else { throw FaviconStoreError.invalidImage }
        // Actor isolation makes this check and the write indivisible. Preserve
        // both exact-page records and an existing origin fallback.
        if copyToken != nil, let existing = icon(for: pageURL) { return existing.info ?? FaviconImageInfo(sourceKind: nil, width: 32, height: 32, opaque: false) }
        let pngs: (Data, Data)
        var info: FaviconImageInfo
        if let normalized, normalized.input == imageData, normalized.minimum == minimumDimension {
            pngs = (normalized.png32, normalized.png64)
            info = normalized.info
        } else {
            let result = try autoreleasepool { () throws -> (Data, Data, FaviconImageInfo) in
                let (image, width, height) = try Self.decodeSource(imageData, minimumDimension: minimumDimension)
                let png64 = try Self.png(image, size: 64)
                let opaque = Self.isOpaque(image)
                return (try Self.png(image, size: 32), png64, FaviconImageInfo(sourceKind: nil, width: width, height: height, opaque: opaque))
            }
            pngs = (result.0, result.1); info = result.2
            normalized = (imageData, minimumDimension, pngs.0, pngs.1, info)
        }
        info.sourceKind = sourceKind
        try write(origin: origin, pageKey: pageSpecific ? FaviconOrigin.pageKey(pageURL) : "",
                  iconURL: iconURL, png32: pngs.0, png64: pngs.1, status: 0, lifetime: 7 * 86400, copyToken: copyToken, info: info)
        return info
    }

    /// Inspect a bounded candidate without publishing a small fallback before
    /// larger declared icons have been tried.
    public func inspect(imageData: Data, minimumDimension: Int) throws -> FaviconImageInfo {
        guard imageData.count <= Self.maximumInputBytes else { throw FaviconStoreError.invalidImage }
        return try autoreleasepool {
            let (image, width, height) = try Self.decodeSource(imageData, minimumDimension: minimumDimension)
            return FaviconImageInfo(sourceKind: nil, width: width, height: height, opaque: Self.isOpaque(image))
        }
    }

    /// A delayed empty/different engine report may revoke only this copy. A
    /// newer ordinary report (or another copy) has a different/null token.
    public func removeCopy(for pageURL: URL, token: UUID) throws {
        guard Self.cacheKey(pageURL) != nil, let origin = FaviconOrigin.key(pageURL) else { throw FaviconStoreError.invalidURL }
        let statements = try open()
        guard let stmt = statements.db.prepare("DELETE FROM favicons WHERE origin=? AND page_key=? AND copy_token=?") else { throw FaviconStoreError.database }
        defer { sqlite3_finalize(stmt) }
        statements.db.bindText(stmt, 1, origin)
        statements.db.bindText(stmt, 2, FaviconOrigin.pageKey(pageURL))
        statements.db.bindText(stmt, 3, token.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw FaviconStoreError.database }
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
                       png64: Data? = nil, status: Int, lifetime: TimeInterval, copyToken: UUID? = nil, info: FaviconImageInfo? = nil) throws {
        guard origin.utf8.count <= 8192, pageKey.utf8.count <= 8192 else { throw FaviconStoreError.invalidURL }
        let statements = try open(), stmt = statements.upsert, db = statements.db
        let reservedBytes = 2 * (origin.utf8.count + pageKey.utf8.count) +
            (iconURL?.absoluteString.utf8.count ?? 0) + (png32?.count ?? 0) + (png64?.count ?? 0) + 512
        func attempt() throws -> Int32 {
            guard db.exec("BEGIN IMMEDIATE") else { throw FaviconStoreError.database }
            var committed = false
            defer { reset(stmt); if !committed { db.exec("ROLLBACK") } }
            // Reserve both key copies and row/index overhead before SQLite needs
            // pages for the new record. Conservative reservation also covers updates.
            try enforceLimits(statements, reservedBytes: reservedBytes, reservedCount: 1)
            let now = Date().timeIntervalSince1970
            db.bindText(stmt, 1, origin); db.bindText(stmt, 2, pageKey)
            db.bindText(stmt, 3, iconURL?.absoluteString)
            bindBlob(stmt, 4, png32); bindBlob(stmt, 5, png64)
            db.bindDouble(stmt, 6, now); db.bindDouble(stmt, 7, now + lifetime)
            db.bindInt(stmt, 8, Int64(status))
            db.bindText(stmt, 9, copyToken?.uuidString)
            let infoJSON = info.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
            db.bindText(stmt, 10, infoJSON)
            let result = sqlite3_step(stmt)
            guard result == SQLITE_DONE else { return result }
            reset(stmt)
            guard db.exec("COMMIT") else { throw FaviconStoreError.database }
            committed = true
            return SQLITE_DONE
        }
        for retry in 0...1 {
            let result = try attempt()
            if result == SQLITE_DONE { return }
            guard (result & 0xff) == SQLITE_FULL, retry == 0 else { throw FaviconStoreError.database }
            // SQLITE_FULL can roll back the whole transaction, including its
            // evictions. Commit oldest-record eviction separately before one retry.
            let batch = max(1, count() / 4)
            guard db.exec("BEGIN IMMEDIATE; DELETE FROM favicons WHERE rowid IN (SELECT rowid FROM favicons ORDER BY fetched_at,rowid LIMIT \(batch)); COMMIT;") else {
                db.exec("ROLLBACK"); throw FaviconStoreError.database
            }
        }
        throw FaviconStoreError.database
    }

    private func enforceLimits(_ statements: FaviconStatements, legacy: Bool = false, reservedBytes: Int = 0, reservedCount: Int = 0) throws {
        let db = statements.db
        // Cap legacy counts in one SQL operation before the bounded byte loop.
        if legacy, !db.exec("DELETE FROM favicons WHERE rowid NOT IN (SELECT rowid FROM favicons ORDER BY fetched_at DESC,rowid DESC LIMIT \(Self.maximumEntries))") { throw FaviconStoreError.database }
        guard let usage = db.prepare("SELECT count(*),coalesce(sum(2*(length(CAST(origin AS BLOB))+length(CAST(page_key AS BLOB)))+coalesce(length(CAST(icon_url AS BLOB)),0)+coalesce(length(png32),0)+coalesce(length(png64),0)+512),0) FROM favicons") else { throw FaviconStoreError.database }
        defer { sqlite3_finalize(usage) }
        // At most 4096 iterations; count UTF-8 keys twice for the primary-key
        // index and allow 512 bytes per row for SQLite/age-index overhead.
        for _ in 0...Self.maximumEntries {
            guard sqlite3_step(usage) == SQLITE_ROW else { throw FaviconStoreError.database }
            let count = Int(db.columnInt(usage, 0)), bytes = Int(db.columnInt(usage, 1))
            reset(usage)
            if count + reservedCount <= Self.maximumEntries && bytes + reservedBytes <= Self.maximumStoredBytes { return }
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
        try decodeSource(data).0
    }

    private static func decodeSource(_ data: Data, minimumDimension: Int = 1) throws -> (CGImage, Int, Int) {
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(source) > 0, CGImageSourceGetCount(source) <= 32 {
            var index = 0
            if CGImageSourceGetType(source).map({ UTType($0 as String)?.conforms(to: .ico) == true }) == true {
                var best = Int.max
                for candidate in 0..<CGImageSourceGetCount(source) {
                    let properties = CGImageSourceCopyPropertiesAtIndex(source, candidate, nil) as? [CFString: Any]
                    let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
                    let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
                    guard max(width, height) <= maximumDimension, min(width, height) >= minimumDimension else { continue }
                    let distance = minimumDimension >= 64 ? -min(width, height) : abs(max(width, height) - 64)
                    if distance < best { best = distance; index = candidate }
                }
            }
            // Read the selected frame's dimensions before asking ImageIO to decode it.
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  let depth = properties[kCGImagePropertyDepth] as? NSNumber, (1...8).contains(depth.intValue),
                  min(width.intValue, height.intValue) >= minimumDimension,
                  (1...Double(maximumDimension)).contains(width.doubleValue), (1...Double(maximumDimension)).contains(height.doubleValue) else {
                throw FaviconStoreError.invalidImage
            }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                          kCGImageSourceThumbnailMaxPixelSize: 64]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) { return (image, width.intValue, height.intValue) }
        }
        // Static SVG favicons are rasterized to a fixed 128 px bitmap. Refuse
        // active content and external resources before AppKit sees the document.
        if let text = String(data: data, encoding: .utf8), text.utf8.count <= maximumInputBytes,
           text.range(of: "<svg", options: .caseInsensitive) != nil,
           !["<!doctype", "<!entity", "<?xml-stylesheet"].contains(where: { text.lowercased().contains($0) }) {
            let validator = FaviconSVGValidator()
            let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = validator
            guard parser.parse(), validator.valid, validator.elements <= 2048,
                  let image = NSImage(data: data), image.size.width.isFinite, image.size.height.isFinite,
                  image.size.width > 0, image.size.height > 0,
                  max(image.size.width, image.size.height) <= CGFloat(maximumDimension), minimumDimension <= 128,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FaviconStoreError.invalidImage }
            let scale = 128 / max(image.size.width, image.size.height)
            let width = image.size.width * scale, height = image.size.height * scale
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            image.draw(in: NSRect(x: (128-width)/2, y: (128-height)/2, width: width, height: height), from: .zero,
                operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            if let bitmap = context.makeImage() { return (bitmap, 128, 128) }
        }
        // Reject other unsupported input before AppKit can rasterize it.
        // Largest accepted source bitmap: 1024 * 1024 * 4 = 4 MiB;
        // our explicit output allocation is 64 * 64 * 4 = 16 KiB.
        throw FaviconStoreError.invalidImage
    }

    private static func isOpaque(_ image: CGImage) -> Bool {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        // Fixed 64 x 64 RGBA scratch: 16 KiB, independent of input dimensions.
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.clear(CGRect(x: 0, y: 0, width: 64, height: 64))
            let scale = 64 / CGFloat(max(image.width,image.height))
            let width = CGFloat(image.width)*scale, height = CGFloat(image.height)*scale
            context.draw(image, in: CGRect(x: (64-width)/2, y: (64-height)/2, width: width, height: height))
            return stride(from: 3, to: buffer.count, by: 4).allSatisfy { buffer[$0] == 255 }
        }
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

/// Only bounded, static vector primitives and local fragment references. No
/// script, image, foreignObject, CSS imports, entities, or external URLs.
private final class FaviconSVGValidator: NSObject, XMLParserDelegate {
    var valid = true
    var elements = 0
    private var depth = 0
    private static let tags: Set<String> = ["svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "defs", "clippath", "mask", "lineargradient", "radialgradient", "stop", "use", "title", "desc"]
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1; elements += 1
        guard depth <= 32, elements <= 2048, Self.tags.contains(name.lowercased()), attributes.count <= 64 else { valid = false; parser.abortParsing(); return }
        for (key, value) in attributes {
            let key = key.lowercased(), value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if key.hasPrefix("on") || key == "style" || value.contains("@import") || value.contains("javascript:") ||
               (key.hasSuffix("href") && !value.hasPrefix("#")) ||
               (value.contains("url(") && value.range(of: #"^url\(\s*['"]?#[a-z0-9_:-]+['"]?\s*\)$"#, options: .regularExpression) == nil) {
                valid = false; parser.abortParsing(); return
            }
        }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { depth -= 1 }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { valid = false; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { valid = false; parser.abortParsing() }
}
