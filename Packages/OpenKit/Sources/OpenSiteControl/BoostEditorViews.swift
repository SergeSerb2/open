import AppKit
import CoreText
import OpenDesign
import OpenBoosts

@MainActor
public enum BoostEditorFonts {
    public struct Item: Sendable { public let name: String; public let css: String; public let family: String?; public let enabled: Bool }
    public static let available: [Item] = {
        let families = [("Helvetica Neue","sans-serif"),("Avenir","sans-serif"),("Futura","sans-serif"),("DIN Alternate","sans-serif"),("Arial Rounded MT Bold","sans-serif"),("PT Mono","monospace"),("Courier","monospace"),("Times New Roman","serif"),("Charter","serif"),("Baskerville","serif"),("Hoefler Text","serif"),("Palatino","serif"),("Chalkboard","cursive"),("SignPainter","cursive"),("Snell Roundhand","cursive"),("Papyrus","fantasy"),("Apple Chancery","cursive"),("Luminari","fantasy"),("Wingdings","fantasy")]
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return [Item(name: "System",css: "system-ui, -apple-system, sans-serif",family: nil,enabled: true)]+families.map { family,generic in
            Item(name: family,css: family+", "+generic,family: family,enabled: installed.contains(family) || NSFont(name: family,size: 14) != nil)
        }
    }()
}

@MainActor
enum EditorRaster {
    static func lines(_ text: String,width: CGFloat,font: NSFont) -> [String] {
        let source = text as NSString,typesetter = CTTypesetterCreateWithAttributedString(NSAttributedString(string: text,attributes: [.font: font]))
        var result: [String] = [],start = 0
        while start<source.length { let count = max(1,CTTypesetterSuggestLineBreak(typesetter,start,Double(width))); result.append(source.substring(with: NSRange(location: start,length: count)).trimmingCharacters(in: .whitespaces)); start += count }
        return result
    }
    static func display(_ view: NSView,draw: () -> Void) {
        let scale = view.window?.backingScaleFactor ?? 1,size = view.bounds.size
        guard size.width>0,size.height>0,let context = CGContext(data: nil,width: Int(ceil(size.width*scale)),height: Int(ceil(size.height*scale)),bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale,y: scale); context.translateBy(x: 0,y: size.height); context.scaleBy(x: 1,y: -1)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context,flipped: true); draw(); NSGraphicsContext.restoreGraphicsState()
        CATransaction.begin(); CATransaction.setDisableActions(true); view.layer?.contents = context.makeImage(); view.layer?.contentsScale = scale; CATransaction.commit()
    }
    static func glyph(_ name: String,in rect: CGRect,size: CGFloat,color: NSColor,weight: NSFont.Weight = .regular) {
        let c = NSGraphicsContext.current!.cgContext,scale = hypot(c.ctm.a,c.ctm.b)
        guard let value = SiteControlGlyphRenderer.symbol(name,size: size,weight: weight,color: color,sparkles: .none,scale: scale) else { return }
        let frame = CGRect(x: rect.midX-value.ink.width/2-value.ink.minX,y: rect.midY-value.ink.height/2-value.ink.minY,width: value.size.width,height: value.size.height)
        NSImage(cgImage: value.image,size: value.size).draw(in: frame,from: .zero,operation: .sourceOver,fraction: 1,respectFlipped: true,hints: nil)
    }
}

