import AppKit
import OpenDesign

/// Reuses sidebar-render's sRGB conversion, plane-fit ink boxes, and CIEDE2000.
/// Captures and side-by-sides contain personal data and belong only in .re/.
@MainActor
enum FeatureCompare {
    static func run(_ args: [String]) throws {
        guard let arcPath = RenderCLI.value(args, "--arc"), let oursPath = RenderCLI.value(args, "--ours"), let out = RenderCLI.value(args, "--out") else { throw CLIError(description: RenderCLI.usage) }
        let arc = try Bitmap(path: arcPath), ours = try Bitmap(path: oursPath)
        guard arc.width == 2216, arc.height == 1394, arc.width == ours.width, arc.height == ours.height else { throw CLIError(description: "reference comparisons require 2216x1394 at 1x") }
        let state = RenderCLI.value(args, "--state") ?? "split", dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var results: [Compare.Result] = []
        func color(_ name: String, _ sample: CGRect) {
            let a = arc.mean(sample), o = ours.mean(sample)
            results.append(Compare.Result(name: name, arcColor: a, oursColor: o, deltaE: ColorMath.deltaE2000(a, o)))
        }
        func geometry(_ name: String, expected: CGRect, actual: CGRect) {
            let error = [abs(expected.minX - actual.minX), abs(expected.minY - actual.minY), abs(expected.maxX - actual.maxX), abs(expected.maxY - actual.maxY)].max()!
            results.append(Compare.Result(name: name, arcBox: expected, oursBox: actual, positionError: error, note: "AX top-left vs rendered view geometry"))
        }
        if state == "split" {
            guard let path = RenderCLI.value(args, "--frames"), let frames = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [[Double]], frames.count == 2 else { throw CLIError(description: "split compare requires --frames JSON from the render") }
            for i in 0..<2 {
                let x = i == 0 ? 228.0 : 1222.0, expected = CGRect(x: x, y: 10, width: 984, height: 1374)
                let f = frames[i]; guard f.count == 4 else { throw CLIError(description: "invalid frames") }
                // Exactly one AX conversion: renderer wrote H - frame.maxY from bottom-left NSViews.
                let actual = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
                geometry("Pane \(i + 1) outer frame", expected: expected, actual: actual)
                geometry("Pane \(i + 1) 32 pt bar", expected: CGRect(x: x, y: 10, width: 984, height: 32), actual: CGRect(x: actual.minX, y: actual.minY, width: actual.width, height: 32))
                color("Pane \(i + 1) bar fill", CGRect(x: x + 150, y: 18, width: 80, height: 12))
            }
            color("Focused ring core", CGRect(x: 1222, y: 80, width: 2, height: 1100))
            let specs: [(String, CGRect)] = [
                ("Unfocused Close glyph", CGRect(x: 1177, y: 14, width: 30, height: 24)),
                ("Focused Back glyph", CGRect(x: 1227, y: 14, width: 32, height: 24)),
                ("Focused Forward glyph", CGRect(x: 1264, y: 14, width: 32, height: 24)),
                ("Focused Reload glyph", CGRect(x: 1301, y: 14, width: 32, height: 24)),
                ("Focused Copy URL glyph", CGRect(x: 1647, y: 14, width: 24, height: 24)),
                ("Focused Host label", CGRect(x: 1670, y: 16, width: 88, height: 22)),
                ("Site Control glyph", CGRect(x: 2107, y: 17, width: 20, height: 20)),
                ("Split menu glyph", CGRect(x: 2137, y: 14, width: 32, height: 24)),
                ("Focused Close glyph", CGRect(x: 2169, y: 14, width: 32, height: 24))]
            for (name, region) in specs { results.append(Compare.measure(.init(name: name, region: region, kind: .ink), arc: arc, ours: ours, scale: 1)) }
        } else if state == "peek" {
            guard let path = RenderCLI.value(args, "--frames"), let frames = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any],
                  let panel = frames["panel"] as? [Double], panel.count == 4,
                  let controls = frames["buttons"] as? [[Double]], controls.count == 3 else { throw CLIError(description: "peek compare requires --frames JSON from the render") }
            geometry("Peek panel frame", expected: CGRect(x: 427, y: 12, width: 1590, height: 1370), actual: CGRect(x: panel[0], y: panel[1], width: panel[2], height: panel[3]))
            for (i, f) in controls.enumerated() {
                geometry(["Close", "Expand", "Split"][i] + " control hit frame", expected: CGRect(x: 2030, y: 21 + Double(i) * 43, width: i == 2 ? 34 : 35, height: i == 2 ? 32 : 33), actual: CGRect(x: f[0], y: f[1], width: f[2], height: f[3]))
            }
            // Edge profiles identify the opaque page boundary without comparing its content.
            func panelFrame(_ bitmap: Bitmap) -> CGRect {
                let y = 700, start = 350, end = 2090
                let deltas = (start..<end).map { x -> (Int, Double) in
                    let a = bitmap.pixel(x - 1, y), b = bitmap.pixel(x, y)
                    return (x, zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) })
                }
                let left = deltas.filter { $0.0 < 800 }.max { $0.1 < $1.1 }!.0
                let right = deltas.filter { $0.0 > 1800 }.max { $0.1 < $1.1 }!.0
                return CGRect(x: left, y: 12, width: right - left, height: 1370)
            }
            geometry("Peek panel edge profile", expected: panelFrame(arc), actual: panelFrame(ours))
            for i in 0..<3 {
                let rect = CGRect(x: 2028, y: 19 + Double(i) * 43, width: 39, height: 37)
                let result = Compare.measure(.init(name: ["Close", "Expand", "Split"][i] + " circle", region: rect,
                                                  kind: .fill(sample: CGRect(x: 2036, y: 26 + Double(i) * 43, width: 3, height: 3))), arc: arc, ours: ours, scale: 1)
                results.append(result)
                results.append(Compare.measure(.init(name: ["Close", "Expand", "Split"][i] + " glyph", region: CGRect(x: 2039, y: 29 + Double(i) * 43, width: 17, height: 17), kind: .ink), arc: arc, ours: ours, scale: 1))
            }
            color("Scrim sidebar top", CGRect(x: 90, y: 85, width: 110, height: 4))
            color("Scrim sidebar center", CGRect(x: 85, y: 1000, width: 110, height: 30))
            color("Scrim sidebar bottom", CGRect(x: 85, y: 1280, width: 110, height: 25))
        } else { throw CLIError(description: "--state split|peek") }
        let table = Compare.markdown(results, title: "M4 \(state), 1x, ICC to sRGB")
        try table.write(to: dir.appendingPathComponent("table.md"), atomically: true, encoding: .utf8)
        print(table)
        // Mask web content, favicons, traffic lights, corners. Retain only measured chrome.
        var sheet = Bitmap(width: arc.width * 3 + 8, height: arc.height, fill: 255)
        func masked(_ x: Int, _ y: Int) -> Bool {
            if x < 76 && y < 40 { return true }
            if x < 8 || x > 2207 { return true }
            if x < 220 && y >= 90 && y < 200 { return true }
            if x >= 16 && x < 40 && y >= 200 { return true }
            if state == "split" { return (x > 230 && x < 1210 || x > 1224 && x < 2204) && y > 42 && y < 1382 }
            if x > 433 && x < 2011 && y > 18 && y < 1376 { return true }
            // Underlying web content is synthetic too; retain the panel and button surroundings only.
            return x > 230 && y > 50 && !(abs(x - 427) < 12 || abs(x - 2017) < 12 || (x > 2028 && x < 2068 && y < 145))
        }
        for y in 0..<arc.height { for x in 0..<arc.width {
            let mask = masked(x, y), a = arc.pixel(x, y), o = ours.pixel(x, y)
            sheet.set(x, y, mask ? [128,128,128] : a); sheet.set(arc.width + 4 + x, y, mask ? [128,128,128] : o)
            sheet.set(2 * (arc.width + 4) + x, y, mask ? [40,40,40] : zip(a,o).map { min(255, abs($0-$1)*4) })
        } }
        sheet.write(to: dir.appendingPathComponent("side-by-side.png"))
        let failures = results.filter { ($0.positionError ?? 0) > 1 || ($0.deltaE ?? 0) > 2 || ($0.name.contains("glyph") && $0.positionError == nil) }
        print("\(failures.isEmpty ? "PASS" : "FAIL") comparison targets: \(failures.count) elements outside ≤1 pt / ΔE00≤2")
        if !failures.isEmpty { throw CLIError(description: "comparison has \(failures.count) out-of-target elements; see table.md") }
    }
}
