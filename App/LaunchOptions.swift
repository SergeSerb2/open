import AppKit
import OpenEngine
import os.signpost

/// Command-line options. Unknown `--switches` also reach Chromium, because
/// CEF parses the process command line itself (for example
/// `--load-extension=/path/to/unpacked`).
///
///   Open [URL...] [--user-data-dir=DIR] [--style=alloy]
///        [--open-remote-debugging-port=N] [--automation-socket=PATH]
///        [--chrome-toolbar] [--verbose] [--pip-site-rules=FILE (Debug)]
struct LaunchOptions {
  /// Open's data root (docs/plans/profiles.md §5): State/browser.json and
  /// Profiles/<dir>/{Engine,State,...}.
  var userDataDirectory: URL
  /// Chrome: tabs are tabs of each window's hidden Chrome window (fork
  /// patch P1), so chrome.tabs sees them. Alloy: the pre-P1 hosting.
  var defaultStyle: OERuntimeStyle = .chrome
  var initialURLs: [URL] = []
  var remoteDebuggingPort = 0
  var verboseLogging = false
  var automationSocket: URL?
  var chromeToolbar = false
  /// Test/support overrides. Normal launches detect first run from the snapshot.
  var skipFirstRun = false
  var arcDirectory: URL?
  /// Debug and automation builds: replaces Open's PiP site-rule file (media-pip §4.5.4, e2e).
  var pipSiteRules: URL?

  init(arguments: [String]) {
    let env = ProcessInfo.processInfo.environment
    skipFirstRun = env["OPEN_SKIP_FIRST_RUN"] == "1"
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    #if DEBUG
      let defaultDir = support.appendingPathComponent("Open-Dev", isDirectory: true)
    #else
      let defaultDir = support.appendingPathComponent("Open", isDirectory: true)
    #endif
    userDataDirectory = env["OPEN_USER_DATA"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultDir

    func path(_ v: String) -> URL {
      URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true)
    }
    for arg in arguments.dropFirst() {
      func value(_ name: String) -> String? {
        arg.hasPrefix("--\(name)=") ? String(arg.dropFirst(name.count + 3)) : nil
      }
      if let v = value("user-data-dir") {
        userDataDirectory = path(v)
      } else if arg == "--skip-first-run" {
        skipFirstRun = true
      } else if let v = value("arc-dir") {
        arcDirectory = path(v)
      } else if let v = value("style") {
        defaultStyle = v == "alloy" ? .alloy : .chrome
      } else if let v = value("open-remote-debugging-port") {
        remoteDebuggingPort = Int(v) ?? 0
      } else if let v = value("automation-socket") {
        automationSocket = URL(fileURLWithPath: v)
      } else if let v = value("pip-site-rules") {
        #if DEBUG || OPEN_AUTOMATION
          pipSiteRules = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
        #endif
      } else if arg == "--chrome-toolbar" {
        chromeToolbar = true
      } else if arg == "--verbose" {
        verboseLogging = true
      } else if !arg.hasPrefix("-"), let url = URL(string: arg), url.scheme != nil {
        initialURLs.append(url)
      }
    }
    if automationSocket == nil, let p = env["OPEN_AUTOMATION_SOCKET"] {
      automationSocket = URL(fileURLWithPath: p)
    }
  }
}

/// Launch marks use one monotonic clock, including the kernel process start.
@MainActor
final class LaunchTiming {
  static let shared = LaunchTiming()
  /// Opt-in, fixed-count startup probes. No timers or idle logging.
  let speedTraceEnabled = ProcessInfo.processInfo.environment["OPEN_SPEED_TRACE"] == "1"
  private let speedLog = OSLog(subsystem: "io.github.sergeserb2.open", category: "SpeedTrace")
  let processStartTicks: UInt64
  let hasKernelProcessStart: Bool
  private let millisecondsPerTick: Double
  private(set) var marks: [(String, UInt64)] = []
  private var firstFrameConfirmed: Bool?
  #if OPEN_AUTOMATION
  private var keyProbeTimestamp: TimeInterval?

  /// Queue an owned-window key dispatch at the confirmed frame. The native
  /// run loop must service it, and OEApplication.sendEvent routes it normally.
  func postKeyReadinessProbe(to window: NSWindow?) {
    guard ProcessInfo.processInfo.environment["OPEN_SPEED_KEY_PROBE"] == "1", let window else { return }
    let timestamp = ProcessInfo.processInfo.systemUptime
    let number = window.windowNumber
    keyProbeTimestamp = timestamp
    mark("keyPosted")
    // CefInitialize can discard events posted before its pump is installed.
    // A native run-loop task survives that setup and still exercises sendEvent.
    RunLoop.main.perform { [weak self] in
      MainActor.assumeIsolated {
        guard self != nil,
          let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: timestamp, windowNumber: number, context: nil,
            characters: "l", charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37)
        else { return }
        NSApp.sendEvent(event)
      }
    }
  }

  func recordKeyReadiness(_ event: NSEvent, handled: Bool) {
    guard keyProbeTimestamp == event.timestamp else { return }
    keyProbeTimestamp = nil
    mark(handled ? "keyAccepted" : "keyRejected")
  }
  #endif

  private init() {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    millisecondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    // The kernel supplies mach_absolute_time ticks. Translate once to the
    // continuous clock; marks then remain monotonic across sleep as well.
    let absolute = mach_absolute_time(), continuous = mach_continuous_time()
    hasKernelProcessStart = status == 0 && info.ri_proc_start_abstime > 0
    processStartTicks = hasKernelProcessStart ? info.ri_proc_start_abstime + (continuous - absolute) : continuous
  }

  var elapsedMilliseconds: Double { Double(mach_continuous_time() - processStartTicks) * millisecondsPerTick }
  func mark(_ name: String) {
    if !marks.contains(where: { $0.0 == name }) {
      marks.append((name, mach_continuous_time()))
      if speedTraceEnabled { os_signpost(.event, log: speedLog, name: "LaunchPhase", "%{public}@", name as NSString) }
    }
  }
  func phase(_ name: String) { if speedTraceEnabled { mark(name) } }
  func recordFirstFrame(confirmed: Bool) { firstFrameConfirmed = confirmed }
  var report: [String: Any] {
    var result: [String: Any] = Dictionary(uniqueKeysWithValues: marks.map { ($0.0, (Double($0.1 - processStartTicks) * millisecondsPerTick).rounded() as Any) })
    if speedTraceEnabled {
      result["preciseMs"] = Dictionary(uniqueKeysWithValues: marks.map { ($0.0, Double($0.1 - processStartTicks) * millisecondsPerTick) })
      result["processStartTicks"] = String(processStartTicks)
      result["millisecondsPerTick"] = millisecondsPerTick
    }
    if let firstFrameConfirmed { result["firstFrameConfirmed"] = firstFrameConfirmed }
    return result
  }
}
