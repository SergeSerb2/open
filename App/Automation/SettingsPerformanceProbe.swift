#if OPEN_AUTOMATION
import AppKit
import QuartzCore
import OpenSettings
import Darwin

/// Bounded real-window measurement. Input stays inside this Open process.
/// All hooks and the display link are removed at completion or cancellation.
@MainActor final class SettingsPerformanceProbe: NSObject {
  private weak var window: NSWindow?
  private let root: SettingsViewModel
  private var link: CADisplayLink?
  private let mode: String
  private var frameCount = 0
  private var previousFrame = 0.0
  private var intervals: [Double] = []
  private var pending: (section: SettingsSection, start: Double, cpu: UInt64, draw: Double?)?
  private var samples: [[String: Any]] = []
  private var index = 0
  private var scroll: NSScrollView?
  private var scrollCPU: [Double] = []
  private var scrollOffsets: [Double] = []
  private var missed = 0
  private var missedSamples: [[String: Any]] = []
  private(set) var running = true
  private let targetFPS: Int
  private let sequence: [SettingsSection]
  init(window: NSWindow, root: SettingsViewModel, mode: String) {
    self.window = window; self.root = root; self.mode = mode
    let sections = SettingsSection.allCases
    let next = sections.firstIndex(of: root.selectedSection).map { $0 + 1 } ?? 0
    sequence = Array(sections.dropFirst(next)) + Array(sections.prefix(next))
    targetFPS = window.screen?.maximumFramesPerSecond ?? 60
    super.init()
    root.onSectionDraw = { [weak self] section, time in
      guard let self, let pending, pending.section == section, pending.draw == nil else { return }
      self.pending?.draw = time
    }
    if mode == "scroll" { press(.shortcuts) }
    guard let view = window.contentView else { stop(); return }
    let link = view.displayLink(target: self, selector: #selector(frame(_:)))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(targetFPS), maximum: Float(targetFPS), preferred: Float(targetFPS))
    self.link = link; link.add(to: .main, forMode: .common)
  }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private func press(_ section: SettingsSection) {
    guard let content = window?.contentView,
      let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "settings-nav-" + section.rawValue }) else { return }
    button.sendAction(button.action, to: button.target)
  }
  @objc private func frame(_ display: CADisplayLink) {
    guard running else { return }
    frameCount += 1
    if previousFrame > 0 { intervals.append((display.timestamp - previousFrame) * 1000) }
    previousFrame = display.timestamp
    if mode == "sections" {
      if let request = pending, let draw = request.draw, display.timestamp >= draw {
        samples.append(["section": request.section.rawValue, "warm": index > sequence.count,
          "firstDrawMs": (draw - request.start) * 1000,
          "firstDisplayOpportunityMs": (display.timestamp - request.start) * 1000])
        pending = nil
      }
      let cadence = max(12, targetFPS / 5)
      if frameCount % cadence == 1 {
        if let pending {
          missed += 1
          missedSamples.append(["section": pending.section.rawValue, "actualSection": root.selectedSection.rawValue,
            "elapsedMs": (CACurrentMediaTime() - pending.start) * 1000, "drawSubmitted": pending.draw != nil])
          self.pending = nil
        }
        if index >= sequence.count * 3 { stop(); return }
        let section = sequence[index % sequence.count]; index += 1
        pending = (section, CACurrentMediaTime(), clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), nil)
        press(section)
      }
    } else {
      let warmup = max(30, targetFPS / 2)
      guard frameCount > warmup else { return }
      if scroll == nil, let content = window?.contentView {
        scroll = descendants(content).compactMap { $0 as? NSScrollView }.first { $0.documentView is NSTableView }
      }
      guard let scroll else { missed += 1; stop(); return }
      let activeFrame = frameCount - warmup
      let delta: Int32 = activeFrame <= targetFPS * 2 ? -12 : 12
      if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0), let event = NSEvent(cgEvent: cg) {
        let begin = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        scroll.scrollWheel(with: event)
        scrollCPU.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - begin) / 1_000_000)
        scrollOffsets.append(scroll.contentView.bounds.minY)
      }
      if activeFrame >= targetFPS * 4 { stop() }
    }
    if frameCount > targetFPS * 20 { missed += 1; stop() }
  }
  func stop() {
    running = false; link?.invalidate(); link = nil; root.onSectionDraw = nil
  }
  var state: [String: Any] {
    ["running": running, "mode": mode, "requestedFPS": targetFPS, "frames": frameCount,
      "frameIntervalsMs": intervals, "sections": samples, "missingDraws": missed,
      "missedSamples": missedSamples,
      "scrollEventCPUms": scrollCPU, "scrollOffsets": scrollOffsets,
      "scope": "Real native navigation action to first content draw submission and next display-link timestamp; display-link pacing during real NSScrollView wheel dispatch. Excludes WindowServer scanout confirmation."]
  }
}
#endif
