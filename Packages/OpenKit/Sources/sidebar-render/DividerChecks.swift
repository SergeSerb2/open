import AppKit
import OpenSidebar

/// CU5 compares the real divider against the baseline release executable.
@MainActor enum DividerChecks {
    static func run(_ args: [String]) throws {
        guard let baseline = RenderCLI.value(args, "--baseline"), let output = RenderCLI.value(args, "--out") else {
            throw CLIError(description: "divider-check --baseline RELEASE_RENDERER --out DIR")
        }
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The caller reads unchanged main's committed manifest. Schema 1 uses
        // scale/ICC; the candidate and caller still check the complete mode.
        let baselineDisplayKey = RenderCLI.value(args, "--baseline-display-key")
        func command(_ executable: String, _ arguments: [String], log: URL) throws {
            _ = FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments; process.standardOutput = handle; process.standardError = handle
            if executable == baseline, let baselineDisplayKey {
                var environment = ProcessInfo.processInfo.environment
                environment["OPEN_VERIFY_DISPLAY_KEY"] = baselineDisplayKey
                process.environment = environment
            }
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CLIError(description: "CU5 command failed; see \(log.path)") }
        }
        let snapshot = root.appendingPathComponent("synthetic")
        try command(baseline, ["synth", "--out", snapshot.path], log: root.appendingPathComponent("synth.log"))
        let model = try RenderCLI.loadModel(snapshot.path)
        let context = try RenderCLI.makeContext(["--space", "0", "--appearance", "light"], model: model)
        var options = RenderScene.Options(); options.size = CGSize(width: 228, height: 900)
        let delegate = RecordingDelegate()
        let scene = RenderScene(context: context, options: options, delegate: delegate)
        let host = OffscreenRenderer.host(scene, scale: 2)
        defer { host.contentView = nil; host.close() }
        guard let divider = scene.sidebar.clearControl?.view else { throw CLIError(description: "CU5 fixture has no divider") }
        let region = scene.convert(divider.bounds, from: divider)
        for clear in [false, true] {
            let name = clear ? "clear" : "rest"
            var matched = false
            for attempt in 1...3 {
                var images: [Bitmap] = []
                for (kind, executable) in [("main", baseline), ("branch", CommandLine.arguments[0])] {
                    let image = root.appendingPathComponent("\(name)-\(attempt)-\(kind).png")
                    let render = ["render", "--snapshot", snapshot.path, "--space", "0", "--appearance", "light", "--size", "228x900", "--scale", "2", "--out", image.path] + (clear ? ["--hover", "divider"] : [])
                    try command(executable, render, log: image.deletingPathExtension().appendingPathExtension("log"))
                    images.append(try Bitmap(path: image.path))
                }
                matched = true
                for y in Int(region.minY * 2)..<Int(region.maxY * 2) {
                    let start = (y * images[0].width + Int(region.minX * 2)) * 4
                    let end = start + Int(region.width * 2) * 4
                    if images[0].data[start..<end] != images[1].data[start..<end] { matched = false; break }
                }
                print("CU5 \(name) paired attempt \(attempt): \(matched ? "identical" : "differs (retained)")")
                if matched { break }
            }
            guard matched else { throw CLIError(description: "CU5 \(name) divider differs from baseline") }
        }
        print("CU5: 2/2 passed (rest and Clear, exact divider pixels; all attempts retained)")
    }
}
