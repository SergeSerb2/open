import AppKit
import QuartzCore
import OpenDesign
import OpenSiteControl

@MainActor
enum Bench {
    static func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }
    static func run() -> [Flows.Check] {
        // This CLI has no application event loop. Match the priority of the
        // browser's interactive UI thread, then restore the caller's priority.
        var previousQoS = QOS_CLASS_DEFAULT
        var relativePriority: Int32 = 0
        guard pthread_get_qos_class_np(pthread_self(), &previousQoS, &relativePriority) == 0 else {
            return [Flows.Check(name: "benchmark caller priority available", pass: false)]
        }
        guard pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) == 0 else {
            return [Flows.Check(name: "interactive UI benchmark priority available", pass: false)]
        }
        defer { _ = pthread_set_qos_class_self_np(previousQoS, relativePriority) }
        let stage = Stage(state: "scc-many", scale: 2)
        stage.controller.dismiss(reason: .action, animated: false)
        var wall: [Double] = [], cpuSamples: [Double] = []
        var parts: [[Double]] = []
        for index in 0..<35 {
            autoreleasepool {
            // Finish the prior fixture's close and removal before timing the
            // next open. The existing page is already painted in the browser.
            OffscreenRenderer.settle(stage.root)
            // Each sample builds a fresh controller and view tree. The window and
            // in-memory source already exist when a user clicks the anchor.
            let start = CACurrentMediaTime(), startCPU = cpu()
            let controller = SiteControlController(source: stage.source, actions: stage.source)
            let afterInit = cpu()
            controller.view.frame = stage.root.bounds
            controller.geometry = stage.controller.geometry
            stage.root.addSubview(controller.view)
            let afterAttach = cpu()
            stage.anchorButton.invoke = { [weak controller, weak source = stage.source] in
                guard let source else { return }
                controller?.present(anchor: .urlField, tabID: source.tabID, animated: false)
            }
            stage.click(CGPoint(x: 201, y: 64))
            let afterPresent = cpu()
            controller.view.layoutSubtreeIfNeeded()
            stage.window.displayIfNeeded(); CATransaction.flush()
            let elapsedCPU = cpu() - startCPU, elapsed = (CACurrentMediaTime() - start) * 1000
            if index >= 5 { wall.append(elapsed); cpuSamples.append(elapsedCPU); parts.append([afterInit - startCPU, afterAttach - afterInit, afterPresent - afterAttach, startCPU + elapsedCPU - afterPresent]) }
            controller.dismiss(reason: .action, animated: false)
            controller.view.removeFromSuperview()
            }
        }
        func p95(_ values: [Double]) -> Double { values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1] }
        print(String(format: "Panel first draw: main-thread CPU p95 %.3f ms; wall p95 %.3f ms; 20 Boosts, 12 tiles, extensions unavailable (section hidden), 2x", p95(cpuSamples), p95(wall)))
        print("CPU samples ms: " + cpuSamples.map { String(format: "%.3f", $0) }.joined(separator: ", "))
        print("Wall samples ms: " + wall.map { String(format: "%.3f", $0) }.joined(separator: ", "))
        print("CPU parts mean (init/attach/present/display): " + (0..<4).map { column in String(format: "%.3f", parts.map { $0[column] }.reduce(0, +) / Double(parts.count)) }.joined(separator: ", "))
        return [Flows.Check(name: "panel build/layout/first draw main-thread CPU p95 < 8 ms", pass: p95(cpuSamples) < 8),
                Flows.Check(name: "native click to first draw wall p95 < 8 ms", pass: p95(wall) < 8)]
    }
}
