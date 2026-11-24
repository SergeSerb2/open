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
    allow.accentFill = true
    styleAllowTitle()
    NotificationCenter.default.addObserver(self, selector: #selector(systemColorsChanged), name: NSColor.systemColorsDidChangeNotification, object: nil)
    onReturn = { [weak self] in if self?.hasKeyboard == true { self?.allow.performClick(nil) } }
    onEscape = { [weak self] in if self?.hasKeyboard == true { self?.notNow.performClick(nil) } }
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  /// Allow's title is white on the accent bezel, as on macOS default buttons. Only a bezel so light
  /// that white text falls under 3:1 (a very light custom accent) gets a dark title. Measured
  /// against the colour the bezel is drawn with (review r2 #4).
  private(set) var allowTitleColor: NSColor = .white
  /// Automation only: draws Allow on this bezel colour instead of the system accent.
  var bezelOverride: NSColor? { didSet { allow.fillOverride = bezelOverride; styleAllowTitle() } }
  private func styleAllowTitle() {
    var bezel = NSColor.systemBlue
    effectiveAppearance.performAsCurrentDrawingAppearance {
      bezel = allow.fillColor.usingColorSpace(.sRGB) ?? .systemBlue
    }
    allowTitleColor = Self.contrast(.white, bezel) >= 3 ? .white : .black
    allow.attributedTitle = NSAttributedString(string: allow.title, attributes: [
      .foregroundColor: allowTitleColor, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
  }
  static func luminance(_ color: NSColor) -> Double {
    let c = color.usingColorSpace(.sRGB) ?? color
    func lin(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
  }
  static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
    let la = luminance(a), lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  }
  /// Automation evidence from the drawn pixels: renders Allow as it draws on screen into an sRGB
  /// bitmap, takes the bezel colour (the most common interior pixel) and the title colour (the
  /// interior pixel farthest from it in luminance), and returns their contrast and whether the
  /// title is light. (A cacheDisplay bitmap is tagged Generic RGB and washed the colours out.)
  func drawnAllowContrast() -> [String: Any] {
    let button = allow
    let w = Int(button.bounds.width * 2), h = Int(button.bounds.height * 2)
    guard w > 8, h > 8, let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [:] }
    context.scaleBy(x: 2, y: 2)
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    button.displayIgnoringOpacity(button.bounds, in: graphics)
    guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return [:] }
    var counts: [UInt32: Int] = [:]
    for y in (h / 4)..<(h * 3 / 4) {
      for x in (w / 6)..<(w * 5 / 6) {
        let o = (y * w + x) * 4
        guard data[o + 3] > 230 else { continue }
        counts[UInt32(data[o]) << 16 | UInt32(data[o + 1]) << 8 | UInt32(data[o + 2]), default: 0] += 1
      }
    }
    func color(_ key: UInt32) -> NSColor {
      NSColor(srgbRed: CGFloat((key >> 16) & 0xFF) / 255, green: CGFloat((key >> 8) & 0xFF) / 255, blue: CGFloat(key & 0xFF) / 255, alpha: 1)
    }
    guard let bezelKey = counts.max(by: { $0.value < $1.value })?.key else { return [:] }
    let bezel = color(bezelKey), lb = Self.luminance(bezel)
    guard let titleKey = counts.keys.max(by: { abs(Self.luminance(color($0)) - lb) < abs(Self.luminance(color($1)) - lb) }) else { return [:] }
    let title = color(titleKey)
    return ["contrast": Self.contrast(bezel, title), "titleLight": Self.luminance(title) > lb,
            "bezel": [bezel.redComponent, bezel.greenComponent, bezel.blueComponent].map { Double($0) },
            "title": [title.redComponent, title.greenComponent, title.blueComponent].map { Double($0) }]
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
  /// The default button (Allow): filled with the accent itself, as macOS default buttons look. A
  /// `bezelColor` push button is drawn lighter than the accent, which left white text under 3:1
  /// (review r2 #4). The title is drawn by the cell on top of this fill.
  var accentFill = false { didSet { isBordered = !accentFill; needsDisplay = true } }
  var fillOverride: NSColor? { didSet { needsDisplay = true } }
  /// The accent as a default button shows it. The popover's vibrant appearance resolves
  /// controlAccentColor to a lighter tint (Blue became #6E91F7, white text 2.98:1), so resolve it
  /// under the plain light or dark appearance instead.
  var fillColor: NSColor {
    if let fillOverride { return fillOverride }
    let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    var color = NSColor.controlAccentColor
    NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
      color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .controlAccentColor
    }
    return color
  }
  init(title: String) {
    super.init(frame: .zero); self.title = title; bezelStyle = .rounded
    target = self; action = #selector(pressed)
  }
  /// Inside the popover a vibrant view blends its drawing with the material, which washed the
  /// accent fill out (#007AFF drew as #6E91F7). The filled default button draws its true colours.
  override var allowsVibrancy: Bool { !accentFill && super.allowsVibrancy }
  override func draw(_ dirtyRect: NSRect) {
    if accentFill {
      let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 6, yRadius: 6)
      var fill = fillColor
      if isHighlighted { fill = fill.blended(withFraction: 0.18, of: .black) ?? fill }
      fill.setFill(); shape.fill()
    }
    super.draw(dirtyRect)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  /// The first click on a prompt that is not key answers it.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  @objc private func pressed() { onPress?() }
}
