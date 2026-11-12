import Foundation

/// Netscape bookmark file (`<DL><DT><H3>…<A HREF>`), as Safari, Chrome and Firefox export it.
/// Tolerant tokenizer: unknown tags are ignored; separators (`<HR>`) are counted and dropped.
/// Source IDs are folder-path positions, so re-importing the same file maps to the same items.
public enum BookmarksHTMLParser {
    public enum ParseError: Error, Equatable { case notBookmarksFile }

    public static func parse(_ data: Data) throws -> (roots: [ImportedBookmark], report: ImportedBookmarksReport) {
        guard data.count <= 64 << 20 else { throw ParseError.notBookmarksFile }
        let text = String(decoding: data, as: UTF8.self)
        guard text.range(of: "<DL", options: .caseInsensitive) != nil else { throw ParseError.notBookmarksFile }
        final class Frame { var id: String; var title: String; var children: [ImportedBookmark] = []; init(_ id: String, _ title: String) { self.id = id; self.title = title } }
        var stack = [Frame("html", "")]
        var report = ImportedBookmarksReport()
        var pendingFolder: String?
        var sawFirstDL = false
        var scanner = text[...]
        while let open = scanner.firstIndex(of: "<") {
            scanner = scanner[open...]
            guard let close = scanner.firstIndex(of: ">") else { break }
            let tag = scanner[scanner.index(after: open)..<close]
            let name = tag.prefix { !$0.isWhitespace && $0 != ">" }.uppercased()
            scanner = scanner[scanner.index(after: close)...]
            switch name {
            case "H3":
                let end = scanner.range(of: "</H3", options: .caseInsensitive)?.lowerBound ?? scanner.endIndex
                pendingFolder = decode(String(scanner[..<end]))
                scanner = scanner[end...]
            case "DL":
                if !sawFirstDL && pendingFolder == nil { sawFirstDL = true; continue }
                sawFirstDL = true
                let parent = stack[stack.count - 1]
                let title = pendingFolder ?? ""
                stack.append(Frame(parent.id + "/" + String(parent.children.count) + ":" + title, title))
                report.sourceRows += 1
                pendingFolder = nil
            case "/DL":
                guard stack.count > 1 else { continue }
                let frame = stack.removeLast()
                if frame.children.isEmpty { report.skippedEmptyFolders += 1 }
                else {
                    report.folders += 1
                    stack[stack.count - 1].children.append(.folder(sourceID: frame.id, title: frame.title, children: frame.children))
                }
            case "A":
                report.sourceRows += 1
                let end = scanner.range(of: "</A", options: .caseInsensitive)?.lowerBound ?? scanner.endIndex
                let title = decode(String(scanner[..<end]))
                scanner = scanner[end...]
                guard let href = attribute("HREF", in: String(tag)), let url = URL(string: href),
                      ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { report.skippedUnsupportedURL += 1; continue }
                let added = attribute("ADD_DATE", in: String(tag)).flatMap(Double.init).flatMap { validatedImportDate(unixSeconds: $0) }
                let frame = stack[stack.count - 1]
                frame.children.append(.url(sourceID: frame.id + "/" + String(frame.children.count), title: title.isEmpty ? href : title, url: url, dateAdded: added))
                report.urls += 1
            case "HR":
                report.sourceRows += 1; report.skippedSeparators += 1
            default: continue
            }
        }
        // Unclosed lists still land.
        while stack.count > 1 {
            let frame = stack.removeLast()
            if frame.children.isEmpty { report.skippedEmptyFolders += 1 }
            else { report.folders += 1; stack[stack.count - 1].children.append(.folder(sourceID: frame.id, title: frame.title, children: frame.children)) }
        }
        return (stack[0].children, report)
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: name + "=", options: .caseInsensitive) else { return nil }
        var rest = tag[range.upperBound...]
        if let quote = rest.first, quote == "\"" || quote == "'" {
            rest = rest.dropFirst()
            return decode(String(rest.prefix { $0 != quote }))
        }
        return decode(String(rest.prefix { !$0.isWhitespace }))
    }

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var out = "", rest = s[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            rest = rest[amp...]
            guard let semi = rest.firstIndex(of: ";"), rest.distance(from: amp, to: semi) <= 10 else { out += "&"; rest = rest.dropFirst(); continue }
            let entity = rest[rest.index(after: amp)..<semi]
            let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "#39": "'", "nbsp": " "]
            if let value = named[String(entity)] { out += value }
            else if entity.hasPrefix("#x") || entity.hasPrefix("#X"), let v = UInt32(entity.dropFirst(2), radix: 16), let c = Unicode.Scalar(v) { out.unicodeScalars.append(c) }
            else if entity.hasPrefix("#"), let v = UInt32(entity.dropFirst()), let c = Unicode.Scalar(v) { out.unicodeScalars.append(c) }
            else { out += rest[...semi] }
            rest = rest[rest.index(after: semi)...]
        }
        return (out + rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
