#if OPEN_AUTOMATION
import AppKit

extension AutomationController {
  func runOnboarding(_ args: [String: Any]) async throws -> [String: Any] {
    let action = args["action"] as? String ?? "state"
    guard action.utf8.count <= 32, ["state", "skip-intro", "get-started", "replay-intro"].contains(action), Set(args.keys).isSubset(of: ["action"]) else {
      throw Failure(message: "unknown onboarding action or argument")
    }
    if action == "replay-intro" { app.showOnboarding(replay: true) }
    else if action != "state" {
      guard let controller = app.onboardingWindowController, controller.window?.isVisible == true else { throw Failure(message: "intro is not active") }
      if action == "skip-intro" { controller.intro.skip() }
      if action == "get-started" {
        guard controller.intro.ready else { throw Failure(message: "Get Started is not ready") }
        controller.intro.getStarted()
      }
    }
    var state = app.onboardingWindowController?.state ?? app.onboardingReceipt ?? ["active": false, "screen": "browser", "phase": "inactive"]
    state["moduleActive"] = app.onboardingActivated
    if app.firstRunWindowController != nil { state["screen"] = "first-run" }
    return state
  }
}
#endif
