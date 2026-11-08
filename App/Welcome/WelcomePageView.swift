import AppKit
import QuartzCore
import OpenDesign

@MainActor
final class WelcomePageView: NSScrollView {
  static let duration = 8.5
  static let cardTextHeight: CGFloat = 80
  static let copy: [(String, String)] = [
    ("Open your first tab", "Click New Tab in the sidebar or press ⌘T, then type a site or a search."),
    ("Pin what matters", "Drag a tab above the line to pin it. Today's tabs tidy themselves away."),
    ("A Space for every part of life", "Spaces give you separate sidebars for work, projects, and home. Swipe with two fingers to switch."),
    ("Two tabs side by side", "Drag a tab from the sidebar onto the page to make a Split View.")
  ]
  var styleProvider: (() -> SpaceThemeStyle?)?
  var openShortcuts: (() -> Void)?
  var openSettings: (() -> Void)?
  let canvas = WelcomeCanvas()
  let heading = NSTextField(labelWithString: "You're all set.")
  let subheading = NSTextField(labelWithString: "Here are the basics.")
  private(set) var cards: [WelcomeCardView] = []
  private let shortcuts = NSButton(title: "Learn Essential Shortcuts", target: nil, action: nil)
  private let settings = NSButton(title: "Settings", target: nil, action: nil)
  var footerFrame: NSRect { shortcuts.frame.union(settings.frame) }
  private var observers: [NSObjectProtocol] = []
  private var completion: Timer?
  var hasCompletion: Bool { completion != nil }
  private var nextPlaylistCard: Int? = 0
  private var started = false
  private var closed = false
  private(set) var visible = false
  private(set) var activeCard: Int? // zero based inside the view; automation is 1…4
  private(set) var playlistPlaying = false
  private(set) var animating = false
  private(set) var playedCards: [Int] = []
  private(set) var completionCount = 0
  var reduceMotion: Bool {
    #if OPEN_AUTOMATION
    if ProcessInfo.processInfo.environment["OPEN_E2E_REDUCE_MOTION"] == "1" { return true }
    #endif
    return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  init() {
    super.init(frame: .zero)
    drawsBackground = true; hasVerticalScroller = true; autohidesScrollers = true
    borderType = .noBorder; documentView = canvas
    setAccessibilityLabel("Welcome to Open. Here are the basics.")
    heading.font = .systemFont(ofSize: 34, weight: .semibold)
    subheading.font = .systemFont(ofSize: 34, weight: .semibold)
    canvas.addSubview(heading); canvas.addSubview(subheading)
    for (i, copy) in Self.copy.enumerated() {
      let card = WelcomeCardView(index: i, title: copy.0, detail: copy.1)
      card.replay = { [weak self] in self?.replay(card: i) }
      cards.append(card); canvas.addSubview(card)
    }
    for (button, symbol) in [(shortcuts, "keyboard"), (settings, "gearshape")] {
      button.isBordered = false; button.font = .systemFont(ofSize: 14)
      button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      button.imagePosition = .imageLeading; button.contentTintColor = .linkColor
      button.setAccessibilityLabel(button.title); canvas.addSubview(button)
    }
    shortcuts.target = self; shortcuts.action = #selector(showShortcuts)
    settings.target = self; settings.action = #selector(showSettings)
    for i in 0..<3 { cards[i].nextKeyView = cards[i + 1] }
    cards[3].nextKeyView = shortcuts; shortcuts.nextKeyView = settings
    let center = NotificationCenter.default
    for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                 NSWindow.didDeminiaturizeNotification,
                 NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.syncVisibility()
        }
      })
    }
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated {
        guard let self else { return }
        if self.reduceMotion { self.stop(); self.cards.forEach { $0.illustration.finish() } }
        self.updateColors()
      } })
    updateColors()
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  isolated deinit {
    completion?.invalidate()
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
  }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); syncVisibility() }
  override func viewDidHide() { super.viewDidHide(); syncVisibility() }
  override func viewDidUnhide() { super.viewDidUnhide(); syncVisibility() }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
  override func layout() {
    super.layout()
    let width = max(200, contentSize.width), height = contentSize.height
    let column = min(960, max(180, width - 64)), x = (width - column) / 2
    let top: CGFloat = height <= 820 ? 56 : 80
    // At 640 pt the 76 pt header and two 80 pt text blocks leave exactly
    // 120 pt per illustration. Add breathing room as the viewport grows.
    let headerBlock: CGFloat = 76 + min(24, max(0, height - 640))
    let cardWidth = (column - 20) / 2
    let available = (height - top - headerBlock - 2 * Self.cardTextHeight - 20 - 56 - 32) / 2
    let imageHeight = min(max(available, 120), column / 2 * 10 / 16)
    let cardHeight = imageHeight + Self.cardTextHeight, gridTop = top + headerBlock
    let footerTop = gridTop + 2 * cardHeight + 20 + 24
    canvas.frame = CGRect(x: 0, y: 0, width: width, height: max(height, footerTop + 32 + 32))
    heading.frame = CGRect(x: x, y: top, width: column, height: 38)
    subheading.frame = CGRect(x: x, y: top + 38, width: column, height: 38)
    for i in 0..<4 { cards[i].frame = CGRect(x: x + CGFloat(i % 2) * (cardWidth + 20),
      y: gridTop + CGFloat(i / 2) * (cardHeight + 20), width: cardWidth, height: cardHeight) }
    shortcuts.frame = CGRect(x: x, y: footerTop, width: 240, height: 32)
    settings.frame = CGRect(x: x + 264, y: shortcuts.frame.minY, width: 100, height: 32)
    updateColors(); syncVisibility()
  }
  func updateColors() {
    let system: ContentAppearance = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    let style = styleProvider?(), appearance = style?.resolvedAppearance(system: system) ?? system
    let palette = style?.palette(for: appearance), dark = appearance == .dark
    backgroundColor = palette?.background.nsColor ?? (dark ? NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1) : .white)
    let primary = palette?.foregroundPrimary.nsColor ?? (dark ? .white : .black)
    let secondary = palette?.foregroundSecondary.nsColor ?? primary.withAlphaComponent(0.6)
    heading.textColor = primary; subheading.textColor = secondary
    let fill = backgroundColor.blended(withFraction: dark ? 0.04 : 0.06, of: dark ? .white : .black) ?? backgroundColor
    let tint: NSColor
    if let style {
      let field = ThemeField.Evaluator(style: style, windowSize: CGSize(width: 1000, height: 1000), isActive: true)
      let (red, green, blue) = field.color(u: 0.12, v: 0.5)
      tint = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    } else { tint = NSColor(srgbRed: 0.24, green: 0.29, blue: 0.48, alpha: 1) }
    for card in cards {
      card.apply(fill: fill, primary: primary, secondary: secondary,
        background: backgroundColor, sidebarTint: tint, dark: dark)
    }
  }
  func syncVisibility() {
    let shown = !closed && window?.isVisible == true && window?.isMiniaturized == false
      && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor && !NSApp.isHidden
    setVisible(shown)
  }
  private func setVisible(_ shown: Bool) {
    guard shown != visible else { return }; visible = shown
    if !shown { cards.forEach { $0.resetHover() }; halt(); return }
    if reduceMotion { nextPlaylistCard = nil; cards.forEach { $0.illustration.finish() }; return }
    if !started { started = true }
    if let index = nextPlaylistCard { play(index, playlist: true) }
  }
  func replay(card index: Int) {
    guard (0..<4).contains(index), visible, !closed else { return }
    nextPlaylistCard = nil
    if reduceMotion { halt(); activeCard = index; cards[index].illustration.finish(); return }
    play(index, playlist: false)
  }
  private func play(_ index: Int, playlist: Bool) {
    halt(); activeCard = index; playlistPlaying = playlist; animating = true
    playedCards.append(index + 1); if playedCards.count > 32 { playedCards.removeFirst() }
    if playlist { nextPlaylistCard = index }
    cards[index].illustration.play(duration: Self.duration)
    completion = Timer.scheduledTimer(withTimeInterval: Self.duration, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.visible, self.animating, self.activeCard == index else { return }
        self.completion = nil; self.completionCount += 1
        self.cards[index].illustration.finish(); self.animating = false; self.playlistPlaying = false
        if playlist, index < 3 { self.nextPlaylistCard = index + 1; self.play(index + 1, playlist: true) }
        else { self.nextPlaylistCard = nil }
      }
    }
  }
  private func halt() {
    completion?.invalidate(); completion = nil
    for card in cards { card.illustration.freeze() }
    animating = false; playlistPlaying = false
  }
  func stop() { nextPlaylistCard = nil; halt() }
  func close() { closed = true; visible = false; stop() }
  func activateFooter(_ link: String) {
    if link == "shortcuts" { shortcuts.performClick(nil) }
    else if link == "settings" { settings.performClick(nil) }
  }
  func reveal(card: Int) {
    let rect = card == 3 ? cards[card].frame.union(settings.frame) : cards[card].frame
    _ = canvas.scrollToVisible(rect)
  }
  @objc private func showShortcuts() { openShortcuts?() }
  @objc private func showSettings() { openSettings?() }
}

