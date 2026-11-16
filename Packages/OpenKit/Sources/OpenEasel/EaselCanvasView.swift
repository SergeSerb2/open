import AppKit

/// The Easel page: title, scrolling 1000-pt-wide canvas, floating tool bar, colour popover.
/// UI only; the App's content host owns loading and saving (`onChange`).
@MainActor
public final class EaselCanvasView: NSView {
    public private(set) var document: EaselDocument
    /// Every committed change (also undo/redo and title edits). The host saves it.
    public var onChange: ((EaselDocument) -> Void)?
    /// The add button: a Split beside the Easel (capture s4 `w-add-button`).
    public var onAddSplit: (() -> Void)?
    /// The Image tool: the host shows an open panel and calls `insertImage`.
    public var onPickImage: (() -> Void)?
    /// A pasted or dropped web address: the host stores the page metadata and calls back.
    public var onLink: ((URL, CGPoint) -> Void)?
    /// Image file name → URL in this Easel's `images/` folder.
    public var imageURL: ((String) -> URL?)? { didSet { objectViews.values.forEach { $0.imageURL = imageURL } } }
    /// A live web card's page view (the App's pooled engine page), and its release.
    public var liveViewProvider: ((UUID, URL) -> NSView?)?
    public var liveViewRelease: ((UUID) -> Void)?
    /// "Open Page in New Tab" on a web or link card.
    public var onOpenURL: ((URL) -> Void)?
    /// Stores picture bytes (validated) and returns the object content, or nil.
    public var storeImage: ((Data) -> EaselImage?)?
    /// The canvas keeps its own undo stack, so ⌘Z on the canvas never undoes sidebar edits.
    public let canvasUndoManager = UndoManager()
    public override var undoManager: UndoManager? { canvasUndoManager }

    public private(set) var tool: EaselTool = .pointer
    public private(set) var selection: [UUID] = []
    public private(set) var zoom: CGFloat = 1
    /// ⌘− ≈ 74 %, 50 %, min ≈ 33 % (docs/re/easels.md); ⌘= ≈ ×1.75, ×2.5, max ≈ ×4 on the third
    /// press (C-report-s6 §1, measured ×1.65–1.76, ×2.35–2.52, ×3.77).
    public static let zoomSteps: [CGFloat] = [0.33, 0.5, 0.75, 1, 1.75, 2.5, 4]

    let scrollView = NSScrollView()
    let docView = EaselDocumentView()
    let toolbar = EaselToolbarView(frame: CGRect(origin: .zero, size: EaselToolbarView.size))
    let titleField = EaselTitleField()
    let popover = EaselColorPopover()
    let selectionView = EaselSelectionView()
    var objectViews: [UUID: EaselObjectView] = [:]
    var textEditor: EaselTextEditor?
    /// Live drag preview (a shape being drawn).
    var draftView: EaselObjectView?
    public private(set) var commitCount = 0

