import Foundation

/// Public Suffix List lookup for "is this typed text a real host?".
///
/// The bundled `public_suffix_list.dat` (MPL-2.0, header intact) loads on first use. Only the ICANN
/// section is used, as Chromium does for URL detection (private suffixes such as `github.io` are
/// registrable sites, not TLDs). Rules become sorted arrays of 64-bit FNV-1a hashes (about 7k rules,
/// under 60 KB), so a lookup is a few binary searches and allocates nothing.
public final class PublicSuffixList: Sendable {
    public static let shared = PublicSuffixList(data: PublicSuffixList.bundledData())

    private let exact: [UInt64]
    /// `*.ck` is stored as hash("ck").
    private let wildcard: [UInt64]
    /// `!www.ck` is stored as hash("www.ck").
    private let exception: [UInt64]
    public let ruleCount: Int
    /// The `// VERSION:` line of the bundled file.
    public let version: String?

    public init(data: Data) {
        var exact: [UInt64] = [], wildcard: [UInt64] = [], exception: [UInt64] = []
        var version: String?
        let endMarker = Array("// ===END ICANN DOMAINS===".utf8)
        let versionMarker = Array("// VERSION: ".utf8)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            while start < bytes.count {
                var end = start
                while end < bytes.count && bytes[end] != 10 { end += 1 }
                var line = UnsafeBufferPointer(rebasing: bytes[start..<end])
                start = end + 1
                if line.last == 13 { line = UnsafeBufferPointer(rebasing: line[0..<(line.count - 1)]) }
                if line.starts(with: endMarker) { break }
                if line.starts(with: versionMarker) {
                    version = String(decoding: line[versionMarker.count...], as: UTF8.self)
                    continue
                }
                if line.isEmpty || line.starts(with: [47, 47]) { continue } // "//"
                // A rule is the first whitespace-free run of the line.
                var ruleEnd = 0
                while ruleEnd < line.count && line[ruleEnd] != 32 && line[ruleEnd] != 9 { ruleEnd += 1 }
                let rule = UnsafeBufferPointer(rebasing: line[0..<ruleEnd])
                if rule.isEmpty { continue }
                if rule[0] == 33 { // "!"
                    exception.append(Self.hash(rule[1...]))
                } else if rule.count > 2 && rule[0] == 42 && rule[1] == 46 { // "*."
                    wildcard.append(Self.hash(rule[2...]))
                } else {
                    exact.append(Self.hash(rule[...]))
                }
            }
        }
        self.exact = exact.sorted()
        self.wildcard = wildcard.sorted()
        self.exception = exception.sorted()
        self.ruleCount = exact.count + wildcard.count + exception.count
        self.version = version
    }

    private static func bundledData() -> Data {
        if let url = Bundle.module.url(forResource: "public_suffix_list", withExtension: "dat"),
           let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            return data
        }
        // The resource is part of the package, so this only runs in a broken build. Keep URL typing usable.
        return Data("com\norg\nnet\nedu\ngov\nio\ndev\napp\nco\nuk\nco.uk\nde\nfr\njp\nca\nus\nau\n".utf8)
    }

    @inline(__always)
    private static func hash(_ bytes: some Collection<UInt8>) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }

    @inline(__always)
    private static func contains(_ sorted: [UInt64], _ value: UInt64) -> Bool {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            let v = sorted[mid]
            if v == value { return true }
            if v < value { lo = mid + 1 } else { hi = mid }
        }
        return false
    }

    /// Number of labels in the public suffix of `host`, or nil when no ICANN rule matches
    /// (an unknown TLD). Applies the PSL algorithm: an exception rule wins, otherwise the matching rule
    /// with the most labels. `host` must be lowercase without a trailing dot.
    public func suffixLabelCount(host: String) -> Int? {
        let bytes = Array(host.utf8)
        guard !bytes.isEmpty else { return nil }
        var starts = [0]
        for (i, b) in bytes.enumerated() where b == 46 { starts.append(i + 1) }
        let labelCount = starts.count
        var best: Int?
        for k in 0..<labelCount {
            let suffix = bytes[starts[k]...]
            let labels = labelCount - k
            let h = Self.hash(suffix)
            if Self.contains(exception, h) { return labels - 1 }
            if best == nil {
                if Self.contains(exact, h) { best = labels }
                else if k + 1 < labelCount, Self.contains(wildcard, Self.hash(bytes[starts[k + 1]...])) { best = labels }
            }
        }
        return best
    }

    /// True when `host` ends in a known ICANN suffix and has at least one label in front of it
    /// (`example.co.uk` yes, `co.uk` no, `example.notatld` no).
    public func isRegistrableHost(_ host: String) -> Bool {
        guard let suffixLabels = suffixLabelCount(host: host) else { return false }
        let labels = host.utf8.reduce(1) { $1 == 46 ? $0 + 1 : $0 }
        return labels > suffixLabels
    }
}
