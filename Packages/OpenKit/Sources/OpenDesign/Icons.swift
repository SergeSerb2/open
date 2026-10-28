import AppKit

/// Every glyph the sidebar draws. Each maps to an SF Symbol with a point size and
/// weight tuned so the 1x ink box matches Arc's measured ink box, or to a vector
/// drawn in code (`CustomIcon`). We never ship Arc's images.
public enum Glyph: String, CaseIterable, Sendable {
    case sidebarToggle, back, forward, reload, stopLoading, compactBack, compactForward
    case magnifier, copyLink, siteControls
    case newTabPlus, rowClose, rowUnload
    case disclosureDown, disclosureRight, clearArrow
    case spaceMore, audioPlaying, audioMuted
    case library, bottomPlus
    case globe
    case mediaPlay, mediaPause, mediaPrevious, mediaNext, mediaPiP, mediaClose, mediaVolume, mediaVolumeMuted
    case mediaMicrophone, mediaMicrophoneMuted, mediaCamera, mediaCameraOff, mediaVolumeLow, mediaVolumeHigh
    case pipClose, pipMinimize, pipSettings, pipPlay, pipPause, pipPrevious, pipNext, pipMute, pipUnmute, pipHangUp
    case pipSkipBack, pipSkipForward

    public struct Spec: Sendable {
        public var symbol: String
        public var pointSize: CGFloat
        public var weight: NSFont.Weight
        /// Measured Arc ink box at 1x (width × height), when one was measured.
        public var arcInk: CGSize?
        public var note: String
        /// Nudge from the centered position, fitted on ink boxes (points, y down).
        public var offset: CGSize = .zero
    }

