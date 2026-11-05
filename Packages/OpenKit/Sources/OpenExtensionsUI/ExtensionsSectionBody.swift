import AppKit
import OpenDesign
import OpenWeb

@MainActor public final class ExtensionsSectionBody: NSView {
    public private(set) var items: [ExtensionItemView] = []
    public private(set) var focusedID: String?
    public var tooltipStyle: SpaceThemeStyle? { didSet { items.forEach { $0.tooltipStyle = tooltipStyle } } }
    public var onIntent: ((ExtensionItemIntent) -> Void)?
    public var onClose: (() -> Void)?
    public var pickerMode = false { didSet { updateFocus() } }
    public private(set) var isGrid = false
    private var prefix = ""
    private var lastTypeTime: TimeInterval = -.infinity
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { pickerMode }
    public override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; clipsToBounds = false; layerContentsRedrawPolicy = .onSetNeedsDisplay }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    @discardableResult public func setActions(_ actions: [ExtensionItem]) -> Bool {
        guard ExtensionsUIContext.accepts(actions) else { return false }
        items.forEach { $0.removeFromSuperview() }
        let ordered = ExtensionsUIContext.ordered(actions)
        isGrid = actions.count > 4
        let add = ExtensionItem(extensionID: "extensions.add", name: "Add Extension")
        items = (ordered + [add]).map { value in
            let item = ExtensionItemView(item: value, style: isGrid ? .tile : .row, isAdd: value.id == add.id)
            item.tooltipStyle = tooltipStyle
            item.onIntent = { [weak self] intent in self?.onIntent?(intent) }
            addSubview(item); return item
        }
        focusedID = ordered.first?.id ?? add.id
        prefix = ""; lastTypeTime = -.infinity
        invalidateIntrinsicContentSize(); needsLayout = true; updateFocus(); return true
    }
    public override var intrinsicContentSize: NSSize {
        let rows = isGrid ? (items.count + 4) / 5 : items.count
        return CGSize(width: isGrid ? 236 : 260,
            height: isGrid ? CGFloat(rows) * 48 - (rows == 0 ? 0 : 4) : CGFloat(rows) * 32)
    }
    public override func layout() {
        super.layout()
        for (i, item) in items.enumerated() {
            item.frame = isGrid ? CGRect(x: CGFloat(i % 5) * 48, y: CGFloat(i / 5) * 48, width: 44, height: 44)
                : CGRect(x: 0, y: CGFloat(i) * 32, width: bounds.width, height: 32)
        }
    }
    private func updateFocus() { for item in items { item.pickerFocused = pickerMode && item.item.id == focusedID } }
    public override func keyDown(with event: NSEvent) {
        guard pickerMode, !items.isEmpty else { super.keyDown(with: event); return }
        let index = items.firstIndex { $0.item.id == focusedID } ?? 0
        var next = index
        switch event.keyCode {
        case 53: onClose?(); return
        case 36, 76: items[index].activate(); return
        case 123: if isGrid { next = (index - 1 + items.count) % items.count }
        case 124: if isGrid { next = (index + 1) % items.count }
        case 125:
            if isGrid { next = index + 5; if next >= items.count { next = index % 5 } }
            else { next = (index + 1) % items.count }
        case 126:
            if isGrid { next = index - 5; if next < 0 { next = index % 5 + ((items.count - 1 - index % 5) / 5) * 5 } }
            else { next = (index - 1 + items.count) % items.count }
        default:
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let text = event.characters, !text.isEmpty, text.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else { super.keyDown(with: event); return }
            if event.timestamp - lastTypeTime > 1 { prefix = "" }
            lastTypeTime = event.timestamp
            if prefix.utf8.count + text.utf8.count <= 4096 { prefix += text }
            if let found = items.firstIndex(where: { $0.item.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).hasPrefix(prefix.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) }) { next = found }
        }
        focusedID = items[next].item.id; updateFocus()
    }
    public override func cancelOperation(_ sender: Any?) { onClose?() }
}
