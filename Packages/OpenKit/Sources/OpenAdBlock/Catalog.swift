import Foundation
import CryptoKit
import Darwin

public struct BlockList: Codable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let category: String
    public let infoURL: URL
    public let urls: [URL]
    public let bundled: Bool
    public let defaultEnabled: Bool
    public let unavailableReason: String?
    public let redirectHosts: [String]?

    enum CodingKeys: String, CodingKey {
        case id, category, urls, bundled
        case displayName = "display_name", infoURL = "info_url"
        case defaultEnabled = "default_enabled", unavailableReason = "unavailable_reason"
        case redirectHosts = "redirect_hosts"
    }
}

public struct AdBlockBundledPin: Sendable {
    public let seedURL: URL
    public let sha256: String
}

public struct AdBlockCatalog: Codable, Sendable {
    public let version: Int
    public let lists: [BlockList]
    public var defaultIDs: [String] { lists.filter(\.defaultEnabled).map(\.id) }

    private static let cached: Result<Self, any Error> = Result { try decodeCatalog() }

    public static func load() throws -> Self { try cached.get() }

    private static func decodeCatalog() throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: resource("catalog.json")))
        guard value.version == 1, value.lists.count == 46,
              Set(value.lists.map(\.id)).count == 46,
              Set(value.defaultIDs) == ["EasyList", "EasyPrivacy"] else {
            throw AdBlockError("catalog: invalid schema")
        }
        for list in value.lists {
            guard !list.id.isEmpty, list.id.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            }), list.urls.allSatisfy({ $0.scheme == "https" && $0.host()?.contains(".") == true }),
            (list.redirectHosts ?? []).allSatisfy({ host in
                !host.isEmpty && host == host.lowercased() && !host.contains("/") && !host.contains(":") &&
                host.split(separator: ".").count >= 2
            }), !list.urls.isEmpty || list.unavailableReason != nil else {
                throw AdBlockError("catalog: invalid list \(list.id)")
            }
        }
        return value
    }

    public func list(_ id: String) throws -> BlockList {
        guard let list = lists.first(where: { $0.id == id }) else { throw AdBlockError("unknown list ID") }
        return list
    }

    static func resource(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources") else {
            throw AdBlockError("missing catalog resource")
        }
        return url
    }

    private static let cachedPins: Result<[String: AdBlockBundledPin], any Error> = Result { try decodePins() }

    public static func bundledPins() throws -> [String: AdBlockBundledPin] { try cachedPins.get() }

    private static func decodePins() throws -> [String: AdBlockBundledPin] {
        let text = try String(contentsOf: resource("list-pins.txt"), encoding: .utf8)
        var pins: [String: AdBlockBundledPin] = [:]
        var commits = Set<String>()
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count == 3 else { throw AdBlockError("invalid bundle pins") }
            let name = String(columns[0]), rawURL = String(columns[1]), hash = String(columns[2])
            let prefix = "https://raw.githubusercontent.com/easylist/easylist/"
            guard ["easylist.txt", "easyprivacy.txt"].contains(name), pins[name] == nil,
                  rawURL.hasPrefix(prefix), let url = URL(string: rawURL),
                  hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw AdBlockError("invalid bundle pins")
            }
            let commit = String(rawURL.dropFirst(prefix.count).prefix(40))
            guard commit.count == 40, commit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  rawURL == prefix + commit + "/" + name else { throw AdBlockError("invalid bundle seed URL") }
            commits.insert(commit)
            pins[name] = AdBlockBundledPin(seedURL: url, sha256: hash)
        }
        guard pins.count == 2, commits.count == 1 else { throw AdBlockError("invalid bundle pins") }
        return pins
    }
}

public struct AdBlockError: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func checkedList(_ data: Data, id: String, limit: Int) throws {
    guard !data.isEmpty, data.count <= limit else { throw AdBlockError("\(id): empty or oversized list") }
    let prefix = String(decoding: data.prefix(4096), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
    guard prefix.hasPrefix("[Adblock Plus") || prefix.hasPrefix("[uBlock") || prefix.hasPrefix("!") else {
        throw AdBlockError("\(id): invalid filter-list header")
    }
}

/// Durable same-directory publication: complete bytes, fsync, rename, then fsync parent.
func atomicWrite(_ data: Data, to url: URL) throws {
    try Task.checkCancellation()
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let temp = parent.appendingPathComponent(".write-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    try Task.checkCancellation()
    try data.write(to: temp, options: .withoutOverwriting)
    try syncPath(temp)
    try Task.checkCancellation()
    guard Darwin.rename(temp.path, url.path) == 0 else { throw AdBlockError("file rename failed (\(errno))") }
    try syncPath(parent)
}

func syncPath(_ url: URL) throws {
    let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw AdBlockError("file sync open failed (\(errno))") }
    defer { Darwin.close(fd) }
    guard fsync(fd) == 0 else { throw AdBlockError("file sync failed (\(errno))") }
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try atomicWrite(encoder.encode(value), to: url)
}

func readJSON<T: Decodable>(_ type: T.Type, at url: URL, fallback: T) throws -> T {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
        if errno == ENOENT { return fallback }
        throw AdBlockError("settings: open failed (\(errno))")
    }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    var info = stat()
    let limit = 4 * 1024 * 1024
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_size >= 0, info.st_size <= limit else { throw AdBlockError("settings: invalid file or size limit exceeded") }
    let data = try file.read(upToCount: Int(info.st_size) + 1) ?? Data()
    guard data.count <= limit else { throw AdBlockError("settings: file too large") }
    return try JSONDecoder().decode(type, from: data)
}
