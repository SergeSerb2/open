import AppKit

/// One process-wide warm-up, queued only after the T5 hook confirms a web paint.
/// The temporary views never join a window. Open drops its references in this
/// turn; AppKit can defer NSTextView teardown until its next event-loop drain.
@MainActor
enum FindBarPrewarm {
  private(set) static var isScheduled = false
  private(set) static var runs = 0
  private(set) static var queuedAt = 0.0
  private(set) static var startedAt = 0.0
  private(set) static var completedAt = 0.0

  static func schedule(afterPaintIn app: AppDelegate) {
    guard !isScheduled else { return }
    isScheduled = true
    queuedAt = LaunchTiming.shared.elapsedMilliseconds
    #if OPEN_AUTOMATION
    if disabled { return }
    #endif
    DispatchQueue.main.async { [weak app] in
      guard let app, !app.shutdownPrepared, !app.terminationRequested else { return }
      startedAt = LaunchTiming.shared.elapsedMilliseconds
      runs += 1
      autoreleasepool { FindBarView.prewarmNativeControls() }
      completedAt = LaunchTiming.shared.elapsedMilliseconds
      #if OPEN_AUTOMATION
      releasedAtCompletion = temporaryBar == nil && temporaryEditor == nil
      #endif
    }
  }
  #if OPEN_AUTOMATION
  static let disabled = ProcessInfo.processInfo.environment["OPEN_FIND_DISABLE_PREWARM"] == "1"
  private static weak var temporaryBar: NSView?
  private static weak var temporaryEditor: NSTextView?
  private static var releasedAtCompletion = false
  static func observeTemporary(bar: NSView, editor: NSTextView) {
    temporaryBar = bar; temporaryEditor = editor
  }
  static var snapshot: [String: Any] {
    ["scheduled": isScheduled, "disabled": disabled, "runs": runs, "queuedAt": queuedAt,
      "startedAt": startedAt, "completedAt": completedAt, "releasedAtCompletion": releasedAtCompletion,
      "temporaryBarReleased": temporaryBar == nil, "temporaryEditorReleased": temporaryEditor == nil,
      "temporaryViewsReleased": temporaryBar == nil && temporaryEditor == nil]
  }
  #endif
}