    public var spec: Spec {
        switch self {
        case .sidebarToggle: Spec(symbol: "sidebar.left", pointSize: 16, weight: .regular, arcInk: CGSize(width: 19, height: 15), note: "toolbar; rounded rect with a lined left pane")
        case .back: Spec(symbol: "arrow.left", pointSize: 16, weight: .regular, arcInk: CGSize(width: 15, height: 12), note: "toolbar", offset: CGSize(width: 0, height: 1))
        case .forward: Spec(symbol: "arrow.right", pointSize: 16, weight: .regular, arcInk: CGSize(width: 15, height: 12), note: "toolbar", offset: CGSize(width: 0, height: 1))
        case .compactBack: Spec(symbol: "arrow.left", pointSize: 14, weight: .regular, arcInk: CGSize(width: 13, height: 10), note: "compact toolbar (S2 06/0029 ink [82, 19, 95, 29])", offset: CGSize(width: 0, height: 1))
        case .compactForward: Spec(symbol: "arrow.right", pointSize: 14, weight: .regular, arcInk: CGSize(width: 13, height: 10), note: "compact toolbar (S2 06/0029 ink [110, 19, 123, 29])", offset: CGSize(width: 0, height: 1))
        case .reload: Spec(symbol: "arrow.clockwise", pointSize: 16, weight: .regular, arcInk: CGSize(width: 14, height: 17), note: "toolbar", offset: CGSize(width: 0, height: 1))
        case .stopLoading: Spec(symbol: "xmark", pointSize: 13, weight: .regular, arcInk: nil, note: "toolbar, while loading")
        case .magnifier: Spec(symbol: "magnifyingglass", pointSize: 12.5, weight: .regular, arcInk: CGSize(width: 12, height: 12), note: "URL field, no page")
        case .copyLink: Spec(symbol: "link", pointSize: 14, weight: .medium, arcInk: CGSize(width: 15, height: 14), note: "URL field accessory")
        case .siteControls: Spec(symbol: "slider.horizontal.2.square", pointSize: 18, weight: .regular, arcInk: CGSize(width: 16, height: 16), note: "URL field accessory (Site Control Center)")
        case .newTabPlus: Spec(symbol: "plus", pointSize: 13, weight: .medium, arcInk: CGSize(width: 11, height: 11), note: "\"New Tab\" row", offset: CGSize(width: -1, height: 1))
        case .rowClose: Spec(symbol: "xmark", pointSize: 13, weight: .semibold, arcInk: CGSize(width: 10, height: 10), note: "hovered or selected Today row")
        case .rowUnload: Spec(symbol: "minus", pointSize: 17, weight: .semibold, arcInk: CGSize(width: 14, height: 2), note: "selected loaded pinned row")
        case .disclosureDown: Spec(symbol: "chevron.down", pointSize: 12, weight: .bold, arcInk: nil, note: "Space header on hover (pinned shown)")
        case .disclosureRight: Spec(symbol: "chevron.right", pointSize: 12, weight: .bold, arcInk: nil, note: "Space header on hover (pinned collapsed)")
        case .clearArrow: Spec(symbol: "arrow.down", pointSize: 9, weight: .semibold, arcInk: nil, note: "Today divider \"Clear\" (AX frame 12×9)")
        case .spaceMore: Spec(symbol: "ellipsis", pointSize: 13, weight: .bold, arcInk: nil, note: "Space header on hover")
        case .audioPlaying: Spec(symbol: "speaker.wave.2.fill", pointSize: 11, weight: .regular, arcInk: nil, note: "row audio indicator")
        case .audioMuted: Spec(symbol: "speaker.slash.fill", pointSize: 11, weight: .regular, arcInk: nil, note: "row audio indicator")
        case .library: Spec(symbol: "archivebox.fill", pointSize: 15, weight: .regular, arcInk: CGSize(width: 14, height: 16), note: "bottom-bar Home / Library; drawn by CustomIcon.library, the symbol is a fallback")
        case .bottomPlus: Spec(symbol: "plus", pointSize: 17, weight: .medium, arcInk: CGSize(width: 14, height: 14), note: "bottom-bar plus")
        case .mediaPlay: Spec(symbol: "play.fill", pointSize: 14, weight: .medium, arcInk: nil, note: "media plan §13.4.3; PP-16")
        case .mediaPause: Spec(symbol: "pause.fill", pointSize: 14, weight: .medium, arcInk: CGSize(width: 9, height: 12), note: "media plan §13.4.3; PP-16")
        case .mediaPrevious: Spec(symbol: "backward.end.fill", pointSize: 14, weight: .medium, arcInk: CGSize(width: 13, height: 11), note: "media plan §13.4.3; PP-16")
        case .mediaNext: Spec(symbol: "forward.end.fill", pointSize: 14, weight: .medium, arcInk: CGSize(width: 13, height: 11), note: "media plan §13.4.3; PP-16")
        case .mediaPiP: Spec(symbol: "pip", pointSize: 12, weight: .medium, arcInk: CGSize(width: 15, height: 13), note: "media plan §13.4.3; PP-16")
        case .mediaClose: Spec(symbol: "xmark", pointSize: 14, weight: .medium, arcInk: CGSize(width: 11, height: 11), note: "media plan §13.4.3; PP-16")
        case .mediaVolume: Spec(symbol: "speaker.wave.3.fill", pointSize: 14, weight: .medium, arcInk: CGSize(width: 19, height: 14), note: "media plan §13.4.3; PP-16")
        case .mediaVolumeMuted: Spec(symbol: "speaker.slash.fill", pointSize: 14, weight: .medium, arcInk: nil, note: "media plan §13.4.3; PP-16")
        case .mediaMicrophone: Spec(symbol: "mic.fill", pointSize: 14, weight: .medium, arcInk: nil, note: "media plan §13.4.3; PP-16")
        case .mediaMicrophoneMuted: Spec(symbol: "mic.slash.fill", pointSize: 14, weight: .medium, arcInk: nil, note: "media plan §13.4.3; PP-16")
        case .mediaCamera: Spec(symbol: "video.fill", pointSize: 14, weight: .medium, arcInk: nil, note: "media plan §13.4.3; PP-16")
        case .mediaCameraOff: Spec(symbol: "video.slash.fill", pointSize: 14, weight: .medium, arcInk: nil, note: "media plan §13.4.3; PP-16")
        case .mediaVolumeLow: Spec(symbol: "speaker.wave.1.fill", pointSize: 12, weight: .medium, arcInk: nil, note: "media plan §13.4.3; PP-16")
        case .mediaVolumeHigh: Spec(symbol: "speaker.wave.3.fill", pointSize: 12, weight: .medium, arcInk: nil, note: "media plan §13.4.3; PP-16")
        case .pipClose: Spec(symbol: "xmark", pointSize: 12, weight: .semibold, arcInk: nil, note: "media plan §4; PP-6/PP-16")
        case .pipMinimize: Spec(symbol: "minus", pointSize: 13, weight: .bold, arcInk: nil, note: "media plan §4; PP-6/PP-16")
        case .pipSettings: Spec(symbol: "ellipsis", pointSize: 13, weight: .bold, arcInk: nil, note: "media plan §4; PP-6/PP-16")
        case .pipPlay: Spec(symbol: "play.fill", pointSize: 28, weight: .regular, arcInk: nil, note: "media plan §4; PP-6/PP-16")
        case .pipPause: Spec(symbol: "pause.fill", pointSize: 28, weight: .regular, arcInk: nil, note: "media plan §4; PP-6/PP-16")
        case .pipPrevious: Spec(symbol: "backward.end.fill", pointSize: 16, weight: .regular, arcInk: nil, note: "media plan §4; PP-6/PP-16")
        case .pipNext: Spec(symbol: "forward.end.fill", pointSize: 16, weight: .regular, arcInk: nil, note: "media plan §4; PP-6/PP-16")
        case .pipMute: Spec(symbol: "speaker.slash.fill", pointSize: 13, weight: .regular, arcInk: nil, note: "media plan §4; PP-6/PP-16")
        case .pipUnmute: Spec(symbol: "speaker.wave.2.fill", pointSize: 13, weight: .regular, arcInk: nil, note: "media plan §4; PP-6/PP-16")
        case .pipHangUp: Spec(symbol: "phone.down.fill", pointSize: 14, weight: .regular, arcInk: nil, note: "media plan §4; PP-6/PP-16")
        case .pipSkipBack: Spec(symbol: "gobackward.15", pointSize: 20, weight: .regular, arcInk: nil, note: "media plan §4; PP-6/PP-16")
        case .pipSkipForward: Spec(symbol: "goforward.15", pointSize: 20, weight: .regular, arcInk: nil, note: "media plan §4; PP-6/PP-16")
        case .globe: Spec(symbol: "globe", pointSize: 14, weight: .regular, arcInk: nil, note: "favicon fallback")
        }
    }

