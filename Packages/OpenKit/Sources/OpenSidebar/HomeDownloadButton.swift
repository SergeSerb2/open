import AppKit
import QuartzCore
import OpenDesign

/// App supplies session state only; the sidebar owns the badge's drawing and
/// finite animations. Completion previews follow the approved Library design.
public struct DownloadBadgeFile: Equatable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let completedAt: Date
    public init(id:String,name:String,path:String,completedAt:Date) { self.id=id;self.name=name;self.path=path;self.completedAt=completedAt }
}

public struct DownloadBadgeState: Equatable, Sendable {
    public var running: Int
    public var progress: Double
    public var indeterminate: Bool
    public var completedAt: Date?
    public var files: [DownloadBadgeFile]
    public init(running: Int, progress: Double, indeterminate: Bool, completedAt: Date?, files: [DownloadBadgeFile] = []) {
        self.running = running; self.progress = progress; self.indeterminate = indeterminate; self.completedAt = completedAt; self.files = Array(files.prefix(3))
    }
}

@MainActor
final class HomeDownloadButton: PlateButton, CAAnimationDelegate, NSDraggingSource {
    private var badgeLayers: [CALayer] = []
    private var dragStarted = false
    private var mouseStart: CGPoint?
    var latestName: String? { previous?.files.first?.name }
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let check = NSImageView()
    private let arrow = NSImageView()
    private var previous: DownloadBadgeState?
    private(set) var completionCount = 0
    private(set) var completing = false

