import AppKit
import OpenDesign
import OpenModel

/// Shared Space card controls; the Library layout follows D1 card geometry.
@MainActor
public final class SpaceControlsView: NSView {
    public var libraryLayout = false { didSet { needsLayout = true } }
    private let edit = SpaceCardButton(pen:true)
    private let libraryMore = SpaceCardButton(pen:false)
    let context: SidebarContext
    let space: Space
    public let grabber: NSView
    private let grip: SpaceGrabber
    private let icon = SpaceIconView()
    private let title = TextLabel()
    private let profile = TextLabel()
    private let more = PlateButton(glyph: .spaceMore)
    private let profileIndicator: ProfileIndicatorButton
    var onGrab: (@MainActor (NSEvent) -> Void)?

    public init(context: SidebarContext, space: Space) {
        self.context = context; self.space = space
        profileIndicator = ProfileIndicatorButton(context:context,space:space)
        let grip = SpaceGrabber(); self.grip = grip; grabber = grip
        super.init(frame: .zero)
        wantsLayer = true
        grip.onGrab = { [weak self] event in self?.onGrab?(event) }
        grip.tooltip = { [unowned context, space] in Tooltip(title: "Drag to Reorder Space", style: context.style(for: space)) }
        grip.tint = { [unowned context, space] in context.roles(for: space).spaceTitle.nsColor }
        icon.context = context; icon.space = space; icon.emojiSize = 20
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.text = { [unowned context, space] in context.title(of: space) }
        title.color = { [unowned context, space] in context.roles(for: space).spaceTitle.nsColor }
        profile.font = .systemFont(ofSize: 11, weight: .medium)
        profile.inset = 6; profile.baseline = 13
        profile.text = { [unowned context, space] in context.model.profile(id: space.profileID)?.name ?? "" }
        profile.color = title.color
        profile.layer?.cornerRadius = 9
        more.context = context
        more.glyphTint = { [unowned context, space] _ in context.roles(for: space).spaceTitle.nsColor }
        more.tooltip = { [unowned context, space] in Tooltip(title: "More options", style: context.style(for: space)) }
        more.menuProvider = { [weak self] in self?.makeMenu() }
        profileIndicator.setAccessibilityIdentifier("spaceManagerSpaceHeaderIndicator")
        profileIndicator.menuProvider = { [weak self] in
            guard let self else {return nil}
            return SidebarMenus(context:self.context,beginRename:{_ in}).profile(self.space)
        }
        edit.isBordered = false
        edit.tint = { [unowned context,space] in context.roles(for: space).title.nsColor.withAlphaComponent(0.55) }
        libraryMore.tint = edit.tint
        libraryMore.target = self; libraryMore.action = #selector(moreSpace)
        libraryMore.setAccessibilityLabel("More options"); libraryMore.toolTip = "More options"
        edit.target = self; edit.action = #selector(editSpace)
        edit.setAccessibilityLabel("Edit Space"); edit.toolTip = "Edit Space"
        for view in [grip, icon, title, profile, more, profileIndicator, edit, libraryMore] { addSubview(view) }
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
        edit.isHidden = !libraryLayout; libraryMore.isHidden = !libraryLayout
        grip.libraryLayout = libraryLayout; more.isHidden = libraryLayout
        if libraryLayout {
            icon.frame = CGRect(x:13,y:12,width:26,height:26)
            title.frame = CGRect(x:44,y:12,width:max(0,bounds.width-86),height:26); title.baseline = 18
            title.color = { [unowned context, space] in context.roles(for: space).title.nsColor.withAlphaComponent(0.66) }
            edit.frame = CGRect(x:bounds.width-39,y:9,width:30,height:30)
            edit.contentTintColor = context.roles(for: space).title.nsColor.withAlphaComponent(0.66)
            grip.frame = CGRect(x:9,y:bounds.height-39,width:30,height:30)
            libraryMore.frame = CGRect(x:bounds.width-39,y:bounds.height-39,width:30,height:30)
            profile.isHidden = true; profileIndicator.isHidden = true
            return
        }
        grip.frame = CGRect(x: bounds.width - 58, y: 10, width: 24, height: 24)
        icon.frame = CGRect(x: 13, y: 9, width: 26, height: 26)
        more.frame = CGRect(x: bounds.width - 32, y: 10, width: 24, height: 24)
        title.frame = CGRect(x: 41, y: hasProfiles ? 1 : 9, width: max(0, bounds.width - 103), height: 26)
        title.baseline = 18
        profileIndicator.isHidden = !hasProfiles
        if hasProfiles {
            let size = ProfileIndicatorMetrics.hitSize
            let x = min(title.frame.minX + title.textWidth + ProfileIndicatorMetrics.gap, grip.frame.minX - size - ProfileIndicatorMetrics.gap)
            profileIndicator.frame=CGRect(x:x,y:4,width:size,height:size)
            title.frame.size.width=max(0,x-ProfileIndicatorMetrics.gap-title.frame.minX)
        }
        profile.isHidden = !hasProfiles
        profile.frame = CGRect(x: 41, y: 23, width: min(max(0, bounds.width - 103), profile.textWidth + 6), height: 18)
        profile.layer?.backgroundColor = GrayScale.a(4).cgColor(context.appearance(for: space))
    }
    @objc private func moreSpace() { makeMenu().popUp(positioning:nil,at:CGPoint(x:libraryMore.frame.minX,y:libraryMore.frame.maxY),in:self) }
    @objc private func editSpace() {
        let menu = SidebarMenus(context:context,beginRename:{ [weak self] _ in self?.beginRename() }).space(space)
        menu.popUp(positioning:nil,at:CGPoint(x:edit.frame.minX,y:edit.frame.maxY),in:self)
    }
    public func beginRename() {
        guard !context.hidesSpaceChrome else { return }
        context.suppressPreviews(.rename,true)
        let field = RenameField(frame:title.frame.insetBy(dx:-2,dy:-1))
        field.stringValue = context.title(of:space); field.font = title.font
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.textColor = context.roles(for: space).title.nsColor
        let id = space.id
        field.onEnd = { [weak self,weak field] value in
            let owner = field?.window
            field?.removeFromSuperview(); self?.title.isHidden = false
            self?.context.suppressPreviews(.rename,false)
            if let value { self?.context.send(.renameSpace(id,title:value)) }
            if let outline = self?.context.manager?.outline(spaceID:id) { owner?.makeFirstResponder(outline) }
        }
        title.isHidden = true; addSubview(field); window?.makeFirstResponder(field); field.currentEditor()?.selectAll(nil)
    }
    /// Laid-out header parts in this view's flipped coordinates (automation and spec checks).
    public var partFrames: [String: CGRect] {
        ["grabber": grip.frame, "icon": icon.frame, "title": title.frame, "more": libraryLayout ? libraryMore.frame : more.frame, "edit": edit.frame]
    }
    public var showsProfileChip: Bool { !profile.isHidden }
    public var displayedTitle: String { title.text() }
    public var displayedProfile: String? { showsProfileChip ? profile.text() : nil }
    public func makeMenu() -> NSMenu {
        if libraryLayout { return SidebarMenus(context:context,beginRename:{ [weak self] _ in self?.beginRename() }).space(space) }
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
    var libraryLayout = false
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
        if libraryLayout {
            let path = NSBezierPath(); path.lineWidth = 1.4; path.lineCapStyle = .round; path.lineJoinStyle = .round
            let offset = CGPoint(x:(bounds.width-16)/2,y:(bounds.height-16)/2)
            for values in [[CGFloat(8),2,8,14],[2,8,14,8],[6,4,8,2,10,4],[6,12,8,14,10,12],[4,6,2,8,4,10],[12,6,14,8,12,10]] {
                path.move(to:CGPoint(x:values[0]+offset.x,y:values[1]+offset.y))
                for i in stride(from:2,to:values.count,by:2) { path.line(to:CGPoint(x:values[i]+offset.x,y:values[i+1]+offset.y)) }
            }
            color.withAlphaComponent(0.55).setStroke(); path.stroke(); return
        }
        guard let image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) else { return }
        let size = image.size
        let rect = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        image.draw(in: rect)
        color.setFill(); rect.fill(using: .sourceAtop)
    }
}


