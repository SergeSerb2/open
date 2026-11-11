import AppKit
import QuartzCore
import OpenDesign
import OpenOnboarding
import OpenModel

enum WelcomeColors {
  /// Match a white/black overlay in the content's encoded sRGB space. AppKit's
  /// calibrated-color blend otherwise changes the requested contrast amount.
  static func surface(_ background: NSColor, dark: Bool) -> NSColor {
    guard let rgb = background.usingColorSpace(.sRGB) else { return background }
    let fraction: CGFloat = dark ? 0.04 : 0.06, ink: CGFloat = dark ? 1 : 0
    return NSColor(srgbRed: rgb.redComponent * (1 - fraction) + ink * fraction,
      green: rgb.greenComponent * (1 - fraction) + ink * fraction,
      blue: rgb.blueComponent * (1 - fraction) + ink * fraction, alpha: 1)
  }
}

@MainActor
final class WelcomePageView: NSScrollView {
  static let duration = 8.5
  static let cardTextHeight: CGFloat = 88
  static let copy: [(String, String)] = [
    ("Open your first tab", "Click New Tab in the sidebar or press ⌘T, then type a site or a search."),
    ("Pin what matters", "Drag a tab above the line to pin it. Today's tabs tidy themselves away."),
    ("A Space for every part of life", "Spaces give you separate sidebars for work, projects, and home. Swipe with two fingers to switch."),
    ("Two tabs side by side", "Drag a tab from the sidebar onto the page to make a Split View.")
  ]
  var themeProvider: (() -> SpaceTheme?)?
  var styleProvider: (() -> SpaceThemeStyle?)?
  var openShortcuts: (() -> Void)?
  var openSettings: (() -> Void)?
  let canvas = WelcomeCanvas()
  private let room = OnboardingRoomView(frame: .zero)
  let heading = NSTextField(labelWithString: "You're all set.")
  let subheading = NSTextField(labelWithString: "Here are the basics.")
  private(set) var cards: [WelcomeCardView] = []
  private let shortcuts = WelcomeFooterButton(title: "Essential Shortcuts", target: nil, action: nil)
  private let settings = WelcomeFooterButton(title: "Settings", target: nil, action: nil)
  func footerLabelFrame(_ button: NSButton) -> NSRect {
    (button as? WelcomeFooterButton)?.labelRect ?? button.bounds
  }
  var footerFrame: NSRect { shortcuts.frame.union(settings.frame) }
  #if OPEN_AUTOMATION
  var footerLinks: [NSButton] { [shortcuts, settings] }
  #endif
  private var observers: [NSObjectProtocol] = []
  private var appearanceObservation: NSKeyValueObservation?
  private struct ColorInputs: Equatable {
    let style: SpaceThemeStyle?
    let system: ContentAppearance
    let key: Bool
  }
  private var colorInputs: ColorInputs?
  private var completion: Timer?
  var hasCompletion: Bool { completion != nil }
  private var nextPlaylistCard: Int? = 0
  private var started = false
  private var closed = false
  private(set) var visible = false
  private(set) var activeCard: Int? { // zero based inside the view; automation is 1…4
    didSet { for card in cards { card.isActive = card.index == activeCard } }
  }
  private(set) var playlistPlaying = false
  private(set) var animating = false
  private(set) var playedCards: [Int] = []
  private(set) var completionCount = 0
  var reduceMotion: Bool {
    #if OPEN_AUTOMATION
    if (NSApp.delegate as? AppDelegate)?.options.reduceMotion == true
      || ProcessInfo.processInfo.environment["OPEN_E2E_REDUCE_MOTION"] == "1" { return true }
    #endif
    return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  init() {
    super.init(frame: .zero)
    drawsBackground = true; hasVerticalScroller = true; autohidesScrollers = true
    // The content pane already accounts for browser chrome. A second automatic
    // titlebar inset offsets the whole page and consumes its bottom margin.
    automaticallyAdjustsContentInsets = false; contentInsets = NSEdgeInsets()
    borderType = .noBorder; documentView = canvas
    setAccessibilityLabel("Welcome to Open. Here are the basics.")
    room.isWelcome = true; canvas.addSubview(room)
    heading.font = .systemFont(ofSize: 40, weight: .semibold)
    subheading.font = .systemFont(ofSize: 40, weight: .semibold)
    canvas.addSubview(heading); canvas.addSubview(subheading)
    for (i, copy) in Self.copy.enumerated() {
      let card = WelcomeCardView(index: i, title: copy.0, detail: copy.1)
      card.replay = { [weak self] in self?.replay(card: i) }
      cards.append(card); canvas.addSubview(card)
    }
    for (button, symbol) in [(shortcuts, "keyboard"), (settings, "gearshape")] {
      button.isBordered = false; button.font = .systemFont(ofSize: 13, weight: .medium)
      button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      button.imagePosition = .imageLeading; button.contentTintColor = .linkColor
      button.setAccessibilityLabel(button.title); canvas.addSubview(button)
    }
    shortcuts.target = self; shortcuts.action = #selector(showShortcuts)
    settings.target = self; settings.action = #selector(showSettings)
    for i in 0..<3 { cards[i].nextKeyView = cards[i + 1] }
    cards[3].nextKeyView = shortcuts; shortcuts.nextKeyView = settings
    let center = NotificationCenter.default
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.updateColors() }
      })
    }
    appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.updateColors() }
    }
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
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateColors(); syncVisibility() }
  override func viewDidHide() { super.viewDidHide(); syncVisibility() }
  override func viewDidUnhide() { super.viewDidUnhide(); syncVisibility() }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
  override func layout() {
    super.layout()
    let width = max(200, contentSize.width), height = contentSize.height
    let column = min(1100, max(180, width - 96)), x = (width-column)/2
    let top: CGFloat = 48, gridTop: CGFloat = 170, gap: CGFloat = 16
    let cardWidth = (column-gap)/2
    let imageHeight = max(96, min(230, (height-gridTop-84-gap)/2-Self.cardTextHeight))
    let cardHeight = imageHeight+Self.cardTextHeight
    let footerTop = gridTop+cardHeight*2+gap+22
    canvas.frame = CGRect(x: 0, y: 0, width: width, height: max(height, footerTop+62))
    room.frame = canvas.bounds
    heading.frame = CGRect(x: x, y: top, width: column-120, height: 44)
    subheading.frame = CGRect(x: x, y: top+43, width: column-120, height: 44)
    for label in [heading,subheading] {
      label.attributedStringValue = NSAttributedString(string: label.stringValue, attributes: [.font: label.font!, .kern: -1.2,
        .foregroundColor: label.textColor ?? .white])
    }
    for i in 0..<4 { cards[i].frame = CGRect(x: x+CGFloat(i%2)*(cardWidth+gap),
      y: gridTop+CGFloat(i/2)*(cardHeight+gap), width: cardWidth, height: cardHeight) }
    shortcuts.frame = CGRect(x: x, y: footerTop, width: 184, height: 32)
    settings.frame = CGRect(x: x+194, y: footerTop, width: 112, height: 32)
    updateColors(); syncVisibility()
  }
  func updateColors() {
    // A Space can override the window appearance. The system fallback must
    // come from the app, not from that already-overridden window/view.
    let system: ContentAppearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    let style = styleProvider?()
    let inputs = ColorInputs(style: style, system: system, key: window?.isKeyWindow == true)
    guard inputs != colorInputs else { return }; colorInputs = inputs
    // Welcome is a view into the dark room in either system appearance.
    let dark = true
    backgroundColor = OnboardingTokens.Room.far
    let primary = OnboardingTokens.Room.white
    let secondary = primary.withAlphaComponent(0.60)
    let header = WelcomeTextColors.pair(primary: primary, secondary: primary.withAlphaComponent(0.52), surface: OnboardingTokens.Room.lit)
    heading.textColor = header.primary; subheading.textColor = header.secondary
    shortcuts.contentTintColor = primary.withAlphaComponent(0.9); settings.contentTintColor = primary.withAlphaComponent(0.9)
    let fill = WelcomeTextColors.opaque(primary.withAlphaComponent(0.055), over: backgroundColor)
    let cardText = WelcomeTextColors.pair(primary: primary, secondary: secondary, surface: OnboardingTokens.Room.lit)
    let tint: NSColor
    if let style {
      let field = ThemeField.Evaluator(style: style, windowSize: CGSize(width: 1000, height: 1000), isActive: true)
      let (red, green, blue) = field.color(u: 0.12, v: 0.5)
      tint = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    } else { tint = OnboardingTokens.Room.space }
    room.tint = tint
    for card in cards { card.illustration.applyTheme(themeProvider?(),dark: style?.resolvedAppearance(system: system) == .dark) }
    for card in cards {
      card.apply(fill: fill, primary: cardText.primary, secondary: cardText.secondary,
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
  /// Automation: the hover area this card installed, matched by identity.
  /// AppKit may add its own tooltip area to the same view.
  var ownTrackingAreaCount: Int {
    guard let tracking else { return 0 }
    return trackingAreas.filter { area in area === tracking }.count
  }
  var isActive = false { didSet { updateBorder() } }
  private var keyboardFocused = false
  private func updateBorder() {
    layer?.borderWidth = 1
    layer?.borderColor = (isHovered || keyboardFocused ? OnboardingTokens.Room.sunMiddle.withAlphaComponent(0.6):NSColor.white.withAlphaComponent(0.09)).cgColor
  }
  private(set) var isHovered = false
  init(index: Int, title: String, detail: String) {
    self.index = index; illustration = WelcomeIllustrationView(kind: index)
    heading = NSTextField(labelWithString: title); self.detail = NSTextField(wrappingLabelWithString: detail)
    super.init(frame: .zero); wantsLayer = true; layer?.cornerRadius = 16; layer?.masksToBounds = true
    heading.font = .systemFont(ofSize: 15, weight: .semibold); self.detail.font = .systemFont(ofSize: 12.5)
    addSubview(illustration); addSubview(heading); addSubview(self.detail); updateBorder()
    setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("\(title). \(detail)")
    setAccessibilityChildren([])
    setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Replay", target: self, selector: #selector(accessibilityPerformPress))])
    toolTip = "Replay \(title)"
    // One hover area for the card's life. inVisibleRect follows bounds, so it
    // never needs replacing (a replaced area synthesizes a new entered event
    // beneath a stationary pointer and restarts the demo). Installing it here,
    // not in updateTrackingAreas, guarantees it exists even when AppKit never
    // calls updateTrackingAreas for this view.
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area); tracking = area
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
    // Restore the single hover area only if something removed it.
    if let tracking, !trackingAreas.contains(where: { $0 === tracking }) { addTrackingArea(tracking) }
  }
  func resetHover() { isHovered = false; updateBorder() }
  override func viewDidHide() { super.viewDidHide(); resetHover() }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { resetHover() } }
  override func mouseEntered(with event: NSEvent) {
    guard !isHovered else { return }
    isHovered = true; updateBorder(); replay?()
  }
  override func mouseExited(with event: NSEvent) { resetHover() }
  override func becomeFirstResponder() -> Bool { keyboardFocused = true; updateBorder(); return true }
  override func resignFirstResponder() -> Bool { keyboardFocused = false; updateBorder(); return true }
  override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); updateBorder(); replay?() }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 49 { replay?() } else { super.keyDown(with: event) }
  }
  override func accessibilityPerformPress() -> Bool { replay?(); return true }
  override func layout() {
    super.layout(); let imageHeight = max(0, bounds.height - WelcomePageView.cardTextHeight)
    illustration.frame = CGRect(x: 12,y: 12,width: max(0,bounds.width-24),height: max(0,imageHeight-12))
    illustration.layer?.cornerRadius = 8
    heading.frame = CGRect(x: 18, y: imageHeight + 12, width: max(0, bounds.width - 36), height: 19)
    detail.frame = CGRect(x: 18, y: imageHeight + 34, width: max(0, bounds.width - 36), height: 48)
  }
  func apply(fill: NSColor, primary: NSColor, secondary: NSColor,
    background: NSColor, sidebarTint: NSColor, dark: Bool) {
    layer?.backgroundColor = fill.cgColor; heading.textColor = primary; detail.textColor = secondary
    illustration.apply(background: background, sidebarTint: sidebarTint, dark: dark)
  }
}

