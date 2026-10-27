import AppKit

@MainActor
enum Bench {
    static func run() -> [Flows.Check] {
        var best = Double.infinity
        // Lead ruling 2026-10-26: at most three complete attempts under shared
        // machine load. The 8 ms main-thread limit and sample counts stay fixed.
        for attempt in 1...3 {
            var load = [Double](repeating: 0,count: 3)
            _ = getloadavg(&load,3)
            var cpu: [Double] = [],wall: [Double] = []
            for index in 0..<35 {
                autoreleasepool {
                    let stage = Stage()
                    if index >= 5 { cpu.append(stage.openCPU); wall.append(stage.openWall) }
                }
            }
            let p95 = cpu.sorted()[Int(ceil(Double(cpu.count)*0.95))-1]
            let wall95 = wall.sorted()[Int(ceil(Double(wall.count)*0.95))-1]
            best = min(best,p95)
            print(String(format: "Step 1 skeleton open attempt %d/3: build + native click + layout + first display; 30 samples, 5 warmups; p95 main thread %.3f ms, wall %.3f ms, load1 %.2f; budget 8 ms",attempt,p95,wall95,load[0]))
            if p95 <= 8 {
                return [Flows.Check(name: String(format: "bench skeleton open p95 %.3f ms <= 8 ms main thread (attempt %d)",p95,attempt),pass: true)]
            }
        }
        return [Flows.Check(name: String(format: "bench skeleton open best p95 %.3f ms <= 8 ms main thread (3 attempts)",best),pass: false)]
    }
}
