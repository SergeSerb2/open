#if OPEN_AUTOMATION
import AppKit
import OpenDesign
import OpenSettings

extension AutomationController {
  func runOnboarding(_ args: [String: Any]) async throws -> [String: Any] {
    let action = args["action"] as? String ?? "state"
    let allowed: [String: Set<String>] = ["state": [], "skip-intro": [], "get-started": [], "replay-intro": [], "next": [], "back": [], "skip": [], "set-name": ["name"], "toggle-favorite": ["index"], "set-theme": ["preset"], "set-blocker": ["on"], "choose-default": ["yes"], "shuffle-card": []]
    guard let extra = allowed[action], Set(args.keys).isSubset(of: extra.union(["action"])) else { throw Failure(message: "unknown onboarding action or argument") }
    if action == "replay-intro" { app.showOnboarding(replay: true) }
    else if action != "state" {
      guard let controller = app.onboardingWindowController, controller.window?.isVisible == true else { throw Failure(message: "onboarding is not active") }
      if let steps = controller.steps {
        guard !steps.finishing, !steps.firstRun.busy, !steps.defaultPending else { throw Failure(message: "onboarding is busy") }
        switch action {
        case "next": guard steps.step != .ready else { throw Failure(message: "use get-started on Ready") }; steps.next()
        case "get-started": guard steps.step == .ready else { throw Failure(message: "not on Ready") }; steps.next()
        case "back": steps.back()
        case "skip": guard [.name, .importData, .favorites, .theme, .blocker].contains(steps.step) else { throw Failure(message: "this step cannot be skipped") }; steps.skip()
        case "set-name": guard steps.step == .name, let name = args["name"] as? String, name.count <= 40 else { throw Failure(message: "name must be at most 40 characters on Name") }; steps.setName(name)
        case "toggle-favorite": guard steps.step == .favorites, let index = args["index"] as? Int, OnboardingStepsController.sites.indices.contains(index) else { throw Failure(message: "favorite index out of range or not on Favorites") }; steps.toggleFavorite(index)
        case "set-theme": guard steps.step == .theme, let index = args["preset"] as? Int, SpaceStylePresets.all.indices.contains(index) else { throw Failure(message: "theme preset out of range or not on Theme") }; steps.editTheme(.selectPreset(index: index))
        case "set-blocker": guard steps.step == .blocker, let on = args["on"] as? Bool else { throw Failure(message: "not on Blocker or missing on") }; steps.setBlocker(on)
        case "choose-default": guard steps.step == .defaultBrowser, let yes = args["yes"] as? Bool else { throw Failure(message: "not on Default browser or missing yes") }; steps.chooseDefault(yes)
        case "shuffle-card": guard steps.step == .ready else { throw Failure(message: "not on Ready") }; steps.shuffleCard()
        default: throw Failure(message: "intro has ended")
        }
      } else {
        if action == "skip-intro" { controller.intro.skip() }
        else if action == "get-started" { guard controller.intro.ready else { throw Failure(message: "Continue is not ready") }; controller.intro.getStarted() }
        else { throw Failure(message: "setup has not started") }
      }
    }
    var state = app.onboardingWindowController?.state ?? app.onboardingReceipt ?? ["active": false, "screen": "done", "phase": "inactive"]
    state["moduleActive"] = app.onboardingActivated
    return state
  }
}
#endif
