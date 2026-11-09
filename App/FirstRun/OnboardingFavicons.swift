import AppKit
import QuartzCore
import OpenAdBlock
@_spi(FaviconDiagnostics) import OpenStore

private struct OnboardingFaviconSiteResolver: FaviconSiteResolver {
  func siteKey(for host: String) -> String? { try? AdBlockSites.shared.registrableDomain(host) }
}

/// One bounded prefetch belongs to the onboarding window. Network, DNS, image
/// decoding and SQLite run on the shared OpenStore actors, never in a draw.
@MainActor final class OnboardingFavicons {
  struct Tile {
    var state = "monogram"
    var image: NSImage?
    var info: FaviconImageInfo?
    var storeHit = false
    var durationMS = 0.0
    var elapsedMS = 0.0
  }
  unowned let app: AppDelegate
  private(set) var tiles = Array(repeating: Tile(), count: OnboardingStepsController.sites.count)
  private(set) var started = false
  private(set) var finished = false
  private(set) var durationMS = 0.0
  private(set) var requests = 0
  private(set) var introElapsedWhenStarted = 0.0
  var onChange: (@MainActor (Int) -> Void)?
  private var worker: Task<Void, Never>?
  init(app: AppDelegate) { self.app = app }
  isolated deinit { worker?.cancel() }
  func start(introElapsed: Double) {
    guard !started else { return }; started = true; introElapsedWhenStarted = introElapsed
    let blocked = app.options.faviconNetworkBlocked
    guard !blocked, let store = app.stores.favicons else {
      for index in tiles.indices { tiles[index].state = "failed" }
      finished = true; return
    }
    for index in tiles.indices { tiles[index].state = "loading" }
    let urls = OnboardingStepsController.sites.map(\.url)
    let cache = app.stores.sidebarFavicons
    worker = Task.detached(priority: .utility) { [weak self] in
      let fetcher = FaviconFetcher(store: store, maxConcurrent: 6, timeout: 6, originTimeout: 6, minimumDimension: 64, fallbackMinimumDimension: 32,
        siteResolver: OnboardingFaviconSiteResolver())
      #if OPEN_AUTOMATION
      if ProcessInfo.processInfo.environment["OPEN_FAVICON_DIAGNOSTICS"] == "1" {
        let file = await self?.app.directories.root.appendingPathComponent("favicon-trace.jsonl")
        if let file, let trace = OnboardingFaviconTrace(file) {
          await fetcher.setDiagnosticHandler { origin, url, event in trace.record(origin: origin, url: url, event: event) }
        }
      }
      #endif
      let report = await fetcher.prefetch(urls, overallTimeout: 12) { [weak self] result in
        let index = result.index-1
        // Prefetch writes an origin fallback. A later engine favicon event goes
        // through StoredFaviconCache.report and its exact-page record wins.
        let bitmap = result.status == .ok ? await store.decodedIcon(for: urls[index]) : nil
        if bitmap != nil { await cache?.refreshFromStore(for: urls[index]) }
        await self?.received(result, bitmap: bitmap)
      }
      guard !Task.isCancelled else { return }
      await self?.complete(report)
    }
  }
  private func complete(_ report: FetchReport) {
    worker = nil
    durationMS = report.durationMs; requests = report.origins.filter { !$0.alreadyCached }.count; finished = true
  }
  private func received(_ result: FaviconFetchResult, bitmap: CGImage?) {
    guard !Task.isCancelled, tiles.indices.contains(result.index-1) else { return }
    let index = result.index-1
    tiles[index].durationMS = result.durationMs; tiles[index].elapsedMS = result.elapsedMs
    tiles[index].info = result.imageInfo; tiles[index].storeHit = result.alreadyCached
    tiles[index].image = bitmap.map { NSImage(cgImage: $0, size: NSSize(width: 32, height: 32)) }
    tiles[index].state = bitmap == nil ? "failed" : "icon"
    onChange?(index)
  }
  var state: [String: Any] {
    ["started": started, "introElapsedWhenStarted": introElapsedWhenStarted, "finished": finished, "durationMS": durationMS, "requests": requests,
     "siteTimeoutSeconds": 6, "overallTimeoutSeconds": 12, "concurrency": 6]
  }
}

