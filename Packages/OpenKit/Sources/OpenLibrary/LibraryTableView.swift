import AppKit

/// Track native contact and momentum even when the offset no longer changes.
/// The document's clip observer alone cannot identify an active gesture tail.
@MainActor
final class LibraryScrollView: NSScrollView {
    var onWheel: ((Bool) -> Void)?
    private var contact = false
    private var momentum = false
    override func scrollWheel(with event:NSEvent) {
        LibraryIdleWork.noteInput()
        func update(_ phase:NSEvent.Phase,_ active:inout Bool) {
            if !phase.intersection([.mayBegin,.began,.changed,.stationary]).isEmpty { active = true }
            if !phase.intersection([.ended,.cancelled]).isEmpty { active = false }
        }
        update(event.phase,&contact); update(event.momentumPhase,&momentum)
        let active = contact || momentum
        LibraryIdleWork.setScrolling(ObjectIdentifier(self),active:active)
        onWheel?(active)
        super.scrollWheel(with:event)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { contact = false; momentum = false; LibraryIdleWork.setScrolling(ObjectIdentifier(self),active:false) }
    }
    isolated deinit { LibraryIdleWork.setScrolling(ObjectIdentifier(self),active:false) }
}

struct LibraryTableRow {
    let key: String
    let height: CGFloat
    let version: ObjectIdentifier?
}

