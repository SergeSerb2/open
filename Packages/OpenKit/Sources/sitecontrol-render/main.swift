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
    static let foundationNames = ["scc-no-boosts","scc-hover-action","scc-pane-anchor","scc-clamped"]
    static let names = ["scc-no-boosts","scc-boost","scc-adblock-on","scc-adblock-excluded","scc-adblock-unavailable","scc-insecure","scc-boosts-off","scc-incognito","scc-internal-page","scc-many","scc-pane-anchor","scc-clamped","scc-light","scc-hover-label","scc-hover-boost","scc-hover-action","scc-keyboard-focus","scc-reload","scc-menu","scc-picker","scc-tooltip","scc-tooltip-on","scc-tooltip-off","scc-tooltip-unavailable","scc-tooltip-private","scc-focus-boost"]
    static func value(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }; return args[i + 1]
    }
    static func run(_ args: [String]) throws {
        guard let command = args.first else { throw CLIError(description: "usage: sitecontrol-render render|ax|flows|check|bench|screens|motion|compare [--state scc-no-boosts] [--out FILE.png] [--scale 1|2] [--appearance light|dark]") }
        if command == "compare" { try MaterialFallback.configure(args) }
        let state = value(args, "--state") ?? "scc-no-boosts"
        guard names.contains(state) else { throw CLIError(description: "unknown state \(state)") }
        let scale = CGFloat(Double(value(args, "--scale") ?? "1") ?? 0)
        guard scale == 1 || scale == 2 else { throw CLIError(description: "scale must be 1 or 2") }
        let appearanceName = value(args, "--appearance") ?? "dark"
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
        case "probes":
            var checks: [Flows.Check] = []
            for name in names { for appearance in [ContentAppearance.light,.dark] { for scale: CGFloat in [1,2] {
                autoreleasepool { checks += ChromeProbes.run(Stage(state: name,scale: scale,appearance: appearance),appearance: appearance) }
            } } }
            report(checks)
        case "check":
            var checks = Flows.run()
            for name in names { for appearance in [ContentAppearance.light,.dark] { for scale: CGFloat in [1,2] {
                autoreleasepool {
                    let stage = Stage(state: name,scale: scale,appearance: appearance)
                    checks += ChromeProbes.run(stage,appearance: appearance)
                }
            } } }
            checks += try receipts(); checks += Bench.run(); report(checks)
        case "screens":
            guard let out = value(args,"--out") else { throw CLIError(description: "screens requires --out") }
            for name in names { for appearance in [ContentAppearance.light,.dark] { for scale: CGFloat in [1,2] {
                autoreleasepool {
                    let stage = Stage(state: name,scale: scale,appearance: appearance)
                    OffscreenRenderer.writePNG(stage.render(scale: scale),to: URL(fileURLWithPath: out).appendingPathComponent("\(name)-\(appearance.rawValue)@\(Int(scale))x.png"))
                }
            } } }
        case "motion":
            guard let out = value(args,"--out") else { throw CLIError(description: "motion requires --out") }; try MotionChecks.frames(out: URL(fileURLWithPath: out))
        case "compare": try SiteControlCompare.run(args)
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
        let directory = root.appendingPathComponent("docs/sitecontrol/step-2")
        let lines = try String(contentsOf: directory.appendingPathComponent("SHA256SUMS"), encoding: .utf8).split(separator: "\n")
        let required = Set(names.flatMap { name in ["light","dark"].flatMap { mode in [1,2].map { "\(name)-\(mode)@\($0)x.png" } } })
        var found = Set<String>(), checks: [Flows.Check] = []
        for line in lines {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2, required.contains(String(parts[1])) else { throw CLIError(description: "invalid render SHA256SUMS entry") }
            let name = String(parts[1]); found.insert(name)
            let hash = SHA256.hash(data: try Data(contentsOf: directory.appendingPathComponent(name))).map { String(format: "%02x", $0) }.joined()
            checks.append(Flows.Check(name: "committed SHA256 " + name, pass: hash == parts[0]))
        }
        checks.append(Flows.Check(name: "complete committed render receipts", pass: found == required && lines.count == required.count))
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
