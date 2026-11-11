#if OPEN_AUTOMATION
import AppKit
import OpenSettings
import OpenLibrary

extension AutomationController {
  func libraryPanelAction(_ args: [String:Any]) throws -> [String:Any] {
    let adapter = app.settingsPresenter
    let action = args["action"] as? String ?? "state"
    if let number = args["window"] as? Int {
      guard let controller = app.windowControllers.first(where: { $0.window?.windowNumber == number }) else { throw Failure(message:"unknown browser window") }
      controller.window?.makeKeyAndOrderFront(nil)
    }
    switch action {
    case "open":
      let section = (args["section"] as? String).flatMap(LibrarySection.init(rawValue:))
      adapter.showLibrary(section:section)
    case "close": adapter.closeLibrary()
    case "toggle": adapter.toggleLibrary()
    case "state": break
    default:
      guard let session=adapter.activeLibrarySession, session.controller?.isLibraryOpen == true, let panel=session.panel else { throw Failure(message:"Library panel is closed") }
      switch action {
      case "select", "section":
        guard let raw=args["section"] as? String, let section=LibraryPanelSection(rawValue:raw), panel.sections.contains(section) else { throw Failure(message:"unknown or hidden section") }
        panel.select(section)
      case "search": panel.setSearch(args["text"] as? String ?? "")
      case "focus-rail": panel.focusRail()
      case "hover-tile":
        guard let raw=args["section"] as? String, let section=LibraryPanelSection(rawValue:raw) else { throw Failure(message:"unknown section") }
        panel.hoverTile(section,hovered:args["hovered"] as? Bool ?? true)
      case "back": panel.pressBack()
      case "refresh": panel.refresh()
      case "resize":
        guard let width=args["width"] as? Double, let height=args["height"] as? Double,
          width.isFinite,height.isFinite,width>=640,height>=480,width<=4096,height<=4096,let window=session.controller?.window else { throw Failure(message:"invalid window size") }
        var frame=window.frame;frame.size=CGSize(width:width,height:height);window.setFrame(frame,display:true)
        session.controller?.libraryWidth=panel.section == .spaces ? width-56 : 417
        session.controller?.layoutContent()
      default: throw Failure(message:"Library action is unavailable at L1: \(action)")
      }
    }
    guard let session=adapter.activeLibrarySession,let controller=session.controller else {
      return ["open":false,"created":false,"window":0,"rows":[],"rail":[]]
    }
    var state=session.panel?.automationState() ?? [:]
    state["open"]=controller.isLibraryOpen
    state["created"]=true
    state["window"]=controller.window?.windowNumber ?? 0
    state["windowID"]=controller.windowID.description
    state["pageCardFrame"]=[controller.container.frame.minX,controller.container.frame.minY,controller.container.frame.width,controller.container.frame.height]
    state["showSetupMilliseconds"]=session.lastShowMilliseconds
    state["sidebarWidth"]=controller.context.sidebarWidth
    state["sidebarMode"]=controller.context.window?.sidebarMode.rawValue ?? ""
    return state
  }
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
