import AppKit
import OpenDesign
import OpenModel
import OpenBoosts

/// The shell owns navigation and tab selection. This library owns one editor per window.
/// Call `boundContextDidChange` when the selected tab, Space or Profile changes and
/// `pageDidNavigate` when the bound tab navigates. No browser-window implementation lives here.
@MainActor
public final class BoostEditorController: NSObject, NSTextFieldDelegate {
    public private(set) var session: BoostEditorSession?
    public private(set) var view: BoostEditorView?
    public private(set) var panel: NSPanel?
    public var onClose: (() -> Void)?
    public var onMenu: ((NSMenu) -> Void)?
    public private(set) var activeAlert: NSAlert?
    private let host: BoostEditorHost
    private let defaults: UserDefaults
    private let makePanel: @MainActor () -> BoostEditorPanel
    private var colorTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?
    private var contentRect = CGRect.zero
    private var panelOffset = CGPoint.zero
    private var inlineOriginal: String?
    private weak var parent: NSWindow?

    public init(host: BoostEditorHost, defaults: UserDefaults = .standard, makePanel: @escaping @MainActor () -> BoostEditorPanel = { BoostEditorPanel(contentRect: CGRect(x: 0,y: 0,width: 316,height: 452),styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false) }) { self.host = host; self.defaults = defaults; self.makePanel = makePanel; super.init() }
    isolated deinit { colorTask?.cancel(); if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }; session?.finish() }
    @discardableResult public func present(parent: NSWindow, contentRect: CGRect, context: SiteControlContext, boostID: BoostID? = nil) -> Bool {
        guard !context.isIncognito else { return false }
        close(); self.parent = parent; self.contentRect = contentRect; panelOffset = .zero
        let store = host.store(for: context.profileID)
        let existing = boostID.flatMap { store.boost(id: $0) }
        if boostID != nil && existing == nil { return false }
        let boost: Boost
        if let existing { boost = existing }
        else {
            var domain = SiteMatch(domain: context.url.host ?? context.displayHost).domain
            if domain.hasPrefix("www.") { domain.removeFirst(4) }
            boost = store.upsert(Boost(name: "My Boost",siteMatch: SiteMatch(domain: domain)))
        }
        let session = BoostEditorSession(context: context,boost: boost,isNew: existing == nil,host: host,defaults: defaults)
        let view = BoostEditorView(session: session)
        let panel = makePanel()
        panel.isReleasedWhenClosed = false; panel.becomesKeyOnlyIfNeeded = true; panel.isFloatingPanel = true
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false; panel.level = .floating
        panel.appearance = parent.contentView?.effectiveAppearance ?? parent.effectiveAppearance; panel.colorSpace = .sRGB
        let root = EditorSurface(view: view); panel.contentView = root
        self.session = session; self.view = view; self.panel = panel
        view.onClose = { [weak self] in self?.close() }
        session.onDelete = { [weak self] in self?.close() }
        view.onResize = { [weak self] height, animated in self?.resize(height: height,animated: animated) }
        view.onRename = { [weak self] in self?.beginInlineRename() }
        view.onHeaderDragEnd = { [weak self] in
            guard let self, let view = self.view else { return }
            self.rememberOffset(); self.resize(height: view.frame.height,animated: false); self.rememberOffset()
        }
        view.makeMenu = { [weak self] in self?.makeMenu() ?? NSMenu() }
        view.onMenu = { [weak self] in self?.onMenu?($0) }
        view.onKey = { [weak self] in self?.handleKey($0) ?? false }
        panel.handleKey = { [weak self] in self?.handleKey($0) ?? false }
        panel.didMove = { [weak self] in self?.rememberOffset() }
        view.nameField.delegate = self
        view.refresh(); parent.addChildWindow(panel,ordered: .above); panel.orderFront(nil)
        panel.makeFirstResponder(view)
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,object: defaults,queue: .main) { [weak view] _ in MainActor.assumeIsolated { view?.refresh() } }
        colorTask = Task { [weak session] in await session?.prepareColors() }
        return true
    }
    public func close() {
        guard let panel else { return }
        if let alert = activeAlert { panel.endSheet(alert.window,returnCode: .cancel); activeAlert = nil }
        colorTask?.cancel(); colorTask = nil
        if inlineOriginal != nil { finishInlineRename() }
        session?.finish(); parent?.removeChildWindow(panel); panel.orderOut(nil); panel.close()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver); self.defaultsObserver = nil }
        self.panel = nil; view = nil; session = nil; onClose?()
    }
    public func boundContextDidChange(tabID: ItemID, profileID: ProfileID) {
        if let session, session.context.tabID != tabID || session.context.profileID != profileID { close() }
    }
    public func pageDidNavigate(tabID: ItemID, url: URL?) { if session?.context.tabID == tabID { session?.updatePageURL(url) } }
    public func boundTabDidClose(_ tabID: ItemID) { if session?.context.tabID == tabID { close() } }
    public func profileDidClose(_ profileID: ProfileID) { if session?.context.profileID == profileID { close() } }
    public func layout(contentRect: CGRect) { self.contentRect = contentRect; if let view { resize(height: view.frame.height,animated: false) } }
    private func rememberOffset() {
        guard let panel, let parent else { return }
        let ideal = parent.convertToScreen(CGRect(x: contentRect.maxX-12-268-24,y: contentRect.maxY-12+24,width: 0,height: 0)).origin
        panelOffset = CGPoint(x: panel.frame.minX-ideal.x,y: panel.frame.maxY-ideal.y)
    }
    private func resize(height: CGFloat, animated: Bool) {
        guard let panel, let parent else { return }
        let pad = BoostEditorMetrics.shadowPadding, h = min(height,max(100,contentRect.height-24))
        let origin = parent.convertToScreen(CGRect(x: contentRect.maxX-12-268-pad,y: contentRect.maxY-12+pad,width: 0,height: 0)).origin
        var rect = CGRect(x: origin.x+panelOffset.x,y: origin.y+panelOffset.y-h-pad*2,width: 268+pad*2,height: h+pad*2)
        let allowed = parent.convertToScreen(contentRect)
        rect.origin.x = min(max(rect.minX,allowed.minX-pad),allowed.maxX-rect.width+pad)
        rect.origin.y = min(max(rect.minY,allowed.minY-pad),allowed.maxY-rect.height+pad)
        panel.setFrame(rect,display: true,animate: false)
        if let surface = panel.contentView as? EditorSurface { surface.contentHeight = height; surface.needsLayout = true }

    }
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let session, let view, let panel else { return false }
        let editing = panel.firstResponder is NSTextView
        if event.keyCode == 53 {
            if inlineOriginal != nil { cancelInlineRename(); return true }
            if editing { panel.makeFirstResponder(view); return true }
            close(); return true
        }
        if editing { return false }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            session.endInteractive()
            if event.modifierFlags.contains(.shift) { session.undoManager.redo() } else { session.undoManager.undo() }; return true
        }
        if event.keyCode == 48 {
            let order = view.focusOrder; guard !order.isEmpty else { return true }
            let i = order.firstIndex { $0 === panel.firstResponder }
            let next = i.map { ($0+(event.modifierFlags.contains(.shift) ? order.count-1 : 1))%order.count } ?? (event.modifierFlags.contains(.shift) ? order.count-1 : 0)
            order[next].scrollToVisible(order[next].bounds); panel.makeFirstResponder(order[next]); return true
        }
        if [123,124].contains(event.keyCode), let b = panel.firstResponder as? SiteControlButton,b.controlID.hasPrefix("editor.tool.") {
            let tools = view.focusOrder.filter { ($0 as? SiteControlButton)?.controlID.hasPrefix("editor.tool.") == true }
            if let i = tools.firstIndex(of: b) { panel.makeFirstResponder(tools[(i+(event.keyCode == 123 ? tools.count-1 : 1))%tools.count]); return true }
        }
        return false
    }
    public func beginInlineRename() {
        guard let view, let session else { return }
        let original = session.boost.name; inlineOriginal = nil; view.nameField.stringValue = original
        view.nameField.isEditable = true; view.nameField.isSelectable = true; view.nameField.target = self; view.nameField.action = #selector(finishInlineRename)
        panel?.makeFirstResponder(view.nameField); view.nameField.selectText(nil)
        inlineOriginal = original
    }
    @objc private func finishInlineRename() {
        guard inlineOriginal != nil, let view else { return }; let name = view.nameField.stringValue
        inlineOriginal = nil; view.nameField.isEditable = false; view.nameField.isSelectable = false; session?.rename(name); panel?.makeFirstResponder(view)
    }
    private func cancelInlineRename() {
        guard let view else { return }; let original = inlineOriginal ?? ""; inlineOriginal = nil; view.nameField.stringValue = original
        view.nameField.isEditable = false; view.nameField.isSelectable = false; panel?.makeFirstResponder(view); view.refresh()
    }
    public func controlTextDidEndEditing(_ obj: Notification) { if inlineOriginal != nil { finishInlineRename() } }
    public func makeMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        guard let session else { return menu }
        for (i,title) in ["Undo","Redo","—","Rename this Boost…","Shuffle","Reset all Edits","All Boosts…","—","Delete this Boost"].enumerated() {
            if title == "—" { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: title,action: #selector(menuAction(_:)),keyEquivalent: i < 2 ? "z" : ""); item.target = self; item.tag = i
            if i == 0 { item.isEnabled = session.undoManager.canUndo }
            if i == 1 { item.isEnabled = session.undoManager.canRedo; item.keyEquivalentModifierMask = [.command,.shift] }
            if i == 5 { item.isEnabled = !session.boost.isEmpty }
            menu.addItem(item)
        }
        return menu
    }
    @objc private func menuAction(_ item: NSMenuItem) {
        guard let session else { return }
        switch item.tag {
        case 0: session.undoManager.undo()
        case 1: session.undoManager.redo()
        case 3: renameSheet()
        case 4: if let font = BoostEditorFonts.available.filter({ $0.name != "Original" && $0.name != "Wingdings" }).randomElement()?.css { session.shuffle(font: font) }
        case 5: confirmation(title: "Reset all edits?",message: "This removes every change in this Boost.",button: "Reset") { [weak session] in session?.resetAll() }
        case 6: session.showAllBoosts()
        case 8: confirmation(title: "Delete this Boost?",message: "This removes the Boost and its changes from this site.",button: "Delete") { [weak session] in session?.delete() }
        default: break
        }
    }
    private func renameSheet() {
        guard let panel,let session else { return }
        let alert = NSAlert(); alert.messageText = "Rename this Boost"; alert.addButton(withTitle: "Done"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: session.boost.name); field.frame = CGRect(x: 0,y: 0,width: 220,height: 24); field.identifier = .init("editor.rename"); field.setAccessibilityLabel("Boost name"); alert.accessoryView = field
        activeAlert = alert
        alert.beginSheetModal(for: panel) { [weak self, weak session] result in if result == .alertFirstButtonReturn { session?.rename(field.stringValue) }; self?.activeAlert = nil }
        alert.window.makeFirstResponder(field); field.selectText(nil)
    }
    private func confirmation(title: String,message: String,button: String,action: @escaping @MainActor () -> Void) {
        guard let panel else { return }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.addButton(withTitle: button); alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true; activeAlert = alert
        alert.beginSheetModal(for: panel) { [weak self] result in if result == .alertFirstButtonReturn { action() }; self?.activeAlert = nil }
    }
}

