import AppKit
import OpenDesign
import OpenModel
import OpenSidebar
import OpenStore
import OpenSpaceEditor

struct CLIError: Error, CustomStringConvertible { var description: String }

@MainActor
enum RenderCLI {
    static let usage = """
    space-editor-render create --out FILE.png [--width 180|200|228|300|500] [--appearance dark|light]
    space-editor-render math [--arc-json FILE]
    space-editor-render editor --out FILE.png [--scale 1|2] [--appearance dark|light]
                               [--style JSON] [--page N] [--hover CONTROL] [--backdrop RRGGBB] [--empty]
                               [--pressed CONTROL] [--focus CONTROL]
    space-editor-render picker --out FILE.png --page emoji|icons [--target space|tab|folder]
                               [--scale 1|2] [--appearance dark|light]
    space-editor-render window --out FILE.png --snapshot DIR|--synthetic [--space N] [--style JSON]
                               [--size 2216x1394] [--width 228] [--scale 1|2] [--appearance dark|light]
                               [--calibrated-import-intensity] [--fixed-p3-blend]
                               [--color-space-of CAPTURE.png | --onscreen]
    space-editor-render compare --arc CAPTURE.png --ours RENDER.png --spec editor|window|theme-window|session2-editor --out DIR
                                [--noise 0|0.45] [--state empty|light|dark]
    space-editor-render compare --spec session2-pad --capture-root SESSION17 --out .re/DIR
                                [--renderer offscreen|onscreen] [--blend display|fixed-p3]
    space-editor-render fit-light-glyphs --capture-root SESSIONS --out .re/DIR [--inspect]
    space-editor-render check
    space-editor-render bench-blend [--ticks 240]
    """
    static func value(_ args: [String], _ key: String) -> String? {
        guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static func fixtureURL(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources/space-schema1") else {
            throw CLIError(description: "missing frozen synthetic fixture \(name)")
        }
        return url
    }

    static func fixtureModel() throws -> BrowserModel {
        SnapshotMapper.model(from: try JSONDecoder().decode(SnapshotFileDTO.self, from: Data(contentsOf: fixtureURL("browser.json"))))
    }

    static func context(_ model: BrowserModel, args: [String]) throws -> SidebarContext {
        guard let window = model.windows.first else { throw CLIError(description: "snapshot has no window") }
        let space = Int(value(args, "--space") ?? "0") ?? -1
        guard model.spaces.indices.contains(space) else { throw CLIError(description: "invalid Space index") }
        window.focusedSpaceID = model.spaces[space].id
        if let width = value(args, "--width").flatMap(Double.init) { window.sidebarWidth = width }
        for space in model.spaces { window.selectedNodeBySpace[space.id] = nil }
        if let json = value(args, "--style") {
            model.spaces[space].theme = SpaceTheme(style: try JSONDecoder().decode(SpaceStyle.self, from: Data(json.utf8)))
        }
        let context = SidebarContext(model: model, windowID: window.id)
        context.systemAppearance = value(args, "--appearance") == "light" ? .light : .dark
        context.isWindowActive = !args.contains("--inactive")
        return context
    }

    static func scene(model: BrowserModel, args: [String], size: CGSize) throws -> RenderScene {
        var options = RenderScene.Options()
        options.size = size
        let context = try context(model, args: args)
        let scene = RenderScene(context: context, options: options, delegate: RecordingDelegate())
        scene.background.composesInDisplaySpace = !args.contains("--fixed-p3-blend")
        if (args.contains("--calibrated-import-intensity") || args.contains("--provisional-import-intensity")), let focused = context.focusedSpace {
            var style = SpaceThemeStyle(theme: focused.theme, system: context.systemAppearance)
            style.usesLegacyIntensity = false
            scene.background.style = style
            scene.sidebar.themeBackground = nil // keep the diagnostic override through sidebar layout
        }
        return scene
    }

    static func window(_ args: [String]) throws {
        guard let output = value(args, "--out"), args.contains("--synthetic") != (value(args, "--snapshot") != nil) else {
            throw CLIError(description: usage)
        }
        let model: BrowserModel
        if let path = value(args, "--snapshot") {
            guard let loaded = try SnapshotStore(root: URL(fileURLWithPath: path)).load() else { throw CLIError(description: "snapshot not found") }
            model = loaded
        } else { model = try fixtureModel() }
        let dimensions = (value(args, "--size") ?? "2216x1394").split(separator: "x").compactMap { Double($0) }
        let scale = Double(value(args, "--scale") ?? "1") ?? 0
        guard dimensions.count == 2, dimensions.allSatisfy({ $0 > 0 && $0.isFinite }), [1.0, 2.0].contains(scale) else {
            throw CLIError(description: "invalid size or scale")
        }
        let scene = try scene(model: model, args: args, size: CGSize(width: dimensions[0], height: dimensions[1]))
        let image: CGImage
        if args.contains("--onscreen") {
            image = try OffscreenRenderer.onscreen(scene)
        } else {
            scene.background.renderScale = scale
            // A capture's embedded display profile: composite as that display does.
            let space = try value(args, "--color-space-of").map { try Bitmap.colorSpace(of: $0) } ?? OffscreenRenderer.sRGB
            image = OffscreenRenderer().render(scene, scale: scale, colorSpace: space)
        }
        OffscreenRenderer.writePNG(image, to: URL(fileURLWithPath: output))
        print("window rendered \(image.width)x\(image.height) in \(image.colorSpace?.name.map { $0 as String } ?? "display profile")")
    }

    static func run(_ args: [String]) throws {
        guard let command = args.first else { throw CLIError(description: usage) }
        let rest = Array(args.dropFirst())
        switch command {
        case "fit-light-glyphs": try LightGlyphFit.run(rest)
        case "math": try Checks.math(rest)
        case "check": try Checks.run()
        case "bench": try LiveThemeChecks.bench(); if Checks.failed > 0 { throw CLIError(description: "bench failed") }
        case "lifetime-check": try EditorChecks.releasedControllerUndo()
        case "bench-blend": try BlendBench.run(rest)
        case "compat-range-check": EditorChecks.compatibilityRange()
        case "window": try window(rest)
        case "editor": try EditorScene.render(rest)
        case "create": try CreationChecks.render(rest)
        case "creation-check": try CreationChecks.run(); if Checks.failed > 0 { throw CLIError(description: "creation checks failed") }
        case "picker": try PickerScene.render(rest)
        case "picker-check":
            try PickerScene.check()
            if Checks.failed > 0 { throw CLIError(description: "picker checks failed") }
        case "compare":
            if value(rest, "--spec") == "session2-pad" { try SessionTwoPadCompare.run(rest) }
            else if value(rest, "--spec") == "session2-editor" { try SessionTwoCompare.run(rest) }
            else if value(rest, "--spec") == "editor" { try EditorCompare.run(rest) }
            else if ["window", "theme-window"].contains(value(rest, "--spec") ?? "") { try Compare.run(rest) }
            else { throw CLIError(description: usage) }
        default: throw CLIError(description: usage)
        }
    }
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    do { try RenderCLI.run(Array(CommandLine.arguments.dropFirst())) }
    catch { FileHandle.standardError.write(Data("space-editor-render: \(error)\n".utf8)); exit(1) }
}
