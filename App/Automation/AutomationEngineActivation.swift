#if OPEN_AUTOMATION
import OpenEngine

extension AutomationController {
  func engineActivationState(_ args: [String: Any]) throws -> Any {
    var state = OEBrowser.activationStateForAutomation(reset: args["reset"] as? Bool ?? false)
    state["expectedChromeWindowID"] = try window.focusedBrowser?.chromeWindowIdentifier ?? -1
    return state
  }

  func probeEngineCloseActivation() throws -> Any {
    guard let browser = try window.focusedBrowser else {
      throw Failure(message: "no engine Browser")
    }
    return browser.probeCloseActivationForAutomation()
  }
}
#endif
