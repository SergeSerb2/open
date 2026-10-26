import Foundation
import Darwin

/// Filesystem operations used before any database connection exists.
enum DurableFiles {
    static func exists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil }
    static func sync(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { throw failure("open for fsync") }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw failure("fsync") }
    }
    static func failure(_ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"])
    }
    static func write(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        try sync(temporary)
        guard rename(temporary.path, url.path) == 0 else { throw failure("rename") }
        try sync(parent)
    }
    static func crashPoint(_ point: String) {
        if ProcessInfo.processInfo.environment["OPENKIT_DEBUG_MIGRATION_CRASH"] == point { _exit(86) }
    }
}