@MainActor
final class EditorButton: SiteControlButton {
    enum Kind { case header,name,color,font,row,half,primary,secondary }
    var kind = Kind.color
    var selected = false { didSet { if oldValue != selected { fadeSelection = true; needsDisplay = true } } }
    var caption = "" { didSet { if oldValue != caption { needsDisplay = true } } }
    var fontFamily: String?
    var secondaryClick: (() -> Void)?
    var activationModifiers: NSEvent.ModifierFlags = []
    private var pressed = false,hovered = false,fadeSelection = false
    private let focus = CAShapeLayer()
    override var needsPanelToBecomeKey: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func mouseEntered(with event: NSEvent) { hovered = true; super.mouseEntered(with: event); if kind == .font { needsDisplay = true } }
    override func mouseExited(with event: NSEvent) { hovered = false; super.mouseExited(with: event); if kind == .font { needsDisplay = true } }
    override func mouseDown(with event: NSEvent) { guard isEnabled else { return }; pressed = true; super.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { pressed = false; activationModifiers = event.modifierFlags; super.mouseUp(with: event) }
    override func keyDown(with event: NSEvent) { activationModifiers = event.modifierFlags; super.keyDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { if isEnabled { secondaryClick?() } }
    override func updateLayer() {
        let previous = layer?.contents
        EditorRaster.display(self) { paint() }
        if fadeSelection,let previous { let a = CABasicAnimation(keyPath: "contents"); a.fromValue = previous; a.toValue = layer?.contents; a.duration = Motion.selectionFade; layer?.add(a,forKey: "selection") }; fadeSelection = false
        if focus.superlayer == nil { layer?.addSublayer(focus) }
        let rect = bounds.insetBy(dx: -2,dy: -2),radius: CGFloat = kind == .font || kind == .header ? rect.height/2 : kind == .name ? 6 : 11
        CATransaction.begin(); CATransaction.setDisableActions(true)
        focus.frame = bounds; focus.path = CGPath(roundedRect: rect,cornerWidth: radius,cornerHeight: radius,transform: nil); focus.fillColor = nil; focus.lineWidth = 2
        focus.strokeColor = showsKeyboardFocus && window?.firstResponder === self ? Core.focusRing.cgColor(.light) : nil; CATransaction.commit()
    }
    private func paint() {
        let m = BoostEditorColors.self
        var color = isEnabled ? m.label.nsColor : m.disabledGlyph.nsColor
        let r: CGFloat = kind == .font ? 13 : kind == .primary ? 10 : 9
        var fill: NSColor?
        switch kind {
        case .header: color = (controlID == "editor.undo" && isEnabled ? RGBA(hex: 0x6E6E70) : m.headerGlyph).nsColor
        case .name: color = m.title.nsColor
        case .font:
            color = (selected ? m.fontSelectedGlyph : m.fontGlyph).nsColor.withAlphaComponent(isEnabled ? 1 : 0.3)
            fill = selected || pressed ? m.fontSelected.nsColor : hovered ? NSColor(white: 236/255,alpha: 1) : nil
        case .primary: fill = m.makeABoost.top.nsColor; color = .white
        case .secondary: color = m.maybeLater.nsColor
        default: fill = selected ? (controlID == "editor.color.advanced" ? m.advancedOn : m.buttonOn).nsColor : (pressed ? m.buttonPressed : m.button).nsColor; if selected { color = .white }
        }
        if let fill {
            fill.setFill(); let path = NSBezierPath(roundedRect: bounds,xRadius: r,yRadius: r); path.fill()
            if kind == .primary {
                NSGraphicsContext.saveGraphicsState(); path.addClip()
                let gradient = NSGradient(colorsAndLocations: (m.makeABoost.top.nsColor,0),(NSColor(srgbRed: 72/255,green: 72/255,blue: 1,alpha: 1),0.2),(m.makeABoost.bottom.nsColor,1))!
                gradient.draw(in: bounds,angle: 90); NSGraphicsContext.restoreGraphicsState()
            }
        }
        if kind == .font {
            let font = fontFamily.flatMap { NSFont(name: $0,size: 14) ?? NSFontManager.shared.font(withFamily: $0,traits: [],weight: 5,size: 14) } ?? .systemFont(ofSize: 14)
            SiteControlDrawing.text("Aa",x: 0,baseline: 18,width: bounds.width,font: font,color: color,alignment: .center); return
        }
        if kind == .name {
            let font = Typography.editorName.font,chevron: CGFloat = 11,gap: CGFloat = caption.isEmpty ? 0 : 11
            let width = min(max(0,bounds.width-chevron-gap),(caption as NSString).size(withAttributes: [.font: font]).width)
            let x = (bounds.width-width-gap-chevron)/2
            SiteControlDrawing.text(caption,x: x,baseline: 16,width: width,font: font,color: color)
            EditorRaster.glyph("chevron.down",in: CGRect(x: x+width+gap,y: 0,width: chevron,height: bounds.height),size: 12,color: m.chevron.nsColor); return
        }
        if kind == .row {
            SiteControlDrawing.text(caption,x: 12,baseline: 24,width: bounds.width-48,font: Typography.editorButton.font,color: color)
            if controlID == "editor.tool.zap",let count = accessibilityValue() as? Int,count>0 { SiteControlDrawing.text(String(count),x: bounds.width-43,baseline: 24,width: 28,font: Typography.editorButton.font,color: color,alignment: .right) }
            else { EditorRaster.glyph(symbol,in: CGRect(x: bounds.width-36,y: 0,width: 21,height: bounds.height),size: 15,color: color) }; return
        }
        if !symbol.isEmpty { EditorRaster.glyph(symbol,in: bounds,size: controlID == "editor.done" ? 16 : 17,color: color) }
        else { let font = kind == .secondary ? Typography.firstRunSecondary.font : Typography.editorButton.font; SiteControlDrawing.text(caption,x: 0,baseline: (bounds.height+font.capHeight)/2,width: bounds.width,font: font,color: color,alignment: .center) }
    }
}

@MainActor
public final class BoostEditorView: NSView {
    public let session: BoostEditorSession
    public let pad: BoostColorPadView
    public private(set) var controls: [SiteControlButton] = []
    public var onResize: ((CGFloat,Bool)->Void)?,onClose: (() -> Void)?,onMenu: ((NSMenu)->Void)?,onKey: ((NSEvent)->Bool)?
    public var makeMenu: (() -> NSMenu)?
    public var screenVisibleFrame: (() -> CGRect)?
    public private(set) var advancedPopover: BoostAdvancedPopover?
    public var advanced: Bool { advancedPopover?.isPresented == true }
    private let fontCard = NSView(),firstRun: EditorInterstitial
    private var fontButtons: [EditorButton] = []
    private var banners: [String] = []
    private var bannerSizes: [CGFloat] = []
    private var lastInterstitial: Bool?
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() { EditorRaster.display(self) { paint() } }
    public init(session: BoostEditorSession) {
        self.session = session; pad = BoostColorPadView(session: session); firstRun = EditorInterstitial(host: session.context.displayHost)
        super.init(frame: .zero); wantsLayer = true; appearance = .init(named: .aqua)
        setAccessibilityElement(false); setAccessibilityLabel("Boost editor")
        addSubview(pad); addSubview(fontCard); fontCard.wantsLayer = true
        fontCard.layer?.backgroundColor = NSColor.white.cgColor; fontCard.layer?.cornerRadius = 11
        fontCard.layer?.shadowColor = NSColor.black.cgColor; fontCard.layer?.shadowOpacity = 0.06; fontCard.layer?.shadowRadius = 8; fontCard.layer?.shadowOffset = CGSize(width: 0,height: 1)
        fontCard.setAccessibilityElement(true); fontCard.setAccessibilityRole(.init(rawValue: "AXGrid")); fontCard.setAccessibilityLabel("Fonts")
        button("editor.done","Done","xmark.circle.fill",.header) { [weak self] in self?.onClose?() }
        button("editor.name",session.boost.name,"",.name) { [weak self] in self?.showNameMenu() }; control(id: "editor.name")?.setAccessibilityRole(.menuButton)
        button("editor.undo","Undo","arrow.counterclockwise",.header) { [weak session] in session?.endInteractive(); session?.undoManager.undo() }
        button("editor.color.invert","Invert lightness","lightbulb",.color) { [weak session] in session?.editWheel { $0.invertLightness.toggle() } }
        button("editor.color.advanced","Advanced color controls","slider.horizontal.3",.color) { [weak self] in self?.toggleAdvanced() }
        button("editor.color.reset","Reset to original colors","nosign",.color) { [weak self] in guard let self else { return }; self.session.resetColors(); self.pad.refresh(animatedReset: true) }
        for (i,item) in BoostEditorFonts.available.enumerated() {
            let b = EditorButton(id: "editor.font.\(i)",label: item.name,symbol: "",pointSize: 14); b.kind = .font; b.fontFamily = item.family; b.isEnabled = item.enabled; b.tooltipTitle = item.name
            b.invoke = { [weak session] in guard let session else { return }; session.setFont(session.boost.fontFamily == item.css ? nil : item.css) }
            b.onKey = { [weak self,weak b] in self?.navigateFonts($0,current: b) ?? false }; fontCard.addSubview(b); fontButtons.append(b)
        }
        button("editor.tool.size","Change text size","",.half) { [weak self] in guard let self else { return }; self.session.cycleTextSize(backwards: (self.control(id: "editor.tool.size") as? EditorButton)?.activationModifiers.contains(.shift) == true) }
        button("editor.tool.case","Change text case","",.half) { [weak self] in guard let self else { return }; self.session.cycleTextCase(backwards: (self.control(id: "editor.tool.case") as? EditorButton)?.activationModifiers.contains(.shift) == true) }
        button("editor.tool.zap","Zap","bolt.fill",.row) {}; button("editor.tool.code","Code","curlybraces",.row) {}
        for id in ["zap","code"] {
            // Blocked on P7: isolated world; App and the engine own the hook.
            let b = control(id: "editor.tool."+id)!; b.isEnabled = false; b.tooltipTitle = id == "zap" ? "Zap isn’t available yet." : "Code editing isn’t available yet."
        }
        for size in [true,false] { (control(id: "editor.tool."+(size ? "size" : "case")) as? EditorButton)?.secondaryClick = { [weak self] in self?.showTextMenu(size: size) } }
        addSubview(firstRun); firstRun.make.invoke = { [weak session] in session?.dismissInterstitial() }; firstRun.later.invoke = { [weak self] in self?.onClose?() }
        session.onChange = { [weak self] in self?.refresh() }; pad.onKey = { [weak self] in self?.onKey?($0) ?? false }; refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public var focusOrder: [NSView] {
        if session.showsInterstitial { return [firstRun.make,firstRun.later] }
        let ids = ["editor.done","editor.name","editor.undo"]
        return ids.compactMap { control(id: $0) }.filter(\.isEnabled)+(pad.acceptsFirstResponder ? [pad] : [])+["invert","advanced","reset"].compactMap { control(id: "editor.color."+$0) }.filter(\.isEnabled)+fontButtons.filter(\.isEnabled)+["size","case","zap","code"].compactMap { control(id: "editor.tool."+$0) }.filter(\.isEnabled)
    }
    public func control(id: String) -> SiteControlButton? { (controls+fontButtons+[firstRun.make,firstRun.later]).first { $0.controlID == id } }
    private func button(_ id: String,_ label: String,_ symbol: String,_ kind: EditorButton.Kind,_ invoke: @escaping ()->Void) {
        let b = EditorButton(id: id,label: label,symbol: symbol,pointSize: 17); b.kind = kind; b.caption = label; b.invoke = invoke; b.tooltipTitle = label
        b.onKey = { [weak self] in self?.onKey?($0) ?? false }; controls.append(b); addSubview(b)
    }
    public func refresh(animated: Bool = false) {
        pad.refresh(); advancedPopover?.refresh()
        let wheel = session.displayWheel
        for id in ["invert","advanced","reset"] {
            let b = control(id: "editor.color."+id) as! EditorButton
            let enabled = session.colorsReady && (id != "reset" || session.boost.colorAdjustment != nil || session.boost.colorWheel != nil)
            if b.isEnabled != enabled { b.isEnabled = enabled }
            b.selected = id == "invert" ? wheel.invertLightness : id == "advanced" && advanced
            if id == "invert" { let glyph = wheel.invertLightness ? "lightbulb.fill" : "lightbulb";if b.symbol != glyph { b.symbol = glyph } }
        }
        if session.isInteracting { return }
        let name = control(id: "editor.name") as! EditorButton; name.caption = session.boost.name; name.setAccessibilityLabel(session.boost.name.isEmpty ? "Boost name" : session.boost.name)
        control(id: "editor.undo")?.isEnabled = session.undoManager.canUndo
        for (i,b) in fontButtons.enumerated() { b.selected = session.boost.fontFamily == BoostEditorFonts.available[i].css }
        (control(id: "editor.tool.size") as? EditorButton)?.caption = "Size"; (control(id: "editor.tool.case") as? EditorButton)?.caption = "Case"
        control(id: "editor.tool.size")?.setAccessibilityValue(BoostEditorSession.textSizeNames[session.textSizeIndex]); control(id: "editor.tool.case")?.setAccessibilityValue(BoostEditorSession.textCaseNames[session.textCaseIndex])
        (control(id: "editor.tool.zap") as? EditorButton)?.caption = "Zap"; (control(id: "editor.tool.code") as? EditorButton)?.caption = "Code"
        control(id: "editor.tool.zap")?.setAccessibilityValue(session.boost.zaps.count)
        let next = [session.isActiveOnPage ? "" : "This Boost doesn't apply to \(session.pageURL.host ?? "this page").",session.globallyEnabled ? "" : "Boosts are off. Changes show when you turn Boosts on in Settings."].filter { !$0.isEmpty }
        if next != banners { banners = next; bannerSizes = next.map { EditorRaster.lines($0,width: 155,font: .systemFont(ofSize: 11,weight: .medium)).count>1 ? 42 : 28 }; needsLayout = true; needsDisplay = true }
        let first = session.showsInterstitial
        if lastInterstitial != first {
            firstRun.isHidden = !first; setAccessibilityChildren(first ? [firstRun] : controls.prefix(3).map { $0 }+[pad]+Array(controls.dropFirst(3).prefix(3))+[fontCard]+Array(controls.suffix(4)))
            if lastInterstitial == true && !first { let fade = CATransition(); fade.type = .fade; fade.duration = 0.2; layer?.add(fade,forKey: "interstitial") }
            lastInterstitial = first; needsLayout = true
        }
        let height = 588+bannerSizes.reduce(0,+)
        if frame.height != height { onResize?(height,animated) }
    }
    public override func layout() {
        super.layout();let m = BoostEditorMetrics.self,shift = bannerSizes.reduce(0,+)
        control(id: "editor.done")?.frame = m.done; control(id: "editor.name")?.frame = m.name; control(id: "editor.undo")?.frame = m.undo
        pad.frame = m.ringFrame.offsetBy(dx: 0,dy: shift)
        for (i,id) in ["invert","advanced","reset"].enumerated() { control(id: "editor.color."+id)?.frame = m.colorButtons[i].offsetBy(dx: 0,dy: shift) }
        fontCard.frame = m.fontCard.offsetBy(dx: 0,dy: shift); fontCard.layer?.shadowPath = CGPath(roundedRect: fontCard.bounds,cornerWidth: 11,cornerHeight: 11,transform: nil)
        for (i,b) in fontButtons.enumerated() { b.frame = CGRect(x: m.fontColumns[i%5]-18,y: m.fontRows[i/5]-273,width: 26,height: 26) }
        for (id,rect) in [("size",m.size),("case",m.textCase),("zap",m.zap),("code",m.code)] { control(id: "editor.tool."+id)?.frame = rect.offsetBy(dx: 0,dy: shift) }
        firstRun.frame = bounds; firstRun.needsLayout = true
    }
    private func paint() {
        BoostEditorColors.background.nsColor.setFill();bounds.fill();BoostEditorColors.header.nsColor.setFill();CGRect(x: 0,y: 0,width: bounds.width,height: 40).fill()
        BoostEditorColors.hairline.nsColor.setFill();CGRect(x: 0,y: 39,width: bounds.width,height: 1).fill()
        var y: CGFloat = 40
        for (text,height) in zip(banners,bannerSizes) {
            BoostEditorColors.warning.withAlpha(0.15).nsColor.setFill();CGRect(x: 0,y: y,width: bounds.width,height: height).fill()
            let lines = Array(EditorRaster.lines(text,width: 155,font: .systemFont(ofSize: 11,weight: .medium)).prefix(2)),pitch: CGFloat = 14
            let baseline = y+(height-CGFloat(lines.count)*pitch)/2+11
            for (i,line) in lines.enumerated() { SiteControlDrawing.text(line,x: 14,baseline: baseline+CGFloat(i)*pitch,width: 155,font: .systemFont(ofSize: 11,weight: .medium),color: BoostEditorColors.title.nsColor) }; y += height
        }
    }
    public override func mouseDown(with event: NSEvent) { if convert(event.locationInWindow,from: nil).y<40 { window?.performDrag(with: event) } }
    public override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
    public func focus(_ target: NSView) { (target as? SiteControlButton)?.showsKeyboardFocus = true; (target as? BoostColorPadView)?.showsKeyboardFocus = true; window?.makeFirstResponder(target);target.needsDisplay = true }
    public func closeAdvanced() { advancedPopover?.close(); advancedPopover = nil; (control(id: "editor.color.advanced") as? EditorButton)?.selected = false }
    private func toggleAdvanced() {
        if advanced { closeAdvanced(); return }
        guard let window,let anchor = control(id: "editor.color.advanced") else { return }
        let popup = BoostAdvancedPopover(session: session,parent: window,anchor: anchor,visibleFrame: screenVisibleFrame?() ?? window.screen?.visibleFrame ?? window.frame)
        popup.onClose = { [weak self] in self?.advancedPopover = nil; (self?.control(id: "editor.color.advanced") as? EditorButton)?.selected = false }
        advancedPopover = popup; popup.present(); (anchor as? EditorButton)?.selected = true
    }
    private func showNameMenu() { let menu = makeMenu?() ?? NSMenu();onMenu?(menu);menu.popUp(positioning: nil,at: CGPoint(x: 0,y: 24),in: control(id: "editor.name")) }
    public func scopeMenu() -> NSMenu {
        let menu = NSMenu();menu.autoenablesItems = false
        for choice in session.scopeChoices() { let item = NSMenuItem(title: choice.title,action: #selector(pickScope(_:)),keyEquivalent: "");item.target = self;item.representedObject = choice.match;item.state = choice.match == session.boost.siteMatch ? .on : .off;menu.addItem(item) };return menu
    }
    @objc private func pickScope(_ item: NSMenuItem) { if let match = item.representedObject as? SiteMatch { session.setScope(match) } }
    private func showTextMenu(size: Bool) {
        let menu = NSMenu();for (i,name) in (size ? BoostEditorSession.textSizeNames : BoostEditorSession.textCaseNames).enumerated() { let item = NSMenuItem(title: name,action: #selector(pickText(_:)),keyEquivalent: "");item.target = self;item.tag = i+(size ? 10 : 0);item.state = i == (size ? session.textSizeIndex : session.textCaseIndex) ? .on : .off;menu.addItem(item) }
        onMenu?(menu);menu.popUp(positioning: nil,at: .zero,in: control(id: "editor.tool."+(size ? "size" : "case")))
    }
    @objc private func pickText(_ item: NSMenuItem) { if item.tag>=10 { session.setTextSize(index: item.tag-10) } else { session.setTextCase(index: item.tag) } }
    private func navigateFonts(_ event: NSEvent,current: EditorButton?) -> Bool {
        if [123,124,125,126].contains(event.keyCode),let current,let index = fontButtons.firstIndex(of: current) {
            let step = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : event.keyCode == 125 ? 5 : -5
            var i = index
            for _ in 0..<20 { i = (i+step+20)%20;if fontButtons[i].isEnabled { focus(fontButtons[i]);break } };return true
        };return onKey?(event) ?? false
    }
}

@MainActor
private final class EditorInterstitial: NSView {
    let make = EditorButton(id: "editor.make",label: "Make a Boost",symbol: "",pointSize: 14)
    let later = EditorButton(id: "editor.later",label: "Maybe Later",symbol: "",pointSize: 12)
    let host: String
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    init(host: String) {
        self.host = host;super.init(frame: .zero);wantsLayer = true
        make.kind = .primary;make.caption = "Make a Boost";later.kind = .secondary;later.caption = "Maybe Later";addSubview(make);addSubview(later)
        setAccessibilityElement(true);setAccessibilityRole(.group);setAccessibilityLabel("Edit the Internet with Boosts");setAccessibilityChildren([make,later])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout();make.frame = BoostEditorMetrics.makeABoost;later.frame = BoostEditorMetrics.maybeLater }
    override func updateLayer() { EditorRaster.display(self) { paint() } }
    private func paint() {
        let c = NSGraphicsContext.current!.cgContext,m = BoostEditorMetrics.self
        BoostEditorColors.firstRunDim.nsColor.setFill();bounds.fill()
        NSColor.white.setFill();CGRect(x: 0,y: 271,width: bounds.width,height: bounds.height-271).fill()
        c.saveGState();c.setShadow(offset: CGSize(width: 0,height: -3),blur: 9,color: NSColor.black.withAlphaComponent(0.25).cgColor);NSColor.white.setFill();CGRect(x: 0,y: 271,width: bounds.width,height: bounds.height-271).fill();c.restoreGState()
        let wave = NSBezierPath();wave.move(to: CGPoint(x: 0,y: 465))
        for x in stride(from: CGFloat(0),through: bounds.width,by: 0.25) { wave.line(to: CGPoint(x: x,y: 464.95-1.95*cos((x-7)*2 * .pi/17))) }
        wave.line(to: CGPoint(x: bounds.maxX,y: bounds.maxY));wave.line(to: CGPoint(x: 0,y: bounds.maxY));wave.close();BoostEditorColors.firstRunFooter.nsColor.setFill();wave.fill()
        c.saveGState();c.translateBy(x: 91.5,y: 281);c.rotate(by: -12 * .pi/180) // Negative in this flipped context: the top edge rises to the right.
        let badge = NSBezierPath(roundedRect: CGRect(x: -35,y: -35,width: 70,height: 70),xRadius: 14,yRadius: 14)
        NSColor(srgbRed: 72/255,green: 72/255,blue: 1,alpha: 1).setFill();badge.fill();NSColor.white.setStroke();badge.lineWidth = 3;badge.stroke()
        EditorRaster.glyph(BoostGlyph.outline,in: CGRect(x: -25,y: -25,width: 50,height: 50),size: 34,color: .white)
        c.setFillColor(NSColor.white.cgColor);SiteControlGlyphRenderer.sparkle(c,at: CGPoint(x: -22,y: -16),size: 6,alpha: 1);SiteControlGlyphRenderer.sparkle(c,at: CGPoint(x: 22,y: 18),size: 5,alpha: 1);c.restoreGState()
        for (line,y) in zip(["Edit the","Internet with","Boosts"],m.titleBaselines) { SiteControlDrawing.text(line,x: 10,baseline: y,width: 163,font: Typography.firstRunTitle.font,color: BoostEditorColors.firstRunTitle.nsColor,alignment: .center) }
        var displayHost = host
        while ("Make "+displayHost as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13,weight: .semibold)]).width>153 && displayHost.count>6 { let count = displayHost.count;displayHost = String(displayHost.prefix(count/2-1))+"…"+String(displayHost.suffix(count/2-1)) }
        SiteControlDrawing.text("Make "+displayHost,x: 14,baseline: 421,width: 155,font: .systemFont(ofSize: 13,weight: .semibold),color: BoostEditorColors.firstRunBody.nsColor,alignment: .center)
        SiteControlDrawing.text("your own!",x: 14,baseline: 437,width: 155,font: .systemFont(ofSize: 13),color: BoostEditorColors.firstRunBody.nsColor,alignment: .center)
    }
}
