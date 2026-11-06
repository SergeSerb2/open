import AppKit
import Darwin
import OpenDesign
import OpenModel
import OpenSpaceEditor

/// §17 "Display-space blend" cost: main-thread work per drag tick for one
/// window, with the display-space layers and with #120's precomputed P3 mix.
/// A tick sets a new editor style and rebuilds the field, as a live drag does.
/// Instructions come from the process's retired-instruction counter; the
/// harness does all of this work on the main thread.
@MainActor
enum BlendBench {
    static func run(_ args: [String]) throws {
        guard args.isEmpty || (args.count == 2 && args[0] == "--ticks") else {
            throw CLIError(description: "bench-blend accepts only --ticks")
        }
        guard retiredInstructions() > 0 else { throw CLIError(description: "retired instruction counter unavailable") }
        let ticks = Int(RenderCLI.value(args, "--ticks") ?? "240") ?? 0
        guard (10...10_000).contains(ticks) else { throw CLIError(description: "bench-blend --ticks 10...10000") }
        let size = CGSize(width: 1728, height: 1084)
        print("| Fill | Blend | Instructions p50 | Instructions p95 | Thread CPU p50 ms | Thread CPU p95 ms |\n|---|---|---|---|---|---|")
        var idleReceipts: [String] = []
        for (name, preset) in [("1 color", 7), ("3 colors", 9)] {
            var state = ThemeEditorState()
            state.apply(.selectPreset(index: preset))
            let styles: [SpaceStyle] = (0..<ticks).map { i in
                let angle = Double(i) / Double(ticks) * 2 * .pi
                state.apply(.dragKnob(to: CGPoint(x: 0.6 * cos(angle), y: 0.6 * sin(angle)), relative: false))
                return state.style!
            }
            for display in [false, true] {
                let scene = try RenderCLI.scene(model: RenderCLI.fixtureModel(), args: [], size: size)
                scene.background.composesInDisplaySpace = display
                let window = OffscreenRenderer.host(scene, scale: 2)
                defer { window.contentView = nil; window.close() }
                var instructions: [Double] = [], cpu: [Double] = []
                // Two warm-up passes fill the texture and style caches.
                for pass in 0..<3 {
                    for style in styles {
                        let i0 = retiredInstructions(), t0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                        scene.background.style = SpaceThemeStyle(style: style, system: .dark)
                        scene.background.prepareForSnapshot()
                        CATransaction.flush()
                        let i1 = retiredInstructions(), t1 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                        if pass == 2 { instructions.append(Double(i1 - i0)); cpu.append(Double(t1 - t0) / 1e6) }
                    }
                }
                func percentile(_ values: [Double], _ p: Double) -> Double {
                    let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
                }
                let fields = scene.background.fieldRebuildCount, tiles = ThemeTexture.generationCount
                RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                idleReceipts.append("Idle \(name), \(display ? "display" : "fixed-p3"): field rebuilds +\(scene.background.fieldRebuildCount - fields), tile generations +\(ThemeTexture.generationCount - tiles) over 0.25 s")
                print(String(format: "| %@ | %@ | %.0f | %.0f | %.3f | %.3f |", name, display ? "display-space layers" : "fixed P3 (#120)",
                             percentile(instructions, 0.5), percentile(instructions, 0.95), percentile(cpu, 0.5), percentile(cpu, 0.95)))
            }
        }
        print("\n" + idleReceipts.joined(separator: "\n"))
    }

    private static func retiredInstructions() -> UInt64 {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? info.ri_instructions : 0
    }
}
