import AppKit
import OpenModel

/// `open-browser://` deep links (Arc parity: Arc registers `arcBrowser`, role Editor;
/// route names quit, restart, space, welcomeToArc and others in Arc 1.170.0 strings).
/// Lead ruling 2026-11-12 01:25: routes quit, restart, space/<name|index>, welcome.
/// Guess — capture pending (C3-PB1-c): Arc's URL and argument shapes; match them when recorded.
/// Unknown routes do nothing and log one line (never the full URL).
@MainActor
final class DeepLinkRouter {
  static let scheme = "open-browser"
  private unowned let app: AppDelegate
  private var pending: [URL] = []
  /// Automation evidence: the last route and its result.
  private(set) var last: (route: String, result: String)?
  private(set) var handledCount = 0
  /// Set by the restart route; the relauncher starts only when the quit is committed.
  private(set) var restartRequested = false
  private var restartStarting = false

  init(app: AppDelegate) { self.app = app }

  static func matches(_ url: URL) -> Bool { url.scheme?.lowercased() == scheme }

  func handle(_ url: URL) {
    if app.linkIntake.ready { route(url) } else { pending.append(url) }
  }

  func markReady() {
    let queued = pending; pending.removeAll()
    for url in queued { route(url) }
  }

  /// `open-browser://space/2` parses as host "space", path "/2"; also accept
  /// `open-browser:space/2` (no authority).
  static func components(_ url: URL) -> [String] {
    var parts: [String] = []
    if let host = url.host(percentEncoded: false), !host.isEmpty { parts.append(host) }
    let path = url.host == nil ? (URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? "") : url.path(percentEncoded: false)
    parts += path.split(separator: "/").map(String.init).compactMap { $0.removingPercentEncoding ?? $0 }
    return parts.filter { !$0.isEmpty }
  }

  private func route(_ url: URL) {
    handledCount += 1
    let parts = Self.components(url)
    let name = parts.first?.lowercased() ?? ""
    let result: String
    switch name {
    // Quit after the Apple event handler returns, so LaunchServices gets its reply first.
    case "quit":
      result = "quit"; DispatchQueue.main.async { NSApp.terminate(nil) }
    case "restart":
      result = "restart"
      DispatchQueue.main.async { [weak self] in
        // The flag marks this quit attempt only (`beginQuitAttempt`), so a restart whose quit
        // is cancelled (an alert's Cancel, a page's "Stay") does not relaunch a later quit.
        self?.restartStarting = true; NSApp.terminate(nil); self?.restartStarting = false
      }
    case "welcome":
      if let factory = frontFactory() { factory.openBasics(nil); result = "welcome" } else { result = "no-window" }
    case "space":
      result = focusSpace(parts.dropFirst().joined(separator: "/"))
    default:
      result = "unknown"
    }
    last = (name, result)
    if result != name {
      // Route names are a fixed, short vocabulary; anything else is reported by length only.
      let label = ["quit", "restart", "welcome", "space"].contains(name) ? name : "<\(name.count) chars>"
      AppDelegate.commandLog("Deep link \(label) did nothing (\(result)).")
    }
  }

  private func frontFactory() -> EngineWebContentHostFactory? {
    app.frontWindowController.flatMap { app.hostFactories[$0.windowID] }
  }

  /// A 1-based index (the Ctrl+1…9 order) or a Space title (case-insensitive).
  private func focusSpace(_ argument: String) -> String {
    // The main model's Spaces live in its windows only (not Incognito or a Blank Window).
    guard let factory = app.frontMainModelWindowController.flatMap({ app.hostFactories[$0.windowID] }) else { return "no-window" }
    let spaces = app.model.spaces
    let space: Space?
    if let index = Int(argument) { space = (1...max(1, spaces.count)).contains(index) && !spaces.isEmpty ? spaces[index - 1] : nil }
    else { space = spaces.first { $0.title?.compare(argument, options: [.caseInsensitive]) == .orderedSame } }
    guard let space else { return "no-space" }
    factory.focus(space: space)
    return "space"
  }

  /// A fresh quit attempt starts: it restarts only if the restart route started it.
  /// Retries of the same attempt (history flush, sleep capture, page replies) keep the flag.
  func beginQuitAttempt() { restartRequested = restartStarting }

  /// Called once the quit is committed. Starts the same executable with the same
  /// options after this process exits (launch URLs are not repeated).
  func relaunchIfRequested() {
    guard restartRequested else { return }
    let arguments = ProcessInfo.processInfo.arguments
    guard let executable = arguments.first else { return }
    let options = Self.relaunchOptions(Array(arguments.dropFirst()))
    let waiter = Process()
    waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
    waiter.arguments = ["-c", "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.1; done; exec \"$@\"",
      String(ProcessInfo.processInfo.processIdentifier), executable] + options
    do { try waiter.run() } catch { AppDelegate.commandLog("Restart could not start the relauncher.") }
  }

  /// Options without the launch URLs. A single-dash user-defaults option
  /// (`-NSFoo YES`, as Xcode passes them) keeps its separate value; `--key=value`
  /// switches stand alone. The old process serial number (`-psn_…`) is dropped.
  static func relaunchOptions(_ arguments: [String]) -> [String] {
    var options: [String] = []
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      guard argument.hasPrefix("-"), !argument.hasPrefix("-psn_") else { continue }
      options.append(argument)
      if !argument.hasPrefix("--"), argument.count > 1, !argument.contains("="),
        index < arguments.count, !arguments[index].hasPrefix("-"),
        URL(string: arguments[index])?.scheme == nil {  // a launch URL is not a value
        options.append(arguments[index]); index += 1
      }
    }
    return options
  }
}
