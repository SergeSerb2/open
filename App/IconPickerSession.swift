import AppKit
import OpenModel
import OpenSpaceEditor

extension EngineWebContentHostFactory {
  @discardableResult
  func openSpaceIconPicker(_ id: SpaceID) -> Bool {
    guard let space = model.space(id: id), let controller, let window, !isClosing else { return false }
    iconPicker?.close()
    if focusedSpace?.id != id { focus(space: space) } // focus has no undo step
    controller.sidebar.layoutSubtreeIfNeeded()
    let anchor = controller.sidebar.headerIconFrame(for: id) ?? fallbackIconAnchor()
    let picker = IconPickerController(target: .space, current: space.icon, window: window, anchor: anchor) { [weak self] icon in
      guard let self, self.model.space(id: id) != nil else { return }
      guard self.model.space(id: id)?.icon != icon else { return }
      self.withIconUndo(name: "Customize Space") { self.model.setSpaceIcon(id: id, icon: icon); return true }
      self.app.scheduleSave(); self.app.scheduleMenuRebuild()
    }
    presentIconPicker(picker, space: id); return true
  }

  @discardableResult
  func openNodeIconPicker(_ id: ItemID) -> Bool {
    guard let node = model.node(id: id), let controller, let window, !isClosing,
          node.tab != nil || node.folder != nil else { return false }
    iconPicker?.close()
    if let space = space(containing: id), focusedSpace?.id != space.id { focus(space: space) }
    controller.sidebar.layoutSubtreeIfNeeded()
    // Choice for the lead: hidden/collapsed rows use the header anchor. Opening
    // a picker never changes expansion, scroll position, or sidebar selection.
    let anchor = controller.sidebar.rowIconFrame(for: id) ?? fallbackIconAnchor()
    let target: IconTarget = node.folder == nil ? .tab : .folder
    let current = node.tab?.iconOverride ?? node.folder?.iconOverride
      ?? (node.tab?.customIcon ?? node.folder?.customIcon).map { SpaceIcon.emoji($0) }
    let picker = IconPickerController(target: target, current: current, window: window, anchor: anchor) { [weak self] icon in
      guard let self, self.model.node(id: id) != nil else { return }
      if self.withIconUndo(name: target == .folder ? "Customize Folder" : "Customize Tab", apply: {
        self.model.setNodeIcon(id: id, icon: icon)
      }) { self.app.scheduleSave() }
    }
    presentIconPicker(picker, space: focusedSpace?.id); return true
  }

  @discardableResult
  private func withIconUndo(name: String, apply: () -> Bool) -> Bool {
    let undo = model.undoManager
    undo?.beginUndoGrouping()
    defer { undo?.endUndoGrouping() }
    let changed = apply()
    if changed { undo?.setActionName(name) }
    return changed
  }

  private func fallbackIconAnchor() -> CGRect {
    guard let sidebar = controller?.sidebar else { return .zero }
    if let id = focusedSpace?.id, let header = sidebar.headerIconFrame(for: id) { return header }
    let frame = sidebar.convert(sidebar.bounds, to: nil)
    return CGRect(x: frame.minX + 16, y: frame.maxY - 48, width: 20, height: 20)
  }

  private func presentIconPicker(_ picker: IconPickerController, space: SpaceID?) {
    iconPicker = picker; iconPickerSpaceID = space
    picker.onClose = { [weak self, weak picker] in
      guard let self, self.iconPicker === picker else { return }
      self.iconPicker = nil; self.iconPickerSpaceID = nil
    }
    picker.show()
  }
}
