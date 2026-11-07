#if OPEN_AUTOMATION
import AppKit
import OpenModel
import OpenSettings
import OpenSpaceEditor

extension AutomationController {
  /// The real Settings presenter, native text field and AX buttons. These
  /// commands never call the model delete or disk cleanup directly.
  func profilesShell(_ args:[String:Any]) async throws -> [String:Any] {
    let adapter=app.settingsPresenter, vm=adapter.settings.profiles
    if let raw=args["profile"] as? String, let profile=app.model.profiles.first(where:{$0.id.description == raw || $0.name == raw}) {
      vm.select(profile.id)
    }
    switch args["action"] as? String ?? "state" {
    case "state":break
    case "show":adapter.show(pane:.profiles)
    case "create":
      guard let name=args["name"] as? String, name.utf8.count <= 1024, vm.create(name:name) != nil else { throw Failure(message:"could not create fixture Profile") }
    case "notice-ok":app.missingProfileNotice?.buttons.first?.performClick(nil)
    case "cancel":
      vm.confirmsDelete=false;vm.confirmsUnused=false;vm.showsCreate=false;vm.showsSuggestNotice=false
      adapter.profileIconPicker?.close()
    case "press":
      guard let label=args["label"] as? String, let owner=adapter.settingsPresenter.window,
        let control=profileAX(owner.attachedSheet ?? owner,label:label) else { throw Failure(message:"Profile control not found") }
      let press=NSSelectorFromString("accessibilityPerformPress")
      guard control.responds(to:press) else { throw Failure(message:"Profile control has no press action") }
      _=control.perform(press)
    case "type-delete":
      guard let text=args["text"] as? String, text.utf8.count <= 1024,
        let sheet=adapter.settingsPresenter.window?.attachedSheet,
        let content=sheet.contentView, let field=profileEditableField(content) else { throw Failure(message:"Profile confirmation field not found") }
      sheet.makeFirstResponder(field);field.selectText(nil)
      _=try await sendKey(["window":sheet.windowNumber,"text":text,"route":"app"],app.frontWindowController.flatMap { app.hostFactories[$0.windowID] })
    case "icon-symbol":
      guard let picker=adapter.profileIconPicker else {throw Failure(message:"Profile icon picker not open")}
      picker.view.pages.selectedSegment=1
      if let action=picker.view.pages.action {NSApp.sendAction(action,to:picker.view.pages.target,from:picker.view.pages)}
      try await Task.sleep(for:.milliseconds(30));picker.view.layoutSubtreeIfNeeded()
      guard let rect=picker.view.controlFrame("item",index:args["index"] as? Int ?? 0) else {throw Failure(message:"Profile icon cell not found")}
      let point=picker.view.convert(CGPoint(x:rect.midX,y:rect.midY),to:nil)
      _=try await mouse(["action":"click","window":picker.panel.windowNumber,"x":Double(point.x),"y":Double(picker.panel.frame.height-point.y),"queued":true],try window)
    case "page":
      guard let raw=args["page"] as? String, let page=ProfilePage(rawValue:raw) else {throw Failure(message:"unknown Profile page")}
      vm.open(page)
    case "open-url":
      guard let raw=args["url"] as? String,raw.utf8.count <= 8192,let url=URL(string:raw) else {throw Failure(message:"invalid Profile URL")}
      adapter.openURL(url,profileID:adapter.settings.selectedProfileID)
    case "indicator-menu":
      guard let view=profileIndicatorViews().first else {throw Failure(message:"no visible Profile indicator")}
      profileIndicatorMenuTitles=[]
      let observer=NotificationCenter.default.addObserver(forName:NSMenu.didBeginTrackingNotification,object:nil,queue:.main) { [weak self] note in
        // NotificationCenter guarantees this observer's delivery on .main.
        // NSMenu's SDK annotation is not Sendable across assumeIsolated.
        nonisolated(unsafe) let menu=note.object as? NSMenu
        MainActor.assumeIsolated {
          guard let menu else {return}
          self?.profileIndicatorMenuTitles=menu.items.map(\.title)
          nonisolated(unsafe) let trackingMenu=menu
          let timer=Timer(timeInterval:0.05,repeats:false) { _ in
            MainActor.assumeIsolated { trackingMenu.cancelTrackingWithoutAnimation() }
          }
          RunLoop.main.add(timer,forMode:.eventTracking)
        }
      }
      // The timer runs in the menu's nested tracking loop, which does not
      // service an ordinary main-queue async block on this AppKit version.
      defer {NotificationCenter.default.removeObserver(observer)}
      _=view.accessibilityPerformPress()
    default:throw Failure(message:"unknown Profiles shell action")
    }
    await Task.yield()
    let owner=adapter.settingsPresenter.window, sheet=owner?.attachedSheet
    let delete=sheet.flatMap {profileAX($0,label:"Delete")}
    let enabled:Bool?=delete.flatMap {object in
      if let element=object as? any NSAccessibilityProtocol { return element.isAccessibilityEnabled() }
      if object.responds(to:NSSelectorFromString("isAccessibilityEnabled")) {
        return (object as AnyObject).isAccessibilityEnabled?()
      }
      let selector=NSSelectorFromString("accessibilityAttributeValue:")
      guard object.responds(to:selector) else {return nil}
      return object.perform(selector,with:"AXEnabled")?.takeUnretainedValue() as? Bool
    }
    return ["profiles":app.model.profiles.map { profile -> [String:Any] in
      ["id":profile.id.description,"name":profile.name,"directory":profile.dataDirectoryName,"spaces":app.model.spaces(using:profile.id).count,
       "icon":String(describing:profile.icon),"loaded":app.profileTeardown.wasLoaded(profile.id)]
    },"rows":vm.dataModel.rows.map(\.name),"unused":vm.unusedIDs.map(\.description),
      "deleting":vm.deleting,"deleteEnabled":vm.canConfirmDelete,"deleteAXEnabled":enabled as Any? ?? NSNull(),
      "deleteAXClass":delete.map {String(reflecting:type(of:$0))} ?? "",
      "deleteText":vm.deleteConfirmation,"deleteNames":vm.deletionProfiles.map(\.name),
      "sheet":sheet?.windowNumber ?? 0,"sheetText":sheet.map(windowText) ?? [],"settings":owner?.windowNumber ?? 0,
      "error":vm.errorText,"canUndo":app.undoManager.canUndo,
      "noticeShown":app.missingProfileNoticeCount,"noticeTitles":app.missingProfileNoticeTitles,
      "noticeVisible":app.missingProfileNotice?.window.isVisible ?? false,
      "iconPicker":adapter.profileIconPicker?.isClosed == false,"indicatorMenu":profileIndicatorMenuTitles,
      "managerIndicators":profileIndicatorViews(in:adapter.libraryPresenter?.window?.contentView,identifier:"spaceManagerSpaceHeaderIndicator").map { $0.accessibilityLabel() ?? "" },
      "indicators":profileIndicatorViews().map {view in
        ["label":view.accessibilityLabel() ?? "","id":view.accessibilityIdentifier() ?? "",
         "frame":[view.frame.minX,view.frame.minY,view.frame.width,view.frame.height]] as [String:Any]
      }]
  }

