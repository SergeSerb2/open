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
        for attempt in 1...attempts {
            print(String(format: "FP10 attempt %d/%d load1 start=%.2f", attempt, attempts, Checks.loadAverage1()))
            do { try runAttempt(args, folders: folders); return }
            catch {
                print("FP10 attempt \(attempt) FAIL: \(error)")
                if attempt == attempts { throw error }
            }
        }
    }

    private static func runAttempt(_ args: [String], folders: Int) throws {
        let negativeProof = args.contains("--negative-proof")
        let negativeTransition = args.contains("--negative-transition-proof")
        let fast = negativeProof || negativeTransition
        guard !(negativeProof && negativeTransition) else { throw CLIError(description: "FP10 controls must run separately") }
        print("FP10 limits: transition main-thread wall p95 <= 2.00 ms; native row layouts/frame peek <= baseline; scroll p95 <= 8.33 ms AND <= baseline p95 * 1.10 + 0.05 ms")
        if negativeTransition { print("FP10 negative control: real 3 ms busy wait inside transition reconciliation") }
        let rows = RenderCLI.value(args, "--rows").flatMap(Int.init) ?? 1000
        let scale = CGFloat(Double(RenderCLI.value(args, "--scale") ?? "2") ?? 2)
        guard (1...1000).contains(folders), rows <= 100_000, rows >= folders * 2 else { throw CLIError(description: "FP10 invalid folder/row counts") }
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
            return Fixture(model: model, folder: first, scene: scene, host: host, delegate: delegate)
        }
        let baseline = fixture(peek: false), peek = fixture(peek: true)
        defer {
            SidebarDiagnostics.measuresFolderTransitions = false
            SidebarDiagnostics.folderBenchFullRowWindowID = nil
            SidebarDiagnostics.folderBenchBusyWindowID = nil
            for f in [baseline, peek] { f.host.contentView = nil; f.host.close() }
        }
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
        let visitedBefore = SidebarDiagnostics.folderSyncItemsVisited
        let configuredBefore = SidebarDiagnostics.folderStateRowsConfigured
        let faviconsBefore = SidebarDiagnostics.folderFaviconDraws, titlesBefore = SidebarDiagnostics.folderTitleDraws
        let layoutsBefore = SidebarDiagnostics.folderRowLayouts + SidebarDiagnostics.tabRowLayouts
        for _ in 0..<transitionCount {
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
            for (name, total) in SidebarDiagnostics.folderReconcilePhases {
                phases[name, default: []].append(total - (phaseBefore[name] ?? 0))
            }
        }
        for name in phases.keys.sorted() { receipt("phase-" + name, phases[name]!) }
        print("FP10 transition visited items=\((SidebarDiagnostics.folderSyncItemsVisited - visitedBefore) / transitionCount) configured rows=\((SidebarDiagnostics.folderStateRowsConfigured - configuredBefore) / transitionCount) cell layouts=\((SidebarDiagnostics.folderRowLayouts + SidebarDiagnostics.tabRowLayouts - layoutsBefore) / transitionCount) per transition")
        print("FP10 draws/transition favicons=\(Double(SidebarDiagnostics.folderFaviconDraws - faviconsBefore) / Double(transitionCount)) titles=\(Double(SidebarDiagnostics.folderTitleDraws - titlesBefore) / Double(transitionCount))")
        receipt("transition-main-thread", transitions)
        receipt("transition-thread-cpu-diagnostic", cpuSamples)
        receipt("transition-input", inputs); receipt("transition-reconcile-and-display", reconciles); receipt("transition-final-layout", layouts)
        print("FP10 displayedNodes=\(rows) folders=\(folders) peekModelNodes=\(peek.model.index.count) nativeRows=\(nativeScrollRows) scale=\(scale); excludes fixture construction, queued wait and animation wall time")
        let relativeLimit = p95(baseScroll) * 1.10 + 0.00005
        print(String(format: "FP10 paired scroll p95 limit=%.3f ms", relativeLimit * 1000))
        guard p95(transitions) <= 0.002 else { throw CLIError(description: "FP10 transition p95 exceeds 2.00 ms") }
        guard p95(peekScroll) <= 0.00833 else { throw CLIError(description: "FP10 scroll exceeds 8.33 ms") }
        guard p95(peekScroll) <= relativeLimit else { throw CLIError(description: "FP10 scroll p95 exceeds matched baseline * 1.10 + 0.05 ms") }
        guard SidebarDiagnostics.fullReloads == reloads else { throw CLIError(description: "FP10 full reload") }
        if negativeTransition { throw CLIError(description: "FP10 transition negative control was not observed; no proof accepted") }
        print("FP10 PASS")
    }
}
