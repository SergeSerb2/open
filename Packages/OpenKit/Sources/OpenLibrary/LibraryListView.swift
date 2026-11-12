import AppKit
import OpenDesign

@MainActor
struct LibraryRowAction {
    var title: String
    var glyph: LibraryGlyph? = nil
    var enabled = true
    var run: () -> Void
}

@MainActor
struct LibraryRowItem {
    var id: String
    var title: String
    var subtitle: String
    var kind: String
    var day = ""
    var image: NSImage? = nil
    var loadImage: ((@escaping @MainActor (NSImage?) -> Void) -> Void)? = nil
    var fileURL: URL? = nil
    var progress: Double? = nil
    var dragURL: URL? = nil
    var activate: () -> Void
    var actions: [LibraryRowAction] = []
    var hoverActions: [LibraryRowAction] = []
    /// False: a right-click opens no menu (Arc's Downloads rows); the More button still opens it.
    var contextMenu = true
    var moreTooltip = "More"
}

/// Native, reusable rows. The model owns snapshots and mutations; this view
/// owns only visible cells, selection, native menus and file/URL pasteboards.
@MainActor
final class LibraryListView: NSView, NSMenuDelegate {
    let table = LibraryTableView()
    private let scroll = LibraryScrollView()
    private(set) var sources: [LibraryRowSource] = []
    var rowCount: Int { sources.count }
    private(set) var reloads = 0
    private(set) var updates = 0
    private(set) var formattingMilliseconds = 0.0
    private(set) var layoutMilliseconds = 0.0
    private(set) var configureMaximumMilliseconds = 0.0
    private(set) var configureSamples: [Double] = []
    private var entries: [Entry] = []
    private var lastSelectedRow = -1
    private enum Entry: Equatable { case heading(String), item(Int) }
    var foreground = NSColor.labelColor { didSet { if foreground != oldValue { cancelPrefetch(); for source in sources { source.preparedText = nil }; reloadVisible(); table.scheduleSettle() } } }
    var overlay = NSColor.labelColor { didSet { if overlay != oldValue { reloadVisible() } } }
    var gallery = false { didSet { if gallery != oldValue { rebuild(); reloadVisible() } } }
    var onSelection: ((String?) -> Void)?
    var onEnd: (() -> Void)?
    private(set) var dragSession: [String:Any] = ["began":0,"ended":0]
    private(set) var activeMenu: NSMenu?
    private(set) var menuLifecycle = ["opened":0,"closed":0]
    private var escapeMenuOnOpen = false
    private(set) var hoveredID: String?
    private(set) var cellsCreated = 0
    private var headingsCreated = 0
    var totalCellsCreated: Int { cellsCreated+headingsCreated }
    private(set) var cellsConfigured = 0
    private var prefetch: Task<Void,Never>?
    private var prefetchWorker: Task<[LibraryPreparedText],Never>?
    private var prefetchGeneration = 0
    private var prefetchRange = NSRange(location:0,length:0)
    private var overscanGeneration = 0
    var pendingTasks: Int { (prefetch == nil ? 0 : 1)+(table.pendingIdle ? 1 : 0) }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        table.makeRow = { [weak self] row,detached in self?.makeRow(row,detached:detached) }
        scroll.onWheel = { [weak self] active in
            self?.table.cancelIdle()
            if !active { self?.table.scheduleSettle() }
        }
        table.canSelect = { [weak self] row in self?.item(at:row) != nil }
        table.onSelectionChange = { [weak self] in self?.selectionChanged() }
        table.onClick = { [weak self] row in self?.item(at:row)?.activate() }
        table.writerAtRow = { [weak self] row in self?.item(at:row)?.dragURL.map { $0 as NSURL } }
        table.onDragBegin = { [weak self] session in self?.dragBegan(session) }
        table.onDragEnd = { [weak self] session,operation in self?.dragEnded(session,operation:operation) }
        table.onActivate = { [weak self] in self?.activateSelected() }
        table.onDelete = { [weak self] in self?.deleteSelected() }
        table.onSettle = { [weak self] in await self?.prepareOverscan() }
        table.onScroll = { [weak self] in self?.overscanGeneration += 1 }
        table.onPrefetch = { [weak self] range,direction,stride in self?.prefetchRows(range,direction:direction,stride:stride) }
        table.menuAtRow = { [weak self] row in
            guard let self, self.item(at:row)?.contextMenu != false else { return nil }; let menu = self.menu(at:row); self.activeMenu = menu; return menu
        }
        table.setAccessibilityLabel("Library items")
        scroll.documentView = table; addSubview(scroll)
    }
    func cancelPrefetch() { prefetch?.cancel(); prefetchWorker?.cancel(); prefetch = nil; prefetchWorker = nil; table.cancelIdle(); prefetchGeneration += 1; prefetchRange.length = 0; overscanGeneration += 1 }
    func prepareOverscan() async {
        guard rowCount>0,bounds.height>0 else { return }
        overscanGeneration += 1
        let generation = overscanGeneration
        let range = table.rows(in:table.visibleRect)
        // Reserve enough cells for a full viewport at either edge of a heading.
        // Parking keeps native tracking/hierarchy setup out of scrolling.
        let capacity = Int(ceil(bounds.height/(gallery ? 118 : 56)))*3+6
        while cellsCreated < capacity {
            guard generation == overscanGeneration,!Task.isCancelled else { return }
            var prepared:LibraryItemView?
            guard await LibraryIdleWork.perform(flush:false,{
                guard generation == overscanGeneration else { return }
                prepared = LibraryIdleWork.measure("cell.creation") { LibraryItemView() }
            }),let view = prepared else { return }
            view.identifier = .init("row")
            // Always return a reserved cell to the pool, including cancellation.
            var parked = false
            defer { if !parked { table.park(view); cellsCreated += 1 } }
            guard await LibraryIdleWork.perform(flush:false,{
            guard generation == overscanGeneration else { return }
            if let first = sources.first {
                view.frame = CGRect(x:0,y:0,width:bounds.width,height:gallery ? 118 : 56)
                let item = LibraryIdleWork.measure("row.resolve") { first.resolve() }
                LibraryIdleWork.row(cellsCreated-1,kind:gallery ? "boostGallery" : item.kind,operation:1)
                LibraryIdleWork.measure("cell.configure") { view.configure(item,foreground:foreground,overlay:overlay,gallery:gallery,text:first.preparedText) }
            }
            }) else { return }
            guard await LibraryIdleWork.perform(flush:false,{
                guard generation == overscanGeneration else { return }
                LibraryIdleWork.measure("layout.pass") { view.layoutSubtreeIfNeeded() }
            }) else { return }
            guard await LibraryIdleWork.prepareLayers(of:view,scale:window?.backingScaleFactor ?? 2,
                row:cellsCreated,operation:1,isCurrent:{ generation == self.overscanGeneration }) else { return }
            guard await LibraryIdleWork.perform(flush:false,{
                LibraryIdleWork.measure("cell.park") { table.park(view) }
                cellsCreated += 1;parked = true
            }) else { return }
        }
        let headingCount = entries.reduce(0) { count,entry in if case .heading = entry { return count+1 }; return count }
        while headingsCreated < min(capacity,headingCount) {
            guard generation == overscanGeneration,!Task.isCancelled else { return }
            let completed = await LibraryIdleWork.perform(flush:false) {
            guard generation == overscanGeneration else { return }
            LibraryIdleWork.row(headingsCreated,kind:"heading",operation:2)
            let view = LibraryIdleWork.measure("cell.creation") { LibraryHeadingView() }; view.identifier = .init("day"); headingsCreated += 1
            LibraryIdleWork.measure("cell.park") { table.park(view) }
            }
            guard completed else { return }
        }
        await table.prepareOverscan { generation == self.overscanGeneration }
        guard generation == overscanGeneration,!Task.isCancelled else { return }
        prefetchRows(range,direction:1)
    }
    func prefetchRows(_ range:NSRange,direction:Int,stride:Int = 0) {
        guard range.length>0 else { return }
        let low = max(0,direction>0 ? range.location : range.location-2*range.length)
        let high = min(entries.count,direction>0 ? range.location+3*range.length : range.location+range.length)
        let nextRange = NSRange(location:low,length:high-low)
        guard nextRange != prefetchRange else { return }
        prefetchRange = nextRange
        prefetch?.cancel(); prefetchWorker?.cancel(); prefetchGeneration += 1
        let generation = prefetchGeneration
        // Fast wheel/trackpad input can cross more than a screen per callback.
        // Prefetch that next viewport as well as the adjacent two screens.
        let predicted = max(0,min(entries.count,range.location+stride))
        let predictedEnd = min(entries.count,predicted+range.length)
        let indexes = Set(low..<high).union(predicted..<predictedEnd).sorted()
        let sources = indexes.compactMap { row -> LibraryRowSource? in
            let entry = entries[row]
            if case .item(let index) = entry { return self.sources[index] }; return nil
        }.filter { $0.preparedText == nil }
        guard !sources.isEmpty else { prefetch = nil; prefetchWorker = nil; return }
        let builders = sources.map { source -> @Sendable () -> LibraryRowText in
            if let prepare = source.prepareText { return prepare }
            let item = source.resolve(), text = LibraryRowText(title:item.title,subtitle:item.subtitle)
            return { text }
        }
        let color = foreground.usingColorSpace(.deviceRGB) ?? .black
        let rgba = [color.redComponent,color.greenComponent,color.blueComponent,color.alphaComponent]
        let titleFont = NSFont.systemFont(ofSize:15,weight:.medium).fontName
        let subtitleFont = NSFont.systemFont(ofSize:13).fontName
        let worker = Task.detached(priority:.utility) { builders.compactMap { builder in Task.isCancelled ? nil : LibraryPreparedText(builder(),color:rgba,titleFont:titleFont,subtitleFont:subtitleFont) } }
        prefetchWorker = worker
        prefetch = Task { @MainActor [weak self] in
            let text = await worker.value
            guard let self,!Task.isCancelled,self.prefetchGeneration == generation,text.count == sources.count else { return }
            for (source,text) in zip(sources,text) {
                source.preparedText = text
                let item = source.resolve()
                if let url = item.fileURL { _ = FilePreviewCache.shared.image(for:url,onReady:{}) }
                _ = LibraryImages.value(item.image)
                item.loadImage? { image in _ = LibraryImages.value(image) }
            }
            self.prefetch = nil; self.prefetchWorker = nil
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    /// First-use font, date and symbol costs belong to the idle prebuild.
    /// These temporary rows never enter a window, take focus or start work.
    static func warmRowKinds(foreground:NSColor,overlay:NSColor) async -> Bool {
        let now = Date()
        _ = now.formatted(date:.omitted,time:.shortened)
        _ = now.formatted(date:.abbreviated,time:.omitted)
        _ = now.formatted(.dateTime.month(.wide).year())
        let bytes = ByteCountFormatter(); bytes.countStyle = .file; bytes.allowsNonnumericFormatting = false
        _ = bytes.string(fromByteCount:1_024_000)
        let placeholder = NSImage(systemSymbolName:"globe",accessibilityDescription:nil)
        let actions = [LibraryRowAction(title:"Delete",glyph:.trash,run:{}),LibraryRowAction(title:"Restore",glyph:.undo,run:{})]
        func display(_ view:NSView) {
            view.displayIfNeeded(); view.layer?.displayIfNeeded()
            for child in view.subviews { display(child) }
            func displayLayers(_ layer:CALayer) { for child in layer.sublayers ?? [] { child.displayIfNeeded(); displayLayers(child) } }
            if let layer = view.layer { displayLayers(layer) }
        }
        // Only first-use warming is split. Visible rows, overscan and the
        // foreground open/search paths keep their existing submission order.
        for (index,kind) in ["download","archive","history","capture","boost","boostGallery"].enumerated() {
            var prepared:LibraryItemView?
            guard await LibraryIdleWork.perform(rowKind:index+1,phase:1,firstUse:true,flush:false,{
                prepared = LibraryItemView(frame:CGRect(x:0,y:0,width:304,height:56))
            }),let row = prepared else { return false }
            guard await LibraryIdleWork.perform(rowKind:index+1,phase:2,flush:false,{
                row.configure(LibraryRowItem(id:"warm-"+kind,title:"Library row",subtitle:"Page · Today",kind:kind,image:placeholder,activate:{},actions:actions,hoverActions:actions),foreground:foreground,overlay:overlay,gallery:kind == "boostGallery")
                row.layoutSubtreeIfNeeded()
            }) else { return false }
            guard await LibraryIdleWork.perform(rowKind:index+1,phase:3,{
                display(row)
            }) else { return false }
        }
        var preparedHeading:LibraryHeadingView?
        guard await LibraryIdleWork.perform(rowKind:7,phase:1,firstUse:true,flush:false,{
            preparedHeading = LibraryHeadingView(frame:CGRect(x:0,y:0,width:304,height:27))
        }),let heading = preparedHeading else { return false }
        guard await LibraryIdleWork.perform(rowKind:7,phase:2,flush:false,{
            heading.configure("Today",color:foreground.withAlphaComponent(0.68))
            heading.layoutSubtreeIfNeeded()
        }) else { return false }
        guard await LibraryIdleWork.perform(rowKind:7,phase:3,{
            display(heading)
        }) else { return false }
        return true
    }
    override func layout() {
        let started = ProcessInfo.processInfo.systemUptime
        defer { layoutMilliseconds += (ProcessInfo.processInfo.systemUptime-started)*1000 }
        super.layout(); scroll.frame = bounds
        if table.frame.width != scroll.contentSize.width { table.setFrameSize(CGSize(width:scroll.contentSize.width,height:table.frame.height)) }; table.reconcile()
    }
    func reloadVisible() {
        let range = table.rows(in:table.visibleRect)
        guard range.length > 0 else { return }
        reloads += 1
        table.reloadData(forRowIndexes:IndexSet(integersIn:range.location..<(range.location+range.length)),columnIndexes:IndexSet(integer:0))
    }
    func update(_ sources: [LibraryRowSource]) {
        let old = self.sources, selected = selectedItem?.id
        if old.count == sources.count && zip(old,sources).allSatisfy({ $0 === $1 }) { return }
        cancelPrefetch()
        self.sources = sources; rebuild(previousSources:old)
        table.scheduleSettle()
        updates += 1
        if let selected, let row = entryIndex(selected) { table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) }
    }
    private func rebuild(previousSources: [LibraryRowSource]? = nil) {
        entries = []; var lastDay = ""
        for (index,source) in sources.enumerated() {
            if !source.day.isEmpty, source.day != lastDay { entries.append(.heading(source.day)); lastDay = source.day }
            entries.append(.item(index))
        }
        table.setRows(entries.map { entry in
            switch entry {
            case .heading(let day): return LibraryTableRow(key:"day:"+day,height:27,version:nil)
            case .item(let index): return LibraryTableRow(key:"item:"+sources[index].id,height:gallery ? 118 : 56,version:ObjectIdentifier(sources[index]))
            }
        })
    }
    func selectionChanged() {
        for row in Set([lastSelectedRow,table.selectedRow]) where entries.indices.contains(row) && row < table.numberOfRows {
            (table.view(atColumn:0,row:row,makeIfNecessary:false) as? LibraryItemView)?.selected = row == table.selectedRow
        }
        lastSelectedRow = table.selectedRow
        onSelection?(selectedItem?.id)
    }
    func makeRow(_ row:Int,detached:Bool = false) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        switch entries[row] {
        case .heading(let text):
            let wrapper: LibraryHeadingView
            if let view = table.makeView(withIdentifier:.init("day"),owner:self) as? LibraryHeadingView { wrapper = view }
            else { wrapper = LibraryHeadingView(); headingsCreated += 1 }
            if detached { wrapper.removeFromSuperview() }
            wrapper.identifier = .init("day"); wrapper.configure(text,color:foreground.withAlphaComponent(0.68))
            return wrapper
        case .item(let index):
            let view: LibraryItemView
            if let reusable = table.makeView(withIdentifier: .init("row"), owner: self) as? LibraryItemView { view = reusable }
            else { view = LibraryIdleWork.measure("cell.creation") { LibraryItemView() }; cellsCreated += 1 }
            if detached { view.removeFromSuperview() }
            view.identifier = .init("row")
            cellsConfigured += 1
            view.onHover = nil
            let started = ProcessInfo.processInfo.systemUptime
            let item = LibraryIdleWork.measure("row.resolve") { sources[index].resolve() }
            LibraryIdleWork.row(row,kind:gallery ? "boostGallery" : item.kind,operation:3)
            LibraryIdleWork.measure("cell.configure") { view.configure(item, foreground: foreground, overlay: overlay, gallery: gallery, text:sources[index].preparedText) }
            let elapsed = (ProcessInfo.processInfo.systemUptime-started)*1000
            formattingMilliseconds += elapsed; configureMaximumMilliseconds = max(configureMaximumMilliseconds,elapsed)
            if configureSamples.count < 4096 { configureSamples.append(elapsed) }
            view.selected = row == table.selectedRow
            view.hovered = sources[index].id == hoveredID
            view.onHover = { [weak self, weak view] hovered in
                guard let self, let view else { return }
                if hovered { self.hoveredID = view.item?.id } else if self.hoveredID == view.item?.id { self.hoveredID = nil }
            }
            view.onMenu = { [weak self, weak view] in
                guard let self, let view, let id = view.item?.id, let row = self.entryIndex(id), let menu = self.menu(at: row) else { return }
                self.activeMenu = menu; menu.popUp(positioning: nil, at: CGPoint(x: view.bounds.maxX-42,y: 40), in: view)
            }
            if index >= sources.count-8 { onEnd?() }
            return view
        }
    }
    func writer(at row:Int) -> NSPasteboardWriting? {
        item(at: row)?.dragURL.map { $0 as NSURL }
    }
    func dragBegan(_ session:NSDraggingSession) {
        dragSession = ["began":(dragSession["began"] as? Int ?? 0)+1,"ended":dragSession["ended"] as? Int ?? 0,
            "types":session.draggingPasteboard.types?.map(\.rawValue) ?? [],
            "url":session.draggingPasteboard.string(forType:.fileURL) ?? session.draggingPasteboard.string(forType:.URL) ?? ""]
        session.animatesToStartingPositionsOnCancelOrFail = false
    }
    func dragEnded(_ session:NSDraggingSession,operation:NSDragOperation) {
        dragSession["ended"] = (dragSession["ended"] as? Int ?? 0)+1; dragSession["operation"] = operation.rawValue
    }
    private func item(at row: Int) -> LibraryRowItem? {
        guard entries.indices.contains(row), case .item(let index) = entries[row] else { return nil }; return sources[index].resolve()
    }
    var selectedItem: LibraryRowItem? { item(at: table.selectedRow) }
    func entryIndex(_ id: String) -> Int? { entries.indices.first { row in if case .item(let index) = entries[row] { return sources[index].id == id }; return false } }
    func activateSelected() { selectedItem?.activate() }
    func deleteSelected() { guard let selectedItem else { return }; (selectedItem.hoverActions+selectedItem.actions).first(where: { ["Delete","Move to Trash","Hide from Open"].contains($0.title) && $0.enabled })?.run() }
    func focus() {
        window?.makeFirstResponder(table)
        if table.selectedRow < 0, let row = entries.indices.first(where: { item(at: $0) != nil }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }
    func menu(at row: Int) -> NSMenu? {
        guard let item = item(at: row), !item.actions.isEmpty else { return nil }
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
        for action in item.actions {
            if action.title == "-" { menu.addItem(.separator()) }
            else { menu.addItem(LibraryMenuItem(action)) }
        }
        return menu
    }
    func showMenu(id:String,escapeOnOpen:Bool = false) -> Bool {
        guard let row = entryIndex(id), let menu = menu(at:row), let cell = table.view(atColumn:0,row:row,makeIfNecessary:true) else { return false }
        activeMenu = menu
        escapeMenuOnOpen = escapeOnOpen
        DispatchQueue.main.async { [weak self,weak cell] in
            guard let self, let cell, self.activeMenu === menu else { return }
            menu.popUp(positioning:nil,at:CGPoint(x:cell.bounds.maxX-42,y:40),in:cell)
        }
        return true
    }
    func menuWillOpen(_ menu:NSMenu) {
        menuLifecycle["opened",default:0] += 1
        guard escapeMenuOnOpen, let window else { return }; escapeMenuOnOpen = false
        for type in [NSEvent.EventType.keyDown,.keyUp] {
            if let event = NSEvent.keyEvent(with:type,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:window.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53) {
                NSApp.postEvent(event,atStart:false)
            }
        }
    }
    func menuDidClose(_ menu: NSMenu) { menuLifecycle["closed",default:0] += 1; if activeMenu === menu { activeMenu = nil } }
    func dismissMenu() -> Bool {
        guard let activeMenu else { return false }; activeMenu.cancelTracking(); self.activeMenu = nil; return true
    }
    func hover(id: String, value: Bool) -> Bool {
        guard let index = entryIndex(id), let row = table.view(atColumn: 0, row: index, makeIfNecessary: true) as? LibraryItemView else { return false }
        hoveredID = value ? id : nil; row.hovered = value; return true
    }
    func perform(id: String, action: String) -> Bool {
        guard let source = sources.first(where: { $0.id == id }) else { return false }; let item = source.resolve()
        if action == "open" { item.activate(); return true }
        guard let entry = (item.actions+item.hoverActions).first(where: { $0.title == action && $0.enabled }) else { return false }
        LibraryMenuItem(entry).invoke(); return true
    }
    func menuState(id: String, select: String?) -> [[String:Any]]? {
        guard let row = entryIndex(id), let menu = menu(at: row) else { return nil }
        if let select, let index = menu.items.firstIndex(where: { $0.title == select && $0.isEnabled }) { menu.performActionForItem(at: index) }
        return menu.items.map { ["title":$0.isSeparatorItem ? "separator" : $0.title,"enabled":$0.isEnabled] }
    }
    func dragState(id: String) -> [String:Any]? {
        guard let row = entryIndex(id), let writer = writer(at:row) else { return nil }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.writeObjects([writer])
        return ["types":board.types?.map(\.rawValue) ?? [],"url":board.string(forType: .fileURL) ?? board.string(forType: .URL) ?? ""]
    }
    func state(in root: NSView) -> [[String:Any]] {
        entries.indices.compactMap { row in
            guard let item = item(at: row) else { return nil }
            let frame = root.convert(table.rect(ofRow: row),from: table)
            return ["id":item.id,"frame":[frame.minX,frame.minY,frame.width,frame.height],"title":item.title,"subtitle":item.subtitle,
              "kind":item.kind,"hovered":hoveredID == item.id,"selected":table.selectedRow == row,"actions":item.hoverActions.map(\.title),"contextMenu":item.contextMenu]
        }
    }
}

