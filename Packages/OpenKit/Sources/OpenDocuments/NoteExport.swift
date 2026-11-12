import Foundation

/// Markdown and self-contained HTML for a Note. Arc's "Export Arc Notes" writes one
/// HTML file per Note with images inline as `data:` URLs (docs/re/easels-notes.md §4.6);
/// Open does the same and adds Markdown with images in a folder beside it.
public enum NoteExport {
    struct Paragraph { let range: NSRange; let block: NoteFormat? }
    struct Style: Equatable { var bold = false, italic = false, underline = false, strike = false; var link: String?; var image: String? }

    static func paragraphs(_ note: NoteDocument) -> [Paragraph] {
        let text = note.text as NSString
        var result: [Paragraph] = []
        let blocks = note.formats.filter { ["h1", "h2", "h3", "bulletList", "numberedList"].contains($0.type) }
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            let block = blocks.first { $0.location <= range.location && range.location < max($0.location + $0.length, $0.location + 1) }
            result.append(Paragraph(range: range, block: block))
        }
        if text.length == 0 { return [] }
        return result
    }

    /// Runs of one inline style inside `range`.
    static func runs(_ note: NoteDocument, in range: NSRange) -> [(String, Style)] {
        let text = note.text as NSString
        guard range.length > 0 else { return [] }
        var styles = Array(repeating: Style(), count: range.length)
        for format in note.formats {
            let lower = max(format.location, range.location), upper = min(format.location + format.length, NSMaxRange(range))
            guard lower < upper else { continue }
            for i in (lower - range.location)..<(upper - range.location) {
                switch format.type {
                case "bold": styles[i].bold = true
                case "italic": styles[i].italic = true
                case "underline": styles[i].underline = true
                case "strikethrough": styles[i].strike = true
                case "link": styles[i].link = format.url
                case "image": styles[i].image = format.url
                default: break
                }
            }
        }
        var result: [(String, Style)] = []
        var start = 0
        for i in 1...range.length where i == range.length || styles[i] != styles[start] || styles[i].image != nil || styles[start].image != nil {
            result.append((text.substring(with: NSRange(location: range.location + start, length: i - start)), styles[start]))
            start = i
        }
        return result
    }

    // MARK: Markdown

    public static func markdown(_ note: NoteDocument, imagePath: (String) -> String = { "images/" + $0 }) -> String {
        var lines: [String] = []
        if !note.title.isEmpty { lines.append("# " + escapeMarkdown(note.title)); lines.append("") }
        var counters: [Int: Int] = [:]
        for paragraph in paragraphs(note) {
            var body = ""
            for (text, style) in runs(note, in: paragraph.range) {
                if let image = style.image { body += "![](\(imagePath(image)))"; continue }
                var piece = escapeMarkdown(text)
                if style.strike { piece = "~~\(piece)~~" }
                if style.underline { piece = "<u>\(piece)</u>" }
                if style.italic { piece = "*\(piece)*" }
                if style.bold { piece = "**\(piece)**" }
                if let link = style.link { piece = "[\(piece)](\(link))" }
                body += piece
            }
            let level = paragraph.block?.level ?? 0
            switch paragraph.block?.type {
            case "h1": counters.removeAll(); lines.append("## " + body)       // the title is the document's #
            case "h2": counters.removeAll(); lines.append("### " + body)
            case "h3": counters.removeAll(); lines.append("#### " + body)
            case "bulletList":
                counters = counters.filter { $0.key < level }
                lines.append(String(repeating: "  ", count: level) + "- " + body)
            case "numberedList":
                counters = counters.filter { $0.key <= level }
                let n = (counters[level] ?? 0) + 1; counters[level] = n
                lines.append(String(repeating: "   ", count: level) + "\(n). " + body)
            default:
                counters.removeAll()
                lines.append(body.isEmpty ? "" : body + "  ")
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func escapeMarkdown(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "\\`*_[]#<>~".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    // MARK: HTML

    /// One self-contained page. `image` returns the bytes and MIME type of an asset, or nil to drop it.
    public static func html(_ note: NoteDocument, image: (String) -> (Data, String)?) -> String {
        var out = "<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>\(escapeHTML(note.title.isEmpty ? "Untitled" : note.title))</title>\n"
        out += "<style>body{font:16px/1.45 -apple-system,system-ui,sans-serif;max-width:680px;margin:48px auto;padding:0 20px;color:#111}"
        out += "h1.title{font-size:30px;color:#220C7F}h1,h2,h3{color:#6E678D}img{max-width:100%}"
        out += "@media (prefers-color-scheme:dark){body{background:#121212;color:#fff}h1.title{color:#E6E6FF}h1,h2,h3{color:#CDCDFF}a{color:#E6E6FF}}</style>\n"
        out += "</head><body>\n<h1 class=\"title\">\(escapeHTML(note.title))</h1>\n"
        var openLists: [(String, Int)] = []   // (tag, level)
        func closeLists(downTo level: Int) {
            while let last = openLists.last, last.1 >= level { out += "</li></\(last.0)>\n"; openLists.removeLast() }
        }
        for paragraph in paragraphs(note) {
            var body = ""
            for (text, style) in runs(note, in: paragraph.range) {
                if let name = style.image {
                    if let (data, mime) = image(name) { body += "<img alt=\"\" src=\"data:\(mime);base64,\(data.base64EncodedString())\">" }
                    continue
                }
                var piece = escapeHTML(text)
                if style.strike { piece = "<s>\(piece)</s>" }
                if style.underline { piece = "<u>\(piece)</u>" }
                if style.italic { piece = "<em>\(piece)</em>" }
                if style.bold { piece = "<strong>\(piece)</strong>" }
                if let link = style.link, let url = URL(string: link), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    piece = "<a href=\"\(escapeHTML(link))\">\(piece)</a>"
                }
                body += piece
            }
            switch paragraph.block?.type {
            case "bulletList", "numberedList":
                let tag = paragraph.block?.type == "bulletList" ? "ul" : "ol"
                let level = paragraph.block?.level ?? 0
                if let last = openLists.last, last.1 == level, last.0 == tag { out += "</li>\n<li>" + body }
                else if let last = openLists.last, last.1 < level { openLists.append((tag, level)); out += "\n<\(tag)><li>" + body }
                else {
                    closeLists(downTo: level)
                    if let last = openLists.last, last.1 == level, last.0 == tag { out += "</li>\n<li>" + body }
                    else {
                        if let last = openLists.last, last.1 == level { out += "</li></\(last.0)>\n"; openLists.removeLast() }
                        openLists.append((tag, level)); out += "<\(tag)><li>" + body
                    }
                }
            default:
                closeLists(downTo: 0)
                switch paragraph.block?.type {
                case "h1": out += "<h1>\(body)</h1>\n"
                case "h2": out += "<h2>\(body)</h2>\n"
                case "h3": out += "<h3>\(body)</h3>\n"
                default: out += body.isEmpty ? "<p><br></p>\n" : "<p>\(body)</p>\n"
                }
            }
        }
        closeLists(downTo: 0)
        return out + "</body></html>\n"
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A file name for a Note: its title without path characters, unique in `used`.
    public static func fileName(for note: NoteDocument, used: inout Set<String>) -> String {
        var base = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "/:\\\0\n\r\t")).joined(separator: "-")
        if base.isEmpty || base.hasPrefix(".") { base = "Untitled" + (base.isEmpty ? "" : base) }
        base = String(base.prefix(80))
        var name = base, n = 2
        while used.contains(name.lowercased()) { name = "\(base) \(n)"; n += 1 }
        used.insert(name.lowercased())
        return name
    }
}

extension NoteStore {
    /// Every stored Note that can be read, oldest first (so the first Note keeps the plain file name). Unreadable files are skipped and counted.
    public func allNotes() -> (notes: [NoteDocument], unreadable: Int) {
        flush()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var notes: [NoteDocument] = [], bad = 0
        for name in names where name.hasSuffix(".json") {
            guard let id = UUID(uuidString: String(name.dropLast(5))) else { continue }
            if let note = load(id) { notes.append(note) } else { bad += 1 }
        }
        return (notes.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }, bad)
    }
}
