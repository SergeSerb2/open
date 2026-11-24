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
      guard let creation = browser.spaceCreationController else {
        return ["open": false, "modelUndoGeneration": app.model.undoGeneration,
          "modelUndoName": app.undoManager.undoActionName, "modelRedoName": app.undoManager.redoActionName]
      }
      let form = creation.creationView
      let style = try creation.draftStyle.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()
      return ["open": true, "modelUndoGeneration": app.model.undoGeneration, "name": form.nameField.stringValue, "style": style,
        "icon": describeIcon(creation.draftIcon),
        "profile": creation.profilePicker.selectedProfileID?.description ?? "", "creatingProfile": creation.profilePicker.isCreatingProfile,
        "profilePopupVisible": !form.profilePopup.isHiddenOrHasHiddenAncestor,
        "profileMenuTitle": form.profilePopup.titleOfSelectedItem ?? "",
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
        "themeKey": creation.themeEditor?.panel.isKeyWindow ?? false,
        "windowActive": browser.context.isWindowActive, "backgroundActive": browser.background.isWindowActive,
        // Composited placement, not native frames: pages move by layer translation (UX round 1 C1).
        "visible": browser.window?.isVisible == true && !form.isHiddenOrHasHiddenAncestor
          && (creationLayerRects(form, in: browser.contentView).presentation.map { $0.intersection(browser.contentView.bounds).width > 0 } ?? false)
          && form.convert(form.bounds, to: browser.contentView).intersection(browser.contentView.bounds).width > 0,
        "previewMatches": browser.background.targetStyle == form.style,
        "otherWindowsMatchModel": app.windowControllers.filter { $0 !== browser }.allSatisfy { controller in
          controller.context.focusedSpace.map { controller.background.targetStyle == controller.context.style(for: $0) } ?? true
        },
        "nameFocused": form.nameField.currentEditor() != nil,
        // What the window server composites: the form's rect through the presentation layer tree
        // (page strips move pages by layer translation, so native frames alone cannot see it).
        "layers": creationLayerState(form, in: browser.contentView),
        "systemAppearance": form.systemAppearance.rawValue, "formAppearance": form.appearance?.name.rawValue ?? ""] as [String: Any]
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

  private func creationLayerState(_ form: NSView, in root: NSView) -> [String: Any] {
    func tx(_ layer: CALayer?) -> Any {
      guard let value = (layer?.value(forKeyPath: "transform.translation.x") as? NSNumber)?.doubleValue, value.isFinite else { return NSNull() }
      return value
    }
    var chain: [[String: Any]] = []
    var view: NSView? = form
    while let current = view, current !== root.superview {
      let layer = current.layer, shown = layer?.presentation()
      chain.append(["class": String(describing: type(of: current)), "hidden": current.isHidden,
        "layerHidden": layer?.isHidden ?? false, "opacity": Double(layer?.opacity ?? -1),
        "presentationOpacity": Double(shown?.opacity ?? -1), "tx": tx(layer), "presentationTx": tx(shown),
        "frame": [current.frame.minX, current.frame.minY, current.frame.width, current.frame.height]])
      view = current.superview
    }
    func list(_ r: CGRect?) -> [Double] {
      guard let r, [r.minX, r.minY, r.width, r.height].allSatisfy(\.isFinite) else { return [] }
      return [r.minX, r.minY, r.width, r.height]
    }
    let rects = creationLayerRects(form, in: root)
    return ["chain": chain, "presentationRectInRoot": list(rects.presentation), "modelRectInRoot": list(rects.model),
            "rootBounds": [root.bounds.width, root.bounds.height]]
  }

  /// The form's rect in the root view through the layer trees. The presentation rect is converted
  /// only inside the presentation tree (both layers must have one); otherwise it is the model rect.
  private func creationLayerRects(_ form: NSView, in root: NSView) -> (model: CGRect?, presentation: CGRect?) {
    guard let formLayer = form.layer, let rootLayer = root.layer else { return (nil, nil) }
    let model = rootLayer.convert(formLayer.bounds, from: formLayer)
    guard let shownForm = formLayer.presentation(), let shownRoot = rootLayer.presentation() else { return (model, model) }
    return (model, shownRoot.convert(shownForm.bounds, from: shownForm))
  }
}
#endif
