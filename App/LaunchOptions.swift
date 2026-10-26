import AppKit
import OpenEngine

/// Command-line options. Unknown `--switches` also reach Chromium, because
/// CEF parses the process command line itself (for example
/// `--load-extension=/path/to/unpacked`).
///
///   Open [URL...] [--user-data-dir=DIR] [--style=chrome]
///        [--open-remote-debugging-port=N] [--automation-socket=PATH]
///        [--chrome-toolbar] [--verbose]
struct LaunchOptions {
  /// Open's data root (docs/plans/profiles.md §5): State/browser.json and
  /// Profiles/<dir>/{Engine,State,...}.
  var userDataDirectory: URL
  var defaultStyle: OERuntimeStyle = .alloy
  var initialURLs: [URL] = []
  var remoteDebuggingPort = 0
  var verboseLogging = false
  var automationSocket: URL?
  var chromeToolbar = false

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
        defaultStyle = v == "chrome" ? .chrome : .alloy
      } else if let v = value("open-remote-debugging-port") {
        remoteDebuggingPort = Int(v) ?? 0
      } else if let v = value("automation-socket") {
        automationSocket = URL(fileURLWithPath: v)
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
  let processStartTicks: UInt64
  let hasKernelProcessStart: Bool
  private let millisecondsPerTick: Double
  private(set) var marks: [(String, UInt64)] = []

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
    if !marks.contains(where: { $0.0 == name }) { marks.append((name, mach_continuous_time())) }
  }
  var report: [String: Double] {
    Dictionary(uniqueKeysWithValues: marks.map { ($0.0, (Double($0.1 - processStartTicks) * millisecondsPerTick).rounded()) })
  }
}
