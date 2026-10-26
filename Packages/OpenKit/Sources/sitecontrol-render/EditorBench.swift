import AppKit
import OpenSiteControl
import OpenBoosts
import OpenDesign

@MainActor
enum EditorBench {
    @MainActor final class Sample { var value: Double?; var offMain = false; var hue: Double? }
    static func run() -> [Flows.Check] {
        func p95(_ values: [Double]) -> Double { values.sorted()[Int(ceil(Double(values.count)*0.95))-1] }
        let stage = EditorStage(scale: 2), wheel = stage.view.wheel
        var events: [Double] = []
        stage.mouse(.leftMouseDown,point: CGPoint(x: 64,y: 30),in: wheel)
        for i in 0..<510 {
            let a = Double(i)*0.03, start = CACurrentMediaTime()
            stage.mouse(.leftMouseDragged,point: CGPoint(x: 64+sin(a)*40,y: 64-cos(a)*40),in: wheel)
            if i >= 10 { events.append((CACurrentMediaTime()-start)*1000) }
        }
        stage.mouse(.leftMouseUp,point: CGPoint(x: 100,y: 64),in: wheel)
        var frames: [Double] = []
        stage.mouse(.leftMouseDown,point: CGPoint(x: 64,y: 30),in: wheel)
        for i in 0..<110 {
            let a = Double(i)*0.03, start = CACurrentMediaTime()
            stage.mouse(.leftMouseDragged,point: CGPoint(x: 64+sin(a)*40,y: 64-cos(a)*40),in: wheel)
            OffscreenRenderer.settle(stage.panel.contentView!)
            if i >= 10 { frames.append((CACurrentMediaTime()-start)*1000) }
        }
        stage.mouse(.leftMouseUp,point: CGPoint(x: 100,y: 64),in: wheel)
        print(String(format: "Editor full drag frame (native event + display): p95 %.3f ms, max %.3f ms (100 frames; diagnostic, no separate plan budget)",p95(frames),frames.max()!))
        stage.host.previews = []; stage.host.previewTimes = []
        let dragStart = CACurrentMediaTime()
        stage.mouse(.leftMouseDown,point: CGPoint(x: 64,y: 30),in: wheel)
        for i in 0..<120 {
            let a = Double(i)*0.05
            stage.mouse(.leftMouseDragged,point: CGPoint(x: 64+sin(a)*40,y: 64-cos(a)*40),in: wheel)
            let deadline = dragStart+Double(i+1)/120
            while CACurrentMediaTime() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(min(0.001,deadline-CACurrentMediaTime()))) }
        }
        stage.mouse(.leftMouseUp,point: CGPoint(x: 100,y: 64),in: wheel)
        let previewCount = stage.host.previews.count
        let idleCalls = stage.host.refreshes+stage.host.previews.count
        let idleCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        let idleMS = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)-idleCPU)/1e6
        let idleStable = stage.host.refreshes+stage.host.previews.count == idleCalls
        let refreshMS = stage.host.refreshDurations.max() ?? .infinity
        print(String(format: "Editor idle: %.3f ms main-thread CPU in 2 s, no host work=%@; ten-page refresh max %.3f ms",idleMS,idleStable.description,refreshMS))
        var open: [Double] = []
        let boostID = stage.session.boost.id
        let context = stage.session.context
        stage.controller.close(); OffscreenRenderer.settle(stage.backdrop)
        for i in 0..<25 {
            let start = CACurrentMediaTime()
            _ = stage.controller.present(parent: stage.parent,contentRect: CGRect(x: 228,y: 10,width: 762,height: 740),context: context,boostID: boostID)
            if let content = stage.controller.panel?.contentView { OffscreenRenderer.settle(content) }
            let elapsed = (CACurrentMediaTime()-start)*1000
            if i >= 5 { open.append(elapsed) }
            stage.controller.close()
        }
        let sample = Sample(), png = stage.host.snapshots!
        Task.detached(priority: .userInitiated) {
            let start = CACurrentMediaTime(), offMain = pthread_main_np() == 0
            let hue = BoostEditorSession.dominantHue(png), elapsed = (CACurrentMediaTime()-start)*1000
            await MainActor.run { sample.value = elapsed; sample.offMain = offMain; sample.hue = hue }
        }
        let timeout = Date().addingTimeInterval(3)
        while sample.value == nil && Date() < timeout { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        print(String(format: "Editor: wheel event p95 %.3f ms (500 native events); previews %d in 1 s / 120 Hz; simple open p95 %.3f ms; hue sample %.3f ms off-main=%@",p95(events),previewCount,p95(open),sample.value ?? -1,sample.offMain.description))
        return [.init(name: "idle editor has no host work and less than 0.5 percent main-thread CPU",pass: idleStable && idleMS < 10),
                .init(name: "commit refreshes ten real page plans within 100 ms",pass: stage.host.refreshedPlans.count == 10 && refreshMS < 100),
                .init(name: "wheel event to preview queue p95 < 2 ms",pass: p95(events)<2),
                .init(name: "1 s 120 Hz drag coalesces to at most 61 real planner previews",pass: previewCount > 0 && previewCount <= 61),
                .init(name: "simple editor build/layout/first draw p95 < 12 ms",pass: p95(open)<12),
                .init(name: "2216x1394 PNG dominant hue under 15 ms off the main thread",pass: sample.value.map { $0<15 } == true && sample.offMain && sample.hue != nil)]
    }
}
