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
    public static func deferIdlePreparation(until uptime:Double) { LibraryIdleWork.notBefore = uptime }
    public static func noteUserInput() { LibraryIdleWork.noteInput() }
    public var idleWorkIntervals: [[String:Double]] { LibraryIdleWork.intervals }
    public override var isFlipped: Bool { true }
    private let railTint = CALayer()
    private let railShadow = CAGradientLayer()
    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() {}
    public let viewModel: LibraryViewModel
    public let context: SidebarContext
    public private(set) var section: LibraryPanelSection
    public private(set) var sections: [LibraryPanelSection] = []
    public internal(set) var filterOpen = false
    public var onClose: (() -> Void)?
    public var onWidthChange: ((CGFloat) -> Void)?
    public var onIdleRefresh: (() -> Void)?
    public internal(set) var prebuiltReady = false
    var preparing = false
    var contentActive: Bool { isPresented || preparing }
    public var isPresented = false {
        didSet { guard isPresented != oldValue else { return }; if isPresented { if !prebuiltReady { refresh(); beginContentUpdates() }; observeTheme(); onIdleRefresh?() } else { prebuiltReady = false; endContentUpdates(); observeContent() }; updatePointerMonitor() }
    }
    public var desiredWidth: CGFloat { section == .spaces ? max(417, (superview?.bounds.width ?? 1280)-56) : 417 }
    let rail = NSScrollView()
    let railDocument = LibraryRailDocument()
    var tiles: [LibraryPanelSection: LibraryControl] = [:]
    let back = LibraryControl(title: "", glyph: .back)
    let header = NSView()
    public let searchField: NSTextField = LibrarySearchField()
    public var searchTimestamps: [String:Double] { (searchField as? LibrarySearchField)?.timestamps ?? [:] }
    public func beginSearchMeasurement() -> Double {
        (searchField as? LibrarySearchField)?.beginMeasurement() ?? ProcessInfo.processInfo.systemUptime
    }
    public func markSearchCommit() { (searchField as? LibrarySearchField)?.timestamps["commit"] = nativeCommittedAt }
    public internal(set) var nativeCommittedAt = 0.0
    var switchPhases: [String:Double] = [:]
    var lastHeaderLayoutKey = ""
    var warmedRows = false
    let searchGlyph = LibraryGlyphView()
    let filter = LibraryControl(title: "Filter", glyph: .filter)
    let content = NSView()
    let loadingSkeleton = LibrarySkeletonView()
    var skeletonTask: Task<Void,Never>?
    var idleWarming = false
    let emptyGlyph = LibraryGlyphView()
    let emptyTitle = LibraryField(labelWithString: "")
    let emptyBody = LibraryField(wrappingLabelWithString: "")
    let emptyButton = LibraryControl(title: "")
    var symbolCache: [String:NSImage] = [:]
    var foreground = NSColor.labelColor
    var overlay = NSColor.labelColor
    var observationArmed = false
    var styleRefreshPending = false
    var hosts: [LibraryPanelSection:LibrarySectionHost] = [:]
    var listView: LibraryListView { host(for:section).list }
    func host(for section:LibraryPanelSection) -> LibrarySectionHost {
        if let host = hosts[section] { return host }
        let host = LibrarySectionHost(); hosts[section] = host
        host.list.foreground = foreground; host.list.overlay = overlay
        host.list.onSelection = { [weak self] id in self?.viewModel.selectedIDs = id.map { [$0] } ?? [] }
        host.list.onEnd = { [weak self] in if self?.section == section { self?.loadNextPage() } }
        host.list.isHidden = true; addSubview(host.list)
        return host
    }
    var submissionPhases: [String:Double] = [:]
    var sourceObservationArmed: Set<LibraryPanelSection> = []
    let filterEditor = LibraryFilterEditor()
    let boostList = LibraryControl(title:"List")
    let boostGallery = LibraryControl(title:"Gallery")
    let boostsProfile = LibraryControl(title:"Profile")
    var keyboardRailNavigation = false
    private var pointerMonitor: Any?
    let boostDisabledText = LibraryField(labelWithString:"Boosts are off.")
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
    let statusLabel = LibraryField(wrappingLabelWithString:"")
    /// Library › Easels (EZ): the App's provider, its last list, and the header card.
    public weak var easelsProvider: (any LibraryEaselsProvider)? { didSet { if oldValue !== easelsProvider { reloadEasels() } } }
    var easelItems: [LibraryEaselItem] = []
    public weak var notesProvider: (any LibraryNotesProvider)? { didSet { if oldValue !== notesProvider { reloadEasels() } } }
    var noteItems: [LibraryNoteItem] = []
    let easelsCard = LibraryEaselsCard()

    public init(viewModel: LibraryViewModel, context: SidebarContext) {
        self.viewModel = viewModel; self.context = context
        section = LibraryPanelSection(viewModel.section)
        super.init(frame: .zero)
        wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay
        railTint.backgroundColor = NSColor.black.withAlphaComponent(0.05).cgColor
        railShadow.colors = [NSColor.black.withAlphaComponent(0.07).cgColor,NSColor.clear.cgColor]
        railShadow.startPoint = CGPoint(x:0,y:0.5); railShadow.endPoint = CGPoint(x:1,y:0.5)
        layer?.addSublayer(railTint); layer?.addSublayer(railShadow)
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
        searchField.identifier = .init("library.search")
        searchField.setAccessibilityLabel("Search Library")
        searchGlyph.glyph = .search
        header.addSubview(searchGlyph); header.addSubview(searchField)
        filter.baseAlpha = 0.045; addSubview(filter)
        content.wantsLayer = true; addSubview(content)
        for view in [emptyGlyph,emptyTitle,emptyBody,emptyButton] { content.addSubview(view) }
        _ = listView; loadingSkeleton.isHidden = true; addSubview(loadingSkeleton); addSubview(filterEditor)
        filter.onPress = { [weak self] in self?.setFilterOpen(true) }
        filterEditor.onDone = { [weak self] in self?.setFilterOpen(false) }
        filterEditor.onToggle = { [weak self] id in self?.toggleChip(id) }
        filterEditor.onHeight = { [weak self] _ in self?.needsLayout = true }
        filterEditor.onClear = { [weak self] in self?.confirmClearHistory() }
        listView.onSelection = { [weak self] id in self?.viewModel.selectedIDs = id.map { [$0] } ?? [] }
        boostDisabledText.font = .systemFont(ofSize:13)
        boostTurnOn.onPress = { [weak self] in self?.viewModel.defaults.set(true,forKey:"open.advanced.enableBoosts"); self?.renderRows() }
        addSubview(boostDisabledText); addSubview(boostTurnOn)
        easelsCard.isHidden = true; easelsCard.onExport = { [weak self] in self?.exportAllEasels() }; addSubview(easelsCard)
        statusLabel.font = .systemFont(ofSize:12); addSubview(statusLabel)
        for button in [boostList,boostGallery,boostsProfile] {
            button.isChip = true; button.baseAlpha = 0.045; button.labelSize = 12
            button.layer?.cornerRadius = 9; addSubview(button)
        }
        boostList.identifier = .init("boosts.layout.list"); boostGallery.identifier = .init("boosts.layout.gallery")
        boostsProfile.identifier = .init("boosts.profile"); boostsProfile.setAccessibilityLabel("Boosts Profile")
        boostList.onPress = { [weak self] in self?.setBoostLayout("List") }
        boostGallery.onPress = { [weak self] in self?.setBoostLayout("Gallery") }
        boostsProfile.onPress = { [weak self] in self?.showBoostProfiles() }
        emptyTitle.identifier = .init("library.emptyTitle"); emptyBody.identifier = .init("library.emptyBody")
        statusLabel.identifier = .init("library.status"); boostDisabledText.identifier = .init("library.boostDisabled")
        emptyTitle.font = .systemFont(ofSize:17,weight:.bold); emptyTitle.alignment = .center
        emptyBody.font = .systemFont(ofSize:14); emptyBody.alignment = .center
        emptyBody.maximumNumberOfLines = 4
        emptyButton.baseAlpha = 0.09; emptyButton.labelSize = 13
        // As an enabled key view this button kept a released panel alive (library_content
        // `closed_view_released` FAIL; passes with it out of the key-view loop). Mouse and
        // AXPress still press it. Follow-up: find the AppKit owner and restore Tab access.
        emptyButton.allowsKeyView = false
        // "Choose Folders…": turn on folder sources; reading them next asks macOS for access.
        emptyButton.onPress = { [weak self] in
            guard let self, self.section == .media, let folders = self.viewModel.mediaFolders else { return }
            folders.markOnboarded()
            Task { @MainActor [weak self] in await self?.viewModel.refreshExternalState(for:.media); self?.refresh() }
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Prepay first-screen native raster work without exposing the panel or
    /// moving the page. Explicit layer display also covers hidden descendants.
    public func prepareFirstScreen() async {
        guard !isPresented,!prebuiltReady else { return }
        preparing = true; prebuiltReady = false
        if !warmedRows {
            (searchField as? LibrarySearchField)?.warmEditor()
            FilePreviewCache.shared.warmPlaceholder()
            for name in ["globe","folder","paintbrush.pointed","doc"] { _ = LibraryImages.value(symbol(name)) }
            guard await LibraryListView.warmRowKinds(foreground:foreground,overlay:overlay),
                !Task.isCancelled else { preparing = false; return }
            warmedRows = true
        }
        refresh(); observeTheme(); observeContent(); refreshData()
        await finishPendingContent()
        guard !isPresented else { preparing = false; return }
        guard !Task.isCancelled else { preparing = false; endContentUpdates(); return }
        layoutSubtreeIfNeeded()
        func render(_ view:NSView) {
            guard !view.isHidden else { return }
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            view.layer?.displayIfNeeded()
            for child in view.subviews { render(child) }
            func display(_ layer:CALayer) { for child in layer.sublayers ?? [] { child.displayIfNeeded(); display(child) } }
            if let layer = view.layer { display(layer) }
        }
        // The root is hidden, but its intended visible children are populated.
        for child in subviews { render(child) }
        layer?.displayIfNeeded(); CATransaction.flush()
        preparing = false; prebuiltReady = true
    }

    /// Called by the same input-cancelled, three-second idle scheduler as the
    /// shell prebuild. Never changes the user's section, query or filters.
    public func warmSectionPages() async {
        guard isPresented,!idleWarming else { return }
        idleWarming = true
        defer { idleWarming = false }
        for target in sections where target != .spaces {
            guard !Task.isCancelled,isPresented else { return }
            let host = host(for:target)
            if !host.loaded {
                await loadProvider(target)
            }
            host.wasWarmed = host.loaded
            guard !Task.isCancelled else { return }
            await host.list.prepareOverscan()
            try? await Task.sleep(for:.milliseconds(32))
        }
    }
    public func cancelIdleWork() {
        for (target,host) in hosts {
            host.list.cancelPrefetch()
            if target != section { host.provider?.cancel(); host.provider = nil; host.providerGeneration += 1 }
        }
    }

    public func refresh() {
        let visible = LibraryPanelSection.visible(in:viewModel.defaults)
        if visible != sections {
            tiles.values.forEach { $0.removeFromSuperview() }; tiles = [:]; sections = visible
            for candidate in sections {
                let tile = LibraryControl(title:candidate.title,glyph:LibraryGlyph(rawValue:candidate.rawValue),tile:true)
                tile.identifier = NSUserInterfaceItemIdentifier("library-\(candidate.rawValue)")
                tile.onPress = { [weak self] in self?.select(candidate) }
                tile.onArrow = { [weak self] delta in self?.keyboardRailNavigation = true; self?.moveRail(delta) }
                tile.onKeyboardFocus = { [weak self] in DispatchQueue.main.async { self?.updateRailFocus() } }
                railDocument.addSubview(tile); tiles[candidate] = tile
            }
        }
        if !sections.contains(section) { section = .downloads; viewModel.section = .downloads }
        refreshTheme()
        updateSection()
        needsLayout = true
    }
    public func select(_ next: LibraryPanelSection, animated: Bool = true) {
        let started = ProcessInfo.processInfo.systemUptime
        switchPhases = [:]
        guard sections.contains(next) else { return }
        let changed = section != next
        if !changed && prebuiltReady { return }
        prebuiltReady = false
        skeletonTask?.cancel(); loadingSkeleton.isHidden = true
        if (!changed && !prebuiltReady) || next == .media { hosts[next]?.loaded = false }
        if changed, animated, window?.isVisible == true {
            let fade = CABasicAnimation(keyPath:"opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.10
            host(for:next).list.layer?.add(fade,forKey:"librarySection")
            content.layer?.add(fade,forKey:"librarySection"); manager?.layer?.add(fade,forKey:"librarySection")
        }
        let animationReady = ProcessInfo.processInfo.systemUptime
        section = next
        if let mapped = next.modelSection { viewModel.section = mapped }
        filterOpen = false
        updateSection()
        let headerReady = ProcessInfo.processInfo.systemUptime
        if isPresented { refreshData() }
        let dataReady = ProcessInfo.processInfo.systemUptime
        onWidthChange?(desiredWidth)
        layoutSubtreeIfNeeded()
        let layoutReady = ProcessInfo.processInfo.systemUptime
        if tiles.values.contains(where: { window?.firstResponder === $0 }) { focusRail() }
        updateRailFocus()
        NSAccessibility.post(element:rail,notification:.selectedChildrenChanged)
        let finished = ProcessInfo.processInfo.systemUptime
        switchPhases = ["animation":(animationReady-started)*1000,"headerVisibility":(headerReady-animationReady)*1000,
            "providerRequest":(dataReady-headerReady)*1000,"layout":(layoutReady-dataReady)*1000,"focusAX":(finished-layoutReady)*1000]
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
    static let folderSourcesBody = "Allow Open to show your Documents, Desktop, and Download Folders to see them here alongside your Captures."
    static let folderSourcesPitch = "Quickly grab screenshots, images, and videos from your computer by showing them in the Open Library!"
    func updateEmptyCopy() {
        // Downloads: every outside entry sets the Profile filter to the window owner's Profile, so a filter alone
        // does not mean the user narrowed anything. With no download in any Profile the copy stays "No downloads yet".
        let noMatches = !viewModel.query.isEmpty || (hasActiveFilters && !(section == .downloads && viewModel.downloads.downloads.isEmpty))
        let folderSources = section == .media && viewModel.mediaFolders.map { !$0.onboarded } == true
        // C-LF-5 (LEAD 20:45, Open's design): Arc's two first-use strings with "Open" (LB-1). The permission ask is
        // the body beside the button; the "Quickly grab…" line is the button's tooltip and accessibility help.
        let copy = folderSources ? (title:"Show your media here",body:LibraryPanelView.folderSourcesBody,button:Optional("Choose Folders…")) : section.emptyCopy
        emptyGlyph.glyph = LibraryGlyph(rawValue:section.rawValue) ?? .media
        emptyTitle.stringValue = noMatches ? "No matches" : copy.title
        emptyBody.stringValue = noMatches ? "Try another word." : copy.body
        emptyButton.title = copy.button ?? ""; emptyButton.isHidden = noMatches || copy.button == nil
        emptyButton.isEnabled = folderSources
        emptyButton.toolTip = folderSources && !noMatches ? LibraryPanelView.folderSourcesPitch : nil
        if section == .media { emptyButton.setAccessibilityHelp(folderSources ? LibraryPanelView.folderSourcesPitch : nil) }
    }
    func refreshTheme() {
        let style = context.focusedSpace.map { context.style(for:$0) } ?? .defaultTheme(system:context.systemAppearance)
        let appearance = style.resolvedAppearance(system:context.systemAppearance)
        self.appearance = appearance.nsAppearance
        foreground = style.titleColor(appearance).nsColor
        overlay = appearance == .dark ? .white : foreground
        for control in Array(tiles.values)+[back,filter,emptyButton,boostList,boostGallery,boostsProfile] { control.foreground=foreground;control.overlay=overlay }
        boostDisabledText.textColor = foreground.withAlphaComponent(0.68); boostTurnOn.foreground = foreground; boostTurnOn.overlay = overlay
        easelsCard.tint(foreground:foreground,overlay:overlay)
        statusLabel.textColor = foreground.withAlphaComponent(0.68)
        searchField.textColor = foreground
        for host in hosts.values { host.list.foreground = foreground; host.list.overlay = overlay }
        searchGlyph.color = foreground.withAlphaComponent(0.68)
        header.layer?.backgroundColor = overlay.withAlphaComponent(0.09).cgColor
        emptyGlyph.color = foreground.withAlphaComponent(0.46)
        emptyTitle.textColor = foreground; emptyBody.textColor = foreground.withAlphaComponent(0.68)
        loadingSkeleton.tint(overlay)
        needsDisplay = true
    }
    func observeTheme() {
        guard !observationArmed else { return }
        observationArmed = true
        withObservationTracking {
            _ = context.focusedSpace?.theme; _ = context.window?.focusedSpaceID
            _ = context.systemAppearance; _ = context.isWindowActive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observationArmed = false
                guard self.isPresented else { self.prebuiltReady = false; self.onIdleRefresh?(); self.observeTheme(); return }
                guard !self.styleRefreshPending else { return }
                self.styleRefreshPending = true
                self.refreshTheme(); self.updateSection()
                self.styleRefreshPending = false; self.observeTheme()
            }
        }
    }
    public override func layout() {
        super.layout()
        let height = bounds.height
        railTint.frame = CGRect(x:0,y:0,width:112,height:height)
        railShadow.frame = CGRect(x:112,y:0,width:10,height:height)
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
        let headerFrame = CGRect(x:120,y:10,width:section.hasFilter ? 212 : 289,height:36)
        if header.frame != headerFrame { header.frame = headerFrame }
        // Header is an unflipped native view: its child y coordinates are symmetric.
        let glyphFrame = CGRect(x:14.5,y:10.5,width:15,height:15)
        if searchGlyph.frame != glyphFrame { searchGlyph.frame = glyphFrame }
        let searchFrame = CGRect(x:44,y:8,width:header.bounds.width-53,height:20)
        if searchField.frame != searchFrame { searchField.frame = searchFrame }
        filter.frame=CGRect(x:336,y:10,width:73,height:36)
        content.frame=CGRect(x:112,y:56,width:max(0,bounds.width-112),height:max(0,height-56))
        layoutActiveList()
        loadingSkeleton.frame = CGRect(x:112,y:56,width:304,height:max(0,height-56))
        statusLabel.frame = CGRect(x:124,y:height-38,width:281,height:34)
        boostDisabledText.frame = CGRect(x:124,y:99,width:190,height:20)
        boostTurnOn.frame = CGRect(x:327,y:94,width:78,height:30)
        easelsCard.frame = CGRect(x:124,y:56,width:281,height:easelsCardHeight)
        filterEditor.frame = CGRect(x:112,y:0,width:305,height:filterEditor.contentHeight)
        boostList.frame = CGRect(x:120,y:54,width:52,height:28)
        boostGallery.frame = CGRect(x:178,y:54,width:72,height:28)
        boostsProfile.frame = CGRect(x:266,y:54,width:143,height:28)
        manager?.frame = CGRect(x:112,y:0,width:max(0,bounds.width-112),height:height)
        let centerX = section == .spaces ? content.bounds.width/2 : 152.5
        // Content is native unflipped; translate the binding window-relative tops.
        let top = 365+(height-800)/2
        func frame(_ x: CGFloat,_ y: CGFloat,_ w: CGFloat,_ h: CGFloat)->CGRect { CGRect(x:x,y:content.bounds.height-(y-56)-h,width:w,height:h) }
        emptyGlyph.frame=frame(centerX-24,top,48,48)
        emptyTitle.frame=frame(centerX-148,top+64,296,22)
        let lines = ceil(emptyBody.attributedStringValue.boundingRect(with:CGSize(width:236,height:100),options:[.usesLineFragmentOrigin,.usesFontLeading]).height)
        emptyBody.frame=frame(centerX-118,top+92,236,max(56,lines))
        let buttonWidth = (emptyButton.title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:13,weight:.semibold)]).width+24
        emptyButton.frame=frame(centerX-buttonWidth/2,top+92+max(17,lines)+14,buttonWidth,28)
    }
    func layoutActiveList() {
        let top:CGFloat = filterOpen ? filterEditor.contentHeight : section == .boosts ? (boostTurnOn.isHidden ? 92 : 132)
            : section == .easels ? 56 + easelsCardHeight + 8 : 56
        let rect = CGRect(x:112,y:top,width:304,height:max(0,bounds.height-top-(statusLabel.isHidden ? 0 : 42)))
        if listView.frame != rect { listView.frame = rect; listView.layoutSubtreeIfNeeded() }
    }
    public func setSearch(_ text: String) {
        viewModel.query = text
        if section == .archive || section == .history {
            let host = hosts[section]
            host?.provider?.cancel(); host?.provider = nil; host?.providerGeneration += 1
            host?.loaded = false; host?.dirty = true; refreshData()
        }
        if searchField.stringValue != text { searchField.stringValue = text }
        renderRows()
    }
    public func controlTextDidChange(_ notification: Notification) {
        (searchField as? LibrarySearchField)?.note("handlerEntry")
        setSearch(searchField.stringValue)
    }
    public func handleKey(_ event: NSEvent) -> Bool {
        if [48,123,124,125,126].contains(event.keyCode) { keyboardRailNavigation = true; updateRailFocus() }
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
    public func focusRail() { if let tile=tiles[section] { window?.makeFirstResponder(tile) }; updateRailFocus() }
    func updateRailFocus() {
        for (candidate,tile) in tiles { tile.keyboardFocus = keyboardRailNavigation && candidate == section && window?.firstResponder === tile }
    }
    private func updatePointerMonitor() {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor); self.pointerMonitor = nil }
        guard isPresented else { keyboardRailNavigation = false; updateRailFocus(); return }
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.otherMouseDown,.mouseMoved,.scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.window { self.keyboardRailNavigation = false; self.updateRailFocus() }
            }
            return event
        }
    }
    isolated deinit { if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) } }
    /// Reads the existing native tiles without laying out or building content.
    /// Frames use panel coordinates, as in automationState().
    public var automationRailState: [[String:Any]] {
        sections.compactMap { candidate in
            guard let tile=tiles[candidate] else { return nil }
            let frame=convert(tile.bounds,from:tile)
            let point=tile.convert(CGPoint(x:tile.bounds.midX,y:tile.bounds.midY),to:nil)
            let hit=window?.contentView?.superview?.hitTest(point)
            return ["id":candidate.rawValue,"frame":[frame.minX,frame.minY,frame.width,frame.height],
                "selected":candidate == section,"hovered":tile.hovered,"focused":window?.firstResponder === tile,
                "focusRing":tile.keyboardFocus,"drawnLabels":tile.drawnLabelCount,
                "hitClass":hit.map { String(describing:type(of:$0)) } ?? "","canDragWindow":tile.mouseDownCanMoveWindow]
        }
    }

    /// Window-relative top-left coordinates, used by real socket capture clients.
    public func automationState() -> [String:Any] {
        layoutSubtreeIfNeeded()
        func rect(_ view:NSView)->[CGFloat] {
            let frame=convert(view.bounds,from:view)
            return [frame.minX,frame.minY,frame.width,frame.height]
        }
        let ink = foreground.usingColorSpace(.sRGB) ?? foreground
        return ["foreground":[ink.redComponent,ink.greenComponent,ink.blueComponent,ink.alphaComponent],"section":section.rawValue,"panelFrame":[frame.minX,frame.minY,frame.width,frame.height],
            "rail":automationRailState,
            "header":["searchFrame":section == .spaces ? [] : rect(header),"filterFrame":section.hasFilter ? rect(filter) : [],"filterOpen":filterOpen,"chips":filterOpen ? filterEditor.state(in:self) : []] as [String:Any],
            "providers":Dictionary(uniqueKeysWithValues:hosts.map { ($0.key.rawValue,["generation":$0.value.providerGeneration,"loaded":$0.value.loaded,"running":$0.value.provider != nil] as [String:Any]) }),
            "profiles":["history":viewModel.historyProfileID.description,"downloads":viewModel.downloadProfileFilter?.description ?? "all"],
            "dragSession":listView.dragSession,"search":viewModel.query,"filterActive":hasActiveFilters,"rows":listView.state(in:self),"boostsLayout":viewModel.boostsPresentation == .gallery ? "Gallery" : "List", "status":viewModel.statusText, "emptyVisible":!content.isHidden,"emptyState":["title":emptyTitle.stringValue,"body":emptyBody.stringValue,"iconFrame":rect(emptyGlyph),"buttonEnabled":emptyButton.isEnabled,"buttonVisible":!emptyButton.isHidden,"bodyFrame":rect(emptyBody),"buttonFrame":rect(emptyButton),"bodyNeededHeight":ceil(emptyBody.attributedStringValue.boundingRect(with:CGSize(width:emptyBody.frame.width,height:200),options:[.usesLineFragmentOrigin,.usesFontLeading]).height),"buttonToolTip":emptyButton.toolTip ?? "","buttonHelp":emptyButton.accessibilityHelp() ?? ""],
            "easels":easelsState, "notes":noteItems.count,
            "menuOpen":listView.activeMenu != nil,"menuLifecycle":listView.menuLifecycle,"firstResponder":window?.firstResponder.map { String(describing:type(of:$0)) } ?? ""]
    }
    public func hoverTile(_ section: LibraryPanelSection, hovered: Bool) { tiles[section]?.hovered=hovered }
    public func pressBack() { back.performClick(nil) }
    /// The empty state's button ("Choose Folders…" on Media), through its real press handler.
    public func pressEmptyButton() -> Bool {
        guard !emptyButton.isHidden, emptyButton.isEnabled else { return false }
        emptyButton.performClick(nil); return true
    }
}
