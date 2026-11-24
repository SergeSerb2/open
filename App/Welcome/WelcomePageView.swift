import AppKit
import QuartzCore
import OpenOnboarding

/// The basics page: heading, a four-step accordion and one clip panel, laid out
/// and timed as measured on the reference page (docs/re/onboarding.md §6).
/// All motion is Core Animation; layout runs only for size or step changes.
@MainActor
final class WelcomePageView: NSScrollView {
  static let steps: [WelcomeStepView.Copy] = [
    .init(title: "Pin what matters", detail: "Drag a tab above the line to pin it. Pinned tabs stay put; today's tabs tidy themselves away.",
      symbol: "pin", keys: []),
    .init(title: "A Space for every part of life", detail: "Spaces give you separate sidebars for work, projects, and home. Click a Space or swipe to switch.",
      symbol: "square.stack", keys: []),
    .init(title: "Two tabs side by side", detail: "Drag a tab from the sidebar to the side of the page to make a Split View.",
      symbol: "rectangle.split.2x1", keys: []),
    .init(title: "Open your first tab", detail: "Click New Tab in the sidebar, or press",
      symbol: "plus", keys: ["⌘", "T"]),
  ]
  /// Reveal schedule after the page first shows (seconds), measured at 60 fps.
  enum Reveal {
    static let logo = 0.28, heading = 1.2, steps = 2.26, clip = 2.9, links = 3.85, fade = 0.28
  }
  static var cardDurations: [Double] { Array(repeating: WelcomeClips.duration, count: 4) }

  var openShortcuts: (() -> Void)?
  var openHelp: (() -> Void)?
  let canvas = WelcomeCanvas()
  private let backdrop = WelcomeBackdropView()
  /// The clip deliberately runs past the page's right edge. This static strip, a copy of the backdrop
  /// behind it, fades the clip into the page there. Rendered on layout only; no per-frame work.
  private let edgeFade = WelcomeEdgeFadeView()
  private let mark = WelcomeMarkView()
  let heading = NSTextField(labelWithString: "You're all set.")
  let subheading = NSTextField(labelWithString: "Here are the basics.")
  private(set) var cards: [WelcomeStepView] = []
  let clipPanel = WelcomeClipPanel()
  private let shortcuts = WelcomeLinkButton(title: "Learn Essential Shortcuts", symbol: "keyboard")
  private let help = WelcomeLinkButton(title: "Help & Resources", symbol: "questionmark.circle")
  var footerLinks: [NSButton] { [shortcuts, help] }
  var footerFrame: NSRect { shortcuts.frame.union(help.frame) }
  func footerLabelFrame(_ button: NSButton) -> NSRect { (button as? WelcomeLinkButton)?.labelRect ?? button.bounds }
  var backgroundTop: NSColor { WelcomeBackdropView.top }