@MainActor
private final class LibraryHeadingView: NSView {
    private let text = LibraryText.layer()
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override init(frame:NSRect) { super.init(frame:frame); wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay; layer?.addSublayer(text) }
    required init?(coder:NSCoder) { fatalError() }
    func configure(_ title:String,color:NSColor) { text.string = LibraryText.value(title,size:13,weight:.semibold,color:color) }
    override func layout() { super.layout(); text.frame = CGRect(x:12,y:6,width:bounds.width-24,height:18); text.contentsScale = window?.backingScaleFactor ?? 2 }
}

@MainActor
private final class LibraryItemView: NSView {
    var item: LibraryRowItem?
    var onHover: ((Bool) -> Void)?
    var onMenu: (() -> Void)?
    var selected = false { didSet { if selected != oldValue { setAccessibilitySelected(selected); needsDisplay = true } } }
    var hovered = false { didSet { guard hovered != oldValue else { return }; buttons.forEach { $0.isHidden = !hovered && !gallery }; needsLayout = true; needsDisplay = true; onHover?(hovered) } }
    private let icon = CALayer(), title = LibraryText.layer(), subtitle = LibraryText.layer()
    private let plate = CALayer(), ring = CAShapeLayer(), progressLayer = CAShapeLayer(), arrow = CAShapeLayer()
    override var wantsUpdateLayer: Bool { true }
    private var buttons: [LibraryControl] = []
    private var foreground = NSColor.labelColor, overlay = NSColor.labelColor
    private var tracking: NSTrackingArea?
    private var gallery = false
    override var isFlipped: Bool { true }
    override init(frame:NSRect) {
        super.init(frame:frame); wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for child in [plate,icon,title,subtitle,ring,progressLayer,arrow] { layer?.addSublayer(child) }
        plate.cornerRadius = 11; plate.cornerCurve = .continuous
        icon.contentsGravity = .resizeAspect
        for shape in [ring,progressLayer,arrow] { shape.fillColor = nil; shape.lineCap = .round; shape.lineJoin = .round }
        ring.lineWidth = 2; progressLayer.lineWidth = 2; arrow.lineWidth = 1.7
    }
    required init?(coder:NSCoder) { fatalError() }
    func configure(_ item:LibraryRowItem,foreground:NSColor,overlay:NSColor,gallery:Bool,text:LibraryPreparedText? = nil) {
        self.item = item; self.foreground = foreground; self.overlay = overlay; self.gallery = gallery
        LibraryIdleWork.measure("text.layout") {
            title.string = text?.title ?? LibraryText.value(item.title,size:15,weight:.medium,color:foreground)
            subtitle.string = text?.subtitle ?? LibraryText.value(item.subtitle,size:13,weight:.regular,color:foreground.withAlphaComponent(0.68))
        }
        setIcon(item.image)
        LibraryIdleWork.measure("favicon.request") { item.loadImage? { [weak self] image in
            guard let self, self.item?.id == item.id, let image else { return }
            LibraryIdleWork.measure("favicon.decode") { self.setIcon(image) }
        } }
        if let url = item.fileURL {
            LibraryIdleWork.measure("filePreview.request") { setIcon(FilePreviewCache.shared.image(for:url) { [weak self] in
                guard let self, self.item?.fileURL == url else { return }
                self.setIcon(FilePreviewCache.shared.image(for:url,onReady:{}))
            }) }
        }
        var actions = item.hoverActions
        if !item.actions.isEmpty { actions.append(.init(title:item.moreTooltip,glyph:.dots,run:{ [weak self] in self?.onMenu?() })) }
        // The table's reuse identifier stays "row". Item identity belongs to AX,
        // not the viewport reuse pool.
        setAccessibilityIdentifier(item.kind == "boost" ? "boosts.\(item.id).card" : "library.\(item.id)")
        let buttonCount = gallery ? 3 : actions.count
        while buttons.count > buttonCount { buttons.removeLast().removeFromSuperview() }
        while buttons.count < buttonCount { let button = LibraryControl(title:""); buttons.append(button); addSubview(button) }
        for (button,action) in zip(buttons,actions) where !gallery {
            button.title = ""; button.glyph = action.glyph; button.isChip = false; button.selected = false
            button.identifier = nil; button.baseAlpha = 0; button.layer?.cornerRadius = 10
            button.glyphSize = 16; button.foreground = foreground; button.overlay = overlay; button.onPress = action.run
            button.toolTip = action.title; button.setAccessibilityLabel(action.title); button.setAccessibilityRole(.button); button.isEnabled = action.enabled; button.needsDisplay = true
        }
        if gallery {
            for (index,choice) in [("edit","Edit Boost","Edit…"),("enabled",item.subtitle.hasSuffix(" · on") ? "Turn Off" : "Turn On",item.subtitle.hasSuffix(" · on") ? "On" : "Off")].enumerated() {
                let (suffix,name,label) = choice, button = buttons[index]
                let action = item.actions.first(where: { $0.title == name })
                button.title = label; button.glyph = nil; button.labelSize = 12; button.toolTip = nil
                button.foreground = foreground; button.overlay = overlay; button.baseAlpha = 0.045
                button.isChip = true; button.layer?.cornerRadius = 9
                button.identifier = .init("boosts.\(item.id).\(suffix)"); button.setAccessibilityLabel(name)
                button.isEnabled = action?.enabled == true; button.onPress = action?.run
                button.setAccessibilityRole(suffix == "enabled" ? .checkBox : .button)
                button.selected = suffix == "enabled" && item.subtitle.hasSuffix(" · on")
            }
            let more = buttons[2]; more.title = ""; more.glyph = .dots; more.isChip = false; more.selected = false
            more.baseAlpha = 0; more.isEnabled = true; more.toolTip = nil; more.foreground = foreground; more.overlay = overlay
            more.setAccessibilityLabel("More options"); more.identifier = .init("boosts.\(item.id).more")
            more.setAccessibilityRole(.button); more.onPress = { [weak self] in self?.onMenu?() }
        }
        setAccessibilityElement(!gallery); setAccessibilityRole(gallery ? .group : .row); setAccessibilityLabel(item.title+". "+item.subtitle)
        setAccessibilityCustomActions(item.hoverActions.map { action in NSAccessibilityCustomAction(name:action.title) { action.run(); return true } })
        hovered = false; buttons.forEach { $0.isHidden = !gallery }; needsLayout = true; needsDisplay = true
    }
    override func updateTrackingAreas() {
        let start = ProcessInfo.processInfo.systemUptime
        defer { LibraryRaster.events["trackingMilliseconds",default:0] += (ProcessInfo.processInfo.systemUptime-start)*1000 }
        LibraryRaster.note("trackingUpdates")
        super.updateTrackingAreas(); guard tracking == nil else { return }
        let area = NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event:NSEvent) { LibraryRaster.note("trackingEnter"); hovered = true }
    override func mouseExited(with event:NSEvent) { LibraryRaster.note("trackingExit"); hovered = false }
    override func layout() {
        super.layout()
        let leading:CGFloat = item?.progress == nil ? 52 : 60
        let top:CGFloat = gallery ? 38 : 11
        let tabIcon = ["archive","history","boost"].contains(item?.kind ?? "")
        icon.frame = CGRect(x:tabIcon ? 20 : 18,y:top+(tabIcon ? 7 : 5),width:tabIcon ? 20 : 24,height:tabIcon ? 20 : 24)
        let trailing:CGFloat = !gallery && hovered ? CGFloat(buttons.count)*34+8 : 20
        title.contentsScale = window?.backingScaleFactor ?? 2; subtitle.contentsScale = title.contentsScale
        title.frame = CGRect(x:leading,y:top,width:max(0,bounds.width-leading-trailing),height:19)
        subtitle.frame = CGRect(x:leading,y:top+20,width:title.frame.width,height:17)
        plate.frame = CGRect(x:8,y:gallery ? 4 : 0,width:max(0,bounds.width-15),height:bounds.height-(gallery ? 8 : 0))
        if gallery {
            for button in buttons {
                let id = button.identifier?.rawValue ?? ""
                if id.hasSuffix(".enabled") { button.frame = CGRect(x:bounds.width-62,y:10,width:46,height:28) }
                else if id.hasSuffix(".edit") { button.frame = CGRect(x:16,y:82,width:68,height:28) }
                else { button.frame = CGRect(x:bounds.width-44,y:82,width:28,height:28) }
            }
        } else {
            for (index,button) in buttons.enumerated() { button.frame = CGRect(x:bounds.width-10-CGFloat(buttons.count-index)*34,y:top+2,width:30,height:30) }
        }
    }
    private func setIcon(_ image:NSImage?) {
        icon.contents = LibraryImages.value(image)
    }
    override func updateLayer() {
        plate.backgroundColor = overlay.withAlphaComponent(hovered || selected ? 0.105 : gallery ? 0.045 : 0).cgColor
        let progress = item?.progress
        icon.isHidden = progress != nil
        for shape in [ring,progressLayer,arrow] { shape.isHidden = progress == nil }
        if let progress {
            ring.path = CGPath(ellipseIn:CGRect(x:20,y:18,width:20,height:20),transform:nil)
            ring.strokeColor = foreground.withAlphaComponent(0.25).cgColor
            let arc = CGMutablePath(); arc.addArc(center:CGPoint(x:30,y:28),radius:10,startAngle:-.pi/2,endAngle:-.pi/2+CGFloat(progress)*2*CGFloat.pi,clockwise:false)
            progressLayer.path = arc; progressLayer.strokeColor = foreground.cgColor
            let path = CGMutablePath(); path.move(to:CGPoint(x:30,y:23)); path.addLine(to:CGPoint(x:30,y:33)); path.move(to:CGPoint(x:26,y:29)); path.addLine(to:CGPoint(x:30,y:33)); path.addLine(to:CGPoint(x:34,y:29))
            arrow.path = path; arrow.strokeColor = foreground.cgColor
        }
    }
}

@MainActor
final class LibraryMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ entry: LibraryRowAction) { handler = entry.run; super.init(title:entry.title,action:#selector(invoke),keyEquivalent:""); target = self; isEnabled = entry.enabled }
    required init(coder:NSCoder) { fatalError() }
    @objc func invoke() { if isEnabled { handler() } }
}
