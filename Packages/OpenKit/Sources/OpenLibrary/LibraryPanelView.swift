import AppKit
import Observation
import OpenDesign
import OpenModel
import OpenSettings
import OpenSidebar

final class LibraryRailDocument: NSView {
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
    public internal(set) var filterOpen = false
    public var onClose: (() -> Void)?
    public var onWidthChange: ((CGFloat) -> Void)?
    public var isPresented = false {
        didSet { if isPresented { refresh(); observeTheme(); beginContentUpdates() } else { endContentUpdates() } }
    }
    public var desiredWidth: CGFloat { section == .spaces ? max(417, (superview?.bounds.width ?? 1280)-56) : 417 }
    let rail = NSScrollView()
    let railDocument = LibraryRailDocument()
    var tiles: [LibraryPanelSection: LibraryControl] = [:]
    let back = LibraryControl(title: "", glyph: .back)
    let header = NSView()
    public let searchField = NSTextField()
    let searchGlyph = LibraryGlyphView()
    let filter = LibraryControl(title: "Filter", glyph: .filter)
    let content = NSView()
    let emptyGlyph = LibraryGlyphView()
    let emptyTitle = NSTextField(labelWithString: "")
    let emptyBody = NSTextField(wrappingLabelWithString: "")
    let emptyButton = LibraryControl(title: "")
    var foreground = NSColor.labelColor
    var overlay = NSColor.labelColor
    var observationArmed = false
    var styleRefreshPending = false
    let listView = LibraryListView()
    let filterEditor = LibraryFilterEditor()
    let boostsLayout = NSSegmentedControl(labels:["List","Gallery"],trackingMode:.selectOne,target:nil,action:nil)
    let boostsProfile = NSPopUpButton()
    let boostDisabledText = NSTextField(labelWithString:"Boosts are off.")
    let boostTurnOn = LibraryControl(title:"Turn On")
    var manager: SpaceManagerView?
    var reloadTask: Task<Void,Never>?
    var historyTask: Task<Void,Never>?
    var contentObservationArmed = false
    var reloadGeneration = 0
    var archiveReasonChips: Set<String> = []
    var archiveSpaceChips: Set<String> = []
    var historyWhenChips: Set<String> = []
    var archivePageLoading = false
    var historyPageLoading = false
    let statusLabel = NSTextField(wrappingLabelWithString:"")

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
        header.wantsLayer = true; header.layer?.cornerRadius = 10; header.layer?.cornerCurve = .continuous
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
        addSubview(listView); addSubview(filterEditor)
        filter.onPress = { [weak self] in self?.setFilterOpen(true) }
        filterEditor.onDone = { [weak self] in self?.setFilterOpen(false) }
        filterEditor.onToggle = { [weak self] id in self?.toggleChip(id) }
        filterEditor.onHeight = { [weak self] _ in self?.needsLayout = true }
        filterEditor.onClear = { [weak self] in self?.confirmClearHistory() }
        listView.onSelection = { [weak self] id in self?.viewModel.selectedIDs = id.map { [$0] } ?? [] }
        boostDisabledText.font = .systemFont(ofSize:13)
        boostTurnOn.onPress = { [weak self] in self?.viewModel.defaults.set(true,forKey:"open.advanced.enableBoosts"); self?.renderRows() }
        addSubview(boostDisabledText); addSubview(boostTurnOn)
        statusLabel.font = .systemFont(ofSize:12); addSubview(statusLabel)
        listView.onEnd = { [weak self] in self?.loadNextPage() }
        boostsLayout.target = self; boostsLayout.action = #selector(changeBoostLayout)
        boostsLayout.setAccessibilityLabel("Boosts layout"); boostsLayout.identifier = .init("boosts.layout")
        boostsProfile.target = self; boostsProfile.action = #selector(changeBoostProfile)
        boostsProfile.setAccessibilityLabel("Boosts Profile")
        addSubview(boostsLayout); addSubview(boostsProfile)
        emptyTitle.font = .systemFont(ofSize:17,weight:.bold); emptyTitle.alignment = .center
        emptyBody.font = .systemFont(ofSize:14); emptyBody.alignment = .center
        emptyBody.maximumNumberOfLines = 4
        emptyButton.baseAlpha = 0.09; emptyButton.labelSize = 13
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
        if changed, animated, window?.isVisible == true {
            let fade = CATransition(); fade.type = .fade; fade.duration = 0.10
            content.layer?.add(fade,forKey:"librarySection"); listView.layer?.add(fade,forKey:"librarySection")
            manager?.layer?.add(fade,forKey:"librarySection")
        }
        section = next
        if let mapped = next.modelSection { viewModel.section = mapped }
        filterOpen = false
        updateSection()
        if isPresented { refreshData() }
        onWidthChange?(desiredWidth)
        needsLayout = true; layoutSubtreeIfNeeded()
        NSAccessibility.post(element:rail,notification:.selectedChildrenChanged)
    }
    func moveRail(_ delta: Int) {
        guard let index = sections.firstIndex(of: section), !sections.isEmpty else { return }
        let next = sections[(index+delta+sections.count)%sections.count]
        select(next)
        if let tile = tiles[next] { window?.makeFirstResponder(tile); tile.scrollToVisible(tile.bounds) }
    }
    func updateSection() {
        for (candidate,tile) in tiles { tile.selected = candidate == section }
        header.isHidden = section == .spaces; filter.isHidden = !section.hasFilter
        searchField.placeholderAttributedString = NSAttributedString(string:section.placeholder,attributes:[.foregroundColor:foreground.withAlphaComponent(0.46),.font:NSFont.systemFont(ofSize:14)])
        searchField.setAccessibilityLabel(section.placeholder)
        if searchField.stringValue != viewModel.query { searchField.stringValue = viewModel.query }
        updateEmptyCopy()
        let ordered = sections.compactMap { tiles[$0] }
        for (a,b) in zip(ordered,ordered.dropFirst()) { a.nextKeyView = b }
        ordered.last?.nextKeyView = section == .spaces ? back : searchField
        searchField.nextKeyView = section.hasFilter ? filter : listView.table
        filter.nextKeyView = listView.table; listView.table.nextKeyView = back; back.nextKeyView = ordered.first
        renderRows()
        needsDisplay = true
    }
    func updateEmptyCopy() {
        let noMatches = !viewModel.query.isEmpty || hasActiveFilters
        let folderSources = section == .media && viewModel.defaults.bool(forKey:"libraryMediaFolderSources")
        let copy = folderSources ? (title:"Show your media here",body:"Screenshots, images and videos from this Mac, ready to drag into any page.",button:Optional("Choose Folders…")) : section.emptyCopy
        emptyGlyph.glyph = LibraryGlyph(rawValue:section.rawValue) ?? .media
        emptyTitle.stringValue = noMatches ? "No matches" : copy.title
        emptyBody.stringValue = noMatches ? "Try another word." : copy.body
        emptyButton.title = copy.button ?? ""; emptyButton.isHidden = noMatches || copy.button == nil
        // Folder sources are intentionally unavailable until their feature exists.
        emptyButton.isEnabled = false
        emptyButton.toolTip = section == .media ? "Coming with folder sources" : nil
        if section == .media { emptyButton.setAccessibilityHelp("Coming with folder sources") }
    }
    func refreshTheme() {
        let style = context.focusedSpace.map { context.style(for:$0) } ?? .defaultTheme(system:context.systemAppearance)
        let appearance = style.resolvedAppearance(system:context.systemAppearance)
        self.appearance = appearance.nsAppearance
        foreground = style.titleColor(appearance).nsColor
        overlay = appearance == .dark ? .white : foreground
        for control in Array(tiles.values)+[back,filter,emptyButton] { control.foreground=foreground;control.overlay=overlay }
        boostDisabledText.textColor = foreground.withAlphaComponent(0.68); boostTurnOn.foreground = foreground; boostTurnOn.overlay = overlay
        statusLabel.textColor = foreground.withAlphaComponent(0.68)
        searchField.textColor = foreground
        listView.foreground = foreground; listView.overlay = overlay
        searchGlyph.color = foreground.withAlphaComponent(0.68)
        header.layer?.backgroundColor = overlay.withAlphaComponent(0.09).cgColor
        emptyGlyph.color = foreground.withAlphaComponent(0.46)
        emptyTitle.textColor = foreground; emptyBody.textColor = foreground.withAlphaComponent(0.68)
        needsDisplay = true
    }
    func observeTheme() {
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
        // Lead 00:00: the tile block's center is H/2 - 5, then clamp to the
        // 52 ... H-56 rail viewport. An overfull minimum-pitch rail scrolls.
        let start = max(0,min(documentHeight-extent,(documentHeight-extent)/2-3))
        for (index,candidate) in sections.enumerated() { tiles[candidate]?.frame=CGRect(x:8,y:start+CGFloat(index)*pitch,width:97,height:80) }
        back.frame = CGRect(x:8,y:height-40,width:32,height:32)
        header.frame=CGRect(x:120,y:10,width:section.hasFilter ? 212 : 289,height:36)
        // Header is an unflipped native view: its child y coordinates are symmetric.
        searchGlyph.frame=CGRect(x:14.5,y:10.5,width:15,height:15)
        searchField.frame=CGRect(x:44,y:8,width:header.bounds.width-53,height:20)
        filter.frame=CGRect(x:336,y:10,width:73,height:36)
        content.frame=CGRect(x:112,y:56,width:max(0,bounds.width-112),height:max(0,height-56))
        let listTop: CGFloat = filterOpen ? filterEditor.contentHeight : section == .boosts ? (boostTurnOn.isHidden ? 92 : 132) : 56
        listView.frame = CGRect(x:112,y:listTop,width:304,height:max(0,height-listTop-(statusLabel.isHidden ? 0 : 42)))
        statusLabel.frame = CGRect(x:124,y:height-38,width:281,height:34)
        boostDisabledText.frame = CGRect(x:124,y:99,width:190,height:20)
        boostTurnOn.frame = CGRect(x:327,y:94,width:78,height:30)
        filterEditor.frame = CGRect(x:112,y:0,width:305,height:filterEditor.contentHeight)
        boostsLayout.frame = CGRect(x:120,y:54,width:140,height:28)
        boostsProfile.frame = CGRect(x:266,y:54,width:143,height:28)
        manager?.frame = CGRect(x:112,y:0,width:max(0,bounds.width-112),height:height)
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
        viewModel.query = text
        if searchField.stringValue != text { searchField.stringValue = text }
        updateSection()
        if isPresented { refreshData() }
    }
    public func controlTextDidChange(_ notification: Notification) { setSearch(searchField.stringValue) }
    public func handleKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command), event.keyCode == 3, section != .spaces {
            window?.makeFirstResponder(searchField); searchField.selectText(nil); return true
        }
        if event.keyCode == 53 {
            if listView.dismissMenu() { return true }
            if filterOpen { setFilterOpen(false) }
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
        let ink = foreground.usingColorSpace(.sRGB) ?? foreground
        return ["foreground":[ink.redComponent,ink.greenComponent,ink.blueComponent,ink.alphaComponent],"section":section.rawValue,"panelFrame":[frame.minX,frame.minY,frame.width,frame.height],
            "rail":sections.compactMap { candidate -> [String:Any]? in
                guard let tile=tiles[candidate] else { return nil }
                let point = tile.convert(CGPoint(x:tile.bounds.midX,y:tile.bounds.midY),to:nil)
                let hit = window?.contentView?.superview?.hitTest(point)
                return ["id":candidate.rawValue,"frame":rect(tile),"selected":candidate == section,"hovered":tile.hovered,"focused":window?.firstResponder === tile,
                    "hitClass":hit.map { String(describing:type(of:$0)) } ?? "", "canDragWindow":tile.mouseDownCanMoveWindow]
            },
            "header":["searchFrame":section == .spaces ? [] : rect(header),"filterFrame":section.hasFilter ? rect(filter) : [],"filterOpen":filterOpen,"chips":filterOpen ? filterEditor.state(in:self) : []] as [String:Any],
            "dragSession":listView.dragSession,"search":viewModel.query,"filterActive":hasActiveFilters,"rows":listView.state(in:self),"boostsLayout":viewModel.boostsPresentation == .gallery ? "Gallery" : "List", "status":viewModel.statusText, "emptyVisible":!content.isHidden,"emptyState":["title":emptyTitle.stringValue,"body":emptyBody.stringValue,"iconFrame":rect(emptyGlyph),"buttonEnabled":emptyButton.isEnabled,"buttonVisible":!emptyButton.isHidden],
            "menuOpen":listView.activeMenu != nil,"firstResponder":window?.firstResponder.map { String(describing:type(of:$0)) } ?? ""]
    }
    public func hoverTile(_ section: LibraryPanelSection, hovered: Bool) { tiles[section]?.hovered=hovered }
    public func pressBack() { back.performClick(nil) }
}
