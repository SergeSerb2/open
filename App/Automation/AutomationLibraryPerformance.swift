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
      return ["cpuSeconds":Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1_000_000]
    }
    let started = ProcessInfo.processInfo.systemUptime
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
        adapter.activeLibrarySession?.panel?.isPresented == true else { throw Failure(message:"invalid Library search") }
      _ = try await sendKey(["key":"f","modifiers":["cmd"],"route":"app"],try? window)
      _ = try await sendKey(["text":text,"route":"app"],try? window)
    case "scroll":
      guard let panel=adapter.activeLibrarySession?.panel, panel.isPresented,
        let row=args["row"] as? Int, (0...100_000).contains(row) else { throw Failure(message:"invalid Library scroll") }
      let visible=panel.scrollToRow(row)
      return ["milliseconds":(ProcessInfo.processInfo.systemUptime-started)*1000,"visibleRows":visible]
    default: throw Failure(message:"unknown Library measurement")
    }
    guard let panel=adapter.activeLibrarySession?.panel else { throw Failure(message:"Library not created") }
    panel.submitNativeFrame()
    let first=(ProcessInfo.processInfo.systemUptime-started)*1000
    await panel.finishPendingContent(); panel.submitNativeFrame()
    let full=(ProcessInfo.processInfo.systemUptime-started)*1000
    return ["firstSubmittedMilliseconds":first,"contentSubmittedMilliseconds":full,
      "providerRows":adapter.library?.section == .downloads ? adapter.library?.downloadItems.count ?? 0 : adapter.library?.section == .history ? adapter.library?.historyRows.count ?? 0 : adapter.library?.archiveRows.count ?? 0,
      "panelGeneration":adapter.activeLibrarySession?.panelGeneration ?? 0]
  }
}
#endif
