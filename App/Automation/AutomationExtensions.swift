#if OPEN_AUTOMATION
import AppKit
import OpenEngine

/// Automation owns only prompts in its test process. No desktop input or
/// persistent preference is used. A handler-free run uses Chromium's dialogs.
@MainActor
final class AutomationExtensionHandler: NSObject, OEExtensionManagerDelegate {
  var handlesPrompts = true
  var pending: [OEExtensionPrompt] = []
  var events: [[String: Any]] = []

  func registerContexts() {
    for context in OEEngine.shared.contexts {
      let manager = context.extensions
      if handlesPrompts { manager.delegate = self }
      else if manager.delegate === self { manager.delegate = nil }
    }
  }
  func extensionManager(_ manager: OEExtensionManager, show prompt: OEExtensionPrompt) {
    guard handlesPrompts, pending.count < 32 else { prompt.cancel(); return }
    pending.append(prompt)
  }
  func extensionManagerDidChange(_ manager: OEExtensionManager) {
    record(["event": "changed", "context": manager.context?.identifier ?? ""])
  }
  func extensionManagerDidBecomeReady(_ manager: OEExtensionManager) {
    record(["event": "ready", "context": manager.context?.identifier ?? ""])
  }
  func extensionManagerDidChangeCommands(_ manager: OEExtensionManager) {
    record(["event": "commands", "context": manager.context?.identifier ?? ""])
  }
  func extensionManager(_ manager: OEExtensionManager, didInstall `extension`: OEExtension, byUser: Bool) {
    record(["event": "installed", "id": `extension`.identifier, "byUser": byUser])
  }
  func extensionManager(_ manager: OEExtensionManager, didFailToLoadExtensionAt path: URL, error: String) {
    record(["event": "loadFailed", "path": path.path, "error": error])
  }
  private func record(_ event: [String: Any]) {
    if events.count >= 256 { events.removeFirst() }
    events.append(event)
  }
  func cancelAll() {
    let prompts = pending; pending.removeAll()
    for prompt in prompts { prompt.cancel() }
  }
  func describe(_ prompt: OEExtensionPrompt) -> [String: Any] {
    let name = prompt.extensionName
    let type: String
    let title: String
    let buttons: [String]
    switch prompt.type {
    case .install, .externalInstall, .remoteInstall:
      type = prompt.type == .externalInstall ? "externalInstall" : prompt.type == .remoteInstall ? "remoteInstall" : "install"
      title = "Add \(name) extension to Open?"; buttons = ["Cancel", "Add Extension"]
    case .permissions, .reEnable:
      type = prompt.type == .reEnable ? "reEnable" : "permissions"
      title = "The extension \(name) has requested additional permissions"; buttons = ["Deny", "Allow"]
    case .uninstall:
      type = "uninstall"
      title = prompt.triggeringExtensionName == nil ? "Remove \(name) extension from Open?" : brand(prompt.chromiumTitle)
      buttons = ["Cancel", "Remove Extension"]
    case .repair:
      type = "repair"; title = brand(prompt.chromiumTitle)
      buttons = [brand(prompt.chromiumCancelLabel), brand(prompt.chromiumAcceptLabel)]
    @unknown default:
      type = "unknown"; title = brand(prompt.chromiumTitle)
      buttons = [brand(prompt.chromiumCancelLabel), brand(prompt.chromiumAcceptLabel)]
    }
    return ["pending": true, "type": type, "extension": prompt.extensionIdentifier,
      "name": name, "title": title, "chromiumTitle": prompt.chromiumTitle,
      "buttons": buttons, "chromiumButtons": [prompt.chromiumCancelLabel, prompt.chromiumAcceptLabel],
      "permissions": prompt.permissions.map { ["message": $0.message, "details": $0.details] },
      "permissionLines": prompt.permissions.flatMap { [$0.message] + $0.details },
      "retainedFiles": prompt.retainedFiles, "retainedDevices": prompt.retainedDevices,
      "triggeringExtensionName": prompt.triggeringExtensionName ?? "",
      "webContent": prompt.webContent?.identifier ?? 0, "browser": prompt.browser?.identifier ?? 0]
  }
  private func brand(_ text: String) -> String {
    text.replacingOccurrences(of: "Chromium", with: "Open").replacingOccurrences(of: "Chrome", with: "Open")
  }
}

extension AutomationController {
  func runExtensionCommand(_ cmd: String, _ args: [String: Any]) async throws -> Any {
    if cmd == "ext-prompt" {
      if let enabled = args["handler"] as? Bool {
        extensionAutomation.cancelAll()
        extensionAutomation.handlesPrompts = enabled
        extensionAutomation.registerContexts()
      }
      if args["clear"] as? Bool == true { extensionAutomation.cancelAll() }
      var result: [String: Any] = ["pending": false]
      if let prompt = extensionAutomation.pending.first {
        result = extensionAutomation.describe(prompt)
        if let answer = args["answer"] as? String {
          guard ["accept", "cancel"].contains(answer) else { throw Failure(message: "answer must be accept or cancel") }
          extensionAutomation.pending.removeFirst()
          let injectCancel = answer == "accept" && prompt.type == .install
            && ProcessInfo.processInfo.environment["OPEN_E2E_P3_CANCEL_INSTALL"] == "1"
          if answer == "accept" && !injectCancel { prompt.accept() } else { prompt.cancel() }
          result["injectedCancel"] = injectCancel
          // The API guarantees exactly once even for accidental duplicate answers.
          if args["twice"] as? Bool == true { prompt.accept(); prompt.cancel() }
          result["answered"] = answer
        } else if args["hold"] as? Bool == false {
          // Dropping the last reference tests release-to-cancel.
          extensionAutomation.pending.removeFirst()
          result["released"] = true
        }
      }
      result["queued"] = extensionAutomation.pending.count
      result["handler"] = extensionAutomation.handlesPrompts
      result["events"] = extensionAutomation.events
      return result
    }
    let factory = try window
    let browser = try focusedBrowser(factory)
    let manager = browser.context.extensions
    if cmd == "ext-commands" {
      return ["ready": manager.isReady, "context": browser.context.identifier,
        "commands": manager.commands.map { command in
          ["extension": command.extensionIdentifier, "name": command.name,
           "summary": command.summary, "keyEquivalent": command.keyEquivalent,
           "modifierFlags": command.modifierFlags.rawValue, "global": command.isGlobal,
           "actionCommand": command.isActionCommand] as [String: Any]
        }]
    }
    guard let id = args["extension"] as? String else { throw Failure(message: "missing extension") }
    if cmd == "ext-run-command" {
      guard let name = args["name"] as? String else { throw Failure(message: "missing command name") }
      return browser.executeExtensionCommand(name, forExtension: id)
    }
    guard let action = args["action"] as? String else { throw Failure(message: "missing management action") }
    switch action {
    case "enable", "disable": manager.setEnabled(action == "enable", forExtension: id)
    case "uninstall": manager.uninstallExtension(id, window: factory.window)
    case "reload": manager.reloadExtension(id)
    case "install-webstore":
      // Completion is recorded so the socket remains available to answer consent.
      manager.install(fromWebStore: id, window: factory.window) { [weak extensionAutomation] installed, error in
        extensionAutomation?.events.append(["event": "installComplete", "id": id, "installed": installed, "error": error ?? ""])
      }
    case "install-crx":
      guard let path = args["path"] as? String, let content = browser.activeWebContent else { throw Failure(message: "missing CRX path or active page") }
      return manager.installLocalCRX(URL(fileURLWithPath: path), webContent: content)
    default: throw Failure(message: "unknown management action")
    }
    return true
  }
}
#endif