/// Original 16-point pen and dots from D1-design-mockup.html.
@MainActor private final class SpaceCardButton: NSButton {
    let pen: Bool
    var tint: @MainActor () -> NSColor = { .labelColor }
    init(pen:Bool) { self.pen = pen; super.init(frame:.zero); isBordered = false }
    required init?(coder:NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func draw(_ dirtyRect:NSRect) {
        let color = tint(); let x = (bounds.width-16)/2, y = (bounds.height-16)/2
        if isHighlighted { color.withAlphaComponent(0.10).setFill(); NSBezierPath(roundedRect:bounds,xRadius:7,yRadius:7).fill() }
        if pen {
            let path = NSBezierPath(); path.lineWidth = 1.4; path.lineCapStyle = .round; path.lineJoinStyle = .round
            let points: [CGPoint] = [.init(x:10.8,y:2.7),.init(x:13.3,y:5.2),.init(x:5.7,y:12.8),.init(x:2.5,y:13.5),.init(x:3.2,y:10.3)]
            path.move(to:CGPoint(x:points[0].x+x,y:points[0].y+y))
            for point in points.dropFirst() { path.line(to:CGPoint(x:point.x+x,y:point.y+y)) }; path.close(); color.setStroke(); path.stroke()
        } else {
            color.setFill(); for dx in [CGFloat(3.5),8,12.5] { NSBezierPath(ovalIn:CGRect(x:x+dx-0.9,y:y+7.1,width:1.8,height:1.8)).fill() }
        }
    }
}
