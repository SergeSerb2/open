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
