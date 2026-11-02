import AppKit
import OpenEngine

/// Help ▸ Troubleshooting (plans/page-platform.md §4.11): Open Task Manager,
/// Record Trace / Cancel Trace, Copy Open Info, Reveal Open Data.
@MainActor
final class TroubleshootingActions {
  static let shared = TroubleshootingActions()

  enum Defaults {
    /// A trace stops by itself after this long (guess for Arc's `tracingDuration`, PG-11).
    static let maxTraceSeconds: TimeInterval = 60
  }

  /// Start of the trace this object records; nil when none records.
  private(set) var traceStartedAt: Date?
  /// One-shot work for the automatic stop; never a repeating timer.
  private var autoStop: DispatchWorkItem?
  /// Where Stop writes the trace. nil = ~/Downloads (automation sets a run folder).
  var traceDirectory: URL?
  private(set) var lastTraceFile: URL?
  private(set) var lastTraceError: String?
  private(set) var taskManagerShown: Bool?
  /// Finder reveal; automation can record instead of opening Finder.
  var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
  /// Shows a toast in the front browser window (title, optional button).
  var presentToast: (_ title: String, _ button: (title: String, action: () -> Void)?, _ sticky: Bool) -> Void = { title, _, _ in
    (NSApp.delegate as? AppDelegate)?.frontWindowController?.showToast(title, undo: nil)
  }

  var isRecording: Bool { traceStartedAt != nil }

  // MARK: Task manager (§4.11.1, EP-10a)

  func showTaskManager() {
    // Chromium's window (D-8, Q7). It needs one live Chrome style page.
    taskManagerShown = OEEngine.shared.showTaskManager()
    if taskManagerShown == false { AppDelegate.commandLog("Task Manager needs an open page") }
  }

  // MARK: Tracing (§4.11.2, EP-11)

  func recordTrace() {
    guard !isRecording, !OEEngine.shared.isTracing else { return }
    // nil categories = CEF's defaults. CEF has no privacy filter: traces can contain URLs.
    guard OEEngine.shared.beginTracing(categories: nil) else {
      lastTraceError = "Chromium refused to start a trace"; return
    }
    traceStartedAt = Date(); lastTraceError = nil
    let stop = DispatchWorkItem { [weak self] in self?.stopTrace() }
    autoStop = stop
    DispatchQueue.main.asyncAfter(deadline: .now() + Defaults.maxTraceSeconds, execute: stop)
    presentToast("Recording Trace…", ("Stop", { [weak self] in self?.stopTrace() }), true)
  }

  /// Stop: writes `Open Trace <yyyy-MM-dd HH.mm.ss>.json` into Downloads.
  func stopTrace() {
    guard let started = traceStartedAt else { return }
    finishRecording()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
    let folder = traceDirectory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    let file = folder.appendingPathComponent("Open Trace \(formatter.string(from: started)).json")
    OEEngine.shared.endTracing(to: file) { [weak self] written, error in
      guard let self else { return }
      self.lastTraceFile = written
      self.lastTraceError = error?.localizedDescription
      MenuRefresh.request()
      if let written {
        self.presentToast("Trace Saved", ("Show in Finder", { [weak self] in self?.reveal(written) }), false)
      } else {
        self.presentToast("The trace could not be saved", nil, false)
      }
    }
  }

  /// Cancel Trace: ends into a temporary file and deletes it.
  func cancelTrace() {
    guard isRecording else { return }
    finishRecording()
    OEEngine.shared.cancelTracing()
  }

  private func finishRecording() {
    traceStartedAt = nil
    autoStop?.cancel(); autoStop = nil
    presentToast("", nil, false)
  }

  // MARK: Copy Open Info (§4.11.3)

  /// No URLs, no profile names, no paths.
  static var openInfoText: String {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "development"
    let build = info["CFBundleVersion"] as? String ?? "0"
    var system = utsname(); uname(&system)
    let machine = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    return """
      Open \(version) (\(build))
      Engine: Chromium \(OEEngine.shared.chromiumVersion), CEF \(OEEngine.shared.cefVersion)
      macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
      Mac: \(hardwareModel) (\(machine))
      """
  }

  private static var hardwareModel: String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1, size <= 256 else { return "unknown" }
    var bytes = [UInt8](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
    return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
  }

  func copyOpenInfo() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(Self.openInfoText, forType: .string)
    presentToast("Copied Open Info", nil, false)
  }

  // MARK: Reveal Open Data (§4.11.4)

  /// The data root (`~/Library/Application Support/Open`, or the automation root).
  func revealOpenData() {
    guard let root = (NSApp.delegate as? AppDelegate)?.directories?.root else { return }
    reveal(root)
  }
}
