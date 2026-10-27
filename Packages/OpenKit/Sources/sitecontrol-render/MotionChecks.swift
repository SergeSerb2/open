import AppKit
import OpenDesign

@MainActor
enum MotionChecks {
    static func run() -> [Flows.Check] {
        var checks: [Flows.Check] = []
        for close in [false,true] {
            let stage = Stage()
            let tip = stage.controller.view.visibleArrowTip
            if close { stage.controller.dismiss(reason: .escape,animated: true) }
            else { stage.controller.dismiss(reason: .action,animated: false); stage.controller.present(anchor: .urlField,tabID: stage.source.tabID,animated: true) }
            // Read configured animation metadata before sampling can outlive it.
            let closeDuration = close ? stage.controller.view.panel.layer?.animation(forKey: "close.opacity")?.duration : nil
            let openAnimation = close ? nil : stage.controller.view.panel.layer?.animation(forKey: "open.scale") as? CASpringAnimation
            for _ in 0..<3 {
                OffscreenRenderer.settle(stage.root); RunLoop.main.run(until: Date().addingTimeInterval(0.025))
                let fixed = stage.controller.view.presentationLayers.allSatisfy { layer in
                    guard let p = layer.presentation() else { return false }
                    return hypot(p.position.x-tip.x,p.position.y-tip.y) <= 0.5
                }
                let positions = stage.controller.view.presentationLayers.map { l in l.presentation().map { String(format: "%.2f,%.2f",$0.position.x,$0.position.y) } ?? "missing" }.joined(separator: "; ")
                checks.append(.init(name: "motion \(close ? "close" : "open") keeps visible arrow tip fixed (\(tip.x),\(tip.y); \(positions))",pass: fixed))
            }
            if !close {
                let animation = openAnimation
                let peak = (0...300).map { SiteControlMetrics.openScale+(1-SiteControlMetrics.openScale)*Motion.springProgress(Motion.popoverOpen,at: Double($0)/1000) }.max()!
                checks.append(.init(name: String(format: "open spring peak %.4f, settles by 0.30 s",peak),pass: animation != nil && (1.010...1.020).contains(peak) && animation!.duration <= 0.30 && abs(Motion.springProgress(Motion.popoverOpen,at: 0.30)-1)<0.001))
            } else {
                checks.append(.init(name: "close ends by 0.20 s",pass: closeDuration.map { $0 > 0 && $0 <= 0.20 } ?? false))
            }
        }
        let height = Stage()
        let tip = height.controller.view.visibleArrowTip
        let actionFrames = height.controller.view.panel.controls.prefix(4).map(\.frame)
        for growing in [true,false] {
            height.controller.view.panel.showsReload = growing; height.source.changed(); height.prepareMaterial()
            let duration = growing ? Motion.heightGrow : Motion.heightShrink
            let configuredDuration = height.controller.view.panel.layer?.animation(forKey: "rows.bounds")?.duration
            for _ in 0..<3 {
                OffscreenRenderer.settle(height.root); RunLoop.main.run(until: Date().addingTimeInterval(0.025))
                let panel = height.controller.view.panel
                let fixed = height.controller.view.presentationLayers.allSatisfy { layer in
                    guard let shown = layer.presentation() else { return false }
                    return hypot(shown.position.x-tip.x,shown.position.y-tip.y)<=0.5
                }
                let actions = zip(panel.controls.prefix(4),actionFrames).allSatisfy { button,expected in
                    guard let shown = button.layer?.presentation() else { return false }
                    return abs(shown.frame.minX-expected.minX)<=0.5 && abs(shown.frame.minY-expected.minY)<=0.5
                }
                checks.append(.init(name: "height \(growing ? "grow" : "shrink") keeps arrow tip and action row fixed",pass: fixed && actions))
            }
            checks.append(.init(name: "height \(growing ? "grow" : "shrink") uses configured \(duration)s curve",pass: configuredDuration == duration))
            RunLoop.main.run(until: Date().addingTimeInterval(duration))
        }
        return checks
    }
    static func frames(out: URL) throws {
        try FileManager.default.createDirectory(at: out,withIntermediateDirectories: true)
        for close in [false,true] {
            let stage = Stage()
            if close { stage.controller.dismiss(reason: .escape,animated: true) }
            else { stage.controller.dismiss(reason: .action,animated: false); stage.controller.present(anchor: .urlField,tabID: stage.source.tabID,animated: true) }
            let start = CACurrentMediaTime()
            for t in [0.0,0.04,0.08,0.17,0.30] {
                let end = start+t
                while CACurrentMediaTime() < end { RunLoop.main.run(until: Date().addingTimeInterval(min(0.005,end-CACurrentMediaTime()))) }
                let image = stage.render(scale: 1,presentation: true)
                OffscreenRenderer.writePNG(image,to: out.appendingPathComponent(String(format: "%@-%03.0fms.png",close ? "close" : "open",t*1000)))
            }
        }
        for growing in [true,false] {
            let stage = Stage()
            if !growing { stage.controller.view.panel.showsReload = true; stage.source.changed(); RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }
            stage.controller.view.panel.showsReload = growing; stage.source.changed(); stage.prepareMaterial()
            let start = CACurrentMediaTime()
            for t in [0.0,0.04,0.08,0.17,0.30] {
                let end = start+t
                while CACurrentMediaTime()<end { RunLoop.main.run(until: Date().addingTimeInterval(min(0.005,end-CACurrentMediaTime()))) }
                let image = stage.render(scale: 1,presentation: true)
                OffscreenRenderer.writePNG(image,to: out.appendingPathComponent(String(format: "%@-%03.0fms.png",growing ? "grow" : "shrink",t*1000)))
            }
        }

    }
}
