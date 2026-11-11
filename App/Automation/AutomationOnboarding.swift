#if OPEN_AUTOMATION
import OpenOnboarding
import AppKit
import ObjectiveC.runtime
import OpenDesign
import OpenSettings
import OpenFeatures
import Darwin

extension AutomationController {
  func runOnboarding(_ args: [String: Any]) async throws -> [String: Any] {
    let pacingRegion = IntroPacingTrace.begin("automation.onboarding")
    defer { pacingRegion?.end() }
    let action = args["action"] as? String ?? "state"
    let allowed: [String: Set<String>] = ["state": [], "release-allocator-cache": [], "skip-intro": [], "get-started": [], "prepare-handoff": [], "replay-intro": [], "next": [], "back": [], "skip": [], "set-name": ["name"], "toggle-favorite": ["index"], "set-theme": ["preset"], "set-blocker": ["on"], "choose-default": ["yes"], "shuffle-card": [], "save-card": [], "card-save": ["path"], "card-cancel": [], "set-appearance": ["appearance"]]
    guard (args["action"] == nil || args["action"] is String), action.utf8.count <= 32,
          let extra = allowed[action], Set(args.keys).isSubset(of: extra.union(["action"])) else {
      throw Failure(message: "unknown onboarding action or argument")
    }
    if action == "release-allocator-cache" {
      guard app.onboardingWindowController == nil, app.onboardingHandedOff else { throw Failure(message: "onboarding must finish before allocator diagnostics") }
      let before = OnboardingWindowController.residentBytes()
      let relieved = malloc_zone_pressure_relief(nil,0)
      return ["before":before,"released":relieved,"after":OnboardingWindowController.residentBytes()]
    }
    if action == "replay-intro" { app.showOnboarding(replay: true) }
    else if action != "state" {
      guard let controller = app.onboardingWindowController, controller.window?.isVisible == true else { throw Failure(message: "onboarding is not active") }
      if let steps = controller.steps {
        guard !steps.finishing, !steps.firstRun.busy, !steps.defaultPending else { throw Failure(message: "onboarding is busy") }
        switch action {
        case "prepare-handoff":
          // Position only the pending window. The pointer will be over the
          // header, clear of card tracking areas, when Welcome first appears.
          // Keep visible content on screen; do not create a browser early.
          guard steps.step == .ready, !controller.replay else { throw Failure(message: "not on first-run Ready") }
          BrowserWindowController.constrainsFramesToScreen = false
          let pointer = NSEvent.mouseLocation
          let left = controller.window?.screen?.frame.minX ?? 0
          for window in app.model.windows {
            window.frameX = left; window.frameY = pointer.y + 100 - 800
            window.frameWidth = 1280; window.frameHeight = 800
          }
        case "set-appearance":
          guard let appearance = args["appearance"] as? String, ["light", "dark"].contains(appearance) else { throw Failure(message: "expected light or dark") }
          controller.window?.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua:.aqua)
        case "save-card": guard steps.step == .ready else { throw Failure(message: "not on Ready") }; steps.saveCard()
        case "card-save", "card-cancel":
          guard let panel = steps.savePanel else { throw Failure(message: "card save panel is not open") }
          let cancel = action == "card-cancel"
          let path = args["path"] as? String
          guard cancel || (path?.utf8.count ?? 0 > 0 && path?.utf8.count ?? 4097 <= 4096 && path?.hasPrefix("/") == true && path?.contains("\0") == false) else { throw Failure(message: "expected absolute save path") }
          let selector = NSSelectorFromString("completeWithReturnCode:url:urls:")
          guard let method = class_getInstanceMethod(type(of: panel), selector), let types = method_getTypeEncoding(method), String(cString: types) == "v40@0:8q16@24@32" else { throw Failure(message: "save panel URL input is unavailable") }
          typealias Complete = @convention(c) (AnyObject, Selector, Int, NSURL?, NSArray?) -> Void
          let complete = unsafeBitCast(method_getImplementation(method), to: Complete.self)
          let selected = cancel ? nil:path.map { URL(fileURLWithPath: $0) }
          complete(panel, selector, cancel ? NSApplication.ModalResponse.cancel.rawValue:NSApplication.ModalResponse.OK.rawValue, selected as NSURL?, selected.map { [$0 as NSURL] as NSArray })
        case "next": guard steps.step != .ready else { throw Failure(message: "use get-started on Ready") }; steps.next()
        case "get-started": guard steps.step == .ready else { throw Failure(message: "not on Ready") }; steps.next()
        case "back": steps.back()
        case "skip": guard [.name, .importData, .favorites, .theme, .blocker].contains(steps.step), steps.step != .importData || ![.report, .importing].contains(steps.firstRun.step) else { throw Failure(message: "this step cannot be skipped") }; steps.skip()
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
    var state = app.onboardingWindowController?.state ?? app.onboardingReceipt ?? ["active": false, "screen": "done", "phase": "inactive", "dim": ["exists": false, "alpha": 0]]
    var allocator = malloc_statistics_t()
    malloc_zone_statistics(nil,&allocator)
    state["allocator"] = ["inUse":allocator.size_in_use,"allocated":allocator.size_allocated,"peak":allocator.max_size_in_use]
    state["moduleActive"] = app.onboardingActivated
    state["launchTiming"] = LaunchTiming.shared.report
    state["audioPreparationPending"] = app.preparedOnboardingSound != nil
    if app.onboardingWindowController == nil, let lifetime = app.onboardingLifetimeState {
      state["retainedObjects"] = lifetime()
    }
    var startup = app.onboardingStartup
    if let firstFrame = state["firstFrameHostTime"] as? Double,
       let launch = startup["launchHostTime"] as? Double {
      startup["firstOnboardingFrameHostTime"] = firstFrame
      startup["launchToFirstOnboardingFrameMS"] = (firstFrame-launch)*1000
    }
    state["startup"] = startup
    if app.frontWindowController != nil { state["welcome"] = try welcome(["action": "state"]) }
    return state
  }
}
#endif
