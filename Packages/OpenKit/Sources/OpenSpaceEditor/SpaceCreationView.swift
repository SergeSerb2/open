import AppKit
import OpenDesign
import OpenModel

/// The real sidebar page. All changes stay in the controller's local draft.
@MainActor
public final class SpaceCreationView: NSView, NSTextFieldDelegate {
    public enum WidthClass: String { case compact, medium, full }
    public let nameField: NSTextField = CreationTextField()
    public let iconButton = NSButton(title: "", target: nil, action: nil)
    public let themeButton: NSButton = NSButton(title: "Choose a Theme", target: nil, action: nil)
    public let profilePopup: NSPopUpButton = CreationProfilePopup(frame: .zero, pullsDown: false)
    public let profileNameField: NSTextField = CreationTextField()
    public let createButton: NSButton = CreationSubmitButton(title: "Create Space", target: nil, action: nil)
    public let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    public let profileInfo = NSButton(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About Profiles")!, target: nil, action: nil)
    public var onCreate: (() -> Void)?
    public var onCancel: (() -> Void)?
    public var onTheme: (() -> Void)?
    public var onIcon: (() -> Void)?
    public var onProfile: ((Int) -> Void)?
    public var localUndoManager: UndoManager? {
        didSet {
            for field in [nameField, profileNameField] {
                (field as? CreationTextField)?.editor.draftUndoManager = localUndoManager
            }
        }
    }
    public private(set) var widthClass: WidthClass = .full
    public private(set) var submitIsPinned = false
    public let scroll = NSScrollView()
    private let document = CreationFlippedView()
    private let header = CreationHeaderView()
    private let titleLabel = NSTextField(labelWithString: "Create a Space")
    private let subtitle = NSTextField(wrappingLabelWithString: "Separate your tabs for life,\nwork, projects, and more.")
    private let nameCard = CreationFlippedView()
    private let themeCard = CreationFlippedView()
    private let profileCard = CreationFlippedView()
    private let profileLabel = NSTextField(labelWithString: "Profile")
    private let issueLabel = NSTextField(wrappingLabelWithString: "")
    private let swatch = CreationSwatchView()
    private let buttons = CreationFlippedView()
    public private(set) var style = SpaceThemeStyle(theme: SpaceTheme(), system: .dark)
    public var systemAppearance: ContentAppearance = .dark
    private var creatingProfile = false
    private var entered = false
    public var cardFrames: [String: CGRect] {
        ["header": header.frame, "name": nameCard.frame, "theme": themeCard.frame, "profile": profileCard.frame,
         "create": convert(createButton.bounds, from: createButton)]
    }
    public override var isFlipped: Bool { true }
    public override var undoManager: UndoManager? { localUndoManager }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; setAccessibilityLabel("Create a Space")
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay; scroll.hasVerticalScroller = false; scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = document; addSubview(scroll); addSubview(buttons)
        for view in [header, titleLabel, subtitle, nameCard, themeCard, profileCard] { document.addSubview(view) }
        for card in [nameCard, themeCard, profileCard] {
            card.wantsLayer = true; card.layer?.cornerRadius = 10; card.layer?.cornerCurve = .continuous
        }
        for field in [nameField, profileNameField] {
            field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
            field.font = .systemFont(ofSize: 14); field.delegate = self
        }
        nameField.placeholderString = "Space name"; nameField.setAccessibilityLabel("Space name")
        profileNameField.placeholderString = "Profile name"; profileNameField.setAccessibilityLabel("Profile name")
        nameCard.addSubview(iconButton); nameCard.addSubview(nameField)
        themeCard.addSubview(themeButton); themeCard.addSubview(swatch)
        for view in [profileLabel, profileInfo, profilePopup, profileNameField, issueLabel] { profileCard.addSubview(view) }
        for button in [iconButton, themeButton, profileInfo, createButton, cancelButton] {
            button.isBordered = false; button.target = self
            button.font = .systemFont(ofSize: 13, weight: button === createButton ? .semibold : .medium)
        }
        iconButton.action = #selector(pickIcon); iconButton.toolTip = "Change Space Icon"
        themeButton.cell = CreationThemeCell(textCell: "Choose a Theme")
        themeButton.isBordered = false; themeButton.font = .systemFont(ofSize: 13, weight: .medium)
        themeButton.action = #selector(pickTheme); themeButton.alignment = .left
        createButton.action = #selector(create); cancelButton.action = #selector(cancel)
        createButton.wantsLayer = true; createButton.layer?.cornerRadius = 8
        createButton.keyEquivalent = "\r"; cancelButton.keyEquivalent = "\u{1b}"
        profileInfo.toolTip = "You can use a Profile to give this Space its own logins, history, and browsing data."
        profilePopup.target = self; profilePopup.action = #selector(pickProfile)
        profilePopup.isBordered = false; profilePopup.font = .systemFont(ofSize: 13)
        profileLabel.font = .systemFont(ofSize: 13, weight: .medium)
        subtitle.font = .systemFont(ofSize: 13); subtitle.alignment = .center; subtitle.maximumNumberOfLines = 2
        titleLabel.alignment = .center
        issueLabel.font = .systemFont(ofSize: 11); issueLabel.textColor = .systemRed
        buttons.addSubview(createButton); buttons.addSubview(cancelButton)
        apply(theme: SpaceTheme(), icon: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public func apply(theme: SpaceTheme, icon: SpaceIcon?) {
        style = SpaceThemeStyle(theme: theme, system: systemAppearance)
        let mode = style.resolvedAppearance(system: systemAppearance)
        appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
        let title = style.titleColor(mode).nsColor
        let secondary = style.palette(for: mode)?.subtitle.nsColor ?? title.withAlphaComponent(0.65)
        let fill = SidebarRole.fieldFill.resolved(mode).nsColor
        for card in [nameCard, themeCard, profileCard] { card.layer?.backgroundColor = fill.cgColor }
        for label in [titleLabel, nameField, profileNameField, profileLabel] { label.textColor = title }
        subtitle.textColor = secondary
        for button in [iconButton, themeButton, profileInfo, cancelButton] { button.contentTintColor = button === cancelButton ? secondary : title }
        createButton.layer?.backgroundColor = (style.palette(for: mode)?.focus.nsColor ?? fill).cgColor
        createButton.contentTintColor = title
        header.icon = icon; header.tint = title; header.fill = fill
        iconButton.image = nil; iconButton.title = ""
        if case .emoji(let emoji) = icon { iconButton.title = emoji }
        else {
            let symbol: String
            switch icon {
            case .named(let id): symbol = NamedSpaceIcons.symbols[id] ?? "face.smiling"
            case .symbol(let name): symbol = name
            default: symbol = "face.smiling"
            }
            let tint = icon == nil ? secondary : title
            iconButton.contentTintColor = tint
            iconButton.image = icon == nil ? creationSmiley(color: tint, size: 16) : creationSymbol(symbol, color: tint, size: 16)
        }
        profileInfo.image = profileInfo.image?.withSymbolConfiguration(.init(paletteColors: [title]))
        swatch.style = style; swatch.draft = theme.style; swatch.needsDisplay = true; needsDisplay = true
    }

    public func setProfiles(_ choices: [SpaceProfileChoice], selected: ProfileID?, creating: Bool, issue: String? = nil) {
        profilePopup.removeAllItems()
        for choice in choices { profilePopup.addItem(withTitle: choice.name) }
        profilePopup.menu?.addItem(.separator()); profilePopup.addItem(withTitle: "New Profile…")
        if creating { profilePopup.selectItem(withTitle: "New Profile…") }
        else if let index = choices.firstIndex(where: { $0.id == selected }) { profilePopup.selectItem(at: index) }
        creatingProfile = creating; profileNameField.isHidden = !creating
        profilePopup.isHidden = false; issueLabel.stringValue = issue ?? ""; issueLabel.isHidden = issue == nil
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        widthClass = w < 190 ? .compact : w < 227 ? .medium : .full
        let gap: CGFloat = widthClass == .full ? 8 : 6
        let inset: CGFloat = widthClass == .full ? 8 : 6
        let hero: CGFloat = widthClass == .compact ? 60 : 80
        let titleY = 16 + hero + 14
        let cardsY = titleY + 24 + 8 + 36 + 20
        let profileHeight: CGFloat = creatingProfile ? (issueLabel.isHidden ? 82 : 112) : 44
        let end = cardsY + 88 + 2 * gap + profileHeight
        submitIsPinned = end + 12 + 64 + 12 > h
        scroll.hasVerticalScroller = submitIsPinned
        let contentHeight = end + (submitIsPinned ? 12 : 88)
        scroll.frame = CGRect(x: 0, y: 0, width: w, height: max(0, h - (submitIsPinned ? 88 : 0)))
        document.frame = CGRect(x: 0, y: 0, width: w, height: max(contentHeight, scroll.bounds.height))
        header.frame = CGRect(x: (w - hero) / 2, y: 16, width: hero, height: hero)
        header.full = widthClass == .full
        titleLabel.font = .systemFont(ofSize: widthClass == .full ? 17 : 15, weight: .semibold)
        titleLabel.frame = CGRect(x: 8, y: titleY, width: w - 16, height: 24)
        subtitle.frame = CGRect(x: 0, y: titleY + 32, width: w, height: 36)
        let cw = w - 2 * inset
        nameCard.frame = CGRect(x: inset, y: cardsY, width: cw, height: 44)
        themeCard.frame = CGRect(x: inset, y: cardsY + 44 + gap, width: cw, height: 44)
        profileCard.frame = CGRect(x: inset, y: cardsY + 88 + 2 * gap, width: cw, height: profileHeight)
        iconButton.frame = CGRect(x: 6, y: 6, width: 32, height: 32)
        nameField.frame = CGRect(x: 44, y: 13, width: cw - 50, height: 22)
        themeButton.frame = CGRect(x: 0, y: 0, width: cw, height: 44)
        swatch.frame = CGRect(x: cw - 36, y: 10, width: 24, height: 24)
        profileLabel.frame = CGRect(x: 12, y: 14, width: 43, height: 18)
        profileInfo.isHidden = widthClass == .compact
        profileInfo.frame = CGRect(x: 57, y: 16, width: 12, height: 12)
        let popupX: CGFloat = widthClass == .compact ? 59 : 75
        let popupWidth = min(cw - popupX - 8, (profilePopup.titleOfSelectedItem ?? "").size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width + 28)
        profilePopup.frame = CGRect(x: cw - 8 - popupWidth, y: 10, width: popupWidth, height: 25)
        profileNameField.frame = CGRect(x: 12, y: 48, width: cw - 24, height: 22)
        issueLabel.frame = CGRect(x: 12, y: 73, width: cw - 24, height: 34)
        if submitIsPinned {
            if buttons.superview !== self { buttons.removeFromSuperview(); addSubview(buttons) }
            buttons.frame = CGRect(x: inset, y: max(0, h - 76), width: cw, height: 64)
        } else {
            if buttons.superview !== document { buttons.removeFromSuperview(); document.addSubview(buttons) }
            buttons.frame = CGRect(x: inset, y: end + 12, width: cw, height: 64)
        }
        createButton.frame = CGRect(x: 0, y: 0, width: cw, height: 32)
        cancelButton.frame = CGRect(x: 0, y: 38, width: cw, height: 26)
    }

    public func focusName() {
        if let editor = nameField.currentEditor() { window?.makeFirstResponder(editor) }
        else { window?.makeFirstResponder(nameField) }
    }
    public func breakTextUndoCoalescing() {
        for field in [nameField, profileNameField] { (field as? CreationTextField)?.editor.breakUndoCoalescing() }
    }
    public func animateEntrance() {
        guard !entered, window?.isVisible == true else { return }; entered = true
        for (i, view) in [header, nameCard, themeCard, profileCard, buttons].enumerated() {
            view.wantsLayer = true
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
            let group = CAAnimationGroup(); group.animations = [fade]; group.duration = 0.2
            group.beginTime = CACurrentMediaTime() + Double(i) * 0.03; group.fillMode = .backwards
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if !Motion.reducesMotion {
                let rise = CABasicAnimation(keyPath: "transform.translation.y"); rise.fromValue = -6; rise.toValue = 0
                group.animations?.append(rise)
            }
            view.layer?.add(group, forKey: "creation-entrance")
        }
    }
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { onCreate?(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { onCancel?(); return true }
        return false
    }
    public override func cancelOperation(_ sender: Any?) { onCancel?() }
    @objc private func create() { onCreate?() }
    @objc private func cancel() { onCancel?() }
    @objc private func pickTheme() { onTheme?() }
    @objc private func pickIcon() { onIcon?() }
    @objc private func pickProfile() { onProfile?(profilePopup.indexOfSelectedItem) }
}

/// AppKit may clear a field's typing history when a new editing session starts.
/// Keep that normal behavior separate from the form-lifetime draft history.
@MainActor private final class CreationFieldEditor: NSTextView {
    weak var draftUndoManager: UndoManager?
    private let typingUndoManager = UndoManager()
    override var undoManager: UndoManager? { typingUndoManager }

    // These are native responder actions, reached by the nil-target Edit menu.
    // No key equivalent or local key monitor bypasses AppKit's menu dispatch.
    @objc(undo:) func undoEditing(_ sender: Any?) {
        breakUndoCoalescing()
        if typingUndoManager.canUndo { typingUndoManager.undo() }
        else if draftUndoManager?.canUndo == true { draftUndoManager?.undo() }
    }
    @objc(redo:) func redoEditing(_ sender: Any?) {
        breakUndoCoalescing()
        // After typing then draft Undo, restore the draft before the typing.
        if draftUndoManager?.canRedo == true { draftUndoManager?.redo() }
        else if typingUndoManager.canRedo { typingUndoManager.redo() }
    }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == NSSelectorFromString("undo:") { return typingUndoManager.canUndo || draftUndoManager?.canUndo == true }
        if item.action == NSSelectorFromString("redo:") { return draftUndoManager?.canRedo == true || typingUndoManager.canRedo }
        return super.validateUserInterfaceItem(item)
    }
}

@MainActor private final class CreationTextFieldCell: NSTextFieldCell {
    weak var editor: NSTextView?
    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor ?? super.fieldEditor(for: controlView) }
}

@MainActor private final class CreationTextField: NSTextField {
    let editor = CreationFieldEditor(usingTextLayoutManager: false)
    override class var cellClass: AnyClass? {
        get { CreationTextFieldCell.self }
        set {}
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        editor.isFieldEditor = true; editor.allowsUndo = true
        (cell as? CreationTextFieldCell)?.editor = editor
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

@MainActor private final class CreationFlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private final class CreationHeaderView: NSView {
    var full = true { didSet { needsDisplay = true } }
    var icon: SpaceIcon? { didSet { needsDisplay = true } }
    var tint = NSColor.white
    var fill = NSColor.white.withAlphaComponent(0.1)
    override func draw(_ dirtyRect: NSRect) {
        if full {
            for (angle, dx, dy) in [(-16.0, -15.0, -3.0), (20.0, 18.0, -6.0)] {
                NSGraphicsContext.saveGraphicsState()
                let transform = AffineTransform(translationByX: bounds.midX + dx, byY: bounds.midY + dy)
                var rotated = transform; rotated.rotate(byDegrees: CGFloat(angle)); (rotated as NSAffineTransform).concat()
                fill.setFill(); NSBezierPath(roundedRect: CGRect(x: -30, y: -30, width: 60, height: 60), xRadius: 15, yRadius: 15).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        fill.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20).fill()
        if case .emoji(let emoji) = icon {
            let text = emoji as NSString, attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 36)]
            let size = text.size(withAttributes: attrs); text.draw(at: CGPoint(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2), withAttributes: attrs)
        } else {
            let name: String
            switch icon { case .named(let id): name = NamedSpaceIcons.symbols[id] ?? "face.smiling"
            case .symbol(let id): name = id; default: name = "face.smiling" }
            let image = icon == nil ? creationSmiley(color: tint, size: 32) : creationSymbol(name, color: tint, size: 32)
            let rect = CGRect(x: bounds.midX - 18, y: bounds.midY - 18, width: 36, height: 36)
            image?.draw(in: rect)
        }
    }
}

@MainActor private final class CreationSwatchView: NSView {
    var style = SpaceThemeStyle(theme: SpaceTheme(), system: .dark)
    var draft: SpaceStyle?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(ovalIn: bounds).addClip()
        let colors: [RGBA]
        switch style.fill { case .blended(let base, _): colors = base; case .corners(let corners): colors = corners }
        let swatchColors: [NSColor]
        if let draft {
            swatchColors = ThemeColorMath.harmony(key: ThemeColorMath.toP3(draft.keyColor), count: draft.colorCount, wheel: draft.wheel).map { color in
                let rgb = ThemeColorMath.toExtendedSRGB(color)
                return NSColor(colorSpace: .extendedSRGB, components: [rgb.red, rgb.green, rgb.blue, 1], count: 4)
            }
        } else { swatchColors = colors.map(\.nsColor) }
        let gradient = NSGradient(colors: swatchColors.count == 1 ? swatchColors + swatchColors : swatchColors)
        gradient?.draw(in: bounds, angle: 30)
        NSColor.black.withAlphaComponent(0.10).setStroke()
        let rim = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)); rim.lineWidth = 2; rim.stroke()
    }
}