/// Native controls with explicit room surfaces, including an inactive-window ink.
@MainActor private final class WelcomeFooterButton: NSButton {
  private var hovered = false
  override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
  required init?(coder: NSCoder) { nil }
  override func updateTrackingAreas() {
    super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  var labelRect: CGRect {
    let font = font ?? .systemFont(ofSize: 13,weight: .medium)
    let size = (title as NSString).size(withAttributes: [.font:font])
    return CGRect(x: 37,y: (bounds.height-size.height)/2,width: min(size.width,bounds.width-51),height: size.height)
  }
  override func draw(_ dirtyRect: NSRect) {
    OnboardingTokens.Room.white.withAlphaComponent(hovered ? 0.14:0.08).setFill()
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5,dy: 0.5),xRadius: 10,yRadius: 10); path.fill()
    OnboardingTokens.Room.white.withAlphaComponent(0.1).setStroke(); path.lineWidth = 1; path.stroke()
    let ink = OnboardingTokens.Room.white.withAlphaComponent(0.9)
    let symbol = image?.withSymbolConfiguration(.init(pointSize: 14,weight: .medium))?.withSymbolConfiguration(.init(paletteColors: [ink]))
    symbol?.draw(in: CGRect(x: 14,y: (bounds.height-15)/2,width: 15,height: 15),from: .zero,operation: .sourceOver,fraction: 1,respectFlipped: isFlipped,hints: nil)
    (title as NSString).draw(in: labelRect,withAttributes: [.font:font ?? .systemFont(ofSize: 13,weight: .medium),.foregroundColor:ink])
    if window?.firstResponder === self { ink.setStroke(); path.lineWidth = 2; path.stroke() }

  }
}