    /// Template image. Tint it with `NSImage.drawTinted` or a layer mask.
    @MainActor public var image: NSImage? {
        if self == .library { return CustomIcon.template(size: 16, cacheKey: "library") { CustomIcon.library(in: $0, color: .black) } }
        return GlyphCache.image(self)
    }
}

@MainActor
enum GlyphCache {
    private static var cache: [Glyph: NSImage] = [:]
    static func image(_ glyph: Glyph) -> NSImage? {
        if let i = cache[glyph] { return i }
        let spec = glyph.spec
        guard let base = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: nil) else { return nil }
        let image = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: spec.pointSize, weight: spec.weight)) ?? base
        image.isTemplate = true
        cache[glyph] = image
        return image
    }
}

/// Vectors no SF Symbol covers. Drawn in code, never copied.
public enum CustomIcon {
    @MainActor private static var letters: [String: NSImage] = [:]

    /// Fallback favicon: rounded square with the host's first letter. Cached per letter, size, and colors.
    @MainActor public static func letterFavicon(_ letter: String, size: CGFloat, fill: NSColor, text: NSColor) -> NSImage {
        let key = "\(letter)|\(size)|\(fill.description)|\(text.description)"
        if let i = letters[key] { return i }
        if letters.count > 256 { letters.removeAll() }
        let image = drawLetterFavicon(letter, size: size, fill: fill, text: text)
        letters[key] = image
        return image
    }

