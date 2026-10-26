import AppKit
import OpenDesign
import OpenModel
import OpenSidebar
import OpenStore

struct CLIError: Error, CustomStringConvertible { var description: String }

@MainActor
enum RenderCLI {
    static func run(_ args: [String]) throws {
        guard let cmd = args.first else { throw CLIError(description: usage) }
        let rest = Array(args.dropFirst())
        switch cmd {
        case "render": try render(rest)
        case "synth": try synth(rest)
        case "tooltip": try tooltip(rest)
        case "compare": try Compare.run(rest)
        case "bench": try Bench.run(rest)
        case "check": try Checks.run(rest)
        default: throw CLIError(description: usage)
        }
    }

    static let usage = """
    usage:
      sidebar-render render --snapshot DIR --out FILE.png [--size WxH] [--scale 1|2] [--space N]
                            [--width W] [--select ROW] [--hover TARGET] [--loaded] [--new-tab-open]
                            [--hidden] [--reveal] [--inactive] [--appearance light|dark]
                            [--clear-today] [--collapse-folders] [--no-lights] [--page] [--crop X,Y,W,H]
          ROW: pinned:N | today:N | favorite:N | folder:N/M (child M of the N-th pinned folder)
          TARGET: ROW | newtab | divider | header | url | home | plus | switcher:N | toolbar:back|forward|reload|toggle
          --switch-to N --at SECONDS: start an animated switch to Space N and capture that moment
      sidebar-render tooltip --snapshot DIR [--space N] --title TEXT [--subtitle TEXT] [--keys "⌘,["] --out FILE.png [--scale S]
      sidebar-render synth --out DIR [--rows N]
      sidebar-render compare --arc FILE.png --ours FILE.png --spec NAME --out DIR [--scale S]
      sidebar-render bench [--rows N]
      sidebar-render check
    """