/// A frame-based, virtualized native list. Geometry is computed once per page:
/// 56pt items, 27pt headings, or 118pt gallery cards. No constraints or height
/// delegate run while scrolling. A bounded viewport/overscan pool stays attached to the hierarchy.
@MainActor
final class LibraryTableView: NSView, NSDraggingSource {
    var onActivate: (() -> Void)?
    var onDelete: (() -> Void)?
    var onClick: ((Int) -> Void)?
    var onSelectionChange: (() -> Void)?
    var menuAtRow: ((Int) -> NSMenu?)?
    var writerAtRow: ((Int) -> NSPasteboardWriting?)?
    var canSelect: ((Int) -> Bool)?
    var makeRow: ((Int,Bool) -> NSView?)?
    var onDragBegin: ((NSDraggingSession) -> Void)?
    var onDragEnd: ((NSDraggingSession,NSDragOperation) -> Void)?
    var onScroll: (() -> Void)?
    var onSettle: (() async -> Void)?
    var onPrefetch: ((NSRange,Int,Int) -> Void)?
    private var previousFirstRow = 0
    private var settleTask: Task<Void,Never>?
    private var settleGeneration = 0
    private var overscanViewport: CGRect?
    var pendingIdle: Bool { settleTask != nil }
    private var previousY: CGFloat = 0
    private(set) var phases: [String:Double] = [:]
    private func record(_ name:String,_ start:Double) { phases[name,default:0] += (ProcessInfo.processInfo.systemUptime-start)*1000 }
    private var rows: [LibraryTableRow] = []
    private var offsets: [CGFloat] = [0]
    private var live: [String:(row:Int,version:ObjectIdentifier?,view:NSView)] = [:]
    private var pool: [NSUserInterfaceItemIdentifier:[NSView]] = [:]
    private var observer: NSObjectProtocol?
    private var reconciling = false
    private var dragStart = CGPoint.zero
    private var didDrag = false
    private(set) var selectedRow = -1
    private(set) var clickedRow = -1
    var numberOfRows: Int { rows.count }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override init(frame:NSRect) {
        super.init(frame:frame); wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        autoresizesSubviews = false
        setAccessibilityRole(.table)
    }
    required init?(coder:NSCoder) { fatalError() }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:clip,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let started = ProcessInfo.processInfo.systemUptime
                    LibraryRaster.note("clipBoundsObserver")
                    LibraryIdleWork.noteInput()
                    self.onScroll?(); self.reconcile()
                    let y = self.enclosingScrollView?.contentView.bounds.minY ?? 0
                    let range = self.rows(in:self.visibleRect)
                    self.onPrefetch?(range,y >= self.previousY ? 1 : -1,range.location-self.previousFirstRow)
                    self.previousFirstRow = range.location
                    self.previousY = y
                    self.scheduleSettle()
                    self.record("clipBounds",started)
                }
            }
        }
    }
    func setRows(_ rows:[LibraryTableRow]) {
        let selected = self.rows.indices.contains(selectedRow) ? self.rows[selectedRow].key : nil
        self.rows = rows
        offsets = [0]; offsets.reserveCapacity(rows.count+1)
        for row in rows { offsets.append(offsets.last!+row.height) }
        selectedRow = selected.flatMap { key in rows.firstIndex { $0.key == key } } ?? -1
        let height = max(1,offsets.last ?? 0)
        if frame.height != height { setFrameSize(CGSize(width:frame.width,height:height)) }
        reconcile()
    }
    override func layout() { super.layout(); reconcile() }
    func makeView(withIdentifier identifier:NSUserInterfaceItemIdentifier,owner:Any?) -> NSView? {
        let start = ProcessInfo.processInfo.systemUptime
        defer { record("dequeue",start) }
        return pool[identifier]?.popLast()
    }
    func park(_ view:NSView) {
        view.isHidden = true
        if view.superview !== self { addSubview(view) }
        if let identifier = view.identifier { pool[identifier,default:[]].append(view) }
    }
    func scheduleSettle() {
        cancelIdle()
        guard !LibraryIdleWork.scrollIsActive else { return }
        let generation = settleGeneration
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for:.milliseconds(80))
            guard let self,!Task.isCancelled else { return }
            await self.onSettle?()
            if generation == self.settleGeneration { self.settleTask = nil }
        }
    }
    func cancelIdle() { settleTask?.cancel(); settleTask = nil; settleGeneration += 1 }
    func prepareOverscan(isCurrent: () -> Bool) async {
        let viewport = enclosingScrollView?.contentView.bounds ?? bounds
        let range = rows(in:viewport.insetBy(dx:0,dy:-viewport.height))
        overscanViewport = viewport
        for row in range.location..<(range.location+range.length) {
            // setRows can run during the awaits below (a gallery switch does not cancel this pass).
            guard !Task.isCancelled,isCurrent(),rows.indices.contains(row) else { return }
            let descriptor = rows[row]
            // Visible rows already belong to the normal display path. Only
            // prepare missing overscan cells here, away from the layer tree.
            if let entry = live[descriptor.key],entry.version == descriptor.version { continue }
            var prepared:NSView?
            guard await LibraryIdleWork.perform(flush:false,{
                guard isCurrent(),rows.indices.contains(row),
                    viewport == (enclosingScrollView?.contentView.bounds ?? bounds) else { return }
                LibraryIdleWork.realizedRow(row)
                if live[descriptor.key] != nil { retire(descriptor.key) }
                guard LibraryIdleWork.canBegin(estimatedMilliseconds:0.75) else { return }
                prepared = makeRow?(row,true)
                prepared?.frame = rect(ofRow:row)
            }),let view = prepared else { return }
            var installed = false
            defer { if !installed { park(view) } }
            guard await LibraryIdleWork.perform(flush:false,{
                guard isCurrent(),LibraryIdleWork.canBegin(estimatedMilliseconds:0.75) else { return }
                LibraryIdleWork.realizedRow(row)
                LibraryIdleWork.measure("layout.pass") { view.layoutSubtreeIfNeeded() }
            }) else { return }
            guard await LibraryIdleWork.prepareLayers(of:view,scale:window?.backingScaleFactor ?? 2,row:row,operation:3,isCurrent:isCurrent) else { return }
            guard await LibraryIdleWork.perform(flush:false,{
                guard isCurrent(),rows.indices.contains(row),
                    rows[row].key == descriptor.key,rows[row].version == descriptor.version,
                    viewport == (enclosingScrollView?.contentView.bounds ?? bounds) else { return }
                addSubview(view);view.isHidden = false
                live[descriptor.key] = (row,descriptor.version,view);installed = true
            }),installed else { return }
        }
    }
    func view(atColumn:Int,row:Int,makeIfNecessary:Bool) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        if let view = live[rows[row].key]?.view { return view }
        guard makeIfNecessary else { return nil }
        scrollRowToVisible(row); reconcile(); return live[rows[row].key]?.view
    }
    func reloadData(forRowIndexes indexes:IndexSet,columnIndexes:IndexSet) {
        for key in Array(live.keys) where indexes.contains(live[key]!.row) { retire(key) }
        reconcile()
    }
    private func retire(_ key:String) {
        guard let entry = live.removeValue(forKey:key) else { return }
        park(entry.view)
    }
    func reconcile(overscan:Bool = false) {
        guard !reconciling else { return }; reconciling = true
        let started = ProcessInfo.processInfo.systemUptime
        defer { reconciling = false; record("reconcile",started) }
        let viewport = enclosingScrollView?.contentView.bounds ?? bounds
        let range = self.rows(in:overscan ? viewport.insetBy(dx:0,dy:-viewport.height) : viewport)
        let visible = range.length == 0 ? [] : Array(range.location..<(range.location+range.length))
        // Keep completed overscan rows, but never populate the unfinished part
        // from an implicit layout pass between idle slices.
        let retained = self.rows(in:overscanViewport == viewport ? viewport.insetBy(dx:0,dy:-viewport.height) : viewport)
        let keys = Set((retained.location..<(retained.location+retained.length)).map { rows[$0].key })
        for key in Array(live.keys) where !keys.contains(key) { retire(key) }
        for row in visible { realize(row,display:overscan) }
    }
    private func realize(_ row:Int,display:Bool) {
            let descriptor = rows[row]
            if let entry = live[descriptor.key],entry.version != descriptor.version { retire(descriptor.key) }
            let view: NSView
            if let existing = live[descriptor.key]?.view { view = existing }
            else {
                let start = ProcessInfo.processInfo.systemUptime
                guard let made = makeRow?(row,false) else { return }
                record("configure",start)
                view = made; if view.superview !== self { addSubview(view) }; view.isHidden = false
            }
            let rect = rect(ofRow:row)
            if view.frame != rect { view.frame = rect }
            if view.needsLayout {
                let start = ProcessInfo.processInfo.systemUptime
                LibraryIdleWork.measure("layout.pass") { view.layoutSubtreeIfNeeded() }; record("cellLayout",start)
            }
            if display {
                let start = ProcessInfo.processInfo.systemUptime
                LibraryIdleWork.measure("display") { view.displayIfNeeded() }
                func display(_ layer:CALayer) { layer.displayIfNeeded(); for child in layer.sublayers ?? [] { display(child) } }
                if let layer = view.layer { LibraryIdleWork.measure("layer.display") { display(layer) } }
                record("overscanDisplay",start)
            }
            live[descriptor.key] = (row,descriptor.version,view)
    }
    func rect(ofRow row:Int) -> CGRect {
        guard rows.indices.contains(row) else { return .zero }
        return CGRect(x:0,y:offsets[row],width:bounds.width,height:rows[row].height)
    }
    private func lowerBound(_ y:CGFloat) -> Int {
        var low = 0, high = rows.count
        while low < high { let mid = (low+high)/2; if offsets[mid+1] <= y { low = mid+1 } else { high = mid } }
        return low
    }
    func row(at point:CGPoint) -> Int {
        let index = lowerBound(point.y)
        return point.y >= 0 && rows.indices.contains(index) && bounds.contains(point) ? index : -1
    }
    func rows(in rect:CGRect) -> NSRange {
        let first = lowerBound(rect.minY),end = min(rows.count,lowerBound(max(rect.minY,rect.maxY-0.001))+1)
        return NSRange(location:first,length:max(0,end-first))
    }
    func scrollRowToVisible(_ row:Int) {
        guard rows.indices.contains(row),let scroll = enclosingScrollView else { return }
        let start = ProcessInfo.processInfo.systemUptime
        let rect = rect(ofRow:row),viewport = scroll.contentView.bounds
        let y = rect.minY < viewport.minY ? rect.minY : rect.maxY > viewport.maxY ? rect.maxY-viewport.height : viewport.minY
        if y != viewport.minY {
            scroll.contentView.scroll(to:CGPoint(x:viewport.minX,y:max(0,y)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        // The synchronous clip-bounds observer already reconciles the cells.
        record("scrollTo",start)
    }
    override func scrollWheel(with event:NSEvent) {
        LibraryIdleWork.noteInput()
        cancelIdle()
        let start = ProcessInfo.processInfo.systemUptime
        super.scrollWheel(with:event); record("scrollWheel",start)
    }
    func selectRowIndexes(_ indexes:IndexSet,byExtendingSelection:Bool) {
        let row = indexes.first ?? -1
        guard row == -1 || rows.indices.contains(row) && canSelect?(row) != false else { return }
        guard selectedRow != row else { return }; selectedRow = row; onSelectionChange?()
    }
    override func hitTest(_ point:NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSControl ? hit : self
    }
    override func mouseDown(with event:NSEvent) {
        window?.makeFirstResponder(self)
        dragStart = convert(event.locationInWindow,from:nil); didDrag = false
        clickedRow = row(at:dragStart)
        if canSelect?(clickedRow) == true { selectRowIndexes(IndexSet(integer:clickedRow),byExtendingSelection:false) }
    }
    override func mouseUp(with event:NSEvent) {
        if !didDrag,clickedRow >= 0,row(at:convert(event.locationInWindow,from:nil)) == clickedRow { onClick?(clickedRow) }
    }
    override func mouseDragged(with event:NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        guard !didDrag,hypot(point.x-dragStart.x,point.y-dragStart.y)>3,let writer = writerAtRow?(clickedRow) else { return }
        didDrag = true
        let item = NSDraggingItem(pasteboardWriter:writer)
        item.setDraggingFrame(CGRect(x:point.x,y:point.y,width:24,height:24),contents:NSImage(systemSymbolName:"doc",accessibilityDescription:nil))
        let session = beginDraggingSession(with:[item],event:event,source:self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }
    func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session:NSDraggingSession,willBeginAt screenPoint:NSPoint) { onDragBegin?(session) }
    func draggingSession(_ session:NSDraggingSession,endedAt screenPoint:NSPoint,operation:NSDragOperation) { onDragEnd?(session,operation) }
    override func keyDown(with event:NSEvent) {
        if event.keyCode == 36 { onActivate?() }
        else if event.keyCode == 51 && event.modifierFlags.contains(.command) { onDelete?() }
        else if event.keyCode == 48 { if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) } }
        else if event.keyCode == 125 || event.keyCode == 126 {
            let delta = event.keyCode == 125 ? 1 : -1
            var row = selectedRow < 0 ? (delta>0 ? 0 : rows.count-1) : selectedRow+delta
            while rows.indices.contains(row) {
                if canSelect?(row) == true { selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); scrollRowToVisible(row); break }
                row += delta
            }
        } else { super.keyDown(with:event) }
    }
    override func menu(for event:NSEvent) -> NSMenu? { menuAtRow?(row(at:convert(event.locationInWindow,from:nil))) }
    isolated deinit { settleTask?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
}
