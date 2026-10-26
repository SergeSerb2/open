import AppKit
import OpenDesign

/// Private captures enter only this command. Crops and reports stay in --out.
@MainActor
enum EditorCompare {
    static func crop(_ input: Bitmap, rect: CGRect) -> Bitmap {
        var output = Bitmap(width: Int(rect.width), height: Int(rect.height), fill: 255)
        for y in 0..<output.height { for x in 0..<output.width { output.set(x, y, input.pixel(x + Int(rect.minX), y + Int(rect.minY))) } }
        return output
    }
    static func median(_ image: Bitmap, rect: CGRect) -> [Double] {
        let (x0, y0, x1, y1) = image.clamp(rect)
        var channels = [[Double]](repeating: [], count: 3)
        for y in y0..<y1 { for x in x0..<x1 {
            let p = image.pixel(x, y); for c in 0..<3 { channels[c].append(p[c]) }
        } }
        return channels.map { channel in let values = channel.sorted(); return values[values.count / 2] }
    }
    static func run(_ args: [String]) throws {
        guard let capture = RenderCLI.value(args, "--arc"), let oursPath = RenderCLI.value(args, "--ours"),
              let out = RenderCLI.value(args, "--out") else { throw CLIError(description: RenderCLI.usage) }
        let input = try Bitmap(path: capture), ours = try Bitmap(path: oursPath)
        let arc: Bitmap
        if input.width == 382 && input.height == 534 { arc = input }
        else if input.width >= 882 && input.height >= 569 { arc = crop(input, rect: CGRect(x: 500, y: 35, width: 382, height: 534)) }
        else { throw CLIError(description: "capture cannot contain the AX panel crop") }
        guard ours.width == 382 && ours.height == 534 else { throw CLIError(description: "editor comparison requires scale 1") }
        let directory = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // These outputs contain capture pixels; callers must use the ignored .re directory.
        guard directory.standardizedFileURL.path.contains("/.re/") else { throw CLIError(description: "capture comparisons must be written under .re") }
        var rows: [Compare.Result] = []
        let center = CGPoint(x: 13 + 178 + 170 * ThemeColorMath.knob(for: ThemeColorMath.toP3(EditorScene.capturedStyle.keyColor), range: 0.01...0.97).x,
                             y: 13 + 178 + 170 * ThemeColorMath.knob(for: ThemeColorMath.toP3(EditorScene.capturedStyle.keyColor), range: 0.01...0.97).y)
        func fill(_ name: String, _ rect: CGRect, limit: Double) {
            var row = Compare.Result(name: name)
            row.arcColor = median(arc, rect: rect); row.oursColor = median(ours, rect: rect)
            row.deltaE = ColorMath.deltaE2000(row.arcColor!, row.oursColor!)
            row.note = "ΔE00 ≤ \(Int(limit))"; rows.append(row)
        }
        fill("pad plate", CGRect(x: 35, y: 110, width: 60, height: 60), limit: 3)
        fill("selected mode plate", CGRect(x: 140, y: 47, width: 4, height: 24), limit: 3)
        // Low-contrast plates have a varying material behind them. Find the
        // strongest median strip step at each edge; grid dots and glyphs cannot
        // move the edge as they can move a center-row threshold box.
        func edge(_ image: Bitmap, expected: Int, vertical: Bool, span: Range<Int>) -> Double {
            func level(_ position: Int) -> Double {
                let values = span.map { vertical ? image.lum(position, $0) : image.lum($0, position) }.sorted()
                return values[values.count / 2]
            }
            return Double(((expected - 4)...(expected + 4)).max { abs(level($0) - level($0 - 1)) < abs(level($1) - level($1 - 1)) }!)
        }
        for (name, frame, verticalSpan, horizontalSpan) in [
            ("material body frame", CGRect(x: 13, y: 13, width: 356, height: 508), 110..<175, 100..<180),
            ("pad frame", CGRect(x: 21, y: 21, width: 340, height: 340), 110..<175, 35..<95),
            ("selected mode frame", CGRect(x: 135, y: 45, width: 32, height: 32), 55..<67, 145..<157)] {
            func box(_ image: Bitmap) -> CGRect {
                let x0 = edge(image, expected: Int(frame.minX), vertical: true, span: verticalSpan)
                let x1 = edge(image, expected: Int(frame.maxX), vertical: true, span: verticalSpan)
                let y0 = edge(image, expected: Int(frame.minY), vertical: false, span: horizontalSpan)
                let y1 = edge(image, expected: Int(frame.maxY), vertical: false, span: horizontalSpan)
                return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            }
            var row = Compare.Result(name: name); let a = box(arc), o = box(ours)
            row.arcBox = a; row.oursBox = o
            row.positionError = zip([a.minX, a.maxX, a.minY, a.maxY], [o.minX, o.maxX, o.minY, o.maxY]).map { abs($0 - $1) }.max()
            row.note = "median edge step; error ≤ 1 pt"; rows.append(row)
        }
        var corner = Compare.Result(name: "material continuous corners")
        var cornerError = 0.0
        for right in [false, true] { for bottom in [false, true] {
            func profile(_ image: Bitmap) -> [CGPoint] {
                var points = [CGPoint(x: 40, y: 0)]
                for row in 0..<20 {
                    let y = bottom ? 520 - row : 13 + row
                    let inside = image.lum(right ? 329 : 53, y), half = (255 + inside) / 2
                    var previous = 255.0
                    for column in 0..<40 {
                        let x = right ? 368 - column : 13 + column, value = image.lum(x, y)
                        if value <= half {
                            points.append(CGPoint(x: Double(column) - 0.5 + (previous - half) / max(0.01, previous - value), y: Double(row) + 0.5)); break
                        }
                        previous = value
                    }
                }
                points.append(CGPoint(x: 0, y: 40)); return points
            }
            let a = profile(arc), o = profile(ours)
            func distance(_ point: CGPoint, to line: [CGPoint]) -> Double {
                zip(line, line.dropFirst()).map { p, q in
                    let dx = q.x - p.x, dy = q.y - p.y
                    let t = min(1, max(0, ((point.x - p.x) * dx + (point.y - p.y) * dy) / max(0.0001, dx * dx + dy * dy)))
                    return hypot(point.x - p.x - t * dx, point.y - p.y - t * dy)
                }.min() ?? .infinity
            }
            for point in a { cornerError = max(cornerError, distance(point, to: o)) }
            for point in o { cornerError = max(cornerError, distance(point, to: a)) }
        } }
        corner.positionError = cornerError; corner.note = "four continuous-20 profiles; max normal distance ≤ 1 pt"
        rows.append(corner)
        fill("knob disc", CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14), limit: 2)
        // Ring core excludes antialiased edges and the colored disc.
        fill("knob ring", CGRect(x: center.x - 2, y: center.y - 20, width: 4, height: 2), limit: 2)
        for (name, rect) in [("Automatic glyph", CGRect(x: 141, y: 48, width: 22, height: 24)),
                             ("Light glyph", CGRect(x: 179, y: 49, width: 24, height: 24)),
                             ("Dark glyph", CGRect(x: 219, y: 49, width: 24, height: 25)),
                             ("Remove glyph", CGRect(x: 160, y: 319, width: 22, height: 22)),
                             ("Add glyph", CGRect(x: 200, y: 319, width: 22, height: 22))] {
            var row = Compare.measure(.init(name: name, region: rect, kind: .ink), arc: arc, ours: ours, scale: 1)
            if let a = row.arcBox, let o = row.oursBox {
                row.positionError = max(abs(a.midX - o.midX), abs(a.midY - o.midY), abs(a.height - o.height))
                row.note = String(format: "center Δ %.1f,%.1f pt; height Δ %.1f pt; shape masked; ΔE00 ≤ 2", o.midX - a.midX, o.midY - a.midY, o.height - a.height)
            }
            if let ac = row.arcColor, let oc = row.oursColor {
                func background(_ image: Bitmap) -> [Double] {
                    var channels = [[Double]](repeating: [], count: 3)
                    let r = rect.insetBy(dx: -1, dy: -1), (x0, y0, x1, y1) = image.clamp(r)
                    for y in y0..<y1 { for x in x0..<x1 where x == x0 || x == x1 - 1 || y == y0 || y == y1 - 1 {
                        let pixel = image.pixel(x, y); for c in 0..<3 { channels[c].append(pixel[c]) }
                    } }
                    return channels.map { let values = $0.sorted(); return values[values.count / 2] }
                }
                let ab = background(arc), ob = background(ours)
                let normalized = (0..<3).map { c -> Double in
                    let alpha = min(1, max(0, (ac[c] - ab[c]) / max(1, 255 - ab[c])))
                    return ob[c] + (255 - ob[c]) * alpha
                }
                row.deltaE = ColorMath.deltaE2000(normalized, oc)
                row.note += "; core ΔE compensates local material tint"
            }
            rows.append(row)
        }
        func whiteBox(_ image: Bitmap, in rect: CGRect) -> CGRect? {
            let (x0, y0, x1, y1) = image.clamp(rect)
            var box: CGRect?
            for y in y0..<y1 { for x in x0..<x1 where image.pixel(x, y).min()! > 220 {
                let pixel = CGRect(x: x, y: y, width: 1, height: 1); box = box.map { $0.union(pixel) } ?? pixel
            } }
            return box
        }
        var geometry = Compare.Result(name: "knob outer frame")
        let region = CGRect(x: center.x - 28, y: center.y - 28, width: 56, height: 56)
        geometry.arcBox = whiteBox(arc, in: region); geometry.oursBox = whiteBox(ours, in: region)
        if let a = geometry.arcBox, let o = geometry.oursBox {
            geometry.positionError = zip([a.minX, a.maxX, a.minY, a.maxY], [o.minX, o.maxX, o.minY, o.maxY]).map { abs($0 - $1) }.max()
        }
        geometry.note = "edge error ≤ 1 pt"; rows.append(geometry)
        // Dot cores: upper luminance decile in a blank pad region, avoiding the knob and controls.
        func dotCore(_ image: Bitmap) -> [Double] {
            var samples: [[Double]] = []
            for y in 180..<280 { for x in 40..<120 { samples.append(image.pixel(x, y)) } }
            samples.sort { $0.reduce(0, +) > $1.reduce(0, +) }
            let top = samples.prefix(200)
            return (0..<3).map { c in top.reduce(0) { $0 + $1[c] } / Double(top.count) }
        }
        var dots = Compare.Result(name: "dot grid core")
        dots.arcColor = dotCore(arc); dots.oursColor = dotCore(ours)
        dots.deltaE = ColorMath.deltaE2000(dots.arcColor!, dots.oursColor!); dots.note = "ΔE00 ≤ 3"; rows.append(dots)
        let table = Compare.markdown(rows, title: "Theme editor shell — F0137")
        try table.write(to: directory.appendingPathComponent("table.md"), atomically: true, encoding: .utf8)
        arc.write(to: directory.appendingPathComponent("capture-panel.png")); ours.write(to: directory.appendingPathComponent("ours-panel.png"))
        print(table)
        let failed = rows.filter { row in
            if let error = row.positionError, error > 1 { return true }
            if row.name == "knob outer frame" && row.positionError == nil { return true }
            if let delta = row.deltaE { return delta > (row.name == "knob disc" || row.name == "knob ring" || row.name.hasSuffix("glyph") ? 2 : 3) }
            if row.name == "material continuous corners" { return row.positionError == nil }
            return row.arcBox == nil || row.oursBox == nil
        }
        if !failed.isEmpty { throw CLIError(description: "editor comparison failed: \(failed.map(\.name).joined(separator: ", "))") }
    }
}
