import AppKit
import OpenDesign
import OpenModel

/// S2 19/0023: Profile-scoped picker; filtering and keyboard behavior are v1 guesses.
@MainActor
public final class LittleOpenSpacePicker: NSViewController, NSSearchFieldDelegate {
    public let searchField = NSSearchField()
    public private(set) var filteredSpaces: [Space] = []
    public private(set) var highlightedIndex = 0
    public var onChoose: ((SpaceID) -> Void)?
    public var onCancel: (() -> Void)?
    private let model: BrowserModel
    private let spaces: [Space]
    private let scroll = NSScrollView()
    private let rows = LittlePickerRoot()
    private var buttons: [LittleSpaceRow] = []
    public init(model: BrowserModel, profileID: ProfileID, currentSpaceID: SpaceID?) {
        self.model = model
        let all = model.spaces.filter { $0.profileID == profileID }
        spaces = all.filter { $0.id == currentSpaceID } + all.filter { $0.id != currentSpaceID }
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    public override func loadView() {
        let m = LittleOpenMetrics.self
        let root = LittlePickerRoot(); root.wantsLayer = true; root.layer?.backgroundColor = m.titleBarFill.cgColor; root.appearance = NSAppearance(named: .darkAqua)
        root.frame = CGRect(x: 0, y: 0, width: m.pickerWidth, height: m.pickerHeader)
        view = root
        searchField.placeholderString = "Search Spaces…"; searchField.font = .systemFont(ofSize: m.fontSize)
        searchField.delegate = self; searchField.sendsSearchStringImmediately = true
        searchField.frame = CGRect(x: m.pickerInset, y: m.pickerInset, width: m.pickerWidth - 2 * m.pickerInset, height: m.pickerSearchHeight)
        root.addSubview(searchField)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.documentView = rows; root.addSubview(scroll)
        filter("")
    }
    public override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(searchField) }
    public func controlTextDidChange(_ obj: Notification) { filter(searchField.stringValue) }
    private func filter(_ query: String) {
        filteredSpaces = spaces.filter { query.isEmpty || model.displayTitle(for: $0).range(of: query, options: .caseInsensitive) != nil }
        highlightedIndex = 0; buttons.forEach { $0.removeFromSuperview() }; buttons = []
        let m = LittleOpenMetrics.self
        for (index, space) in filteredSpaces.enumerated() {
            let button = LittleSpaceRow(space: space, title: model.displayTitle(for: space)) { [weak self] in
                guard let self else { return }; self.highlightedIndex = index; self.chooseHighlighted()
            }
            button.frame = CGRect(x: m.pickerInset, y: CGFloat(index) * m.pickerRowHeight, width: m.pickerWidth - 2 * m.pickerInset, height: m.pickerRowHeight)
            rows.addSubview(button); buttons.append(button)
        }
        rows.frame = CGRect(x: 0, y: 0, width: m.pickerWidth, height: CGFloat(filteredSpaces.count) * m.pickerRowHeight)
        let height = CGFloat(min(m.pickerVisibleRows, filteredSpaces.count)) * m.pickerRowHeight
        scroll.frame = CGRect(x: 0, y: m.pickerHeader, width: m.pickerWidth, height: height)
        preferredContentSize = CGSize(width: m.pickerWidth, height: m.pickerHeader + height + m.pickerInset)
        view.frame.size = preferredContentSize
        updateHighlight()
    }
    private func updateHighlight() {
        for (i, button) in buttons.enumerated() { button.rowHighlighted = i == highlightedIndex }
        if buttons.indices.contains(highlightedIndex) { rows.scrollToVisible(buttons[highlightedIndex].frame) }
    }
    public func moveHighlight(by delta: Int) {
        highlightedIndex = max(0, min(filteredSpaces.count - 1, highlightedIndex + delta)); updateHighlight()
    }
    public func chooseHighlighted() {
        guard filteredSpaces.indices.contains(highlightedIndex) else { return }; onChoose?(filteredSpaces[highlightedIndex].id)
    }
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveHighlight(by: -1)
        case #selector(NSResponder.moveDown(_:)): moveHighlight(by: 1)
        case #selector(NSResponder.insertNewline(_:)): chooseHighlighted()
        case #selector(NSResponder.cancelOperation(_:)): onCancel?()
        default: return false
        }
        return true
    }
}

@MainActor
private final class LittlePickerRoot: NSView { override var isFlipped: Bool { true } }

@MainActor
private final class LittleSpaceRow: NSButton {
    let space: Space
    let perform: () -> Void
    var rowHighlighted = false { didSet { needsDisplay = true } }
    init(space: Space, title: String, perform: @escaping () -> Void) {
        self.space = space; self.perform = perform
        super.init(frame: .zero); self.title = title; isBordered = false; target = self; action = #selector(choose)
        setAccessibilityLabel(title)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    @objc private func choose() { perform() }
    override func draw(_ dirtyRect: NSRect) {
        let m = LittleOpenMetrics.self
        if rowHighlighted { m.capsuleFill.nsColor.setFill(); NSBezierPath(roundedRect: bounds, xRadius: m.capsuleRadius, yRadius: m.capsuleRadius).fill() }
        let icon = CGRect(x: m.pickerInset, y: (bounds.height - m.pickerIconSize) / 2, width: m.pickerIconSize, height: m.pickerIconSize)
        SpaceThemeStyle(theme: space.theme, system: .dark).accentColor(.light).nsColor.setFill()
        NSBezierPath(roundedRect: icon, xRadius: m.pickerIconRadius, yRadius: m.pickerIconRadius).fill()
        switch space.icon {
        case .emoji(let text):
            (text as NSString).draw(in: icon.insetBy(dx: m.pickerEmojiInset.width, dy: m.pickerEmojiInset.height), withAttributes: [.font: NSFont.systemFont(ofSize: m.pickerEmojiSize)])
        default:
            let symbol: String
            switch space.icon { case .symbol(let name): symbol = name; case .named(let name): symbol = NamedSpaceIcons.symbolName(for: name); default: symbol = "square" }
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.draw(in: icon.insetBy(dx: m.pickerSymbolInset, dy: m.pickerSymbolInset), from: .zero, operation: .sourceOver, fraction: 0.8, respectFlipped: true, hints: nil)
        }
        let rect = CGRect(x: icon.maxX + m.pickerInset, y: (bounds.height - m.hostHeight) / 2, width: max(0, bounds.width - icon.maxX - 2 * m.pickerInset), height: m.hostHeight)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: m.fontSize), .foregroundColor: m.text.nsColor, .paragraphStyle: paragraph])
    }
}
