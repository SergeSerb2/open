import AppKit
import SwiftUI
import OpenCommands
import OpenDesign

struct SettingsShortcutsList: NSViewRepresentable {
    let model: ShortcutsViewModel
    let commands: [CommandDefinition]
    let revision: KeyBindingStore
    let recording: String?
    let findByKeys: Bool
    let selection: String?
    func makeNSView(context: Context) -> SettingsShortcutScrollView { SettingsShortcutScrollView(model: model) }
    func updateNSView(_ view: SettingsShortcutScrollView, context: Context) { view.update(commands, store: revision, recording: recording, finding: findByKeys) }
}

@MainActor final class SettingsShortcutScrollView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    let model: ShortcutsViewModel
    let table: SettingsShortcutTable
    private var commands: [CommandDefinition] = []
    private var oldStore: KeyBindingStore?
    private var recording: String?
    private var finding = false
    init(model: ShortcutsViewModel) {
        self.model = model; table = SettingsShortcutTable(model: model)
        super.init(frame: .zero)
        drawsBackground = false; hasVerticalScroller = true; autohidesScrollers = true
        let column = NSTableColumn(identifier: .init("shortcut")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.headerView = nil; table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .plain
        table.backgroundColor = SettingsStyle.card.nsColor; table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none; table.allowsEmptySelection = true
        table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("Keyboard shortcuts")
        documentView = table
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(_ next: [CommandDefinition], store: KeyBindingStore, recording: String?, finding: Bool) {
        let changedRows = next.map(\.id) != commands.map(\.id)
        let update = changedRows || oldStore != store || self.recording != recording || self.finding != finding
        commands = next; oldStore = store; self.recording = recording; self.finding = finding
        if update { table.reloadData(); table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<commands.count)) }
        if let selected = model.selectedCommandID, let index = commands.firstIndex(where: { $0.id == selected }) {
            if table.selectedRow != index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); table.scrollRowToVisible(index) }
        }
        if recording != nil || finding { window?.makeFirstResponder(table) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { commands.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard commands.indices.contains(row) else { return 44 }
        return model.conflictText(for: commands[row].id) != nil || commands[row].scope == .global ? 60 : 44
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard commands.indices.contains(row) else { return nil }
        let view = tableView.makeView(withIdentifier: .init("shortcut-row"), owner: self) as? SettingsShortcutCell ?? SettingsShortcutCell()
        view.identifier = .init("shortcut-row"); view.update(command: commands[row], model: model, last: row == commands.count - 1)
        return view
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if commands.indices.contains(table.selectedRow) { model.selectedCommandID = commands[table.selectedRow].id }
    }
}

