import AppKit
import OpenCommandBar
import OpenDesign

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    do {
        try CLI.run(Array(CommandLine.arguments.dropFirst()))
    } catch {
        FileHandle.standardError.write(Data("commandbar-render: \(error)\n".utf8))
        exit(1)
    }
}

@MainActor
enum CLI {
    static let usage = """
    usage:
      commandbar-render render (--state NAME | --scene FILE.json) --out FILE.png [--scale 1|2] [--size WxH] [--backdrop-color #RRGGBB]
          states: \(Scenes.names.joined(separator: ", "))
      commandbar-render compare --arc CAPTURE.png --ours RENDER.png --scene FILE.json --out DIR [--title TEXT] [--space srgb|p3]
      commandbar-render ax [--state NAME]           # dump the rendered overlay accessibility tree
      commandbar-render flows                      # keyboard and mouse flows; exit 1 on failure
      commandbar-render check                      # flows + a render of every state + the keystroke budget (tools/verify-all.sh)
      commandbar-render bench [--tabs 5000] [--history 100000] [--scale 2] [--completion]
      commandbar-render screens --out DIR [--scale 2]   # every state on synthetic data, for docs
    """

    static func value(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func size(_ s: String?) -> CGSize? {
        guard let s, let x = s.firstIndex(of: "x"), let w = Double(s[..<x]), let h = Double(s[s.index(after: x)...]) else { return nil }
        return CGSize(width: w, height: h)
    }

    static func run(_ args: [String]) throws {
        guard let cmd = args.first else { throw CLIError(description: usage) }
        let rest = Array(args.dropFirst())
        switch cmd {
        case "render": try render(rest)
        case "compare": try compare(rest)
        case "ax":
            let env = Scenes.env()
            let stage = try Scenes.run(value(rest, "--state") ?? "typing-git", env: env, size: CGSize(width: 1440, height: 900), scale: 1, backdrop: .darkPage)
            _ = stage.render(scale: 1)
            print(ReviewFlows.accessibilityDump(stage.controller.view))
        case "flows":
            report(Flows.run())
        case "check":
            // tools/verify-all.sh: flows, a render of every state, and the keystroke budget.
            var checks = Flows.run()
            checks += renderSmoke()
            // Completion A/B: the same keystrokes with inline completion on (the budget run) and off.
            let r = Bench.run(tabs: 5000, history: 100_000, scale: 2, rounds: 2, completionAB: true)
            checks.append(Flows.Check(name: "keystroke → rows drawn, main-thread CPU p95 < 8 ms (5,000 tabs, 100k history, 2x, inline completion on)",
                                      pass: r.keystrokes > 0 && r.cpuP95 < 8,
                                      detail: String(format: "CPU p50 %.2f p95 %.2f ms; wall p50 %.2f p95 %.2f ms; %d keystrokes", r.cpuP50, r.cpuP95, r.wallP50, r.wallP95, r.keystrokes)))
            print("\(checks.last!.pass ? "PASS" : "FAIL")  \(checks.last!.name)  —  \(checks.last!.detail)")
            let added = r.addedP95Milliseconds
            checks.append(Flows.Check(name: "inline completion adds ≤ 0.3 ms p95 over the plain keystroke (main-thread cycles); no extra panel layout pass (≤ 1 per keystroke)",
                                      pass: added.map { $0 <= 0.3 } ?? false && r.maxLayoutPasses <= 1 && r.meanLayoutPasses <= r.meanLayoutPassesOff + 0.02
                                        && r.completedKeystrokes * 3 >= r.keystrokes,
                                      detail: (added.map { String(format: "p95 %+.3f ms, paired median %+.3f ms; ", $0, r.pairedMedianMilliseconds ?? 0) } ?? "cycle counter \(r.counterStatus); ")
                                        + String(format: "layout passes on max %d mean %.2f, off mean %.2f; %d of %d keystrokes completed", r.maxLayoutPasses, r.meanLayoutPasses, r.meanLayoutPassesOff, r.completedKeystrokes, r.keystrokes)))
            print("\(checks.last!.pass ? "PASS" : "FAIL")  \(checks.last!.name)  —  \(checks.last!.detail)")
            report(checks)
        case "bench":
            Bench.run(tabs: Int(value(rest, "--tabs") ?? "") ?? 5000, history: Int(value(rest, "--history") ?? "") ?? 100_000,
                      scale: CGFloat(Double(value(rest, "--scale") ?? "2") ?? 2), completionAB: rest.contains("--completion"))
        case "screens": try screens(rest)
        default: throw CLIError(description: usage)
        }
    }

    static func report(_ checks: [Flows.Check]) {
        let failed = checks.filter { !$0.pass }.count
        print("\n| # | Result | Check |\n|---|---|---|")
        for (i, c) in checks.enumerated() { print("| \(i + 1) | \(c.pass ? "PASS" : "FAIL") | \(c.name) |") }
        print("\n\(checks.count - failed)/\(checks.count) passed")
        if failed > 0 { exit(1) }
    }

    /// Renders every scripted state at 2x and checks that the panel drew over the backdrop.
    static func renderSmoke() -> [Flows.Check] {
        let env = Scenes.env()
        var checks: [Flows.Check] = []
        for state in Scenes.names {
            var pass = false, detail = ""
            do {
                let stage = try Scenes.run(state, env: env, size: CGSize(width: 1100, height: 760), scale: 2, backdrop: .darkPage)
                let image = stage.render(scale: 2)
                let panel = stage.controller.view.panelFrame
                let probe = CGPoint(x: (panel.minX + 300) * 2, y: (panel.minY + 8) * 2)
                let fill = pixel(image, probe), page = pixel(image, CGPoint(x: 10, y: 10))
                if state == "little-open" {
                    pass = image.width == 980 && zip(fill, [39, 42, 55]).allSatisfy { abs($0 - $1) <= 3 }
                        && stage.controller.view.debugHasCloseButton && stage.controller.isPresented
                } else { pass = image.width == 2200 && fill != page && stage.controller.isPresented }
                detail = "\(image.width)×\(image.height), panel fill \(fill), page \(page), rows \(stage.controller.rows.count)"
            } catch { detail = "\(error)" }
            checks.append(Flows.Check(name: "render \(state) at 2x", pass: pass, detail: detail))
            print("\(pass ? "PASS" : "FAIL")  render \(state) at 2x  —  \(detail)")
        }
        return checks
    }

    static func pixel(_ image: CGImage, _ p: CGPoint) -> [Int] {
        guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return [] }
        let i = Int(p.y) * image.bytesPerRow + Int(p.x) * 4
        return [Int(ptr[i]), Int(ptr[i + 1]), Int(ptr[i + 2])]
    }

