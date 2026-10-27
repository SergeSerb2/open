import AppKit
import QuartzCore
import OpenDesign
import OpenSiteControl

@MainActor
enum Bench {
    enum Fixture: String,CaseIterable { case skeleton,cold }
    struct Samples {
        var cpu: [Double] = []
        var wall: [Double] = []
        var parts: [[Double]] = []
        var instructions: [UInt64] = []
        var instructionError: String?
    }
    static func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID))/1e6 }
    static func p95(_ values: [Double]) -> Double { values.sorted()[Int(ceil(Double(values.count)*0.95))-1] }
    static func run(only: Fixture? = nil) -> [Flows.Check] {
        var previousQoS = QOS_CLASS_DEFAULT
        var relativePriority: Int32 = 0
        guard pthread_get_qos_class_np(pthread_self(),&previousQoS,&relativePriority) == 0,
              pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0) == 0 else {
            return [.init(name: "interactive UI benchmark priority available",pass: false)]
        }
        defer { _ = pthread_set_qos_class_self_np(previousQoS,relativePriority) }
        return (only.map { [$0] } ?? Fixture.allCases).map { fixture in
            var best = Double.infinity
            // Lead ruling: at most three complete attempts. Every attempt keeps
            // five warmups, thirty samples, and the 8 ms main-thread CPU budget.
            for attempt in 1...3 {
                var load = [Double](repeating: 0,count: 3)
                _ = getloadavg(&load,3)
                let samples = fixture == .cold ? cold() : skeleton()
                let cpu95 = p95(samples.cpu),wall95 = p95(samples.wall)
                best = min(best,cpu95)
                print(String(format: "%@ open attempt %d/3: 2x; 30 samples, 5 warmups; CPU p95 %.3f ms; wall p95 %.3f ms (diagnostic); load1 %.2f; CPU lateness %.3f ms; budget <8 ms",fixture.rawValue,attempt,cpu95,wall95,load[0],max(0,cpu95-8)))
                if !samples.parts.isEmpty {
                    print("CPU phases mean ms (init/attach/present/display): "+(0..<4).map { column in String(format: "%.3f",samples.parts.map { $0[column] }.reduce(0,+)/Double(samples.parts.count)) }.joined(separator: ", "))
                }
                if cpu95<8 { return .init(name: String(format: "%@ open CPU p95 %.3f ms <8 ms (attempt %d)",fixture.rawValue,cpu95,attempt),pass: true) }
            }
            return .init(name: String(format: "%@ open best CPU p95 %.3f ms <8 ms (3 attempts)",fixture.rawValue,best),pass: false)
        }
    }
    private static func skeleton() -> Samples {
        var result = Samples()
        for index in 0..<35 {
            autoreleasepool {
                let stage = Stage(scale: 2)
                if index>=5 { result.cpu.append(stage.openCPU); result.wall.append(stage.openWall) }
            }
        }
        return result
    }
    static func measureThreadInstructions() throws {
        let samples = cold(probeInstructions: true)
        guard samples.instructionError == nil,samples.instructions.count == 30 else {
            throw CLIError(description: samples.instructionError ?? "incomplete main-thread instruction samples")
        }
        let sorted = samples.instructions.sorted(),median = (sorted[14]+sorted[15])/2
        var load = [Double](repeating: 0,count: 3); _ = getloadavg(&load,3)
        print(String(format: "cold instructions: 2x; 30 samples, 5 warmups; main-thread median %llu; min %llu; max %llu; CPU p95 %.3f ms (8 ms gate unchanged); wall p95 %.3f ms (diagnostic); load1 %.2f",median,sorted.first!,sorted.last!,p95(samples.cpu),p95(samples.wall),load[0]))
        print("main-thread instruction samples: "+samples.instructions.map(String.init).joined(separator: ","))
    }
    private static func cold(probeInstructions: Bool = false) -> Samples {
        let stage = Stage(state: "scc-many",scale: 2)
        stage.controller.dismiss(reason: .action,animated: false)
        var result = Samples()
        for index in 0..<35 {
            autoreleasepool {
                OffscreenRenderer.settle(stage.root)
                let first = probeInstructions ? ThreadInstructions.read() : nil
                let start = CACurrentMediaTime(),startCPU = cpu()
                let controller = SiteControlController(source: stage.source,actions: stage.source)
                let afterInit = cpu()
                controller.view.frame = stage.root.bounds; controller.geometry = stage.controller.geometry
                stage.root.addSubview(controller.view)
                let afterAttach = cpu()
                stage.anchorButton.invoke = { [weak controller,weak source = stage.source] in
                    guard let source else { return }; controller?.present(anchor: .urlField,tabID: source.tabID,animated: false)
                }
                stage.click(CGPoint(x: 201,y: 64))
                let afterPresent = cpu()
                controller.view.layoutSubtreeIfNeeded(); stage.window.displayIfNeeded(); CATransaction.flush()
                let elapsedCPU = cpu()-startCPU,elapsed = (CACurrentMediaTime()-start)*1000
                let last = probeInstructions ? ThreadInstructions.read() : nil
                if index>=5 {
                    result.cpu.append(elapsedCPU); result.wall.append(elapsed)
                    result.parts.append([afterInit-startCPU,afterAttach-afterInit,afterPresent-afterAttach,startCPU+elapsedCPU-afterPresent])
                    if probeInstructions {
                        if let before = first?.sample,let after = last?.sample,after.instructions>before.instructions {
                            result.instructions.append(after.instructions-before.instructions)
                        } else { result.instructionError = last?.sample == nil ? last?.status : first?.status ?? "zero/backward thread instruction delta" }
                    }
                }
                controller.dismiss(reason: .action,animated: false); controller.view.removeFromSuperview()
            }
        }
        return result
    }
}
