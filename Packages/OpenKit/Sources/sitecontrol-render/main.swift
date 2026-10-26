import AppKit
import OpenDesign
import CryptoKit

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    do { try CLI.run(Array(CommandLine.arguments.dropFirst())) }
    catch { FileHandle.standardError.write(Data("sitecontrol-render: \(error)\n".utf8)); exit(1) }
}

struct CLIError: Error, CustomStringConvertible { let description: String }
@MainActor
enum CLI {
    static let motionNames = ["open", "close", "grow", "shrink"]
    static let motionTimes = [0.0, 0.04, 0.08, 0.26]
    static let sccNames = ["scc-basic", "scc-insecure", "scc-adblock-excluded", "scc-adblock-unavailable", "scc-no-boosts", "scc-boosts-off", "scc-incognito", "scc-internal-page", "scc-many", "scc-pane-anchor", "scc-dark", "scc-reload", "scc-hover", "scc-keyboard-focus", "scc-menu", "scc-picker", "scc-tooltip-on", "scc-tooltip-off", "scc-tooltip-unavailable", "scc-tooltip-private"]
    static let editorNames = ["editor-interstitial", "editor-simple", "editor-advanced-color", "editor-neutral-page", "editor-not-active", "editor-global-off", "editor-legacy", "editor-menu", "editor-scope-host", "editor-scope-ip", "editor-rename", "editor-reset", "editor-delete", "editor-double-banner", "editor-hover-side", "editor-pressed-side", "editor-focus-side", "editor-hover-chip", "editor-pressed-chip", "editor-focus-chip", "editor-hover-tile", "editor-pressed-tile", "editor-focus-tile"]
    static let names = sccNames + editorNames
    static func value(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }; return args[i + 1]
    }
    static func run(_ args: [String]) throws {
        guard let command = args.first else { throw CLIError(description: "usage: sitecontrol-render render|ax|flows|check|bench|screens|motion [--state scc-basic] [--out FILE.png] [--scale 1|2] [--appearance light|dark]") }
        let state = value(args, "--state") ?? "scc-basic"
        guard names.contains(state) else { throw CLIError(description: "unknown state \(state)") }
        let scale = CGFloat(Double(value(args, "--scale") ?? "1") ?? 0)
        guard scale == 1 || scale == 2 else { throw CLIError(description: "scale must be 1 or 2") }
        let appearanceName = value(args, "--appearance") ?? "light"
        guard let appearance = ContentAppearance(rawValue: appearanceName) else { throw CLIError(description: "appearance must be light or dark") }
        switch command {
        case "render":
            guard let out = value(args, "--out") else { throw CLIError(description: "render requires --out") }
            let image: CGImage
            if state.hasPrefix("editor-") { let editor = EditorStage(state: state,scale: scale,appearance: appearance); image = withExtendedLifetime(editor) { editor.render() } }
            else { let stage = Stage(state: state,scale: scale,appearance: appearance); image = withExtendedLifetime(stage) { stage.render(scale: scale) } }
            OffscreenRenderer.writePNG(image, to: URL(fileURLWithPath: out))
            print("wrote \(out) (\(image.width)×\(image.height))")
        case "ax":
            if state.hasPrefix("editor-") { let stage = EditorStage(state: state,scale: scale,appearance: appearance); print(Flows.accessibilityDump(stage.view),terminator: "") }
            else { let stage = Stage(state: state, scale: scale, appearance: appearance); _ = stage.render(scale: scale); print(Flows.accessibilityDump(stage.controller.view.panel), terminator: "") }
        case "flows": report(Flows.run() + EditorFlows.run())
        case "check":
            var checks = Flows.run() + EditorFlows.run()
            for state in sccNames { for appearance in [ContentAppearance.light, .dark] { for scale: CGFloat in [1, 2] {
                autoreleasepool {
                let stage = Stage(state: state, scale: scale, appearance: appearance)
                let image = stage.render(scale: scale)
                if state.hasPrefix("scc-tooltip") || state == "scc-menu" { checks.append(Flows.Check(name: state+" captures the native overlay",pass: stage.hasOverlay)) }
                let panel = stage.controller.view.panelFrame
                let a = pixel(image, x: Int((panel.minX + 160) * scale), y: Int((panel.minY + 8) * scale))
                let b = pixel(image, x: Int(800 * scale), y: Int(600 * scale))
                let button = stage.controller.view.panel.control(id: "action.share")!
                let glyph = button.convert(button.bounds.insetBy(dx: 10, dy: 6), to: stage.root)
                var ink = 0
                for y in Int(glyph.minY * scale)..<Int(glyph.maxY * scale) { for x in Int(glyph.minX * scale)..<Int(glyph.maxX * scale) {
                    let color = pixel(image, x: x, y: y)
                    if zip(color.prefix(3), a.prefix(3)).contains(where: { abs(Int($0) - Int($1)) > 40 }) { ink += 1 }
                } }
                let prefix = "render \(state) \(appearance.rawValue) \(Int(scale))x"
                let footer = pixel(image, x: Int(panel.midX*scale), y: Int((panel.maxY-12)*scale))
                let actionFill = pixel(image, x: Int(panel.midX*scale), y: Int((panel.minY+85)*scale))
                checks.append(Flows.Check(name: prefix + " header/action/footer fill", pass: a == footer && a == actionFill))
                var separators = [panel.minY + SiteControlMetrics.headerHeight + SiteControlMetrics.actionRowHeight,
                                  panel.maxY - SiteControlMetrics.footerHeight]
                if let header = stage.controller.view.panel.control(id: "section.boosts") {
                    separators.append(header.convert(header.bounds, to: stage.root).minY)
                }
                let snapped = separators.allSatisfy { y in
                    let line = pixel(image, x: Int(panel.midX*scale), y: Int(y*scale))
                    let next = pixel(image, x: Int(panel.midX*scale), y: Int(y*scale)+1)
                    return line != a && next == a
                }
                checks.append(Flows.Check(name: prefix + " every separator on device pixel", pass: snapped))
                let above = pixel(image, x: Int(panel.midX*scale), y: Int((panel.minY-10)*scale))
                let below = pixel(image, x: Int(panel.midX*scale), y: Int((panel.maxY+10)*scale))
                checks.append(Flows.Check(name: prefix + " shadow offset down", pass: luminance(below) < luminance(above)))
                let origin = state == "scc-pane-anchor" ? CGPoint(x: 599, y: 51) : CGPoint(x: 241, y: 40)
                checks.append(Flows.Check(name: prefix + " anchor geometry", pass: panel.origin == origin))
                checks.append(Flows.Check(name: "complete opaque capture \(state) \(appearance.rawValue) \(Int(scale))x", pass: fullyOpaque(image)))
                checks.append(Flows.Check(name: "render \(state) \(appearance.rawValue) \(Int(scale))x (fill and glyph ink)", pass: image.width == Int(1000 * scale) && image.height == Int(760 * scale) && a != b && a.count == 4 && ink > 4))
                }
            } } }
            checks += EditorFlows.renders()
            checks.append(contentsOf: try receipts())
            checks += Bench.run() + EditorBench.run()
            report(checks)
        case "bench": report(Bench.run() + EditorBench.run())
        case "motion":
            guard let out = value(args, "--out") else { throw CLIError(description: "motion requires --out") }
            let directory = URL(fileURLWithPath: out)
            for transition in motionNames { for time in motionTimes {
                autoreleasepool {
                    let stage = Stage()
                    switch transition {
                    case "close": stage.controller.dismiss(reason: .escape, animated: true)
                    case "grow": stage.tap("contentBlocking")
                    case "shrink": stage.source.value?.boosts = []; stage.source.changed()
                    default:
                        stage.controller.dismiss(reason: .action, animated: false)
                        stage.controller.present(anchor: .urlField, tabID: stage.source.tabID, animated: true)
                    }
                    let end = Date().addingTimeInterval(time)
                    while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.001))) }
                    OffscreenRenderer.settle(stage.root)
                    let image = OffscreenRenderer().snapshot(stage.root, scale: 1, presentation: true)
                    OffscreenRenderer.writePNG(image, to: directory.appendingPathComponent(String(format: "%@-%03.0fms.png", transition, time * 1000)))
                }
            } }
            print("wrote open/close/grow/shrink presentation frames to \(out)")
        case "screens":
            guard let out = value(args, "--out") else { throw CLIError(description: "screens requires --out") }
            let directory = URL(fileURLWithPath: out)
            for state in (value(args,"--group") == "editor" ? editorNames : names) { for appearance in [ContentAppearance.light, .dark] { for scale: CGFloat in [1, 2] {
                autoreleasepool {
                let image: CGImage
                if state.hasPrefix("editor-") { let editor = EditorStage(state: state,scale: scale,appearance: appearance); image = withExtendedLifetime(editor) { editor.render() } }
                else { let stage = Stage(state: state,scale: scale,appearance: appearance); image = withExtendedLifetime(stage) { stage.render(scale: scale) } }
                OffscreenRenderer.writePNG(image, to: directory.appendingPathComponent("\(state)-\(appearance.rawValue)@\(Int(scale))x.png"))
                }
            } } }
            print("wrote \((value(args,"--group") == "editor" ? editorNames.count : names.count) * 4) renders to \(out)")
        default: throw CLIError(description: "unknown command \(command)")
        }
    }
    static func luminance(_ pixel: [UInt8]) -> Int { pixel.prefix(3).map(Int.init).reduce(0, +) }
    static func stablePixels(_ first: Data, _ next: Data) -> Bool {
        guard first.count == next.count else { return false }
        // Native symbol redraws can round antialiased edge channels by 2/255.
        // Permit that quantization; opacity remains exact in fullyOpaque.
        return first.withUnsafeBytes { (a: UnsafeRawBufferPointer) in
            next.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                for i in 0..<a.count { if abs(Int(a[i]) - Int(b[i])) > 2 { return false } }
                return true
            }
        }
    }
    static func fullyOpaque(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        for y in 0..<image.height { for x in 0..<image.width {
            if bytes[y * image.bytesPerRow + x * 4 + 3] != 255 { return false }
        } }
        return true
    }
    static func hasInk(_ image: CGImage, rect: CGRect, scale: CGFloat, fill: [UInt8]) -> Bool {
        var ink = 0
        for y in Int(rect.minY*scale)..<Int(rect.maxY*scale) {
            for x in Int(rect.minX*scale)..<Int(rect.maxX*scale) {
                if abs(luminance(pixel(image, x: x, y: y)) - luminance(fill)) > 45 { ink += 1 }
            }
        }
        return ink > Int(8 * scale * scale)
    }
    static func receipts() throws -> [Flows.Check] {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("AGENTS.md").path) && root.path != "/" { root.deleteLastPathComponent() }
        let baseNames = Set(["scc-basic-light@1x.png", "scc-basic-light@2x.png", "scc-basic-dark@1x.png", "scc-basic-dark@2x.png"])
        let stepOne = try receiptChecks(root.appendingPathComponent("docs/sitecontrol/step-1"), required: baseNames)
        let allNames = Set(sccNames.flatMap { state in ["light", "dark"].flatMap { appearance in [1, 2].map { "\(state)-\(appearance)@\($0)x.png" } } })
        let stepTwo = try receiptChecks(root.appendingPathComponent("docs/sitecontrol/step-2"), required: allNames)
        let motionFiles = Set(motionNames.flatMap { name in motionTimes.map { String(format: "%@-%03.0fms.png", name, $0*1000) } })
        let editorFiles = Set(editorNames.flatMap { state in ["light","dark"].flatMap { appearance in [1,2].map { "\(state)-\(appearance)@\($0)x.png" } } })
        let stepFour = try receiptChecks(root.appendingPathComponent("docs/sitecontrol/step-4"),required: editorFiles)
        return stepFour + stepOne + stepTwo + (try receiptChecks(root.appendingPathComponent("docs/sitecontrol/step-2/motion"), required: motionFiles))
    }
    static func receiptChecks(_ directory: URL, required: Set<String>) throws -> [Flows.Check] {
        let lines = try String(contentsOf: directory.appendingPathComponent("SHA256SUMS"), encoding: .utf8).split(separator: "\n")
        var found = Set<String>(), checks: [Flows.Check] = []
        for line in lines {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2, required.contains(String(parts[1])) else { throw CLIError(description: "invalid render SHA256SUMS entry") }
            let name = String(parts[1]); found.insert(name)
            let hash = SHA256.hash(data: try Data(contentsOf: directory.appendingPathComponent(name))).map { String(format: "%02x", $0) }.joined()
            checks.append(Flows.Check(name: directory.lastPathComponent + " committed SHA256 " + name, pass: hash == parts[0]))
        }
        checks.append(Flows.Check(name: "complete " + directory.lastPathComponent + " render receipts", pass: found == required && lines.count == required.count))
        return checks
    }
    static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        guard let data = image.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return [] }
        let i = y * image.bytesPerRow + x * 4; return Array(UnsafeBufferPointer(start: p + i, count: 4))
    }
    static func report(_ checks: [Flows.Check]) {
        print("| Result | Check |\n|---|---|")
        for c in checks { print("| \(c.pass ? "PASS" : "FAIL") | \(c.name) |") }
        let passed = checks.filter(\.pass).count
        print("\n\(passed)/\(checks.count) passed")
        if passed != checks.count { exit(1) }
    }
}
