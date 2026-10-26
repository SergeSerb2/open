import AppKit
import OpenDesign

/// Whole-corpus calibration, inside the private compare harness only.
@MainActor
enum LightGlyphFit {
    struct Glyph { let name: String; let rect: CGRect }
    static let glyphs = [
        Glyph(name: "Automatic", rect: CGRect(x: 141, y: 48, width: 22, height: 24)),
        Glyph(name: "Light", rect: CGRect(x: 179, y: 49, width: 24, height: 24)),
        Glyph(name: "Dark", rect: CGRect(x: 219, y: 49, width: 24, height: 25)),
        Glyph(name: "Remove", rect: CGRect(x: 160, y: 319, width: 22, height: 22)),
        Glyph(name: "Add", rect: CGRect(x: 200, y: 319, width: 22, height: 22)),
        Glyph(name: "Previous", rect: CGRect(x: 28, y: 381, width: 20, height: 24)),
        Glyph(name: "Next", rect: CGRect(x: 334, y: 381, width: 20, height: 24)),
    ]
    static func nodes(_ object: Any) -> [[String: Any]] {
        if let list = object as? [Any] { return list.flatMap(nodes) }
        guard let node = object as? [String: Any] else { return [] }
        return [node] + node.values.flatMap(nodes)
    }
    /// Recorder AX labels are absent on mode buttons. Resolve the four action
    /// 32×32 controls inside the captured popover, using its own origin.
    static func buttons(_ ax: Any) throws -> [String: [String: Any]] {
        func rect(_ node: [String: Any]) -> CGRect? {
            guard let values = node["rel"] as? [Double], values.count == 4 else { return nil }
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        guard let popover = nodes(ax).first(where: { node in
            guard node["role"] as? String == "AXPopover", let r = rect(node) else { return false }
            return r.size == CGSize(width: 382, height: 534)
        }), let origin = rect(popover)?.origin else { throw CLIError(description: "no captured editor AX popover") }
        let centers: [CGPoint] = [.init(x: 151, y: 61), .init(x: 191, y: 61), .init(x: 231, y: 61),
                                 .init(x: 171, y: 329), .init(x: 211, y: 329), .init(x: 38, y: 393), .init(x: 344, y: 393)]
        var result: [String: [String: Any]] = [:]
        for (glyph, center) in zip(glyphs.dropFirst(3), centers.dropFirst(3)) {
            let matches = nodes(popover).filter { node in
                guard node["role"] as? String == "AXButton", let r = rect(node), r.size == CGSize(width: 32, height: 32) else { return false }
                return abs(r.midX - origin.x - center.x) <= 1 && abs(r.midY - origin.y - center.y) <= 1
            }
            guard matches.count == 1 else { throw CLIError(description: "ambiguous AX control \(glyph.name) (matches \(matches.count))") }
            result[glyph.name] = matches[0]
        }
        return result
    }
    static func values(_ image: Bitmap, rect: CGRect, sample: GlyphInk.Sample, disabled: Bool) -> [Double] {
        let bg = 0.2126 * sample.background[0] + 0.7152 * sample.background[1] + 0.0722 * sample.background[2]
        let factor = disabled ? Double(ThemeEditorColors.disabledGlyphAlpha) : 1
        let (x0, y0, x1, y1) = image.clamp(rect)
        var result: [Double] = []
        for y in y0..<y1 { for x in x0..<x1 where !GlyphInk.dotPixel(x: x, y: y) {
            let contrast = (sample.darkInk ? bg - image.lum(x, y) : image.lum(x, y) - bg) / max(1, sample.darkInk ? bg : 255 - bg)
            if contrast >= sample.minimumContrast { result.append(contrast / factor) }
        } }
        return result
    }
    static func paintAlpha(_ image: Bitmap, reference: Bitmap, rect: CGRect, sample: GlyphInk.Sample) -> Double {
        let bg = 0.2126 * sample.background[0] + 0.7152 * sample.background[1] + 0.0722 * sample.background[2]
        let (x0, y0, x1, y1) = image.clamp(rect)
        var ratios: [Double] = []
        for y in y0..<y1 { for x in x0..<x1 where !GlyphInk.dotPixel(x: x, y: y) {
            let actual = (bg - image.lum(x, y)) / max(1, bg)
            let coverage = (bg - reference.lum(x, y)) / max(1, bg)
            if actual >= sample.minimumContrast && coverage > 0 { ratios.append(actual / coverage) }
        } }
        return GlyphInk.median(ratios)
    }
    static func run(_ args: [String]) throws {
        guard let rootPath = RenderCLI.value(args, "--capture-root"), let outPath = RenderCLI.value(args, "--out"), outPath.contains("/.re/") else {
            throw CLIError(description: "fit-light-glyphs --capture-root SESSIONS --out .re/DIR [--inspect]")
        }
        if args.contains("--candidate") { throw CLIError(description: "R3 checks the fixed authored tokens; the erroneous peak-fit candidate path is retired") }
        let root = URL(fileURLWithPath: rootPath), directory = URL(fileURLWithPath: outPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let groups = [("20261026-103516-20-light-mode", Array(27...34), "75733"),
                      ("20261026-104045-17-theme-editor", [158, 159], "76541")]
        var samples: [String: [Double]] = [:], normalizedErrors: [String: [Double]] = [:], rawErrors: [String: [Double]] = [:]
        var all: [Double] = [], instanceFits: [Double] = [], instances = 0, frames: [String] = []
        var lines = ["| Frame | Glyph | Core pixels | Arc alpha / disabled factor | Open contrast | Open paint alpha | Core ΔE00 normalized | Core ΔE00 raw |", "|---|---|---|---|---|---|---|---|"]
        for (sessionName, numbers, windowID) in groups {
            let session = root.appendingPathComponent(sessionName)
            let folders = try FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for number in numbers {
                guard let folder = folders.first(where: { $0.lastPathComponent.hasPrefix(String(format: "%04d-", number)) }) else { throw CLIError(description: "missing light frame \(number)") }
                let ax = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("ax.json")))
                let controls = try buttons(ax)
                func enabled(_ name: String) throws -> Bool {
                    guard let node = controls[name] else { throw CLIError(description: "missing AX control \(name)") }
                    guard node["flags"] != nil else { return true }
                    guard let flags = node["flags"] as? [String] else { throw CLIError(description: "unknown AX flag schema") }
                    return !flags.contains("disabled")
                }
                if args.contains("--inspect") {
                    for glyph in glyphs.dropFirst(3) { print("frame \(sessionName):\(number) glyph \(glyph.name) enabled \(try enabled(glyph.name))") }
                    continue
                }
                var file = folder.appendingPathComponent("win-\(windowID).png")
                if !FileManager.default.fileExists(atPath: file.path) {
                    guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("win-\(windowID).same").path),
                          let previous = folders.last(where: { $0.lastPathComponent < folder.lastPathComponent && FileManager.default.fileExists(atPath: $0.appendingPathComponent("win-\(windowID).png").path) }) else {
                        throw CLIError(description: "missing light panel pixels for frame \(number)")
                    }
                    file = previous.appendingPathComponent("win-\(windowID).png")
                }
                let input = try Bitmap(path: file.path)
                let arc = input.width == 382 && input.height == 534 ? input : EditorCompare.crop(input, rect: CGRect(x: 228, y: 9, width: 382, height: 534))
                let removeEnabled = try enabled("Remove"), addEnabled = try enabled("Add")
                let previousEnabled = try enabled("Previous"), nextEnabled = try enabled("Next")
                let hoveredLight = sessionName.contains("17-theme-editor")
                var style = EditorScene.capturedStyle
                if hoveredLight { style.appearance = .light }
                let scene = try EditorScene(style: removeEnabled ? style : nil, light: true)
                scene.view.remove.enabled = removeEnabled; scene.view.add.enabled = addEnabled
                scene.view.presets.previous.enabled = previousEnabled; scene.view.presets.next.enabled = nextEnabled
                // 0158/0159 show selected Light while the pointer still hovers it.
                scene.view.modes.buttons[1].forcedHover = hoveredLight
                let ownURL = directory.appendingPathComponent("own-\(sessionName)-\(number).png")
                OffscreenRenderer.writePNG(scene.snapshot(), to: ownURL)
                let ours = try Bitmap(path: ownURL.path)
                // Some diagonal SF strokes have no fully covered pixel at 1x.
                // A unit-black render of the same native glyph measures coverage
                // without changing the authored opacity or optical weight.
                for button in scene.view.modes.buttons + [scene.view.remove, scene.view.add, scene.view.presets.previous, scene.view.presets.next] {
                    button.glyphView.contentTintColor = .black
                }
                OffscreenRenderer.settle(scene.view)
                let referenceURL = directory.appendingPathComponent("coverage-\(sessionName)-\(number).png")
                OffscreenRenderer.writePNG(OffscreenRenderer().snapshot(scene.view, scale: 1), to: referenceURL)
                let reference = try Bitmap(path: referenceURL.path)
                frames.append("\(sessionName):\(number)")
                for glyph in glyphs {
                    let disabled = controls[glyph.name] != nil ? !(try enabled(glyph.name)) : false
                    let a = GlyphInk.sample(arc, rect: glyph.rect, disabled: disabled)
                    let o = GlyphInk.sample(ours, rect: glyph.rect, disabled: disabled)
                    let estimates = values(arc, rect: glyph.rect, sample: a, disabled: disabled)
                    guard !estimates.isEmpty, o.count > 0 else { throw CLIError(description: "no dot-free stroke interior for \(glyph.name) frame \(number)") }
                    let paint = paintAlpha(ours, reference: reference, rect: glyph.rect, sample: o)
                    let effective = paint * (disabled ? Double(ThemeEditorColors.disabledGlyphAlpha) : 1)
                    let normalized = ColorMath.deltaE2000(a.color, a.background.map { $0 * (1 - effective) })
                    let raw = ColorMath.deltaE2000(a.color, o.color)
                    samples[glyph.name, default: []] += estimates; all += estimates; instances += 1
                    instanceFits.append(GlyphInk.median(estimates))
                    normalizedErrors[glyph.name, default: []].append(normalized); rawErrors[glyph.name, default: []].append(raw)
                    lines.append(String(format: "| %@:%04d | %@ | %d | %.5f | %.5f | %.5f | %.2f | %.2f |", sessionName, number, glyph.name, estimates.count, GlyphInk.median(estimates), o.contrast, paint, normalized, raw))
                }
                scene.controller.close()
            }
        }
        if args.contains("--inspect") { return }
        let fit = GlyphInk.median(all), spread = samples.mapValues { GlyphInk.median($0) }
        let maxError = normalizedErrors.values.flatMap { $0 }.max() ?? .infinity
        let agreement = instanceFits.allSatisfy { abs($0 - fit) <= 0.05 }
        let passed = instances == 70 && fit >= 0.45 && abs(fit - 0.5) <= 0.01 && agreement && maxError <= 2
        var report = "# R3 corrected light glyph calibration\n\nMethod: exclude pad-dot lattice pixels (4.25 pt period, including antialias support); median stroke plateau (≥95% of the upper-half stroke median), excluding antialiased edges. No peak selector. Render item-17 0158/0159 with Light selected AND hovered. Token ΔE00 uses Arc's local background and native SF coverage measured by a unit-black reference render; raw core ΔE00 is also reported. This corrects antialias coverage, not glyph opacity.\n\n"
        report += "Ten frames are repeated samples of **two UI states**, not ten independent states. Item-20 0027–0034 repeat the static empty/light state; item-17 0158–0159 show forced Light with its hovered plate.\n\n"
        report += String(format: "Authored alpha %.5f; disabled factor %.2f; median Arc alpha %.5f; %d glyph instances / %d dot-free core pixels; per-instance %.5f–%.5f; max offset %.5f; max normalized ΔE00 %.2f. Gate %@.\n\n", ThemeEditorColors.glyph.light.alpha, Double(ThemeEditorColors.disabledGlyphAlpha), fit, instances, all.count, instanceFits.min() ?? 0, instanceFits.max() ?? 0, instanceFits.map { abs($0 - fit) }.max() ?? 0, maxError, passed ? "PASS" : "FAIL")
        report += "| Glyph | Core pixels | Median Arc alpha | Offset | Normalized ΔE00 range | Raw ΔE00 range |\n|---|---|---|---|---|---|\n"
        for glyph in glyphs {
            let values = samples[glyph.name] ?? [], normalized = normalizedErrors[glyph.name] ?? [], raw = rawErrors[glyph.name] ?? []
            report += String(format: "| %@ | %d | %.5f | %+.5f | %.2f–%.2f | %.2f–%.2f |\n", glyph.name, values.count, GlyphInk.median(values), GlyphInk.median(values) - fit, normalized.min() ?? 0, normalized.max() ?? 0, raw.min() ?? 0, raw.max() ?? 0)
        }
        report += "\n" + lines.joined(separator: "\n") + "\n\nFrames: " + frames.joined(separator: ", ") + "\n"
        try report.write(to: directory.appendingPathComponent("fit.md"), atomically: true, encoding: .utf8)
        let result: [String: Any] = ["fit": fit, "passed": passed, "glyphInstances": instances, "corePixels": all.count, "perGlyph": spread, "distinctUIStates": 2, "maximumNormalizedDeltaE": maxError, "frames": frames]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]).write(to: directory.appendingPathComponent("fit.json"))
        print(report)
        if !passed { throw CLIError(description: "corrected light glyph calibration failed") }
    }
}
