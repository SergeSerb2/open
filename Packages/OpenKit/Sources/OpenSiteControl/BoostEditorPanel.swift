import AppKit
import OpenDesign
import OpenModel
import OpenBoosts

public struct BoostEditorScreen: Sendable {
    public let frame: CGRect,visibleFrame: CGRect
    public init(frame: CGRect,visibleFrame: CGRect) { self.frame = frame;self.visibleFrame = visibleFrame }
}

/// The shell owns selection/navigation. The library owns the child editor and its session.
@MainActor
public final class BoostEditorController: NSObject {
    public private(set) var session: BoostEditorSession?
    public private(set) var view: BoostEditorView?
    public private(set) var panel: NSPanel?
    public var onClose: (() -> Void)?,onMenu: ((NSMenu)->Void)?
    public private(set) var activeAlert: NSAlert?
    /// Value geometry keeps offscreen harnesses offscreen. App uses native NSScreen values.
    public var screens: () -> [BoostEditorScreen] = { NSScreen.screens.map { BoostEditorScreen(frame: $0.frame,visibleFrame: $0.visibleFrame) } }
    private let host: BoostEditorHost,defaults: UserDefaults
    private let makePanel: @MainActor () -> BoostEditorPanel
    private var colorTask: Task<Void,Never>?
    private var defaultsObserver: NSObjectProtocol?
    private weak var parent: NSWindow?
    private var chosenScreen = CGRect.zero
    private var generation = 0
    private var modeGeneration = 0
    private var simpleFrame: CGRect?
    private var codeSize = BoostEditorMetrics.codeWindow
    public init(host: BoostEditorHost,defaults: UserDefaults = .standard,makePanel: @escaping @MainActor () -> BoostEditorPanel = { BoostEditorPanel(contentRect: CGRect(origin: .zero,size: BoostEditorMetrics.window),styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false) }) { self.host = host;self.defaults = defaults;self.makePanel = makePanel;super.init() }
    isolated deinit { colorTask?.cancel();if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) };session?.finish() }
    @discardableResult public func present(parent: NSWindow,contentRect: CGRect,context: SiteControlContext,boostID: BoostID? = nil) -> Bool {
        guard !context.isIncognito else { return false }
        let store = host.store(for: context.profileID),existing = boostID.flatMap { store.boost(id: $0) }
        let point = CGPoint(x: parent.frame.maxX-1,y: parent.frame.midY)
        guard boostID == nil || existing != nil,let screen = screens().first(where: { $0.frame.contains(point) }) else { return false }
        // Resolve the request before finishing the previous editor.
        close();generation += 1;self.parent = parent;chosenScreen = screen.visibleFrame
        let boost: Boost
        if let existing { boost = existing }
        else { var domain = SiteMatch(domain: context.url.host ?? context.displayHost).domain;if domain.hasPrefix("www.") { domain.removeFirst(4) };boost = store.upsert(Boost(name: "My Boost",siteMatch: SiteMatch(domain: domain))) }
        let session = BoostEditorSession(context: context,boost: boost,isNew: existing == nil,host: host,defaults: defaults),view = BoostEditorView(session: session),panel = makePanel()
        panel.isReleasedWhenClosed = false;panel.becomesKeyOnlyIfNeeded = true;panel.isFloatingPanel = true;panel.level = .floating
        panel.appearance = .init(named: .aqua);panel.backgroundColor = .clear;panel.isOpaque = false;panel.hasShadow = true;panel.colorSpace = .sRGB
        panel.contentView = view;view.autoresizingMask = [.width,.height];view.wantsLayer = true;view.layer?.cornerRadius = 12;view.layer?.cornerCurve = .continuous;view.layer?.masksToBounds = true
        self.session = session;self.view = view;self.panel = panel
        view.onClose = { [weak self] in self?.close(animated: true) };session.onDelete = { [weak self] in self?.close(animated: true) }
        view.onResize = { [weak self] height,_ in self?.resize(height: height) }
        view.makeMenu = { [weak self] in self?.makeMenu() ?? NSMenu() };view.onMenu = { [weak self] in self?.onMenu?($0) };view.onKey = { [weak self] in self?.handleKey($0) ?? false }
        view.screenVisibleFrame = { [weak self] in self?.chosenScreen ?? .zero }
        panel.handleKey = { [weak self] in self?.handleKey($0) ?? false }
        panel.didBecomeKey = { [weak self,weak panel] in guard let self,let panel,self.activeAlert == nil,let view = self.view,!(panel.firstResponder is NSTextView) else { return };view.focus(view.focusOrder.first ?? view) }
        view.onCodeMode = { [weak self] in self?.setCodeMode($0) }
        resize(height: 588);view.refresh();view.layoutSubtreeIfNeeded();parent.addChildWindow(panel,ordered: .above);panel.orderFront(nil);panel.makeFirstResponder(view)
        animateOpen()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,object: defaults,queue: .main) { [weak view] _ in MainActor.assumeIsolated { view?.refresh() } }
        colorTask = Task { [weak session] in await session?.prepareColors() };return true
    }
    public func close(animated: Bool = false, returnFocus: Bool = true) {
        guard let panel else { return }
        generation += 1;modeGeneration += 1
        if let alert = activeAlert { panel.endSheet(alert.window,returnCode: .cancel);activeAlert = nil }
        colorTask?.cancel();colorTask = nil;view?.closeAdvanced();session?.finish()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver);self.defaultsObserver = nil }
        self.panel = nil;view = nil;session = nil
        let finish: @MainActor @Sendable ()->Void = { [weak panel,weak parent] in guard let panel else { return };parent?.removeChildWindow(panel);panel.orderOut(nil);panel.close();if returnFocus && parent?.isVisible == true { parent?.makeKeyAndOrderFront(nil) } }
        if animated { NSAnimationContext.runAnimationGroup { context in context.duration = Motion.boostEditorCloseDuration;panel.animator().alphaValue = 0 } completionHandler: { MainActor.assumeIsolated { finish() } } } else { finish() }
        if returnFocus && parent?.isVisible == true { parent?.makeKeyAndOrderFront(nil) };onClose?()
    }
    public func boundContextDidChange(tabID: ItemID,profileID: ProfileID) { if let session,session.context.tabID != tabID || session.context.profileID != profileID { close() } }
    public func pageDidNavigate(tabID: ItemID,url: URL?) { if session?.context.tabID == tabID { session?.updatePageURL(url) } }
    public func boundPageDidCommit(tabID: ItemID) { if session?.context.tabID == tabID { session?.boundPageDidCommit() } }
    public func boundTabDidClose(_ id: ItemID) { if session?.context.tabID == id { close() } }
    public func profileDidClose(_ id: ProfileID) { if session?.context.profileID == id { close() } }
    public func layout(contentRect: CGRect) { if let view { resize(height: view.frame.height) } }
    /// OEApplication offers Command keys to the browser before NSPanel.sendEvent.
    /// Keep the editor's private undo stack ahead of the page's edit commands.
    @discardableResult public func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let panel, event.window === panel, panel.isKeyWindow else { return false }
        return handleKey(event)
    }
    private func resize(height: CGFloat) {
        guard let panel,let parent else { return }
        if view?.isCodeMode == true { return }
        let visible = chosenScreen.insetBy(dx: 8,dy: 8),w: CGFloat = 183,h = min(height,visible.height)
        let ideal = CGRect(x: parent.frame.maxX-w/2,y: parent.frame.maxY-160-h,width: w,height: h)
        let frame = CGRect(x: min(max(ideal.minX,visible.minX),visible.maxX-w),y: min(max(ideal.minY,visible.minY),visible.maxY-h),width: w,height: h)
        panel.setFrame(frame,display: true);view?.frame = CGRect(origin: .zero,size: frame.size)
    }
    public func setCodeMode(_ enabled: Bool,animated: Bool = true) {
        guard let panel,let view,view.isCodeMode != enabled else { return }
        modeGeneration += 1;let token = modeGeneration
        let wasEditing = panel.firstResponder is NSTextView
        view.pad.finishKeyboardGesture();session?.endInteractive();session?.flushCode()
        if enabled {
            simpleFrame = panel.frame
            codeSize = BoostEditorMetrics.codeWindow
            let raw = defaults.string(forKey: "open.boosts.codeEditorSize") ?? "480x588"
            let parts = raw.utf8.count <= 64 ? raw.split(separator: "x",maxSplits: 2,omittingEmptySubsequences: false) : []
            if parts.count == 2,let w = Double(parts[0]),let h = Double(parts[1]),w.isFinite,h.isFinite,w>0,h>0 { codeSize = CGSize(width: w,height: h) }
        }
        let visible = chosenScreen.insetBy(dx: BoostEditorMetrics.screenMargin,dy: BoostEditorMetrics.screenMargin)
        let size = enabled ? CGSize(width: min(max(codeSize.width,BoostEditorMetrics.codeMinimum.width),visible.width),height: min(max(codeSize.height,BoostEditorMetrics.codeMinimum.height),visible.height)) : (simpleFrame?.size ?? BoostEditorMetrics.window)
        let right = min(max(panel.frame.maxX,visible.minX+size.width),visible.maxX)
        let top = min(max(panel.frame.maxY,visible.minY+size.height),visible.maxY)
        let target = CGRect(x: right-size.width,y: top-size.height,width: size.width,height: size.height)
        let install: @MainActor ()->Void = { [weak self,weak view] in
            guard let self,let view,self.modeGeneration == token else { return }
            view.setCodeMode(enabled)
            view.codeView?.onResize = { [weak self] in self?.resizeCode(to: $0,persist: $1) }
            if !enabled { panel.makeFirstResponder(view);if !wasEditing { self.parent?.makeKeyAndOrderFront(nil) } }
            view.needsLayout = true;view.layoutSubtreeIfNeeded()
        }
        guard animated else { install();panel.setFrame(target,display: true);view.frame = CGRect(origin: .zero,size: target.size);view.alphaValue = 1;return }
        // A new transition starts at the current native frame and presentation opacity.
        let alpha = view.layer?.presentation()?.opacity ?? Float(view.alphaValue)
        view.layer?.removeAllAnimations();view.alphaValue = CGFloat(alpha)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = BoostEditorMetrics.codeFadeOut;view.animator().alphaValue = 0
        } completionHandler: { MainActor.assumeIsolated {
            guard self.modeGeneration == token else { return };install()
            NSAnimationContext.runAnimationGroup { context in context.duration = BoostEditorMetrics.codeFadeIn;view.animator().alphaValue = 1 }
        } }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.codeModeResize;context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { panel.setFrame(target,display: true) }
            else { panel.animator().setFrame(target,display: true) }
        }
    }
    public func resizeCode(to proposed: CGSize,persist: Bool) {
        guard let panel,view?.isCodeMode == true,proposed.width.isFinite,proposed.height.isFinite else { return }
        let visible = chosenScreen.insetBy(dx: BoostEditorMetrics.screenMargin,dy: BoostEditorMetrics.screenMargin)
        let w = min(max(BoostEditorMetrics.codeMinimum.width,proposed.width),panel.frame.maxX-visible.minX)
        let h = min(max(BoostEditorMetrics.codeMinimum.height,proposed.height),panel.frame.maxY-visible.minY)
        codeSize = CGSize(width: w,height: h)
        panel.setFrame(CGRect(x: panel.frame.maxX-w,y: panel.frame.maxY-h,width: w,height: h),display: true)
        view?.frame = CGRect(origin: .zero,size: codeSize);view?.needsLayout = true
        if persist { defaults.set("\(Int(w.rounded()))x\(Int(h.rounded()))",forKey: "open.boosts.codeEditorSize") }
    }
    private func animateOpen() {
        guard let panel,let layer = view?.layer else { return }
        let opacity = CABasicAnimation(keyPath: "opacity");opacity.fromValue = 0;opacity.toValue = 1;opacity.duration = Motion.boostEditorOpenDuration;layer.add(opacity,forKey: "editor.open.opacity")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { let scale = CABasicAnimation(keyPath: "transform.scale");scale.fromValue = 0.97;scale.toValue = 1;scale.duration = Motion.boostEditorOpenDuration;scale.timingFunction = Motion.easeOut;layer.add(scale,forKey: "editor.open.scale") }
        panel.alphaValue = 1
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let panel,let view,let session else { return false }
        let editing = panel.firstResponder is NSTextView
        if event.keyCode == 53 {
            if editing { panel.makeFirstResponder(view);return true }
            if view.advanced { view.closeAdvanced();return true }
            if view.isCodeMode { setCodeMode(false);return true }
            // C12-D2-3: Escape leaves the main My Boost editor open; Done closes it.
            return true
        }
        if view.isCodeMode,event.modifierFlags.contains(.command),event.charactersIgnoringModifiers?.lowercased() == "r" { session.refreshToRun();return true }
        if view.isCodeMode,event.modifierFlags.contains(.command),let key = event.charactersIgnoringModifiers,["1","2"].contains(key) { view.codeView?.select(key == "1" ? .css : .js);return true }
        if editing { return false }
        if event.modifierFlags.contains(.command),event.charactersIgnoringModifiers?.lowercased() == "z" { view.pad.finishKeyboardGesture();session.endInteractive();if event.modifierFlags.contains(.shift) { session.undoManager.redo() } else { session.undoManager.undo() };return true }
        if event.keyCode == 48 {
            let order = view.focusOrder;guard !order.isEmpty else { return false }
            let i = order.firstIndex { $0 === panel.firstResponder },step = event.modifierFlags.contains(.shift) ? order.count-1 : 1
            view.focus(order[i.map { ($0+step)%order.count } ?? (event.modifierFlags.contains(.shift) ? order.count-1 : 0)]);return true
        };return false
    }
    public func makeMenu() -> NSMenu {
        let menu = NSMenu();menu.autoenablesItems = false;guard let session,let view else { return menu }
        for (id,title) in [(0,"Rename this Boost…"),(1,"Shuffle"),(2,"Reset all Edits"),(3,"Delete this Boost"),(4,"—"),(5,"All Boosts…"),(6,"—"),(7,"Apply to")] {
            if title == "—" { menu.addItem(.separator());continue }
            let item = NSMenuItem(title: title,action: id == 7 ? nil : #selector(menuAction(_:)),keyEquivalent: "");item.target = self;item.tag = id
            if id == 1 { item.isEnabled = session.colorsReady };if id == 2 { item.isEnabled = !session.boost.isEmpty };if id == 7 { item.submenu = view.scopeMenu() };menu.addItem(item)
        };return menu
    }
    @objc private func menuAction(_ item: NSMenuItem) {
        guard item.isEnabled,let session else { return }
        switch item.tag {
        case 0: renameSheet()
        case 1: if let font = BoostEditorFonts.available.filter({ $0.enabled && $0.name != "Wingdings" }).randomElement() { session.shuffle(font: font.css) }
        case 2: confirmation(title: "Reset all edits?",message: "This removes every change in this Boost.",button: "Reset") { [weak session] in session?.resetAll() }
        case 3: confirmation(title: "Delete this Boost?",message: "This can't be undone.",button: "Delete") { [weak session] in session?.delete() }
        case 5: session.showAllBoosts()
        default:break
        }
    }
    private func renameSheet() {
        guard let panel,let session else { return }
        let alert = NSAlert();alert.messageText = "Rename this Boost";alert.addButton(withTitle: "Done");alert.addButton(withTitle: "Cancel")
        let field = EditorNameField(string: session.boost.name);field.frame = CGRect(x: 0,y: 0,width: 220,height: 24);field.identifier = .init("editor.rename");field.setAccessibilityLabel("Boost name");alert.accessoryView = field
        activeAlert = alert;alert.beginSheetModal(for: panel) { [weak self,weak session] response in if response == .alertFirstButtonReturn { session?.rename(field.stringValue) };self?.activeAlert = nil }
        alert.window.makeFirstResponder(field);field.selectText(nil)
    }
    private func confirmation(title: String,message: String,button: String,action: @escaping @MainActor ()->Void) {
        guard let panel else { return }
        let alert = NSAlert();alert.messageText = title;alert.informativeText = message;alert.addButton(withTitle: button);alert.addButton(withTitle: "Cancel");alert.buttons.first?.hasDestructiveAction = true
        activeAlert = alert;alert.beginSheetModal(for: panel) { [weak self] response in if response == .alertFirstButtonReturn { action() };self?.activeAlert = nil }
    }
}

@MainActor private final class EditorNameField: NSTextField { override var needsPanelToBecomeKey: Bool { true } }
@MainActor
open class BoostEditorPanel: NSPanel {
    var handleKey: ((NSEvent)->Bool)?,didBecomeKey: (() -> Void)?
    open override var canBecomeKey: Bool { true }
    open override func becomeKey() { super.becomeKey();didBecomeKey?() }
    open override func sendEvent(_ event: NSEvent) { if event.type == .keyDown,handleKey?(event) == true { return };super.sendEvent(event) }
}
