#if OPEN_AUTOMATION
import AppKit
import Darwin
import OpenLibrary

extension AutomationController {
  /// Native submission and provider completion through the real Library path.
  /// Reports both clocks; neither value claims physical display scan-out.
  func libraryPerformance(_ args:[String:Any]) async throws -> [String:Any] {
    let operation = args["operation"] as? String ?? "state"
    let adapter = app.settingsPresenter
    if operation == "cpu" {
      var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
      return ["cpuSeconds":Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1_000_000,"counters":adapter.activeLibrarySession?.panel?.performanceCounters ?? [:]]
    }
    let countersBefore = adapter.activeLibrarySession?.panel?.performanceCounters ?? [:]
    var started = ProcessInfo.processInfo.systemUptime
    if operation == "scroll-series" {
      guard let panel = adapter.activeLibrarySession?.panel,panel.isPresented else { throw Failure(message:"Library not open") }
      let probe = LibraryScrollProbe()
      let samples = await probe.run(panel)
      return ["frames":samples.map(\.json),"counters":panel.performanceCounters]
    }
    switch operation {
    case "open":
      let raw = args["section"] as? String ?? "downloads"
      guard let section = LibraryPanelSection(rawValue:raw), section != .easels else { throw Failure(message:"unknown benchmark section") }
      adapter.showLibrary(section:section.modelSection)
    case "section":
      guard let raw=args["section"] as? String, let section=LibraryPanelSection(rawValue:raw),
        let panel=adapter.activeLibrarySession?.panel, panel.isPresented, panel.sections.contains(section) else { throw Failure(message:"Library not open") }
      panel.select(section)
    case "search":
      guard let text=args["text"] as? String, text.utf8.count<=256,
        adapter.activeLibrarySession?.panel?.isPresented == true,
        let target=adapter.activeLibrarySession?.controller?.window else { throw Failure(message:"invalid Library search") }
      _ = try await sendKey(["key":"f","modifiers":["cmd"],"route":"app"],try? window)
      // Focus is setup. Time the actual in-app key dispatch, without sendKey's
      // fixed post-delivery wait, which is for asynchronous CEF page callbacks.
      guard let searchPanel = adapter.activeLibrarySession?.panel else { throw Failure(message:"Library not created") }
      started = searchPanel.beginSearchMeasurement()
      for character in text {
        for type in [NSEvent.EventType.keyDown,.keyUp] {
          guard let event=NSEvent.keyEvent(with:type,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
            windowNumber:target.windowNumber,context:nil,characters:String(character),charactersIgnoringModifiers:String(character),isARepeat:false,keyCode:0)
          else { throw Failure(message:"could not create Library search event") }
          NSApp.sendEvent(event)
        }
      }
    case "scroll":
      guard let panel=adapter.activeLibrarySession?.panel, panel.isPresented,
        let row=args["row"] as? Int, (0...100_000).contains(row) else { throw Failure(message:"invalid Library scroll") }
      let visible=panel.scrollToRow(row)
      return ["milliseconds":(ProcessInfo.processInfo.systemUptime-started)*1000,"visibleRows":visible,"reuse":panel.listReuseState,"counters":panel.performanceCounters,"counterDelta":panel.performanceCounters.mapValues { $0 }.reduce(into:[String:Double]()) { $0[$1.key] = $1.value-(countersBefore[$1.key] ?? 0) }]
    default: throw Failure(message:"unknown Library measurement")
    }
    guard let panel=adapter.activeLibrarySession?.panel else { throw Failure(message:"Library not created") }
    let actionMilliseconds = (ProcessInfo.processInfo.systemUptime-started)*1000
    let pending = panel.hasPendingFirstScreen
    panel.submitNativeFrame()
    let first=(panel.nativeCommittedAt-started)*1000
    let firstPhases = panel.performanceCounters.filter { $0.key.hasPrefix("last.") }
    // An unchanged retained host is complete at its first submission. Do not
    // add an unrelated actor hop and a second compositor flush to that clock.
    if pending { await panel.finishPendingContent(); panel.submitNativeFrame() }
    let full=(panel.nativeCommittedAt-started)*1000
    if operation == "search" { panel.markSearchCommit() }
    return ["firstSubmittedMilliseconds":first,"contentSubmittedMilliseconds":full,
      "providerRows":panel.filteredRowCount,
      "actionMilliseconds":actionMilliseconds,"firstSubmissionPhases":firstPhases,
      "searchTimestamps":operation == "search" ? panel.searchTimestamps : [:],
      "panelGeneration":adapter.activeLibrarySession?.panelGeneration ?? 0,
      "visibleRows":panel.listReuseState["rows"] ?? 0,"counters":panel.performanceCounters,
      "counterDelta":panel.performanceCounters.reduce(into:[String:Double]()) { $0[$1.key] = $1.value-(countersBefore[$1.key] ?? 0) }]
  }
}
#endif