    public init(document: EaselDocument) {
        self.document = document
        super.init(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        wantsLayer = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        // The page starts at the content top: no automatic title-bar inset.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        // One explicit group per canvas edit (not per run-loop event).
        canvasUndoManager.groupsByEvent = false
        scrollView.documentView = docView
        docView.canvas = self
        docView.registerDrops()
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        addSubview(scrollView)
        docView.addSubview(titleField)
        docView.addSubview(selectionView)
        docView.addSubview(popover)
        popover.isHidden = true
        popover.onPick = { [weak self] color in self?.setColor(color) }
        addSubview(toolbar)
        toolbar.onSelect = { [weak self] t in self?.select(tool: t) }
        toolbar.onAdd = { [weak self] in self?.onAddSplit?() }
        titleField.stringValue = document.title ?? ""
        titleField.onCommit = { [weak self] text in self?.setTitle(text) }
        titleField.onBeginEditing = { [weak self] in self?.endTextEditing(commit: true) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Easel")
        syncObjects()
    }
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() { layer?.backgroundColor = EaselStyle.canvas(dark: isDark).cgColor }
    var isDark: Bool { EaselStyle.dark(effectiveAppearance) }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true; titleField.updateColors()
    }

    // MARK: Geometry

    /// View points per document point: the clip width maps to 1000 document points at 100 %.
    var baseScale: CGFloat { max(0.05, scrollView.contentView.bounds.width / EaselDocument.width) }
    public var scale: CGFloat { baseScale * zoom }
    var originX: CGFloat { max(0, (docView.bounds.width - EaselDocument.width * scale) / 2) }
    func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: originX + r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
    }
    func docPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - originX) / scale, y: p.y / scale) }
    func viewPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: originX + p.x * scale, y: p.y * scale) }

    /// Toolbar 10 pt from the left, 12 pt from the bottom (C-measurements-s4: buttons at
    /// x 376 in a page from x 366; bar 4 pt around them).
    static let toolbarInset = CGPoint(x: 6, y: 12)
    /// Title: centred, top 32 pt, 546 × 66 (C-measurements-s4 AX frame).
    static let titleTop: CGFloat = 32
    static let titleSize = CGSize(width: 546, height: 66)

    /// The host sizes this view by frame (no constraints): lay out on every size change.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
        toolbar.frame.origin = CGPoint(x: Self.toolbarInset.x, y: bounds.height - Self.toolbarInset.y - toolbar.frame.height)
        layoutDocument()
    }

    func layoutDocument() {
        let clip = scrollView.contentView.bounds
        let width = max(clip.width, EaselDocument.width * scale)
        let bottom = max(document.contentBottom, draftView.map { $0.object.frame.maxY } ?? 0) + 400
        let height = max(clip.height, bottom * scale)
        if docView.frame.size != CGSize(width: width, height: height) { docView.frame.size = CGSize(width: width, height: height) }
        let tw = min(Self.titleSize.width, max(120, width - 40))
        let lineHeight = ceil(EaselTitleField.font.ascender - EaselTitleField.font.descender + EaselTitleField.font.leading) + 4
        titleField.frame = CGRect(x: (width - tw) / 2, y: Self.titleTop + (Self.titleSize.height - lineHeight) / 2, width: tw, height: lineHeight)
        for (id, view) in objectViews {
            guard let object = document.object(id) else { continue }
            view.scale = scale
            view.frame = viewRect(object.frame)
        }
        if let draftView { draftView.scale = scale; draftView.frame = viewRect(draftView.object.frame) }
        textEditor?.layoutIn(canvas: self)
        updateSelectionChrome()
        updateLiveViews()
    }

    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateLiveViews() }
    public override func viewDidHide() { super.viewDidHide(); releaseAllLiveViews() }
    public override func viewDidUnhide() { super.viewDidUnhide(); updateLiveViews() }
    @objc func clipBoundsChanged(_ note: Notification) { updateLiveViews() }

    // MARK: Document sync

    func syncObjects() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let ids = Set(document.objects.map(\.id))
        for (id, view) in objectViews where !ids.contains(id) { view.removeFromSuperview(); objectViews[id] = nil }
        var ordered: [EaselObjectView] = []
        for object in document.paintOrder {
            let view = objectViews[object.id] ?? {
                let v = EaselObjectView(object: object); objectViews[object.id] = v; return v
            }()
            view.object = object
            view.imageURL = imageURL
            view.palette = document.palette
            view.scale = scale
            view.frame = viewRect(object.frame)
            view.editing = textEditor?.objectID == object.id
            ordered.append(view)
        }
        // Objects sit between the title (bottom) and the selection chrome (top).
        if docView.subviews.compactMap({ $0 as? EaselObjectView }) != ordered {
            for view in ordered { docView.addSubview(view, positioned: .below, relativeTo: selectionView) }
        }
        selection.removeAll { !ids.contains($0) }
        CATransaction.commit()
        layoutDocument()
    }

    /// One undoable change. `name` is the Edit menu's undo title.
    func mutate(_ name: String, _ body: (inout EaselDocument) -> Void) {
        var next = document
        body(&next)
        guard next != document else { return }
        next.modifiedAt = Date()
        let old = document
        apply(next)
        registerUndo(restoring: old, name: name)
    }
    func registerUndo(restoring old: EaselDocument, name: String) {
        let manager = canvasUndoManager
        let grouped = !manager.isUndoing && !manager.isRedoing
        if grouped { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: self) { canvas in
            let current = canvas.document
            canvas.endTextEditing(commit: false)
            canvas.apply(old)
            canvas.registerUndo(restoring: current, name: name)
        }
        manager.setActionName(name)
        if grouped { manager.endUndoGrouping() }
    }
    func apply(_ next: EaselDocument) {
        document = next
        if titleField.currentEditor() == nil { titleField.stringValue = next.title ?? "" }
        commitCount += 1
        syncObjects()
        onChange?(next)
    }

    // MARK: Tools

    public func select(tool: EaselTool) {
        endTextEditing(commit: true)
        // The Image tool opens a file panel and returns to the pointer (no drawing mode).
        if tool == .image { endTextEditing(commit: true); onPickImage?(); return }
        self.tool = tool
        toolbar.selectedTool = tool
        if tool != .pointer { setSelection([]) }
        window?.invalidateCursorRects(for: docView)
    }

    public func setSelection(_ ids: [UUID]) {
        selection = ids.filter { document.object($0) != nil }
        updateSelectionChrome()
        NSAccessibility.post(element: docView, notification: .selectedChildrenChanged)
    }

    func updateSelectionChrome(hidePopover: Bool = false) {
        let rects = selection.compactMap { document.object($0) }.map { viewRect($0.frame) }
        selectionView.frame = docView.bounds
        selectionView.rects = textEditor == nil ? rects : []
        guard selection.count == 1, textEditor == nil, !hidePopover, let object = document.object(selection[0]),
              let color = object.content.color else { popover.isHidden = true; return }
        let r = viewRect(object.frame)
        popover.palette = document.palette
        popover.current = color
        let size = EaselColorPopover.size
        var y = r.minY - EaselColorPopover.gap - size.height
        popover.arrowDown = y >= 0
        if y < 0 { y = r.maxY + EaselColorPopover.gap }
        let x = min(max(4, r.midX - size.width / 2), docView.bounds.width - size.width - 4)
        popover.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        popover.arrowX = r.midX - x
        popover.isHidden = false
        popover.needsDisplay = true
    }

    // MARK: Edits (public: the automation socket drives the same paths)

    public func setTitle(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate("Rename Easel") { $0.title = trimmed.isEmpty ? nil : trimmed }
    }

    public func setColor(_ color: EaselColor) {
        let ids = selection
        mutate("Change Color") { doc in
            for id in ids {
                guard let i = doc.index(of: id), case .shape(let kind, _, let arrow, let points) = doc.objects[i].content else { continue }
                doc.objects[i].content = .shape(kind: kind, color: color, arrow: arrow, points: points)
                EaselDefaults.setColor(color, for: kind)
            }
        }
        updateSelectionChrome()
    }

    public func setPalette(_ palette: EaselPalette) { mutate("Change Color Palette") { $0.palette = palette } }

    public func deleteSelection() {
        let ids = Set(selection)
        guard !ids.isEmpty else { return }
        mutate("Delete") { $0.objects.removeAll { ids.contains($0.id) } }
        setSelection([])
    }

    public func bringToFront() {
        let ids = selection
        mutate("Bring to Front") { doc in
            var z = doc.maxZ
            for id in ids { if let i = doc.index(of: id) { z += 1; doc.objects[i].zIndex = z } }
        }
    }
    public func sendToBack() {
        let ids = selection
        mutate("Send to Back") { doc in
            var z = doc.minZ
            for id in ids.reversed() { if let i = doc.index(of: id) { z -= 1; doc.objects[i].zIndex = z } }
        }
    }

    public func moveSelection(by delta: CGVector) {
        let ids = Set(selection)
        guard !ids.isEmpty, delta != .zero else { return }
        mutate("Move") { doc in
            for i in doc.objects.indices where ids.contains(doc.objects[i].id) {
                doc.objects[i].frame = Self.clamped(doc.objects[i].frame.offsetBy(dx: delta.dx, dy: delta.dy))
            }
        }
    }

    public func setFrame(_ frame: CGRect, of id: UUID) {
        mutate("Resize") { doc in
            if let i = doc.index(of: id) { doc.objects[i].frame = Self.clamped(frame) }
        }
    }

    /// Keeps objects on the page: x within 0…1000 (partly), y ≥ 0; min size 4 pt.
    static func clamped(_ r: CGRect) -> CGRect {
        var r = r.standardized
        r.size.width = max(4, r.width); r.size.height = max(4, r.height)
        r.origin.x = min(max(r.minX, -r.width + 20), EaselDocument.width - 20)
        r.origin.y = max(0, r.minY)
        return r
    }

    @discardableResult
    public func insert(_ object: EaselObject, name: String = "Add") -> UUID {
        var object = object
        object.zIndex = document.maxZ + 1
        object.frame = Self.clamped(object.frame)
        mutate(name) { $0.objects.append(object) }
        return object.id
    }

    public func duplicateSelection() {
        let objects = selection.compactMap { document.object($0) }
        guard !objects.isEmpty else { return }
        var z = document.maxZ
        let copies = objects.map { o -> EaselObject in
            z += 1
            return EaselObject(frame: o.frame.offsetBy(dx: 20, dy: 20), zIndex: z, content: o.content)
        }
        mutate("Duplicate") { $0.objects.append(contentsOf: copies) }
        setSelection(copies.map(\.id))
    }

    // MARK: Pasteboard

    public static let pasteboardType = NSPasteboard.PasteboardType("io.github.sergeserb2.open.easel-objects")

    public func copySelection() {
        let objects = selection.compactMap { document.object($0) }
        guard !objects.isEmpty, let data = try? JSONEncoder().encode(objects) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.pasteboardType)
        let text = objects.compactMap { if case .text(let t) = $0.content { t.string } else { nil } }.joined(separator: "\n")
        if !text.isEmpty { pb.setString(text, forType: .string) }
    }
    public func cutSelection() { copySelection(); deleteSelection() }
    public func paste() {
        let clip = scrollView.contentView.bounds
        _ = ingest(NSPasteboard.general, at: docPoint(CGPoint(x: clip.midX, y: clip.midY)), name: "Paste")
    }

    /// Paste and drop: Easel objects, image files, image data, a web address (link card), or
    /// text, in that order. `center` is in document points. Returns false when nothing fit.
    @discardableResult
    public func ingest(_ pb: NSPasteboard, at center: CGPoint, name: String) -> Bool {
        if let data = pb.data(forType: Self.pasteboardType), data.count <= EaselDocument.maxFileBytes,
           let objects = try? JSONDecoder().decode([EaselObject].self, from: data), EaselDocument.isValid(objects),
           document.objects.count + objects.count <= EaselDocument.maxObjects,
           objects.allSatisfy({ $0.content.imageFiles.isEmpty || $0.content.imageFiles.allSatisfy { imageURL?($0).map { FileManager.default.fileExists(atPath: $0.path) } ?? false } }) {
            var z = document.maxZ
            let copies = objects.map { o -> EaselObject in
                z += 1; return EaselObject(frame: Self.clamped(o.frame.offsetBy(dx: 20, dy: 20)), zIndex: z, content: o.content)
            }
            mutate(name) { $0.objects.append(contentsOf: copies) }
            setSelection(copies.map(\.id))
            return true
        }
        let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        var images: [EaselImage] = []
        for file in files.prefix(20) {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int,
                  size <= EaselStore.maxImageBytes, let data = try? Data(contentsOf: file), let image = storeImage?(data) else { continue }
            images.append(image)
        }
        if images.isEmpty, let type = pb.availableType(from: [.png, .tiff]), let data = pb.data(forType: type),
           data.count <= EaselStore.maxImageBytes, let image = storeImage?(data) {
            images.append(image)
        }
        if !images.isEmpty {
            var ids: [UUID] = []
            var at = center
            for image in images { ids.append(insertImage(image, centeredAt: at, name: name)); at.x += 24; at.y += 24 }
            setSelection(ids)
            return true
        }
        if let url = Self.webURL(in: pb) { onLink?(url, center); return onLink != nil }
        if let string = pb.string(forType: .string), !string.isEmpty, string.utf16.count <= EaselDocument.maxTextLength {
            let id = insert(EaselObject(frame: CGRect(x: center.x - 150, y: center.y - 15, width: 300, height: 30), zIndex: 0,
                                        content: .text(EaselText(string: string))), name: name)
            setSelection([id])
            return true
        }
        return false
    }

    /// One http(s) address on the pasteboard (a URL item, or text that is only an address).
    static func webURL(in pb: NSPasteboard) -> URL? {
        let candidates = ((pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? [])
            + [pb.string(forType: .string).flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }].compactMap { $0 }
        return candidates.first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host() != nil
            && $0.absoluteString.utf16.count <= EaselDocument.maxURLLength }
    }

    /// Pictures land at most 400 document points wide (GUESS — capture pending), keeping
    /// their aspect ratio.
    @discardableResult
    public func insertImage(_ image: EaselImage, centeredAt c: CGPoint? = nil, name: String = "Add Image") -> UUID {
        let center = c ?? visibleCenter
        let w = min(400, CGFloat(image.width)), h = w * CGFloat(image.height) / CGFloat(image.width)
        let id = insert(EaselObject(frame: CGRect(x: center.x - w / 2, y: max(0, center.y - h / 2), width: w, height: h),
                                    zIndex: 0, content: .image(image)), name: name)
        return id
    }

    /// Link cards: 320 × 250 with a picture, 320 × 72 without (GUESS — capture pending).
    @discardableResult
    public func insertLink(_ link: EaselLink, centeredAt c: CGPoint? = nil) -> UUID {
        let center = c ?? visibleCenter
        let h: CGFloat = link.imageFile == nil ? (link.summary == nil ? 52 : 72) : 250
        let id = insert(EaselObject(frame: CGRect(x: center.x - 160, y: max(0, center.y - h / 2), width: 320, height: h),
                                    zIndex: 0, content: .link(link)), name: "Add Link")
        setSelection([id])
        return id
    }

    /// Web cards (captures) keep the capture's aspect ratio, at most 500 points wide.
    @discardableResult
    public func insertWebCard(_ card: EaselWebCard, pixelSize: CGSize, centeredAt c: CGPoint? = nil) -> UUID {
        let center = c ?? visibleCenter
        let w = min(500, max(40, pixelSize.width / 2)), h = w * max(1, pixelSize.height) / max(1, pixelSize.width)
        let id = insert(EaselObject(frame: CGRect(x: center.x - w / 2, y: max(0, center.y - h / 2), width: w, height: h),
                                    zIndex: 0, content: .webCard(card)), name: "Add Capture")
        setSelection([id])
        return id
    }

    /// Fills in a link card's metadata when it arrives. Not an undo step: undoing "Add Link"
    /// still removes the card.
    public func updateLink(_ id: UUID, _ change: (inout EaselLink) -> Void) {
        guard let i = document.index(of: id), case .link(var link) = document.objects[i].content else { return }
        change(&link)
        var next = document
        next.objects[i].content = .link(link)
        let height: CGFloat = link.imageFile == nil ? (link.summary == nil ? 52 : 72) : 250
        next.objects[i].frame.size.height = height
        apply(next)
        updateSelectionChrome()
    }

    public var visibleCenter: CGPoint {
        let clip = scrollView.contentView.bounds
        return docPoint(CGPoint(x: clip.midX, y: clip.midY))
    }

    // MARK: Text editing

    public var isEditingText: Bool { textEditor != nil }

    /// Places the 280 × 28 pt box (capture s4 `e2-text-focus`; in document points at Arc's
    /// 906-pt page) and starts editing. The empty box is not an undo step: committing text
    /// records one "Add Text" step; an empty box simply goes away.
    func addText(at docPoint: CGPoint) {
        endTextEditing(commit: true)
        let before = document
        var object = EaselObject(frame: Self.clamped(CGRect(x: docPoint.x, y: docPoint.y - 15, width: 309, height: 31)),
                                 zIndex: document.maxZ + 1, content: .text(EaselText()))
        object.zIndex = document.maxZ + 1
        var next = document; next.objects.append(object)
        apply(next)
        select(tool: .pointer)
        setSelection([object.id])
        beginTextEditing(object.id, undoBase: before)
    }

    public func beginTextEditing(_ id: UUID) { beginTextEditing(id, undoBase: nil) }

    func beginTextEditing(_ id: UUID, undoBase: EaselDocument?) {
        guard let object = document.object(id), case .text = object.content else { return }
        endTextEditing(commit: true)
        let editor = EaselTextEditor(objectID: id, canvas: self)
        editor.undoBase = undoBase
        textEditor = editor
        docView.addSubview(editor, positioned: .above, relativeTo: nil)
        objectViews[id]?.editing = true
        editor.layoutIn(canvas: self)
        updateSelectionChrome()
        window?.makeFirstResponder(editor.textView)
    }

    /// Commits the typed text. Clearing an existing box deletes it (undoable).
    public func endTextEditing(commit: Bool) {
        guard let editor = textEditor else { return }
        textEditor = nil
        let id = editor.objectID
        editor.removeFromSuperview()
        objectViews[id]?.editing = false
        defer { if window?.firstResponder === editor.textView { window?.makeFirstResponder(docView) }; updateSelectionChrome() }
        guard let object = document.object(id), case .text(var text) = object.content else { return }
        let typed = editor.textView.string
        let empty = typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let base = editor.undoBase {
            // A new box: one "Add Text" step from the document before the box, or nothing.
            var next = base
            if commit, !empty {
                text.string = typed
                text.paragraphStyle = editor.style.paragraphStyle; text.fontFamily = editor.style.fontFamily
                var o = object; o.content = .text(text); o.frame.size.height = max(object.frame.height, editor.neededDocHeight)
                next.objects.append(o)
                next.modifiedAt = Date()
                apply(next)
                registerUndo(restoring: base, name: "Add Text")
            } else {
                next.modifiedAt = document.modifiedAt
                apply(next)
                setSelection([])
            }
            return
        }
        guard commit else { return }
        if empty { setSelection([id]); deleteSelection(); return }
        text.string = typed
        text.paragraphStyle = editor.style.paragraphStyle; text.fontFamily = editor.style.fontFamily
        let height = max(object.frame.height, editor.neededDocHeight)
        mutate("Typing") { doc in
            if let i = doc.index(of: id) { doc.objects[i].content = .text(text); doc.objects[i].frame.size.height = height }
        }
    }

    // MARK: Zoom

    public func zoomIn() { setZoom(Self.zoomSteps.first { $0 > zoom + 0.001 } ?? zoom) }
    public func zoomOut() { setZoom(Self.zoomSteps.last { $0 < zoom - 0.001 } ?? zoom) }
    public func resetZoom() { setZoom(1) }
    public func setZoom(_ value: CGFloat) {
        let z = min(max(value, Self.zoomSteps.first!), Self.zoomSteps.last!)
        guard abs(z - zoom) > 0.0001 else { return }
        let clip = scrollView.contentView.bounds
        // The zoom keeps the visible centre in place (C-report-s6 §1: anchored near the centre).
        let anchor = docPoint(CGPoint(x: clip.midX, y: clip.midY))
        zoom = z
        layoutDocument()
        let size = scrollView.contentView.bounds.size
        let center = viewPoint(anchor)
        docView.scroll(CGPoint(x: max(0, min(center.x - size.width / 2, docView.bounds.width - size.width)),
                               y: max(0, min(center.y - size.height / 2, docView.bounds.height - size.height))))
    }

    // MARK: State (automation and accessibility)

    public func state() -> [String: Any] {
        // A size change marks layout as needed; report the laid-out geometry, not the old one.
        layoutSubtreeIfNeeded()
        func r(_ c: CGRect) -> [Double] { [c.minX, c.minY, c.width, c.height].map { (Double($0) * 1000).rounded() / 1000 } }
        let objects: [[String: Any]] = document.paintOrder.map { o in
            var item: [String: Any] = ["id": o.id.uuidString.lowercased(), "kind": o.content.kindName, "frame": r(o.frame),
                                       "zIndex": o.zIndex, "viewFrame": r(objectViews[o.id].map { docView.convert($0.frame, to: self) } ?? .zero)]
            switch o.content {
            case .text(let t): item["text"] = t.string; item["fontFamily"] = t.fontFamily.rawValue; item["paragraphStyle"] = t.paragraphStyle.rawValue
            case .shape(_, let c, let arrow, let points):
                item["color"] = c.rawValue
                if let arrow { item["arrow"] = [arrow.start.x, arrow.start.y, arrow.end.x, arrow.end.y] }
                if let points { item["pointCount"] = points.count }
            case .image(let i): item["file"] = i.file; item["pixelSize"] = [i.width, i.height]
            case .webCard(let w): item["url"] = w.url; item["title"] = w.title as Any? ?? NSNull(); item["file"] = w.imageFile as Any? ?? NSNull()
                item["live"] = w.isLive; item["liveAttached"] = objectViews[o.id]?.liveView != nil
            case .link(let l): item["url"] = l.source; item["title"] = l.title as Any? ?? NSNull()
                item["summary"] = l.summary as Any? ?? NSNull(); item["file"] = l.imageFile as Any? ?? NSNull()
            }
            return item
        }
        let toolbarButtons = toolbar.buttons.map { b -> [String: Any] in
            ["label": b.accessibilityLabel() ?? "", "frame": r(b.convert(b.bounds, to: self)), "selected": b.isSelectedTool]
        }
        return ["id": document.id.uuidString.lowercased(), "title": document.title as Any? ?? NSNull(),
                "displayTitle": document.displayTitle, "titleFieldText": titleField.stringValue,
                "titlePlaceholder": titleField.placeholderString ?? "", "titleFrame": r(titleField.convert(titleField.bounds, to: self)),
                "palette": document.palette.rawValue, "objects": objects, "tool": tool.rawValue,
                "selection": selection.map { $0.uuidString.lowercased() }, "zoom": zoom, "scale": scale,
                "toolbarFrame": r(toolbar.frame), "toolbarButtons": toolbarButtons,
                "popoverShown": !popover.isHidden, "popoverFrame": r(popover.isHidden ? .zero : docView.convert(popover.frame, to: self)),
                "popoverColor": popover.isHidden ? NSNull() : popover.current.rawValue as Any,
                "editingText": textEditor.map { $0.objectID.uuidString.lowercased() } as Any? ?? NSNull(),
                "editorText": textEditor?.textView.string as Any? ?? NSNull(),
                "canUndo": canvasUndoManager.canUndo, "canRedo": canvasUndoManager.canRedo,
                "undoName": canvasUndoManager.undoActionName, "commitCount": commitCount,
                "documentViewSize": [docView.frame.width, docView.frame.height],
                "scrollOffset": scrollView.contentView.bounds.minY,
                "appearance": effectiveAppearance.name.rawValue, "liveCount": liveObjectIDs.count]
    }

    /// Converts a document point to window coordinates (automation drives real mouse events).
    public func windowPoint(forDocument p: CGPoint) -> CGPoint {
        layoutSubtreeIfNeeded()
        return docView.convert(viewPoint(p), to: nil)
    }
    public var documentView: NSView { docView }
    public var titleView: NSTextField { titleField }
    public var toolbarView: NSView { toolbar }
    public func toolbarButton(_ tool: EaselTool) -> NSView? { toolbar.button(tool) }
    public var addButton: NSView { toolbar.addButton }
    public var colorPopover: NSView { popover }
    public func swatchCenter(_ color: EaselColor) -> CGPoint? {
        guard !popover.isHidden, let c = popover.center(of: color) else { return nil }
        return popover.convert(c, to: nil)
    }
    public var editorTextView: NSTextView? { textEditor?.textView }
    public func editorSizeButton(_ which: String) -> NSView? { textEditor?.sizeControl.button(which) }

    /// Writes the title field's pending text now (the host flushes before quit).
    public func commitPendingEdits() {
        if titleField.currentEditor() != nil { setTitle(titleField.stringValue) }
        endTextEditing(commit: true)
    }

    public func focus() { window?.makeFirstResponder(docView) }
}

/// Per-tool default colours (findings §3.4: rectangle lightGreen, circle red, arrow lightBlue,
/// freehand black; the user's last pick per tool sticks, as Arc's `rectangleColor` & co.).
enum EaselDefaults {
    static func key(_ kind: EaselShapeKind) -> String { "open.easel.color.\(kind.rawValue)" }
    static func color(for kind: EaselShapeKind) -> EaselColor {
        if let raw = UserDefaults.standard.string(forKey: key(kind)), let c = EaselColor(rawValue: raw) { return c }
        switch kind {
        case .rectangle: return .lightGreen
        case .circle: return .red
        case .arrow: return .lightBlue
        case .freehand: return .black
        }
    }
    static func setColor(_ color: EaselColor, for kind: EaselShapeKind) { UserDefaults.standard.set(color.rawValue, forKey: key(kind)) }
}
