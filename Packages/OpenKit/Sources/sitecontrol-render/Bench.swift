import AppKit

@MainActor
enum Bench {
    static func run() -> [Flows.Check] {
        var cpu: [Double] = [], wall: [Double] = []
        for index in 0..<35 {
            let stage = Stage()
            if index >= 5 { cpu.append(stage.openCPU); wall.append(stage.openWall) }
        }
        let p95 = cpu.sorted()[Int(ceil(Double(cpu.count) * 0.95)) - 1]
        let wall95 = wall.sorted()[Int(ceil(Double(wall.count) * 0.95)) - 1]
        print(String(format: "Step 1 skeleton open: build + native click + layout + first display; 30 samples, 5 warmups; p95 main thread %.3f ms, wall %.3f ms", p95, wall95))
        return [Flows.Check(name: String(format: "bench skeleton open p95 %.3f ms <= 8 ms main thread", p95), pass: p95 <= 8)]
    }
}
