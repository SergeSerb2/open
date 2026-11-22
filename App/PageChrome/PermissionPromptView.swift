import AppKit

@MainActor
final class PermissionPromptView: PageChromePopoverView {
  let symbol = NSImageView()
  let question = NSTextField(wrappingLabelWithString: "")
  let help = NSTextField(labelWithString: "Click the lock to change this any time")
  let allow = PermissionButton(title: "Allow")
  let notNow = PermissionButton(title: "Not Now")
  override var isFlipped: Bool { true }
  /// Off until the user clicks into the prompt: a prompt that just appeared takes no keys, so a
  /// Return or Escape typed into the page never answers it (bug sweep r6 V-05).
  var hasKeyboard = false {
    didSet { allow.keyEquivalent = hasKeyboard ? "\r" : ""; notNow.keyEquivalent = hasKeyboard ? "\u{1b}" : "" }
  }
  /// A click on the prompt's background (not a button) asks for the keyboard.
  var onFocusRequest: (() -> Void)?
  override var acceptsFirstResponder: Bool { hasKeyboard }
  override func mouseDown(with event: NSEvent) { onFocusRequest?(); super.mouseDown(with: event) }
  init() {
    super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 156))
    question.font = .systemFont(ofSize: 13, weight: .semibold); question.maximumNumberOfLines = 3
    help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor
    for child in [symbol, question, help, notNow, allow] { addSubview(child) }
    onReturn = { [weak self] in if self?.hasKeyboard == true { self?.allow.performClick(nil) } }
    onEscape = { [weak self] in if self?.hasKeyboard == true { self?.notNow.performClick(nil) } }
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  func preferredHeight(width: CGFloat) -> CGFloat {
    let questionHeight = question.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: max(1, width - 60), height: 64)).height ?? 48
    return max(156, 108 + questionHeight)
  }
  override func layout() {
    super.layout()
    symbol.frame = CGRect(x: 16, y: 16, width: 20, height: 24)
    question.frame = CGRect(x: 44, y: 16, width: max(1, bounds.width - 60), height: bounds.height - 108)
    help.frame = CGRect(x: 16, y: bounds.height - 80, width: max(1, bounds.width - 32), height: 16)
    notNow.frame = CGRect(x: bounds.width - 188, y: bounds.height - 44, width: 84, height: 28)
    allow.frame = CGRect(x: bounds.width - 96, y: bounds.height - 44, width: 80, height: 28)
  }
}

@MainActor
final class PermissionButton: NSButton {
  var onPress: (() -> Void)?
  init(title: String) {
    super.init(frame: .zero); self.title = title; bezelStyle = .rounded
    target = self; action = #selector(pressed)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  @objc private func pressed() { onPress?() }
}
