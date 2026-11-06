import AppKit
import OpenFeatures

extension AppDelegate {
  func installLittleOpenPageClose(on coordinator: LittleOpenCoordinator) {
    coordinator.requestPageClose = { [weak self, weak coordinator] id, completion in
      #if OPEN_AUTOMATION
      if AutomationOwnerWatch.quittingWithoutPrompts { return false }
      #endif
      guard let self, !self.terminationRequested, let window = coordinator?.controllers[id]?.window,
            let host = self.littleOpenHosts.values.first(where: { $0.view.window === window }),
            let owner = host.owner else { return false }
      return owner.pageChrome.requestClose(host.content, completion: completion)
    }
  }
}