    @MainActor private static func drawLetterFavicon(_ letter: String, size: CGFloat, fill: NSColor, text: NSColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: size * 0.22, yRadius: size * 0.22)
            fill.setFill(); path.fill()
            let font = NSFont.systemFont(ofSize: size * 0.58, weight: .semibold)
            let s = NSAttributedString(string: letter.uppercased(), attributes: [.font: font, .foregroundColor: text])
            let b = s.size()
            s.draw(at: NSPoint(x: rect.midX - b.width / 2, y: rect.midY - b.height / 2 + 0.5))
            return true
        }
    }

    /// Folder glyph: closed (one filled shape with a tab) or open (a lighter back
    /// panel and a skewed front). Draws into a flipped context.
    @MainActor public static func folder(open: Bool, in r: CGRect, color: NSColor) {
        let tabW = r.width * 0.4, tabH: CGFloat = 2.4, c: CGFloat = 1.6
        let back = NSBezierPath()
        back.move(to: NSPoint(x: r.minX + c, y: r.minY))
        back.line(to: NSPoint(x: r.minX + tabW - 1, y: r.minY))
        back.line(to: NSPoint(x: r.minX + tabW + 1.4, y: r.minY + tabH))
        back.line(to: NSPoint(x: r.maxX - c, y: r.minY + tabH))
        back.appendArc(withCenter: NSPoint(x: r.maxX - c, y: r.minY + tabH + c), radius: c, startAngle: 270, endAngle: 0)
        back.line(to: NSPoint(x: r.maxX, y: r.maxY - c))
        back.appendArc(withCenter: NSPoint(x: r.maxX - c, y: r.maxY - c), radius: c, startAngle: 0, endAngle: 90)
        back.line(to: NSPoint(x: r.minX + c, y: r.maxY))
        back.appendArc(withCenter: NSPoint(x: r.minX + c, y: r.maxY - c), radius: c, startAngle: 90, endAngle: 180)
        back.line(to: NSPoint(x: r.minX, y: r.minY + c))
        back.appendArc(withCenter: NSPoint(x: r.minX + c, y: r.minY + c), radius: c, startAngle: 180, endAngle: 270)
        back.close()
        if open {
            color.withAlphaComponent(0.55).setFill()
            back.fill()
            let top = r.minY + r.height * 0.38
            let front = NSBezierPath()
            front.move(to: NSPoint(x: r.minX + 2.6, y: top))
            front.line(to: NSPoint(x: r.maxX + 1.2, y: top))
            front.line(to: NSPoint(x: r.maxX - 1.8, y: r.maxY))
            front.line(to: NSPoint(x: r.minX, y: r.maxY))
            front.close()
            color.setFill()
            front.fill()
        } else {
            color.setFill()
            back.fill()
            NSColor.white.withAlphaComponent(0.25).setFill()
            NSRect(x: r.minX, y: r.minY + tabH + 1.2, width: r.width, height: 0.8).fill()
        }
    }

    // Fixed, reusable vector paths avoid allocating four paths for every recycled row.
    @MainActor private static let peekFolderBody: NSBezierPath = {
        let r = CGRect(x: 0.5, y: 1.5, width: 17, height: 15)
        let tabW = r.width * 0.4, tabH: CGFloat = 2.4, c: CGFloat = 1.6
        let path = NSBezierPath()
        path.move(to: NSPoint(x: r.minX + c, y: r.minY))
        path.line(to: NSPoint(x: r.minX + tabW - 1, y: r.minY))
        path.line(to: NSPoint(x: r.minX + tabW + 1.4, y: r.minY + tabH))
        path.line(to: NSPoint(x: r.maxX - c, y: r.minY + tabH))
        path.appendArc(withCenter: NSPoint(x: r.maxX - c, y: r.minY + tabH + c), radius: c, startAngle: 270, endAngle: 0)
        path.line(to: NSPoint(x: r.maxX, y: r.maxY - c))
        path.appendArc(withCenter: NSPoint(x: r.maxX - c, y: r.maxY - c), radius: c, startAngle: 0, endAngle: 90)
        path.line(to: NSPoint(x: r.minX + c, y: r.maxY))
        path.appendArc(withCenter: NSPoint(x: r.minX + c, y: r.maxY - c), radius: c, startAngle: 90, endAngle: 180)
        path.line(to: NSPoint(x: r.minX, y: r.minY + c))
        path.appendArc(withCenter: NSPoint(x: r.minX + c, y: r.minY + c), radius: c, startAngle: 180, endAngle: 270)
        path.close(); return path
    }()
    @MainActor private static let peekFolderDots: NSBezierPath = {
        let path = NSBezierPath(), m = SpaceListMetrics.self, d = m.folderPeekDotDiameter
        for i in 0..<3 {
            let center = NSPoint(x: m.folderPeekDotFirstX + CGFloat(i) * m.folderPeekDotPitch + 0.5, y: m.folderPeekDotY + 0.5)
            path.appendOval(in: CGRect(x: center.x - d/2, y: center.y - d/2, width: d, height: d))
        }
        return path
    }()

    /// Open's own closed-folder vector; nominal frame reconciles the existing 20 pt host.
    @MainActor public static func folderPeek(in frame: CGRect, color: NSColor, dotsColor: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.minY)
        context.scaleBy(x: frame.width / 18, y: frame.height / 18)
        color.setFill(); peekFolderBody.fill()
        NSColor.white.withAlphaComponent(0.25).setFill()
        CGRect(x: 0.5, y: 5.1, width: 17, height: 0.8).fill()
        dotsColor.setFill(); peekFolderDots.fill()
        context.restoreGState()
    }

    @MainActor private static var templates: [String: NSImage] = [:]

    /// A template image drawn once by `draw` in a flipped context.
    @MainActor public static func template(size: CGFloat, cacheKey: String, draw: @escaping (CGRect) -> Void) -> NSImage {
        if let i = templates[cacheKey] { return i }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in draw(rect); return true }
        image.isTemplate = true
        templates[cacheKey] = image
        return image
    }

    /// Default Space mark (no emoji set): a sphere with a tilted ring.
    @MainActor public static func planet(in r: CGRect, color: NSColor) {
        let d = r.width * 0.66
        let body = CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
        color.setFill()
        NSBezierPath(ovalIn: body).fill()
        let ring = NSBezierPath(ovalIn: CGRect(x: -r.width * 0.58, y: -r.height * 0.16, width: r.width * 1.16, height: r.height * 0.32))
        var t = AffineTransform(translationByX: r.midX, byY: r.midY)
        t.rotate(byDegrees: -18)
        ring.transform(using: t)
        ring.lineWidth = max(1, r.width * 0.07)
        color.setStroke()
        ring.stroke()
    }

    /// Library (bottom-bar Home): a filled box with a lid and two items above it.
    /// Ink box 14×16 like Arc's measured glyph; the art is ours.
    @MainActor public static func library(in r: CGRect, color: NSColor) {
        color.setFill()
        let w: CGFloat = 14, h: CGFloat = 16
        let x = r.midX - w / 2, y = r.midY - h / 2   // flipped: y grows down
        NSBezierPath(roundedRect: CGRect(x: x + 1, y: y + 7.5, width: w - 2, height: 8.5), xRadius: 2, yRadius: 2).fill()
        NSBezierPath(roundedRect: CGRect(x: x, y: y + 5, width: w, height: 2), xRadius: 1, yRadius: 1).fill()
        NSBezierPath(ovalIn: CGRect(x: x + 2.5, y: y + 0.5, width: 3.5, height: 3.5)).fill()
        NSBezierPath(roundedRect: CGRect(x: x + 7.5, y: y, width: 3.5, height: 4.5), xRadius: 0.8, yRadius: 0.8).fill()
        color.withAlphaComponent(0.0).setFill()
    }
}


extension CustomIcon {
}
