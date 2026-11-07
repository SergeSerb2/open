import Foundation
import Darwin

public enum SecretsImportStep: String, Codable, CaseIterable, Sendable { case logins, webData, cookies }

/// Counts and opaque profile IDs only. This file never contains source records.
public struct SecretsImportLedgerSnapshot: Codable, Sendable {
    public struct Step: Codable, Sendable {
        public var state = "pending"
        public var added = 0
        public var existing = 0
        public var failed = 0
        public var addresses: SecretsWriteResult? = nil
        public var cards: SecretsWriteResult? = nil
    }
    public struct Profile: Codable, Sendable {
        public var openProfile: UUID?
        public var logins = Step()
        public var webData = Step()
        public var cookies = Step()
    }
    public let version: Int
    public let runID: UUID
    public let started: Date
    public var profiles: [String: Profile]
    public var finished: Date?
}

@MainActor public final class SecretsImportLedger {
    public let fileURL: URL
    private var current: SecretsImportLedgerSnapshot?

    public init(dataRoot: URL) { fileURL = dataRoot.appendingPathComponent("State/secrets-import.json") }

    /// Query at launch, before a new run replaces the old ledger.
    public var unfinished: SecretsImportLedgerSnapshot? {
        get throws { let value = try read(); return value?.finished == nil ? value : nil }
    }

    public func read() throws -> SecretsImportLedgerSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let fd = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 1024 * 1024 else {
            throw ArcSecretsImportError.inputLimit
        }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileReadUnknown) }
                offset += count
            }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(SecretsImportLedgerSnapshot.self, from: data)
        guard value.version == 1, value.profiles.count <= 256 else { throw ArcSecretsImportError.inputLimit }
        return value
    }

    func begin(profiles: [String], openProfiles: [String: UUID]) throws {
        current = SecretsImportLedgerSnapshot(version: 1, runID: UUID(), started: Date(),
            profiles: Dictionary(uniqueKeysWithValues: profiles.map { ($0, .init(openProfile: openProfiles[$0])) }), finished: nil)
        try write()
    }

    func complete(_ step: SecretsImportStep, profile: String, counts: ArcSecretsProfileCounts) throws {
        guard var value = current, var entry = value.profiles[profile] else { throw ArcSecretsImportError.invalidLocalState }
        func result(_ count: SecretsImportCounts) -> SecretsImportLedgerSnapshot.Step {
            .init(state: "done", added: count.added, existing: count.existing, failed: count.failed)
        }
        switch step {
        case .logins: entry.logins = result(counts.logins)
        case .cookies: entry.cookies = result(counts.cookies)
        case .webData:
            entry.webData = .init(state: "done", addresses: counts.addresses.writeResult, cards: counts.cards.writeResult)
        }
        value.profiles[profile] = entry; current = value
        try write()
    }

    func finish() throws {
        guard var value = current else { throw ArcSecretsImportError.invalidLocalState }
        value.finished = Date(); current = value; try write()
    }

    private func write() throws {
        guard let current else { return }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".secrets-import-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temporary) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(current)
        guard data.count <= 1024 * 1024 else { throw ArcSecretsImportError.inputLimit }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, fileURL.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let directoryFD = Darwin.open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
