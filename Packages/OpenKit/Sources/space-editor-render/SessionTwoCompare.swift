import AppKit
import OpenDesign

/// Session-2 probes. Private pixels enter only here and never leave `.re`.
@MainActor
enum SessionTwoCompare {
    static func run(_ args: [String]) throws {
        guard let path = RenderCLI.value(args, "--arc"), let oursPath = RenderCLI.value(args, "--ours"),
              let out = RenderCLI.value(args, "--out"), out.contains("/.re/") else {
            throw CLIError(description: "session2-editor comparison requires private --out under .re")
        }
        let input = try Bitmap(path: path), ours = try Bitmap(path: oursPath)
        guard (input.width == 382 && input.height == 534) || (input.width >= 610 && input.height >= 543) else {
            throw CLIError(description: "capture does not contain the session-2 panel")
        }
        let arc = input.width == 382 && input.height == 534 ? input
            : EditorCompare.crop(input, rect: CGRect(x: 228, y: 9, width: 382, height: 534))
        guard ours.width == 382 && ours.height == 534 else { throw CLIError(description: "session 2 requires a 1x panel render") }
        let state = RenderCLI.value(args, "--state") ?? "empty"
        if state == "slider" {
            let value = Double(RenderCLI.value(args, "--value") ?? "0.8") ?? 0.8
            try slider(arc: arc, ours: ours, value: value, out: out); return
        }
        if state == "preview" { try preview(arc: arc, ours: ours, out: out); return }
        if state == "page-two" {
            let rows = (0..<9).map { i in
                let rect = CGRect(x: 71 + Double(i) * 29.5, y: 391, width: 4, height: 4)
                return Compare.measure(.init(name: "page-2 swatch \(i + 1)", region: rect, kind: .fill(sample: rect)), arc: arc, ours: ours, scale: 1)
            }
            try write(rows, title: "Session 2 page-two center colors", out: out)
            if rows.contains(where: { ($0.deltaE ?? .infinity) > 2 }) { throw CLIError(description: "page-two color gate failed") }
            return
        }
        var elements: [Compare.Element] = [
            .init(name: "pad fill", region: CGRect(x: 35, y: 110, width: 60, height: 60),
                  kind: .fill(sample: CGRect(x: 35, y: 110, width: 60, height: 60))),
            .init(name: "Light glyph", region: CGRect(x: 179, y: 49, width: 24, height: 24), kind: .ink),
            .init(name: "Dark glyph", region: CGRect(x: 219, y: 49, width: 24, height: 25), kind: .ink),
        ]
        if state.hasPrefix("empty") {
            elements += [
                .init(name: "empty label", region: CGRect(x: 70, y: 177, width: 240, height: 30), kind: .ink),
                // Grid dots are brighter than disabled glyphs. Sample authored
                // core coordinates rather than mistaking dots for glyph bounds.
                .init(name: "disabled Remove core", region: CGRect(x: 165, y: 329, width: 9, height: 1),
                      kind: .fill(sample: CGRect(x: 165, y: 329, width: 9, height: 1))),
                .init(name: "disabled Add core", region: CGRect(x: 209, y: 328, width: 2, height: 2),
                      kind: .fill(sample: CGRect(x: 209, y: 328, width: 2, height: 2))),
            ]
        } else {
            elements += [
                .init(name: "Remove glyph", region: CGRect(x: 157, y: 317, width: 27, height: 27), kind: .ink),
                .init(name: "Add glyph", region: CGRect(x: 197, y: 317, width: 27, height: 27), kind: .ink),
            ]
        }
        var results = elements.map { Compare.measure($0, arc: arc, ours: ours, scale: 1) }
        for i in results.indices {
            if case .ink = elements[i].kind {
                if elements[i].name != "empty label" {
                    let a = GlyphInk.sample(arc, rect: elements[i].region)
                    let o = GlyphInk.sample(ours, rect: elements[i].region)
                    results[i].arcColor = a.color; results[i].oursColor = o.color
                    results[i].deltaE = ColorMath.deltaE2000(a.color, o.color(over: a.background))
                    results[i].note = String(format: "dot lattice masked; median stroke interior; raw ΔE00 %.2f; contrast Arc %.3f / Open %.3f", ColorMath.deltaE2000(a.color, o.color), a.contrast, o.contrast)
                } else {
                // Compare the opaque ink plateau, not a shape-dependent mixture
                // of solid and antialiased SF/Arc pixels.
                func core(_ image: Bitmap) -> [Double] {
                    let r = elements[i].region
                    let background = EditorCompare.median(image, rect: r)
                    let a = 0.2126 * background[0] + 0.7152 * background[1] + 0.0722 * background[2]
                    let (x0, y0, x1, y1) = image.clamp(r)
                    var peak = 0.0
                    for y in y0..<y1 { for x in x0..<x1 { peak = max(peak, abs(image.lum(x, y) - a)) } }
                    var sum = [0.0, 0, 0], count = 0.0
                    for y in y0..<y1 { for x in x0..<x1 where abs(image.lum(x, y) - a) >= peak * 0.99 {
                        let p = image.pixel(x, y); for channel in 0..<3 { sum[channel] += p[channel] }; count += 1
                    } }
                    return sum.map { $0 / max(1, count) }
                }
                results[i].arcColor = core(arc); results[i].oursColor = core(ours)
                results[i].deltaE = ColorMath.deltaE2000(results[i].arcColor!, results[i].oursColor!)
                results[i].note = "opaque core ≥99% peak contrast from median background; symbol shape exempt"
                }
            }
            if let a = results[i].arcBox, let o = results[i].oursBox {
                // Symbol shape is exempt; tokens still have center/height limits.
                results[i].positionError = max(abs(a.midX - o.midX), abs(a.midY - o.midY), abs(a.height - o.height))
            }
        }
        let table = Compare.markdown(results, title: "Session 2 — \(state)")
        let directory = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try table.write(to: directory.appendingPathComponent("table.md"), atomically: true, encoding: .utf8)
        print(table)
        // These new captures also expose Step 9's unresolved radius/color law.
        // Report actual measurements without pretending that gate is complete.
    }

