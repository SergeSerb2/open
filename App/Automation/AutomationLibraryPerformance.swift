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
    if operation == "preparation-state" { return libraryPreparationState() }
    if operation == "preparation-trace" {
      guard let trace = libraryPreparationHeartbeat else { throw Failure(message:"Library preparation trace not enabled at launch") }
      if args["stop"] as? Bool == true { trace.stop() }
      return trace.json(slices:adapter.activeLibrarySession?.panel?.idleWorkIntervals ?? [])
    }
    if operation == "cpu" {
      var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
      return ["cpuSeconds":Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1_000_000,"launchElapsedMilliseconds":LaunchTiming.shared.elapsedMilliseconds,"counters":adapter.activeLibrarySession?.panel?.performanceCounters ?? [:]]
    }
    let countersBefore = adapter.activeLibrarySession?.panel?.performanceCounters ?? [:]
    let preparationBefore = operation == "open" ? libraryPreparationState() : [:]
    var started = ProcessInfo.processInfo.systemUptime
    if operation == "scroll-series" {
      guard let panel = adapter.activeLibrarySession?.panel,panel.isPresented else { throw Failure(message:"Library not open") }
      guard let profile = LibraryScrollProfile(rawValue:args["profile"] as? String ?? "scroller") else { throw Failure(message:"unknown Library scroll profile") }
      let beginAt = args["beginAtLaunchMilliseconds"] as? Double ?? 0
      guard beginAt.isFinite,(0...300_000).contains(beginAt) else { throw Failure(message:"invalid Library scroll start") }
      if beginAt > LaunchTiming.shared.elapsedMilliseconds {
        try await Task.sleep(for:.milliseconds(beginAt-LaunchTiming.shared.elapsedMilliseconds))
      }
      let probe = LibraryScrollProbe()
      let idleStart = panel.idleWorkIntervals.count
      let samples = await probe.run(panel,profile:profile)
      let launchUptime = ProcessInfo.processInfo.systemUptime-LaunchTiming.shared.elapsedMilliseconds/1000
      return ["profile":profile.rawValue,"frames":samples.prefix(profile.callbacks).map(\.json),
        "settlingFrames":samples.dropFirst(profile.callbacks).map(\.json),"counters":panel.performanceCounters,"inputError":probe.inputError,
        "idleWorkIntervals":panel.idleWorkIntervals.dropFirst(idleStart).map { slice in
          var detail = slice
          detail["startLaunchMilliseconds"] = (slice["startUptime"]!-launchUptime)*1000
          detail["endLaunchMilliseconds"] = (slice["endUptime"]!-launchUptime)*1000
          return detail
        },
        "heartbeatContexts":["0":"App main run loop outside scroll callback","1":"Library scrollToRow and submitNativeFrame","2":"NSWindow.sendEvent wheel delivery","3":"Library submitNativeFrame"]]
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
      "preparationBefore":preparationBefore,
      "providerRows":panel.filteredRowCount,
      "actionMilliseconds":actionMilliseconds,"firstSubmissionPhases":firstPhases,
      "searchTimestamps":operation == "search" ? panel.searchTimestamps : [:],
      "panelGeneration":adapter.activeLibrarySession?.panelGeneration ?? 0,
      "visibleRows":panel.listReuseState["rows"] ?? 0,"counters":panel.performanceCounters,
      "counterDelta":panel.performanceCounters.reduce(into:[String:Double]()) { $0[$1.key] = $1.value-(countersBefore[$1.key] ?? 0) }]
  }

  func libraryPreparationState() -> [String:Any] {
    let panel = app.settingsPresenter.activeLibrarySession?.panel
    let ready = panel?.prebuiltReady ?? false
    let pending = app.libraryPrebuildTask != nil
    let tasks = panel?.performanceCounters["tasks"] ?? 0
    return ["launchMilliseconds":LaunchTiming.shared.elapsedMilliseconds,
      "prebuiltReady":ready,"prebuildTaskPending":pending,"panelTasks":tasks,
      "completed":ready && !pending && tasks == 0,
      "idleSliceCount":panel?.idleWorkIntervals.count ?? 0]
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
  let launchMilliseconds: Double
  let input: [String:Double]
  let counters: [String:Double]
  let counterDelta: [String:Double]
  let heartbeat: [String:Double]
  let betweenCallbackDelta: [String:Double]
  var json: [String:Any] { ["startTicks":startTicks,"endTicks":endTicks,"milliseconds":milliseconds,"visibleRows":visibleRows,"intervalMilliseconds":intervalMilliseconds,"launchMilliseconds":launchMilliseconds,"input":input,"counters":counters,"counterDelta":counterDelta,"betweenCallbackDelta":betweenCallbackDelta,"heartbeat":heartbeat] }
}
private enum LibraryScrollProfile: String {
  case wheel, scroller, control
  var callbacks: Int { switch self { case .wheel:600; case .scroller:120; case .control:216 } }
}
@MainActor
private final class LibraryScrollProbe: NSObject {
  weak var panel: LibraryPanelView?
  var link: CADisplayLink?
  var completion: CheckedContinuation<[LibraryScrollFrame],Never>?
  var rows: [LibraryScrollFrame] = []
  var previousTimestamp = 0.0
  var previousCounters: [String:Double] = [:]
  var profile = LibraryScrollProfile.scroller
  weak var scroll: NSScrollView?
  var inputError = ""
  let heartbeat = LibraryScrollHeartbeat()
  var observers: [CFRunLoopObserver] = []
  func run(_ panel:LibraryPanelView,profile:LibraryScrollProfile) async -> [LibraryScrollFrame] {
    self.panel = panel
    self.profile = profile
    func find(_ view:NSView) -> NSScrollView? {
      if let candidate = view as? NSScrollView,!candidate.isHiddenOrHasHiddenAncestor,
        candidate.documentView?.accessibilityRole() == .table { return candidate }
      for child in view.subviews { if let found = find(child) { return found } }
      return nil
    }
    scroll = find(panel)
    guard scroll != nil else { inputError = "visible Library scroll view not found"; return [] }
    rows.reserveCapacity(profile.callbacks+216)
    heartbeat.start(launchUptime:ProcessInfo.processInfo.systemUptime-LaunchTiming.shared.elapsedMilliseconds/1000)
    // Observe sleep after Core Animation's implicit transaction commit. An
    // order-zero beforeWaiting observer would hide that work as idle when
    // preparation leaves commits to the run loop.
    for (activity,order) in [(CFRunLoopActivity.afterWaiting,CFIndex.min),(.beforeWaiting,CFIndex.max)] {
      if let observer = CFRunLoopObserverCreateWithHandler(nil,activity.rawValue,true,order,{ [heartbeat] _,activity in
        heartbeat.beat(busy:activity == .afterWaiting)
      }) {
        observers.append(observer)
        CFRunLoopAddObserver(CFRunLoopGetMain(),observer,.commonModes)
      }
    }
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
    let launchMilliseconds = LaunchTiming.shared.elapsedMilliseconds
    var input: [String:Double] = [:]
    let visible: Int
    switch index >= profile.callbacks ? .control : profile {
    case .scroller:
      heartbeat.context("Library scrollToRow and submitNativeFrame")
      visible = panel.scrollToRow(Int((Double(index)/119)*Double(max(0,count-1))))
    case .wheel:
      // One precise-pixel native event per display callback. Contact ramps to
      // three 56pt rows, followed by decaying momentum. Nothing posts to macOS.
      let delta = index < 180 ? max(1,168*sin(min(1,Double(index)/90)*Double.pi/2)) : max(1,168*exp(-Double(index-180)/80))
      // Quartz scroll phases (1/2/4) and momentum phases (1/2/3) have
      // different encodings from NSEvent.Phase. Record the converted values.
      // Keep the decaying contact input for 4.5s; native momentum supplies
      // the final 0.5s. A long synthetic momentum tail can outlive AppKit's
      // own inertia and would turn most of the receipt into idle callbacks.
      let phase:Int64 = index == 0 ? 1 : index < 539 ? 2 : index == 539 ? 4 : 0
      let momentum:Int64 = index < 540 ? 0 : index == 540 ? 1 : index == 599 ? 3 : 2
      let points = index == 539 || index == 599 ? 0 : delta
      guard let cg = CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:-Int32(points.rounded()),wheel2:0,wheel3:0),let scroll,let window = scroll.window else {
        inputError = "could not create native wheel event"; finish(); return
      }
      cg.setIntegerValueField(.scrollWheelEventIsContinuous,value:1)
      cg.setIntegerValueField(.scrollWheelEventScrollPhase,value:phase)
      cg.setIntegerValueField(.scrollWheelEventMomentumPhase,value:momentum)
      cg.setIntegerValueField(.scrollWheelEventScrollCount,value:1)
      // CreateScrollWheelEvent2 starts with timestamp 0. AppKit must see a
      // current event time, including on the momentum part of the gesture.
      cg.timestamp = UInt64(ProcessInfo.processInfo.systemUptime*1_000_000_000)
      cg.flags = []
      // CGEvent-created NSEvents have windowNumber 0. Deliver to the owning
      // window with a window-local hit point so AppKit can latch momentum.
      let point = scroll.convert(CGPoint(x:scroll.bounds.midX,y:scroll.bounds.midY),to:nil)
      cg.location = CGPoint(x:point.x,y:(NSScreen.screens.first?.frame.maxY ?? 0)-point.y)
      guard let event = NSEvent(cgEvent:cg) else { inputError = "could not convert native wheel event"; finish(); return }
      let y = scroll.contentView.bounds.minY
      heartbeat.context("NSWindow.sendEvent wheel delivery")
      window.sendEvent(event)
      heartbeat.context("Library submitNativeFrame")
      panel.submitNativeFrame()
      input = ["requestedPoints":points,"eventDeltaY":event.scrollingDeltaY,"precise":event.hasPreciseScrollingDeltas ? 1 : 0,"phase":Double(event.phase.rawValue),"momentumPhase":Double(event.momentumPhase.rawValue),"windowNumber":Double(event.windowNumber),"timestamp":event.timestamp,"offsetBefore":y,"offsetAfter":scroll.contentView.bounds.minY]
      visible = 0
    case .control:
      // The no-scroll control performs no layout, display or forced commit.
      visible = 0
    }
    let after = panel.scrollCounters
    rows.append(LibraryScrollFrame(startTicks:startTicks,endTicks:mach_absolute_time(),milliseconds:(ProcessInfo.processInfo.systemUptime-start)*1000,visibleRows:visible,
      intervalMilliseconds:previousTimestamp == 0 ? 0 : (link.timestamp-previousTimestamp)*1000,launchMilliseconds:launchMilliseconds,input:input,
      counters:after,counterDelta:after.reduce(into:[String:Double]()) { $0[$1.key] = $1.value-(before[$1.key] ?? 0) },heartbeat:heartbeat.read(),
      betweenCallbackDelta:previousCounters.isEmpty ? [:] : before.reduce(into:[String:Double]()) { $0[$1.key] = $1.value-(previousCounters[$1.key] ?? 0) }))
    heartbeat.context("App main run loop outside scroll callback")
    previousCounters = after
    previousTimestamp = link.timestamp
    if rows.count == profile.callbacks+(profile == .control ? 0 : 216) { finish() }
  }
  func finish() {
    link?.invalidate(); link = nil
    for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(),observer,.commonModes) }
    observers = []
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
  private var accountedTimestamp = ProcessInfo.processInfo.systemUptime
  private var intervalBusyMilliseconds = 0.0
  private var maxBusy = 0.0, maxIdle = 0.0
  private var launchUptime = 0.0, busyStart = 0.0, busyEnd = 0.0
  private var entry = "App main run loop outside scroll callback", busyEntry = ""
  private var samples = 0.0
  private var timer: (any DispatchSourceTimer)?
  func beat(busy:Bool) {
    lock.withLock {
      let now = ProcessInfo.processInfo.systemUptime
      if self.busy { intervalBusyMilliseconds += (now-accountedTimestamp)*1000 }
      if self.busy,!busy,(now-timestamp)*1000 > maxBusy {
        maxBusy = (now-timestamp)*1000
        busyStart = (timestamp-launchUptime)*1000; busyEnd = (now-launchUptime)*1000
        busyEntry = entry
      }
      self.busy = busy; timestamp = now; accountedTimestamp = now
    }
  }
  func context(_ entry:String) { lock.withLock { self.entry = entry } }
  func start(launchUptime:Double) {
    self.launchUptime = launchUptime
    let timer = DispatchSource.makeTimerSource(queue:DispatchQueue(label:"open.library.scroll-watchdog",qos:.userInteractive))
    timer.schedule(deadline:.now(),repeating:.milliseconds(2),leeway:.microseconds(100))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      self.lock.withLock {
        let age = (ProcessInfo.processInfo.systemUptime-self.timestamp)*1000
        if self.busy,age > self.maxBusy {
          self.maxBusy = age; self.busyStart = (self.timestamp-self.launchUptime)*1000
          self.busyEnd = (ProcessInfo.processInfo.systemUptime-self.launchUptime)*1000; self.busyEntry = self.entry
        } else if !self.busy { self.maxIdle = max(self.maxIdle,age) }
        self.samples += 1
      }
    }
    self.timer = timer; timer.resume()
  }
  func read() -> [String:Double] {
    lock.withLock {
      let now = ProcessInfo.processInfo.systemUptime
      if busy { intervalBusyMilliseconds += (now-accountedTimestamp)*1000 }
      accountedTimestamp = now
      let context:Double = switch busyEntry {
      case "Library scrollToRow and submitNativeFrame":1
      case "NSWindow.sendEvent wheel delivery":2
      case "Library submitNativeFrame":3
      default:0
      }
      let result = ["maxBusyAgeMilliseconds":maxBusy,"maxIdleAgeMilliseconds":maxIdle,"watchdogSamples":samples,"busyStartLaunchMilliseconds":busyStart,"busyEndLaunchMilliseconds":busyEnd,"busyInsideCallback":context == 0 ? 0.0 : 1.0,"busyContextCode":context,"mainBusyIntervalMilliseconds":intervalBusyMilliseconds]
      maxBusy = 0; maxIdle = 0; samples = 0; intervalBusyMilliseconds = 0
      return result
    }
  }
  func stop() { timer?.cancel(); timer = nil }
}
#endif