    static func render(_ args: [String]) throws {
        guard let out = value(args, "--out") else { throw CLIError(description: usage) }
        let scale = CGFloat(Double(value(args, "--scale") ?? "1") ?? 1)
        let image: CGImage
        if let scenePath = value(args, "--scene") {
            let scene = try SceneFile.load(scenePath)
            let stage = try sceneStage(scene, scale: scale)
            image = stage.render(scale: scale)
        } else if let state = value(args, "--state") {
            let env = Scenes.env()
            let color = value(args, "--backdrop-color").flatMap(RGBA.init(hexString:)) ?? CommandBarBackdrop.darkPage.color
            let stage = try Scenes.run(state, env: env, size: size(value(args, "--size")) ?? CGSize(width: 1440, height: 900), scale: scale,
                                       backdrop: CommandBarBackdrop(color: color))
            image = stage.render(scale: scale)
            if args.contains("--debug") {
                let c = stage.controller
                print("text \"\(c.text)\" scope \(c.siteScope?.id ?? "-") input \(c.view.debugInput)")
                for r in c.rows { print("  \(r.kind.rawValue) \(r.title) | \(r.subtitle) | \(r.icon) | \(r.accessory)") }
            }
        } else {
            throw CLIError(description: usage)
        }
        OffscreenRenderer.writePNG(image, to: URL(fileURLWithPath: out))
        print("wrote \(out) (\(image.width)×\(image.height))")
    }