@MainActor final class SettingsShortcutTable: NSTableView, SettingsKeyCapturing {
    let model: ShortcutsViewModel
    init(model: ShortcutsViewModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func captureSettingsKey(_ event: NSEvent) -> Bool {
        guard model.recordingCommandID != nil || model.findByKeys else { return false }
        keyDown(with: event); return true
    }
    override func keyDown(with event: NSEvent) {
        if model.findByKeys {
            if event.keyCode == 53 { model.findByKeys = false }
            else if let shortcut = OpenCommands.KeyboardShortcut.from(event: event) { model.find(shortcut) }
            return
        }
        if let id = model.recordingCommandID {
            if event.keyCode == 53 { model.cancelRecording() }
            else if event.keyCode == 51 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty { model.clear(id) }
            else if let shortcut = OpenCommands.KeyboardShortcut.from(event: event) { model.record(shortcut, for: id, append: model.appendRecording) }
            return
        }
        if event.keyCode == 36, let id = model.selectedCommandID { model.beginRecording(id); reloadData(); return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if model.recordingCommandID != nil || model.findByKeys { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor private final class SettingsShortcutCell: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let categoryLabel = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let keyButton = SettingsShortcutKeyButton()
    private let reset = SettingsShortcutFocusButton(title: "↺", target: nil, action: nil)
    private let resolve = NSButton(title: "Keep this", target: nil, action: nil)
    private weak var model: ShortcutsViewModel?
    private var command: CommandDefinition?
    private var last = false
    private var changed = false
    private var hovered = false
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        [titleLabel, categoryLabel, detail, keyButton, reset, resolve].forEach(addSubview)
        titleLabel.font = .systemFont(ofSize: 13); titleLabel.lineBreakMode = .byTruncatingTail
        categoryLabel.font = .systemFont(ofSize: 11); detail.font = .systemFont(ofSize: 11.5)
        keyButton.target = self; keyButton.action = #selector(record)
        reset.isBordered = false; reset.target = self; reset.action = #selector(resetShortcut)
        resolve.isBordered = false; resolve.font = .systemFont(ofSize: 11); resolve.target = self; resolve.action = #selector(keepShortcut)
        keyButton.focusChanged = { [weak self] in self?.refreshAffordances() }
        reset.focusChanged = { [weak self] in self?.refreshAffordances() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(command: CommandDefinition, model: ShortcutsViewModel, last: Bool) {
        self.command = command; self.model = model; self.last = last
        changed = model.store.bindings[command.id] != nil
        titleLabel.stringValue = model.displayTitle(command)
        categoryLabel.stringValue = command.scope == .global ? "Global" : ShortcutsViewModel.category(for: command)
        let conflict = model.conflictText(for: command.id)
        detail.stringValue = conflict ?? (command.scope == .global ? "Works when Open is in the background." : "")
        detail.isHidden = detail.stringValue.isEmpty; resolve.isHidden = conflict == nil
        resolve.isEnabled = model.canKeepShortcut(for: command.id)
        keyButton.shortcuts = model.store.effectiveShortcuts(for: command)
        keyButton.recording = model.recordingCommandID == command.id
        keyButton.showAdd = hovered; keyButton.conflict = conflict != nil; keyButton.isEnabled = command.isCustomizable
        keyButton.setAccessibilityLabel((command.isCustomizable ? "Record shortcut for " : "Shortcut for ") + model.displayTitle(command))
        keyButton.setAccessibilityValue(keyButton.shortcuts.map(\.symbolDisplay).joined(separator: ", "))
        reset.setAccessibilityLabel("Reset " + model.displayTitle(command))
        setAccessibilityElement(false); setAccessibilityLabel(model.displayTitle(command) + (changed ? ", changed from default" : ""))
        toolTip = model.displayTitle(command) + (changed ? " · Changed from default" : "")
        refreshAffordances()
        needsLayout = true; needsDisplay = true; keyButton.needsDisplay = true
    }
    override func layout() {
        super.layout()
        let keyWidth = keyButton.recording ? CGFloat(183) : max(80, min(225, keyButton.preferredWidth))
        keyButton.frame = .init(x: bounds.width - keyWidth - 14, y: 9, width: keyWidth, height: 26)
        reset.frame = .init(x: keyButton.frame.minX - 25, y: 10, width: 22, height: 24)
        let labelWidth = max(80, reset.frame.minX - 22)
        let size = (titleLabel.stringValue as NSString).size(withAttributes: [.font: titleLabel.font!])
        titleLabel.frame = .init(x: 14, y: 12, width: labelWidth, height: 20)
        let categoryX = 14 + size.width + 10
        categoryLabel.frame = .init(x: categoryX, y: 14, width: max(0, reset.frame.minX - categoryX - 8), height: 18)
        categoryLabel.isHidden = categoryLabel.frame.width < 35
        resolve.frame = .init(x: bounds.width - 85, y: 34, width: 72, height: 19)
        detail.frame = .init(x: 14, y: 34, width: bounds.width - (resolve.isHidden ? 28 : 108), height: 22)
    }
    override func draw(_ dirtyRect: NSRect) {
        SettingsStyle.card.nsColor.setFill(); bounds.fill()
        if hovered { SettingsStyle.control.nsColor.withAlphaComponent(0.5).setFill(); bounds.fill() }
        titleLabel.textColor = SettingsStyle.text.nsColor; categoryLabel.textColor = SettingsStyle.secondary.nsColor
        detail.textColor = keyButton.conflict ? SettingsStyle.attentionText.nsColor : SettingsStyle.secondary.nsColor
        reset.contentTintColor = SettingsStyle.secondary.nsColor; resolve.contentTintColor = SettingsStyle.attentionText.nsColor
        if changed {
            SettingsStyle.accessibleAccent(model?.root.settingsAccentSource, dark: contentAppearance == .dark).setFill()
            NSBezierPath(ovalIn: .init(x: 5, y: 20, width: 4, height: 4)).fill()
        }
        if !last { SettingsStyle.hairline.nsColor.setFill(); NSRect(x: 14, y: bounds.height - 1, width: bounds.width - 14, height: 1).fill() }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self))
    }
    private func refreshAffordances() {
        let focused = window?.firstResponder === keyButton || window?.firstResponder === reset
        keyButton.showAdd = hovered; keyButton.needsDisplay = true
        reset.isHidden = !changed || !(hovered || focused)
        needsDisplay = true
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; refreshAffordances() }
    override func mouseExited(with event: NSEvent) { hovered = false; refreshAffordances() }
    @objc private func record() { guard let command, let model else { return }; model.beginRecording(command.id, append: NSApp.currentEvent?.modifierFlags.contains(.shift) == true); window?.makeFirstResponder(enclosingScrollView?.documentView) }
    @objc private func resetShortcut() { if let command { model?.reset(command.id) } }
    @objc private func keepShortcut() { if let command { model?.keepShortcut(for: command.id) } }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard command?.isCustomizable == true else { return nil }
        let menu = NSMenu()
        for (title, action) in [("Record Shortcut", #selector(record)), ("Clear Shortcut", #selector(clearShortcut)), ("Reset Shortcut", #selector(resetShortcut))] { let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self }
        for value in ShortcutPriority.allCases {
            let item = menu.addItem(withTitle: value == .browserFirst ? "Open wins" : value == .siteFirst ? "Website wins" : "Website first, Open on double-press", action: #selector(setPriority(_:)), keyEquivalent: "")
            item.representedObject = value.rawValue; item.target = self
        }
        return menu
    }
    @objc private func clearShortcut() { if let command { model?.clear(command.id) } }
    @objc private func setPriority(_ sender: NSMenuItem) { if let command, let raw = sender.representedObject as? String, let value = ShortcutPriority(rawValue: raw) { model?.priority(value, for: command.id) } }
}

@MainActor private class SettingsShortcutFocusButton: NSButton {
    var focusChanged: (() -> Void)?
    override var acceptsFirstResponder: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder(); needsDisplay = true
        DispatchQueue.main.async { [weak self] in self?.focusChanged?() }; return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder(); needsDisplay = true
        DispatchQueue.main.async { [weak self] in self?.focusChanged?() }; return result
    }
}

@MainActor private final class SettingsShortcutKeyButton: SettingsShortcutFocusButton {
    var shortcuts: [OpenCommands.KeyboardShortcut] = []
    var showAdd = false
    var recording = false
    var conflict = false
    override var isFlipped: Bool { true }
    init() { super.init(frame: .zero); isBordered = false; title = ""; setAccessibilityRole(.button) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var preferredWidth: CGFloat { shortcuts.reduce(0) { $0 + CGFloat(caps($1).count) * 25 + 8 } }
    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        if window?.firstResponder === self {
            SettingsStyle.accent.nsColor.withAlphaComponent(0.35).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 7, yRadius: 7)
            ring.lineWidth = 3; ring.stroke()
        }
        if recording {
            SettingsStyle.sunEnd.nsColor.withAlphaComponent(0.12).setFill(); let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7); path.fill()
            SettingsStyle.sunEnd.nsColor.setStroke(); path.lineWidth = 1.5; path.stroke()
            SettingsStyle.sunEnd.nsColor.setFill(); NSBezierPath(ovalIn: .init(x: 10, y: 10, width: 6, height: 6)).fill()
            ("Press a shortcut…  esc" as NSString).draw(at: .init(x: 23, y: 6), withAttributes: [.font: font, .foregroundColor: SettingsStyle.attentionText.nsColor]); return
        }
        if shortcuts.isEmpty { guard isEnabled && (showAdd || window?.firstResponder === self) else { return }; let label = "Add shortcut"; let width = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width; (label as NSString).draw(at: .init(x: bounds.width - width, y: 6), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: SettingsStyle.secondary.nsColor]); return }
        var x = bounds.width
        for shortcut in shortcuts.reversed() {
            for key in caps(shortcut).reversed() {
                let size = (key as NSString).size(withAttributes: [.font: font]); let width = max(22, size.width + 10)
                x -= width
                let rect = NSRect(x: x, y: 2, width: width, height: 22)
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
                SettingsStyle.key.nsColor.setFill(); path.fill()
                (conflict ? SettingsStyle.sunEnd.nsColor : SettingsStyle.keyLine.nsColor).setStroke(); path.lineWidth = 1; path.stroke()
                SettingsStyle.keyLine.nsColor.setFill(); NSRect(x: x + 4, y: 22, width: width - 8, height: 1).fill()
                (key as NSString).draw(at: .init(x: x + (width - size.width) / 2, y: 5), withAttributes: [.font: font, .foregroundColor: SettingsStyle.text.nsColor.withAlphaComponent(isEnabled ? 1 : 0.7)])
                x -= 3
            }
            x -= 5
        }
    }
    private func caps(_ shortcut: OpenCommands.KeyboardShortcut) -> [String] {
        var keys: [String] = []
        if shortcut.modifiers.contains(.control) { keys.append("⌃") }; if shortcut.modifiers.contains(.option) { keys.append("⌥") }
        if shortcut.modifiers.contains(.shift) { keys.append("⇧") }; if shortcut.modifiers.contains(.command) { keys.append("⌘") }
        let key = OpenCommands.KeyboardShortcut.displayKey(shortcut.key); keys.append(key.count == 1 ? key.uppercased() : key); return keys
    }
}
