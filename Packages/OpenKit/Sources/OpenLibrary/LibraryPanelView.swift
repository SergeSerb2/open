import AppKit
import Observation
import OpenDesign
import OpenModel
import OpenSettings
import OpenSidebar

private final class LibraryRailDocument: NSView {
    override var isFlipped: Bool { true }
}

/// Lazily hosted in a browser root. The existing full-window Space field shows
/// through every transparent part; only the rail adds its darkening and shadow.
@MainActor
public final class LibraryPanelView: NSView, NSTextFieldDelegate {
    public override var isFlipped: Bool { true }
    public let viewModel: LibraryViewModel
    public let context: SidebarContext
    public private(set) var section: LibraryPanelSection
    public private(set) var sections: [LibraryPanelSection] = []
    public private(set) var filterOpen = false
    public var onClose: (() -> Void)?
    public var onWidthChange: ((CGFloat) -> Void)?
    public var isPresented = false {
        didSet { if isPresented { refresh(); observeTheme() } }
    }
    public var desiredWidth: CGFloat { section == .spaces ? max(417, (superview?.bounds.width ?? 1280)-56) : 417 }
    private let rail = NSScrollView()
    private let railDocument = LibraryRailDocument()
    private var tiles: [LibraryPanelSection: LibraryControl] = [:]
    private let back = LibraryControl(title: "", glyph: .back)
    private let header = NSView()
    public let searchField = NSTextField()
    private let searchGlyph = LibraryGlyphView()
    private let filter = LibraryControl(title: "Filter", glyph: .filter)
    private let content = NSView()
    private let emptyGlyph = LibraryGlyphView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyBody = NSTextField(wrappingLabelWithString: "")
    private let emptyButton = LibraryControl(title: "")
    private var foreground = NSColor.labelColor
    private var overlay = NSColor.labelColor
    private var observationArmed = false
    private var styleRefreshPending = false

