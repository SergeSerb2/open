import AppKit
import OpenDesign

/// The same real 2x panel open, layout, first native display and transaction
/// flush as the original CPU gate. Instructions gate work; milliseconds retain
/// the <12 ms product target for a quiet-machine latency check.
@MainActor
enum EditorOpenBench {
    static func run(_ stage: EditorStage,acceptInstructionCost: Bool) -> [Flows.Check] {
        var cpu: [Double] = [], wall: [Double] = [], present: [Double] = [], settle: [Double] = []
        var instructions: [UInt64] = []
        var error: String?
        let boostID = stage.session.boost.id, context = stage.session.context
        stage.controller.close()
        OffscreenRenderer.settle(stage.backdrop)
        let windowCountBefore = NSApp.windows.count
        for index in 0..<25 {
            // AppKit normally drains native windows at the event-loop boundary.
            // Release each closed panel outside the measured span so later
            // flushes do not include prior samples' autoreleased windows.
            autoreleasepool {
                let first = ThreadInstructions.read()
                let wallStart = CACurrentMediaTime(), start = Bench.cpu()
                let opened = stage.controller.present(parent: stage.parent,
                    contentRect: CGRect(x: 228,y: 10,width: 762,height: 740),context: context,boostID: boostID)
                let afterPresent = Bench.cpu()
                let content = stage.controller.panel?.contentView
                if let content { OffscreenRenderer.settle(content) }
                let end = Bench.cpu(), elapsedWall = (CACurrentMediaTime()-wallStart)*1000
                let last = ThreadInstructions.read()
                if !opened || content == nil { error = "editor did not open its native panel" }
                if index >= 5 {
                    cpu.append(end-start); wall.append(elapsedWall)
                    present.append(afterPresent-start); settle.append(end-afterPresent)
                    if let before = first.sample, let after = last.sample,
                       after.instructions > before.instructions, after.cycles > before.cycles {
                        instructions.append(after.instructions-before.instructions)
                    } else { error = first.sample == nil ? first.status : last.sample == nil ? last.status : "zero/backward editor thread counters" }
                }
                stage.controller.close()
            }
        }
        print("Editor open procedure: \(acceptInstructionCost ? "sitecontrol-render check after pooled suites" : "standalone bench, not the cost reference procedure"); 2x; 5 warmups; 20 measured opens; per-open autorelease pool; native window list \(windowCountBefore) -> \(NSApp.windows.count)")
        var loads = [Double](repeating: 0,count: 3)
        _ = getloadavg(&loads,3)
        print(String(format: "Editor open: 2x; 20 samples, 5 warmups; main-thread CPU p95 %.3f ms; wall p95 %.3f ms; present CPU p95 %.3f ms; settle CPU p95 %.3f ms; CPU lateness vs 12 ms %+.3f ms; load1 %.2f (timings diagnostic)",
                     Bench.p95(cpu),Bench.p95(wall),Bench.p95(present),Bench.p95(settle),Bench.p95(cpu)-12,loads[0]))
        let latency = Flows.Check(name: String(format: "simple editor build/layout/first draw main-thread CPU p95 %.3f ms vs 12 ms; lateness %+.3f ms; load1 %.2f (quiet-machine acceptance by lead)",
                                               Bench.p95(cpu),Bench.p95(cpu)-12,loads[0]),pass: false,info: true)
        guard error == nil, instructions.count == 20 else {
            return [latency,.init(name: error ?? "incomplete editor main-thread instruction samples",pass: false)]
        }
        let sorted = instructions.sorted(), median = sorted[9]+(sorted[10]-sorted[9]+1)/2
        print("Editor open main-thread instructions: median \(median); min \(sorted.first!); max \(sorted.last!); samples \(instructions)")
        guard acceptInstructionCost else {
            return [latency,.init(name: "standalone editor median \(median) instructions; cost acceptance and reference recording require sitecontrol-render check",pass: false,info: true)]
        }
        do {
            let baseline = try InstructionBaseline.current()
            guard let accepted = baseline.machine?.simpleEditorOpenInstructions else {
                return [latency,.init(name: "simple editor build/layout/first draw median \(median) instructions; \(baseline.key): no accepted editor baseline",pass: false,info: true)]
            }
            let limit = accepted+(accepted+9)/10
            return [latency,.init(name: "simple editor build/layout/first draw median \(median) instructions <= \(limit) (ceil(\(accepted) x1.10)); \(baseline.key)",pass: median <= limit)]
        } catch { return [latency,.init(name: "editor instruction gate: \(error)",pass: false)] }
    }
}
