import AppKit
import QuartzCore
import OpenDesign
import OpenSiteControl

@MainActor
enum Bench {
    static func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }
    static func run() -> [Flows.Check] {
        let stage = Stage(state: "scc-many", scale: 2)
        stage.controller.dismiss(reason: .action, animated: false)
        var wall: [Double] = [], cpuSamples: [Double] = []
        var parts: [[Double]] = []
        for index in 0..<35 {
            autoreleasepool {
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
        return [Flows.Check(name: "panel build/layout/first draw main-thread CPU p95 < 8 ms", pass: p95(cpuSamples) < 8)]
    }
}
