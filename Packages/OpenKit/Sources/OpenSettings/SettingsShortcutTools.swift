import AppKit
import SwiftUI
import OpenDesign

/// Fixed native controls avoid a second SwiftUI layout tree above the native
/// shortcut table. The existing model still owns filtering and key capture.
struct SettingsShortcutTools: NSViewRepresentable {
    let model: ShortcutsViewModel
    let query: String
    let filter: String
    let category: String
    let categories: [String]
    let counts: [Int]
    let finding: Bool
    let found: String?
    let accent: NSColor
    func makeNSView(context: Context) -> SettingsShortcutToolsView { SettingsShortcutToolsView(model: model) }
    func updateNSView(_ view: SettingsShortcutToolsView, context: Context) {
        view.update(query: query, filter: filter, category: category, categories: categories,
            counts: counts, finding: finding, found: found, accent: accent)
    }
}

@MainActor final class SettingsShortcutToolsView: NSView, NSTextFieldDelegate {
    private let model: ShortcutsViewModel
    private let search = NSTextField()
    private let glass = NSImageView()
    private let find = NSButton(title: "", target: nil, action: nil)
    private let found = NSButton(title: "", target: nil, action: nil)
    private let category = SettingsChoiceButton(frame: .zero, pullsDown: false)
    private let filters = [("All", "all"), ("Changed", "changed"), ("Unassigned", "unassigned"), ("Conflicts", "conflicts")]
    private var chips: [SettingsShortcutFilterButton] = []
    private var categoryIDs: [String] = []
    private var accent = SettingsStyle.accent.nsColor
    private var dividerX: CGFloat = 0
    override var isFlipped: Bool { true }
    init(model: ShortcutsViewModel) {
        self.model = model
        super.init(frame: .zero)
        search.isBordered = false; search.drawsBackground = false; search.focusRingType = .none
        search.font = .systemFont(ofSize: 13); search.delegate = self
        search.setAccessibilityLabel("Find a command"); addSubview(search)
        glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        glass.setAccessibilityElement(false); addSubview(glass)
        for button in [find, found] {
            button.isBordered = false; button.font = .systemFont(ofSize: 11)
            button.target = self; addSubview(button)
        }
        find.action = #selector(findKeys); found.action = #selector(clearFound)
        for (title, id) in filters {
            let chip = SettingsShortcutFilterButton(title: title, target: self, action: #selector(selectFilter(_:)))
            chip.identifier = .init(id); chip.isBordered = false; chip.focusRingType = .none
            chip.setAccessibilityLabel(title + " shortcuts")
            chips.append(chip); addSubview(chip)
        }
        category.isBordered = false; category.autoenablesItems = false
        category.target = self; category.action = #selector(selectCategory)
        category.setAccessibilityLabel("Shortcut category"); addSubview(category)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(query: String, filter: String, category selected: String, categories: [String],
                counts: [Int], finding: Bool, found symbol: String?, accent: NSColor) {
        self.accent = accent
        if search.stringValue != query { search.stringValue = query }
        for (index, chip) in chips.enumerated() {
            chip.count = counts.indices.contains(index) ? counts[index] : 0
            chip.selected = filters[index].1 == filter; chip.accent = accent
            chip.setAccessibilitySelected(chip.selected); chip.setAccessibilityValue(String(chip.count))
            chip.needsDisplay = true
        }
        categoryIDs = ["all"] + categories
        let names = ["Category"] + categories
        if category.itemTitles != names { category.removeAllItems(); category.addItems(withTitles: names) }
        category.selectItem(at: categoryIDs.firstIndex(of: selected) ?? 0)
        category.accent = accent; category.needsDisplay = true
        find.title = finding ? "Press a shortcut… Esc cancels" : "Press keys ⌥⌘K"
        find.contentTintColor = finding ? SettingsStyle.attentionText.nsColor : SettingsStyle.secondary.nsColor
        found.isHidden = symbol == nil; found.title = symbol.map { $0 + " ×" } ?? ""
        found.setAccessibilityLabel("Clear shortcut key filter")
        needsLayout = true; needsDisplay = true
    }
    override func layout() {
        super.layout()
        glass.frame = .init(x: 10, y: 10, width: 14, height: 14)
        let findWidth = ceil((find.title as NSString).size(withAttributes: [.font: find.font!]).width) + 4
        find.frame = .init(x: max(120, bounds.width - 10 - findWidth), y: 4, width: findWidth, height: 26)
        let foundWidth = found.isHidden ? 0 : ceil((found.title as NSString).size(withAttributes: [.font: found.font!]).width) + 12
        found.frame = .init(x: find.frame.minX - foundWidth - 8, y: 4, width: foundWidth, height: 26)
        search.frame = .init(x: 32, y: 8, width: max(60, find.frame.minX - foundWidth - 48), height: 20)
        var x: CGFloat = 0
        for chip in chips {
            let width = chip.fittingWidth
            chip.frame = .init(x: x, y: 44, width: width, height: 26); x += width + 6
        }
        dividerX = x + 3
        let categoryWidth = ceil(((category.selectedItem?.title ?? "Category") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width) + 32
        category.frame = .init(x: dividerX + 10, y: 44, width: categoryWidth, height: 26)
    }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: .init(x: 0.5, y: 0.5, width: bounds.width - 1, height: 33), xRadius: 8, yRadius: 8)
        SettingsStyle.card.nsColor.setFill(); shape.fill()
        let focused = (window?.firstResponder as? NSTextView)?.delegate === search
        (focused ? accent : SettingsStyle.controlLine.nsColor).setStroke(); shape.lineWidth = 1; shape.stroke()
        if focused {
            accent.withAlphaComponent(0.35).setStroke()
            let ring = NSBezierPath(roundedRect: .init(x: 1.5, y: 1.5, width: bounds.width - 3, height: 31), xRadius: 7, yRadius: 7)
            ring.lineWidth = 3; ring.stroke()
        }
        search.textColor = SettingsStyle.text.nsColor
        search.placeholderAttributedString = NSAttributedString(string: "Find a command", attributes: [.font: search.font!, .foregroundColor: SettingsStyle.secondary.nsColor])
        glass.contentTintColor = SettingsStyle.secondary.nsColor; found.contentTintColor = SettingsStyle.secondary.nsColor
        SettingsStyle.hairline.nsColor.setFill(); NSRect(x: dividerX, y: 48, width: 1, height: 18).fill()
    }
    func controlTextDidChange(_ notification: Notification) { model.query = search.stringValue }
    func controlTextDidBeginEditing(_ notification: Notification) { needsDisplay = true }
    func controlTextDidEndEditing(_ notification: Notification) { needsDisplay = true }
    @objc private func findKeys() { model.findByKeys.toggle() }
    @objc private func clearFound() { model.findShortcut = nil }
    @objc private func selectFilter(_ sender: NSButton) { model.filter = sender.identifier?.rawValue ?? "all" }
    @objc private func selectCategory() {
        guard categoryIDs.indices.contains(category.indexOfSelectedItem) else { return }
        model.category = categoryIDs[category.indexOfSelectedItem]
    }
}

@MainActor private final class SettingsShortcutFilterButton: NSButton {
    var count = 0
    var selected = false
    var accent = SettingsStyle.accent.nsColor
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var fittingWidth: CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width)
        + ceil((String(count) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width) + 21
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func draw(_ dirtyRect: NSRect) {
        (selected ? accent.withAlphaComponent(0.2) : SettingsStyle.control.nsColor).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 13, yRadius: 13).fill()
        let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let titleWidth = (title as NSString).size(withAttributes: [.font: titleFont]).width
        (title as NSString).draw(at: .init(x: 8, y: 5), withAttributes: [.font: titleFont, .foregroundColor: SettingsStyle.text.nsColor])
        (String(count) as NSString).draw(at: .init(x: 13 + titleWidth, y: 6), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: SettingsStyle.secondary.nsColor])
        if window?.firstResponder === self {
            accent.withAlphaComponent(0.35).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 12, yRadius: 12)
            ring.lineWidth = 3; ring.stroke()
        }
    }
}
