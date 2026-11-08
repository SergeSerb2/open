#if OPEN_AUTOMATION
import AppKit
import OpenFeatures
import OpenWeb
import OpenEngine

/// Synthetic metadata only. No credentials, Keychain, or engine storage access.
@MainActor final class MockSavePrompt: SavePromptRequest {
  let kind: SavePromptKind
  let displayHost: String
  var offersNeverForSite: Bool { kind == .password }
  private(set) var isAnswered = false
  private let didFinish: (String) -> Void
  init(kind: SavePromptKind, displayHost: String, didFinish: @escaping (String) -> Void) {
    self.kind = kind; self.displayHost = displayHost; self.didFinish = didFinish
  }
  func answer(_ answer: SavePromptAnswer) {
    guard !isAnswered else { return }; isAnswered = true
    let value = switch answer { case .save: "save"; case .neverForSite: "never"; case .dismiss: "dismiss" }
    didFinish(value)
  }
  isolated deinit { if !isAnswered { didFinish("ignored") } }
}

extension SavePromptKind {
  var automationName: String {
    switch self { case .password: "password"; case .passwordUpdate: "passwordUpdate"; case .card: "card"; case .address: "address"; case .addressUpdate: "addressUpdate" }
  }
  init?(automationName: String) {
    switch automationName {
    case "password": self = .password
    case "update", "passwordUpdate": self = .passwordUpdate
    case "card": self = .card
    case "address": self = .address
    case "addressUpdate": self = .addressUpdate
    default: return nil
    }
  }
}

extension AutomationController {
  private var savePromptFactory: EngineWebContentHostFactory? {
    let owners = Array(app.hostFactories.values) + app.littleOpenHosts.values.compactMap(\.owner)
    return owners.first { $0.window === NSApp.keyWindow || $0.window?.attachedSheet === NSApp.keyWindow }
      ?? app.frontWindowController.flatMap { app.hostFactories[$0.windowID] }
  }

  func recordRealSavePrompt(_ prompt: OESavePrompt, answer: String, owner: EngineWebContentHostFactory? = nil, page: OEWebContent? = nil) {
    guard let host = URL(string: prompt.origin)?.host()?.lowercased(),
          host == "example.com" || host.hasSuffix(".example.com") || host == "localhost" || host == "127.0.0.1" else { return }
    let previous = realSavePromptAnswers.object(forKey: prompt) as String?
    guard previous == nil || previous == "pending", previous != answer else { return }
    realSavePromptAnswers.setObject(answer as NSString, forKey: prompt)
    if let owner { realSavePromptFactories.setObject(owner, forKey: prompt) }
    if let page { realSavePromptPages.setObject(page, forKey: prompt) }
    realSavePromptFactories.object(forKey: prompt)?.record("savePrompt", realSavePromptPages.object(forKey: prompt),
      ["kind": prompt.openSavePromptKind.automationName, "displayHost": prompt.displayHost, "answer": answer])
  }

  func savePromptDidPresent(_ sheet: SavePromptSheet) {
    guard sheet.request is OESavePrompt, savePromptPolicy != "hold" else { return }
    let policy = savePromptPolicy
    DispatchQueue.main.async { [weak self, weak sheet] in
      guard self?.savePromptPolicy == policy, let sheet, sheet.isVisible, sheet.request != nil else { return }
      // These are the same target/actions as a user's choice. Never answer
      // the request directly from an automation policy.
      let button = policy == "save" ? sheet.dialogView.primaryButton
        : policy == "never" ? sheet.dialogView.button(for: .leading) : sheet.dialogView.cancelButton
      if let button, button.isEnabled { button.performClick(nil) }
    }
  }

  func savePrompt(_ args: [String: Any]) async throws -> Any {
    guard args.keys.allSatisfy({ ["mock", "answer", "state", "withdraw"].contains($0) }),
          args.count == 1 else { throw Failure(message: "expected one of mock, answer, state, withdraw") }
    guard let factory = savePromptFactory, let presenter = factory.savePrompts else {
      if args["state"] as? Bool == true { return ["visible": false, "queueLength": 0] as [String: Any] }
      throw Failure(message: "no browser window")
    }
    if let mock = args["mock"] as? [String: Any] {
      guard Set(mock.keys) == ["kind", "host"], let raw = mock["kind"] as? String,
            let kind = SavePromptKind(automationName: raw), let host = mock["host"] as? String,
            host.utf8.count <= SavePromptSheet.maximumHostBytes,
            !host.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            let page = factory.selectedContent else { throw Failure(message: "invalid mock kind/host or no focused page (host limit 4096 UTF-8 bytes)") }
      let request = MockSavePrompt(kind: kind, displayHost: host) { [weak factory, weak page] answer in
        factory?.record("savePrompt", page, ["kind": kind.automationName, "displayHost": host, "answer": answer])
      }
      presenter.enqueue(request, page: AnyHashable(page.identifier))
    } else if let answer = args["answer"] as? String {
      guard let sheet = presenter.active else { throw Failure(message: "no visible save sheet") }
      let button: NSButton?
      switch answer {
      case "save": button = sheet.dialogView.primaryButton
      case "dismiss": button = sheet.dialogView.cancelButton
      case "never": button = sheet.dialogView.button(for: .leading)
      default: throw Failure(message: "unknown save prompt answer")
      }
      guard let button, button.isEnabled, sheet.isVisible else { throw Failure(message: "save sheet button is unavailable") }
      button.performClick(nil) // Same NSButton target/action as a user click.
    } else if args["withdraw"] as? Bool == true {
      if let request = presenter.active?.request { presenter.withdraw(request) }
    } else if args["state"] as? Bool != true { throw Failure(message: "invalid save prompt arguments") }
    await Task.yield()
    guard let sheet = presenter.active else { return ["visible": false, "queueLength": presenter.queuedCount] as [String: Any] }
    return ["visible": sheet.isVisible, "kind": sheet.kind.automationName, "title": sheet.title,
      "body": sheet.dialogView.bodyLabel.stringValue, "buttons": sheet.dialogView.buttonModels.map(\.label),
      "defaultButton": sheet.dialogView.primaryButton?.accessibilityLabel() ?? "",
      "cancelButton": sheet.dialogView.cancelButton?.accessibilityLabel() ?? "",
      "queueLength": presenter.queuedCount, "window": sheet.windowNumber] as [String: Any]
  }
}
#endif
