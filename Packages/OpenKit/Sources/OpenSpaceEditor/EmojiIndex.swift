import CoreText
import Foundation

public struct EmojiEntry: Sendable {
    public let value: String
    public let name: String
    public let category: Int
    public let variants: [String]
    /// Default plus each supported uniform skin tone. Unsupported variants are
    /// removed once at load time; mixed tones stay in the pinned source index.
    public var tones: [String] {
        [value] + (0x1F3FB...0x1F3FF).compactMap { tone in
            variants.first { sequence in
                let modifiers = sequence.unicodeScalars.filter { (0x1F3FB...0x1F3FF).contains(Int($0.value)) }
                return !modifiers.isEmpty && modifiers.allSatisfy { Int($0.value) == tone }
            }
        }
    }
}

public struct EmojiIndex: Sendable {
    public let categories: [String]
    public let entries: [EmojiEntry]
    public static func load() throws -> EmojiIndex {
        guard let url = Bundle.module.url(forResource: "emoji-index", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count <= 400_000,
              let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let categories = root["categories"] as? [String], categories.count == 8,
              let rows = root["entries"] as? [[Any]], rows.count <= 5_000 else { throw CocoaError(.fileReadCorruptFile) }
        // Trusted bundled input, still bounded: at most 5,000 entries, each with
        // 100 variants of 128 UTF-8 bytes. Largest raw allocation <= 400 KB.
        let entries = try rows.map { row -> EmojiEntry in
            guard row.count == 4, let value = row[0] as? String, value.utf8.count <= 128,
                  let name = row[1] as? String, name.utf8.count <= 256,
                  let category = row[2] as? Int, (0..<8).contains(category),
                  let variants = row[3] as? [String], variants.count <= 100,
                  variants.allSatisfy({ $0.utf8.count <= 128 }) else { throw CocoaError(.fileReadCorruptFile) }
            return EmojiEntry(value: value, name: name, category: category, variants: variants)
        }
        return EmojiIndex(categories: categories, entries: entries)
    }

    /// CoreText owns the created objects through Swift's CF memory management.
    /// One pass uses at most one emoji line (128 UTF-8 bytes) at a time.
    fileprivate func supportedBySystemFont() -> EmojiIndex {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)
        func supported(_ value: String) -> Bool {
            let text = NSAttributedString(string: value, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
            let runs = CTLineGetGlyphRuns(CTLineCreateWithAttributedString(text)) as! [CTRun]
            guard runs.count == 1, let run = runs.first, CTRunGetGlyphCount(run) == 1,
                  let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName],
                  CFGetTypeID(runFont as CFTypeRef) == CTFontGetTypeID() else { return false }
            return CTFontCopyPostScriptName(runFont as! CTFont) as String == "AppleColorEmoji"
        }
        return EmojiIndex(categories: categories, entries: entries.compactMap { entry in
            guard supported(entry.value) else { return nil }
            return EmojiEntry(value: entry.value, name: entry.name, category: entry.category,
                              variants: entry.variants.filter(supported))
        })
    }
}

/// Starts once, only on first open. Decode and CoreText filtering never block
/// the UI thread. The process cache is refreshed by the next app launch.
actor EmojiIndexCache {
    static let shared = EmojiIndexCache()
    private var cached: EmojiIndex?
    func load() async throws -> EmojiIndex {
        if let cached { return cached }
        let index = try EmojiIndex.load().supportedBySystemFont()
        cached = index
        return index
    }
}
