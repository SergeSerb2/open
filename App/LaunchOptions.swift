import AppKit
import OpenEngine

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
  /// Debug and automation builds: replaces Open's PiP site-rule file (media-pip §4.5.4, e2e).
  var pipSiteRules: URL?

  init(arguments: [String]) {
    let env = ProcessInfo.processInfo.environment
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
  private struct ClockOrigin {
    let ticks: UInt64
    let millisecondsPerTick: Double
    let hasKernelProcessStart: Bool
  }
  private let continuousOffset: UInt64
  private let fallbackStartTicks: UInt64
  private lazy var origin = loadClockOrigin()
  var processStartTicks: UInt64 { origin.ticks }
  var hasKernelProcessStart: Bool { origin.hasKernelProcessStart }
  private(set) var marks: [(String, UInt64)] = []
  private var firstFrameConfirmed: Bool?

  private init() {
    // Capture the absolute/continuous offset before a possible sleep. Kernel
    // metadata can wait until reporting; recording a mark only reads the clock.
    let absolute = mach_absolute_time(), continuous = mach_continuous_time()
    continuousOffset = continuous - absolute
    fallbackStartTicks = continuous
  }

  private func loadClockOrigin() -> ClockOrigin {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    let hasStart = status == 0 && info.ri_proc_start_abstime > 0
    return ClockOrigin(
      ticks: hasStart ? info.ri_proc_start_abstime + continuousOffset : (marks.first?.1 ?? fallbackStartTicks),
      millisecondsPerTick: Double(timebase.numer) / Double(timebase.denom) / 1_000_000,
      hasKernelProcessStart: hasStart)
  }

  var elapsedMilliseconds: Double {
    let clock = origin
    return Double(mach_continuous_time() - clock.ticks) * clock.millisecondsPerTick
  }
  func mark(_ name: String) {
    if !marks.contains(where: { $0.0 == name }) { marks.append((name, mach_continuous_time())) }
  }
  func recordProcessEntry(_ ticks: UInt64) { marks.append(("processMain", ticks)) }
  func recordFirstFrame(confirmed: Bool) { firstFrameConfirmed = confirmed }
  var report: [String: Any] {
    let clock = origin
    var result: [String: Any] = Dictionary(uniqueKeysWithValues: marks.map { ($0.0, (Double($0.1 - clock.ticks) * clock.millisecondsPerTick).rounded() as Any) })
    if let firstFrameConfirmed { result["firstFrameConfirmed"] = firstFrameConfirmed }
    return result
  }
}
