#if OPEN_AUTOMATION
import AppKit
import OpenEngine
import OpenModel
import OpenSleep

/// Tab sleep automation commands (app-shell §6 `sleep` suite, docs/automation.md "Tab sleep").
/// Automation builds only: the clock offset, the explicit pass and the low-power override
/// never exist in a user build.
extension AutomationController {
  static let sleepCommands: Set<String> = ["sleep-state", "sleep-now", "sleep-mode", "sleep-clock", "sleep-tick",
                                           "sleep-power", "sleep-start", "sleep-store"]

  func runSleepCommand(_ cmd: String, _ a: [String: Any]) async throws -> Any {
    let sleep = app.tabSleep
    switch cmd {
    case "sleep-start":
      // Suites that never paint a page start the controller as T5 would.
      sleep.start()
      return sleepState(nil)
    case "sleep-state":
      return sleepState(try a["tab"].map { _ in try sleepTab(a) })
    case "sleep-now":
      // OpenSleep's debug sleep (memory-fork §9.4): freeze + discard now, never past a gate.
      let controller = try sleepController()
      let tab = try sleepTab(a)
      let gate = controller.blockingGate(tabID: tab.id, forDiscard: true)
      await controller.debugSleepNow(tabID: tab.id)
      return ["refusedBy": gate?.rawValue ?? NSNull(), "tab": describeSleep(tab, controller)] as [String: Any]
    case "sleep-mode":
      // Writes every Profile's mode, as Settings ▸ Advanced does (setTabSleepMode).
      if let raw = a["mode"] as? String {
        guard let mode = SleepMode(rawValue: raw) else { throw Failure(message: "mode must be off, conservative, balanced or aggressive") }
        for profile in app.model.profiles {
          var settings = profile.settings; settings.sleepMode = mode
          app.model.updateProfileSettings(id: profile.id, settings: settings)
        }
        app.scheduleSave(); sleep.modeChanged()
      }
      return Dictionary(uniqueKeysWithValues: app.model.profiles.map { ($0.id.description, $0.settings.sleepMode.rawValue) })
    case "sleep-clock":
      // Moves the controller's clock (hide times, grace periods, discard delays) forward.
      if a["reset"] as? Bool == true { sleep.clock.offset = 0 }
      if let seconds = a["advance"] as? Double {
        guard seconds >= 0, seconds <= 7 * 86400 else { throw Failure(message: "advance must be 0…604800 s") }
        sleep.clock.offset += seconds
      }
      return ["offset": sleep.clock.offset]
    case "sleep-tick":
      // One controller pass now (or a memory-pressure pass), instead of waiting for the loop.
      let controller = try sleepController()
      // A timer pass may be in flight (it awaits SQLite); a tick then would return at once.
      while controller.isRunningPass { try await Task.sleep(for: .milliseconds(5)) }
      switch a["pressure"] as? String {
      case nil: await controller.tick()
      case "warning": await controller.handleMemoryPressure(.warning)
      case "critical": await controller.handleMemoryPressure(.critical)
      default: throw Failure(message: "pressure must be warning or critical")
      }
      return sleepState(nil)
    case "sleep-power":
      // Battery Saver: overrides macOS Low Power Mode; null follows macOS again.
      if a.keys.contains("lowPower") { sleep.lowPowerOverride = a["lowPower"] as? Bool }
      return ["lowPowerMode": sleep.lowPowerMode, "override": sleep.lowPowerOverride ?? NSNull(),
              "system": ProcessInfo.processInfo.isLowPowerModeEnabled, "toasts": sleep.batteryToasts,
              "lastToast": app.frontWindowController?.lastToastTitle ?? ""] as [String: Any]
    case "sleep-store":
      guard let store = sleep.store ?? (sleep.prepare() != nil ? sleep.store : nil) else { throw Failure(message: "sleep is not ready") }
      var rows: [[String: Any]] = []
      for id in await store.storedTabIDs() {
        let envelope = await store.sleepHistory(tabID: id)
        rows.append(["tab": id.description, "url": envelope?.currentURL.absoluteString ?? "",
                     "title": envelope?.currentTitle ?? "", "entries": envelope?.entryCount ?? 0,
                     "pageState": envelope?.hasPageState ?? false, "tag": envelope?.chromiumTag ?? "",
                     "file": store.fileURL(for: id).path])
      }
      return rows
    default:
      throw Failure(message: "unknown sleep command")
    }
  }

