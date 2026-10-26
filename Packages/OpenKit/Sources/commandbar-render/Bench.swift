import AppKit
import OpenCommandBar
import OpenDesign
import OpenModel
import OpenSuggest

/// Keystroke → updated rows, on the main thread: the field editor inserts one character,
/// the controller queries the real engine (5,000 tabs, 100k-URL history), applies the
/// first snapshot, and AppKit lays out and draws the rows. Measured per keystroke as wall
/// time (the run loop is polled without sleeping) and as main-thread CPU time.
@MainActor
enum Bench {
    static func threadCPU() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }

    struct Result {
        var wallP50 = 0.0, wallP95 = 0.0, cpuP50 = 0.0, cpuP95 = 0.0, keystrokes = 0
    }

    @discardableResult
    static func run(tabs: Int, history: Int, scale: CGFloat, rounds: Int = 3) -> Result {
        // An app's main thread runs at user-interactive QoS; a command-line tool's does not by default.
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
        print("building \(tabs) tabs and \(history) history URLs…")
        let (model, profile, spaces) = Synthetic.benchModel(tabs: tabs)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("commandbar-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = blocking { await Synthetic.history(at: dir, bulk: history) }
        let engine = SuggestEngine(model: model, history: store, fetcher: nil)
        engine.prewarm()
        let stage = Stage(size: CGSize(width: 1440, height: 900), scale: scale, engine: engine, backdrop: .darkPage)
        let c = stage.controller
        c.favicons = Synthetic.favicons()
        let request = CommandBarRequest(mode: .newTab, profileID: profile.id, spaceID: spaces[0].id, allowsRemoteSuggestions: false)

        // Typical queries, typed one character at a time.
        let queries = ["alpha", "budget 4", "canvas", "delta-1", "editor review", "figma", "garden 12", "harbor", "index",
                       "journal", "kernel", "ledger", "matrix 3", "notion", "orbit", "planner", "quartz", "review", "signal",
                       "tracker", "article 512", "site-42", "toggle sidebar", "new tab", "12*7+3", "localhost:3000", "github.com",
                       "budget alpha", "zz", "q"]
        var wall: [Double] = [], cpu: [Double] = [], later: [Double] = [], drawn: [Int] = []
        var laterSnapshots = 0
        var appliedCPU = 0.0
        c.onSnapshotApplied = { snapshot in
            if snapshot.sequence > 0 { laterSnapshots += 1 } else { appliedCPU = threadCPU() }
        }
        var partInsert: [Double] = [], partApply: [Double] = [], partDisplay: [Double] = []
        for round in 0..<max(2, rounds) {
            for q in queries {
                c.present(request, animated: false)
                stage.settle()
                for ch in q {
                    guard let editor = stage.window.firstResponder as? NSTextView else { break }
                    let target = c.text + String(ch)
                    let draws0 = c.view.debugRowDrawCount
                    let w0 = ContinuousClock.now, c0 = threadCPU()
                    editor.insertText(String(ch), replacementRange: editor.selectedRange())
                    let cInserted = threadCPU()
                    while !(c.appliedQuery == target && c.appliedSequence >= 0) {
                        RunLoop.main.run(mode: .default, before: .distantPast)
                    }
                    let cApplied = appliedCPU
                    stage.root.layoutSubtreeIfNeeded()
                    stage.window.displayIfNeeded()
                    CATransaction.flush()
                    let w1 = ContinuousClock.now, c1 = threadCPU()
                    if round > 0 { // round 0 warms caches (fonts, symbols, the tab index)
                        wall.append(ms(w1 - w0)); cpu.append(c1 - c0); drawn.append(c.view.debugRowDrawCount - draws0)
                        partInsert.append(cInserted - c0); partApply.append(cApplied - cInserted); partDisplay.append(c1 - cApplied)
                    }
                    // Later snapshots (history) merge off the keystroke path; time their main-thread cost too.
                    let l0 = threadCPU()
                    stage.settle()
                    if round > 0 { later.append(threadCPU() - l0) }
                }
                c.dismiss(reason: .programmatic, animated: false)
            }
        }
        wall.sort(); cpu.sort(); later.sort()
        func pct(_ a: [Double], _ p: Double) -> Double { a.isEmpty ? 0 : a[min(a.count - 1, Int(Double(a.count) * p))] }
        var load = [0.0, 0, 0]
        getloadavg(&load, 3)
        print(String(format: "load average %.1f %.1f %.1f on %d cores, scale %.0fx, %d keystrokes measured",
                     load[0], load[1], load[2], ProcessInfo.processInfo.activeProcessorCount, scale, wall.count))
        print(String(format: "keystroke → rows drawn, wall:     p50 %.2f ms  p95 %.2f ms  max %.2f ms", pct(wall, 0.5), pct(wall, 0.95), wall.last ?? 0))
        print(String(format: "keystroke → rows drawn, main CPU: p50 %.2f ms  p95 %.2f ms  max %.2f ms", pct(cpu, 0.5), pct(cpu, 0.95), cpu.last ?? 0))
        print(String(format: "rows redrawn per keystroke: mean %.1f", Double(drawn.reduce(0, +)) / Double(max(1, drawn.count))))
        partInsert.sort(); partApply.sort(); partDisplay.sort()
        print(String(format: "  CPU parts p50/p95: text change + engine query %.2f/%.2f, snapshot apply %.2f/%.2f, layout + draw + commit %.2f/%.2f ms",
                     pct(partInsert, 0.5), pct(partInsert, 0.95), pct(partApply, 0.5), pct(partApply, 0.95), pct(partDisplay, 0.5), pct(partDisplay, 0.95)))
        print(String(format: "later snapshots (history merge, incl. settle polling), main CPU: p50 %.2f ms  p95 %.2f ms; %d merged",
                     pct(later, 0.5), pct(later, 0.95), laterSnapshots))
        print(String(format: "budget 8 ms: wall p95 %@, main-thread CPU p95 %@", pct(wall, 0.95) < 8 ? "within" : "over", pct(cpu, 0.95) < 8 ? "within" : "over"))
        return Result(wallP50: pct(wall, 0.5), wallP95: pct(wall, 0.95), cpuP50: pct(cpu, 0.5), cpuP95: pct(cpu, 0.95), keystrokes: wall.count)
    }

    static func ms(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
}
