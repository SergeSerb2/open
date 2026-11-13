#if OPEN_HTTP_AUTH
import AppKit
import OpenDesign

/// The shell retains the engine's network challenge until an answer or withdrawal.
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

struct HTTPAuthSheetText {
  let title: String
  let body: String
  let username: String
  let password: String
  let accept: String
  let cancel: String
}

@MainActor
private final class HTTPAuthFieldBackdrop: NSView {
  weak var field: NSTextField?
  override func mouseDown(with event: NSEvent) {
    if let field { window?.makeFirstResponder(field) }
  }
}

/// C13-AUTH: 413×257 pt, two labeled fields, Cancel and Sign in without key hints.
/// Layout evidence and capture paths are in docs/re/passwords-autofill.md PW-11.
@MainActor
final class HTTPAuthView: NSView {
  let titleLabel: NSTextField
  let bodyLabel: NSTextField
  let usernameField = NSTextField()
  let passwordField = NSSecureTextField()
  let buttonModels: [DialogSheetButton]
  let buttons = [NSButton(), NSButton()]
  var cancelButton: NSButton? { buttons.first }
  var primaryButton: NSButton? { buttons.last }
  var onPress: ((DialogSheetButton.Role) -> Void)?
  private let fieldBackgrounds = [HTTPAuthFieldBackdrop(), HTTPAuthFieldBackdrop()]
  private let fieldLabels: [NSTextField]
  override var isFlipped: Bool { true }

  init(text: HTTPAuthSheetText) {
    titleLabel = NSTextField(labelWithString: text.title)
    bodyLabel = NSTextField(labelWithString: text.body)
    fieldLabels = [NSTextField(labelWithString: text.username), NSTextField(labelWithString: text.password)]
    buttonModels = [.init(text.cancel, role: .cancel), .init(text.accept, role: .primary)]
    super.init(frame: CGRect(x: 0, y: 0, width: 413, height: 257))
    wantsLayer = true
    layer?.cornerRadius = 16
    layer?.cornerCurve = .continuous
    titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
    titleLabel.lineBreakMode = .byTruncatingMiddle
    titleLabel.frame = CGRect(x: 19, y: 19, width: 375, height: 23)
    titleLabel.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
    bodyLabel.font = .systemFont(ofSize: 13)
    bodyLabel.frame = CGRect(x: 19, y: 60, width: 375, height: 18)
    addSubview(titleLabel); addSubview(bodyLabel)
    for (index, field) in [usernameField, passwordField].enumerated() {
      let y = 98 + CGFloat(index) * 55
      let backdrop = fieldBackgrounds[index]
      backdrop.field = field
      backdrop.frame = CGRect(x: 93, y: y, width: 300, height: 30)
      backdrop.wantsLayer = true; backdrop.layer?.cornerRadius = 5
      addSubview(backdrop)
      let label = fieldLabels[index]
      label.frame = CGRect(x: 19, y: y + 5, width: 67, height: 18)
      label.font = .systemFont(ofSize: 13)
      addSubview(label)
      field.font = .systemFont(ofSize: 13)
      field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
      field.focusRingType = .none
      field.placeholderString = label.stringValue
      field.setAccessibilityLabel(label.stringValue)
      field.identifier = .init(index == 0 ? "http-auth-username" : "http-auth-password")
      field.frame = CGRect(x: 99, y: y + 5, width: 288, height: 18)
      addSubview(field)
    }
    for (index, button) in buttons.enumerated() {
      button.title = buttonModels[index].label
      button.font = .systemFont(ofSize: 13, weight: .medium)
      button.isBordered = false; button.wantsLayer = true
      button.layer?.cornerRadius = 5
      button.frame = CGRect(x: 235 + CGFloat(index) * 83, y: 207, width: 75, height: 30)
      button.target = self; button.action = #selector(press(_:)); button.tag = index
      button.keyEquivalent = index == 0 ? "\u{1b}" : "\r"
      button.keyEquivalentModifierMask = []
      button.setAccessibilityLabel(button.title)
      addSubview(button)
    }
    refreshColors()
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  @objc private func press(_ sender: NSButton) { onPress?(buttonModels[sender.tag].role) }

  func refreshColors() {
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
      NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }
    // C13-AUTH PNGs, embedded display profile converted to sRGB. These are
    // recreated colors and geometry; no captured image is bundled in the App.
    let background = dark ? color(40, 38, 36) : .white
    let foreground = dark ? color(148, 147, 146) : color(127, 127, 127)
    let control = dark ? color(61, 59, 58) : color(243, 243, 243)
    let accent = dark ? color(43, 182, 246) : color(13, 80, 255)
    layer?.backgroundColor = background.cgColor
    for label in [titleLabel, bodyLabel] + fieldLabels { label.textColor = foreground }
    for (index, field) in [usernameField, passwordField].enumerated() {
      let focused = field.currentEditor() != nil
      fieldBackgrounds[index].layer?.backgroundColor = (focused ? (dark ? NSColor.black : .white) : control).cgColor
      fieldBackgrounds[index].layer?.borderWidth = focused ? 2 : 0
      fieldBackgrounds[index].layer?.borderColor = accent.cgColor
      field.textColor = dark ? color(167, 167, 166) : foreground
      field.placeholderAttributedString = NSAttributedString(string: field.placeholderString ?? "",
        attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: dark ? color(167, 167, 166) : color(122, 122, 122)])
    }
    for (index, button) in buttons.enumerated() {
      button.layer?.backgroundColor = (index == 0 ? control : accent).cgColor
      button.attributedTitle = NSAttributedString(string: buttonModels[index].label,
        attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
          .foregroundColor: index == 0 ? foreground : NSColor.white])
    }
  }

  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshColors() }
}

