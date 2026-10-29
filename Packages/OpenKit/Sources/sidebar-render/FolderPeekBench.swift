import AppKit
import OpenDesign
import OpenModel
import OpenSidebar

/// Matched native sidebar workloads. One-child expanded baseline has identical row geometry.
@MainActor
enum FolderPeekBench {
    @MainActor struct Fixture {
        let model: BrowserModel, folder: Folder, scene: RenderScene, host: ScaledWindow
        let delegate: RecordingDelegate
        var sidebar: SidebarView { scene.sidebar }
    }
    static func run(_ args: [String], folders: Int) throws {
        let control = args.contains("--negative-proof") || args.contains("--negative-transition-proof")
        let attempts = control ? 1 : 3
        var failures: [String] = []
        var passed = false
        for attempt in 1...attempts {
            print(String(format: "FP10 attempt %d/%d load1 start=%.2f", attempt, attempts, Checks.loadAverage1()))
            do { try runAttempt(args, folders: folders); passed = true }
            catch { failures.append(String(describing: error)); print("FP10 attempt \(attempt) FAIL: \(error)") }
        }
        guard passed else { throw CLIError(description: failures.last ?? "FP10 no attempt passed") }
    }

    private static func runAttempt(_ args: [String], folders: Int) throws {
        let negativeProof = args.contains("--negative-proof")
        let negativeTransition = args.contains("--negative-transition-proof")
        let fast = negativeProof || negativeTransition
        guard !(negativeProof && negativeTransition) else { throw CLIError(description: "FP10 controls must run separately") }
        print("FP10 limits: transition main-thread wall p95 <= 2.00 ms, or matched plain p95 * 1.10 + 0.05 ms if pinned parent plain p95 > 2.00 ms; native row layouts/frame peek <= baseline; scroll p95 <= 8.33 ms AND <= baseline p95 * 1.10 + 0.05 ms")
        if negativeTransition { print("FP10 negative control: real 3 ms busy wait inside transition reconciliation") }
        let rows = RenderCLI.value(args, "--rows").flatMap(Int.init) ?? 1000
        let scale = CGFloat(Double(RenderCLI.value(args, "--scale") ?? "2") ?? 2)
        guard folders == 50, rows == 1000, scale == 2 else { throw CLIError(description: "FP10 requires --rows 1000 --scale 2 --folder-peek 50 for matched controls") }
        let visibleRows = RenderCLI.value(args, "--visible-rows").flatMap(Int.init)
        guard visibleRows.map({ (1...64).contains($0) }) ?? true else { throw CLIError(description: "FP10 visible rows must be 1...64") }
        func fixture(peek: Bool) -> Fixture {
            let profile = Profile(name: "FP10")
            var nodes: [SidebarNode] = [], first: Folder!
            let spacing = max(1, (rows - folders * 2) / folders)
            for i in 0..<folders {
                let children = (0..<(peek ? 3 : 1)).map { k in SidebarNode.tab(Tab(url: Synthetic.url("peek-\(i)-\(k)"), title: "Synthetic child")) }
                let folder = Folder(title: "Synthetic folder", isExpanded: !peek, children: children, peekedChildID: peek ? children[1].id : nil)
                if first == nil { first = folder }
                nodes.append(.folder(folder))
                for k in 0..<spacing { nodes.append(.tab(Tab(url: Synthetic.url("row-\(i)-\(k)"), title: "Synthetic row"))) }
            }
            while nodes.count + folders < rows { nodes.append(.tab(Tab(url: Synthetic.url("tail"), title: "Synthetic row"))) }
            let space = Space(title: "FP10", profileID: profile.id, pinned: nodes)
            let window = BrowserWindowState(focusedSpaceID: space.id, sidebarWidth: 228)
            let model = BrowserModel(profiles: [profile], spaces: [space], windows: [window])
            let context = SidebarContext(model: model, windowID: window.id)
            context.systemAppearance = .dark
            var options = RenderScene.Options(); options.size = CGSize(width: 1280, height: 900)
            let delegate = RecordingDelegate()
            let scene = RenderScene(context: context, options: options, delegate: delegate)
            let host = OffscreenRenderer.host(scene, scale: scale)
            FolderToggleProbe.resize(scene: scene, host: host, visibleRows: visibleRows)
            return Fixture(model: model, folder: first, scene: scene, host: host, delegate: delegate)
        }
        let baseline = fixture(peek: false), peek = fixture(peek: true)
        let plain = FolderToggleProbe.fixture(rows: rows, scale: scale, visibleRows: visibleRows)
        // Register fixture cleanup before the parent launch, which can throw.
        defer {
            SidebarDiagnostics.folderTrace = nil
            SidebarDiagnostics.measuresFolderTransitions = false
            SidebarDiagnostics.folderBenchFullRowWindowID = nil
            SidebarDiagnostics.folderBenchBusyWindowID = nil
            for f in [baseline, peek] { f.host.contentView = nil; f.host.close() }
            plain.host.contentView = nil; plain.host.close()
        }
        let parent = try RenderCLI.value(args, "--parent-renderer").map { try ParentFolderToggleProbe(path: $0, rows: rows, visibleRows: visibleRows) }
        defer { parent?.close() }
        func p95(_ values: [Double]) -> Double { let v = values.sorted(); return v[min(v.count - 1, Int(Double(v.count) * 0.95))] }
        func receipt(_ name: String, _ values: [Double]) {
            let v = values.sorted()
            print(String(format: "FP10 %@ n=%d median %@ p95 %@ max %@ load1=%.2f", name, v.count, Bench.ms(v[v.count/2]), Bench.ms(p95(v)), Bench.ms(v.last!), Checks.loadAverage1()))
        }
        typealias ScrollFrame = (seconds: Double, layouts: Int)
        func scroll(_ f: Fixture, step: Int) -> ScrollFrame {
            let outline = f.sidebar.focusedOutline!, clip = outline.enclosingScrollView!.contentView
            let maxY = max(0, outline.frame.height - clip.bounds.height)
            let y = min(maxY, CGFloat(step % max(1, Int(maxY / 120))) * 120)
            let before = SidebarDiagnostics.tabRowLayouts + SidebarDiagnostics.folderRowLayouts
            let elapsed = Bench.time {
                clip.scroll(to: NSPoint(x: 0, y: y)); outline.enclosingScrollView?.reflectScrolledClipView(clip)
                f.scene.layoutSubtreeIfNeeded(); f.host.displayIfNeeded(); CATransaction.flush()
            }
            return (elapsed, SidebarDiagnostics.tabRowLayouts + SidebarDiagnostics.folderRowLayouts - before)
        }
        if negativeProof { SidebarDiagnostics.folderBenchFullRowWindowID = peek.model.windows[0].id }
        for i in 0..<(fast ? 2 : 40) { _ = scroll(baseline, step: i); _ = scroll(peek, step: i) }
        var baseFrames: [ScrollFrame] = [], peekFrames: [ScrollFrame] = []
        for i in 0..<(fast ? 12 : 400) {
            if i.isMultiple(of: 2) { baseFrames.append(scroll(baseline, step: i)); peekFrames.append(scroll(peek, step: i)) }
            else { peekFrames.append(scroll(peek, step: i)); baseFrames.append(scroll(baseline, step: i)) }
        }
        let baseScroll = baseFrames.map { $0.seconds }, peekScroll = peekFrames.map { $0.seconds }
        let baselineWork = baseFrames.map { $0.layouts }.max()!, peekWork = peekFrames.map { $0.layouts }.max()!
        let nativeScrollRows = peek.sidebar.visibleRowCount
        let clockOverhead = (0..<1000).map { _ in Bench.time {} }.max()!
        receipt("baseline-scroll", baseScroll); receipt("peek-scroll", peekScroll)
        print(String(format: "FP10 paired p95 delta=%.6f ms clock/read overhead=%.6f ms", (p95(peekScroll)-p95(baseScroll))*1000, clockOverhead*1000))
        print("FP10 native row layouts/frame max: baseline=\(baselineWork) peek=\(peekWork); displayed node rows=\(rows)")
        // Deterministic paired work gate, independent of scheduler/WindowServer stalls.
        guard peekWork <= baselineWork else {
            throw CLIError(description: "FP10 FAIL row layouts/frame: peek \(peekWork) > matched baseline \(baselineWork)")
        }
        if negativeProof { throw CLIError(description: "FP10 negative control was not observed; no negative proof accepted") }
        let outline = peek.sidebar.focusedOutline!, clip = outline.enclosingScrollView!.contentView
        clip.scroll(to: .zero); OffscreenRenderer.settle(peek.scene, runLoop: 0.01)
        let f = peek.folder
        peek.model.setExpanded(folderID: f.id, expanded: true)
        let space = peek.model.spaces[0], window = peek.model.windows[0]
        peek.model.selectNode(windowID: window.id, spaceID: space.id, nodeID: f.children[1].id)
        OffscreenRenderer.settle(peek.scene, runLoop: 0.01)
        SidebarDiagnostics.folderBenchBusyWindowID = negativeTransition ? peek.model.windows[0].id : nil
        SidebarDiagnostics.measuresFolderTransitions = true
        let reloads = SidebarDiagnostics.fullReloads
        var transitions: [Double] = [], inputs: [Double] = [], reconciles: [Double] = [], layouts: [Double] = []
        var phases: [String: [Double]] = [:]
        var cpuSamples: [Double] = []
        let transitionCount = fast ? 24 : 240
        func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }
        var parentSamples: [FolderToggleProbe.Sample] = [], plainSamples: [FolderToggleProbe.Sample] = []
        // Warm native reuse pools before allocation and transition measurement.
        for _ in 0..<12 { _ = try FolderToggleProbe.step(plain); _ = try parent?.step() }
        var peekCounters: [String: Int] = [:]
        func peekStep() throws {
            let countersBefore = SidebarDiagnostics.folderBenchCounters
            let workBefore = [SidebarDiagnostics.folderSyncItemsVisited, SidebarDiagnostics.folderStateRowsConfigured,
                              SidebarDiagnostics.folderRowLayouts + SidebarDiagnostics.tabRowLayouts,
                              SidebarDiagnostics.folderFaviconDraws, SidebarDiagnostics.folderTitleDraws]
            let phaseBefore = SidebarDiagnostics.folderReconcilePhases
            let row = outline.row(forItem: f)
            let view = outline.rowView(atRow: row, makeIfNecessary: true)!
            let before = SidebarDiagnostics.folderReconcileSeconds, callbacks = SidebarDiagnostics.folderReconcileCount
            let cpuBefore = SidebarDiagnostics.folderReconcileCPUSeconds
            let inputCPUStart = cpu()
            let input = Bench.time { _ = view.accessibilityPerformPress() }
            let inputCPU = cpu() - inputCPUStart
            // Await queued Observation via the synchronous harness's native run loop.
            // Exclude suspension/wall time; include measured completed reconciliation plus layout/display.
            let observed = Checks.waitFor { SidebarDiagnostics.folderReconcileCount > callbacks }
            guard observed else { throw CLIError(description: "FP10 no completed Observation reconciliation") }
            let layoutCPUStart = cpu()
            let layout = Bench.time { peek.scene.layoutSubtreeIfNeeded(); peek.host.displayIfNeeded(); CATransaction.flush() }
            let layoutCPU = cpu() - layoutCPUStart
            let reconciliation = SidebarDiagnostics.folderReconcileSeconds - before
            let childCount: Int
            switch f.expansion { case .expanded: childCount = 3; case .peeked: childCount = 1; case .collapsed: childCount = 0 }
            guard outline.numberOfRows == nativeScrollRows + childCount - 1 else {
                throw CLIError(description: "FP10 native transition row count does not match the real folder state")
            }
            cpuSamples.append(inputCPU + SidebarDiagnostics.folderReconcileCPUSeconds - cpuBefore + layoutCPU)
            inputs.append(input); reconciles.append(reconciliation); layouts.append(layout)
            transitions.append(input + reconciliation + layout)
            let workAfter = [SidebarDiagnostics.folderSyncItemsVisited, SidebarDiagnostics.folderStateRowsConfigured,
                             SidebarDiagnostics.folderRowLayouts + SidebarDiagnostics.tabRowLayouts,
                             SidebarDiagnostics.folderFaviconDraws, SidebarDiagnostics.folderTitleDraws]
            for (i, key) in ["visited-items", "configured-rows", "cell-layouts", "favicon-draws", "title-draws"].enumerated() {
                peekCounters[key, default: 0] += workAfter[i] - workBefore[i]
            }
            for (name, total) in SidebarDiagnostics.folderBenchCounters {
                peekCounters[name, default: 0] += total - (countersBefore[name] ?? 0)
            }
            for (name, total) in SidebarDiagnostics.folderReconcilePhases {
                phases[name, default: []].append(total - (phaseBefore[name] ?? 0))
            }
        }
        // Cycle all three real states so inserted native cells have entered the reuse pool.
        for _ in 0..<12 { try peekStep() }
        transitions = []; inputs = []; reconciles = []; layouts = []; cpuSamples = []; phases = [:]; peekCounters = [:]
        if args.contains("--trace-transition") {
            var events: [String] = []
            SidebarDiagnostics.folderTrace = { if events.count < 200 { events.append($0) } }
            try peekStep()
            SidebarDiagnostics.folderTrace = nil
            print("FP10 TRACE one transition, excluded from timed samples:")
            events.forEach { print("FP10 TRACE " + $0) }
            transitions = []; inputs = []; reconciles = []; layouts = []; cpuSamples = []; phases = [:]; peekCounters = [:]
        }
        for i in 0..<transitionCount {
            // Rotate all three paths. IPC wait is outside the parent's measured sample.
            for kind in [i % 3, (i + 1) % 3, (i + 2) % 3] {
                switch kind {
                case 0: if let parent { parentSamples.append(try parent.step()) }
                case 1: plainSamples.append(try FolderToggleProbe.step(plain))
                default: try peekStep()
                }
            }
        }
        receipt("branch-plain-main-thread", plainSamples.map(\.total))
        for expanded in [false, true] {
            receipt("branch-plain-" + (expanded ? "expand" : "collapse"), plainSamples.filter { $0.expanded == expanded }.map(\.total))
        }
        if !parentSamples.isEmpty {
            receipt("parent-2d51f14a-plain-main-thread", parentSamples.map(\.total))
            for expanded in [false, true] {
                receipt("parent-plain-" + (expanded ? "expand" : "collapse"), parentSamples.filter { $0.expanded == expanded }.map(\.total))
            }
        }
        for name in phases.keys.sorted() { receipt("phase-" + name, phases[name]!) }
        for key in Set(peekCounters.keys).union(["note-height-calls", "noted-heights", "row-layouts", "row-allocations", "cell-allocations"]).sorted() { print("FP10 peek work \(key)=\(peekCounters[key, default: 0]) total / \(transitionCount) transitions") }
        receipt("transition-main-thread", transitions)
        receipt("transition-thread-cpu-diagnostic", cpuSamples)
        receipt("transition-input", inputs); receipt("transition-reconcile-and-display", reconciles); receipt("transition-final-layout", layouts)
        print("FP10 window=\(peek.scene.bounds.size) clip=\(clip.bounds.size) native visible rows=\(outline.rows(in: clip.bounds).length)")
        print("FP10 displayedNodes=\(rows) folders=\(folders) peekModelNodes=\(peek.model.index.count) nativeRows=\(nativeScrollRows) scale=\(scale); excludes fixture construction, queued wait and animation wall time")
        let relativeLimit = p95(baseScroll) * 1.10 + 0.00005
        print(String(format: "FP10 paired scroll p95 limit=%.3f ms", relativeLimit * 1000))
        let parentExceedsTarget = !parentSamples.isEmpty && p95(parentSamples.map(\.total)) > 0.002
        // A slow parent establishes the outline-wide floor. The branch's plain
        // toggle is the same-run paired control used for the allowed overhead.
        let transitionLimit = parentExceedsTarget ? max(0.002, p95(plainSamples.map(\.total)) * 1.10 + 0.00005) : 0.002
        print(String(format: "FP10 transition p95 peek=%.3f ms plain=%.3f ms parent=%.3f ms limit=%.3f ms; parent exemption=%@ load1=%.2f", p95(transitions)*1000, p95(plainSamples.map(\.total))*1000, parentSamples.isEmpty ? 0 : p95(parentSamples.map(\.total))*1000, transitionLimit*1000, parentExceedsTarget ? "yes" : "no", Checks.loadAverage1()))
        guard p95(transitions) <= transitionLimit else { throw CLIError(description: "FP10 transition p95 exceeds printed matched plain limit") }
        guard p95(peekScroll) <= 0.00833 else { throw CLIError(description: "FP10 scroll exceeds 8.33 ms") }
        guard p95(peekScroll) <= relativeLimit else { throw CLIError(description: "FP10 scroll p95 exceeds matched baseline * 1.10 + 0.05 ms") }
        guard SidebarDiagnostics.fullReloads == reloads else { throw CLIError(description: "FP10 full reload") }
        if negativeTransition { throw CLIError(description: "FP10 transition negative control was not observed; no proof accepted") }
        print("FP10 PASS")
    }
}
