import Foundation
import Darwin

struct GenerationReference: Codable, Sendable, Equatable {
    var generation: Int
    var manifestSHA256: String
}

struct CurrentGeneration: Codable, Sendable {
    var live: GenerationReference
    var previous: GenerationReference?
}

struct GenerationFile: Codable, Sendable {
    var file: String
    var bytes: Int
    var sha256: String
    var listID: String
    /// Ordered upstream content hashes; a bundled seed uses its pinned content hash.
    var sourceRevision: [String]
    var generation: Int
}

struct GenerationManifest: Codable, Sendable {
    var generation: Int
    var files: [GenerationFile]
    /// Immutable settings receipt makes state-before-pointer crashes recoverable.
    var state: AdBlockProfileState
}

/// Only current.json selects inputs. Unreferenced directories and extra files are never inputs.
/// Engine consumers must repeat this verification, including DAT input hashes (see §9.2).
struct GenerationStorage: Sendable {
    let maximumBytes: Int
    let ephemeral: Bool

    func current(in directory: URL) throws -> CurrentGeneration? {
        try readJSON(CurrentGeneration?.self, at: directory.appendingPathComponent("current.json"), fallback: nil)
    }

    func path(_ reference: GenerationReference, in directory: URL) -> URL {
        directory.appendingPathComponent("generations/\(reference.generation)", isDirectory: true)
    }

    func verify(_ reference: GenerationReference, directory: URL, catalog: AdBlockCatalog) throws -> GenerationManifest {
        guard reference.generation > 0 else { throw AdBlockError("invalid generation number") }
        let generation = path(reference, in: directory)
        let values = try generation.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              let bytes = boundedData(generation.appendingPathComponent("manifest.json"), maximum: 4 * 1024 * 1024),
              digest(bytes) == reference.manifestSHA256 else { throw AdBlockError("manifest SHA-256 mismatch or missing generation") }
        let manifest = try JSONDecoder().decode(GenerationManifest.self, from: bytes)
        let ids = manifest.state.enabledBlockLists
        guard manifest.generation == reference.generation, manifest.state.catalogVersion == catalog.version,
              Set(ids).count == ids.count, manifest.files.count == ids.count,
              Set(manifest.files.map(\.listID)) == Set(ids),
              ids.allSatisfy({ id in catalog.lists.contains { $0.id == id && !$0.urls.isEmpty } }) else {
            throw AdBlockError("manifest enabled-list set mismatch")
        }
        for file in manifest.files {
            guard file.file == "\(file.listID).txt", file.generation == reference.generation,
                  let receipt = manifest.state.lists[file.listID], receipt.bytes == file.bytes,
                  receipt.sha256 == file.sha256, file.sourceRevision == revisions(receipt),
                  let data = boundedData(generation.appendingPathComponent(file.file), maximum: maximumBytes),
                  data.count == file.bytes, digest(data) == file.sha256 else {
                throw AdBlockError("\(file.listID): size or SHA-256 mismatch")
            }
        }
        return manifest
    }

    func save(_ state: AdBlockProfileState, directory: URL) throws {
        try Task.checkCancellation()
        if !ephemeral { try writeJSON(state, to: directory.deletingLastPathComponent().appendingPathComponent("catalog-state.json")) }
    }

    /// All inputs are validated and durable before state is saved and the single live pointer moves.
    func publish(state: AdBlockProfileState, inputs: URL, directory: URL,
                 previous: GenerationReference?) throws -> GenerationReference {
        let files = FileManager.default
        let generations = directory.appendingPathComponent("generations", isDirectory: true)
        try Task.checkCancellation()
        try files.createDirectory(at: generations, withIntermediateDirectories: true)
        let numbers = try files.contentsOfDirectory(atPath: generations.path).compactMap(Int.init)
        let latest = max(numbers.max() ?? 0, previous?.generation ?? 0)
        guard latest < Int.max else { throw AdBlockError("generation number exhausted") }
        let number = latest + 1
        let generation = generations.appendingPathComponent(String(number), isDirectory: true)
        try Task.checkCancellation()
        try files.createDirectory(at: generation, withIntermediateDirectories: false)
        // A failed/crashed publication leaves an unreferenced directory. Open never promotes it.
        var entries: [GenerationFile] = []
        for id in state.enabledBlockLists.sorted() {
            guard let receipt = state.lists[id],
                  let data = boundedData(inputs.appendingPathComponent("\(id).txt"), maximum: maximumBytes),
                  data.count == receipt.bytes, digest(data) == receipt.sha256 else {
                throw AdBlockError("\(id): publication input size or SHA-256 mismatch")
            }
            try atomicWrite(data, to: generation.appendingPathComponent("\(id).txt"))
            entries.append(GenerationFile(file: "\(id).txt", bytes: data.count, sha256: receipt.sha256,
                                          listID: id, sourceRevision: revisions(receipt), generation: number))
        }
        let manifest = GenerationManifest(generation: number, files: entries, state: state)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let bytes = try encoder.encode(manifest)
        try atomicWrite(bytes, to: generation.appendingPathComponent("manifest.json"))
        try syncPath(generation)
        try syncPath(generations)
        try syncPath(directory)
        try save(state, directory: directory)
        // Explicit diagnostic fault injection, also available in release CLI verification builds.
        // SIGKILL proves no defers/rollback code is needed to preserve the old generation.
        if ProcessInfo.processInfo.environment["OPEN_ADBLOCK_DEBUG_KILL_BEFORE_CURRENT"] == "1" {
            Darwin.kill(getpid(), SIGKILL)
            // kill() can return before another thread receives the signal. Never fall
            // through to pointer publication, even in that short delivery window.
            while true { Darwin.pause() }
        }
        let reference = GenerationReference(generation: number, manifestSHA256: digest(bytes))
        try activate(reference, previous: previous, directory: directory)
        return reference
    }

    func activate(_ reference: GenerationReference, previous: GenerationReference?, directory: URL) throws {
        try Task.checkCancellation()
        try writeJSON(CurrentGeneration(live: reference, previous: previous), to: directory.appendingPathComponent("current.json"))
        // Cleanup is best-effort AFTER publication. Failure cannot roll back a committed pointer.
        cleanup(keeping: [reference.generation, previous?.generation].compactMap { $0 }, directory: directory)
    }

    func cleanup(keeping numbers: [Int], directory: URL) {
        let generations = directory.appendingPathComponent("generations")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: generations.path)) ?? [] {
            guard !Task.isCancelled else { return }
            guard let number = Int(name), !numbers.contains(number) else { continue }
            try? FileManager.default.removeItem(at: generations.appendingPathComponent(name))
        }
    }

    func quarantine(_ reference: GenerationReference, directory: URL) throws {
        let source = path(reference, in: directory)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let target = directory.appendingPathComponent("quarantine/\(reference.generation)-\(UUID().uuidString)")
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: source, to: target)
        try syncPath(source.deletingLastPathComponent())
        try syncPath(target.deletingLastPathComponent())
    }

    private func revisions(_ receipt: AdBlockListReceipt) -> [String] {
        receipt.sources.isEmpty ? [receipt.sha256] : receipt.sources.map(\.sha256)
    }
}

/// Do not follow file symlinks or read unbounded files into memory.
func boundedData(_ url: URL, maximum: Int) -> Data? {
    let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_size >= 0, info.st_size <= maximum else { return nil }
    let data = try? file.read(upToCount: Int(info.st_size) + 1)
    guard let data, data.count == Int(info.st_size) else { return nil }
    return data
}