    static func write(_ rows: [Compare.Result], title: String, out: String) throws {
        let directory = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let table = Compare.markdown(rows, title: title)
        try table.write(to: directory.appendingPathComponent("table.md"), atomically: true, encoding: .utf8)
        print(table)
    }
    static func preview(arc: Bitmap, ours: Bitmap, out: String) throws {
        func stats(_ image: Bitmap) -> ([Double], Double) {
            var samples: [[Double]] = []
            for y in 448..<482 { for x in 294..<328 where hypot(Double(x) + 0.5 - 311, Double(y) + 0.5 - 465) < 17 {
                samples.append(image.pixel(x, y))
            } }
            let mean = (0..<3).map { c in samples.reduce(0) { $0 + $1[c] } / Double(samples.count) }
            let luminance = samples.map { 0.2126 * $0[0] + 0.7152 * $0[1] + 0.0722 * $0[2] }
            let m = luminance.reduce(0, +) / Double(luminance.count)
            return (mean, sqrt(luminance.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(luminance.count)))
        }
        let a = stats(arc), o = stats(ours)
        var row = Compare.Result(name: "dial preview mean")
        row.arcColor = a.0; row.oursColor = o.0; row.deltaE = ColorMath.deltaE2000(a.0, o.0)
        row.note = String(format: "L standard deviation Arc %.2f, Open %.2f; own texture art", a.1, o.1)
        try write([row], title: "Session 2 dial preview", out: out)
        if row.deltaE ?? .infinity > 2 { throw CLIError(description: "preview color gate failed") }
    }
    static func slider(arc: Bitmap, ours: Bitmap, value: Double, out: String) throws {
        let center = 38.8 + 208.4 * value
        func thumb(_ image: Bitmap) -> CGRect? {
            func run(_ range: Range<Int>, anchor: Int, sample: (Int) -> Double) -> (Int, Int)? {
                guard let middle = range.min(by: { abs($0 - anchor) < abs($1 - anchor) }), sample(middle) > 220 else { return nil }
                var lo = middle, hi = middle
                while lo > range.lowerBound && sample(lo - 1) > 220 { lo -= 1 }
                while hi + 1 < range.upperBound && sample(hi + 1) > 220 { hi += 1 }
                return (lo, hi + 1)
            }
            guard let x = run(26..<270, anchor: Int(center.rounded()), sample: { image.lum($0, 465) }),
                  let y = run(425..<507, anchor: 465, sample: { image.lum(Int(center.rounded()), $0) }) else { return nil }
            return CGRect(x: x.0, y: y.0, width: x.1 - x.0, height: y.1 - y.0)
        }
        var frame = Compare.Result(name: "value-scaled thumb")
        frame.arcBox = thumb(arc); frame.oursBox = thumb(ours)
        if let a = frame.arcBox, let o = frame.oursBox {
            frame.positionError = zip([a.minX, a.maxX, a.minY, a.maxY], [o.minX, o.maxX, o.minY, o.maxY]).map { abs($0 - $1) }.max()
        }
        frame.note = "white core run through center; calibrated input and art"
        func wave(_ image: Bitmap, thumb: CGRect?) -> (amplitude: Double, center: Double)? {
            var matrix = [[Double]](repeating: [0, 0, 0], count: 3), vector = [0.0, 0, 0], count = 0
            // At full value the thumb covers the right-hand reference strip.
            // Sample the uncovered end of the track for the background profile.
            let reference = value > 0.9 ? 33 : 250
            for x in 44..<242 where !(thumb?.insetBy(dx: -6, dy: -2).contains(CGPoint(x: x, y: 465)) ?? false) {
                var weights: [(Double, Double)] = []
                for y in 446..<484 {
                    let background = (image.lum(reference, y) + image.lum(reference + 1, y) + image.lum(reference + 2, y)) / 3
                    let weight = max(0, image.lum(x, y) - background)
                    weights.append((Double(y) + 0.5, weight))
                }
                let peak = weights.map(\.1).max() ?? 0
                guard peak > 8 else { continue }
                let ink = weights.filter { $0.1 > peak * 0.2 }, total = ink.reduce(0) { $0 + $1.1 }
                let cy = ink.reduce(0) { $0 + $1.0 * $1.1 } / total
                let phase = (Double(x) + 0.5 - 38.8) * 2 * Double.pi / 37.9
                let row = [1, sin(phase), cos(phase)]
                for i in 0..<3 { for j in 0..<3 { matrix[i][j] += row[i] * row[j] }; vector[i] += row[i] * cy }
                count += 1
            }
            guard count > 10, let fit = ColorMath.solve3(matrix, vector) else { return nil }
            return (hypot(fit[1], fit[2]), fit[0])
        }
        var amplitude = Compare.Result(name: "wave centroid amplitude")
        if let a = wave(arc, thumb: frame.arcBox), let o = wave(ours, thumb: frame.oursBox) {
            amplitude.positionError = max(abs(a.amplitude - o.amplitude), abs(a.center - o.center))
            amplitude.note = String(format: "Arc A %.2f y %.2f; Open A %.2f y %.2f", a.amplitude, a.center, o.amplitude, o.center)
        }
        try write([frame, amplitude], title: "Session 2 intensity \(value)", out: out)
        guard let frameError = frame.positionError, let waveError = amplitude.positionError,
              frameError <= 1, waveError <= 1 else { throw CLIError(description: "slider geometry gate failed") }
    }
}
