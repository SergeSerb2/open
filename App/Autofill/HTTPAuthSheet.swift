#if OPEN_HTTP_AUTH
import AppKit
import OpenDesign

/// The engine owns the network challenge and the password manager. The shell
/// retains this request only while waiting for a user's answer.
@MainActor
protocol HTTPAuthRequest: AnyObject {
  var origin: String { get }
  var realm: String { get }
  var scheme: String { get }
  var isProxy: Bool { get }
  var isAnswered: Bool { get }
  func accept(username: String, password: String)
  func cancel()
}

/// Supplied by the capture-backed bridge. No provisional dialog copy ships.
struct HTTPAuthSheetText {
  let title: String
  let body: String
  let username: String
  let password: String
  let accept: String
  let cancel: String
}

/// Uses the save-password sheet's existing controls while C13-AUTH supplies
/// the final layout. OPEN_HTTP_AUTH remains off until both capture and engine
/// adoption are complete.
@MainActor
final class HTTPAuthSheet: DialogSheetPanel, NSTextFieldDelegate {
  static let maximumMetadataBytes = 4096
  static let maximumCredentialBytes = 4096
  let usernameField = NSTextField()
  let passwordField = NSSecureTextField()
  private(set) var request: (any HTTPAuthRequest)?
  var onFinished: (() -> Void)?
  private var userEdited = false

  init(request: any HTTPAuthRequest, text: HTTPAuthSheetText) {
    self.request = request
    super.init(title: text.title, body: text.body,
      buttons: [.init(text.cancel, role: .cancel), .init(text.accept, role: .primary)])
    let p = DialogSheetMetrics.padding
    let fieldY = dialogView.bodyLabel.frame.maxY + 16
    for (index, field) in [usernameField, passwordField].enumerated() {
      let label = index == 0 ? text.username : text.password
      field.placeholderString = label
      field.setAccessibilityLabel(label)
      field.identifier = NSUserInterfaceItemIdentifier(index == 0 ? "http-auth-username" : "http-auth-password")
      field.delegate = self
      field.font = .systemFont(ofSize: 13)
      field.frame = CGRect(x: p, y: fieldY + CGFloat(index) * 38,
        width: DialogSheetMetrics.textWidth, height: 28)
      dialogView.addSubview(field)
    }
    for button in dialogView.buttons { button.frame.origin.y += 92 }
    dialogView.frame.size.height += 92
    setContentSize(dialogView.frame.size)
    usernameField.nextKeyView = passwordField
    passwordField.nextKeyView = dialogView.cancelButton
    dialogView.buttons.last?.nextKeyView = usernameField
    initialFirstResponder = usernameField
    dialogView.onPress = { [weak self] role in self?.finish(accept: role == .primary) }
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  func controlTextDidChange(_ notification: Notification) {
    userEdited = true
    dialogView.primaryButton?.isEnabled = credentialsWithinLimit
  }

  private var credentialsWithinLimit: Bool {
    usernameField.stringValue.utf8.count <= Self.maximumCredentialBytes
      && passwordField.stringValue.utf8.count <= Self.maximumCredentialBytes
  }

  /// A late password-manager result must never overwrite the user's typing.
  func autofill(username: String, password: String) {
    guard !userEdited, request?.isAnswered == false,
          username.utf8.count <= Self.maximumCredentialBytes,
          password.utf8.count <= Self.maximumCredentialBytes else { return }
    usernameField.stringValue = username
    passwordField.stringValue = password
  }

  private func finish(accept: Bool) {
    guard let request, !accept || credentialsWithinLimit else { return }
    self.request = nil
    let username = accept ? usernameField.stringValue : ""
    let password = accept ? passwordField.stringValue : ""
    clearCredentials()
    if !request.isAnswered {
      if accept { request.accept(username: username, password: password) }
      else { request.cancel() }
    }
    onFinished?()
  }

  func clearCredentials() {
    // Swift/AppKit strings cannot promise zeroization. Avoid keeping copies in
    // presenter state, automation metadata, logs, or detached sheet editors.
    for field in [usernameField, passwordField] {
      if let editor = field.currentEditor() as? NSTextView { editor.string = "" }
    }
    usernameField.stringValue = ""
    passwordField.stringValue = ""
  }

  func releaseRequest() { request = nil; clearCredentials() }
  override func close() { finish(accept: false); super.close() }
}
#endif
