import AppKit

/// The scrolling page. Owns every pointer and key interaction on the canvas.
@MainActor
final class EaselDocumentView: NSView, NSMenuItemValidation {
    weak var canvas: EaselCanvasView!

    private enum Drag {
        case none
        case move(ids: [UUID], start: CGPoint, frames: [UUID: CGRect], moved: Bool)
        case resize(id: UUID, corner: Int, start: CGPoint, frame: CGRect)
        case draw(kind: EaselShapeKind, start: CGPoint, points: [CGPoint])
        case text(start: CGPoint)
    }
    private var drag: Drag = .none

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Drop (image files, pictures, web addresses, text)

    func registerDrops() { registerForDraggedTypes([.fileURL, .URL, .png, .tiff, .string, EaselCanvasView.pasteboardType]) }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let p = canvas.docPoint(convert(sender.draggingLocation, from: nil))
        return canvas.ingest(sender.draggingPasteboard, at: p, name: "Drop")
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var undoManager: UndoManager? { canvas.canvasUndoManager }
    override func accessibilityRole() -> NSAccessibility.Role? { .layoutArea }
    override func accessibilityLabel() -> String? { "Canvas" }
    override func isAccessibilityElement() -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: canvas.tool == .pointer ? .arrow : .crosshair)
    }

    // MARK: Hit testing

    func objectID(at p: CGPoint) -> UUID? {
        for object in canvas.document.paintOrder.reversed() {
            let r = canvas.viewRect(object.frame)
            switch object.content {
            case .shape(.arrow, _, _, _), .shape(.freehand, _, _, _):
                guard r.insetBy(dx: -6, dy: -6).contains(p), let view = canvas.objectViews[object.id] else { continue }
                if Self.strokeHit(object, in: view, point: convert(p, to: view)) { return object.id }
            default:
                if r.contains(p) { return object.id }
            }
        }
        return nil
    }
    private static func strokeHit(_ object: EaselObject, in view: EaselObjectView, point: CGPoint) -> Bool {
        let b = view.bounds
        let path: NSBezierPath
        switch object.content {
        case .shape(.arrow, _, let arrow?, _):
            path = EaselObjectView.arrowPath(from: CGPoint(x: arrow.start.x * b.width, y: arrow.start.y * b.height),
                                             to: CGPoint(x: arrow.end.x * b.width, y: arrow.end.y * b.height), scale: view.scale)
        case .shape(.freehand, _, _, let points?) where !points.isEmpty:
            path = EaselObjectView.freehandPath(points.map { CGPoint(x: $0.x * b.width, y: $0.y * b.height) })
        default: return b.contains(point)
        }
        return path.cgPath.copy(strokingWithWidth: 14, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(point)
    }
    /// Corner handle under the point: 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left.
    func handle(at p: CGPoint) -> (UUID, Int)? {
        guard canvas.selection.count == 1, let id = canvas.selection.first, let o = canvas.document.object(id) else { return nil }
        let r = canvas.viewRect(o.frame)
        for (i, c) in EaselSelectionView.corners(r).enumerated() where hypot(c.x - p.x, c.y - p.y) <= 8 { return (id, i) }
        return nil
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if canvas.isEditingText {
            if let editor = canvas.textEditor, editor.frame.contains(p) { return }
            canvas.endTextEditing(commit: true)
        }
        window?.makeFirstResponder(self)
        switch canvas.tool {
        case .pointer:
            if let (id, corner) = handle(at: p), let o = canvas.document.object(id) {
                drag = .resize(id: id, corner: corner, start: p, frame: o.frame); return
            }
            guard let id = objectID(at: p) else { canvas.setSelection([]); drag = .none; return }
            if event.clickCount == 2, case .text = canvas.document.object(id)?.content {
                canvas.setSelection([id]); canvas.beginTextEditing(id); drag = .none; return
            }
            var ids = canvas.selection
            if event.modifierFlags.contains(.shift) {
                if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
            } else if !ids.contains(id) { ids = [id] }
            canvas.setSelection(ids)
            var frames: [UUID: CGRect] = [:]
            for id in ids { frames[id] = canvas.document.object(id)?.frame }
            drag = .move(ids: ids, start: p, frames: frames, moved: false)
        case .text:
            drag = .text(start: p)
        case .ellipse, .rectangle, .arrow, .freehand:
            drag = .draw(kind: canvas.tool.shapeKind!, start: p, points: [p])
        case .image:
            drag = .none
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let s = canvas.scale
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        switch drag {
        case .move(let ids, let start, let frames, _):
            let (d, guides) = snappedMove(ids: ids, frames: frames, raw: CGVector(dx: (p.x - start.x) / s, dy: (p.y - start.y) / s))
            canvas.selectionView.guides = guides
            for id in ids {
                guard let f = frames[id], let view = canvas.objectViews[id] else { continue }
                view.frame = canvas.viewRect(EaselCanvasView.clamped(f.offsetBy(dx: d.dx, dy: d.dy)))
            }
            drag = .move(ids: ids, start: start, frames: frames, moved: true)
            canvas.selectionView.rects = ids.compactMap { canvas.objectViews[$0]?.frame }
            canvas.popover.isHidden = true
        case .resize(let id, let corner, let start, let frame):
            let r = Self.resized(frame, corner: corner, by: CGVector(dx: (p.x - start.x) / s, dy: (p.y - start.y) / s),
                                 keepAspect: event.modifierFlags.contains(.shift))
            canvas.objectViews[id]?.frame = canvas.viewRect(r)
            canvas.selectionView.rects = [canvas.viewRect(r)]
            canvas.popover.isHidden = true
        case .draw(let kind, let start, var points):
            points.append(p)
            drag = .draw(kind: kind, start: start, points: points)
            showDraft(kind: kind, start: start, current: p, points: points, square: event.modifierFlags.contains(.shift))
        case .text, .none: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let s = canvas.scale
        let finished = drag
        drag = .none
        switch finished {
        case .move(let ids, let start, let frames, let moved):
            canvas.selectionView.guides = []
            guard moved else { return }
            let (d, _) = snappedMove(ids: ids, frames: frames, raw: CGVector(dx: (p.x - start.x) / s, dy: (p.y - start.y) / s))
            canvas.moveSelectionFrames(ids: ids, original: frames, by: d)
        case .resize(let id, let corner, let start, let frame):
            let r = Self.resized(frame, corner: corner, by: CGVector(dx: (p.x - start.x) / s, dy: (p.y - start.y) / s),
                                 keepAspect: event.modifierFlags.contains(.shift))
            canvas.setFrame(r, of: id)
            canvas.updateSelectionChrome()
        case .draw(let kind, let start, var points):
            points.append(p)
            canvas.draftView?.removeFromSuperview(); canvas.draftView = nil
            guard let object = Self.shape(kind: kind, start: canvas.docPoint(start), end: canvas.docPoint(p),
                                          points: points.map(canvas.docPoint), square: event.modifierFlags.contains(.shift)) else { return }
            let id = canvas.insert(object, name: "Add \(kind == .circle ? "Ellipse" : kind.rawValue.capitalized)")
            canvas.select(tool: .pointer)
            canvas.setSelection([id])
        case .text(let start):
            canvas.addText(at: canvas.docPoint(start))
        case .none: break
        }
    }

    /// The raw drag delta plus the alignment-guide snap, in document points.
    private func snappedMove(ids: [UUID], frames: [UUID: CGRect], raw: CGVector) -> (CGVector, [EaselGuide]) {
        let moving = ids.compactMap { frames[$0] }.map { EaselCanvasView.clamped($0.offsetBy(dx: raw.dx, dy: raw.dy)) }
        guard let first = moving.first else { return (raw, []) }
        let union = moving.dropFirst().reduce(first) { $0.union($1) }
        let others = canvas.document.objects.filter { !ids.contains($0.id) }.map(\.frame)
        let (snap, guides) = EaselSnapping.snap(moving: union, others: others, scale: canvas.scale, toView: canvas.viewRect)
        return (CGVector(dx: raw.dx + snap.dx, dy: raw.dy + snap.dy), guides)
    }

    private func showDraft(kind: EaselShapeKind, start: CGPoint, current: CGPoint, points: [CGPoint], square: Bool) {
        guard let object = Self.shape(kind: kind, start: canvas.docPoint(start), end: canvas.docPoint(current),
                                      points: points.map(canvas.docPoint), square: square, draft: true) else { return }
        if let draft = canvas.draftView { draft.object = object }
        else {
            let v = EaselObjectView(object: object); v.palette = canvas.document.palette
            canvas.draftView = v
            addSubview(v, positioned: .below, relativeTo: canvas.selectionView)
        }
        canvas.draftView?.scale = canvas.scale
        canvas.draftView?.frame = canvas.viewRect(object.frame)
    }

    /// A new shape from a drag, in document points. A click (no drag) makes a 200 × 200 shape
    /// centred on the click (C-report-s6 §1: ellipse 198 × 198 + outline; the rectangle is
    /// assumed the same) and a 160-pt arrow (GUESS — capture pending).
    static func shape(kind: EaselShapeKind, start: CGPoint, end: CGPoint, points: [CGPoint], square: Bool, draft: Bool = false) -> EaselObject? {
        let color = EaselDefaults.color(for: kind)
        let tiny = hypot(end.x - start.x, end.y - start.y) < 4
        if draft && tiny { return nil }
        switch kind {
        case .rectangle, .circle:
            var r: CGRect
            if tiny { r = CGRect(x: start.x - 100, y: start.y - 100, width: 200, height: 200) }
            else {
                var w = end.x - start.x, h = end.y - start.y
                if square { let m = max(abs(w), abs(h)); w = w < 0 ? -m : m; h = h < 0 ? -m : m }
                r = CGRect(x: start.x, y: start.y, width: w, height: h).standardized
            }
            return EaselObject(frame: r, zIndex: 0, content: .shape(kind: kind, color: color, arrow: nil, points: nil))
        case .arrow:
            let b = tiny ? CGPoint(x: start.x + 160, y: start.y) : end
            let pad: CGFloat = 20
            let r = CGRect(x: min(start.x, b.x) - pad, y: min(start.y, b.y) - pad,
                           width: abs(b.x - start.x) + pad * 2, height: abs(b.y - start.y) + pad * 2)
            func f(_ p: CGPoint) -> EaselPoint { EaselPoint(x: (p.x - r.minX) / r.width, y: (p.y - r.minY) / r.height) }
            return EaselObject(frame: r, zIndex: 0, content: .shape(kind: .arrow, color: color, arrow: (f(start), f(b)), points: nil))
        case .freehand:
            let pts = points.isEmpty ? [start] : points
            let pad: CGFloat = 4
            let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!, minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
            let r = CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
            let simplified = simplify(pts, tolerance: 0.6)
            return EaselObject(frame: r, zIndex: 0, content: .shape(kind: .freehand, color: color, arrow: nil,
                points: simplified.map { EaselPoint(x: ($0.x - r.minX) / r.width, y: ($0.y - r.minY) / r.height) }))
        }
    }

    /// Drops points closer than `tolerance` document points to the previous kept point.
    static func simplify(_ pts: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard var last = pts.first else { return [] }
        var out = [last]
        for p in pts.dropFirst() where hypot(p.x - last.x, p.y - last.y) >= tolerance { out.append(p); last = p }
        if let end = pts.last, out.last != end { out.append(end) }
        return out
    }

    static func resized(_ f: CGRect, corner: Int, by d: CGVector, keepAspect: Bool) -> CGRect {
        var minX = f.minX, minY = f.minY, maxX = f.maxX, maxY = f.maxY
        switch corner {
        case 0: minX += d.dx; minY += d.dy
        case 1: maxX += d.dx; minY += d.dy
        case 2: maxX += d.dx; maxY += d.dy
        default: minX += d.dx; maxY += d.dy
        }
        var r = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: max(4, abs(maxX - minX)), height: max(4, abs(maxY - minY)))
        if keepAspect, f.height > 0 {
            let ratio = f.width / f.height
            if r.width / r.height > ratio { r.size.width = r.height * ratio } else { r.size.height = r.width / ratio }
            if corner == 0 || corner == 3 { r.origin.x = f.maxX - r.width }
            if corner == 0 || corner == 1 { r.origin.y = f.maxY - r.height }
        }
        return r
    }

    override func magnify(with event: NSEvent) { canvas.setZoom(canvas.zoom * (1 + event.magnification)) }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty {
            switch event.keyCode {
            case 51, 117: canvas.deleteSelection(); return
            case 53:
                if canvas.tool != .pointer { canvas.select(tool: .pointer) } else { canvas.setSelection([]) }
                return
            case 36, 76:
                if canvas.selection.count == 1, case .text = canvas.document.object(canvas.selection[0])?.content {
                    canvas.beginTextEditing(canvas.selection[0]); return
                }
            case 123, 124, 125, 126:
                let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                let d: CGVector = [123: CGVector(dx: -step, dy: 0), 124: CGVector(dx: step, dy: 0),
                                   125: CGVector(dx: 0, dy: step), 126: CGVector(dx: 0, dy: -step)][event.keyCode]!
                canvas.moveSelection(by: d); return
            default: break
            }
            if let key = event.charactersIgnoringModifiers?.lowercased(),
               let tool = EaselTool.allCases.first(where: { $0.shortcut == key }) ?? (key == "v" ? .pointer : nil) {
                canvas.select(tool: tool); return
            }
        }
        super.keyDown(with: event)
    }

    // MARK: Edit menu (responder chain)

    /// The window's own undo: would use the sidebar's undo manager; the canvas has its own stack.
    @objc func undo(_ sender: Any?) { canvas.canvasUndoManager.undo() }
    @objc func redo(_ sender: Any?) { canvas.canvasUndoManager.redo() }
    @objc func copy(_ sender: Any?) { canvas.copySelection() }
    @objc func cut(_ sender: Any?) { canvas.cutSelection() }
    @objc func paste(_ sender: Any?) { canvas.paste() }
    @objc func delete(_ sender: Any?) { canvas.deleteSelection() }
    @objc override func selectAll(_ sender: Any?) { canvas.setSelection(canvas.document.objects.map(\.id)) }
    @objc func duplicate(_ sender: Any?) { canvas.duplicateSelection() }
    @objc func bringToFront(_ sender: Any?) { canvas.bringToFront() }
    @objc func sendToBack(_ sender: Any?) { canvas.sendToBack() }
    @objc func toggleAlignmentGuides(_ sender: Any?) { EaselSnapping.enabled.toggle() }
    @objc func toggleLive(_ sender: Any?) {
        guard canvas.selection.count == 1, let id = canvas.selection.first,
              case .webCard(let card) = canvas.document.object(id)?.content else { return }
        canvas.setLive(!card.isLive, for: id)
    }
    @objc func openPage(_ sender: Any?) {
        guard canvas.selection.count == 1, let content = canvas.document.object(canvas.selection[0])?.content else { return }
        let raw: String? = switch content { case .webCard(let w): w.url; case .link(let l): l.source; default: nil }
        if let raw, let url = URL(string: raw) { canvas.onOpenURL?(url) }
    }
    @objc func choosePalette(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? String, let palette = EaselPalette(rawValue: p) { canvas.setPalette(palette) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            item.title = canvas.canvasUndoManager.undoMenuItemTitle
            return canvas.canvasUndoManager.canUndo
        case #selector(redo(_:)):
            item.title = canvas.canvasUndoManager.redoMenuItemTitle
            return canvas.canvasUndoManager.canRedo
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)), #selector(duplicate(_:)),
             #selector(bringToFront(_:)), #selector(sendToBack(_:)): return !canvas.selection.isEmpty
        case #selector(paste(_:)):
            let pb = NSPasteboard.general
            return pb.availableType(from: [EaselCanvasView.pasteboardType, .fileURL, .URL, .png, .tiff, .string]) != nil
        case #selector(selectAll(_:)): return !canvas.document.objects.isEmpty
        case #selector(toggleAlignmentGuides(_:)):
            item.state = EaselSnapping.enabled ? .on : .off
            return true
        case #selector(choosePalette(_:)):
            item.state = (item.representedObject as? String) == canvas.document.palette.rawValue ? .on : .off
            return true
        default: return true
        }
    }

    /// Object menu: Bring to Front · Send to Back · Delete · — · Cut · Copy · Paste · — ·
    /// Duplicate. Canvas menu: Paste · — · Color Palette ▸ (C-measurements-s4 `e3-*-menu-ax`).
    /// · — · Use Alignment Guides ✓.
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        if canvas.isEditingText { canvas.endTextEditing(commit: true) }
        if canvas.tool != .pointer { canvas.select(tool: .pointer) }
        window?.makeFirstResponder(self)
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; return i
        }
        if let id = objectID(at: p) {
            if !canvas.selection.contains(id) { canvas.setSelection([id]) }
            var rows: [NSMenuItem] = [item("Bring to Front", #selector(bringToFront(_:))), item("Send to Back", #selector(sendToBack(_:))),
                              item("Delete", #selector(delete(_:))), .separator(),
                              item("Cut", #selector(cut(_:))), item("Copy", #selector(copy(_:))), item("Paste", #selector(paste(_:))),
                              .separator(), item("Duplicate", #selector(duplicate(_:)))]
            // Web and link cards: own rows (titles GUESS — Arc's comment-only rows need capture).
            switch canvas.document.object(id)?.content {
            case .webCard(let card)?:
                rows += [.separator(), item(card.isLive ? "Show Screenshot" : "Show Live Website", #selector(toggleLive(_:))),
                         item("Open Page in New Tab", #selector(openPage(_:)))]
            case .link?: rows += [.separator(), item("Open Page in New Tab", #selector(openPage(_:)))]
            default: break
            }
            return Self.menu(rows)
        }
        canvas.setSelection([])
        let palettes = NSMenu(title: "Color Palette")
        for palette in EaselPalette.allCases {
            let i = item(palette.title, #selector(choosePalette(_:))); i.representedObject = palette.rawValue
            palettes.addItem(i)
        }
        let paletteItem = NSMenuItem(title: "Color Palette", action: nil, keyEquivalent: ""); paletteItem.submenu = palettes
        let guides = item("Use Alignment Guides", #selector(toggleAlignmentGuides(_:)))
        guides.state = EaselSnapping.enabled ? .on : .off
        return Self.menu([item("Paste", #selector(paste(_:))), .separator(), paletteItem, .separator(), guides])
    }
    static func menu(_ items: [NSMenuItem]) -> NSMenu {
        let m = NSMenu(); items.forEach(m.addItem); return m
    }
    /// The menu a right-click at a document point would show (automation).
    func contextMenu(atDocument p: CGPoint) -> NSMenu? {
        guard let window, let event = NSEvent.mouseEvent(with: .rightMouseDown, location: convert(canvas.viewPoint(p), to: nil),
                                                         modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                         clickCount: 1, pressure: 1) else { return nil }
        return menu(for: event)
    }
}

extension EaselCanvasView {
    /// Commits a drag move: the drag already showed the frames; one undo step.
    func moveSelectionFrames(ids: [UUID], original: [UUID: CGRect], by d: CGVector) {
        mutate("Move") { doc in
            for id in ids {
                guard let i = doc.index(of: id), let f = original[id] else { continue }
                doc.objects[i].frame = Self.clamped(f.offsetBy(dx: d.dx, dy: d.dy))
            }
        }
        updateSelectionChrome()
    }
    public func contextMenuTitles(atDocument p: CGPoint) -> [String] {
        func titles(_ m: NSMenu?) -> [String] {
            (m?.items ?? []).map { $0.isSeparatorItem ? "—" : ($0.submenu != nil ? $0.title + " ▸" : $0.title) }
        }
        return titles(docView.contextMenu(atDocument: p))
    }
    /// Performs a context-menu row as a click would (automation).
    @discardableResult
    public func performContextMenu(atDocument p: CGPoint, title: String, submenu: String? = nil) -> Bool {
        guard let menu = docView.contextMenu(atDocument: p),
              var item = menu.items.first(where: { $0.title == title }) else { return false }
        if let submenu { guard let sub = item.submenu?.items.first(where: { $0.title == submenu }) else { return false }; item = sub }
        guard let action = item.action, docView.validateMenuItem(item) else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }
}

/// Thin blue outline and four round corner handles (capture s4 `e2-*-selected`:
/// #7FB8D6 outline ≈ 2 pt; white handles ≈ 8 pt with a blue ring).
@MainActor
final class EaselSelectionView: NSView {
    var rects: [CGRect] = [] { didSet { if oldValue != rects { needsDisplay = true } } }
    var guides: [EaselGuide] = [] { didSet { if oldValue != guides { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    static func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }
    override func draw(_ dirtyRect: NSRect) {
        let dark = EaselStyle.dark(effectiveAppearance)
        for g in guides {
            let line = NSBezierPath(); line.lineWidth = 1.5
            line.move(to: g.from); line.line(to: g.to)
            EaselStyle.guide(dark: dark).setStroke(); line.stroke()
            let ticks = NSBezierPath(); ticks.lineWidth = 1.5
            for t in g.ticks {
                if g.vertical { ticks.move(to: CGPoint(x: t.x - 4, y: t.y)); ticks.line(to: CGPoint(x: t.x + 4, y: t.y)) }
                else { ticks.move(to: CGPoint(x: t.x, y: t.y - 4)); ticks.line(to: CGPoint(x: t.x, y: t.y + 4)) }
            }
            EaselStyle.selection.setStroke(); ticks.stroke()
        }
        // While a guide shows, Arc hides the outline of the moving object (`e4-move-guides`).
        guard guides.isEmpty else { return }
        for r in rects {
            let outline = NSBezierPath(rect: r); outline.lineWidth = 2
            EaselStyle.selection.setStroke(); outline.stroke()
            guard rects.count == 1 else { continue }
            for c in Self.corners(r) {
                let h = NSBezierPath(ovalIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)); h.lineWidth = 1.5
                NSColor.white.setFill(); h.fill(); EaselStyle.selection.setStroke(); h.stroke()
            }
        }
    }
}

/// Colour grid above a selected shape: two rows (6 + 5) of 20-pt swatches at a 26-pt pitch,
/// 181 × 70 pt card, corner 10, arrow 12 × 6 pointing at the shape, 9 pt above it
/// (measured on capture s4 `e2-rect-selected` at 2×).
@MainActor
final class EaselColorPopover: NSView {
    static let size = CGSize(width: 181, height: 76)  // 70 card + 6 arrow
    static let gap: CGFloat = 9
    static let card: CGFloat = 70
    var palette: EaselPalette = .vibrant
    var current: EaselColor = .white
    var arrowDown = true
    var arrowX: CGFloat = 90
    var onPick: ((EaselColor) -> Void)?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        shadow = { let s = NSShadow(); s.shadowBlurRadius = 10; s.shadowOffset = NSSize(width: 0, height: -2); s.shadowColor = NSColor(white: 0, alpha: 0.12); return s }()
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Colors")
    }
    required init?(coder: NSCoder) { fatalError() }

    var cardRect: CGRect { CGRect(x: 0, y: arrowDown ? 0 : 6, width: bounds.width, height: Self.card) }
    func center(of color: EaselColor) -> CGPoint? {
        for (row, colors) in EaselColor.rows.enumerated() {
            guard let i = colors.firstIndex(of: color) else { continue }
            let span = CGFloat(colors.count - 1) * 26
            return CGPoint(x: bounds.midX - span / 2 + CGFloat(i) * 26, y: cardRect.minY + 22.5 + CGFloat(row) * 26)
        }
        return nil
    }
    override func draw(_ dirtyRect: NSRect) {
        let dark = EaselStyle.dark(effectiveAppearance)
        let card = cardRect
        let path = NSBezierPath(roundedRect: card, xRadius: 10, yRadius: 10)
        let ax = min(max(arrowX, 16), bounds.width - 16)
        let tip = NSBezierPath()
        if arrowDown { tip.move(to: CGPoint(x: ax - 6, y: card.maxY)); tip.line(to: CGPoint(x: ax, y: card.maxY + 6)); tip.line(to: CGPoint(x: ax + 6, y: card.maxY)) }
        else { tip.move(to: CGPoint(x: ax - 6, y: card.minY)); tip.line(to: CGPoint(x: ax, y: card.minY - 6)); tip.line(to: CGPoint(x: ax + 6, y: card.minY)) }
        tip.close(); path.append(tip)
        EaselStyle.popover(dark: dark).setFill(); path.fill()
        for colors in EaselColor.rows {
            for color in colors {
                guard let c = center(of: color) else { continue }
                let fill = palette.color(color, dark: dark)
                let swatch = NSBezierPath(ovalIn: CGRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20))
                fill.setFill(); swatch.fill()
                swatch.lineWidth = 1
                // The swatch that matches the popover (white in light, black in dark) gets a visible ring.
                (color == .white ? NSColor(white: dark ? 1 : 0, alpha: dark ? 0.35 : 0.15)
                    : fill.blended(withFraction: 0.18, of: .black) ?? fill).setStroke()
                swatch.stroke()
                if color == current {
                    let check = NSBezierPath(); check.lineWidth = 1.8; check.lineCapStyle = .round; check.lineJoinStyle = .round
                    check.move(to: CGPoint(x: c.x - 5, y: c.y)); check.line(to: CGPoint(x: c.x - 1.5, y: c.y + 3.5)); check.line(to: CGPoint(x: c.x + 5, y: c.y - 3.5))
                    ((color == .white && !dark) || (color == .black && dark) || color == .yellow ? NSColor(white: 0.2, alpha: 1) : .white).setStroke(); check.stroke()
                }
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for color in EaselColor.allCases {
            if let c = center(of: color), hypot(c.x - p.x, c.y - p.y) <= 12 { onPick?(color); needsDisplay = true; return }
        }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Centred bold title ("Untitled Easel" placeholder).
@MainActor
final class EaselTitleField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    /// The first edit of the title: an open text box must close first, or its commit would
    /// restore the document from before the box and drop the new title.
    var onBeginEditing: (() -> Void)?
    /// GUESS 26 pt bold — the 2× capture's glyph run measures ≈ 140 pt wide for
    /// "Untitled Easel"; capture of the font pending.
    static let font = NSFont.systemFont(ofSize: 26, weight: .bold)
    init() {
        super.init(frame: .zero)
        isBordered = false; drawsBackground = false; focusRingType = .none
        alignment = .center; font = Self.font
        lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        delegate = self
        setAccessibilityLabel("Easel Title")
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    func updateColors() {
        let dark = EaselStyle.dark(effectiveAppearance)
        textColor = EaselStyle.title(dark: dark)
        placeholderAttributedString = NSAttributedString(string: EaselDocument.untitled, attributes: [
            .font: Self.font, .foregroundColor: EaselStyle.title(dark: dark), .paragraphStyle: {
                let p = NSMutableParagraphStyle(); p.alignment = .center; return p }()])
    }
    override var placeholderString: String? { get { EaselDocument.untitled } set {} }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    func controlTextDidBeginEditing(_ obj: Notification) { onBeginEditing?() }
    func controlTextDidEndEditing(_ obj: Notification) { onCommit?(stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) {
            window?.makeFirstResponder(superview); return true
        }
        return false
    }
}
