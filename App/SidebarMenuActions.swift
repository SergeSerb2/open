import AppKit
import OpenModel
import OpenFeatures
import OpenSidebar

// AppKit's picker delegate predates actor annotations. This picker is created,
// shown and closed on the main thread; its callbacks stay on that thread.
extension EngineWebContentHostFactory: @preconcurrency NSSharingServicePickerDelegate, NSMenuDelegate {
  @discardableResult
  func shareSidebarTab(_ id: ItemID) -> Bool {
    guard !isClosing, let tab = model.tab(id: id), let sidebar = controller?.sidebar,
          sidebar.window != nil, let rect = sidebar.rowFrame(nodeID: id) ?? sidebar.favoriteFrame(tabID: id) else { return false }
    sidebarSharePicker?.close()
    // Closing a picker the copy toast opened releases that toast too.
    shareToastHandle?.hold(false); shareToastHandle = nil
    let picker = NSSharingServicePicker(items: [tab.url])
    sidebarSharePicker = picker; picker.delegate = self
    #if OPEN_AUTOMATION
    sidebarShareRequest = ["url": tab.url.absoluteString, "node": id.description,
      "anchor": [rect.minX, rect.minY, rect.width, rect.height], "requested": true,
      "servicesRequested": false, "closed": false]
    #endif
    picker.show(relativeTo: rect, of: sidebar, preferredEdge: .maxX)
    return true
  }

  func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, sharingServicesForItems items: [Any],
                            proposedSharingServices proposedServices: [NSSharingService]) -> [NSSharingService] {
    #if OPEN_AUTOMATION
    sidebarShareRequest["servicesRequested"] = true
    if dismissSidebarShareForAutomation {
      stopShareDismissalForAutomation()
      sidebarShareDismissAttemptsForAutomation = 0
      let pickerID = ObjectIdentifier(sharingServicePicker)
      // AppKit can ignore close() until its asynchronous picker presentation
      // finishes. This bounded automation-only timer also runs in nested loops.
      let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
        guard let self else { timer.invalidate(); return }
        MainActor.assumeIsolated {
          guard let picker = self.sidebarSharePicker, ObjectIdentifier(picker) == pickerID else {
            self.stopShareDismissalForAutomation(); return
          }
          self.sidebarShareDismissAttemptsForAutomation += 1
          picker.close()
          if self.sidebarShareDismissAttemptsForAutomation >= 100 { self.stopShareDismissalForAutomation() }
        }
      }
      sidebarShareDismissTimerForAutomation = timer
      for mode: RunLoop.Mode in [.default, .eventTracking, .modalPanel] { RunLoop.main.add(timer, forMode: mode) }
    }
    #endif
    return proposedServices
  }

  func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
    guard sidebarSharePicker === sharingServicePicker else { return }
    // A copy toast that opened this picker restarts its lifetime now.
    shareToastHandle?.hold(false); shareToastHandle = nil
    #if OPEN_AUTOMATION
    stopShareDismissalForAutomation()
    sidebarShareRequest["closed"] = true
    sidebarShareRequest["choseService"] = service != nil
    #endif
    // The delegate callback must not release the picker while AppKit uses it.
    DispatchQueue.main.async { [weak self, sharingServicePicker] in
      if self?.sidebarSharePicker === sharingServicePicker {
        self?.sidebarSharePicker = nil
        #if OPEN_AUTOMATION
        if self?.spaceProfileMenu == nil { self?.stopObservingSidebarMenusForAutomation() }
        #endif
      }
    }
  }

  @discardableResult
  func showSpaceProfileMenu() -> Bool {
    guard !isClosing, spaceProfileMenu == nil, let sidebar = controller?.sidebar,
          let rect = sidebar.spaceHeaderFrame, let menu = sidebar.profileMenu() else { return false }
    menu.delegate = self; spaceProfileMenu = menu
    #if OPEN_AUTOMATION
    profileMenuRequest = ["shown": false, "trackingBegan": false, "closed": false,
      "items": menu.items.filter { !$0.isSeparatorItem }.map { ["title": $0.title, "enabled": $0.isEnabled, "checked": $0.state == .on] }]
    if profileMenuResponseForAutomation != nil { observeSidebarMenusForAutomation() }
    #endif
    // Menu-bar dispatch must finish before tracking the header menu.
    DispatchQueue.main.async { [weak self, weak sidebar] in
      guard let self, let sidebar, !self.isClosing, self.spaceProfileMenu === menu else { return }
      menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY), in: sidebar)
      #if OPEN_AUTOMATION
      // Match normal AppKit dispatch: the chosen action runs after tracking,
      // never from inside the menuWillOpen/cancelTracking callback.
      if let choice = self.profileMenuResponseForAutomation, choice != "cancel",
         let index = menu.items.firstIndex(where: { $0.title == choice && $0.isEnabled }) {
        menu.performActionForItem(at: index)
        self.profileMenuRequest["chosen"] = choice
      }
      self.profileMenuRequest["closed"] = true
      #endif
      self.spaceProfileMenu = nil
      #if OPEN_AUTOMATION
      if self.sidebarSharePicker == nil { self.stopObservingSidebarMenusForAutomation() }
      #endif
    }
    return true
  }

  func menuWillOpen(_ menu: NSMenu) {
    guard spaceProfileMenu === menu else { return }
    #if OPEN_AUTOMATION
    profileMenuRequest["shown"] = true
    if let choice = profileMenuResponseForAutomation {
      profileMenuRequest["response"] = choice
    }
    #endif
  }

  #if OPEN_AUTOMATION
  func stopShareDismissalForAutomation() {
    sidebarShareDismissTimerForAutomation?.invalidate()
    sidebarShareDismissTimerForAutomation = nil
  }

  private func observeSidebarMenusForAutomation() {
    guard sidebarMenuTrackingObserverForAutomation == nil else { return }
    sidebarMenuTrackingObserverForAutomation = NotificationCenter.default.addObserver(
      forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
    ) { [weak self] note in
      let trackedMenuID = (note.object as? NSMenu).map(ObjectIdentifier.init)
      MainActor.assumeIsolated {
        guard let self else { return }
        // This callback runs inside AppKit's tracking loop. Queuing work on
        // the main dispatch queue can wait until that loop has already ended.
        if let menu = self.spaceProfileMenu, trackedMenuID == ObjectIdentifier(menu),
           self.profileMenuResponseForAutomation != nil {
          self.profileMenuRequest["trackingBegan"] = true
          // didBeginTracking is posted before AppKit enters its event loop.
          // Run the cancellation on that loop's next turn, not the GCD queue.
          RunLoop.main.perform(inModes: [.eventTracking, .modalPanel, .default]) { [weak self] in
            MainActor.assumeIsolated {
              guard let menu = self?.spaceProfileMenu, ObjectIdentifier(menu) == trackedMenuID else { return }
              menu.cancelTrackingWithoutAnimation()
            }
          }
        }
      }
    }
  }

  func stopObservingSidebarMenusForAutomation() {
    if let observer = sidebarMenuTrackingObserverForAutomation { NotificationCenter.default.removeObserver(observer) }
    sidebarMenuTrackingObserverForAutomation = nil
  }
  #endif
}

