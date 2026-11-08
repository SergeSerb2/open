#if OPEN_AUTOMATION
import AppKit
import OpenEngine
import Darwin

extension AutomationController {
  func welcome(_ args: [String: Any]) throws -> [String: Any] {
    let factory = try window
    let action = args["action"] as? String ?? "state"
    let allowed: Set<String>
    switch action {
    case "state", "insert": allowed = ["action"]
    case "replay", "reveal": allowed = ["action", "card"]
    case "hover": allowed = ["action", "card", "phase"]
    case "link": allowed = ["action", "link"]
    default: throw Failure(message: "unknown welcome action")
    }
    guard Set(args.keys).isSubset(of: allowed) else { throw Failure(message: "unknown welcome argument") }
    switch action {
    case "state": break
    case "insert":
      guard let space = factory.focusedSpace else { throw Failure(message: "no Space") }
      let id = WelcomeTab.insert(into: factory.model, spaceID: space.id)
      factory.selectTabForCommand(id, spaceID: space.id); factory.scheduleSave()
    case "link":
      guard let link = args["link"] as? String, ["shortcuts", "settings"].contains(link),
        let id = factory.selectedTab?.id, let page = factory.welcomeHosts[id]?.page, page.visible else {
        throw Failure(message: "unknown link or Welcome page is not visible")
      }
      page.activateFooter(link)
    case "reveal":
      guard let number = args["card"] as? Int, (1...4).contains(number),
        let id = factory.selectedTab?.id, let page = factory.welcomeHosts[id]?.page, page.visible else {
        throw Failure(message: "card must be 1…4 on a visible Welcome page")
      }
      page.reveal(card: number - 1)
    case "replay", "hover":
      guard let number = args["card"] as? Int, (1...4).contains(number) else { throw Failure(message: "card must be 1…4") }
      guard let id = factory.selectedTab?.id, let page = factory.welcomeHosts[id]?.page, page.visible else {
        throw Failure(message: "Welcome page is not visible")
      }
      let card = page.cards[number - 1]
      if action == "hover" {
        let phase = args["phase"] as? String ?? "enter"
        guard ["enter", "exit"].contains(phase) else { throw Failure(message: "hover phase must be enter or exit") }
        guard let event = NSEvent.enterExitEvent(with: phase == "enter" ? .mouseEntered : .mouseExited, location: .zero, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: page.window?.windowNumber ?? 0,
          context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) else { throw Failure(message: "could not create hover event") }
        if phase == "enter" { card.mouseEntered(with: event) } else { card.mouseExited(with: event) }
      } else { _ = card.accessibilityPerformPress() }
    default: throw Failure(message: "unknown welcome action")
    }
    let page = factory.selectedTab.flatMap { factory.welcomeHosts[$0.id]?.page }
    let all = factory.welcomeHosts.values.map(\.page)
    var cpu = timespec()
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpu)
    return ["appCPUSeconds": Double(cpu.tv_sec) + Double(cpu.tv_nsec) / 1_000_000_000,
      "visible": page?.visible == true, "activeCard": page?.activeCard.map { $0 + 1 } as Any? ?? NSNull(),
      "playlist": page?.playlistPlaying == true ? "playing" : "stopped", "animating": page?.animating == true,
      "reduceMotion": page?.reduceMotion == true, "playedCards": page?.playedCards ?? [],
      "focusedCard": page.flatMap { page in page.cards.firstIndex { $0 === page.window?.firstResponder } }.map { $0 + 1 } as Any? ?? NSNull(),
      "duration": WelcomePageView.duration, "completionCount": page?.completionCount ?? 0,
      "pendingCompletion": page?.hasCompletion == true,
      "animationCount": all.reduce(0) { $0 + $1.cards.reduce(0) { $0 + $1.illustration.animationCount } },
      "hostCount": all.count, "engineContentCreationCount": factory.contentCreationCount,
      "tab": factory.selectedTab?.id.description ?? "",
      "urlField": factory.controller?.sidebar.displayedURLText ?? "",
      "cards": page?.cards.map { ["label": $0.accessibilityLabel() ?? "", "role": $0.accessibilityRole()?.rawValue ?? "",
        "hovered": $0.isHovered, "trackingAreas": $0.trackingAreas.count,
        "actions": $0.accessibilityCustomActions()?.map(\.name) ?? []] as [String: Any] } ?? [],
      "engineInternalPages": OEEngine.shared.allWebContents.filter { $0.url.map(WelcomeTab.isInternal) == true }.count,
      "hosts": factory.welcomeHosts.map { id, host in ["tab": id.description, "visible": host.page.visible,
        "animating": host.page.animating, "playlist": host.page.playlistPlaying ? "playing" : "stopped"] as [String: Any] }
    ]
  }
}
#endif