  private var observers: [NSObjectProtocol] = []
  private var completion: Timer?
  private var revealTimer: Timer?
  var hasCompletion: Bool { completion != nil || revealTimer != nil }
  private var appearedAt: CFTimeInterval?
  private var playlistEndedAt: CFTimeInterval?
  var appearanceElapsed: Double { appearedAt.map { CACurrentMediaTime() - $0 } ?? 0 }
  var playlistElapsed: Double { appearedAt.map { (playlistEndedAt ?? CACurrentMediaTime()) - $0 } ?? 0 }
  private var started = false
  private var closed = false
  private(set) var visible = false
  private(set) var revealed = false
  private(set) var activeCard: Int? { didSet { if activeCard != oldValue { relayoutSteps(animated: activeCard != nil && oldValue != nil && !reduceMotion) } } }
  private(set) var playlistPlaying = false
  /// A clip is playing (or about to show its first frame).
  private(set) var animating = false
  private(set) var playedCards: [Int] = []
  private(set) var completionCount = 0
  private(set) var ended = false
  /// Interrupted clip: where to resume when the page shows again.
  private var paused: (index: Int, playlist: Bool, elapsed: Double)?
  private var clipStartedAt: CFTimeInterval?
  private var clipOffset: Double = 0
  var reduceMotion: Bool {
    (NSApp.delegate as? AppDelegate)?.options.resolvedReduceMotion
      ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  init() {
    super.init(frame: .zero)
    drawsBackground = true; backgroundColor = WelcomeBackdropView.top
    hasVerticalScroller = true; autohidesScrollers = true
    // The content pane already accounts for browser chrome.
    automaticallyAdjustsContentInsets = false; contentInsets = NSEdgeInsets()
    borderType = .noBorder; documentView = canvas
    appearance = NSAppearance(named: .aqua)
    setAccessibilityLabel("Welcome to Open. Here are the basics.")
    canvas.wantsLayer = true; canvas.layer?.masksToBounds = true
    canvas.addSubview(backdrop); canvas.addSubview(mark)
    for label in [heading, subheading] {
      label.font = .systemFont(ofSize: 32, weight: .heavy)
      label.textColor = WelcomeStyle.ink
      label.wantsLayer = true
      canvas.addSubview(label)
    }
    canvas.addSubview(clipPanel)
    canvas.addSubview(edgeFade)
    for (i, copy) in Self.steps.enumerated() {
      let card = WelcomeStepView(index: i, copy: copy)
      card.press = { [weak self] in self?.replay(card: i) }
      cards.append(card); canvas.addSubview(card)
    }
    clipPanel.replay = { [weak self] in self?.replayAll() }
    for button in [shortcuts, help] { canvas.addSubview(button) }
    shortcuts.target = self; shortcuts.action = #selector(showShortcuts)
    help.target = self; help.action = #selector(showHelp)
    for i in 0..<3 { cards[i].nextKeyView = cards[i + 1] }
    cards[3].nextKeyView = clipPanel.replayAll; clipPanel.replayAll.nextKeyView = shortcuts; shortcuts.nextKeyView = help
    let center = NotificationCenter.default
    for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                 NSWindow.didDeminiaturizeNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.syncVisibility() }
      })
    }
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated {
        guard let self, self.reduceMotion else { return }
        self.finishReveal(); self.stop()
      } })
    activeCard = 0
    cards[0].setActive(true, animated: false)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  isolated deinit {
    completion?.invalidate(); revealTimer?.invalidate()
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
  }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); syncVisibility() }
  override func viewDidHide() { super.viewDidHide(); syncVisibility() }
  override func viewDidUnhide() { super.viewDidUnhide(); syncVisibility() }

  // MARK: Layout

  struct Metrics {
    var column: CGRect = .zero, mark: CGRect = .zero, heading: CGRect = .zero, subheading: CGRect = .zero
    var stepsTop: CGFloat = 0, clip: CGRect = .zero, clipShown: CGRect = .zero, document: CGSize = .zero
  }
  private(set) var metrics = Metrics()

  func computeMetrics(width rawWidth: CGFloat, height: CGFloat) -> Metrics {
    var m = Metrics()
    let width = max(320, rawWidth)
    let margin: CGFloat = 31
    let columnWidth = min(336, width - margin * 2)
    let clipTop = round(height * 0.196), clipBottom = round(height * 0.045)
    let top = clipTop + 10
    m.mark = CGRect(x: margin, y: top, width: 32, height: 47)
    m.heading = CGRect(x: margin, y: top + 66, width: columnWidth + 40, height: 36)
    m.subheading = CGRect(x: margin, y: top + 66 + 35, width: columnWidth + 40, height: 36)
    m.stepsTop = top + 66 + 70 + 24
    let tallest = (0..<4).map { cards[$0].expandedHeight(width: columnWidth) }.max() ?? 182
    let stepsBottom = m.stepsTop + WelcomeStyle.collapsedHeight * 3 + WelcomeStyle.cardGap * 3 + tallest
    m.column = CGRect(x: margin, y: top, width: columnWidth, height: stepsBottom - top)
    let clipX = margin + columnWidth + 32
    if width - clipX >= 260 {
      let clipHeight = max(240, height - clipTop - clipBottom)
      m.clip = CGRect(x: clipX, y: clipTop, width: round(clipHeight * 1.6), height: clipHeight)
      m.document = CGSize(width: width, height: max(height, stepsBottom + 32, m.clip.maxY + clipBottom))
    } else {
      let clipWidth = width - margin * 2
      m.clip = CGRect(x: margin, y: stepsBottom + 24, width: clipWidth, height: round(clipWidth / 1.6))
      m.document = CGSize(width: width, height: max(height, m.clip.maxY + 32))
    }
    m.clipShown = CGRect(x: 0, y: 0, width: min(m.clip.width, m.document.width - m.clip.minX),
      height: min(m.clip.height, m.document.height - m.clip.minY))
    return m
  }

  override func layout() {
    super.layout()
    let m = computeMetrics(width: contentSize.width, height: contentSize.height)
    metrics = m
    canvas.frame = CGRect(origin: .zero, size: m.document)
    backdrop.frame = canvas.bounds
    mark.frame = m.mark
    heading.frame = m.heading; subheading.frame = m.subheading
    clipPanel.shownRect = m.clipShown
    clipPanel.frame = m.clip
    // Shadow room above and below the clip; the strip ends at the page's right edge.
    let fadeWidth: CGFloat = 72
    if m.clipShown.width < m.clip.width - 1 {
      let edge = m.clip.minX + m.clipShown.width
      edgeFade.frame = CGRect(x: edge - fadeWidth, y: max(0, m.clip.minY - 40), width: fadeWidth,
                              height: min(m.document.height, m.clip.maxY + 40) - max(0, m.clip.minY - 40))
      edgeFade.isHidden = false
      edgeFade.render(backdrop: backdrop, scale: window?.backingScaleFactor ?? 2)
    } else { edgeFade.isHidden = true }
    let linkTop: CGFloat = 23.5
    let helpSize = help.intrinsicContentSize, shortcutSize = shortcuts.intrinsicContentSize
    help.frame = CGRect(x: m.document.width - 23.5 - helpSize.width, y: linkTop, width: helpSize.width, height: 42)
    shortcuts.frame = CGRect(x: help.frame.minX - 9 - shortcutSize.width, y: linkTop, width: shortcutSize.width, height: 42)
    relayoutSteps(animated: false)
    syncVisibility()
  }

  /// Step frames for the current active step. Animated changes run as one
  /// spring per moved step on its layer; AppKit sees only the final frames.
  private func relayoutSteps(animated: Bool) {
    guard !cards.isEmpty, metrics.column.width > 0 else { return }
    var y = metrics.stepsTop
    for card in cards {
      let height = card.index == activeCard ? card.expandedHeight(width: metrics.column.width) : WelcomeStyle.collapsedHeight
      let target = CGRect(x: metrics.column.minX, y: y, width: metrics.column.width, height: height)
      if animated, let layer = card.layer, card.frame != target {
        let fromPosition = layer.presentation()?.position ?? layer.position
        let fromBounds = layer.presentation()?.bounds ?? layer.bounds
        card.frame = target
        card.layoutSubtreeIfNeeded()
        let position = WelcomeStyle.spring("position"); position.fromValue = NSValue(point: fromPosition); position.toValue = NSValue(point: layer.position)
        let bounds = WelcomeStyle.spring("bounds"); bounds.fromValue = NSValue(rect: fromBounds); bounds.toValue = NSValue(rect: layer.bounds)
        layer.add(position, forKey: "step-position"); layer.add(bounds, forKey: "step-bounds")
      } else {
        card.frame = target
      }
      y += height + WelcomeStyle.cardGap
    }
  }

  // MARK: Visibility

  func syncVisibility() {
    let shown = !closed && window?.isVisible == true && window?.isMiniaturized == false
      && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor && !NSApp.isHidden
    setVisible(shown)
  }
  private func setVisible(_ shown: Bool) {
    guard shown != visible else { return }; visible = shown
    if !shown { cards.forEach { $0.resetHover() }; pause(); return }
    if !started {
      started = true; appearedAt = CACurrentMediaTime()
      if reduceMotion { finishReveal(); clipPanel.showPoster(0); playlistEndedAt = appearedAt; return }
      startReveal(); return
    }
    resume()
  }

  // MARK: Reveal

  private var revealLayers: [(CALayer, Double)] {
    var layers: [(CALayer, Double)] = []
    if let l = mark.layer { layers.append((l, Reveal.logo)) }
    for label in [heading, subheading] { if let l = label.layer { layers.append((l, Reveal.heading)) } }
    for card in cards { if let l = card.layer { layers.append((l, Reveal.steps)) } }
    if let l = clipPanel.layer { layers.append((l, Reveal.clip)) }
    for button in [shortcuts, help] { if let l = button.layer { layers.append((l, Reveal.links)) } }
    return layers
  }
  private func startReveal() {
    layoutSubtreeIfNeeded()
    let now = CACurrentMediaTime()
    CATransaction.begin(); CATransaction.setDisableActions(true)
    for (layer, delay) in revealLayers {
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 0; fade.toValue = 1; fade.duration = Reveal.fade
      fade.beginTime = layer.convertTime(now, from: nil) + delay
      fade.fillMode = .backwards; fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      layer.add(fade, forKey: "reveal")
    }
    CATransaction.commit()
    // Prepare the first clip under the panel's fade; it starts with the panel.
    clipPanel.play(0, crossfade: false, autostart: false) {}
    playlistPlaying = true
    revealTimer = Timer.scheduledTimer(withTimeInterval: Reveal.clip, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.revealTimer = nil
        self.revealed = true
        guard self.visible, self.playlistPlaying else { return }
        self.play(0, playlist: true, crossfade: false)
      }
    }
  }
  private func finishReveal() {
    revealTimer?.invalidate(); revealTimer = nil
    revealed = true
    for (layer, _) in revealLayers { layer.removeAnimation(forKey: "reveal") }
  }
  private var revealAnimationCount: Int { revealLayers.filter { $0.0.animation(forKey: "reveal") != nil }.count }

  // MARK: Playlist

  func replay(card index: Int) {
    guard (0..<4).contains(index), visible, !closed else { return }
    if playlistPlaying, playlistEndedAt == nil { playlistEndedAt = CACurrentMediaTime() }
    finishReveal()
    play(index, playlist: false, crossfade: true)
  }
  func replayAll() {
    guard visible, !closed else { return }
    finishReveal()
    playlistEndedAt = nil; appearedAt = CACurrentMediaTime()
    play(0, playlist: true, crossfade: true)
  }

  private func play(_ index: Int, playlist: Bool, crossfade: Bool, from offset: Double = 0) {
    halt(release: false)
    ended = false
    let animate = !reduceMotion
    if activeCard != index {
      cards.forEach { $0.setActive($0.index == index, animated: animate) }
      activeCard = index
    }
    playlistPlaying = playlist; animating = true; paused = nil
    // Until this clip's first frame shows, a pause resumes at `offset`. A start time left by the
    // previous clip would count its play time and resume this clip near its end (skipped).
    clipStartedAt = nil; clipOffset = offset
    if offset == 0 { playedCards.append(index + 1); if playedCards.count > 32 { playedCards.removeFirst() } }
    let remaining = max(0.1, WelcomeClips.duration - offset)
    clipPanel.play(index, crossfade: crossfade && animate, autostart: true, from: offset) { [weak self] in
      guard let self, self.animating, self.activeCard == index else { return }
      self.clipStartedAt = CACurrentMediaTime(); self.clipOffset = offset
      self.cards[index].startProgress(duration: WelcomeClips.duration, from: offset)
      self.completion = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated { self?.clipFinished(index) }
      }
    }
  }

  private func clipFinished(_ index: Int) {
    guard visible, animating, activeCard == index else { return }
    completion = nil; completionCount += 1; animating = false
    cards[index].finishProgress()
    if playlistPlaying, index < 3 {
      // The reference holds the last frame for the gap, then moves on.
      clipPanel.stop(release: false)
      completion = Timer.scheduledTimer(withTimeInterval: WelcomeClips.gap, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.completion = nil
          guard self.visible, self.playlistPlaying else { return }
          self.play(index + 1, playlist: true, crossfade: false)
        }
      }
      return
    }
    if playlistPlaying { playlistEndedAt = CACurrentMediaTime() }
    playlistPlaying = false; ended = true
    clipPanel.setEnd(true, animated: !reduceMotion)
  }

  /// Stop timers and the clip, keep the active step.
  private func halt(release: Bool) {
    completion?.invalidate(); completion = nil
    for card in cards { card.stopProgress(hide: true) }
    clipPanel.stop(release: release)
    animating = false
  }

  /// Hidden or covered: pause where we are and release the decoder.
  private func pause() {
    // The reveal's last fades (the links) still run while the first clip already plays: finish them,
    // then pause that clip where it is (bug sweep r3 T6: before, the reveal path left the clip's timer
    // and progress running, so a miniaturized Welcome page never came to rest).
    let revealing = revealTimer != nil || revealAnimationCount > 0
    if revealing { finishReveal() }
    if revealing, !animating {
      if playlistPlaying { paused = (0, true, 0) }
      clipPanel.stop(release: true)
      return
    }
    if animating, let index = activeCard {
      let elapsed = clipOffset + (clipStartedAt.map { CACurrentMediaTime() - $0 } ?? 0)
      paused = (index, playlistPlaying, min(elapsed, WelcomeClips.duration - 0.05))
      completion?.invalidate(); completion = nil
      cards[index].stopProgress(hide: false)
      clipPanel.stop(release: true)
      animating = false
    } else if completion != nil, playlistPlaying, let index = activeCard {
      // In the gap between two clips: resume with the next one.
      completion?.invalidate(); completion = nil
      paused = (min(3, index + 1), true, 0)
      clipPanel.stop(release: true)
    } else {
      clipPanel.stop(release: true)
    }
  }
  private func resume() {
    guard let state = paused, !reduceMotion else { return }
    paused = nil
    play(state.index, playlist: state.playlist, crossfade: false, from: state.elapsed)
  }

  func stop() {
    if playlistPlaying, playlistEndedAt == nil { playlistEndedAt = CACurrentMediaTime() }
    paused = nil; playlistPlaying = false
    halt(release: true)
  }
  func close() { closed = true; visible = false; finishReveal(); stop() }
  var isPaused: Bool { paused != nil }

  // MARK: Links

  func activateFooter(_ link: String) {
    if link == "shortcuts" { shortcuts.performClick(nil) } else if link == "help" { help.performClick(nil) }
  }
  func reveal(card: Int) { _ = canvas.scrollToVisible(cards[card].frame) }
  @objc private func showShortcuts() { openShortcuts?() }
  @objc private func showHelp() { openHelp?() }

  /// Automation: every CA animation the page holds.
  var animationCount: Int {
    revealAnimationCount + clipPanel.animationCount
      + cards.reduce(0) { $0 + ($1.layer?.animationKeys()?.count ?? 0) + ($1.progressAnimating ? 1 : 0) }
  }
}