    /// A stage that shows a scene file's fixed rows over its backdrop.
    static func sceneStage(_ scene: SceneFile, scale: CGFloat) throws -> Stage {
        let backdrop = try scene.loadBackdrop()
        let env = Scenes.env()
        let stage = Stage(size: scene.size, scale: scale, engine: env.engine, backdrop: backdrop)
        if scene.blurBackdrop == false { stage.controller.backdrop = CommandBarBackdrop(color: backdrop.color) }
        stage.root.bottomColor = scene.backdropBottomColor.flatMap(RGBA.init(hexString:))
        stage.controller.theme = try scene.loadTheme()
        // Favicons are masked in comparisons; a neutral square keeps plates and spacing real.
        let favicons = StaticFaviconSource()
        favicons.placeholder = Synthetic.icon("", color: 0x808080)
        stage.controller.favicons = favicons
        stage.controller.privacyURL = Scenes.samplePrivacyURL
        stage.controller.presentPreview(scene.preview)
        OffscreenRenderer.settle(stage.root)
        if !stage.controller.view.debugUsesOwnFieldEditor {
            print("note: first responder is \(String(describing: stage.window.firstResponder.map { type(of: $0) }))")
        }
        return stage
    }

    static func compare(_ args: [String]) throws {
        guard let arc = value(args, "--arc"), let ours = value(args, "--ours"), let scenePath = value(args, "--scene"),
              let out = value(args, "--out") else { throw CLIError(description: usage) }
        let scene = try SceneFile.load(scenePath)
        // Session-2 captures (S2) carry the display's profile: measure them in Display P3 (`--space p3`).
        ColorMath.space = value(args, "--space") == "p3" ? .displayP3 : .sRGB
        _ = try Compare.run(arcPath: arc, oursPath: ours, scene: scene, out: out, title: value(args, "--title") ?? scenePath)
    }

    /// Every state over synthetic backdrops, cropped around the panel, for docs/commandbar.md.
    static func screens(_ args: [String]) throws {
        guard let out = value(args, "--out") else { throw CLIError(description: usage) }
        let scale = CGFloat(Double(value(args, "--scale") ?? "2") ?? 2)
        let dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let env = Scenes.env()
        let size = CGSize(width: 1100, height: 760)
        for state in Scenes.names {
            let stage = try Scenes.run(state, env: env, size: size, scale: scale, backdrop: .darkPage)
            let image = stage.render(scale: scale)
            let panel = stage.controller.view.panelFrame.insetBy(dx: -40, dy: -30)
            let crop = CGRect(x: panel.minX * scale, y: panel.minY * scale, width: panel.width * scale, height: (panel.height + 40) * scale).integral
            if let cut = image.cropping(to: crop) {
                OffscreenRenderer.writePNG(cut, to: dir.appendingPathComponent("\(state).png"))
                print("wrote \(state).png")
            }
        }
        // The light-backdrop edge style (a white page behind the panel).
        let light = try Scenes.run("typing-git", env: env, size: size, scale: scale, backdrop: CommandBarBackdrop(color: RGBA(hex: 0xFFFFFF)))
        let image = light.render(scale: scale)
        let panel = light.controller.view.panelFrame.insetBy(dx: -40, dy: -30)
        if let cut = image.cropping(to: CGRect(x: panel.minX * scale, y: panel.minY * scale, width: panel.width * scale, height: (panel.height + 40) * scale).integral) {
            OffscreenRenderer.writePNG(cut, to: dir.appendingPathComponent("light-backdrop.png"))
            print("wrote light-backdrop.png")
        }
    }
}
