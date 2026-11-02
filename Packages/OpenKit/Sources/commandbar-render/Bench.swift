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
        /// `--completion`: the same keystrokes with inline completion off, and panel layout passes.
        var offCPUP95 = 0.0, completedKeystrokes = 0, maxLayoutPasses = 0, meanLayoutPasses = 0.0, meanLayoutPassesOff = 0.0
        /// What completion adds per keystroke (plan §5.4: p95 with completion − p95 without), from main-thread
        /// cycle counts over the keystroke's own work (no polling), converted at the off run's measured cycles
        /// per millisecond. Cycles only count while the thread runs, so machine load barely moves them.
        /// nil when the counter is unavailable.
        var addedP95Milliseconds: Double?, pairedMedianMilliseconds: Double?, counterStatus = ""
    }

    /// `completionAB`: every query is typed twice per round, inline completion off then on (order
    /// alternating by round), against a history whose hosts complete the queries. The result's CPU
    /// numbers are the completion-on run; `offCPUP95` is the same keystrokes with completion off.
    @discardableResult
    static func run(tabs: Int, history: Int, scale: CGFloat, rounds: Int = 3, completionAB: Bool = false) -> Result {
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
        if completionAB {
            // A typed host page that each one-word query is a prefix of, so most keystrokes complete.
            blocking {
                for q in queries where q.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) {
                    guard let url = URL(string: "https://\(q)zone.example.com/") else { continue }
                    await store.recordVisit(url: url, title: "\(q) zone", time: Date(), typed: true)
                }
            }
        }
        var cpuOff: [Double] = [], layouts: [Int] = [], layoutsOff: [Int] = []
        var cyclesOn: [Double] = [], cyclesOff: [Double] = []
        var partsOn: [[Double]] = [[], [], []], partsOff: [[Double]] = [[], [], []]
        var counterStatus = ThreadInstructions.read().status
        var completed = 0
        var wall: [Double] = [], cpu: [Double] = [], later: [Double] = [], drawn: [Int] = []
        var laterSnapshots = 0
        var appliedCPU = 0.0
        // Cycle stamps around snapshot 0's apply: the bench's polling spins stay out of the count.
        var applyStart: UInt64?, applyEnd: UInt64?, applyStartCPU = 0.0
        var segmentCPUOff: [Double] = []
        c.onSnapshotWillApply = { snapshot in
            if snapshot.sequence == 0 { applyStartCPU = threadCPU(); applyStart = ThreadInstructions.read().sample?.cycles }
        }
        c.onSnapshotApplied = { snapshot in
            if snapshot.sequence > 0 { laterSnapshots += 1 } else { appliedCPU = threadCPU(); applyEnd = ThreadInstructions.read().sample?.cycles }
        }
        var partInsert: [Double] = [], partApply: [Double] = [], partDisplay: [Double] = []
        for round in 0..<max(2, rounds) {
            for q in queries {
              for pass in completionAB ? [round % 2 == 0, round % 2 != 0] : [true] {
                c.allowsInlineCompletion = pass
                let measured = !completionAB || pass
                c.present(request)
                stage.settle()
                for ch in q {
                    guard let editor = stage.window.firstResponder as? NSTextView else { break }
                    let target = c.text + String(ch)
                    let draws0 = c.view.debugRowDrawCount
                    let layouts0 = c.view.debugPanelLayoutCount
                    applyStart = nil; applyEnd = nil
                    let i0 = ThreadInstructions.read().sample
                    let w0 = ContinuousClock.now, c0 = threadCPU()
                    editor.insertText(String(ch), replacementRange: editor.selectedRange())
                    let cInserted = threadCPU()
                    let iInserted = ThreadInstructions.read().sample
                    while !(c.appliedQuery == target && c.appliedSequence >= 0) {
                        RunLoop.main.run(mode: .default, before: .distantPast)
                    }
                    let cApplied = appliedCPU
                    let cDisplay = threadCPU()
                    let iDisplay = ThreadInstructions.read().sample
                    stage.root.layoutSubtreeIfNeeded()
                    stage.window.displayIfNeeded()
                    CATransaction.flush()
                    let w1 = ContinuousClock.now, c1 = threadCPU()
                    let i1 = ThreadInstructions.read().sample
                    // Key handling + snapshot 0's apply + layout/draw/commit, without the polling between them.
                    var cycles: Double?
                    if let a = i0?.cycles, let b = iInserted?.cycles, let s = applyStart, let e = applyEnd,
                       let d = iDisplay?.cycles, let f = i1?.cycles {
                        cycles = Double(b &- a) + Double(e &- s) + Double(f &- d)
                        if round > 0, completionAB {
                            let parts = [Double(b &- a), Double(e &- s), Double(f &- d)]
                            for k in 0..<3 { if measured { partsOn[k].append(parts[k]) } else { partsOff[k].append(parts[k]) } }
                        }
                    }
                    if cycles == nil { counterStatus = "unavailable" }
                    if round > 0, !measured {
                        cpuOff.append(c1 - c0); layoutsOff.append(c.view.debugPanelLayoutCount - layouts0)
                        if let cycles { cyclesOff.append(cycles); segmentCPUOff.append((cInserted - c0) + (cApplied - applyStartCPU) + (c1 - cDisplay)) }
                    }
                    if round > 0, measured, completionAB, let cycles { cyclesOn.append(cycles) }
                    if round > 0, measured { // round 0 warms caches (fonts, symbols, the tab index)
                        wall.append(ms(w1 - w0)); cpu.append(c1 - c0); drawn.append(c.view.debugRowDrawCount - draws0)
                        partInsert.append(cInserted - c0); partApply.append(cApplied - cInserted); partDisplay.append(c1 - cApplied)
                        layouts.append(c.view.debugPanelLayoutCount - layouts0)
                        if c.inlineCompletion != nil { completed += 1 }
                    }
                    // Later snapshots (history) merge off the keystroke path; time their main-thread cost too.
                    let l0 = threadCPU()
                    stage.settle()
                    if round > 0 { later.append(threadCPU() - l0) }
                }
                c.dismiss(reason: .programmatic)
              }
            }
        }
        c.allowsInlineCompletion = true
        // Plan §5.4: the completion run's p95 minus the plain run's p95 (same keystrokes, interleaved).
        var addedP95: Double?, pairedMedian: Double?
        func med(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[a.count / 2] }
        func p95(_ a: [Double]) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * 0.95))] }
        if completionAB, cyclesOn.count == cyclesOff.count, !cyclesOn.isEmpty, counterStatus == "available" {
            let msPerCycle = segmentCPUOff.reduce(0, +) / cyclesOff.reduce(0, +)
            addedP95 = (p95(cyclesOn) - p95(cyclesOff)) * msPerCycle
            pairedMedian = med(zip(cyclesOn, cyclesOff).map { $0 - $1 }) * msPerCycle
            print(String(format: "main-thread cycles per keystroke (key handling + snapshot 0 apply + draw): on p50 %.0f p95 %.0f, off p50 %.0f p95 %.0f; %.0f cycles per µs",
                         med(cyclesOn), p95(cyclesOn), med(cyclesOff), p95(cyclesOff), 1 / msPerCycle / 1000))
            print(String(format: "  parts p50 on/off: key %.0f/%.0f, apply %.0f/%.0f, draw %.0f/%.0f; p95 on/off: key %.0f/%.0f, apply %.0f/%.0f, draw %.0f/%.0f",
                         med(partsOn[0]), med(partsOff[0]), med(partsOn[1]), med(partsOff[1]), med(partsOn[2]), med(partsOff[2]),
                         p95(partsOn[0]), p95(partsOff[0]), p95(partsOn[1]), p95(partsOff[1]), p95(partsOn[2]), p95(partsOff[2])))
        }
        wall.sort(); cpu.sort(); later.sort(); cpuOff.sort()
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
        let meanLayouts = Double(layouts.reduce(0, +)) / Double(max(1, layouts.count))
        let meanLayoutsOff = Double(layoutsOff.reduce(0, +)) / Double(max(1, layoutsOff.count))
        if completionAB {
            print(String(format: "inline completion A/B (same keystrokes, interleaved): main CPU p95 on %.3f ms, off %.3f ms, difference %+.3f ms; %d of %d keystrokes showed a completion",
                         pct(cpu, 0.95), pct(cpuOff, 0.95), pct(cpu, 0.95) - pct(cpuOff, 0.95), completed, cpu.count))
            print(String(format: "panel layout passes per keystroke: completion on mean %.2f max %d, off mean %.2f max %d", meanLayouts, layouts.max() ?? 0, meanLayoutsOff, layoutsOff.max() ?? 0))
            if let addedP95, let pairedMedian {
                print(String(format: "inline completion adds (main-thread cycles at the off run's rate): p95 %+.3f ms over the plain p95 (budget +0.3); paired median %+.3f ms", addedP95, pairedMedian))
            } else {
                print("inline completion's added work: cycle counter \(counterStatus)")
            }
        }
        return Result(wallP50: pct(wall, 0.5), wallP95: pct(wall, 0.95), cpuP50: pct(cpu, 0.5), cpuP95: pct(cpu, 0.95), keystrokes: wall.count,
                      offCPUP95: pct(cpuOff, 0.95), completedKeystrokes: completed, maxLayoutPasses: layouts.max() ?? 0, meanLayoutPasses: meanLayouts, meanLayoutPassesOff: meanLayoutsOff,
                      addedP95Milliseconds: addedP95, pairedMedianMilliseconds: pairedMedian, counterStatus: counterStatus)
    }

    static func ms(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
}
