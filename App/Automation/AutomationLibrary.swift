#if OPEN_AUTOMATION
import AppKit
import OpenSettings

extension AutomationController {
  /// Read the real Library and its hosted grid. The only focus setup is the
  /// source list; Tab must reach the grid through the normal App event path.
  func libraryCapturesState(_ args: [String: Any]) throws -> [String: Any] {
    let adapter = app.settingsPresenter
    guard let library = adapter.library, let window = adapter.libraryPresenter?.window else {
      throw Failure(message: "Library not open")
    }
    if let record = args["recordFileActions"] as? Bool { adapter.recordCaptureFileActions = record }
    window.layoutIfNeeded(); window.contentView?.layoutSubtreeIfNeeded()
    var grid: CaptureGridKeyboardView?
    var sidebar: NSTableView?
    func walk(_ view: NSView) {
      if let view = view as? CaptureGridKeyboardView { grid = view }
      if let table = view as? NSTableView, table.numberOfRows == LibrarySection.allCases.count { sidebar = table }
      for child in view.subviews { walk(child) }
    }
    if let content = window.contentView { walk(content) }
    if args["focus"] as? String == "sidebar", let sidebar { window.makeFirstResponder(sidebar) }
    let gridRect = grid.map { $0.convert($0.bounds, to: nil) } ?? .zero
    return ["window": window.windowNumber, "visible": window.isVisible, "section": library.section.rawValue,
      "loadFailed": library.captures.loadFailed, "status": library.statusText,
      "selected": library.selectedIDs.sorted(), "pendingDelete": library.pendingCaptureDelete?.uuidString ?? "",
      "captureCount": library.captures.captures.count,
      "items": library.captureItems.prefix(256).map { ["id": $0.id.uuidString, "name": $0.fileName, "kind": $0.kind.rawValue] },
      "columns": grid?.columns ?? 0, "gridFocused": grid != nil && window.firstResponder === grid,
      "gridFrame": [gridRect.minX, window.frame.height - gridRect.maxY, gridRect.width, gridRect.height],
      "firstResponder": window.firstResponder.map { String(describing: type(of: $0)) } ?? "",
      "text": windowText(window), "opened": adapter.captureFileActions,
      "pasteboardHasImage": NSImage(pasteboard: .general) != nil] as [String: Any]
  }
}
#endif
