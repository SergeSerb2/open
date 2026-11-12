import Foundation

/// Easel → web page you can open anywhere (Arc 1.172 "Export All Easels", findings §3.8).
/// Layout of one export: `index.html` (our own viewer: inline CSS/JS, system fonts, no Arc
/// files), `easel.json` (the export schema of findings §3.8: frames as fractions of the
/// width, `type` discriminator), and `images/`. "Export all" writes one folder per Easel plus
/// an `index.html` list.
public enum EaselExporter {
    public struct Item: Sendable {
        public var document: EaselDocument
        public var imagesDirectory: URL
        public init(document: EaselDocument, imagesDirectory: URL) { self.document = document; self.imagesDirectory = imagesDirectory }
    }

    public enum Failure: Error, CustomStringConvertible {
        case write(String)
        public var description: String { switch self { case .write(let s): s } }
    }

    /// Writes one Easel into `folder` (created; must not exist yet).
    public static func export(_ item: Item, to folder: URL) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            let images = folder.appendingPathComponent("images", isDirectory: true)
            let used = Set(item.document.objects.flatMap(\.content.imageFiles))
            if !used.isEmpty { try fm.createDirectory(at: images, withIntermediateDirectories: false) }
            for file in used where EaselDocument.isImageFileName(file) {
                let source = item.imagesDirectory.appendingPathComponent(file)
                if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: images.appendingPathComponent(file)) }
            }
            let json = try exportJSON(item.document)
            try json.write(to: folder.appendingPathComponent("easel.json"), options: .atomic)
            try page(title: item.document.displayTitle, json: json).write(to: folder.appendingPathComponent("index.html"), options: .atomic)
        } catch let error as Failure { throw error } catch { throw Failure.write(error.localizedDescription) }
    }

    /// Writes every Easel into `folder` (created): one sub-folder each, and an index page.
    /// Returns the number written; a failed Easel is skipped and listed in `failures`.
    @discardableResult
    public static func exportAll(_ items: [Item], to folder: URL, failures: inout [String]) throws -> Int {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        var names = Set<String>(), rows: [(String, String)] = []
        for item in items {
            var name = folderName(item.document.displayTitle), n = 2
            while names.contains(name.lowercased()) { name = "\(folderName(item.document.displayTitle)) \(n)"; n += 1 }
            names.insert(name.lowercased())
            do { try export(item, to: folder.appendingPathComponent(name, isDirectory: true)); rows.append((name, item.document.displayTitle)) }
            catch { failures.append("\(item.document.displayTitle): \(error)") }
        }
        let list = rows.map { "<li><a href=\"\(attr(percent($0.0)))/index.html\">\(html($0.1))</a></li>" }.joined(separator: "\n")
        let index = """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Easels</title><style>body{font:16px -apple-system,system-ui,sans-serif;max-width:720px;margin:48px auto;padding:0 16px;color:#101118}
        h1{font-size:28px}li{margin:8px 0}a{color:#2930fb}@media(prefers-color-scheme:dark){body{background:#16121b;color:#eee}a{color:#8f95ff}}</style>
        </head><body><h1>Easels</h1><ul>
        \(list)
        </ul></body></html>
        """
        try Data(index.utf8).write(to: folder.appendingPathComponent("index.html"), options: .atomic)
        return rows.count
    }

    /// A safe folder name from a title: no slashes, colons, or leading dots; ≤ 80 characters.
    public static func folderName(_ title: String) -> String {
        let cleaned = title.map { "/:\\\0".contains($0) || $0.isNewline ? "-" : $0 }
        var s = String(cleaned).trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        s = String(s.prefix(80))
        return s.isEmpty ? EaselDocument.untitled : s
    }

    // MARK: Export JSON (findings §3.8 schema)

    static func exportJSON(_ doc: EaselDocument) throws -> Data {
        let w = EaselDocument.width
        func frame(_ r: CGRect) -> [String: Double] {
            ["x": Double(r.minX / w), "y": Double(r.minY / w), "width": Double(r.width / w), "height": Double(r.height / w)]
        }
        let iso = ISO8601DateFormatter()
        let objects: [[String: Any]] = doc.paintOrder.map { o in
            var content: [String: Any]
            switch o.content {
            case .text(let t): content = ["type": "text", "string": t.string, "fontFamily": t.fontFamily.rawValue, "paragraphStyle": t.paragraphStyle.rawValue]
            case .shape(let kind, let color, let arrow, let points):
                content = ["type": "shape", "kind": kind.rawValue, "color": color.rawValue]
                if let arrow { content["arrow"] = ["start": ["x": arrow.start.x, "y": arrow.start.y], "end": ["x": arrow.end.x, "y": arrow.end.y]] }
                if let points { content["points"] = points.map { ["x": $0.x, "y": $0.y] } }
            case .image(let i):
                content = ["type": "image", "src": "images/\(i.file)", "size": ["width": i.width, "height": i.height]]
                if let alt = i.altText { content["altText"] = alt }
            case .webCard(let c):
                content = ["type": "webCard", "url": c.url]
                if let t = c.title { content["title"] = t }
                if let f = c.imageFile { content["image"] = "images/\(f)" }
                if let d = c.capturedAt { content["dateCaptured"] = iso.string(from: d) }
            case .link(let l):
                content = ["type": "link", "source": l.source]
                if let t = l.title { content["title"] = t }
                if let s = l.summary { content["description"] = s }
                if let f = l.imageFile { content["image"] = "images/\(f)" }
            }
            return ["id": o.id.uuidString.lowercased(), "frame": frame(o.frame), "zIndex": o.zIndex, "content": content]
        }
        var root: [String: Any] = ["formatVersion": 1, "id": doc.id.uuidString.lowercased(), "palette": doc.palette.rawValue,
                                   "exportedAt": iso.string(from: Date()), "objects": objects]
        if let title = doc.title { root["title"] = title }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    // MARK: Viewer page

    static func html(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    static func attr(_ s: String) -> String { html(s).replacingOccurrences(of: "\"", with: "&quot;") }
    static func percent(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s }

    /// The palette hex values match `EaselPalette` (light; black and white swap in dark).
    static func paletteJS() -> String {
        func hex(_ p: EaselPalette, _ c: EaselColor) -> String {
            switch c {
            case .white: return "#FFFFFF"
            case .black: return "#000000"
            case .gray: return "#BBBBBB"
            case .darkBlue: return "#3139FB"
            case .pink: return p == .vibrant ? "#FF994E" : "#F2C2AC"
            case .red: return p == .vibrant ? "#F53714" : "#D74807"
            case .yellow: return p == .vibrant ? "#FFD335" : "#C2A12A"
            case .lightGreen: return p == .vibrant ? "#34E895" : "#D0D87F"
            case .darkGreen: return p == .vibrant ? "#107A00" : "#1D5914"
            case .lightBlue: return p == .vibrant ? "#00C7F3" : "#55A2BD"
            case .purple: return p == .vibrant ? "#C0009F" : "#A6729D"
            }
        }
        let rows = EaselPalette.allCases.map { p in
            "\(p.rawValue):{" + EaselColor.allCases.map { "\($0.rawValue):'\(hex(p, $0))'" }.joined(separator: ",") + "}"
        }
        return "{" + rows.joined(separator: ",") + "}"
    }

    static func page(title: String, json: Data) -> Data {
        // The JSON goes into a <script type="application/json"> block; "</" is escaped so no
        // value can end the block early.
        let embedded = String(decoding: json, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
        let text = """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(html(title))</title>
        <style>
        :root{--bg:#fdfcfd;--ink:#101118;--card:#fff;--edge:rgba(0,0,0,.08)}
        @media(prefers-color-scheme:dark){:root{--bg:#16121b;--ink:#f2f2f5;--card:#050625;--edge:rgba(255,255,255,.1)}}
        body{margin:0;background:var(--bg);color:var(--ink);font-family:-apple-system,system-ui,sans-serif}
        h1{text-align:center;font-size:26px;margin:32px 16px 0;font-weight:700;opacity:.8}
        #page{position:relative;width:min(1000px,100vw);margin:0 auto}
        .o{position:absolute;box-sizing:border-box}
        .t{padding:0 .5%;white-space:pre-wrap;overflow:hidden}
        .card{border-radius:10px;overflow:hidden;border:1px solid var(--edge);background:var(--card)}
        .card img,.img img{width:100%;height:100%;object-fit:cover;display:block}
        .img{border-radius:6px;overflow:hidden}
        .meta{position:absolute;left:0;right:0;bottom:0;padding:8px 12px;font-size:13px}
        .meta b{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .meta span{opacity:.55;font-size:12px;display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        a{color:inherit;text-decoration:none}
        </style></head><body><h1 id="title"></h1><div id="page"></div>
        <script type="application/json" id="easel">\(embedded)</script>
        <script>
        (function(){
          var doc=JSON.parse(document.getElementById('easel').textContent);
          var dark=matchMedia('(prefers-color-scheme: dark)').matches;
          var pal=\(paletteJS())[doc.palette]||{};
          function color(n){if(dark&&n==='white')return '#000000';if(dark&&n==='black')return '#FFFFFF';return pal[n]||'#888'}
          var sizes={clean:{ultra:80,h0:60,h1:44,h2:24,body:15},mono:{ultra:80,h0:60,h1:44,h2:24,body:15},fancy:{ultra:80,h0:60,h1:48,h2:28,body:16},hip:{ultra:80,h0:60,h1:44,h2:21,body:18}};
          var faces={clean:'-apple-system,system-ui,sans-serif',mono:'ui-monospace,Menlo,monospace',fancy:'ui-serif,Georgia,serif',hip:'ui-rounded,-apple-system,sans-serif'};
          document.getElementById('title').textContent=doc.title||'Untitled Easel';
          var page=document.getElementById('page'),bottom=0;
          function el(tag,cls){var e=document.createElement(tag);if(cls)e.className=cls;return e}
          function safe(u){try{var x=new URL(u,location.href);return /^https?:|^file:/.test(x.protocol)?x.href:'#'}catch(e){return '#'}}
          function host(u){try{return new URL(u).host.replace(/^www\\./,'')}catch(e){return u}}
          doc.objects.forEach(function(o){
            var f=o.frame,c=o.content,e;bottom=Math.max(bottom,f.y+f.height);
            if(c.type==='text'){e=el('div','o t');e.textContent=c.string;var s=(sizes[c.fontFamily]||sizes.clean)[c.paragraphStyle]||15;
              e.style.fontFamily=faces[c.fontFamily]||faces.clean;e.style.fontSize='calc(min(1000px,100vw)*'+(s/1000)+')';
              e.style.fontWeight=c.paragraphStyle==='body'?'400':'800';e.style.textAlign=c.paragraphStyle==='body'?'left':'center'}
            else if(c.type==='shape'){e=el('div','o');var ns='http://www.w3.org/2000/svg',svg=document.createElementNS(ns,'svg');
              svg.setAttribute('viewBox','0 0 100 100');svg.setAttribute('preserveAspectRatio','none');svg.style.width='100%';svg.style.height='100%';svg.style.overflow='visible';
              var col=color(c.color),p;
              if(c.kind==='rectangle'){p=document.createElementNS(ns,'rect');p.setAttribute('x',0);p.setAttribute('y',0);p.setAttribute('width',100);p.setAttribute('height',100)}
              else if(c.kind==='circle'){p=document.createElementNS(ns,'ellipse');p.setAttribute('cx',50);p.setAttribute('cy',50);p.setAttribute('rx',50);p.setAttribute('ry',50)}
              else{p=document.createElementNS(ns,'path');var pts=c.kind==='arrow'&&c.arrow?[c.arrow.start,c.arrow.end]:(c.points||[]);
                var d=pts.map(function(q,i){return (i?'L':'M')+(q.x*100)+' '+(q.y*100)}).join(' ');
                if(c.kind==='arrow'&&pts.length===2){var a=pts[0],b=pts[1],dx=(b.x-a.x)*f.width,dy=(b.y-a.y)*f.height,len=Math.hypot(dx,dy)||1,h=Math.min(.032,.3*len),ang=Math.atan2(dy,dx);
                  [Math.PI*.75,-Math.PI*.75].forEach(function(t){d+=' M'+(b.x*100)+' '+(b.y*100)+' L'+((b.x+h*Math.cos(ang+t)/f.width)*100)+' '+((b.y+h*Math.sin(ang+t)/f.height)*100)})}
                p.setAttribute('d',d);p.setAttribute('fill','none')}
              if(c.kind==='rectangle'||c.kind==='circle'){p.setAttribute('fill',col);p.setAttribute('fill-opacity','.75')}
              p.setAttribute('stroke',c.color==='white'?'rgba(0,0,0,.1)':col);p.setAttribute('stroke-width','2.5');p.setAttribute('vector-effect','non-scaling-stroke');
              p.setAttribute('stroke-linecap','round');p.setAttribute('stroke-linejoin','round');svg.appendChild(p);e.appendChild(svg)}
            else if(c.type==='image'){e=el('div','o img');var im=el('img');im.src=c.src;im.alt=c.altText||'';e.appendChild(im)}
            else if(c.type==='webCard'){e=el('a','o card');e.href=safe(c.url);e.title=c.title||c.url;if(c.image){var wi=el('img');wi.src=c.image;wi.alt=c.title||'';e.appendChild(wi)}}
            else if(c.type==='link'){e=el('a','o card');e.href=safe(c.source);if(c.image){var li=el('img');li.src=c.image;li.alt='';li.style.height='calc(100% - 64px)';e.appendChild(li)}
              var m=el('div','meta'),b=el('b');b.textContent=c.title||host(c.source);m.appendChild(b);
              if(c.description){var sd=el('span');sd.textContent=c.description;m.appendChild(sd)}
              var sh=el('span');sh.textContent=host(c.source);m.appendChild(sh);e.appendChild(m)}
            else return;
            e.style.left=(f.x*100)+'%';e.style.top='calc(min(1000px,100vw)*'+f.y+')';e.style.width=(f.width*100)+'%';
            e.style.height='calc(min(1000px,100vw)*'+f.height+')';e.style.zIndex=o.zIndex;page.appendChild(e)});
          page.style.height='calc(min(1000px,100vw)*'+(bottom+.1)+')';
        })();
        </script></body></html>
        """
        return Data(text.utf8)
    }
}