@MainActor private final class CreationSubmitButton: NSButton {
    override func mouseDown(with event: NSEvent) {
        if !Motion.reducesMotion {
            let press = CABasicAnimation(keyPath: "transform.scale"); press.fromValue = 1; press.toValue = 0.98
            press.duration = 0.08; press.fillMode = .forwards; press.isRemovedOnCompletion = false
            layer?.add(press, forKey: "creation-press")
        }
        super.mouseDown(with: event)
        layer?.removeAnimation(forKey: "creation-press")
    }
}

@MainActor private final class CreationThemeCell: NSButtonCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let title = super.titleRect(forBounds: rect)
        return CGRect(x: rect.minX + 12, y: title.minY, width: max(0, rect.width - 60), height: title.height)
    }
}

@MainActor private final class CreationProfilePopup: NSPopUpButton {
    override init(frame: NSRect, pullsDown flag: Bool) {
        super.init(frame: frame, pullsDown: flag)
        let popupCell = CreationProfileCell(textCell: "", pullsDown: flag)
        popupCell.arrowPosition = .noArrow; cell = popupCell
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        creationSymbol("chevron.down", color: .labelColor, size: 10)?.draw(in:
            CGRect(x: bounds.maxX - 13, y: bounds.midY - 3, width: 9, height: 6))
    }
}