@MainActor
final class WelcomeCanvas: NSView { override var isFlipped: Bool { true } }

@MainActor
final class WelcomeCardView: NSControl {
  let index: Int
  let illustration: WelcomeIllustrationView
  let heading: NSTextField
  let detail: NSTextField
  var replay: (() -> Void)?
  private var tracking: NSTrackingArea?
  private(set) var isHovered = false
  init(index: Int, title: String, detail: String) {
    self.index = index; illustration = WelcomeIllustrationView(kind: index)
    heading = NSTextField(labelWithString: title); self.detail = NSTextField(wrappingLabelWithString: detail)
    super.init(frame: .zero); wantsLayer = true; layer?.cornerRadius = 16; layer?.masksToBounds = true
    heading.font = .systemFont(ofSize: 17, weight: .semibold); self.detail.font = .systemFont(ofSize: 14)
    addSubview(illustration); addSubview(heading); addSubview(self.detail)
    setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("\(title). \(detail)")
    setAccessibilityChildren([])
    setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Replay", target: self, selector: #selector(accessibilityPerformPress))])
    toolTip = "Replay \(title)"
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override var canBecomeKeyView: Bool { true }
  override var focusRingType: NSFocusRingType { get { .exterior } set {} }
  override var focusRingMaskBounds: NSRect { bounds }
  override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill() }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    // inVisibleRect follows bounds. Replacing this area during layout synthesizes
    // a new entered event beneath a stationary pointer and restarts the demo.
    guard tracking == nil else { return }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area); tracking = area
  }
  func resetHover() { isHovered = false }
  override func viewDidHide() { super.viewDidHide(); resetHover() }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { resetHover() } }
  override func mouseEntered(with event: NSEvent) {
    guard !isHovered else { return }
    isHovered = true; replay?()
  }
  override func mouseExited(with event: NSEvent) { resetHover() }
  override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); replay?() }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 49 { replay?() } else { super.keyDown(with: event) }
  }
  override func accessibilityPerformPress() -> Bool { replay?(); return true }
  override func layout() {
    super.layout(); let imageHeight = max(0, bounds.height - WelcomePageView.cardTextHeight)
    illustration.frame = CGRect(x: 0, y: 0, width: bounds.width, height: imageHeight)
    heading.frame = CGRect(x: 16, y: imageHeight + 6, width: max(0, bounds.width - 32), height: 21)
    detail.frame = CGRect(x: 16, y: imageHeight + 29, width: max(0, bounds.width - 32), height: 51)
  }
  func apply(fill: NSColor, primary: NSColor, secondary: NSColor,
    background: NSColor, sidebarTint: NSColor, dark: Bool) {
    layer?.backgroundColor = fill.cgColor; heading.textColor = primary; detail.textColor = secondary
    illustration.apply(background: background, sidebarTint: sidebarTint, dark: dark)
  }
}
