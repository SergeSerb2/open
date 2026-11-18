import AppKit
import AVFoundation
import QuartzCore

/// The four bundled clips, recorded from the real app (tools/basics). Each has
/// a still poster (its last frame) and a blurred copy for the end state.
enum WelcomeClips {
  static let names = ["pin", "spaces", "split", "newtab"]
  /// Clip length; the playlist advances after this plus `gap` (reference: 9.0 s period).
  static let duration: Double = 8.5
  static let gap: Double = 0.5
  static func movie(_ index: Int) -> URL? { Bundle.main.url(forResource: "basics-\(names[index])", withExtension: "mp4") }
  static func poster(_ index: Int, blurred: Bool = false) -> CGImage? {
    guard let url = Bundle.main.url(forResource: "basics-\(names[index])-\(blurred ? "blur" : "poster")", withExtension: "jpg"),
      let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
  }
}

/// One clip surface for the whole page. The decoder exists only while a clip
/// plays; a poster layer covers every switch so the page never shows black.
@MainActor
final class WelcomeClipPanel: NSView {
  private let clip = CALayer()
  private let playerLayer = AVPlayerLayer()
  private let poster = CALayer()
  private let endCover = CALayer()
  let replayAll = WelcomeReplayAllButton()
  private var player: AVPlayer?
  private var readyObservation: NSKeyValueObservation?
  private var posters: [Int: CGImage] = [:]
  private var blurred: [Int: CGImage] = [:]
  private(set) var loadedClip: Int?
  private(set) var showsEnd = false
  var replay: (() -> Void)?
  /// Automation: a live decoder (player with an item) exists.
  var hasDecoder: Bool { player?.currentItem != nil }
  var isPlaying: Bool { (player?.rate ?? 0) > 0 }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    guard let root = layer else { return }
    root.shadowColor = NSColor.black.cgColor; root.shadowOpacity = 0.12; root.shadowRadius = 18
    root.shadowOffset = CGSize(width: 0, height: -6)
    clip.cornerRadius = WelcomeStyle.cardRadius; clip.cornerCurve = .continuous; clip.masksToBounds = true
    clip.borderWidth = 1; clip.borderColor = WelcomeStyle.cardBorder.cgColor
    clip.backgroundColor = NSColor.white.cgColor
    playerLayer.videoGravity = .resizeAspectFill
    poster.contentsGravity = .resizeAspectFill
    endCover.contentsGravity = .resizeAspectFill; endCover.opacity = 0
    endCover.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
    for sub in [playerLayer, poster, endCover] { clip.addSublayer(sub) }
    root.addSublayer(clip)
    replayAll.isHidden = true; replayAll.alphaValue = 0
    replayAll.target = self; replayAll.action = #selector(replayPressed)
    addSubview(replayAll)
    setAccessibilityElement(false)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }

  /// The rectangle of the clip that the page shows (it may run past the page).
  var shownRect: CGRect = .zero
  override func layout() {
    super.layout()
    CATransaction.begin(); CATransaction.setDisableActions(true)
    clip.frame = bounds
    layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: WelcomeStyle.cardRadius, cornerHeight: WelcomeStyle.cardRadius, transform: nil)
    for sub in [playerLayer, poster, endCover] { sub.frame = clip.bounds }
    CATransaction.commit()
    let visible = shownRect.isEmpty ? bounds : shownRect
    let size = replayAll.intrinsicContentSize
    replayAll.frame = CGRect(x: round(visible.midX - size.width / 2), y: round(visible.midY - size.height / 2),
      width: size.width, height: size.height)
  }

  private func image(_ index: Int) -> CGImage? {
    if let cached = posters[index] { return cached }
    let image = WelcomeClips.poster(index); posters[index] = image; return image
  }
  private func blurredImage(_ index: Int) -> CGImage? {
    if let cached = blurred[index] { return cached }
    let image = WelcomeClips.poster(index, blurred: true); blurred[index] = image; return image
  }

  /// Still state: the poster of a step, no decoder (Reduce Motion, before play).
  func showPoster(_ index: Int) {
    stop(release: true)
    CATransaction.begin(); CATransaction.setDisableActions(true)
    poster.contents = image(index); poster.opacity = 1
    CATransaction.commit()
    loadedClip = index; setEnd(false, animated: false)
  }

  /// Play one clip, from its start or from `offset` (a resume). `started` runs
  /// when its first frame shows, so the page starts its timer and progress in
  /// step with the picture. With `autostart: false` the clip is prepared and
  /// held on its first frame until the next `play` of the same clip.
  func play(_ index: Int, crossfade: Bool, autostart: Bool, from offset: Double = 0,
            started: @escaping @MainActor () -> Void) {
    readyObservation = nil
    if let player, prepared == index, offset == 0, autostart {
      prepared = nil; player.play(); started(); return
    }
    prepared = nil
    guard let url = WelcomeClips.movie(index) else { showPoster(index); started(); return }
    // Cover the switch with the frame now on screen. Each poster is its clip's
    // last frame, which is also what a finished clip shows.
    CATransaction.begin(); CATransaction.setDisableActions(true)
    if poster.opacity < 1 || poster.contents == nil { poster.contents = loadedClip.flatMap(image) ?? image(index) }
    poster.removeAllAnimations(); poster.opacity = 1
    CATransaction.commit()
    setEnd(false, animated: crossfade)
    self.player?.pause()
    // A fresh player per clip: its layer reports readiness for this item only.
    let item = AVPlayerItem(url: url)
    let player = AVPlayer(playerItem: item)
    player.isMuted = true; player.preventsDisplaySleepDuringVideoPlayback = false
    player.actionAtItemEnd = .pause
    if offset > 0 { player.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    self.player = player
    playerLayer.player = player
    loadedClip = index
    let reveal: @MainActor () -> Void = { [weak self] in
      guard let self, self.loadedClip == index, self.player === player else { return }
      self.readyObservation = nil
      if autostart { player.play() } else { self.prepared = index }
      CATransaction.begin()
      if crossfade {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.28
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        self.poster.add(fade, forKey: "crossfade")
      }
      CATransaction.setDisableActions(true); self.poster.opacity = 0
      CATransaction.commit()
      if autostart { started() }
    }
    readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
      guard layer.isReadyForDisplay else { return }
      DispatchQueue.main.async { MainActor.assumeIsolated { reveal() } }
    }
  }
  private var prepared: Int?

  /// Pause; with `release`, drop the player and its decoder. The poster then
  /// shows the paused frame (taken once, off the main thread).
  func stop(release: Bool) {
    readyObservation = nil; prepared = nil
    guard let player else { return }
    player.pause()
    guard release else { return }
    let time = player.currentTime()
    let asset = player.currentItem?.asset
    CATransaction.begin(); CATransaction.setDisableActions(true)
    if poster.opacity < 1, let index = loadedClip { poster.contents = image(index) }
    poster.removeAllAnimations(); poster.opacity = 1
    CATransaction.commit()
    player.replaceCurrentItem(with: nil)
    playerLayer.player = nil
    self.player = nil
    if let asset, let index = loadedClip, time.seconds > 0.05, time.seconds < WelcomeClips.duration - 0.05 {
      let generator = AVAssetImageGenerator(asset: asset)
      generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
      generator.generateCGImageAsynchronously(for: time) { [weak self] image, _, _ in
        guard let image else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated {
          guard let self, self.player == nil, self.loadedClip == index else { return }
          CATransaction.begin(); CATransaction.setDisableActions(true); self.poster.contents = image; CATransaction.commit()
        } }
      }
    }
  }

  /// The playlist ended: blur and dim the last frame, offer Replay All.
  func setEnd(_ end: Bool, animated: Bool) {
    guard end != showsEnd else { return }
    showsEnd = end
    if end, let index = loadedClip { stop(release: true); endCover.contents = blurredImage(index) }
    CATransaction.begin()
    if animated {
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = endCover.presentation()?.opacity ?? endCover.opacity; fade.toValue = end ? 1 : 0
      fade.duration = 0.28; fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      endCover.add(fade, forKey: "end")
    }
    CATransaction.setDisableActions(true); endCover.opacity = end ? 1 : 0
    CATransaction.commit()
    if end {
      replayAll.isHidden = false
      if animated {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.28; context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
          replayAll.animator().alphaValue = 1
        }
      } else { replayAll.alphaValue = 1 }
    } else {
      replayAll.alphaValue = 0; replayAll.isHidden = true
    }
  }

  @objc private func replayPressed() { replay?() }

  /// Automation: the number of CA animations this panel holds.
  var animationCount: Int {
    [clip, poster, endCover, playerLayer].reduce(0) { $0 + ($1.animationKeys()?.count ?? 0) }
      + (replayAll.layer?.animationKeys()?.count ?? 0)
  }
}

