import Foundation
import CryptoKit

/// Reads Arc's "Export All Easels" output (Arc 1.172, findings §3.8): a folder (or the
/// unpacked archive) with one sub-folder per Easel holding `easel.json` and `images/`.
/// Arc keeps Easel content only on its servers, so this export is the only way in.
///
/// Limits: at most 2,000 Easels and 64 MiB per `easel.json` (`EaselDocument.maxFileBytes`);
/// every converted document must pass `EaselDocument.isValid`; picture files go through
/// `EaselStore.addImage` (type, bytes, pixel limits). A folder that breaks a limit is skipped
/// and counted, never partly imported.
public enum EaselImporter {
    public static let maxEasels = 2_000

    public struct Imported: Sendable {
        /// Arc's Easel id (matches the sidebar item's `easelID`, GUESS until a real export is seen).
        public var arcID: String
        public var document: EaselDocument
        /// Picture files to store: source file → the object ids that use it.
        public var pictures: [URL]
    }
    public struct Result: Sendable {
        public var easels: [Imported] = []
        public var skipped: [String] = []
        public var droppedObjects = 0
    }

    /// The Open document id for an Arc Easel id: stable, so a sidebar row imported from Arc
    /// and the export's content meet at the same Easel.
    public static func documentID(forArcEaselID arcID: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("open.easel.arc:\(arcID)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5 style
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Reads every `<folder>/<name>/easel.json` (also `<folder>/easel.json` for a single Easel).
    public static func read(folder: URL) -> Result {
        var result = Result()
        let fm = FileManager.default
        var candidates: [URL] = []
        if fm.fileExists(atPath: folder.appendingPathComponent("easel.json").path) { candidates = [folder] }
        else {
            let children = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            candidates = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .filter { fm.fileExists(atPath: $0.appendingPathComponent("easel.json").path) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        for dir in candidates {
            guard result.easels.count < maxEasels else { result.skipped.append("\(dir.lastPathComponent): over \(maxEasels) Easels"); continue }
            switch convert(dir) {
            case .success(let (item, dropped)): result.easels.append(item); result.droppedObjects += dropped
            case .failure(let message): result.skipped.append("\(dir.lastPathComponent): \(message.text)")
            }
        }
        return result
    }

    struct Message: Error { let text: String }

    static func convert(_ dir: URL) -> Swift.Result<(Imported, Int), Message> {
        let file = dir.appendingPathComponent("easel.json")
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int,
              size <= EaselDocument.maxFileBytes, let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(Message(text: "unreadable easel.json")) }
        guard let arcID = root["id"] as? String, !arcID.isEmpty, arcID.utf8.count <= 256 else { return .failure(Message(text: "no id")) }
        if let version = root["formatVersion"] as? Int, version > 1 { return .failure(Message(text: "format \(version) is newer than this importer")) }
        let rawObjects = root["objects"] as? [[String: Any]] ?? []
        guard rawObjects.count <= EaselDocument.maxObjects else { return .failure(Message(text: "too many objects")) }
        var doc = EaselDocument(id: documentID(forArcEaselID: arcID))
        if let title = root["title"] as? String { doc.title = String(title.prefix(EaselDocument.maxTitleLength)) }
        doc.palette = (root["palette"] as? String).flatMap(EaselPalette.init(rawValue:)) ?? .vibrant
        var pictures: [URL] = [], dropped = 0
        let base = dir.standardizedFileURL.path + "/"
        func picture(_ value: Any?) -> String? {
            guard let src = value as? String, !src.isEmpty, !src.hasPrefix("/"), !src.contains("..") else { return nil }
            let url = dir.appendingPathComponent(src).standardizedFileURL
            guard url.path.hasPrefix(base), FileManager.default.fileExists(atPath: url.path) else { return nil }
            pictures.append(url)
            return "pending:\(pictures.count - 1)"
        }
        for (index, raw) in rawObjects.enumerated() {
            guard let frameRaw = raw["frame"] as? [String: Any], let content = raw["content"] as? [String: Any],
                  let type = content["type"] as? String else { dropped += 1; continue }
            func num(_ k: String) -> CGFloat? { (frameRaw[k] as? NSNumber).map { CGFloat($0.doubleValue) } }
            guard let x = num("x"), let y = num("y"), let w = num("width"), let h = num("height") else { dropped += 1; continue }
            // Export frames are fractions of the 1000-pt width (findings §3.4/§3.8).
            let frame = CGRect(x: x * EaselDocument.width, y: y * EaselDocument.width, width: w * EaselDocument.width, height: h * EaselDocument.width)
            let z = (raw["zIndex"] as? Int) ?? index
            let id = (raw["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            func s(_ k: String) -> String? { (content[k] as? String).map { String($0.prefix(EaselDocument.maxTextLength)) } }
            var converted: EaselContent?
            switch type {
            case "text":
                converted = .text(EaselText(string: s("string") ?? "",
                                            fontFamily: s("fontFamily").flatMap(EaselFontFamily.init(rawValue:)) ?? .clean,
                                            paragraphStyle: s("paragraphStyle").flatMap(EaselParagraphStyle.init(rawValue:)) ?? .body))
            case "richText":
                // Formats are not kept yet; the text is.
                converted = .text(EaselText(string: s("text") ?? ""))
            case "shape":
                guard let kind = s("kind").flatMap(EaselShapeKind.init(rawValue:)) else { break }
                let color = s("color").flatMap(EaselColor.init(rawValue:)) ?? .black
                func point(_ v: Any?) -> EaselPoint? {
                    guard let d = v as? [String: Any], let px = (d["x"] as? NSNumber)?.doubleValue, let py = (d["y"] as? NSNumber)?.doubleValue else { return nil }
                    return EaselPoint(x: px, y: py)
                }
                // GUESS — real export pending: arrow ends and freehand points are fractions of
                // the object frame (as in Open). Values outside -1…2 are read as fractions of
                // the document width and moved into the frame.
                func local(_ p: EaselPoint) -> EaselPoint {
                    if (-1...2).contains(p.x) && (-1...2).contains(p.y) { return p }
                    let dx = p.x * EaselDocument.width, dy = p.y * EaselDocument.width
                    return EaselPoint(x: (dx - frame.minX) / max(frame.width, 1), y: (dy - frame.minY) / max(frame.height, 1))
                }
                var arrow: (EaselPoint, EaselPoint)?
                if let a = content["arrow"] as? [String: Any], let st = point(a["start"]), let en = point(a["end"]) { arrow = (local(st), local(en)) }
                let points = (content["points"] as? [Any])?.prefix(EaselDocument.maxPoints).compactMap(point).map(local)
                converted = .shape(kind: kind, color: color, arrow: arrow.map { (start: $0.0, end: $0.1) }, points: points)
            case "image":
                guard let file = picture(content["src"]) else { break }
                let size = content["size"] as? [String: Any]
                converted = .image(EaselImage(file: file, width: max(1, (size?["width"] as? Int) ?? Int(frame.width * 2)),
                                              height: max(1, (size?["height"] as? Int) ?? Int(frame.height * 2)), altText: s("altText")))
            case "webCard":
                converted = .webCard(EaselWebCard(url: s("url") ?? "", title: s("title"), imageFile: picture(content["image"])))
            case "link":
                converted = .link(EaselLink(source: s("source") ?? "", title: s("title"), summary: s("description"), imageFile: picture(content["image"])))
            case "browser":
                // Open has no browser object: it becomes a link card to the same page.
                if let url = s("url") { converted = .link(EaselLink(source: url)) }
            default: break
            }
            guard let converted else { dropped += 1; continue }
            doc.objects.append(EaselObject(id: id, frame: frame, zIndex: z, content: converted))
        }
        return .success((Imported(arcID: arcID, document: doc, pictures: pictures), dropped))
    }

    /// Replaces `pending:<n>` file names with the stored names; objects whose picture could not
    /// be stored are dropped. Returns the finished document and the dropped count.
    public static func resolvePictures(_ item: Imported, store: (Data) -> EaselImage?) -> (EaselDocument, Int) {
        var stored: [Int: EaselImage] = [:]
        for (n, url) in item.pictures.enumerated() {
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size <= 50 << 20,
               let data = try? Data(contentsOf: url), let image = store(data) { stored[n] = image }
        }
        func real(_ name: String?) -> (ok: Bool, name: String?) {
            guard let name else { return (true, nil) }
            guard name.hasPrefix("pending:"), let n = Int(name.dropFirst(8)) else { return (true, name) }
            return stored[n].map { (true, $0.file) } ?? (false, nil)
        }
        var doc = item.document, dropped = 0
        doc.objects = doc.objects.compactMap { (o: EaselObject) -> EaselObject? in
            var o = o
            switch o.content {
            case .image(var i):
                let pendingIndex = i.file.hasPrefix("pending:") ? Int(i.file.dropFirst(8)) : nil
                let r = real(i.file)
                guard r.ok, let f = r.name else { dropped += 1; return nil }
                i.file = f
                if let n = pendingIndex, let s = stored[n] { i.width = s.width; i.height = s.height }
                o.content = .image(i)
            case .webCard(var w): w.imageFile = real(w.imageFile).name; o.content = .webCard(w)
            case .link(var l): l.imageFile = real(l.imageFile).name; o.content = .link(l)
            default: break
            }
            return o
        }
        return (doc, dropped)
    }
}
