import AppKit

/// Every glyph the sidebar draws. Each maps to an SF Symbol with a point size
/// and weight tuned so the 1x ink matches Arc's measured ink box, or to a
/// custom vector drawn in code (`Glyph.draw`). We never ship Arc's images.
public enum Glyph: String, CaseIterable, Sendable {
    case sidebarToggle, back, forward, reload, stopLoading
    case magnifier, copyLink, siteControls
    case newTabPlus, rowClose, rowUnload, resetToPinned
    case folderClosed, folderOpen, disclosure
    case spaceMore, audioPlaying, audioMuted
    case library, bottomPlus, archive
    case globe, splitView

    public struct Spec: Sendable {
        public var symbol: String?
        public var pointSize: CGFloat
        public var weight: NSFont.Weight
        /// Measured or target ink box at 1x (width × height), for checks.
        public var ink: CGSize?
        public var note: String
    }

    public var spec: Spec {
        switch self {
        case .sidebarToggle: Spec(symbol: "sidebar.left", pointSize: 15, weight: .regular, ink: CGSize(width: 19, height: 15), note: "Arc: rounded rect with a lined left pane")
        case .back: Spec(symbol: "arrow.left", pointSize: 15, weight: .regular, ink: CGSize(width: 15, height: 12), note: "thin arrow")
        case .forward: Spec(symbol: "arrow.right", pointSize: 15, weight: .regular, ink: CGSize(width: 15, height: 12), note: "thin arrow")
        case .reload: Spec(symbol: "arrow.clockwise", pointSize: 15, weight: .regular, ink: CGSize(width: 14, height: 17), note: "open circle arrow")
        case .stopLoading: Spec(symbol: "xmark", pointSize: 13, weight: .regular, ink: nil, note: "while loading")
        case .magnifier: Spec(symbol: "magnifyingglass", pointSize: 11, weight: .semibold, ink: CGSize(width: 12, height: 12), note: "URL field, empty state")
        case .copyLink: Spec(symbol: "link", pointSize: 13, weight: .medium, ink: nil, note: "URL field accessory")
        case .siteControls: Spec(symbol: "slider.horizontal.2.square", pointSize: 14, weight: .medium, ink: nil, note: "Site Control Center entry")
        case .newTabPlus: Spec(symbol: "plus", pointSize: 13, weight: .medium, ink: CGSize(width: 11, height: 11), note: "\"New Tab\" row")
        case .rowClose: Spec(symbol: "xmark", pointSize: 12, weight: .semibold, ink: CGSize(width: 10, height: 10), note: "hovered Today row")
        case .rowUnload: Spec(symbol: "minus", pointSize: 13, weight: .semibold, ink: CGSize(width: 14, height: 2), note: "selected pinned row: close and keep pinned")
        case .resetToPinned: Spec(symbol: "arrow.uturn.backward", pointSize: 12, weight: .medium, ink: nil, note: "\"Back to Pinned URL\"")
        case .folderClosed: Spec(symbol: "folder", pointSize: 14, weight: .regular, ink: nil, note: "folder row icon")
        case .folderOpen: Spec(symbol: "folder", pointSize: 14, weight: .regular, ink: nil, note: "custom open-folder art is a TODO")
        case .disclosure: Spec(symbol: "chevron.right", pointSize: 10, weight: .bold, ink: nil, note: "rotates 90° when expanded")
        case .spaceMore: Spec(symbol: "ellipsis", pointSize: 13, weight: .bold, ink: nil, note: "Space header, shown on hover")
        case .audioPlaying: Spec(symbol: "speaker.wave.2.fill", pointSize: 11, weight: .regular, ink: nil, note: "row audio indicator")
        case .audioMuted: Spec(symbol: "speaker.slash.fill", pointSize: 11, weight: .regular, ink: nil, note: "row audio indicator")
        case .library: Spec(symbol: "archivebox.fill", pointSize: 14, weight: .regular, ink: CGSize(width: 15, height: 16), note: "Home/Library; Arc uses its own box art")
        case .bottomPlus: Spec(symbol: "plus", pointSize: 16, weight: .regular, ink: CGSize(width: 14, height: 14), note: "bottom-bar plus")
        case .archive: Spec(symbol: "archivebox", pointSize: 14, weight: .regular, ink: nil, note: "archive entry")
        case .globe: Spec(symbol: "globe", pointSize: 14, weight: .regular, ink: CGSize(width: 16, height: 16), note: "favicon fallback")
        case .splitView: Spec(symbol: "rectangle.split.2x1", pointSize: 13, weight: .regular, ink: nil, note: "split row badge")
        }
    }

    /// Template symbol image. Tint it with `tinted(_:)` or a layer mask.
    @MainActor public var image: NSImage? { GlyphCache.image(self) }
}

@MainActor
enum GlyphCache {
    private static var cache: [Glyph: NSImage] = [:]
    static func image(_ glyph: Glyph) -> NSImage? {
        if let i = cache[glyph] { return i }
        let spec = glyph.spec
        guard let name = spec.symbol,
              let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: spec.pointSize, weight: spec.weight)
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = true
        cache[glyph] = image
        return image
    }
}

extension NSImage {
    /// Draws a template image filled with `color` into a new image of the same size.
    @MainActor public func tinted(_ color: NSColor) -> NSImage {
        let out = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        out.isTemplate = false
        return out
    }
}

/// Custom vectors for things no SF Symbol covers. Drawn in code, never copied.
public enum CustomIcon {
    /// Fallback favicon: rounded square with the host's first letter.
    @MainActor public static func letterFavicon(_ letter: String, size: CGFloat, fill: NSColor, text: NSColor) -> NSImage {
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
}
