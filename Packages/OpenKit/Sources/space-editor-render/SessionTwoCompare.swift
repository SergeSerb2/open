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
}