@MainActor
open class BoostEditorPanel: NSPanel {
    var handleKey: ((NSEvent) -> Bool)?
    var didMove: (() -> Void)?
    open override var canBecomeKey: Bool { true }
    open override func sendEvent(_ event: NSEvent) { if event.type == .keyDown, handleKey?(event) == true { return }; super.sendEvent(event) }
    open override func mouseUp(with event: NSEvent) { super.mouseUp(with: event); didMove?() }
}

@MainActor
private final class EditorSurface: NSView {
    let editor: BoostEditorView
    let scroll = NSScrollView()
    let panelShadow = CALayer()
    var contentHeight: CGFloat = 404
    override var isFlipped: Bool { true }
    init(view: BoostEditorView) {
        editor = view; super.init(frame: .zero); wantsLayer = true
        layer?.addSublayer(panelShadow); panelShadow.shadowColor = NSColor.black.cgColor; panelShadow.shadowOpacity = 0.25; panelShadow.shadowRadius = 16; panelShadow.shadowOffset = CGSize(width: 0,height: 6)
        scroll.drawsBackground = false; scroll.documentView = view; scroll.hasVerticalScroller = false; addSubview(scroll)
        setAccessibilityElement(false)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout(); let rect = bounds.insetBy(dx: 24,dy: 24)
        scroll.frame = rect; editor.frame = CGRect(origin: .zero,size: CGSize(width: 268,height: contentHeight))
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 12; scroll.layer?.cornerCurve = .continuous; scroll.layer?.masksToBounds = true
        panelShadow.frame = bounds; panelShadow.shadowPath = SiteControlShape.path(in: rect,radius: 12)
    }
}