    public init(viewModel: LibraryViewModel, context: SidebarContext) {
        self.viewModel = viewModel; self.context = context
        section = LibraryPanelSection(viewModel.section)
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
        rail.drawsBackground = false; rail.hasVerticalScroller = false
        rail.horizontalScrollElasticity = .none; rail.verticalScrollElasticity = .none
        rail.documentView = railDocument
        rail.setAccessibilityRole(.tabGroup); rail.setAccessibilityLabel("Library")
        addSubview(rail)
        back.setAccessibilityLabel("Back to browser")
        back.onPress = { [weak self] in self?.onClose?() }; addSubview(back)
        header.wantsLayer = true; header.layer?.cornerRadius = 10
        addSubview(header)
        searchField.isBordered = false; searchField.drawsBackground = false
        searchField.font = .systemFont(ofSize: 14); searchField.focusRingType = .none
        searchField.lineBreakMode = .byTruncatingTail; searchField.usesSingleLineMode = true
        searchField.delegate = self
        searchField.setAccessibilityLabel("Search Library")
        searchGlyph.glyph = .search
        header.addSubview(searchGlyph); header.addSubview(searchField)
        filter.baseAlpha = 0.045; addSubview(filter)
        content.wantsLayer = true; addSubview(content)
        for view in [emptyGlyph,emptyTitle,emptyBody,emptyButton] { content.addSubview(view) }
        emptyTitle.font = .systemFont(ofSize:17,weight:.bold); emptyTitle.alignment = .center
        emptyBody.font = .systemFont(ofSize:14); emptyBody.alignment = .center
        emptyBody.maximumNumberOfLines = 4
        emptyButton.baseAlpha = 0.09
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func refresh() {
        let visible = LibraryPanelSection.visible(in:viewModel.defaults)
        if visible != sections {
            tiles.values.forEach { $0.removeFromSuperview() }; tiles = [:]; sections = visible
            for candidate in sections {
                let tile = LibraryControl(title:candidate.title,glyph:LibraryGlyph(rawValue:candidate.rawValue),tile:true)
                tile.identifier = NSUserInterfaceItemIdentifier("library-\(candidate.rawValue)")
                tile.onPress = { [weak self] in self?.select(candidate) }
                tile.onArrow = { [weak self] delta in self?.moveRail(delta) }
                railDocument.addSubview(tile); tiles[candidate] = tile
            }
        }
        if !sections.contains(section) { section = .downloads; viewModel.section = .downloads }
        refreshTheme()
        updateSection()
        needsLayout = true
    }
    public func select(_ next: LibraryPanelSection, animated: Bool = true) {
        guard sections.contains(next) else { return }
        let changed = section != next
        section = next
        if let mapped = next.modelSection { viewModel.section = mapped }
        filterOpen = false
        updateSection()
        onWidthChange?(desiredWidth)
        needsLayout = true; layoutSubtreeIfNeeded()
        if changed, animated, window?.isVisible == true {
            content.layer?.removeAnimation(forKey:"librarySection")
            let fade = CABasicAnimation(keyPath:"opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.10
            content.layer?.add(fade,forKey:"librarySection")
        }
        NSAccessibility.post(element:rail,notification:.selectedChildrenChanged)
    }
    private func moveRail(_ delta: Int) {
        guard let index = sections.firstIndex(of: section), !sections.isEmpty else { return }
        let next = sections[(index+delta+sections.count)%sections.count]
        select(next)
        if let tile = tiles[next] { window?.makeFirstResponder(tile); tile.scrollToVisible(tile.bounds) }
    }
    private func updateSection() {
        for (candidate,tile) in tiles { tile.selected = candidate == section }
        header.isHidden = section == .spaces; filter.isHidden = !section.hasFilter
        searchField.placeholderAttributedString = NSAttributedString(string:section.placeholder,attributes:[.foregroundColor:foreground.withAlphaComponent(0.46),.font:NSFont.systemFont(ofSize:14)])
        searchField.setAccessibilityLabel(section.placeholder)
        if searchField.stringValue != viewModel.query { searchField.stringValue = viewModel.query }
        let noMatches = !viewModel.query.isEmpty
        let copy = section.emptyCopy
        emptyGlyph.glyph = LibraryGlyph(rawValue:section.rawValue) ?? .media
        emptyTitle.stringValue = noMatches ? "No matches" : copy.title
        emptyBody.stringValue = noMatches ? "Try another word." : copy.body
        emptyButton.title = copy.button ?? ""; emptyButton.isHidden = noMatches || copy.button == nil
        // Folder sources are intentionally unavailable until their feature exists.
        emptyButton.isEnabled = false
        emptyButton.toolTip = section == .media ? "Coming with folder sources" : nil
        if section == .media { emptyButton.setAccessibilityHelp("Coming with folder sources") }
        let ordered = sections.compactMap { tiles[$0] }
        for (a,b) in zip(ordered,ordered.dropFirst()) { a.nextKeyView = b }
        ordered.last?.nextKeyView = section == .spaces ? back : searchField
        searchField.nextKeyView = section.hasFilter ? filter : back
        filter.nextKeyView = back; back.nextKeyView = ordered.first
        needsDisplay = true
    }
    private func refreshTheme() {
        let style = context.focusedSpace.map { context.style(for:$0) } ?? .defaultTheme(system:context.systemAppearance)
        let appearance = style.resolvedAppearance(system:context.systemAppearance)
        self.appearance = appearance.nsAppearance
        foreground = style.titleColor(appearance).nsColor
        overlay = appearance == .dark ? .white : foreground
        for control in Array(tiles.values)+[back,filter,emptyButton] { control.foreground=foreground;control.overlay=overlay }
        searchField.textColor = foreground
        searchGlyph.color = foreground.withAlphaComponent(0.68)
        header.layer?.backgroundColor = overlay.withAlphaComponent(0.09).cgColor
        emptyGlyph.color = foreground.withAlphaComponent(0.46)
        emptyTitle.textColor = foreground; emptyBody.textColor = foreground.withAlphaComponent(0.68)
        needsDisplay = true
    }
    private func observeTheme() {
        guard isPresented, !observationArmed else { return }
        observationArmed = true
        withObservationTracking {
            _ = context.focusedSpace?.theme; _ = context.window?.focusedSpaceID
            _ = context.systemAppearance; _ = context.isWindowActive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observationArmed = false
                guard self.isPresented, !self.styleRefreshPending else { return }
                self.styleRefreshPending = true
                self.refreshTheme(); self.updateSection()
                self.styleRefreshPending = false; self.observeTheme()
            }
        }
    }
    public override func layout() {
        super.layout()
        let height = bounds.height
        rail.frame = CGRect(x:0,y:52,width:112,height:max(0,height-108))
        let pitch = min(100,max(72,floor((height-108)/CGFloat(max(1,sections.count)))))
        let extent = CGFloat(max(0,sections.count-1))*pitch+80
        let documentHeight = max(rail.bounds.height,extent)
        railDocument.frame = CGRect(x:0,y:0,width:112,height:documentHeight)
        let start = max(0,(documentHeight-extent)/2 - (sections.count == 6 ? 3 : 0))
        for (index,candidate) in sections.enumerated() { tiles[candidate]?.frame=CGRect(x:8,y:start+CGFloat(index)*pitch,width:97,height:80) }
        back.frame = CGRect(x:8,y:height-40,width:32,height:32)
        header.frame=CGRect(x:120,y:10,width:section.hasFilter ? 212 : 289,height:36)
        // Header is an unflipped native view: its child y coordinates are symmetric.
        searchGlyph.frame=CGRect(x:14.5,y:10.5,width:15,height:15)
        searchField.frame=CGRect(x:44,y:8,width:header.bounds.width-53,height:20)
        filter.frame=CGRect(x:336,y:10,width:73,height:36)
        content.frame=CGRect(x:112,y:56,width:max(0,bounds.width-112),height:max(0,height-56))
        let centerX = section == .spaces ? content.bounds.width/2 : 152.5
        // Content is native unflipped; translate the binding window-relative tops.
        let top = 365+(height-800)/2
        func frame(_ x: CGFloat,_ y: CGFloat,_ w: CGFloat,_ h: CGFloat)->CGRect { CGRect(x:x,y:content.bounds.height-(y-56)-h,width:w,height:h) }
        emptyGlyph.frame=frame(centerX-24,top,48,48)
        emptyTitle.frame=frame(centerX-148,top+64,296,22)
        emptyBody.frame=frame(centerX-118,top+92,236,56)
        let lines = ceil(emptyBody.attributedStringValue.boundingRect(with:CGSize(width:236,height:100),options:[.usesLineFragmentOrigin,.usesFontLeading]).height)
        let buttonWidth = (emptyButton.title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:13,weight:.semibold)]).width+24
        emptyButton.frame=frame(centerX-buttonWidth/2,top+92+max(17,lines)+14,buttonWidth,28)
    }
    public override func draw(_ dirtyRect:NSRect) {
        NSColor.black.withAlphaComponent(0.05).setFill(); CGRect(x:0,y:0,width:112,height:bounds.height).fill()
        NSGradient(starting:NSColor.black.withAlphaComponent(0.07),ending:.clear)?.draw(in:CGRect(x:112,y:0,width:10,height:bounds.height),angle:0)
    }
    public func setSearch(_ text: String) {
        viewModel.query = text; searchField.stringValue = text; updateSection()
    }
    public func controlTextDidChange(_ notification: Notification) { setSearch(searchField.stringValue) }
    public func handleKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command), event.keyCode == 3, section != .spaces {
            window?.makeFirstResponder(searchField); searchField.selectText(nil); return true
        }
        if event.keyCode == 53 {
            if filterOpen { filterOpen = false }
            else if !viewModel.query.isEmpty { setSearch("") }
            else { onClose?() }
            return true
        }
        return false
    }
    public func focusRail() { if let tile=tiles[section] { window?.makeFirstResponder(tile) } }
    /// Window-relative top-left coordinates, used by real socket capture clients.
    public func automationState() -> [String:Any] {
        layoutSubtreeIfNeeded()
        func rect(_ view:NSView)->[CGFloat] {
            let frame=convert(view.bounds,from:view)
            return [frame.minX,frame.minY,frame.width,frame.height]
        }
        return ["section":section.rawValue,"panelFrame":[frame.minX,frame.minY,frame.width,frame.height],
            "rail":sections.compactMap { candidate -> [String:Any]? in
                guard let tile=tiles[candidate] else { return nil }
                return ["id":candidate.rawValue,"frame":rect(tile),"selected":candidate == section,"hovered":tile.hovered,"focused":window?.firstResponder === tile]
            },
            "header":["searchFrame":section == .spaces ? [] : rect(header),"filterFrame":section.hasFilter ? rect(filter) : [],"filterOpen":filterOpen,"chips":[]] as [String:Any],
            "search":viewModel.query,"rows":[],"emptyState":["title":emptyTitle.stringValue,"body":emptyBody.stringValue,"iconFrame":rect(emptyGlyph),"buttonEnabled":emptyButton.isEnabled],
            "firstResponder":window?.firstResponder.map { String(describing:type(of:$0)) } ?? ""]
    }
    public func hoverTile(_ section: LibraryPanelSection, hovered: Bool) { tiles[section]?.hovered=hovered }
    public func pressBack() { back.performClick(nil) }
}
