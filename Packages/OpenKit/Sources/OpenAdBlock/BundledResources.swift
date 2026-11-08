import Foundation

/// App-bound redirect stubs. Runtime list updates never download these bytes.
struct BundledResources: Sendable {
    static let maximumBytes = 4 * 1024 * 1024
    let url: URL
    let sha256: String

    init(bundle: URL?) throws {
        url = try bundle?.appendingPathComponent("resources.json") ?? AdBlockCatalog.resource("resources.json")
        sha256 = try Self.revision()
    }

    private static let pin: Result<String, any Error> = Result {
        let text = try String(contentsOf: AdBlockCatalog.resource("resources-pins.txt"), encoding: .utf8)
        let rows = text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { $0.split(whereSeparator: \.isWhitespace) }
        guard rows.count == 2, let output = rows.first(where: { $0.first == "resources.json" }),
              output.count == 3, output[1] == "assemble:ubo.tar.gz", output[2].count == 64,
              output[2].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw AdBlockError("invalid bundled resources pin")
        }
        return String(output[2])
    }

    static func revision() throws -> String { try pin.get() }

    func verifiedData() throws -> Data {
        // Largest allocation is 4 MiB + 1 byte (boundedData's overflow probe).
        guard let data = boundedData(url, maximum: Self.maximumBytes), !data.isEmpty, digest(data) == sha256 else {
            throw AdBlockError("_resources: bundled size or SHA-256 pin mismatch; run tools/fetch-adblock-lists.sh")
        }
        return data
    }
}
