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
            do {
                let samples = fixture == .cold ? cold(probeInstructions: true) : skeleton()
                var load = [Double](repeating: 0,count: 3); _ = getloadavg(&load,3)
                let cpu95 = p95(samples.cpu),wall95 = p95(samples.wall)
                print(String(format: "%@ open: 2x; 30 samples, 5 warmups; CPU p95 %.3f ms; wall p95 %.3f ms; load1 %.2f; CPU target lateness %.3f ms (diagnostic; product target <8 ms)",fixture.rawValue,cpu95,wall95,load[0],max(0,cpu95-8)))
                if fixture == .skeleton {
                    return .init(name: "skeleton timing is diagnostic; the full cold workload owns the instruction gate",pass: false,info: true)
                }
                guard samples.instructionError == nil,samples.instructions.count==30 else {
                    return .init(name: samples.instructionError ?? "incomplete main-thread instruction samples",pass: false)
                }
                let instructions = median(samples.instructions),baseline = try InstructionBaseline.current()
                guard let machine = baseline.machine else {
                    return .init(name: "cold open main-thread median \(instructions) instructions; \(baseline.key): no accepted machine/build baseline",pass: false,info: true)
                }
                return .init(name: "cold open main-thread median \(instructions) instructions <= \(machine.limit) (ceil(\(machine.coldOpenInstructions) x1.10)); \(baseline.key)",pass: instructions<=machine.limit)
            } catch { return .init(name: "cold instruction gate: \(error)",pass: false) }
        }
    }
    private static func median(_ values: [UInt64]) -> UInt64 {
        let sorted = values.sorted(); return sorted[14]+(sorted[15]-sorted[14]+1)/2
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
        let sorted = samples.instructions.sorted(),median = median(samples.instructions)
        var load = [Double](repeating: 0,count: 3); _ = getloadavg(&load,3)
        print(String(format: "cold instructions: 2x; 30 samples, 5 warmups; main-thread median %llu; min %llu; max %llu; CPU p95 %.3f ms (product target <8 ms, diagnostic); wall p95 %.3f ms (diagnostic); load1 %.2f",median,sorted.first!,sorted.last!,p95(samples.cpu),p95(samples.wall),load[0]))
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
                        } else if first?.sample == nil { result.instructionError = first?.status }
                        else if last?.sample == nil { result.instructionError = last?.status }
                        else { result.instructionError = "zero/backward thread instruction delta" }
                    }
                }
                controller.dismiss(reason: .action,animated: false); controller.view.removeFromSuperview()
            }
        }
        return result
    }
}
