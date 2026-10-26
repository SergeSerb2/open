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
    // Complete glyph host frames, including ink outside the core probe ROIs.
    static let glyphFrames = [CGRect(x: 135, y: 45, width: 32, height: 32),
                              CGRect(x: 175, y: 45, width: 32, height: 32), CGRect(x: 215, y: 45, width: 32, height: 32),
                              CGRect(x: 155, y: 313, width: 32, height: 32), CGRect(x: 195, y: 313, width: 32, height: 32),
                              CGRect(x: 22, y: 377, width: 32, height: 32), CGRect(x: 328, y: 377, width: 32, height: 32)]
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(); guard !sorted.isEmpty else { return .nan }
        return sorted.count.isMultiple(of: 2) ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]
    }
    static func luminance(_ c: [Double]) -> Double { 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2] }
    static func core(_ image: Bitmap, _ rect: CGRect) -> (background: Double, pixels: [Double], color: [Double]) {
        let background = luminance(EditorCompare.median(image, rect: rect))
        let (x0, y0, x1, y1) = image.clamp(rect)
        var values: [[Double]] = []
        for y in y0..<y1 { for x in x0..<x1 { values.append(image.pixel(x, y)) } }
        let peak = values.map { abs(luminance($0) - background) }.max() ?? 0
        let pixels = values.filter { abs(luminance($0) - background) >= peak * 0.99 }
        let color = (0..<3).map { channel in pixels.reduce(0) { $0 + $1[channel] } / Double(max(1, pixels.count)) }
        return (background, pixels.map(luminance), color)
    }
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
    static func run(_ args: [String]) throws {
        guard let rootPath = RenderCLI.value(args, "--capture-root"), let outPath = RenderCLI.value(args, "--out"), outPath.contains("/.re/") else {
            throw CLIError(description: "fit-light-glyphs --capture-root SESSIONS --out .re/DIR [--inspect] [--candidate ALPHA]")
        }
        let root = URL(fileURLWithPath: rootPath), directory = URL(fileURLWithPath: outPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let groups = [("20261026-103516-20-light-mode", Array(27...34), "75733"),
                      ("20261026-104045-17-theme-editor", [158, 159], "76541")]
        let alpha = ThemeEditorColors.glyph.light.alpha
        let candidate = RenderCLI.value(args, "--candidate").flatMap(Double.init)
        if let candidate, !candidate.isFinite || !(0...1).contains(candidate) { throw CLIError(description: "invalid candidate alpha") }
        var candidateErrors: [String: [Double]] = [:], newFailures = 0, outsideChanges = 0
        var samples: [String: [Double]] = [:], errors: [String: [Double]] = [:]
        var all: [Double] = [], instanceFits: [Double] = [], instances = 0, frames: [String] = []
        var lines = ["| Frame | Glyph | Core pixels | Fitted alpha | Current core ΔE00 | Candidate core ΔE00 |", "|---|---|---|---|---|---|"]
        for (sessionName, numbers, windowID) in groups {
            let session = root.appendingPathComponent(sessionName)
            let folders = try FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for number in numbers {
                let prefix = String(format: "%04d-", number)
                guard let folder = folders.first(where: { $0.lastPathComponent.hasPrefix(prefix) }) else { throw CLIError(description: "missing light frame \(number)") }
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
                    // Recorder's .same marker reuses the immediately preceding
                    // available PNG for this same window inside this session.
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
                var style = EditorScene.capturedStyle
                // These final item-17 frames explicitly force Light; item 20's
                // empty style inherits the already-light simulated system.
                if sessionName.contains("17-theme-editor") { style.appearance = .light }
                let scene = try EditorScene(style: removeEnabled ? style : nil, light: true)
                scene.view.remove.enabled = removeEnabled; scene.view.add.enabled = addEnabled
                scene.view.presets.previous.enabled = previousEnabled; scene.view.presets.next.enabled = nextEnabled
                // Offscreen native buttons use the production authored alpha.
                // No desktop input or on-screen window is used.
                let image = scene.snapshot()
                let ownURL = directory.appendingPathComponent("own-\(sessionName)-\(number).png")
                OffscreenRenderer.writePNG(image, to: ownURL)
                let ours = try Bitmap(path: ownURL.path)
                var proposed: Bitmap?
                if let candidate {
                    for button in scene.view.modes.buttons + [scene.view.remove, scene.view.add, scene.view.presets.previous, scene.view.presets.next] {
                        button.glyphView.contentTintColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: candidate)
                    }
                    OffscreenRenderer.settle(scene.view)
                    let proposedURL = directory.appendingPathComponent("candidate-\(sessionName)-\(number).png")
                    OffscreenRenderer.writePNG(OffscreenRenderer().snapshot(scene.view, scale: 1), to: proposedURL)
                    proposed = try Bitmap(path: proposedURL.path)
                    for y in 0..<ours.height { for x in 0..<ours.width where !glyphFrames.contains(where: { $0.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) }) {
                        if ours.pixel(x, y) != proposed!.pixel(x, y) { outsideChanges += 1 }
                    } }
                }
                frames.append("\(sessionName):\(number)")
                for glyph in glyphs {
                    let a = core(arc, glyph.rect), o = core(ours, glyph.rect)
                    let coverage = median(o.pixels.map { (o.background - $0) / max(1, o.background) })
                    guard coverage > 0.02, !a.pixels.isEmpty else { throw CLIError(description: "no light glyph core for \(glyph.name)") }
                    let estimates = a.pixels.map { alpha * ((a.background - $0) / max(1, a.background)) / coverage }
                    samples[glyph.name, default: []] += estimates; all += estimates; instances += 1
                    instanceFits.append(median(estimates))
                    let error = ColorMath.deltaE2000(a.color, o.color)
                    errors[glyph.name, default: []].append(error)
                    var candidateText = "—"
                    if let proposed {
                        let candidateError = ColorMath.deltaE2000(a.color, core(proposed, glyph.rect).color)
                        candidateErrors[glyph.name, default: []].append(candidateError)
                        if error <= 2 && candidateError > 2 { newFailures += 1 }
                        candidateText = String(format: "%.2f", candidateError)
                    }
                    lines.append(String(format: "| %@:%04d | %@ | %d | %.5f | %.2f | %@ |", sessionName, number, glyph.name, estimates.count, median(estimates), error, candidateText))
                }
                scene.controller.close()
            }
        }
        if args.contains("--inspect") { return }
        let fit = median(all)
        if let candidate, abs(candidate - fit) > 0.000001 { throw CLIError(description: "candidate must equal the whole-corpus median") }
        let spread = samples.mapValues { median($0) }
        let agreement = instanceFits.allSatisfy { abs($0 - fit) <= 0.05 }
        let eligible = instances == 70 && fit >= 0.45 && fit <= 1 && agreement
        var report = "# Session-2 light glyph alpha fit\n\nCore method frozen before fit: ≥99% peak contrast from the region's median background, matching the reported N7 residual. Every light-frame glyph is included; no worst-glyph selection. Normalize both backgrounds and the current render's per-role coverage (including disabled alpha).\n\n"
        report += String(format: "Authored alpha %.5f; median fitted alpha %.5f; %d glyph instances, %d core pixels; agreement %@; fit %@.\n\n", alpha, fit, instances, all.count, agreement ? "PASS" : "FAIL", eligible ? "STATISTICALLY ELIGIBLE; other light gates still required" : "REFUSED")
        report += "| Glyph | Core pixels | Median fitted alpha | Offset from global median | Current core ΔE00 range | Candidate core ΔE00 range |\n|---|---|---|---|---|---|\n"
        for glyph in glyphs {
            let values = samples[glyph.name] ?? []
            let proposed = candidateErrors[glyph.name].map { String(format: "%.2f–%.2f", $0.min()!, $0.max()!) } ?? "—"
            report += String(format: "| %@ | %d | %.5f | %+.5f | %.2f–%.2f | %@ |\n", glyph.name, values.count, median(values), median(values) - fit, errors[glyph.name]!.min()!, errors[glyph.name]!.max()!, proposed)
        }
        report += String(format: "\nPer-instance fitted alpha range %.5f–%.5f; largest absolute offset %.5f.\n", instanceFits.min()!, instanceFits.max()!, instanceFits.map { abs($0 - fit) }.max()!)
        if let candidate {
            let allPass = candidateErrors.values.flatMap { $0 }.allSatisfy { $0 <= 2 }
            report += String(format: "\nCandidate %.5f: %d previously passing glyph comparisons crossed ΔE00 2; %d changed pixels outside complete glyph host frames (other text and controls). Final fit %@; authored alpha remains unchanged.\n", candidate, newFailures, outsideChanges, eligible && newFailures == 0 && outsideChanges == 0 && allPass ? "PASSES ALL GATES" : "REFUSED")
        }
        report += "\n" + lines.joined(separator: "\n") + "\n\nFrames: " + frames.joined(separator: ", ") + "\n"
        try report.write(to: directory.appendingPathComponent("fit.md"), atomically: true, encoding: .utf8)
        var result: [String: Any] = ["fit": fit, "eligible": eligible, "glyphInstances": instances, "corePixels": all.count,
                                     "perGlyph": spread, "perInstanceMin": instanceFits.min()!, "perInstanceMax": instanceFits.max()!, "frames": frames]
        if let candidate {
            result["candidate"] = candidate; result["newGlyphFailures"] = newFailures; result["outsideChanges"] = outsideChanges
            result["candidateAllPass"] = candidateErrors.values.flatMap { $0 }.allSatisfy { $0 <= 2 }
        }
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]).write(to: directory.appendingPathComponent("fit.json"))
        print(report)
    }
}