  private func profileEditableField(_ view:NSView)->NSTextField? {
    if let field=view as? NSTextField,field.isEditable {return field}
    for child in view.subviews {if let result=profileEditableField(child) {return result}}
    return nil
  }
  private func profileIndicatorViews()->[NSView] {
    profileIndicatorViews(in:app.frontWindowController?.sidebar,identifier:"space-profile-indicator")
  }
  private func profileIndicatorViews(in root:NSView?,identifier:String)->[NSView] {
    guard let root else {return []}
    root.layoutSubtreeIfNeeded()
    var result:[NSView]=[]
    func walk(_ view:NSView) {
      guard !view.isHiddenOrHasHiddenAncestor else {return}
      if view.accessibilityIdentifier() == identifier {result.append(view)}
      for child in view.subviews {walk(child)}
    }
    walk(root);return result
  }
  private func profileAX(_ root:NSObject,label:String)->NSObject? {
    let write=NSSelectorFromString("accessibilitySetValue:forAttribute:")
    if NSApp.responds(to:write) {NSApp.perform(write,with:NSNumber(value:true),with:"AXEnhancedUserInterface")}
    var seen=Set<ObjectIdentifier>()
    func walk(_ object:NSObject,depth:Int)->NSObject? {
      guard depth <= 24,seen.count < 4096,seen.insert(ObjectIdentifier(object)).inserted else {return nil}
      if let view=object as? NSView,view.isHiddenOrHasHiddenAncestor {return nil}
      for name in ["accessibilityLabel","accessibilityTitle","accessibilityHelp","accessibilityValue"] {
        let selector=NSSelectorFromString(name)
        if object.responds(to:selector),object.perform(selector)?.takeUnretainedValue() as? String == label {return object}
      }
      let selector=NSSelectorFromString("accessibilityChildren")
      if object.responds(to:selector),let children=object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
        for child in children.prefix(4096) {if let found=walk(child,depth:depth+1) {return found}}
      }
      if let view=object as? NSView {for child in view.subviews {if let found=walk(child,depth:depth+1) {return found}}}
      if let window=object as? NSWindow,let content=window.contentView {return walk(content,depth:depth+1)}
      return nil
    }
    return walk(root,depth:0)
  }
}
#endif
