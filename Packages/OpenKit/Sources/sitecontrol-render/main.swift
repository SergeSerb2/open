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
    static let names = ["scc-basic"]
    static func value(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }; return args[i + 1]
    }
    static func run(_ args: [String]) throws {
        guard let command = args.first else { throw CLIError(description: "usage: sitecontrol-render render|ax|flows|check|bench [--state scc-basic] [--out FILE.png] [--scale 1|2] [--appearance light|dark]") }
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
            print(Flows.accessibilityDump(stage.controller.view.panel), terminator: "")
        case "flows": report(Flows.run())
        case "bench": report(Bench.run())
        case "check":
            var checks = Flows.run()
            for appearance in [ContentAppearance.light, .dark] { for scale: CGFloat in [1, 2] {
                let stage = Stage(state: state, scale: scale, appearance: appearance)
                let image = stage.render(scale: scale)
                let panel = stage.controller.view.panelFrame
                let label = "render \(state) \(appearance.rawValue) \(Int(scale))x"
                let header = pixel(image, x: Int((panel.minX + 160) * scale), y: Int((panel.minY + 8) * scale))
                let action = pixel(image, x: Int((panel.minX + 160) * scale), y: Int((panel.minY + 85) * scale))
                let footer = pixel(image, x: Int((panel.minX + 160) * scale), y: Int((panel.minY + 124) * scale))
                let separator = pixel(image, x: Int((panel.minX + 160) * scale), y: Int((panel.minY + 92) * scale))
                let page = pixel(image, x: Int(800 * scale), y: Int(600 * scale))
                let top = pixel(image, x: Int((panel.midX) * scale), y: Int((panel.minY - 10) * scale))
                let bottom = pixel(image, x: Int((panel.midX) * scale), y: Int((panel.maxY + 10) * scale))
                checks.append(Flows.Check(name: label + " header/action/footer fill and size", pass:
                    image.width == Int(1000 * scale) && image.height == Int(760 * scale) && header.count == 4 && header != page && header == action && header == footer))
                checks.append(Flows.Check(name: label + " action and footer ink", pass:
                    hasInk(image, rect: CGRect(x: panel.minX + 18, y: panel.minY + 48, width: 44, height: 36), scale: scale, fill: header) &&
                    hasInk(image, rect: CGRect(x: panel.minX + 10, y: panel.minY + 100, width: 80, height: 28), scale: scale, fill: header)))
                checks.append(Flows.Check(name: label + " separator on device pixel", pass: separator != header && pixel(image, x: Int((panel.minX+160)*scale), y: Int((panel.minY+92)*scale)+1) == header))
                checks.append(Flows.Check(name: label + " shadow visible and offset down", pass: bottom != page && luminance(bottom) < luminance(top)))
                checks.append(Flows.Check(name: label + " anchor x241 y40 without arrow", pass: panel.minX == 241 && panel.minY == 40 && pixel(image, x: Int(235*scale), y: Int(64*scale)) != header))
            } }
            checks.append(contentsOf: try receipts())
            checks.append(contentsOf: Bench.run())
            report(checks)
        default: throw CLIError(description: "unknown command \(command)")
        }
    }
    static func luminance(_ pixel: [UInt8]) -> Int { pixel.prefix(3).map(Int.init).reduce(0, +) }
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
        let directory = root.appendingPathComponent("docs/sitecontrol/step-1")
        let lines = try String(contentsOf: directory.appendingPathComponent("SHA256SUMS"), encoding: .utf8).split(separator: "\n")
        let required = Set(["scc-basic-light@1x.png", "scc-basic-light@2x.png", "scc-basic-dark@1x.png", "scc-basic-dark@2x.png"])
        var found = Set<String>(), checks: [Flows.Check] = []
        for line in lines {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2, required.contains(String(parts[1])) else { throw CLIError(description: "invalid render SHA256SUMS entry") }
            let name = String(parts[1]); found.insert(name)
            let hash = SHA256.hash(data: try Data(contentsOf: directory.appendingPathComponent(name))).map { String(format: "%02x", $0) }.joined()
            checks.append(Flows.Check(name: "committed SHA256 " + name, pass: hash == parts[0]))
        }
        checks.append(Flows.Check(name: "four committed render receipts", pass: found == required && lines.count == required.count))
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
