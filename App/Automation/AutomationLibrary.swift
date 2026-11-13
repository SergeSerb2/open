#if OPEN_AUTOMATION
import AppKit
import ObjectiveC
import OpenSettings
import OpenLibrary
import OpenOnboarding

extension AutomationController {
  func libraryPanelAction(_ args: [String:Any]) throws -> [String:Any] {
    let adapter = app.settingsPresenter
    let action = args["action"] as? String ?? "state"
    var probeHit: String?
    if let number = args["window"] as? Int {
      guard let controller = app.windowControllers.first(where: { $0.window?.windowNumber == number }) else { throw Failure(message:"unknown browser window") }
      controller.window?.makeKeyAndOrderFront(nil)
    }
    switch action {
    case "trace-start":
      IntroPacingTrace.current?.finish()
      let trace = IntroPacingTrace()
      trace.start(at:CACurrentMediaTime())
      IntroPacingTrace.current = trace
      return ["started":true]
    case "trace-stop":
      let now = CACurrentMediaTime()
      guard let intervals = args["intervals"] as? [[Double]], intervals.count <= 128,
        intervals.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) && $0[0] >= now-60 && $0[0] < $0[1] && $0[1] <= now })
      else { throw Failure(message:"expected at most 128 recent frame intervals") }
      guard let trace = IntroPacingTrace.current else { throw Failure(message:"Library trace is not active") }
      for interval in intervals { trace.recordInterval(start:interval[0],end:interval[1],nominal:1/120,callback:now) }
      trace.finish()
      let state = trace.state
      IntroPacingTrace.current = nil
      return state
    case "prebuild-state":
      let controller = app.frontStandardWindowController
      return ["ready":adapter.activeLibrarySession?.panel?.prebuiltReady ?? false,
        "section":adapter.activeLibrarySession?.panel?.section.rawValue ?? "",
        "firstSidebarDraw":controller.flatMap { app.libraryFirstSidebarDraws[$0.windowID] } ?? 0,
        "lastInput":app.libraryLastInput,"builtAt":app.libraryPrebuiltAt ?? 0]
    case "sessions":
      return ["closedPanelAlive":adapter.lastClosedLibraryPanel != nil,"sessions":adapter.librarySessions.values.map { session in
        ["controllerAlive":session.controller != nil,"panelAlive":session.panel != nil] as [String:Any]
      }]
    case "open":
      var section: LibraryPanelSection?
      if let raw=args["section"] as? String {
        guard let parsed=LibraryPanelSection(rawValue:raw == "captures" ? "media" : raw), LibraryPanelSection.visible(in:.standard).contains(parsed) else { throw Failure(message:"unknown or hidden Library section") }
        section=parsed
      }
      adapter.showLibrary(section:section?.modelSection ?? (section == .easels ? .media : nil))
      if section == .easels { adapter.activeLibrarySession?.panel?.select(.easels) }
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
      case "save-panel":
        guard let sheet = session.controller?.window?.attachedSheet as? NSSavePanel else { throw Failure(message:"Library save panel is not open") }
        let cancel = args["cancel"] as? Bool ?? false
        let path = args["path"] as? String
        guard cancel || (path?.hasPrefix("/") == true && (path?.utf8.count ?? 4097) <= 4096 && path?.contains("\0") == false) else { throw Failure(message:"expected an absolute save path") }
        let selector = NSSelectorFromString("completeWithReturnCode:url:urls:")
        guard let method = class_getInstanceMethod(type(of:sheet),selector), let types = method_getTypeEncoding(method), String(cString:types) == "v40@0:8q16@24@32" else { throw Failure(message:"save panel URL input unavailable") }
        typealias Complete = @convention(c) (AnyObject,Selector,Int,NSURL?,NSArray?) -> Void
        let complete = unsafeBitCast(method_getImplementation(method),to:Complete.self)
        let url = cancel ? nil : path.map { URL(fileURLWithPath:$0) }
        complete(sheet,selector,cancel ? NSApplication.ModalResponse.cancel.rawValue : NSApplication.ModalResponse.OK.rawValue,url as NSURL?,url.map { [$0 as NSURL] as NSArray })
      case "release-delay":
        guard let delay = args["seconds"] as? Double, delay.isFinite, delay >= 0.1, delay <= 60 else { throw Failure(message:"release delay must be 0.1...60 seconds") }
        session.releaseDelay = delay
      case "filter": panel.setFilterOpen(args["open"] as? Bool ?? true)
      case "chip":
        guard let id = args["id"] as? String, panel.toggleChip(id) else { throw Failure(message:"unknown filter chip") }
      case "focus-list": panel.focusList()
      case "easels-export":
        // "Export All Easels →" on the Easels card, as a click.
        guard panel.pressExportAllEasels() else { throw Failure(message:"Export All Easels is not available") }
      case "row-select":
        guard let id = args["id"] as? String, panel.selectRow(id) else { throw Failure(message:"unknown row") }
      case "hover-row":
        guard let id = args["id"] as? String, panel.hoverRow(id,hovered:args["hovered"] as? Bool ?? true) else { throw Failure(message:"row is not visible") }
      case "row-action":
        guard let id = args["id"] as? String, let name = args["name"] as? String, panel.performRow(id,action:name) else { throw Failure(message:"row action unavailable") }
      case "row-menu":
        guard let id = args["id"] as? String, let menu = panel.rowMenu(id,select:args["select"] as? String) else { throw Failure(message:"row menu unavailable") }
        return ["items":menu]
      case "row-right-click":
        guard let id = args["id"] as? String, let result = panel.rightClickRow(id) else { throw Failure(message:"unknown row") }
        return ["menu": result.titles.map { $0 as Any } ?? NSNull(), "selected": result.selected]
      case "show-row-menu":
        guard let id = args["id"] as? String, panel.showRowMenu(id,escapeOnOpen:args["escape"] as? Bool ?? false) else { throw Failure(message:"row menu unavailable") }
      case "row-drag-session":
        guard let id = args["id"] as? String, panel.selectRow(id), let target = session.controller?.window,
          let row = (panel.automationState()["rows"] as? [[String:Any]])?.first(where: { $0["id"] as? String == id }),
          let box = row["frame"] as? [CGFloat], panel.dragPayload(id) != nil else { throw Failure(message:"row is not draggable") }
        let start = panel.convert(CGPoint(x:box[0]+30,y:box[1]+box[3]/2),to:nil)
        probeHit = target.contentView?.superview?.hitTest(start).map { String(describing:type(of:$0)) }
        func event(_ type:NSEvent.EventType,_ point:CGPoint) -> NSEvent? {
          NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
            windowNumber:target.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:type == .leftMouseUp ? 0 : 1)
        }
        let end = CGPoint(x:start.x+480,y:start.y+12)
        guard let down = event(.leftMouseDown,start), let initial = event(.leftMouseDragged,CGPoint(x:start.x+16,y:start.y)),
          let drag = event(.leftMouseDragged,end), let up = event(.leftMouseUp,end) else { throw Failure(message:"could not create drag events") }
        DispatchQueue.main.async {
          NSApp.postEvent(initial,atStart:false); NSApp.postEvent(drag,atStart:false); NSApp.postEvent(up,atStart:false)
          NSApp.sendEvent(down)
        }
      case "row-drag":
        guard let id = args["id"] as? String, let payload = panel.dragPayload(id) else { throw Failure(message:"row is not draggable") }
        return payload
      case "boost-layout": panel.setBoostLayout(args["name"] as? String ?? "List")
      case "focus-rail": panel.focusRail()
      case "hover-tile":
        guard let raw=args["section"] as? String, let section=LibraryPanelSection(rawValue:raw) else { throw Failure(message:"unknown section") }
        panel.hoverTile(section,hovered:args["hovered"] as? Bool ?? true)
      case "back": panel.pressBack()
      case "empty-button": guard panel.pressEmptyButton() else { throw Failure(message:"empty-state button is not available") }
      case "refresh": panel.refresh()
      case "resize":
        guard let width=args["width"] as? Double, let height=args["height"] as? Double,
          width.isFinite,height.isFinite,width>=640,height>=480,width<=4096,height<=4096,let window=session.controller?.window else { throw Failure(message:"invalid window size") }
        var frame=window.frame;frame.size=CGSize(width:width,height:height);window.setFrame(frame,display:true)
        session.controller?.libraryWidth=panel.section == .spaces ? width-56 : 417
        session.controller?.layoutContent()
      default: throw Failure(message:"Library action is unavailable: \(action)")
      }
    }
    guard let session=adapter.activeLibrarySession,let controller=session.controller else {
      return ["open":false,"created":false,"window":0,"rows":[],"rail":[]]
    }
    var state=session.panel?.automationState() ?? [:]
    state["prebuiltReady"] = session.panel?.prebuiltReady ?? false
    state["prebuild"] = ["firstSidebarDraw":app.libraryFirstSidebarDraws[controller.windowID] ?? 0,"lastInput":app.libraryLastInput,"builtAt":app.libraryPrebuiltAt ?? 0,"pending":app.libraryPrebuildTask != nil] as [String:Any]
    state["performance"] = session.panel?.performanceCounters ?? [:]
    state["open"]=controller.isLibraryOpen
    state["created"]=true
    state["panelCreated"]=session.panel != nil
    state["releasedPanelAlive"]=session.releasedPanel != nil
    state["panelGeneration"]=session.panelGeneration
    state["releaseDelay"]=session.releaseDelay
    state["releaseClock"] = ["scheduledAt":session.releaseScheduledAt,"firedAt":session.releaseFiredAt,"pending":session.releasePending] as [String:Any]
    state["key"]=controller.window?.isKeyWindow ?? false
    state["window"]=controller.window?.windowNumber ?? 0
    state["windowID"]=controller.windowID.description
    if let probeHit { state["dragStartHit"] = probeHit }
    state["pageCardFrame"]=[controller.container.frame.minX,controller.container.frame.minY,controller.container.frame.width,controller.container.frame.height]
    state["showSetupMilliseconds"]=session.lastShowMilliseconds
    state["sidebarWidth"]=controller.context.sidebarWidth
    state["sidebarMode"]=controller.context.window?.sidebarMode.rawValue ?? ""
    func motion(_ layer: CALayer?) -> [String:Any] {
      guard let layer else { return [:] }
      func rect(_ value: CGRect) -> [CGFloat] { [value.minX,value.minY,value.width,value.height] }
      return ["frame":rect(layer.frame),"presentation":rect(layer.presentation()?.frame ?? layer.frame),
        "localTime":layer.convertTime(CACurrentMediaTime(),from:nil),"speed":layer.speed,
        "animations":(layer.animationKeys() ?? []).compactMap { key -> [String:Any]? in
          guard let animation=layer.animation(forKey:key) else { return nil }
          return ["key":key,"duration":animation.duration,"beginTime":animation.beginTime,
            "speed":animation.speed,"repeatCount":animation.repeatCount,"removedOnCompletion":animation.isRemovedOnCompletion,
            "properties":((animation as? CAAnimationGroup)?.animations ?? [animation]).compactMap { ($0 as? CAPropertyAnimation)?.keyPath }]
        }]
    }
    state["motion"]=["page":motion(controller.container.layer),"panel":motion(session.panel?.layer),
      "sidebar":motion(controller.sidebar.layer),"occlusion":controller.window?.occlusionState.rawValue ?? 0,
      "snapshotCount":controller.libraryMotionSnapshotCount,
      "snapshotLiveViewsHidden":controller.libraryMotionLiveViewsHidden,
      "snapshotStatus":controller.container.librarySnapshotStatus,
      "preparingClose":controller.isPreparingLibraryClose,
      "timing":["start":controller.libraryMotionStartedAt,"end":controller.libraryMotionEndsAt,
        "layoutCommit":controller.libraryLayoutCommittedAt,"opening":controller.libraryMotionOpening] as [String:Any]] as [String:Any]
    return state
  }
  /// Read the real Library and its hosted grid. The only focus setup is the
  /// source list; Tab must reach the grid through the normal App event path.
  func libraryCapturesState(_ args: [String: Any]) throws -> [String: Any] {
    let adapter = app.settingsPresenter
    guard let library = adapter.library, let window = adapter.libraryWindow else {
      throw Failure(message: "Library not open")
    }
    if let record = args["recordFileActions"] as? Bool { adapter.recordCaptureFileActions = record }
    if let panel = adapter.activeLibrarySession?.panel, panel.isPresented {
      if args["focus"] as? String == "sidebar" { panel.focusRail() }
      let s = panel.automationState()
      return ["window":window.windowNumber,"visible":window.isVisible,"section":library.section.rawValue,
        "loadFailed":library.captures.loadFailed,"status":library.statusText,"selected":library.selectedIDs.sorted(),
        "pendingDelete":library.pendingCaptureDelete?.uuidString ?? "","captureCount":library.captures.captures.count,
        "items":library.captureItems.prefix(256).map { ["id":$0.id.uuidString,"name":$0.fileName,"kind":$0.kind.rawValue] },
        "columns":1,"gridFocused":panel.listFocused,"gridFrame":[112,56,304,max(0,panel.bounds.height-56)],
        "firstResponder":s["firstResponder"] ?? "","text":windowText(window),"opened":adapter.captureFileActions,
        "pasteboardHasImage":NSImage(pasteboard:.general) != nil] as [String:Any]
    }
    throw Failure(message:"Library panel is not visible")
  }
}
#endif
