#if OPEN_AUTOMATION
import AppKit
import OpenDesign
import OpenModel
import OpenSpaceEditor

extension AutomationController {
  func runSpaceEditorCommand(_ command: String, _ args: [String: Any]) async throws -> Any {
    let host = try window
    guard let browser = host.controller else { throw Failure(message: "no browser window") }
    switch command {
    case "theme-get":
      guard let space = (args["space"] as? String).flatMap({ raw in app.model.spaces.first { $0.id.description == raw } }) ?? host.focusedSpace else { throw Failure(message: "unknown Space") }
      return ["style": try space.theme.style.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()]
    case "creation-open": return browser.beginSpaceCreation()
    case "creation-close":
      if let editor = browser.spaceCreationController?.themeEditor { editor.close() }
      else { browser.spaceCreationController?.cancel() }
      return true
    case "creation-state":
      guard let creation = browser.spaceCreationController else { return ["open": false, "modelUndoGeneration": app.model.undoGeneration] }
      let form = creation.creationView
      let style = try creation.draftStyle.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()
      return ["open": true, "modelUndoGeneration": app.model.undoGeneration, "name": form.nameField.stringValue, "style": style,
        "icon": describeIcon(creation.draftIcon),
        "profile": creation.profilePicker.selectedProfileID?.description ?? "", "creatingProfile": creation.profilePicker.isCreatingProfile,
        "widthClass": form.widthClass.rawValue, "pinnedSubmit": form.submitIsPinned,
        "localUndo": creation.localUndoManager.canUndo, "modelUndo": app.undoManager.canUndo,
        "localUndoName": creation.localUndoManager.undoActionName, "localRedoName": creation.localUndoManager.redoActionName,
        "windowUndoMatches": browser.window?.undoManager === creation.localUndoManager,
        "nameUndoIsSeparate": form.nameField.currentEditor().map { $0.undoManager !== creation.localUndoManager } ?? false,
        "nameUndo": form.nameField.currentEditor()?.undoManager?.canUndo ?? false,
        "nameRedo": form.nameField.currentEditor()?.undoManager?.canRedo ?? false,
        "themeUndoMatches": creation.themeEditor?.panel.undoManager === creation.localUndoManager,
        "themeCommits": creation.themeEditor?.commitCount ?? 0,
        "themeOpen": creation.themeEditor != nil,
        "previewMatches": browser.background.targetStyle == form.style,
        "otherWindowsMatchModel": app.windowControllers.filter { $0 !== browser }.allSatisfy { controller in
          controller.context.focusedSpace.map { controller.background.targetStyle == controller.context.style(for: $0) } ?? true
        },
        "nameFocused": form.nameField.currentEditor() != nil] as [String: Any]
    case "creation-act":
      guard let creation = browser.spaceCreationController else { throw Failure(message: "no creation form") }
      let form = creation.creationView
      switch args["action"] as? String {
      case "key": return try await sendKey(args, host)
      case "click":
        switch args["control"] as? String {
        case "theme": form.themeButton.performClick(nil)
        case "icon": form.iconButton.performClick(nil)
        case "create": form.createButton.performClick(nil)
        case "cancel": form.cancelButton.performClick(nil)
        default: throw Failure(message: "unknown creation control")
        }
      case "profile":
        guard let name = args["name"] as? String,
              let index = form.profilePopup.itemTitles.firstIndex(of: name) else { throw Failure(message: "unknown creation Profile") }
        form.profilePopup.selectItem(at: index)
        if let action = form.profilePopup.action { NSApp.sendAction(action, to: form.profilePopup.target, from: form.profilePopup) }
      case "preset":
        guard let editor = creation.themeEditor, let index = args["index"] as? Int, (0..<9).contains(index) else { throw Failure(message: "no draft preset") }
        let strip = editor.panel.editorView.presets
        let point = CGPoint(x: 48 + CGFloat(index) * 29.5 + 12, y: 16)
        let location = strip.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
          let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: editor.panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
          editor.panel.sendEvent(event)
        }
        editor.flushPreviewFrame()
      default: throw Failure(message: "unknown creation action")
      }
      return true
    default: throw Failure(message: "unknown space editor command")
    }
  }
}
#endif
