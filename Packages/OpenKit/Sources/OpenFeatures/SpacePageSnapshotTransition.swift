import AppKit
import OpenDesign
import OpenModel

/// The retained pixels for a Space change. The caller supplies an outgoing
/// viewport capture, or keeps the unchanged live source beneath the plate.
/// Native selection changes
/// once, after the incoming plate covers that viewport. Only a matching engine
/// presentation receipt may retire the plate. Animation completion is not that
/// receipt.
///
/// WebContentContainer owns selection and the per-view presentation requests.
@MainActor
final class SpacePageSnapshotTransition: NSView {
    struct SnapshotKey: Hashable {
        let space: SpaceID
        let profile: ProfileID
        let tabs: [ItemID]
        /// Host/document generations, not URLs or titles. Navigation, host
        /// replacement and selection changes must invalidate the old key.
        let revisions: [UInt64]
        let layout: [Double]
        let width: Int
        let height: Int
        let scale: Double
    }

    struct Receipt: Equatable {
        fileprivate let generation: UInt64
    }

    enum Phase: String { case idle, moving, awaitingPresentation, presentationFailed }
    private(set) var phase: Phase = .idle
    private(set) var destinationUsesSnapshot = false
    private(set) var lastAnimation: CAAnimation?
    private(set) var cachedBytes = 0
    private var generation: UInt64 = 0
    private var outgoing: CALayer?
    private var incoming: CALayer?
    private var cache: [SnapshotKey: CGImage] = [:]
    private var lru: [SnapshotKey] = []
    private var covered: ((Receipt) -> Void)?
    private static let byteLimit = 64 * 1024 * 1024

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = true
        layer?.cornerRadius = PanelMetrics.cornerRadius
        layer?.cornerCurve = .continuous
        // The caller inserts this above the page and below other UI. Block
        // clicks through a still-retained image into a different live document.
        setAccessibilityHidden(true)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        phase == .idle ? nil : super.hitTest(point)
    }

    /// Memory only, including private windows. At most 64 MiB of cached RGBA
    /// images; active outgoing/incoming plates retain at most two more images.
    /// A refused or failed capture keeps the caller's outgoing view untouched.
    @discardableResult
    func remember(_ image: CGImage, for key: SnapshotKey) -> Bool {
        guard let bytes = Self.cost(image), key.tabs.count <= 4, key.tabs.count == key.revisions.count,
              image.width == key.width, image.height == key.height,
              key.scale.isFinite, (1...4).contains(key.scale) else { return false }
        removeCached(key)
        while cachedBytes > Self.byteLimit - bytes || lru.count >= 8 {
            guard let oldest = lru.first else { break }; removeCached(oldest)
        }
        cache[key] = image; lru.append(key); cachedBytes += bytes
        return true
    }

    func invalidate(tab: ItemID) {
        for key in Array(cache.keys) where key.tabs.contains(tab) { removeCached(key) }
    }

    func invalidateAll() {
        cache.removeAll(); lru.removeAll(); cachedBytes = 0
    }

    private func removeCached(_ key: SnapshotKey) {
        if let image = cache.removeValue(forKey: key) { cachedBytes -= Self.cost(image) ?? 0 }
        lru.removeAll { $0 == key }
    }

    static func cost(_ image: CGImage) -> Int? {
        guard image.width > 0, image.height > 0, image.width <= 8192, image.height <= 8192,
              image.width <= 16 * 1024 * 1024 / image.height,
              image.bytesPerRow > 0, image.bytesPerRow <= byteLimit / image.height else { return nil }
        return image.bytesPerRow * image.height
    }

    /// Capture only the retained plates at an input/resize boundary. Transparent
    /// regions keep showing the unchanged native source below. This also folds
    /// an interrupted slide into one bounded image, without growing layer trees.
    func capturePresentation(size: CGSize, scale: CGFloat) -> CGImage? {
        guard phase != .idle, let layer, !bounds.isEmpty,
              let context = Self.context(size: size, scale: scale) else { return nil }
        context.scaleBy(x: size.width / bounds.width, y: size.height / bounds.height)
        (layer.presentation() ?? layer).render(in: context)
        return context.makeImage()
    }

    static func context(size: CGSize, scale: CGFloat) -> CGContext? {
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width > 0, size.height > 0, (1...4).contains(scale),
              size.width * scale <= 8192, size.height * scale <= 8192 else { return nil }
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard width <= 16 * 1024 * 1024 / height,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        return context
    }

    /// A plain cached source is not sufficient on reversal. The owner passes
    /// capturePresentation() then, and leaves the native source unchanged until
    /// onCovered. Nil is valid for the first slide over that unchanged source.
    @discardableResult
    func begin(outgoing image: CGImage?, destination key: SnapshotKey,
               theme: SpaceThemeStyle, themeFrame: CGRect, direction: CGFloat,
               animated: Bool, token: SpringToken = Motion.spaceSwitch,
               onCovered: @escaping (Receipt) -> Void) -> Bool {
        guard !bounds.isEmpty, image == nil || Self.cost(image!) != nil, direction.isFinite,
              key.scale.isFinite, (1...4).contains(key.scale),
              image == nil || (image!.width == key.width && image!.height == key.height),
              key.width == Int(ceil(bounds.width * key.scale)),
              key.height == Int(ceil(bounds.height * key.scale)),
              themeFrame.width.isFinite, themeFrame.height.isFinite,
              themeFrame.width > 0, themeFrame.height > 0 else { return false }
        generation &+= 1
        let receipt = Receipt(generation: generation)
        covered = onCovered
        // Replacement of an interrupted composition is atomic. The owner must
        // capture its presentation first; no native page is exposed here.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        outgoing?.removeFromSuperlayer(); incoming?.removeFromSuperlayer()
        let source = CALayer(); source.frame = bounds; source.contents = image
        source.contentsGravity = .resize; source.contentsScale = key.scale
        let target = CALayer(); target.frame = bounds; target.masksToBounds = true
        target.contentsScale = source.contentsScale
        if let cached = cache[key] {
            destinationUsesSnapshot = true; target.contents = cached; target.contentsGravity = .resize
            lru.removeAll { $0 == key }; lru.append(key)
        } else {
            destinationUsesSnapshot = false
            // An opaque, canonical Space field. The field stays in window
            // coordinates while this clipped plate slides over the old pixels.
            let field = CALayer(); field.frame = themeFrame
            field.contents = ThemeField.makeImage(style: theme, windowSize: themeFrame.size,
                                                 isActive: window?.isKeyWindow == true)
            field.contentsGravity = .resize
            let evaluator = ThemeField.Evaluator(style: theme, windowSize: themeFrame.size,
                                                 isActive: window?.isKeyWindow == true)
            let color = evaluator.color(u: 0.5, v: 0.5)
            target.backgroundColor = NSColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1).cgColor
            target.addSublayer(field)
        }
        layer?.addSublayer(source); layer?.addSublayer(target)
        outgoing = source; incoming = target
        // The outgoing plate stays stationary. Every point remains covered
        // until the incoming plate covers it; sliding both would reveal a gap.
        target.setValue(CGFloat.zero, forKeyPath: "transform.translation.x")
        let animate = animated && !Motion.reducesMotion && direction != 0
        phase = animate ? .moving : .awaitingPresentation
        lastAnimation = nil
        if animate {
            let spring = token.animation(keyPath: "transform.translation.x")
            let from = direction.sign == .minus ? -bounds.width : bounds.width
            let progress = Motion.springProgress(token, at: spring.duration)
            spring.fromValue = from
            spring.toValue = progress.isFinite && abs(progress) > 0.001 ? from - from / CGFloat(progress) : 0
            let hz = Float(window?.screen?.maximumFramesPerSecond ?? 60)
            spring.preferredFrameRateRange = CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz)
            CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated {
                self?.destinationCovered(receipt)
            } }
            target.add(spring, forKey: "spacePageSlide")
            lastAnimation = target.animation(forKey: "spacePageSlide")
        }
        CATransaction.commit()
        if !animate { destinationCovered(receipt) }
        return true
    }

    private func destinationCovered(_ receipt: Receipt) {
        guard receipt.generation == generation, incoming != nil,
              phase == .moving || phase == .awaitingPresentation else { return }
        phase = .awaitingPresentation
        // This is the one native-layout/attachment boundary. The owner then
        // asks the engine for a frame on that attached view, at this viewport.
        let callback = covered; covered = nil; callback?(receipt)
    }

    /// Call only from the engine's successful presentation callback, after
    /// validating its request, document, view-attachment and viewport token.
    /// A stale completion, load event, rAF or timer cannot remove these pixels.
    func presented(_ receipt: Receipt) {
        guard receipt.generation == generation, phase == .awaitingPresentation else { return }
        retire()
    }

    /// A closed/crashed renderer is not a presentation receipt. Keep its plate
    /// until the owner presents an explicit error surface or cancels the window.
    func presentationFailed(_ receipt: Receipt) {
        guard receipt.generation == generation, phase == .awaitingPresentation else { return }
        phase = .presentationFailed
    }

    /// Window close/profile teardown, or after an explicit replacement surface
    /// is ready. Never use this as the normal live-page handoff.
    func cancel() { generation &+= 1; retire() }

    private func retire() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        outgoing?.removeFromSuperlayer(); incoming?.removeFromSuperlayer()
        outgoing = nil; incoming = nil; covered = nil; lastAnimation = nil
        phase = .idle
        CATransaction.commit()
        removeFromSuperview()
    }
}
