import AppKit

@MainActor
final class PermissionPromptView: PageChromePopoverView {
  let symbol = NSImageView()
  let question = NSTextField(wrappingLabelWithString: "")
  let help = NSTextField(wrappingLabelWithString: "Change this any time in Site Controls")
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
  /// The prompt lost first responder (a click into the page): it gives up its keys.
  var onFocusLost: (() -> Void)?
  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned { onFocusLost?() }
    return resigned
  }
  override var acceptsFirstResponder: Bool { hasKeyboard }
  /// The prompt's window is not key when it shows: the first click must reach it (review round 2).
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { onFocusRequest?(); super.mouseDown(with: event) }
  static let preferredWidth: CGFloat = 320, minimumWidth: CGFloat = 260
  init() {
    super.init(frame: CGRect(x: 0, y: 0, width: Self.preferredWidth, height: 156))
    question.font = .systemFont(ofSize: 13, weight: .semibold); question.maximumNumberOfLines = 3
    help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor; help.maximumNumberOfLines = 2
    for child in [symbol, question, help, notNow, allow] { addSubview(child) }
    // Allow looks like the default button from the start (UXC-W2-S7). Return and Escape still
    // answer only once the prompt has the keyboard (bug sweep r6 V-05): see `hasKeyboard`.
    allow.bezelColor = .controlAccentColor
    styleAllowTitle()
    NotificationCenter.default.addObserver(self, selector: #selector(systemColorsChanged), name: NSColor.systemColorsDidChangeNotification, object: nil)
    onReturn = { [weak self] in if self?.hasKeyboard == true { self?.allow.performClick(nil) } }
    onEscape = { [weak self] in if self?.hasKeyboard == true { self?.notNow.performClick(nil) } }
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  /// White or black title on the accent bezel, whichever reads better: a light accent (Yellow,
  /// Graphite in dark) gets a dark title (review r1 #4).
  private(set) var allowTitleColor: NSColor = .white
  private(set) var allowTitleContrast: Double = 0
  private func styleAllowTitle() {
    var accent = NSColor.controlAccentColor
    effectiveAppearance.performAsCurrentDrawingAppearance { accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue }
    func luminance(_ c: NSColor) -> Double {
      let c = c.usingColorSpace(.sRGB) ?? c
      func lin(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
      return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }
    let l = luminance(accent)
    let onWhite = 1.05 / (l + 0.05), onBlack = (l + 0.05) / 0.05
    allowTitleColor = onWhite >= onBlack ? .white : .black
    allowTitleContrast = max(onWhite, onBlack)
    allow.attributedTitle = NSAttributedString(string: allow.title, attributes: [
      .foregroundColor: allowTitleColor, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
  }
  @objc private func systemColorsChanged() { styleAllowTitle() }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); styleAllowTitle() }
  // Compact stack (UX round 1 F17): question, help line under it, buttons at the bottom.
  private func questionHeight(width: CGFloat) -> CGFloat {
    let measured = question.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: max(1, width - 60), height: 64)).height ?? 32
    return max(24, ceil(measured))
  }
  /// The help line wraps at the 260 pt minimum width (Bold Text, larger fonts) instead of clipping.
  private func helpHeight(width: CGFloat) -> CGFloat {
    let measured = help.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: max(1, width - 60), height: 40)).height ?? 16
    return max(16, ceil(measured))
  }
  func preferredHeight(width: CGFloat) -> CGFloat { 16 + questionHeight(width: width) + 8 + helpHeight(width: width) + 16 + 28 + 14 }
  override func layout() {
    super.layout()
    let questionHeight = questionHeight(width: bounds.width)
    symbol.frame = CGRect(x: 16, y: 16, width: 20, height: 24)
    question.frame = CGRect(x: 44, y: 16, width: max(1, bounds.width - 60), height: questionHeight)
    help.frame = CGRect(x: 44, y: question.frame.maxY + 8, width: max(1, bounds.width - 60), height: helpHeight(width: bounds.width))
    notNow.frame = CGRect(x: bounds.width - 188, y: bounds.height - 42, width: 84, height: 28)
    allow.frame = CGRect(x: bounds.width - 96, y: bounds.height - 42, width: 80, height: 28)
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
  /// The first click on a prompt that is not key answers it.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  @objc private func pressed() { onPress?() }
}