/// Keep palette colors when AppKit draws a symbol outside an NSImageView.
@MainActor private func creationSymbol(_ name: String, color: NSColor, size: CGFloat) -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        .applying(.init(paletteColors: [color]))
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    image?.isTemplate = false
    return image
}

/// Our own placeholder artwork, drawn in the requested text color in both appearances.
@MainActor private func creationSmiley(color: NSColor, size: CGFloat) -> NSImage {
    NSImage(size: CGSize(width: size, height: size), flipped: true) { rect in
        color.setStroke(); color.setFill()
        let face = NSBezierPath(ovalIn: rect.insetBy(dx: size * 0.08, dy: size * 0.08))
        face.lineWidth = size * 0.065; face.stroke()
        for x in [0.34, 0.66] {
            NSBezierPath(ovalIn: CGRect(x: size * x - size * 0.045, y: size * 0.32,
                width: size * 0.09, height: size * 0.09)).fill()
        }
        let smile = NSBezierPath()
        smile.move(to: CGPoint(x: size * 0.30, y: size * 0.59))
        smile.curve(to: CGPoint(x: size * 0.70, y: size * 0.59),
            controlPoint1: CGPoint(x: size * 0.40, y: size * 0.75), controlPoint2: CGPoint(x: size * 0.60, y: size * 0.75))
        smile.lineWidth = size * 0.06; smile.lineCapStyle = .round; smile.stroke()
        return true
    }
}
@MainActor private final class CreationProfileCell: NSPopUpButtonCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var title = super.titleRect(forBounds: rect); title.size.width = max(0, title.width - 16); return title
    }
}
