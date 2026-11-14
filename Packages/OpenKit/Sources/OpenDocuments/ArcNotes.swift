import Foundation

/// Reading Arc Notes (docs/re/easels-notes.md §4.3–4.6). Facts: the sidebar kind is
/// `arcDocument {arcDocumentID, …}`; the local store is `StorableARCDocuments/`
/// holding `StorableARCDocument {version, arcDocument}`; a document is
/// `{id, title {value}, data {scratchpad {blocks, rootBlocks}}}` with `fullBlob` blocks
/// of `text` + `properties [{range, value: RichTextFormatType}]`; the export is one
/// `ExportedARCDocument {id, title, html, lastUpdatedAt}` per Note.
/// GUESS (no Arc Note exists to capture, Arc 1.172 cannot create one): the JSON
/// spelling of ranges and enum values, the file names inside the store and the
/// export, and the HTML element set. The readers accept every likely spelling.
public enum ArcNotes {
    public static let maxFileBytes = 32 << 20
    public static let maxFiles = 5000

    /// The stable Open Note id for an Arc document id (re-imports land on the same file).
    public static func noteID(forArcDocumentID arcID: String) -> UUID {
        if let uuid = UUID(uuidString: arcID) { return uuid }
        var a: UInt64 = 0xcbf29ce484222325, b: UInt64 = 0x84222325cbf29ce4
        for byte in Array("note:\(arcID)".utf8) {
            a = (a ^ UInt64(byte)) &* 0x100000001b3
            b = (b ^ UInt64(byte)) &* 0x100000001b3 ^ 0x9e3779b97f4a7c15
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8(truncatingIfNeeded: a >> (8 * i)); bytes[8 + i] = UInt8(truncatingIfNeeded: b >> (8 * i)) }
        bytes[6] = (bytes[6] & 0x0F) | 0x50; bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public struct Parsed: Sendable {
        public var arcID: String?
        public var note: NoteDocument
        /// Image bytes by placeholder name used in `note.formats` ("import-<n>"); the caller stores them.
        public var images: [String: (Data, String)]
        public var droppedImages: Int
    }

    // MARK: StorableARCDocuments

    /// Every readable document in `<Arc>/StorableARCDocuments`, keyed by Arc document id.
    public static func readStore(_ directory: URL) -> (documents: [String: Parsed], unreadable: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return ([:], 0) }
        var documents: [String: Parsed] = [:], bad = 0
        for name in names.sorted().prefix(maxFiles) where !name.hasPrefix(".") {
            let url = directory.appendingPathComponent(name)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxFileBytes,
                let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data),
                let parsed = storable(object) else { bad += 1; continue }
            if let id = parsed.arcID { documents[id] = parsed } else { bad += 1 }
        }
        return (documents, bad)
    }

    /// One `StorableARCDocument` (or a bare `ARCDocument`).
    public static func storable(_ object: Any) -> Parsed? {
        guard var root = object as? [String: Any] else { return nil }
        if let inner = root["arcDocument"] as? [String: Any] { root = inner }
        guard let id = root["id"] as? String else { return nil }
        let title = (root["title"] as? [String: Any])?["value"] as? String ?? root["title"] as? String ?? ""
        let scratchpad = ((root["data"] as? [String: Any])?["scratchpad"] as? [String: Any]) ?? [:]
        let blocks = dictionary(scratchpad["blocks"])
        let order = (scratchpad["rootBlocks"] as? [Any])?.compactMap { $0 as? String } ?? Array(blocks.keys).sorted()
        var text = "", formats: [NoteFormat] = []
        for blockID in order {
            guard let block = blocks[blockID] as? [String: Any], let blockText = block["text"] as? String else { continue }
            if !text.isEmpty { text += "\n" }
            let offset = (text as NSString).length
            text += blockText
            let length = (blockText as NSString).length
            for property in block["properties"] as? [Any] ?? [] {
                guard let property = property as? [String: Any] else { continue }
                let rich = property["richText"] as? [String: Any] ?? property
                guard let range = range(rich["range"]), range.location >= 0, range.length >= 0,
                    range.length <= length - range.location, let format = format(rich["value"]) else { continue }
                var f = format; f.location = offset + range.location; f.length = range.length
                if ["h1", "h2", "h3", "bulletList", "numberedList"].contains(f.type) {
                    let paragraph = (text as NSString).paragraphRange(for: NSRange(location: f.location, length: f.length))
                    let trimmed = (text as NSString).substring(with: paragraph).hasSuffix("\n") ? paragraph.length - 1 : paragraph.length
                    f.location = paragraph.location; f.length = max(0, trimmed)
                }
                formats.append(f)
            }
        }
        var note = NoteDocument(id: noteID(forArcDocumentID: id), title: title, text: text, formats: dedupe(formats))
        if let created = root["createdAt"] as? Double { note.createdAt = Date(timeIntervalSinceReferenceDate: created) }
        return Parsed(arcID: id, note: note, images: [:], droppedImages: 0)
    }

    /// Swift dictionaries may encode as an object or as alternating key/value arrays.
    static func dictionary(_ value: Any?) -> [String: Any] {
        if let dict = value as? [String: Any] { return dict }
        guard let array = value as? [Any] else { return [:] }
        var result: [String: Any] = [:]
        var i = 0
        while i + 1 < array.count { if let key = array[i] as? String { result[key] = array[i + 1] }; i += 2 }
        return result
    }

    static func range(_ value: Any?) -> NSRange? {
        if let pair = value as? [Any], pair.count == 2, let a = (pair[0] as? NSNumber)?.intValue, let b = (pair[1] as? NSNumber)?.intValue {
            return NSRange(location: a, length: b)
        }
        if let dict = value as? [String: Any], let a = (dict["location"] as? NSNumber)?.intValue, let b = (dict["length"] as? NSNumber)?.intValue {
            return NSRange(location: a, length: b)
        }
        return nil
    }

    /// `RichTextFormatType` → NoteFormat type. Strings ("bold") or objects ({"bold": {}}).
    static func format(_ value: Any?) -> NoteFormat? {
        var name: String?, payload: [String: Any] = [:]
        if let s = value as? String { name = s }
        else if let dict = value as? [String: Any], dict.count == 1, let key = dict.keys.first {
            name = key; payload = dict[key] as? [String: Any] ?? [:]
            if let inner = dict[key] as? [String: Any], let wrapped = inner["_0"] as? [String: Any] { payload = wrapped }
        }
        guard let name else { return nil }
        let level = min(max((payload["level"] as? NSNumber)?.intValue ?? 0, 0), 5)
        switch name {
        case "bold", "italic", "underline", "strikethrough", "h1", "h2", "h3": return NoteFormat(type: name, location: 0, length: 0)
        case "unorderedList": return NoteFormat(type: "bulletList", location: 0, length: 0, level: level)
        case "orderedList": return NoteFormat(type: "numberedList", location: 0, length: 0, level: level)
        case "formattedHyperlink", "hyperlink":
            guard let raw = payload["url"] as? String, let url = URL(string: raw), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return NoteFormat(type: "link", location: 0, length: 0, url: raw)
        default: return nil   // image data inside the store: counted by the caller as dropped
        }
    }

    static func dedupe(_ formats: [NoteFormat]) -> [NoteFormat] {
        var seen = Set<String>(), result: [NoteFormat] = []
        for f in formats {
            let key = "\(f.type)|\(f.location)|\(f.length)|\(f.url ?? "")|\(f.level ?? -1)"
            if seen.insert(key).inserted { result.append(f) }
        }
        return result.sorted { ($0.location, $0.type) < ($1.location, $1.type) }
    }

    // MARK: Export HTML

    /// One exported Note: an `.html` page, or a `.json` `ExportedARCDocument` with an `html` field.
    public static func exported(fileName: String, data: Data) -> Parsed? {
        guard data.count <= maxFileBytes else { return nil }
        if fileName.lowercased().hasSuffix(".json") {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let html = object["html"] as? String else { return nil }
            var parsed = parseHTML(html, fallbackTitle: object["title"] as? String ?? "")
            if let id = object["id"] as? String { parsed.arcID = id; parsed.note.id = noteID(forArcDocumentID: id) }
            if let title = object["title"] as? String, !title.isEmpty { parsed.note.title = title }
            return parsed
        }
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        let base = (fileName as NSString).lastPathComponent
        return parseHTML(html, fallbackTitle: (base as NSString).deletingPathExtension)
    }

    /// A tolerant HTML reader for the Note element set: h1–h6, p, div, br, ul/ol/li,
    /// b/strong, i/em, u, s/strike/del, a[href], img[src=data:]. Other tags keep their text.
    public static func parseHTML(_ html: String, fallbackTitle: String) -> Parsed {
        var title = ""
        var text = "", formats: [NoteFormat] = []
        var images: [String: (Data, String)] = [:], dropped = 0
        var inline: [String: Int] = [:]           // open inline tag counts
        var links: [String?] = []                 // nil for an unsupported href, so </a> pops the right one
        var lists: [String] = []                   // "ul" / "ol"
        var block: (type: String?, level: Int?) = (nil, nil)
        var paragraphStart = 0
        var skipDepth = 0                         // inside <head>, <style>, <script>
        var inTitle = false
        var length: Int { (text as NSString).length }

        func closeParagraph() {
            let end = length
            if let type = block.type, end > paragraphStart {
                formats.append(NoteFormat(type: type, location: paragraphStart, length: end - paragraphStart, level: block.level))
            }
            if end > 0, !text.hasSuffix("\n") { text += "\n" }
            paragraphStart = length
            block = (nil, nil)
        }
        func openParagraph(_ type: String?, _ level: Int?) {
            if length > paragraphStart || (!text.isEmpty && !text.hasSuffix("\n")) { closeParagraph() }
            paragraphStart = length
            block = (type, level)
        }
        func append(_ piece: String) {
            guard !piece.isEmpty else { return }
            let start = length
            text += piece
            let n = (piece as NSString).length
            for (tag, type) in [("b", "bold"), ("i", "italic"), ("u", "underline"), ("s", "strikethrough")] where (inline[tag] ?? 0) > 0 {
                formats.append(NoteFormat(type: type, location: start, length: n))
            }
            if let href = links.last ?? nil { formats.append(NoteFormat(type: "link", location: start, length: n, url: href)) }
        }

        let scanner = html as NSString
        var i = 0
        while i < scanner.length {
            let lt = scanner.range(of: "<", options: [], range: NSRange(location: i, length: scanner.length - i))
            let textEnd = lt.location == NSNotFound ? scanner.length : lt.location
            if textEnd > i {
                let raw = scanner.substring(with: NSRange(location: i, length: textEnd - i))
                let decoded = decodeEntities(raw.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " "))
                if inTitle { title += decoded }
                else if skipDepth == 0 {
                    let trimmed = length == paragraphStart ? String(decoded.drop { $0 == " " }) : decoded
                    append(trimmed)
                }
            }
            guard lt.location != NSNotFound else { break }
            let gt = scanner.range(of: ">", options: [], range: NSRange(location: lt.location, length: scanner.length - lt.location))
            guard gt.location != NSNotFound else { break }
            let tag = scanner.substring(with: NSRange(location: lt.location + 1, length: gt.location - lt.location - 1))
            i = gt.location + 1
            if tag.hasPrefix("!") || tag.hasPrefix("?") { continue }
            let closing = tag.hasPrefix("/")
            let body = closing ? String(tag.dropFirst()) : tag
            let name = body.split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "\n" || $0 == "\t" }).first.map { $0.lowercased() } ?? ""
            switch name {
            case "head", "style", "script": skipDepth += closing ? -1 : 1; skipDepth = max(skipDepth, 0)
            case "title": inTitle = !closing
            case "h1", "h2", "h3", "h4", "h5", "h6":
                if closing { closeParagraph() } else {
                    // A title heading: class "title", or the page's first h1 (checked against <title> below).
                    let isTitle = attribute("class", in: body)?.split(separator: " ").contains("title") == true
                        || (name == "h1" && text.isEmpty && !formats.contains { $0.type == "title" })
                    openParagraph(isTitle ? "title" : (name == "h1" ? "h1" : name == "h2" ? "h2" : "h3"), nil)
                }
            case "p", "div", "blockquote", "pre": if closing { closeParagraph() } else { openParagraph(nil, nil) }
            case "br": let keep = block; closeParagraph(); block = keep
            case "ul", "ol":
                if closing { if !lists.isEmpty { lists.removeLast() }; closeParagraph() } else { lists.append(name) }
            case "li":
                if closing { closeParagraph() } else {
                    openParagraph(lists.last == "ol" ? "numberedList" : "bulletList", max(0, min(lists.count - 1, 5)))
                }
            case "b", "strong": inline["b", default: 0] += closing ? -1 : 1
            case "i", "em": inline["i", default: 0] += closing ? -1 : 1
            case "u": inline["u", default: 0] += closing ? -1 : 1
            case "s", "strike", "del": inline["s", default: 0] += closing ? -1 : 1
            case "a":
                if closing { if !links.isEmpty { links.removeLast() } }
                else if let href = attribute("href", in: body).map(decodeEntities), let url = URL(string: href),
                    ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { links.append(href) }
                else { links.append(nil) }
            case "img":
                guard skipDepth == 0, let src = attribute("src", in: body), src.hasPrefix("data:"),
                    let comma = src.firstIndex(of: ","), src[..<comma].hasSuffix(";base64"),
                    let data = Data(base64Encoded: String(src[src.index(after: comma)...]), options: .ignoreUnknownCharacters),
                    data.count <= 20 << 20 else { dropped += 1; continue }
                let mime = String(src.dropFirst(5).prefix(while: { $0 != ";" }))
                let ext = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp", "image/heic": "heic", "image/tiff": "tiff"][mime] ?? "png"
                let key = "import-\(images.count)"
                images[key] = (data, ext)
                let at = length
                text += "\u{FFFC}"
                formats.append(NoteFormat(type: "image", location: at, length: 1, url: key))
            default: break
            }
            for key in inline.keys where inline[key]! < 0 { inline[key] = 0 }
        }
        closeParagraph()
        // The page's title heading is the Note title, not body text.
        if let titleFormat = formats.first(where: { $0.type == "title" }) {
            let range = NSRange(location: titleFormat.location, length: titleFormat.length)
            let heading = (text as NSString).substring(with: range).trimmingCharacters(in: .whitespaces)
            if title.trimmingCharacters(in: .whitespaces).isEmpty || heading == title.trimmingCharacters(in: .whitespaces) {
                title = heading
                let cut = NSRange(location: range.location, length: min(range.length + 1, length - range.location))
                text = (text as NSString).replacingCharacters(in: cut, with: "")
                formats = formats.compactMap { f in
                    if f.type == "title" { return nil }
                    if f.location >= NSMaxRange(cut) { var g = f; g.location -= cut.length; return g }
                    if NSMaxRange(NSRange(location: f.location, length: f.length)) <= cut.location { return f }
                    return nil
                }
            }
        }
        formats = formats.map { f in var g = f; if g.type == "title" { g.type = "h1" }; return g }
        while text.hasSuffix("\n") { text.removeLast() }
        let total = (text as NSString).length
        formats = formats.compactMap { f in
            guard f.location < total else { return nil }
            var g = f; g.length = min(g.length, total - g.location); return g.length > 0 || g.type == "image" ? g : nil
        }
        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = NoteDocument(title: finalTitle.isEmpty ? fallbackTitle : finalTitle, text: text, formats: dedupe(merge(formats)))
        return Parsed(arcID: nil, note: note, images: images, droppedImages: dropped)
    }

    /// Joins touching runs of one inline format (text arrives in pieces).
    static func merge(_ formats: [NoteFormat]) -> [NoteFormat] {
        var result: [NoteFormat] = []
        for f in formats.sorted(by: { ($0.type, $0.url ?? "", $0.location) < ($1.type, $1.url ?? "", $1.location) }) {
            if let last = result.last, ["bold", "italic", "underline", "strikethrough", "link"].contains(f.type),
                last.type == f.type, last.url == f.url, last.location + last.length == f.location {
                result[result.count - 1].length += f.length
            } else { result.append(f) }
        }
        return result
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "(?i)\\b\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        for group in 2...4 where match.range(at: group).location != NSNotFound {
            return (tag as NSString).substring(with: match.range(at: group))
        }
        return nil
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = "", i = text.startIndex
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "#39": "'"]
        while i < text.endIndex {
            if text[i] == "&", let semi = text[i...].prefix(12).firstIndex(of: ";") {
                let entity = String(text[text.index(after: i)..<semi])
                var value: String?
                if let v = named[entity] { value = v }
                else if entity.hasPrefix("#x") || entity.hasPrefix("#X"), let code = UInt32(entity.dropFirst(2), radix: 16), let s = Unicode.Scalar(code) { value = String(Character(s)) }
                else if entity.hasPrefix("#"), let code = UInt32(entity.dropFirst()), let s = Unicode.Scalar(code) { value = String(Character(s)) }
                if let value { out += value; i = text.index(after: semi); continue }
            }
            out.append(text[i]); i = text.index(after: i)
        }
        return out
    }
}