  private func sleepController() throws -> SleepController {
    guard let controller = app.tabSleep.prepare() else { throw Failure(message: "sleep is not ready (engine not initialized)") }
    return controller
  }

  private func sleepTab(_ a: [String: Any]) throws -> Tab {
    guard let s = a["tab"] as? String, let uuid = UUID(uuidString: s), let tab = app.model.tab(id: ItemID(rawValue: uuid)) else {
      throw Failure(message: "missing or unknown tab")
    }
    return tab
  }

  private func describeSleep(_ tab: Tab, _ controller: SleepController) -> [String: Any] {
    let adapter = app.tabSleep.adapter
    let phase: String
    switch tab.live.sleepPhase {
    case .placeholder: phase = "placeholder"
    case .live: phase = "live"
    case .frozen: phase = "frozen"
    case .sleeping: phase = "sleeping"
    }
    func time(_ date: Date?) -> Any { date.map { $0.timeIntervalSince1970 } ?? NSNull() }
    return [
      "id": tab.id.description, "url": tab.url.absoluteString, "title": tab.title, "phase": phase,
      "content": controller.liveContent.contains(tab.id), "hosts": adapter?.hosts(tab.id).count ?? 0,
      "discarded": adapter?.wasDiscarded(tabID: tab.id) ?? false,
      "freezeGate": controller.blockingGate(tabID: tab.id, forDiscard: false)?.rawValue ?? NSNull(),
      "discardGate": controller.blockingGate(tabID: tab.id, forDiscard: true)?.rawValue ?? NSNull(),
      "hiddenAt": time(controller.hiddenAt[tab.id]), "sleptAt": time(controller.sleptAt[tab.id]),
      "retryAfter": time(controller.retryAfter[tab.id]),
      "audible": tab.live.isAudible, "capturing": tab.live.isCapturing, "devTools": tab.live.devToolsOpen,
      "notificationsAllowed": tab.live.notificationsAllowed, "downloading": controller.downloading.contains(tab.id),
      "lastFormInteractionAt": time(tab.live.lastFormInteractionAt),
    ]
  }

  private func sleepState(_ tab: Tab?) -> [String: Any] {
    let sleep = app.tabSleep
    guard let controller = sleep.controller else { return ["prepared": false, "started": false] }
    let tabs = tab.map { [$0] } ?? app.model.index.values.compactMap(\.tab).sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
    let visibility = app.media.visibility.sleepVisibility()
    return [
      "prepared": true, "started": sleep.isStarted, "scheduled": controller.isPassScheduled,
      "scheduledDelay": controller.scheduledPassDelay ?? NSNull(), "nextPassDelay": controller.nextPassDelay() ?? NSNull(),
      "passes": controller.passCount, "lowPowerMode": controller.lowPowerMode, "clockOffset": sleep.clock.offset,
      "visible": controller.visibleTabIDs().map(\.description).sorted(),
      "pictureInPicture": visibility.pictureInPicture.map(\.description).sorted(),
      "mediaControls": visibility.mediaControls.map(\.description).sorted(),
      "criticalCloses": sleep.adapter?.criticalCloses ?? 0,
      "tabs": tabs.map { describeSleep($0, controller) }, "log": Array(sleep.log.suffix(200)),
      "batteryToasts": sleep.batteryToasts, "quitCapture": sleep.quitCapture,
    ]
  }
}
#endif
