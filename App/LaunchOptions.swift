import AppKit
import OpenEngine

/// Spike command-line options. Unknown `--switches` also reach Chromium,
/// because CEF parses the process command line itself (for example
/// `--load-extension=/path/to/unpacked`).
struct LaunchOptions {
  var userDataDirectory: URL
  var defaultStyle: RuntimeStyle = .alloy
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

    for arg in arguments.dropFirst() {
      func value(_ name: String) -> String? {
        arg.hasPrefix("--\(name)=") ? String(arg.dropFirst(name.count + 3)) : nil
      }
      if let v = value("user-data-dir") {
        userDataDirectory = URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true)
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
    if automationSocket == nil, let path = env["OPEN_AUTOMATION_SOCKET"] {
      automationSocket = URL(fileURLWithPath: path)
    }
  }
}

/// Wall-clock marks for launch measurements (see docs/engine-spike.md).
@MainActor
final class LaunchTiming {
  static let shared = LaunchTiming()

  /// Process start, from the kernel.
  let processStart: Date
  private(set) var marks: [(String, Date)] = []

  private init() {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    sysctl(&mib, 4, &info, &size, nil, 0)
    let tv = info.kp_proc.p_un.__p_starttime
    processStart = Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
  }

  func mark(_ name: String) {
    if !marks.contains(where: { $0.0 == name }) {
      marks.append((name, Date()))
    }
  }

  /// Milliseconds since process start for each mark.
  var report: [String: Double] {
    var out: [String: Double] = [:]
    for (name, date) in marks {
      out[name] = (date.timeIntervalSince(processStart) * 1000).rounded()
    }
    return out
  }
}
