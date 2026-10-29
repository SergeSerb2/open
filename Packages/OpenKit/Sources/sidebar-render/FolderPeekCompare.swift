import AppKit
import OpenDesign

/// Dedicated, unmasked S2 08/0090 glyph comparison. Never reads or emits private text.
@MainActor
enum FolderPeekCompare {
    static func run(_ args: [String]) throws {
        guard let arcPath = RenderCLI.value(args, "--arc"), let oursPath = RenderCLI.value(args, "--ours"),
              let output = RenderCLI.value(args, "--out") else { throw CLIError(description: RenderCLI.usage) }
        let arc = try Bitmap(path: arcPath, viaDisplayP3: true), ours = try Bitmap(path: oursPath, viaDisplayP3: true)
        guard arc.width == ours.width, arc.height == ours.height else { throw CLIError(description: "FP6 size mismatch") }
        guard (Double(RenderCLI.value(args, "--width") ?? "228") ?? 228) == 228 else { throw CLIError(description: "FP6 capture requires sidebar width 228") }
        let row = Int(RenderCLI.value(args, "--folder-row-top") ?? "239") ?? 239
        let scale = Double(RenderCLI.value(args, "--scale") ?? "1") ?? 1
        guard scale == 1, arc.width >= 214, row >= 0, row < arc.height - 82 else { throw CLIError(description: "FP6 requires valid 1x row coordinates") }
        func hex(_ c: [Double]) -> String { String(format: "#%02X%02X%02X", Int(c[0]), Int(c[1]), Int(c[2])) }
        var lines = ["FP6 pipeline: embedded ICC -> Display P3 bitmap -> sRGB bitmap -> Lab D65 / CIEDE2000. Hex values below are sRGB.",
                     "| Sample | Position | Capture | Render | ΔE00 | Result |", "|---|---|---|---|---:|---|"]
        var passed = true
        var renderedDots: [[Double]] = []
        for (name, x, y) in [("dot 1",22,row+21),("dot 2",26,row+21),("dot 3",30,row+21),("body",26,row+25)] {
            let a = arc.pixel(x,y), o = ours.pixel(x,y), de = ColorMath.deltaE2000(a,o)
            if name.hasPrefix("dot") { renderedDots.append(o) }
            let valid = de <= 2 && (name == "body" ? o[2] > o[0] + 80 : o[0] > 100 && o[1] > 100)
            passed = passed && valid
            lines.append(String(format: "| %@ | (%d,%d) | %@ | %@ | %.3f | %@ |", name,x,y,hex(a),hex(o),de,valid ? "PASS" : "FAIL"))
        }
        let uniform = renderedDots.dropFirst().allSatisfy { $0 == renderedDots.first! }
        passed = passed && uniform
        lines.append("One rendered dot color: \(uniform ? "PASS" : "FAIL")")
        func dots(_ bitmap: Bitmap) -> [CGRect]? {
            var boxes: [CGRect] = []
            let body = bitmap.pixel(26,row+25)
            for center in [22,26,30] {
                var points: [CGPoint] = []
                for y in (row+19)...(row+23) {
                    for x in (center-1)...(center+1) {
                        let c = bitmap.pixel(x,y)
                        if c[0] > body[0] + 65 && c[1] > body[1] + 65 { points.append(CGPoint(x:x,y:y)) }
                    }
                }
                guard !points.isEmpty else { return nil }
                boxes.append(CGRect(x: points.map(\.x).min()!, y: points.map(\.y).min()!,
                    width: points.map(\.x).max()! - points.map(\.x).min()! + 1,
                    height: points.map(\.y).max()! - points.map(\.y).min()! + 1))
            }
            return boxes
        }
        if let a = dots(arc), let o = dots(ours) {
            for i in 0..<3 {
                let error = max(abs(a[i].minX-o[i].minX), abs(a[i].minY-o[i].minY), abs(a[i].maxX-o[i].maxX), abs(a[i].maxY-o[i].maxY))
                let valid = error <= 1 && abs(o[i].width - 3) <= 1
                lines.append("dot \(i+1) capture box=\(a[i]) render box=\(o[i]) position error=\(error) pt \(valid ? "PASS" : "FAIL")")
                passed = passed && valid
            }
            let pitch = [o[1].midX-o[0].midX,o[2].midX-o[1].midX]
            passed = passed && pitch.allSatisfy { abs($0 - SpaceListMetrics.folderPeekDotPitch) <= 0.5 }
            lines.append("dot pitches=\(pitch) pt (4 ±0.5)")
        } else { passed = false; lines.append("FAIL missing glyph/dot samples") }
        // Tight accessory-only ink region: no titles or personal favicons enter the measurement.
        let dash = Compare.Element(name: "folder hover dash", region: CGRect(x:190,y:row+13,width:24,height:14), kind: .ink)
        let dashResult = Compare.measure(dash, arc: arc, ours: ours, scale: 1)
        lines.append(Compare.markdown([dashResult], title: "FP6 hover accessory"))
        passed = passed && dashResult.positionError.map { $0 <= 1 } == true && dashResult.deltaE.map { $0 <= 2 } == true
        lines.append(passed ? "FP6 PASS" : "FP6 FAIL")
        let text = lines.joined(separator: "\n") + "\n"
        let dir = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("table.md"), atomically: true, encoding: .utf8)
        print(text)
        guard passed else { throw CLIError(description: "FP6 capture comparison exceeded threshold") }
    }
}
