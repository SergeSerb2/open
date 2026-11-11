import AppKit

struct LibraryTableRow {
    let key: String
    let height: CGFloat
    let version: ObjectIdentifier?
}

/// A frame-based, virtualized native list. Geometry is computed once per page:
/// 56pt items, 27pt headings, or 118pt gallery cards. No constraints or height
/// delegate run while scrolling. Only viewport cells live in the hierarchy.
@MainActor
final class LibraryTableView: NSView, NSDraggingSource {
    var onActivate: (() -> Void)?
    var onDelete: (() -> Void)?
    var onClick: ((Int) -> Void)?
    var onSelectionChange: (() -> Void)?
    var menuAtRow: ((Int) -> NSMenu?)?
    var writerAtRow: ((Int) -> NSPasteboardWriting?)?
    var canSelect: ((Int) -> Bool)?
    var makeRow: ((Int) -> NSView?)?
    var onDragBegin: ((NSDraggingSession) -> Void)?
    var onDragEnd: ((NSDraggingSession,NSDragOperation) -> Void)?
    var onScroll: (() -> Void)?
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
                MainActor.assumeIsolated { LibraryRaster.note("clipBoundsObserver"); self?.onScroll?(); self?.reconcile() }
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
    func makeView(withIdentifier identifier:NSUserInterfaceItemIdentifier,owner:Any?) -> NSView? { pool[identifier]?.popLast() }
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
        entry.view.removeFromSuperview()
        if let identifier = entry.view.identifier { pool[identifier,default:[]].append(entry.view) }
    }
    func reconcile() {
        guard !reconciling else { return }; reconciling = true
        defer { reconciling = false }
        let viewport = enclosingScrollView?.contentView.bounds ?? bounds
        let range = self.rows(in:viewport)
        let visible = range.length == 0 ? [] : Array(range.location..<(range.location+range.length))
        let keys = Set(visible.map { rows[$0].key })
        for key in Array(live.keys) where !keys.contains(key) { retire(key) }
        for row in visible {
            let descriptor = rows[row]
            if let entry = live[descriptor.key],entry.version != descriptor.version { retire(descriptor.key) }
            let view: NSView
            if let existing = live[descriptor.key]?.view { view = existing }
            else {
                guard let made = makeRow?(row) else { continue }
                view = made; addSubview(view)
            }
            let rect = rect(ofRow:row)
            if view.frame != rect { view.frame = rect }
            view.layoutSubtreeIfNeeded()
            live[descriptor.key] = (row,descriptor.version,view)
        }
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
    func scrollRowToVisible(_ row:Int) { guard rows.indices.contains(row) else { return }; scrollToVisible(rect(ofRow:row)); reconcile() }
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
    isolated deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
