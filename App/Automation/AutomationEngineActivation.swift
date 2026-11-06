#if OPEN_AUTOMATION
import OpenEngine

extension AutomationController {
  func probeEngineCloseActivation() throws -> Any {
    guard let browser = try window.focusedBrowser else {
      throw Failure(message: "no engine Browser")
    }
    return browser.probeCloseActivationForAutomation()
  }
}
#endif
