import AppKit

/// Transparent drag destinations measured in capture s11/v4/e1-blank-drag/e1-hold.ax.json:
/// 80 pt immediately outside the window's left edge; 30 pt outside the sidebar's right edge.
/// They exist only for a local tab drag. Both use the destination sidebar's production drop path.
@MainActor
public final class SidebarDropRails {
    private weak var sidebar: SidebarView?
    private var panels: [NSPanel] = []
    public var windows: [NSWindow] { panels }

    public init(sidebar: SidebarView) {
        self.sidebar = sidebar
        guard let parent = sidebar.window else { return }
        parent.layoutIfNeeded()
        let frame = parent.frame
        let sidebarFrame = parent.convertToScreen(sidebar.convert(sidebar.bounds, to: nil))
        let frames = [CGRect(x: frame.minX - 80, y: frame.minY, width: 80, height: frame.height),
                      CGRect(x: sidebarFrame.maxX, y: frame.minY, width: 30, height: frame.height)]
        for frame in frames {
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.contentView = SidebarDropRailView(sidebar: sidebar)
            parent.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            panels.append(panel)
        }
    }

    public func close() {
        sidebar?.clearDropIndicator()
        for panel in panels {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil); panel.close()
        }
        panels.removeAll()
    }
}

@MainActor
private final class SidebarDropRailView: NSView {
    private weak var sidebar: SidebarView?
    init(sidebar: SidebarView) {
        self.sidebar = sidebar
        super.init(frame: .zero)
        registerForDraggedTypes([.sidebarNode])
        setAccessibilityElement(false)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sidebar?.receiveRailDrop(sender, perform: false) == true ? .move : []
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        sidebar?.receiveRailDrop(sender, perform: false) == true
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        sidebar?.receiveRailDrop(sender, perform: true) == true
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { sidebar?.clearDropIndicator() }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { sidebar?.clearDropIndicator() }
}

/// Capture s11/v4/e1-blank-drag/e1-hold.png: the blue line is 4 physical pixels
/// at 2x (#363DFA); the ring's outer diameter is 16 pixels. It never changes row layout.
@MainActor
final class SidebarDropIndicator: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(false) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 54.0 / 255, green: 61.0 / 255, blue: 250.0 / 255, alpha: 1).setStroke()
        let ring = NSBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 6, height: 6))
        ring.lineWidth = 2; ring.stroke()
        let line = NSBezierPath(); line.move(to: CGPoint(x: 7, y: 4)); line.line(to: CGPoint(x: bounds.maxX, y: 4))
        line.lineWidth = 2; line.stroke()
    }
}