    init() {
        super.init(glyph: .library)
        clipsToBounds = false; layer?.masksToBounds = false
        for shape in [track, ring] {
            shape.fillColor = nil; shape.lineWidth = 2; shape.opacity = 0
            layer?.addSublayer(shape)
        }
        check.wantsLayer = true; check.layer?.opacity = 0
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        addSubview(check)
        arrow.wantsLayer = true; arrow.layer?.opacity = 0
        arrow.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        addSubview(arrow)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // C12-PB1-4: 20 pt ring centred at window x=34, bottom=37.
        // The Library glyph keeps its own frame underneath and to the left.
        let frame = CGRect(x: 16, y: -6, width: 20, height: 20)
        for shape in [track, ring] {
            shape.frame = frame
            shape.path = CGPath(ellipseIn: CGRect(x: 1, y: 1, width: 18, height: 18), transform: nil)
            shape.transform = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
        }
        arrow.frame = CGRect(x: 20, y: -2, width: 12, height: 12)
        check.frame = CGRect(x: bounds.midX - 4.5, y: bounds.midY - 4.5, width: 9, height: 9)
        for badge in badgeLayers {
            badge.frame = CGRect(x:10,y:-12,width:32,height:32)
            badge.sublayers?.first?.frame = badge.bounds
            badge.shadowPath = CGPath(roundedRect:badge.bounds,cornerWidth:7,cornerHeight:7,transform:nil)
        }
        CATransaction.commit()
    }
    override func updateLayer() {
        super.updateLayer()
        let state = tracked({ context?.downloadBadge }) { [weak self] in self?.needsDisplay = true }
        // Use the Favorites-empty disc's bright Space accent in both appearances.
        // The mark keeps that accent even when the card itself uses its dark neutral disc.
        let titleInk = tracked({
            let style = context?.focusedSpace.map { context!.style(for: $0) } ?? .defaultTheme(system: context?.systemAppearance ?? .light)
            return style.roles(.light).title.nsColor
        }) { [weak self] in self?.needsDisplay = true }
        let tint = FavoritesEmptyStateView.accentColor(titleInk: titleInk)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.strokeColor = tint.withAlphaComponent(0.22).cgColor
        track.fillColor = FavoritesEmptyStateView.cardFillColor(.light).cgColor
        ring.strokeColor = tint.cgColor; check.contentTintColor = tint; arrow.contentTintColor = tint
        CATransaction.commit()
        guard state != previous else { return }
        let old = previous; previous = state
        updateFiles((state?.running ?? 0) > 0 ? [] : state?.files ?? [], animated:old?.files.first?.id != state?.files.first?.id)
        if let state, state.running > 0 {
            if completing { interruptCompletion() }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            arrow.layer?.opacity = 1; track.opacity = 1; ring.opacity = 1; ring.strokeEnd = state.indeterminate ? 0.25 : state.progress
            CATransaction.commit()
            if state.indeterminate && ring.animation(forKey: "download-spin") == nil && !Motion.reducesMotion {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = -Double.pi / 2; spin.toValue = 3 * Double.pi / 2
                spin.duration = 1; spin.repeatCount = .infinity
                ring.add(spin, forKey: "download-spin")
            } else if !state.indeterminate || Motion.reducesMotion { ring.removeAnimation(forKey: "download-spin") }
        } else if let date = state?.completedAt, date != old?.completedAt, Date().timeIntervalSince(date) < 2 {
            complete()
        } else if !completing { clearAnimations() }
    }
    private func updateFiles(_ files:[DownloadBadgeFile],animated:Bool) {
        badgeLayers.forEach { $0.removeFromSuperlayer() }; badgeLayers = []
        for file in files.prefix(1) {
            let badge = CALayer(), image = CALayer()
            badge.shadowColor = NSColor.black.cgColor; badge.shadowOpacity = 0.22; badge.shadowRadius = 4; badge.shadowOffset = CGSize(width:0,height:-2)
            image.cornerRadius = 7; image.cornerCurve = .continuous; image.masksToBounds = true; image.contentsGravity = .resizeAspectFill
            let preview = FilePreviewCache.shared.image(for:URL(fileURLWithPath:file.path)) { [weak self] in
                guard let self else { return }; self.updateFiles((self.previous?.running ?? 0) > 0 ? [] : self.previous?.files ?? [],animated:false)
            }
            image.contents = preview.cgImage(forProposedRect:nil,context:nil,hints:nil); badge.addSublayer(image)
            layer?.insertSublayer(badge,at:UInt32(max(0,layer?.sublayers?.count ?? 0)-badgeLayers.count)); badgeLayers.append(badge)
        }
        needsLayout = true; superview?.needsLayout = true
        if animated, !files.isEmpty, !Motion.reducesMotion {
            let drop = CABasicAnimation(keyPath:"transform.translation.y"); drop.fromValue = -20; drop.toValue = 0; drop.duration = 0.20
            drop.timingFunction = CAMediaTimingFunction(name:.easeOut); badgeLayers.first?.add(drop,forKey:"library-download-drop")
        }
        setAccessibilityLabel(files.first.map { "Download — " + $0.name } ?? ((previous?.running ?? 0) > 0 ? "Downloads" : "Library"))
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !isHidden, ((previous?.running ?? 0) > 0 || !badgeLayers.isEmpty),
           CGRect(x:10,y:-12,width:32,height:32).contains(local) { return self }
        return super.hitTest(point)
    }
    override func mouseDown(with event:NSEvent) { mouseStart = convert(event.locationInWindow,from:nil); dragStarted = false; super.mouseDown(with:event) }
    override func mouseDragged(with event:NSEvent) {
        guard !dragStarted, let start=mouseStart, let file=previous?.files.first, previous?.running == 0 else { return }
        let point=convert(event.locationInWindow,from:nil)
        guard hypot(point.x-start.x,point.y-start.y)>=4 else { return }
        dragStarted = true
        let url=URL(fileURLWithPath:file.path), item=NSDraggingItem(pasteboardWriter:URL(fileURLWithPath:file.path) as NSURL)
        item.setDraggingFrame(CGRect(x:10,y:-12,width:32,height:32),contents:NSWorkspace.shared.icon(forFile:url.path))
        beginDraggingSession(with:[item],event:event,source:self)
    }
    override func mouseUp(with event:NSEvent) {
        defer { mouseStart = nil; dragStarted = false }
        guard !dragStarted else { return }
        let local = convert(event.locationInWindow,from:nil)
        let pressedMark = isPressed && !bounds.contains(local) && CGRect(x:10,y:-12,width:32,height:32).contains(local)
        super.mouseUp(with:event)
        if pressedMark { action?() }
    }
    func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext)->NSDragOperation { .copy }
    var fileDragEvidence:[String:Any] {
        guard let file=previous?.files.first, previous?.running == 0 else { return [:] }
        let board=NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }; board.writeObjects([URL(fileURLWithPath:file.path) as NSURL])
        return ["types":board.types?.map(\.rawValue) ?? [],"url":board.string(forType:.fileURL) ?? ""]
    }
    private func clearAnimations() {
        completing = false
        arrow.layer?.opacity = 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for shape in [track, ring] { shape.removeAllAnimations(); shape.opacity = 0 }
        check.layer?.removeAllAnimations(); check.layer?.opacity = 0
        glyphView.layer?.removeAllAnimations(); glyphView.layer?.opacity = 1
        CATransaction.commit()
    }
    private func interruptCompletion() {
        let targets: [(CALayer?, Float)] = [(glyphView.layer, 1), (check.layer, 0), (track, 1), (ring, 1)]
        let opacities = targets.map { $0.0?.presentation()?.opacity ?? $0.1 }
        clearAnimations()
        for (index, target) in targets.enumerated() {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = opacities[index]; fade.toValue = target.1; fade.duration = 0.15
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            target.0?.add(fade, forKey: "download-interrupted-completion")
        }
    }
    private func complete() {
        arrow.layer?.opacity = 0
        completing = true; completionCount += 1
        let now = CACurrentMediaTime()
        ring.removeAnimation(forKey: "download-spin")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.strokeEnd = 1
        for shape in [track, ring] {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = shape.presentation()?.opacity ?? 1; fade.toValue = 0
            fade.beginTime = now + 0.15; fade.duration = 0.8; fade.fillMode = .backwards
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shape.opacity = 0; shape.add(fade, forKey: "download-complete-ring")
        }
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 0, 1, 1, 0, 0]; opacity.keyTimes = [0.0, 0.15/1.45, 0.3/1.45, 1.15/1.45, 1.3/1.45, 1.0].map { NSNumber(value: $0) }
        opacity.timingFunctions = [CAMediaTimingFunctionName.linear, .easeOut, .linear, .easeOut, .linear].map { CAMediaTimingFunction(name: $0) }
        opacity.duration = 1.45
        check.layer?.add(opacity, forKey: "download-complete-check")
        if !Motion.reducesMotion {
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = check.layer?.presentation()?.value(forKeyPath: "transform.scale") ?? 0.6
            spring.toValue = 1; spring.mass = 1; spring.stiffness = pow(2 * .pi / 0.5, 2); spring.damping = 2 * sqrt(spring.stiffness)
            spring.beginTime = now + 0.15; spring.duration = 0.5; spring.fillMode = .backwards
            check.layer?.add(spring, forKey: "download-complete-spring")
        }
        glyphView.wantsLayer = true
        let home = CAKeyframeAnimation(keyPath: "opacity")
        home.values = [1, 0, 0, 1]; home.keyTimes = [0.0, 0.15/1.45, 1.3/1.45, 1.0].map { NSNumber(value: $0) }; home.duration = 1.45
        home.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeIn)]
        home.delegate = self
        glyphView.layer?.add(home, forKey: "download-complete-home")
        CATransaction.commit()
    }
    nonisolated func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard flag else { return }
        MainActor.assumeIsolated { clearAnimations() }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { clearAnimations() }
        super.viewWillMove(toWindow: newWindow)
    }
    var evidence: [String: Any] {
        let box=window?.contentView?.convert(bounds,from:self) ?? .zero
        let rootFrame:[CGFloat]=[box.minX,box.minY,box.width,box.height]
        let mark = window?.contentView?.convert(CGRect(x:10,y:-12,width:32,height:32),from:self) ?? .zero
        let spring = check.layer?.animation(forKey: "download-complete-spring") as? CASpringAnimation
        let fade = ring.animation(forKey: "download-complete-ring")
        let home = glyphView.layer?.animation(forKey: "download-complete-home")
        return ["files":previous?.files.map { ["id":$0.id,"name":$0.name,"path":$0.path] } ?? [],"thumbnailSize":32,"markFrame":[mark.minX,mark.minY,mark.width,mark.height],"frame":rootFrame,"tooltipTitle":latestName ?? "Library","stackCount":badgeLayers.count,"drag":fileDragEvidence,"reduceMotion": Motion.reducesMotion, "spring": spring.map { ["duration": $0.duration, "mass": $0.mass, "stiffness": $0.stiffness, "damping": $0.damping] } ?? [:],
         "ringFadeDuration": fade?.duration ?? 0, "homeDuration": home?.duration ?? 0,
         "ringBounds": [ring.path?.boundingBox.minX ?? 0, ring.path?.boundingBox.minY ?? 0, ring.path?.boundingBox.width ?? 0, ring.path?.boundingBox.height ?? 0], "lineWidth": ring.lineWidth,
"running": previous?.running ?? 0, "progress": previous?.progress ?? 0,
         "indeterminate": previous?.indeterminate ?? false, "completing": completing,
         "completions": completionCount, "animations": [track, ring, check.layer, glyphView.layer].compactMap { $0 }.reduce(0) { $0 + ($1.animationKeys()?.count ?? 0) },
         "trackOpacity": track.opacity, "ringOpacity": ring.opacity, "checkOpacity": check.layer?.opacity ?? 0, "homeOpacity": glyphView.layer?.opacity ?? 1]
    }
}