@MainActor
final class WelcomeCanvas: NSView { override var isFlipped: Bool { true } }

/// Our own light backdrop: a lavender wash with a cool and a warm glow.
/// Static layers; nothing redraws after layout.
@MainActor
final class WelcomeBackdropView: NSView {
  static let top = WelcomeStyle.rgb(0xE6E5F8)
  private let base = CAGradientLayer()
  private let cool = CAGradientLayer()
  private let warm = CAGradientLayer()
  private let haze = CAGradientLayer()
  override init(frame: NSRect) {
    super.init(frame: frame); wantsLayer = true
    base.colors = [Self.top.cgColor, WelcomeStyle.rgb(0xDCDFF4).cgColor]
    base.startPoint = CGPoint(x: 0.5, y: 0); base.endPoint = CGPoint(x: 0.5, y: 1)
    for (layer, color, alpha) in [(cool, WelcomeStyle.rgb(0xB9DCEF), 0.75), (warm, WelcomeStyle.rgb(0xFFD7B5), 0.6),
                                  (haze, WelcomeStyle.rgb(0x8E8FE8), 0.22)] as [(CAGradientLayer, NSColor, CGFloat)] {
      layer.type = .radial
      layer.colors = [color.withAlphaComponent(alpha).cgColor, color.withAlphaComponent(0).cgColor]
      layer.startPoint = CGPoint(x: 0.5, y: 0.5); layer.endPoint = CGPoint(x: 1, y: 1)
    }
    for sub in [base, haze, cool, warm] { layer?.addSublayer(sub) }
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func layout() {
    super.layout()
    CATransaction.begin(); CATransaction.setDisableActions(true)
    let b = bounds
    base.frame = b
    cool.frame = CGRect(x: -b.width * 0.25, y: b.height * 0.45, width: b.width * 0.9, height: b.height * 0.9)
    warm.frame = CGRect(x: b.width * 0.45, y: b.height * 0.55, width: b.width * 0.9, height: b.height * 0.8)
    haze.frame = CGRect(x: b.width * 0.35, y: -b.height * 0.45, width: b.width * 0.9, height: b.height * 0.9)
    CATransaction.commit()
  }
}

/// A copy of the backdrop strip under it, faded in from the left by a static mask.
@MainActor
final class WelcomeEdgeFadeView: NSView {
  private let fade = CAGradientLayer()
  private var rendered: (CGRect, CGFloat)?
  override init(frame: NSRect) {
    super.init(frame: frame); wantsLayer = true; setAccessibilityElement(false)
    fade.startPoint = CGPoint(x: 0, y: 0.5); fade.endPoint = CGPoint(x: 1, y: 0.5)
    fade.colors = [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.cgColor]
    layer?.mask = fade
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  /// Draws the backdrop's layers for this view's frame into one bitmap (at most 72 x page height pt).
  func render(backdrop: NSView, scale: CGFloat) {
    guard rendered.map({ $0.0 != frame || $0.1 != scale }) ?? true, frame.width > 0, frame.height > 0,
          let source = backdrop.layer else { return }
    rendered = (frame, scale)
    let width = Int(ceil(frame.width * scale)), height = Int(ceil(frame.height * scale))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    // The backdrop is flipped (y down); draw it top-down, offset to this strip.
    context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: scale, y: -scale)
    context.translateBy(x: -frame.minX, y: -frame.minY)
    source.render(in: context)
    CATransaction.begin(); CATransaction.setDisableActions(true)
    layer?.contents = context.makeImage(); layer?.contentsScale = scale; fade.frame = bounds
    CATransaction.commit()
  }
}

/// Open's doorway mark, drawn once at the backing scale.
@MainActor
final class WelcomeMarkView: NSView {
  override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay; setAccessibilityElement(false) }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) { OnboardingBrandMark.draw(in: bounds.insetBy(dx: 1, dy: 1), flipped: true) }
}

