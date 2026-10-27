import AppKit
import OpenDesign
import OpenModel

/// Compact header for a Space Manager column; all geometry is plan §3.2 guess.
@MainActor
public final class SpaceControlsView: NSView {
    let context: SidebarContext
    let space: Space
    public let grabber: NSView
    private let grip: SpaceGrabber
    private let icon = SpaceIconView()
    private let title = TextLabel()
    private let profile = TextLabel()
    private let more = PlateButton(glyph: .spaceMore)
    var onGrab: (@MainActor (NSEvent) -> Void)?

    public init(context: SidebarContext, space: Space) {
        self.context = context; self.space = space
        let grip = SpaceGrabber(); self.grip = grip; grabber = grip
        super.init(frame: .zero)
        wantsLayer = true
        grip.onGrab = { [weak self] event in self?.onGrab?(event) }
        grip.tooltip = { [unowned context, space] in Tooltip(title: "Drag to Reorder Space", style: context.style(for: space)) }
        grip.tint = { [unowned context, space] in SidebarRole.spaceTitle.resolved(context.appearance(for: space)).nsColor }
        icon.context = context; icon.space = space; icon.emojiSize = 20
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.text = { [unowned context, space] in context.title(of: space) }
        title.color = { [unowned context, space] in SidebarRole.spaceTitle.resolved(context.appearance(for: space)).nsColor }
        profile.font = .systemFont(ofSize: 11, weight: .medium)
        profile.inset = 6; profile.baseline = 13
        profile.text = { [unowned context, space] in context.model.profile(id: space.profileID)?.name ?? "" }
        profile.color = title.color
        profile.layer?.cornerRadius = 9
        more.context = context
        more.glyphTint = { [unowned context, space] _ in SidebarRole.spaceTitle.resolved(context.appearance(for: space)).nsColor }
        more.tooltip = { [unowned context, space] in Tooltip(title: "More options", style: context.style(for: space)) }
        more.menuProvider = { [weak self] in self?.makeMenu() }
        for view in [grip, icon, title, profile, more] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel(context.title(of: space))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override var isFlipped: Bool { true }
    public override func layout() {
        super.layout()
        let hasProfiles = tracked({
            _ = context.model.profile(id: space.profileID)?.name
            _ = context.appearance(for: space)
            return context.model.profiles.count > 1
        }) { [weak self] in self?.needsLayout = true }
        grip.frame = CGRect(x: bounds.width - 58, y: 10, width: 24, height: 24)
        icon.frame = CGRect(x: 13, y: 9, width: 26, height: 26)
        more.frame = CGRect(x: bounds.width - 32, y: 10, width: 24, height: 24)
        title.frame = CGRect(x: 41, y: hasProfiles ? 1 : 9, width: max(0, bounds.width - 103), height: 26)
        title.baseline = 18
        profile.isHidden = !hasProfiles
        profile.frame = CGRect(x: 41, y: 23, width: min(max(0, bounds.width - 103), profile.textWidth + 6), height: 18)
        profile.layer?.backgroundColor = GrayScale.a(4).cgColor(context.appearance(for: space))
    }
    /// Laid-out header parts in this view's flipped coordinates (automation and spec checks).
    public var partFrames: [String: CGRect] {
        ["grabber": grip.frame, "icon": icon.frame, "title": title.frame, "more": more.frame]
    }
    public var showsProfileChip: Bool { !profile.isHidden }
    public var displayedTitle: String { title.text() }
    public var displayedProfile: String? { showsProfileChip ? profile.text() : nil }
    public func makeMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let turn = NSMenuItem(title: "Turn into Folder", action: nil, keyEquivalent: "")
        let destinations = NSMenu(); destinations.autoenablesItems = false
        for other in context.model.spaces where other.id != space.id {
            destinations.addItem(ClosureMenuItem(context.title(of: other)) { [unowned context, space] in
                context.send(.exportSpaceIntoFolder(space: space.id, destination: other.id))
            })
        }
        turn.submenu = destinations; turn.isEnabled = !destinations.items.isEmpty
        menu.addItem(turn); menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Delete", enabled: context.model.spaces.count > 1) { [unowned context, space] in context.send(.deleteSpace(space.id)) })
        return menu
    }
}

@MainActor
private final class SpaceGrabber: NSView {
    var onGrab: (@MainActor (NSEvent) -> Void)?
    var tooltip: (@MainActor () -> Tooltip)?
    private var tracking: NSTrackingArea?
    var tint: @MainActor () -> NSColor = { .secondaryLabelColor }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true

        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Drag to Reorder Space")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        if let tooltip = tooltip?() { TooltipController.shared.schedule(tooltip, for: self, at: convert(event.locationInWindow, from: nil)) }
    }
    override func mouseExited(with event: NSEvent) { TooltipController.shared.cancel(for: self) }
    override func mouseDown(with event: NSEvent) { TooltipController.shared.cancel(for: self); onGrab?(event) }
    override func draw(_ dirtyRect: NSRect) {
        let color = tracked({ tint() }) { [weak self] in self?.needsDisplay = true }
        guard let image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) else { return }
        let size = image.size
        let rect = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        image.draw(in: rect)
        color.setFill(); rect.fill(using: .sourceAtop)
    }
}