@MainActor
final class HTTPAuthSheet: NSPanel, NSTextFieldDelegate {
  static let maximumMetadataBytes = 4096
  static let maximumCredentialBytes = 4096
  let dialogView: HTTPAuthView
  var usernameField: NSTextField { dialogView.usernameField }
  var passwordField: NSSecureTextField { dialogView.passwordField }
  private(set) var request: (any HTTPAuthRequest)?
  var onFinished: (() -> Void)?
  private(set) var didAutofill = false
  private var userEdited = false
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  init(request: any HTTPAuthRequest, text: HTTPAuthSheetText) {
    self.request = request
    dialogView = HTTPAuthView(text: text)
    super.init(contentRect: CGRect(origin: .zero, size: dialogView.frame.size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    title = text.title
    isReleasedWhenClosed = false; isOpaque = false; backgroundColor = .clear; hasShadow = true
    contentView = dialogView
    usernameField.delegate = self; passwordField.delegate = self
    usernameField.nextKeyView = passwordField
    passwordField.nextKeyView = dialogView.cancelButton
    dialogView.cancelButton?.nextKeyView = dialogView.primaryButton
    dialogView.primaryButton?.nextKeyView = usernameField
    initialFirstResponder = usernameField
    autorecalculatesKeyViewLoop = false
    defaultButtonCell = dialogView.primaryButton?.cell as? NSButtonCell
    setAccessibilityRole(.sheet); setAccessibilityLabel(text.title)
    setAccessibilityDefaultButton(dialogView.primaryButton); setAccessibilityCancelButton(dialogView.cancelButton)
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { animationBehavior = .none }
    dialogView.onPress = { [weak self] role in self?.finish(accept: role == .primary) }
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  func controlTextDidBeginEditing(_ notification: Notification) { dialogView.refreshColors() }
  func controlTextDidEndEditing(_ notification: Notification) { dialogView.refreshColors() }
  func controlTextDidChange(_ notification: Notification) {
    userEdited = true
    dialogView.primaryButton?.isEnabled = credentialsWithinLimit
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard !textView.hasMarkedText() else { return false }
    switch NSStringFromSelector(selector) {
    case "insertNewline:", "insertNewlineIgnoringFieldEditor:":
      control.validateEditing(); finish(accept: true); return true
    case "cancelOperation:": finish(accept: false); return true
    default: return false
    }
  }

  private var credentialsWithinLimit: Bool {
    usernameField.stringValue.utf8.count <= Self.maximumCredentialBytes
      && passwordField.stringValue.utf8.count <= Self.maximumCredentialBytes
  }

  /// Receives a matching engine password-store result. User typing wins.
  func autofill(username: String, password: String) {
    guard !userEdited, request?.isAnswered == false,
          username.utf8.count <= Self.maximumCredentialBytes,
          password.utf8.count <= Self.maximumCredentialBytes else { return }
    usernameField.stringValue = username; passwordField.stringValue = password
    didAutofill = true
  }

  private func finish(accept: Bool) {
    usernameField.validateEditing(); passwordField.validateEditing()
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
    // AppKit strings cannot promise zeroization. Keep values out of presenter
    // state, automation metadata, logs and detached sheet field editors.
    for field in [usernameField, passwordField] {
      if let editor = field.currentEditor() as? NSTextView { editor.string = "" }
      field.stringValue = ""
    }
  }
  func releaseRequest() { request = nil; clearCredentials() }
  override func close() { finish(accept: false); super.close() }
  override func cancelOperation(_ sender: Any?) { finish(accept: false) }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    // Return must first commit an in-progress input-method composition.
    if let editor = firstResponder as? NSTextView, editor.hasMarkedText() { return false }
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76 { finish(accept: true); return true }
    if modifiers.isEmpty, event.keyCode == 53 { finish(accept: false); return true }
    if modifiers == .command, event.charactersIgnoringModifiers == "." { finish(accept: false); return true }
    return super.performKeyEquivalent(with: event)
  }
  func announce() {
    NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
      .announcement: "\(title). \(dialogView.bodyLabel.stringValue)",
      .priority: NSAccessibilityPriorityLevel.high.rawValue])
  }
}
#endif