/// Top-right link: a frosted white button with a symbol and a label.
@MainActor
final class WelcomeLinkButton: NSButton {
  private var hovered = false
  private let symbol: String
  private let labelFont = NSFont.systemFont(ofSize: 15, weight: .medium)
  init(title: String, symbol: String) {
    self.symbol = symbol
    super.init(frame: .zero)
    self.title = title; isBordered = false; wantsLayer = true
    setAccessibilityLabel(title)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize {
    let width = (title as NSString).size(withAttributes: [.font: labelFont]).width
    return NSSize(width: ceil(width) + 26 + 20 + 10 + 24, height: 42)
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  var labelRect: CGRect {
    let size = (title as NSString).size(withAttributes: [.font: labelFont])
    return CGRect(x: 26 + 20 + 10, y: (bounds.height - size.height) / 2, width: min(size.width, bounds.width - 66), height: size.height)
  }
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
    NSColor.white.withAlphaComponent(hovered || isHighlighted ? 0.92 : 0.72).setFill(); path.fill()
    WelcomeStyle.cardBorder.setStroke(); path.lineWidth = 1; path.stroke()
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))?
      .withSymbolConfiguration(.init(paletteColors: [WelcomeStyle.ink]))
    image?.draw(in: CGRect(x: 26, y: (bounds.height - 18) / 2, width: 20, height: 18), from: .zero, operation: .sourceOver,
      fraction: 1, respectFlipped: true, hints: nil)
    (title as NSString).draw(in: labelRect, withAttributes: [.font: labelFont, .foregroundColor: WelcomeStyle.ink])
    if window?.firstResponder === self { NSColor.keyboardFocusIndicatorColor.setStroke(); path.lineWidth = 2; path.stroke() }
  }
}