extension EngineWebContentHostFactory {
  @discardableResult
  func showRenameSpaceDialog() -> Bool {
    guard !isClosing, pendingRenameAlert == nil, let space = focusedSpace, let window,
          window.attachedSheet == nil else { return false }
    let alert = NSAlert(); alert.messageText = "Rename Space"
    alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
    let field = NSTextField(string: space.title ?? "")
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24); field.placeholderString = "Space name"
    // A single-line field consumes Return to send its action. Forward that
    // native action to the alert's Rename button so Return confirms the sheet.
    field.cell?.sendsActionOnEndEditing = false
    field.target = alert.buttons[0]; field.action = #selector(NSButton.performClick(_:))
    alert.accessoryView = field; pendingRenameAlert = alert
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }; self.pendingRenameAlert = nil
      guard !self.isClosing, !self.app.terminationRequested, response == .alertFirstButtonReturn,
            let current = self.model.space(id: space.id) else { return }
      let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard current.title != (trimmed.isEmpty ? nil : trimmed) else { return }
      self.app.undoManager.beginUndoGrouping()
      self.model.renameSpace(id: space.id, title: field.stringValue)
      self.app.undoManager.setActionName("Rename Space"); self.app.undoManager.endUndoGrouping()
      self.app.scheduleSave()
    }
    return true
  }
}

@MainActor
func makeSpaceProfileChangeAlert(_ request: ChangeProfileRequest) -> NSAlert {
  let alert = NSAlert(); alert.alertStyle = .warning
  alert.messageText = "Change Profile?"; alert.informativeText = request.warning
  alert.addButton(withTitle: "Change Profile"); alert.addButton(withTitle: "Cancel")
  alert.showsSuppressionButton = true; alert.suppressionButton?.title = "Don't show again"
  return alert
}

extension EngineWebContentHostFactory {
  @discardableResult
  func requestSpaceProfileChange(spaceID: SpaceID, profileID: ProfileID) -> Bool {
    guard let request = ChangeProfileRequest(spaceID: spaceID, toProfile: profileID, in: model),
          pendingSpaceProfileAlert == nil, let window, window.attachedSheet == nil else { return false }
    let apply: @MainActor () -> Void = { [weak self] in
      guard let self, !self.isClosing, !self.app.terminationRequested,
        self.model.space(id: spaceID)?.profileID == request.fromProfileID,
        self.model.profile(id: profileID) != nil else { return }
      self.app.undoManager.beginUndoGrouping()
      self.model.moveSpace(id: spaceID, toProfile: profileID)
      self.app.undoManager.setActionName("Change Profile")
      self.app.undoManager.endUndoGrouping()
      self.app.scheduleSave(); self.app.scheduleMenuRebuild()
    }
    let preferences = UserDefaults.standard
    if preferences.object(forKey: request.dontShowAgainKey) != nil && !preferences.bool(forKey: request.dontShowAgainKey) {
      apply(); return true
    }
    let alert = makeSpaceProfileChangeAlert(request)
    pendingSpaceProfileAlert = alert
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }; self.pendingSpaceProfileAlert = nil
      guard response == .alertFirstButtonReturn else { return }
      if alert.suppressionButton?.state == .on { preferences.set(false, forKey: request.dontShowAgainKey) }
      apply()
    }
    return true
  }
}