#if OPEN_AUTOMATION
/// One in-app scroll step per native display callback. The socket does not
/// pace frames, and this display link is invalidated before the reply.
private struct LibraryScrollFrame: Sendable {
  let startTicks: UInt64
  let endTicks: UInt64
  let milliseconds: Double
  let visibleRows: Int
  let intervalMilliseconds: Double
  let counters: [String:Double]
  let counterDelta: [String:Double]
  let heartbeat: [String:Double]
  var json: [String:Any] { ["startTicks":startTicks,"endTicks":endTicks,"milliseconds":milliseconds,"visibleRows":visibleRows,"intervalMilliseconds":intervalMilliseconds,"counters":counters,"counterDelta":counterDelta,"heartbeat":heartbeat] }
}
@MainActor
private final class LibraryScrollProbe: NSObject {
  weak var panel: LibraryPanelView?
  var link: CADisplayLink?
  var completion: CheckedContinuation<[LibraryScrollFrame],Never>?
  var rows: [LibraryScrollFrame] = []
  var previousTimestamp = 0.0
  let heartbeat = LibraryScrollHeartbeat()
  var observer: CFRunLoopObserver?
  func run(_ panel:LibraryPanelView) async -> [LibraryScrollFrame] {
    self.panel = panel
    heartbeat.start()
    observer = CFRunLoopObserverCreateWithHandler(nil,CFRunLoopActivity.beforeWaiting.rawValue|CFRunLoopActivity.afterWaiting.rawValue,true,0) { [heartbeat] _,activity in
      heartbeat.beat(busy:activity == .afterWaiting)
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(),observer,.commonModes)
    return await withCheckedContinuation { continuation in
      completion = continuation
      link = panel.displayLink(target:self,selector:#selector(frame(_:)))
      link?.preferredFrameRateRange = CAFrameRateRange(minimum:120,maximum:120,preferred:120)
      link?.add(to:.main,forMode:.common)
    }
  }
  @objc func frame(_ link:CADisplayLink) {
    guard let panel else { finish(); return }
    let startTicks = mach_absolute_time()
    let index = rows.count, count = panel.filteredRowCount
    let before = panel.scrollCounters, start = ProcessInfo.processInfo.systemUptime
    let visible = panel.scrollToRow(Int((Double(index)/119)*Double(max(0,count-1))))
    let after = panel.scrollCounters
    rows.append(LibraryScrollFrame(startTicks:startTicks,endTicks:mach_absolute_time(),milliseconds:(ProcessInfo.processInfo.systemUptime-start)*1000,visibleRows:visible,
      intervalMilliseconds:previousTimestamp == 0 ? 0 : (link.timestamp-previousTimestamp)*1000,
      counters:after,counterDelta:after.reduce(into:[String:Double]()) { $0[$1.key] = $1.value-(before[$1.key] ?? 0) },heartbeat:heartbeat.read()))
    previousTimestamp = link.timestamp
    if rows.count == 120 { finish() }
  }
  func finish() {
    link?.invalidate(); link = nil
    if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(),observer,.commonModes); self.observer = nil }
    heartbeat.stop()
    completion?.resume(returning:rows); completion = nil
  }
}
#endif

#if OPEN_AUTOMATION
/// Exists only for the socket scroll benchmark. A run-loop heartbeat separates
/// busy main-thread gaps from a sleeping main thread with no display callback.
private final class LibraryScrollHeartbeat: @unchecked Sendable {
  private let lock = NSLock()
  private var busy = false
  private var timestamp = ProcessInfo.processInfo.systemUptime
  private var maxBusy = 0.0, maxIdle = 0.0
  private var samples = 0.0
  private var timer: (any DispatchSourceTimer)?
  func beat(busy:Bool) {
    lock.withLock { self.busy = busy; timestamp = ProcessInfo.processInfo.systemUptime }
  }
  func start() {
    let timer = DispatchSource.makeTimerSource(queue:DispatchQueue(label:"open.library.scroll-watchdog",qos:.userInteractive))
    timer.schedule(deadline:.now(),repeating:.milliseconds(2),leeway:.microseconds(100))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      self.lock.withLock {
        let age = (ProcessInfo.processInfo.systemUptime-self.timestamp)*1000
        if self.busy { self.maxBusy = max(self.maxBusy,age) } else { self.maxIdle = max(self.maxIdle,age) }
        self.samples += 1
      }
    }
    self.timer = timer; timer.resume()
  }
  func read() -> [String:Double] {
    lock.withLock {
      let result = ["maxBusyAgeMilliseconds":maxBusy,"maxIdleAgeMilliseconds":maxIdle,"watchdogSamples":samples]
      maxBusy = 0; maxIdle = 0; samples = 0
      return result
    }
  }
  func stop() { timer?.cancel(); timer = nil }
}
#endif