    static func value(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func size(_ s: String?) -> CGSize? {
        guard let s, let x = s.firstIndex(of: "x"), let w = Double(s[..<x]), let h = Double(s[s.index(after: x)...]) else { return nil }
        return CGSize(width: w, height: h)
    }

    static func loadModel(_ dir: String) throws -> BrowserModel {
        let store = SnapshotStore(root: URL(fileURLWithPath: dir))
        guard let model = try store.load() else { throw CLIError(description: "no snapshot in \(dir)") }
        return model
    }

    /// Resolves `pinned:N`, `today:N`, `favorite:N`, `folder:N/M` in the focused Space.
    static func resolve(_ spec: String, context: SidebarContext) -> ItemID? {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let space = context.focusedSpace else { return nil }
        switch parts[0] {
        case "pinned": return Int(parts[1]).flatMap { space.pinned.indices.contains($0) ? space.pinned[$0].id : nil }
        case "today": return Int(parts[1]).flatMap { space.today.indices.contains($0) ? space.today[$0].id : nil }
        case "favorite": return Int(parts[1]).flatMap { i in context.favoritesProfile.flatMap { $0.favorites.indices.contains(i) ? $0.favorites[i].id : nil } }
        case "folder":
            let nm = parts[1].split(separator: "/").compactMap { Int($0) }
            let folders = space.pinned.compactMap(\.folder)
            guard nm.count == 2, folders.indices.contains(nm[0]), folders[nm[0]].children.indices.contains(nm[1]) else { return nil }
            return folders[nm[0]].children[nm[1]].id
        default: return nil
        }
    }

    static func hoverTarget(_ spec: String, context: SidebarContext) -> SidebarHoverTarget? {
        switch spec {
        case "newtab": return .newTab
        case "divider": return .divider
        case "header": return .header
        case "url": return .urlField
        case "home": return .home
        case "plus": return .plus
        case "toolbar:back": return .toolbar(.back)
        case "toolbar:forward": return .toolbar(.forward)
        case "toolbar:reload": return .toolbar(.reload)
        case "toolbar:toggle": return .toolbar(.sidebarToggle)
        default:
            if spec.hasPrefix("switcher:"), let i = Int(spec.dropFirst(9)), context.model.spaces.indices.contains(i) {
                return .switcher(context.model.spaces[i].id)
            }
            if spec.hasPrefix("favorite:") { return resolve(spec, context: context).map { .favorite($0) } }
            return resolve(spec, context: context).map { .row($0) }
        }
    }

    /// Builds the context for a snapshot and applies the forced states.
    static func makeContext(_ args: [String], model: BrowserModel) throws -> SidebarContext {
        guard let window = model.windows.first else { throw CLIError(description: "snapshot has no window") }
        if let n = value(args, "--space").flatMap(Int.init) {
            guard model.spaces.indices.contains(n) else { throw CLIError(description: "no Space \(n)") }
            window.focusedSpaceID = model.spaces[n].id
        }
        if let w = value(args, "--width").flatMap(Double.init) { window.sidebarWidth = w }
        // Renders start with nothing selected, as in the idle captures.
        for s in model.spaces { window.selectedNodeBySpace[s.id] = nil }
        let context = SidebarContext(model: model, windowID: window.id)
        context.systemAppearance = value(args, "--appearance") == "light" ? .light : .dark
        context.isWindowActive = !args.contains("--inactive")
        context.isNewTabCommandBarOpen = args.contains("--new-tab-open")
        if args.contains("--clear-today"), let s = context.focusedSpace { s.today = []; model.rebuildIndex() }
        // Capture-matching edits (render only): clear a Space title, insert a tab into a folder.
        if let n = value(args, "--untitled").flatMap(Int.init), model.spaces.indices.contains(n) { model.spaces[n].title = "" }
        if let spec = value(args, "--insert-folder-tab"), let s = context.focusedSpace {
            // "N/M=Title": insert at child M of the N-th pinned folder.
            let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
            let nm = parts.first?.split(separator: "/").compactMap { Int($0) } ?? []
            let folders = s.pinned.compactMap(\.folder)
            if parts.count == 2, nm.count == 2, folders.indices.contains(nm[0]) {
                let u = URL(string: "https://example.com/")!
                folders[nm[0]].children.insert(.tab(Tab(url: u, title: parts[1], pinnedURL: u)), at: min(nm[1], folders[nm[0]].children.count))
                model.rebuildIndex()
            }
        }
        if let n = value(args, "--drop-today").flatMap(Int.init), let s = context.focusedSpace {
            s.today = Array(s.today.dropFirst(n)); model.rebuildIndex()
        }
        if args.contains("--collapse-folders") {
            func walk(_ nodes: [SidebarNode]) { for case .folder(let f) in nodes { f.isExpanded = false; walk(f.children) } }
            for s in model.spaces { walk(s.pinned); walk(s.today) }
        }
        if let sel = value(args, "--select") {
            guard let id = resolve(sel, context: context), let space = context.focusedSpace else { throw CLIError(description: "no row \(sel)") }
            window.selectedNodeBySpace[space.id] = id
        }
        if args.contains("--loaded") { context.isTabLoaded = { _ in true } }
        if let h = value(args, "--hover") {
            guard let t = hoverTarget(h, context: context) else { throw CLIError(description: "no hover target \(h)") }
            context.forcedHover = t
        }
        return context
    }

    static func render(_ args: [String]) throws {
        guard let dir = value(args, "--snapshot"), let out = value(args, "--out") else { throw CLIError(description: usage) }
        let model = try loadModel(dir)
        let context = try makeContext(args, model: model)
        var options = RenderScene.Options()
        if let s = size(value(args, "--size")) { options.size = s }
        options.sidebarHidden = args.contains("--hidden") || args.contains("--reveal")
        options.revealCard = args.contains("--reveal")
        options.trafficLights = !args.contains("--no-lights")
        options.emptyPanel = !args.contains("--page")
        let scale = CGFloat(Double(value(args, "--scale") ?? "1") ?? 1)
        let delegate = RecordingDelegate()
        let scene = RenderScene(context: context, options: options, delegate: delegate)
        scene.background.renderScale = scale
        var image: CGImage
        if let n = value(args, "--switch-to").flatMap(Int.init), model.spaces.indices.contains(n), let window = model.windows.first {
            // A transition frame: animate the switch and capture the presentation tree at `--at` seconds.
            SidebarDiagnostics.forceAnimations = true
            let host = OffscreenRenderer.host(scene, scale: scale)
            model.focusSpace(windowID: window.id, spaceID: model.spaces[n].id)
            let at = Double(value(args, "--at") ?? "0.1") ?? 0.1
            RunLoop.main.run(until: Date().addingTimeInterval(at))
            image = OffscreenRenderer().snapshot(scene, scale: scale, presentation: true)
            host.contentView = nil
            host.close()
        } else {
            image = OffscreenRenderer().render(scene, scale: scale)
        }
        if let c = value(args, "--crop")?.split(separator: ",").compactMap({ Double($0) }), c.count == 4 {
            image = image.cropping(to: CGRect(x: c[0] * scale, y: c[1] * scale, width: c[2] * scale, height: c[3] * scale)) ?? image
        }
        OffscreenRenderer.writePNG(image, to: URL(fileURLWithPath: out))
        print("wrote \(out) \(image.width)x\(image.height)")
    }

    /// Renders one Arc-style tooltip capsule in a Space's colors.
    static func tooltip(_ args: [String]) throws {
        guard let dir = value(args, "--snapshot"), let out = value(args, "--out"), let title = value(args, "--title") else { throw CLIError(description: usage) }
        let model = try loadModel(dir)
        let context = try makeContext(args, model: model)
        guard let space = context.focusedSpace else { return }
        let keys = value(args, "--keys")?.split(separator: ",").map(String.init) ?? []
        let tip = Tooltip(title: title, subtitle: value(args, "--subtitle"), keys: keys, style: context.style(for: space))
        let view = TooltipView(tooltip: tip)
        let pad: CGFloat = 12
        let frame = NSView(frame: CGRect(x: 0, y: 0, width: view.fittingSize.width + 2 * pad, height: view.fittingSize.height + 2 * pad))
        frame.wantsLayer = true
        frame.layer?.backgroundColor = CGColor(gray: 0.5, alpha: 0.15)
        view.frame = CGRect(x: pad, y: pad, width: view.fittingSize.width, height: view.fittingSize.height)
        frame.addSubview(view)
        let scale = CGFloat(Double(value(args, "--scale") ?? "2") ?? 2)
        let image = OffscreenRenderer().render(frame, scale: scale)
        OffscreenRenderer.writePNG(image, to: URL(fileURLWithPath: out))
        print("wrote \(out) \(image.width)x\(image.height)")
    }

    static func synth(_ args: [String]) throws {
        guard let out = value(args, "--out") else { throw CLIError(description: usage) }
        let model = Synthetic.model(bulkRows: value(args, "--rows").flatMap(Int.init))
        try Synthetic.write(model, to: URL(fileURLWithPath: out))
        print("wrote synthetic snapshot to \(out): \(model.spaces.count) Spaces, \(model.index.count) nodes")
    }
}
