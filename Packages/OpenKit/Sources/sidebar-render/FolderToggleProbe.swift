import AppKit
import OpenDesign
import OpenModel
import OpenSidebar

/// Portable plain-toggle control, compiled unchanged against the pinned parent and branch.
@MainActor
enum FolderToggleProbe {
    struct Fixture {
        let model: BrowserModel, folder: Folder, scene: RenderScene, host: ScaledWindow
        let delegate: RecordingDelegate
        let expandedRows: Int
    }
    struct Sample: Codable {
        let total: Double, input: Double, reconcile: Double, layout: Double
        let expanded: Bool
    }
    static func fixture(rows: Int, scale: CGFloat, visibleRows: Int? = nil) -> Fixture {
        let profile = Profile(name: "FP10 plain")
        var nodes: [SidebarNode] = [], first: Folder!
        for i in 0..<50 {
            let children = (0..<(i == 0 ? 3 : 1)).map { k in SidebarNode.tab(Tab(url: Synthetic.url("peek-\(i)-\(k)"), title: "Synthetic child")) }
            let folder = Folder(title: "Synthetic folder", children: children)
            if first == nil { first = folder }
            nodes.append(.folder(folder))
            for k in 0..<max(0, (rows - 100) / 50) { nodes.append(.tab(Tab(url: Synthetic.url("row-\(i)-\(k)"), title: "Synthetic row"))) }
        }
        while nodes.count + 50 < rows { nodes.append(.tab(Tab(url: Synthetic.url("tail"), title: "Synthetic row"))) }
        let space = Space(title: "FP10", profileID: profile.id, pinned: nodes)
        let window = BrowserWindowState(focusedSpaceID: space.id, sidebarWidth: 228)
        let model = BrowserModel(profiles: [profile], spaces: [space], windows: [window])
        let context = SidebarContext(model: model, windowID: window.id); context.systemAppearance = .dark
        var options = RenderScene.Options(); options.size = CGSize(width: 1280, height: 900)
        let delegate = RecordingDelegate()
        let scene = RenderScene(context: context, options: options, delegate: delegate)
        let host = OffscreenRenderer.host(scene, scale: scale)
        resize(scene: scene, host: host, visibleRows: visibleRows)
        return Fixture(model: model, folder: first, scene: scene, host: host, delegate: delegate, expandedRows: scene.sidebar.focusedOutline!.numberOfRows)
    }
    static func resize(scene: RenderScene, host: ScaledWindow, visibleRows: Int?) {
        guard let visibleRows, let outline = scene.sidebar.focusedOutline, let clip = outline.enclosingScrollView?.contentView else { return }
        // Include the real 3 pt spacer in the requested native row count.
        let viewportHeight = outline.rect(ofRow: visibleRows - 1).maxY
        let height = scene.bounds.height + viewportHeight - clip.bounds.height
        host.setContentSize(NSSize(width: 1280, height: height)); scene.setFrameSize(NSSize(width: 1280, height: height))
        OffscreenRenderer.settle(scene)
    }
    static func step(_ fixture: Fixture) throws -> Sample {
        let outline = fixture.scene.sidebar.focusedOutline!
        let row = outline.row(forItem: fixture.folder)
        let view = outline.rowView(atRow: row, makeIfNecessary: true)!
        let before = SidebarDiagnostics.folderReconcileSeconds, callbacks = SidebarDiagnostics.folderReconcileCount
        let input = Bench.time { _ = view.accessibilityPerformPress() }
        guard Checks.waitFor({ SidebarDiagnostics.folderReconcileCount > callbacks }) else { throw CLIError(description: "FP10 plain control missing observed reconciliation") }
        let layout = Bench.time { fixture.scene.layoutSubtreeIfNeeded(); fixture.host.displayIfNeeded(); CATransaction.flush() }
        let reconcile = SidebarDiagnostics.folderReconcileSeconds - before
        guard outline.numberOfRows == fixture.expandedRows - (fixture.folder.isExpanded ? 0 : 3) else { throw CLIError(description: "FP10 plain native row mismatch") }
        return Sample(total: input + reconcile + layout, input: input, reconcile: reconcile, layout: layout, expanded: fixture.folder.isExpanded)
    }
    static func serve(_ args: [String]) throws {
        let rows = RenderCLI.value(args, "--rows").flatMap(Int.init) ?? 1000
        let visible = RenderCLI.value(args, "--visible-rows").flatMap(Int.init)
        guard rows == 1000, visible.map({ (1...64).contains($0) }) ?? true else {
            throw CLIError(description: "FP10 plain probe requires 1000 rows and 1...64 visible rows")
        }
        let fixture = fixture(rows: rows, scale: 2, visibleRows: visible)
        defer { SidebarDiagnostics.measuresFolderTransitions = false; fixture.host.contentView = nil; fixture.host.close() }
        SidebarDiagnostics.measuresFolderTransitions = true
        #if FP10_PARENT
        let revision = "2d51f14a1207c00157edb90f51459d97b7b1096b"
        #else
        let revision = "branch"
        #endif
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: ["ready": true, "revision": revision]))
        FileHandle.standardOutput.write(Data([10]))
        while let command = readLine() {
            if command == "quit" { return }
            guard command == "step" else { throw CLIError(description: "FP10 invalid probe command") }
            FileHandle.standardOutput.write(try JSONEncoder().encode(step(fixture))); FileHandle.standardOutput.write(Data([10]))
        }
    }
}

@MainActor
final class ParentFolderToggleProbe {
    let process = Process(), input = Pipe(), output = Pipe()
    private var buffer = Data()
    init(path: String, rows: Int, visibleRows: Int?) throws {
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["plain-toggle-probe", "--rows", String(rows)] + (visibleRows.map { ["--visible-rows", String($0)] } ?? [])
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.standardError
        try process.run()
        do {
            let ready = try JSONSerialization.jsonObject(with: line()) as? [String: Any]
            guard ready?["revision"] as? String == "2d51f14a1207c00157edb90f51459d97b7b1096b" else { throw CLIError(description: "FP10 plain control is not the pinned parent") }
        } catch { close(); throw error }
    }
    func step() throws -> FolderToggleProbe.Sample {
        try input.fileHandleForWriting.write(contentsOf: Data("step\n".utf8))
        return try JSONDecoder().decode(FolderToggleProbe.Sample.self, from: line())
    }
    private func line() throws -> Data {
        while true {
            if let end = buffer.firstIndex(of: 10) { let data = Data(buffer[..<end]); buffer.removeSubrange(...end); return data }
            let next = output.fileHandleForReading.availableData
            guard !next.isEmpty, buffer.count + next.count <= 16_384 else { throw CLIError(description: "FP10 parent probe closed or response oversized") }
            buffer.append(next)
        }
    }
    func close() {
        if process.isRunning { try? input.fileHandleForWriting.write(contentsOf: Data("quit\n".utf8)) }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.waitUntilExit() }
    }
}