/// Shared by each choice and the miniature sidebar. Its frame is always 32 pt.
@MainActor final class OnboardingSiteIconView: NSView {
  private let monogram = OnboardingSiteIconDrawing()
  private let artwork = OnboardingSiteIconDrawing()
  private var image: NSImage?
  private(set) var fadeDuration = 0.0
  var arrivalDelay = 0.0
  var monogramColor: UInt32 { OnboardingSiteIconDrawing.color(for: monogram.name) }
  var monogramContrast: Double {
    let hex = monogramColor
    let channels = [Double((hex >> 16) & 255), Double((hex >> 8) & 255), Double(hex & 255)].map { value in
      let s = value/255; return s <= 0.04045 ? s/12.92 : pow((s+0.055)/1.055, 2.4)
    }
    return 1.05/(0.2126*channels[0]+0.7152*channels[1]+0.0722*channels[2]+0.05)
  }
  override init(frame: NSRect) {
    super.init(frame: frame); wantsLayer = true
    for child in [monogram, artwork] {
      child.frame = bounds; child.autoresizingMask = [.width, .height]; child.wantsLayer = true; addSubview(child)
    }
    artwork.layer?.opacity = 0
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { nil }
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func layout() { super.layout(); monogram.frame = bounds; artwork.frame = bounds }
  func apply(name: String, tile: OnboardingFavicons.Tile, animated: Bool, reduceMotion: Bool) {
    monogram.name = name; artwork.name = name
    artwork.image = tile.image
    artwork.iconIsOpaque = tile.info.map { $0.opaque && min($0.width, $0.height) >= 64 } == true
    artwork.sourceDimension = tile.info.map { min($0.width, $0.height) } ?? 64
    artwork.updateStyle(); monogram.updateStyle()
    monogram.needsDisplay = true; artwork.needsDisplay = true
    guard image !== tile.image else { return }
    let wasImage = image != nil; image = tile.image
    let show = image != nil
    fadeDuration = show && !wasImage && animated && !reduceMotion ? 0.2 : 0
    let oldMono = monogram.layer?.presentation()?.opacity ?? (wasImage ? 0 : 1)
    let oldArt = artwork.layer?.presentation()?.opacity ?? (wasImage ? 1 : 0)
    CATransaction.begin(); CATransaction.setDisableActions(true)
    monogram.layer?.opacity = show ? 0 : 1; artwork.layer?.opacity = show ? 1 : 0
    CATransaction.commit()
    if fadeDuration > 0 {
      let start = CACurrentMediaTime()+arrivalDelay
      for (child, from, to) in [(monogram, oldMono, Float(0)), (artwork, oldArt, Float(1))] {
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = from; fade.toValue = to
        fade.duration = fadeDuration; fade.beginTime = start; fade.fillMode = .backwards
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        child.layer?.add(fade, forKey: "site-icon")
      }
      let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 0.96; scale.toValue = 1
      scale.duration = fadeDuration; scale.beginTime = start; scale.fillMode = .backwards
      scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
      artwork.layer?.add(scale, forKey: "site-icon-scale")
    }
  }
}

@MainActor private final class OnboardingSiteIconDrawing: NSView {
  var name = ""
  var image: NSImage?
  var iconIsOpaque = false
  var sourceDimension = 64
  override var isFlipped: Bool { true }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateStyle(); needsDisplay = true }
  func updateStyle() {
    guard let layer else { return }
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    CATransaction.begin(); CATransaction.setDisableActions(true)
    layer.cornerRadius = image == nil ? 8:7; layer.cornerCurve = .continuous
    layer.masksToBounds = image == nil || iconIsOpaque
    layer.backgroundColor = image != nil && !iconIsOpaque ? (dark ? NSColor(srgbRed: 61/255, green: 61/255, blue: 66/255, alpha: 1):.white).cgColor : NSColor.clear.cgColor
    layer.borderWidth = image == nil ? 0:iconIsOpaque ? 0.5:1
    layer.borderColor = (dark ? NSColor.white.withAlphaComponent(0.10):NSColor.black.withAlphaComponent(iconIsOpaque ? 0.08:0.06)).cgColor
    layer.shadowColor = NSColor.black.cgColor; layer.shadowOpacity = image != nil && !iconIsOpaque && !dark ? 0.06:0
    layer.shadowRadius = 4; layer.shadowOffset = CGSize(width: 0, height: 1)
    layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 7, cornerHeight: 7, transform: nil)
    CATransaction.commit()
  }
  // OKLCH L .545 / C .11, hues 20/60/110/160/200/240/280/330,
  // clipped to sRGB. White contrast is at least 4.5:1 for all eight.
  // FNV-1a is stable across launches and Swift versions.
  private static let palette: [UInt32] = [0xA75355, 0x9E5F23, 0x747518, 0x238359, 0x008289, 0x2377A9, 0x6468AF, 0x93578E]
  static func color(for name: String) -> UInt32 {
    if name == "GitHub" { return 0x3A3A3E }
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
    return palette[Int(hash % UInt64(palette.count))]
  }
  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds
    NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
    if let image {
      NSGraphicsContext.current?.imageInterpolation = .high
      let side = min(CGFloat(26), CGFloat(sourceDimension*2)/max(1, window?.backingScaleFactor ?? 2))
      let imageRect = NSRect(x: rect.midX-side/2, y: rect.midY-side/2, width: side, height: side)
      image.draw(in: iconIsOpaque ? rect : imageRect, from: .zero, operation: .sourceOver,
        fraction: 1, respectFlipped: true, hints: nil)
    } else {
      let hex = Self.color(for: name)
      NSColor(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255,
        blue: CGFloat(hex & 255)/255, alpha: 1).setFill(); rect.fill()
      let pair = ["Gmail":"Gm", "Google Maps":"Go", "GitHub":"Gh", "Slack":"Sl", "Spotify":"Sp", "WhatsApp":"Wa", "Wikipedia":"Wi"][name]
      let letter = (pair ?? String(name.prefix(1)).uppercased()) as NSString
      let pointSize: CGFloat = pair == nil ? 15:11
      let base = NSFont.systemFont(ofSize: pointSize, weight: .semibold)
      let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: pointSize) } ?? base
      let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
      let size = letter.size(withAttributes: attributes)
      letter.draw(at: NSPoint(x: rect.midX-size.width/2, y: rect.midY-size.height/2-0.5), withAttributes: attributes)
    }
  }
}

#if OPEN_AUTOMATION
/// Opt-in trace for the twelve public suggestions, in an automation data root.
/// It is never enabled for normal launches or user browsing.
private final class OnboardingFaviconTrace: @unchecked Sendable {
  private let file: FileHandle
  private let lock = NSLock()
  init?(_ url: URL) {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    guard let file = try? FileHandle(forWritingTo: url) else { return nil }; self.file = file
  }
  deinit { try? file.close() }
  func record(origin: String, url: String, event: String) {
    guard var data = try? JSONSerialization.data(withJSONObject: ["origin": origin, "url": url, "event": event], options: [.sortedKeys]) else { return }
    data.append(10); lock.withLock { try? file.write(contentsOf: data) }
  }
}
#endif
