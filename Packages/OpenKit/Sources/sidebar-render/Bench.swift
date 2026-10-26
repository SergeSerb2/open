import AppKit
import OpenDesign
import OpenModel
import OpenSidebar

/// Performance bench on a synthetic 1,000-row Space: build and first frame,
/// scrolling, model edits through `TreeChange`, and a Space switch.
@MainActor
enum Bench {
    static func ms(_ seconds: Double) -> String { String(format: "%.2f ms", seconds * 1000) }

    static func time(_ body: () -> Void) -> Double {
        let t = CACurrentMediaTime()
        body()
        return CACurrentMediaTime() - t
    }

    static func run(_ args: [String]) throws {
        let rows = RenderCLI.value(args, "--rows").flatMap(Int.init) ?? 1000
        let scale = CGFloat(Double(RenderCLI.value(args, "--scale") ?? "2") ?? 2)
        let model = Synthetic.model(bulkRows: rows)
        model.rebuildIndex()
        if RenderCLI.value(args, "--row-media") == "mixed" {
            for (i, tab) in model.index.values.compactMap(\.tab).sorted(by: { $0.url.absoluteString < $1.url.absoluteString }).enumerated() {
                tab.live.isAudible = i % 3 == 0
                tab.isMuted = i % 3 == 1
                tab.live.isCapturing = i % 3 == 2
            }
            print("row media fixture: audible, muted and capturing in thirds")
        }
        guard let window = model.windows.first else { return }
        let context = SidebarContext(model: model, windowID: window.id)
        context.systemAppearance = .dark
        let delegate = RecordingDelegate()
        var options = RenderScene.Options()
        options.size = CGSize(width: 1280, height: 900)
        let reloadsBefore = SidebarDiagnostics.fullReloads

        var scene: RenderScene!
        var host: ScaledWindow!
        let build = time {
            scene = RenderScene(context: context, options: options, delegate: delegate)
            host = OffscreenRenderer.host(scene, scale: scale)
        }
        let sidebar = scene.sidebar
        print("Space rows (outline rows incl. spacer/New Tab): \(sidebar.visibleRowCount), model nodes: \(model.index.count)")
        print("build + first layout + first display (\(Int(scale))x): \(ms(build))")

        let renderer = OffscreenRenderer()
        var image: CGImage?
        let render = time { image = renderer.snapshot(scene, scale: scale) }
        print("offscreen GPU render of the window (\(image?.width ?? 0)×\(image?.height ?? 0)): \(ms(render))")

        // Scrolling: move the clip view by 120 pt per step (about one wheel tick at 120 Hz).
        guard let outline = sidebar.focusedOutline, let clip = outline.enclosingScrollView?.contentView else { return }
        var steps: [Double] = []
        let maxY = max(0, outline.frame.height - clip.bounds.height)
        var y: CGFloat = 0
        let loops = Int(ProcessInfo.processInfo.environment["BENCH_SCROLL_LOOPS"] ?? "1") ?? 1
        for _ in 1..<max(loops, 1) {
            var yy: CGFloat = 0
            while yy < maxY { yy += 120; clip.scroll(to: NSPoint(x: 0, y: yy)); scene.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
            clip.scroll(to: .zero)
        }
        while y < maxY {
            y = min(maxY, y + 120)
            steps.append(time {
                clip.scroll(to: NSPoint(x: 0, y: y))
                outline.enclosingScrollView?.reflectScrolledClipView(clip)
                scene.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                CATransaction.flush()
            })
        }
        steps.sort()
        if !steps.isEmpty {
            print(String(format: "scroll %d steps of 120 pt: median %@, p95 %@, max %@ (120 Hz budget 8.33 ms)", steps.count,
                         ms(steps[steps.count / 2]), ms(steps[Int(Double(steps.count) * 0.95)]), ms(steps.last!)))
        }
        clip.scroll(to: .zero)

        if args.contains("--selection") {
            let first = context.focusedSpace!.pinned[0].id
            let frame = sidebar.rowFrame(nodeID: first)!
            let point = sidebar.convert(NSPoint(x: 100, y: frame.midY), to: nil)
            host.makeFirstResponder(outline)
            scene.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let layouts = SidebarDiagnostics.tabRowLayouts
            let reloads = SidebarDiagnostics.fullReloads
            var toggles: [Double] = []
            for _ in 0..<200 {
                let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: .command,
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                toggles.append(time {
                    outline.mouseDown(with: event)
                    scene.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                })
            }
            let p95 = toggles.sorted()[190]
            print("MS14 selection toggle ×200 (real Cmd-click + display): p95 \(ms(p95)), row layouts \(SidebarDiagnostics.tabRowLayouts - layouts)")
            guard p95 <= 0.001, SidebarDiagnostics.tabRowLayouts - layouts <= 2,
                  SidebarDiagnostics.fullReloads == reloads else { throw CLIError(description: "selection performance budget exceeded") }
            context.selection.clear()
        }

        // Model edits: each command emits a TreeChange that the page applies as a diff.
        guard let space = context.focusedSpace else { return }
        var rng = SystemRandomNumberGenerator()
        var moveTimes: [Double] = []
        let moveCount = Int(ProcessInfo.processInfo.environment["BENCH_MOVES"] ?? "200") ?? 200
        for _ in 0..<moveCount {
            let nodes = space.pinned + space.today
            guard let node = nodes.randomElement(using: &rng) else { break }
            let toToday = Bool.random(using: &rng)
            let dest: NodeParent = toToday ? .spaceToday(space.id) : .spacePinned(space.id)
            let count = toToday ? space.today.count : space.pinned.count
            let at = Int.random(in: 0...max(0, count - 1), using: &rng)
            moveTimes.append(time {
                model.moveNode(id: node.id, to: dest, at: at)
                scene.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            })
        }
        var insertTimes: [Double] = [], closeTimes: [Double] = []
        for i in 0..<100 {
            var tab: Tab!
            insertTimes.append(time {
                tab = model.newTab(in: space.id, url: URL(string: "https://bench\(i).example.com")!, title: "Bench \(i)")
                scene.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            })
            closeTimes.append(time {
                model.closeTab(id: tab.id)
                scene.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            })
        }
        func stats(_ a: [Double]) -> String {
            let s = a.sorted()
            return "median \(ms(s[s.count / 2])), p95 \(ms(s[Int(Double(s.count) * 0.95)])), max \(ms(s.last!))"
        }
        print("moveNode ×200 (model + diff + layout + display): \(stats(moveTimes))")
        print("newTab ×100: \(stats(insertTimes))")
        print("closeTab ×100: \(stats(closeTimes))")
        let expected = Checks.expectedRows(context: context)
        print("rows match the model after edits: \(sidebar.displayedRows == expected ? "yes" : "NO") (\(expected.count) rows)")
        print("full reloads: \(SidebarDiagnostics.fullReloads - reloadsBefore) (one per page built; edits add none)")

        // Space switch: model change → pager slide setup and theme cross-fade start.
        let target = model.spaces[1].id
        let switchTime = time {
            model.focusSpace(windowID: window.id, spaceID: target)
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            scene.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        }
        print("Space switch to an unvisited Space (observation hop + page build + layout + display): \(ms(switchTime))")
        OffscreenRenderer.settle(scene, runLoop: 0.05)
        let back = time {
            model.focusSpace(windowID: window.id, spaceID: model.spaces[0].id)
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            scene.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        }
        print("Space switch back to the 1,000-row Space (page kept): \(ms(back))")
        // A second sidebar for the same model: warm process caches (fonts, symbols, emoji).
        var scene2: RenderScene!
        var host2: ScaledWindow!
        let warm = time {
            scene2 = RenderScene(context: SidebarContext(model: model, windowID: window.id), options: options, delegate: delegate)
            host2 = OffscreenRenderer.host(scene2, scale: scale)
        }
        print("second sidebar, warm caches: build + first layout + first display: \(ms(warm))")
        host2.contentView = nil
        host2.close()
        host.contentView = nil
        host.close()
    }
}