/// "Replay All": a filled accent button with our own symbol and label.
@MainActor
final class WelcomeReplayAllButton: NSButton {
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true; isBordered = false; title = "Replay All"
    setAccessibilityLabel("Replay All")
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  private let labelFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
  override var intrinsicContentSize: NSSize {
    let width = (title as NSString).size(withAttributes: [.font: labelFont]).width
    return NSSize(width: ceil(width) + 16 + 18 + 6 + 18, height: 39)
  }
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
    (isHighlighted ? WelcomeStyle.accent.blended(withFraction: 0.15, of: .black) ?? WelcomeStyle.accent : WelcomeStyle.accent).setFill()
    path.fill()
    let symbol = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))?
      .withSymbolConfiguration(.init(paletteColors: [.white]))
    symbol?.draw(in: CGRect(x: 16, y: (bounds.height - 17) / 2, width: 17, height: 17), from: .zero, operation: .sourceOver,
      fraction: 1, respectFlipped: true, hints: nil)
    let size = (title as NSString).size(withAttributes: [.font: labelFont])
    (title as NSString).draw(at: CGPoint(x: 16 + 18 + 6, y: (bounds.height - size.height) / 2),
      withAttributes: [.font: labelFont, .foregroundColor: NSColor.white])
    if window?.firstResponder === self {
      NSColor.keyboardFocusIndicatorColor.setStroke(); path.lineWidth = 2; path.stroke()
    }
  }
}
