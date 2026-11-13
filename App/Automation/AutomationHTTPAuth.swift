#if OPEN_AUTOMATION && OPEN_HTTP_AUTH
import AppKit

extension AutomationController {
  /// Operates the real sheet only. Values never leave the native fields; the
  /// harness types synthetic credentials through NSApplication.sendEvent.
  func httpAuthentication(_ args: [String: Any]) async throws -> Any {
    guard args.count == 1,
          args.keys.allSatisfy({ ["state", "focus", "answer"].contains($0) }) else {
      throw Failure(message: "expected one of state, focus, answer")
    }
    let owners = Array(app.hostFactories.values) + app.littleOpenHosts.values.compactMap(\.owner)
    let factory = owners.first { $0.window === NSApp.keyWindow || $0.window?.attachedSheet === NSApp.keyWindow }
      ?? app.frontWindowController.flatMap { app.hostFactories[$0.windowID] }
    guard let presenter = factory?.httpAuth, let sheet = presenter.active, sheet.isVisible else {
      if args["state"] as? Bool == true { return ["visible": false] }
      throw Failure(message: "no visible HTTP authentication sheet")
    }
    if let field = args["focus"] as? String {
      guard field == "username" || field == "password" else { throw Failure(message: "unknown authentication field") }
      sheet.makeKeyAndOrderFront(nil)
      guard sheet.makeFirstResponder(field == "username" ? sheet.usernameField : sheet.passwordField) else {
        throw Failure(message: "authentication field could not become first responder")
      }
    } else if let answer = args["answer"] as? String {
      guard answer == "accept" || answer == "cancel" else { throw Failure(message: "unknown authentication answer") }
      let button = answer == "accept" ? sheet.dialogView.primaryButton : sheet.dialogView.cancelButton
      guard let button, button.isEnabled else { throw Failure(message: "authentication button is unavailable") }
      button.performClick(nil)
    } else if args["state"] as? Bool != true { throw Failure(message: "invalid authentication arguments") }
    await Task.yield()
    guard presenter.active === sheet, sheet.isVisible, sheet.request != nil else { return ["visible": false] }
    return ["visible": true, "title": sheet.title, "body": sheet.dialogView.bodyLabel.stringValue,
      "buttons": sheet.dialogView.buttonModels.map(\.label), "window": sheet.windowNumber,
      "parent": sheet.sheetParent?.windowNumber ?? 0, "queueLength": presenter.queuedCount,
      "usernamePresent": !sheet.usernameField.stringValue.isEmpty,
      "passwordPresent": !sheet.passwordField.stringValue.isEmpty,
      "autofilled": sheet.didAutofill,
      "credentialLookupFinished": sheet.credentialLookupFinished] as [String: Any]
  }
}
#endif
