import AppKit
import OpenDesign

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    do { try CLI.run(Array(CommandLine.arguments.dropFirst())) }
    catch { FileHandle.standardError.write(Data("sitecontrol-render: \(error)\n".utf8)); exit(1) }
}

struct CLIError: Error, CustomStringConvertible { let description: String }
@MainActor
enum CLI {
    static let names = ["scc-basic", "scc-insecure", "scc-adblock-excluded", "scc-adblock-unavailable", "scc-no-boosts", "scc-boosts-off", "scc-incognito", "scc-internal-page", "scc-many", "scc-pane-anchor", "scc-dark"]
    static func value(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }; return args[i + 1]
    }
    static func run(_ args: [String]) throws {
        guard let command = args.first else { throw CLIError(description: "usage: sitecontrol-render render|ax|flows|check [--state scc-basic] [--out FILE.png] [--scale 1|2] [--appearance light|dark]") }
        let state = value(args, "--state") ?? "scc-basic"
        guard names.contains(state) else { throw CLIError(description: "unknown state \(state)") }
        let scale = CGFloat(Double(value(args, "--scale") ?? "1") ?? 0)
        guard scale == 1 || scale == 2 else { throw CLIError(description: "scale must be 1 or 2") }
        let appearanceName = value(args, "--appearance") ?? "light"
        guard let appearance = ContentAppearance(rawValue: appearanceName) else { throw CLIError(description: "appearance must be light or dark") }
        switch command {
        case "render":
            guard let out = value(args, "--out") else { throw CLIError(description: "render requires --out") }
            let stage = Stage(state: state, scale: scale, appearance: appearance)
            let image = stage.render(scale: scale)
            OffscreenRenderer.writePNG(image, to: URL(fileURLWithPath: out))
            print("wrote \(out) (\(image.width)×\(image.height))")
        case "ax":
            let stage = Stage(state: state, scale: scale, appearance: appearance)
            _ = stage.render(scale: scale)
            print(Flows.accessibilityDump(stage.controller.view.panel))
        case "flows": report(Flows.run())
        case "check":
            var checks = Flows.run()
            for state in names { for appearance in [ContentAppearance.light, .dark] { for scale: CGFloat in [1, 2] {
                let stage = Stage(state: state, scale: scale, appearance: appearance)
                let image = stage.render(scale: scale)
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
                checks.append(Flows.Check(name: "render \(state) \(appearance.rawValue) \(Int(scale))x (fill and glyph ink)", pass: image.width == Int(1000 * scale) && image.height == Int(760 * scale) && a != b && a.count == 4 && ink > 4))
            } } }
            checks += Bench.run()
            report(checks)
        case "bench": report(Bench.run())
        case "motion":
            guard let out = value(args, "--out") else { throw CLIError(description: "motion requires --out") }
            let directory = URL(fileURLWithPath: out)
            for closing in [false, true] { for time in [0.0, 0.04, 0.08, 0.18] {
                let stage = Stage()
                if closing { stage.controller.dismiss(reason: .escape, animated: true) }
                else {
                    stage.controller.dismiss(reason: .action, animated: false)
                    stage.controller.present(anchor: .urlField, tabID: stage.source.tabID, animated: true)
                }
                let end = Date().addingTimeInterval(time)
                while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.001))) }
                OffscreenRenderer.settle(stage.root)
                let image = OffscreenRenderer().snapshot(stage.root, scale: 1, presentation: true)
                OffscreenRenderer.writePNG(image, to: directory.appendingPathComponent(String(format: "%@-%03.0fms.png", closing ? "close" : "open", time * 1000)))
            } }
            print("wrote open/close presentation frames to \(out)")
        case "screens":
            guard let out = value(args, "--out") else { throw CLIError(description: "screens requires --out") }
            let directory = URL(fileURLWithPath: out)
            for state in names { for appearance in [ContentAppearance.light, .dark] { for scale: CGFloat in [1, 2] {
                let stage = Stage(state: state, scale: scale, appearance: appearance)
                let image = stage.render(scale: scale), panel = stage.controller.view.panelFrame
                let crop = panel.insetBy(dx: -24, dy: -24).intersection(stage.root.bounds)
                let pixels = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale).integral
                if let image = image.cropping(to: pixels) {
                    OffscreenRenderer.writePNG(image, to: directory.appendingPathComponent("\(state)-\(appearance.rawValue)@\(Int(scale))x.png"))
                }
            } } }
            print("wrote \(names.count * 4) renders to \(out)")
        default: throw CLIError(description: "unknown command \(command)")
        }
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
