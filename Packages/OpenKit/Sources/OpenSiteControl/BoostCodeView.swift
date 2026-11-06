import AppKit
import OpenDesign

/// Constructed only when Code is opened; simple-mode launch keeps its native tree unchanged.
@MainActor public final class BoostCodeView: NSView {
    public let session: BoostEditorSession
    public private(set) var language: BoostCodeLanguage = .css
    public var onBack: (() -> Void)?
    public var onResize: ((CGSize,Bool)->Void)?
    public var onKey: ((NSEvent)->Bool)?
    public private(set) var controls: [SiteControlButton] = []
    private var editors: [BoostCodeLanguage: CodeEditorView] = [:]
    private var scrolls: [BoostCodeLanguage: NSScrollView] = [:]
    private var laidOut: Set<BoostCodeLanguage> = []
    private let notice = NSTextField(wrappingLabelWithString: "JavaScript in a Boost runs on this site like the site's own code.")
    public var editor: CodeEditorView { editors[language]! }
    public var showsRefreshToRun: Bool { language == .js && session.needsJSReload }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public init(session: BoostEditorSession) {
        self.session = session;super.init(frame: .zero);wantsLayer = true;layer?.backgroundColor = NSColor.white.cgColor
        setAccessibilityElement(false);setAccessibilityLabel("Boost code editor")
        add("editor.code.back","Back","arrow.left",.codeBack) { [weak self] in self?.onBack?() }
        add("editor.code.css","CSS","",.codeSegment) { [weak self] in self?.select(.css) }
        add("editor.code.js","JS","",.codeSegment) { [weak self] in self?.select(.js) }
        add("editor.code.pick","Pick Selector","eyedropper",.color) {}
        control("editor.code.pick")?.isEnabled = false
        add("editor.code.devtools","Show Developer Tools","hammer",.color) { [weak session] in session?.toggleDevTools() }
        add("editor.code.run","Refresh to Run","",.codeRun) { [weak session] in session?.refreshToRun() }
        add("editor.code.dismissNotice","Dismiss JavaScript notice","xmark",.header) { [weak session] in session?.dismissJSNotice() }
        notice.font = .systemFont(ofSize: BoostEditorMetrics.gutterFont);notice.textColor = BoostEditorColors.label.nsColor;addSubview(notice)
        for kind in [BoostCodeLanguage.css,.js] {
            let text = CodeEditorView(),scroll = NSScrollView()
            scroll.wantsLayer = true;scroll.layer?.masksToBounds = true
            scroll.hasVerticalScroller = true;scroll.autohidesScrollers = true;scroll.drawsBackground = true;scroll.backgroundColor = .white
            scroll.documentView = text;scroll.hasVerticalRuler = true;scroll.rulersVisible = true;scroll.verticalRulerView = CodeLineRuler(scrollView: scroll,editor: text)
            text.onEdit = { [weak session] in session?.editCode($0,language: kind) }
            text.onEndEditing = { [weak session] in session?.endCodeEditing(kind) }
            text.load(session.code(kind),language: kind)
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self,selector: #selector(scrolled(_:)),name: NSView.boundsDidChangeNotification,object: scroll.contentView)
            editors[kind] = text;scrolls[kind] = scroll;addSubview(scroll)
        }
        for edge in [CodeResizeStrip.Edge.left,.bottom] {
            let strip = CodeResizeStrip(edge: edge);strip.onResize = { [weak self] size,end in self?.onResize?(size,end) };addSubview(strip)
        }
        refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public func control(_ id: String) -> SiteControlButton? { controls.first { $0.controlID == id } }
    public var focusOrder: [NSView] { controls.filter { !$0.isHidden && $0.isEnabled }.map { $0 as NSView } }
    public func select(_ language: BoostCodeLanguage) {
        guard self.language != language else { return }
        let editing = window?.firstResponder is CodeEditorView
        session.flushCode();self.language = language;refresh();layoutSubtreeIfNeeded()
        if editing { window?.makeFirstResponder(editor) }
    }
    public func refresh() {
        for (kind,text) in editors { if text.string != session.code(kind) { text.load(session.code(kind),language: kind) };scrolls[kind]?.isHidden = kind != language }
        for kind in [BoostCodeLanguage.css,.js] { let b = control("editor.code."+kind.rawValue) as? EditorButton;b?.selected = language == kind;b?.setAccessibilityValue(language == kind) }
        control("editor.code.run")?.isHidden = !showsRefreshToRun
        (control("editor.code.devtools") as? EditorButton)?.selected = session.devToolsVisible
        let showsNotice = language == .js && session.showsJSNotice
        notice.isHidden = !showsNotice;control("editor.code.dismissNotice")?.isHidden = !showsNotice
        needsLayout = true;needsDisplay = true
    }
    private func add(_ id: String,_ title: String,_ symbol: String,_ kind: EditorButton.Kind,_ action: @escaping ()->Void) {
        let b = EditorButton(id: id,label: title,symbol: symbol,pointSize: BoostEditorMetrics.codeButtonGlyph)
        b.caption = title;b.kind = kind;b.invoke = action;b.tooltipTitle = title;b.onKey = { [weak self] in self?.onKey?($0) ?? false }
        controls.append(b);addSubview(b)
    }
    public override func layout() {
        super.layout();let m = BoostEditorMetrics.self,w = bounds.width,h = bounds.height,noticeHeight = notice.isHidden ? 0 : m.codeNoticeHeight
        control("editor.code.back")?.frame = m.back
        for (i,kind) in [BoostCodeLanguage.css,.js].enumerated() { control("editor.code."+kind.rawValue)?.frame = CGRect(x: w/2-m.segment.width+CGFloat(i)*m.segment.width,y: m.codeSegmentTop,width: m.segment.width,height: m.segment.height) }
        for (kind,scroll) in scrolls {
            scroll.frame = CGRect(x: 0,y: m.codeHeader,width: w,height: h-m.codeHeader-m.codeBottomBar-noticeHeight)
            scroll.tile()
            if let text = scroll.documentView as? CodeEditorView {
                text.setFrameSize(CGSize(width: scroll.contentView.bounds.width,height: max(text.frame.height,scroll.contentView.bounds.height)))
                if !laidOut.contains(kind) {
                    // Loading before a viewport exists can leave the empty document
                    // scrolled above its clip. Establish the native viewport first.
                    scroll.contentView.scroll(to: .zero);text.scrollRangeToVisible(text.selectedRange());scroll.reflectScrolledClipView(scroll.contentView);laidOut.insert(kind)
                }
            }
        }
        for (i,id) in ["pick","devtools"].enumerated() { control("editor.code."+id)?.frame = CGRect(x: m.codeBarInset+CGFloat(i)*(m.codeButton+m.codeBarGap),y: h-m.codeBottomBar+m.codeBarTop,width: m.codeButton,height: m.codeButton) }
        let width = ("Refresh to Run" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: m.codeControlFont,weight: .medium)]).width
        control("editor.code.run")?.frame = CGRect(x: w-m.codeBarInset-width,y: h-m.codeBottomBar+m.codeBarTop,width: width,height: m.codeButton)
        notice.frame = CGRect(x: m.codeBarInset,y: h-m.codeBottomBar-noticeHeight+m.codeNoticeInset,width: w-2*m.codeBarInset-m.codeNoticeHeight,height: noticeHeight-m.codeNoticeInset)
        control("editor.code.dismissNotice")?.frame = CGRect(x: w-m.codeNoticeHeight,y: h-m.codeBottomBar-noticeHeight,width: m.codeNoticeHeight,height: m.codeNoticeHeight)
        for strip in subviews.compactMap({ $0 as? CodeResizeStrip }) { strip.frame = strip.edge == .left ? CGRect(x: 0,y: m.codeHeader,width: m.codeResizeStrip,height: h-m.codeHeader) : CGRect(x: 0,y: h-m.codeResizeStrip,width: w,height: m.codeResizeStrip) }
    }
    public override func draw(_ dirtyRect: NSRect) {
        BoostEditorColors.header.nsColor.setFill();CGRect(x: 0,y: 0,width: bounds.width,height: BoostEditorMetrics.codeHeader).fill()
        BoostEditorColors.hairline.nsColor.setFill();CGRect(x: 0,y: BoostEditorMetrics.codeHeader-1,width: bounds.width,height: 1).fill()
    }
    public override func mouseDown(with event: NSEvent) { if convert(event.locationInWindow,from: nil).y<BoostEditorMetrics.codeHeader { window?.performDrag(with: event) } }
    @objc private func scrolled(_ notification: Notification) { editor.highlightVisible();scrolls[language]?.verticalRulerView?.needsDisplay = true }
}

/// Native tracking consumes only the owning panel's synthetic or real event stream.
@MainActor private final class CodeResizeStrip: NSView {
    enum Edge { case left,bottom }
    let edge: Edge
    var onResize: ((CGSize,Bool)->Void)?
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(edge: Edge) { self.edge = edge;super.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds,cursor: edge == .left ? .resizeLeftRight : .resizeUpDown) }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = window.convertPoint(toScreen: event.locationInWindow),size = window.frame.size
        while let next = window.nextEvent(matching: [.leftMouseDragged,.leftMouseUp]) {
            let point = window.convertPoint(toScreen: next.locationInWindow)
            let target = CGSize(width: size.width+(edge == .left ? start.x-point.x : 0),height: size.height+(edge == .bottom ? start.y-point.y : 0))
            onResize?(target,next.type == .leftMouseUp)
            if next.type == .leftMouseUp { break }
        }
    }
}
