import AppKit
import OpenDesign
import OpenModel

/// Native folder card. The App places it in the preview panel; it owns no host.
@MainActor
public final class FolderPreviewView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    public let context: SidebarContext
    public let folder: Folder
    public let searchField = NSSearchField()
    public let tableView = FolderPreviewTable()
    private let headerIcon = FolderPreviewIcon()
    private let title = TextLabel()
    private let emptyLabel = TextLabel()
    private let scroll = NSScrollView()
    private var tabs: [Tab] = []
    private var filtered: [Tab] = []
    private var loops: [ObservationLoop] = []
    public var onSelect: (@MainActor (ItemID) -> Void)?

    public init(context: SidebarContext, folder: Folder) {
        self.context = context; self.folder = folder
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 10; layer?.cornerCurve = .continuous; layer?.masksToBounds = true
        headerIcon.folder = folder
        title.text = { [weak folder] in folder?.title ?? "" }; title.font = .systemFont(ofSize: 13, weight: .semibold); title.baseline = 23
        searchField.delegate = self; searchField.placeholderString = "Search tabs"; searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Search folder tabs")
        let column = NSTableColumn(identifier: .init("folder-preview")); tableView.addTableColumn(column)
        tableView.headerView = nil; tableView.rowHeight = HoverPreviewMetrics.rowHeight; tableView.intercellSpacing = .zero
        tableView.style = .plain; tableView.backgroundColor = .clear; tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none; tableView.allowsEmptySelection = true
        tableView.delegate = self; tableView.dataSource = self
        tableView.target = self; tableView.action = #selector(openClickedRow)
        tableView.onOpen = { [weak self] in self?.openSelected() }
        tableView.onEscape = { [weak context] in context?.existingHoverPreviews?.dismiss() }
        scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay; scroll.documentView = tableView
        emptyLabel.font = .systemFont(ofSize: 13); emptyLabel.baseline = 21; emptyLabel.alignment = .center
        emptyLabel.color = { Core.foregroundSecondary.nsColor }
        emptyLabel.text = { [weak self] in self?.searchField.stringValue.isEmpty == false ? "No matching tabs" : "No tabs" }
        emptyLabel.setAccessibilityElement(true); emptyLabel.setAccessibilityRole(.staticText)
        for view in [headerIcon, title, searchField, scroll, emptyLabel] { addSubview(view) }
        rebuild()
        loops.append(ObservationLoop(read: { [weak self] in
            guard let self else { return }
            _ = self.folder.title; _ = self.folder.customIcon
            for tab in self.collectTabs() { _ = tab.title; _ = tab.customTitle; _ = tab.url }
        }) { [weak self] in self?.rebuild() })
        loops.append(ObservationLoop(read: { [weak self] in
            guard let self else { return }; _ = self.context.systemAppearance; _ = self.context.focusedSpace?.theme
        }) { [weak self] in self?.applyAppearance() })
        applyAppearance()
        frame.size = fittingSize
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { loops.forEach { $0.cancel() } }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func keyDown(with event: NSEvent) { tableView.keyDown(with: event) }
    public override var fittingSize: NSSize { CGSize(width: HoverPreviewMetrics.folderWidth, height: HoverPreviewMetrics.headerHeight + (tabs.count > 8 ? 32 : 0) + CGFloat(max(1, min(filtered.count, 10))) * HoverPreviewMetrics.rowHeight) }
    public var displayedTabIDs: [ItemID] { filtered.map(\.id) }
    public var displayedHeaderIcon: String? { folder.customIcon }

    private func collectTabs() -> [Tab] {
        func walk(_ nodes: [SidebarNode]) -> [Tab] {
            nodes.flatMap { node in switch node { case .tab(let tab): [tab]; case .split(let split): split.panes; case .folder(let folder): walk(folder.children) } }
        }
        return walk(folder.children)
    }
    private func rebuild() {
        tabs = collectTabs()
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = query.isEmpty ? tabs : tabs.filter { $0.displayTitle.localizedCaseInsensitiveContains(query) }
        searchField.isHidden = tabs.count <= 8
        emptyLabel.isHidden = !filtered.isEmpty
        emptyLabel.setAccessibilityLabel(emptyLabel.text())
        tableView.reloadData(); needsLayout = true; invalidateIntrinsicContentSize()
    }
    private func applyAppearance() {
        let appearance = context.focusedSpace.map(context.appearance(for:)) ?? context.systemAppearance
        self.appearance = appearance.nsAppearance
        searchField.appearance = self.appearance
        layer?.backgroundColor = PreviewColors.background.cgColor(appearance)
        title.color = { Core.foregroundPrimary.nsColor }
        headerIcon.needsDisplay = true; tableView.needsDisplay = true
    }
    public override func layout() {
        super.layout()
        headerIcon.frame = CGRect(x: 12, y: 10, width: 16, height: 16)
        title.frame = CGRect(x: 36, y: 0, width: max(0, bounds.width - 48), height: 36)
        searchField.frame = CGRect(x: 12, y: 36, width: max(0, bounds.width - 24), height: 24)
        let y: CGFloat = searchField.isHidden ? 36 : 68
        scroll.frame = CGRect(x: 0, y: y, width: bounds.width, height: max(0, bounds.height - y))
        tableView.tableColumns.first?.width = bounds.width
        emptyLabel.frame = CGRect(x: 12, y: y, width: max(0, bounds.width - 24), height: 32)
    }
    public func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("preview-tab"), owner: self) as? FolderPreviewCell ?? FolderPreviewCell()
        cell.identifier = .init("preview-tab"); cell.favicon.context = context; cell.favicon.tab = filtered[row]
        cell.title.text = { [tab = filtered[row]] in tab.displayTitle }
        return cell
    }
    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FolderPreviewRow() }
    public func controlTextDidChange(_ obj: Notification) { rebuild() }
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { openSelected(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { context.existingHoverPreviews?.dismiss(); return true }
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
            let row = selector == #selector(NSResponder.moveDown(_:)) ? 0 : max(filtered.count - 1, 0)
            if filtered.indices.contains(row) { tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); window?.makeFirstResponder(tableView) }
            return true
        }
        return false
    }
    @objc private func openClickedRow() {
        let row = tableView.clickedRow
        guard filtered.indices.contains(row) else { return }
        open(filtered[row])
    }
    private func openSelected() {
        let row = max(tableView.selectedRow, 0)
        guard filtered.indices.contains(row) else { return }; open(filtered[row])
    }
    private func open(_ tab: Tab) {
        context.existingHoverPreviews?.dismiss()
        var parent = context.model.parent(of: tab.id)
        while let current = parent {
            switch current {
            case .folder(let id): context.send(.setExpanded(folderID: id, expanded: true)); parent = context.model.parent(of: id)
            case .splitPane(let id): parent = context.model.parent(of: id)
            case .spacePinned(let id), .spaceToday(let id): context.send(.select(nodeID: tab.id, space: id)); onSelect?(tab.id); return
            case .favorites: return
            }
        }
    }
}

@MainActor
public final class FolderPreviewTable: NSTableView {
    var onOpen: (@MainActor () -> Void)?
    var onEscape: (@MainActor () -> Void)?
    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onOpen?()
        case 53: onEscape?()
        case 125, 126:
            guard numberOfRows > 0 else { return }
            let next = selectedRow < 0 ? 0 : min(max(selectedRow + (event.keyCode == 125 ? 1 : -1), 0), numberOfRows - 1)
            selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false); scrollRowToVisible(next)
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
private final class FolderPreviewRow: NSTableRowView {
    private var hovered = false
    private var tracking: NSTrackingArea?
    override var isSelected: Bool { didSet { needsDisplay = true } }
    override func drawBackground(in dirtyRect: NSRect) {
        guard hovered || isSelected else { return }
        SidebarColors.itemHoveredBackground.nsColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
}
@MainActor
private final class FolderPreviewCell: NSTableCellView {
    let favicon = FaviconView(), title = TextLabel()
    init() {
        super.init(frame: .zero); wantsLayer = true; addSubview(favicon); addSubview(title)
        favicon.inkSize = 16; title.font = .systemFont(ofSize: 13); title.baseline = 21; title.color = { Core.foregroundPrimary.nsColor }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); favicon.frame = CGRect(x: 12, y: 8, width: 16, height: 16); title.frame = CGRect(x: 36, y: 0, width: max(0, bounds.width - 48), height: 32) }
}
@MainActor
private final class FolderPreviewIcon: NSView {
    weak var folder: Folder?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let icon = tracked({ folder?.customIcon }) { [weak self] in self?.needsDisplay = true }
        if let icon {
            if let image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) {
                image.drawTinted(in: bounds, color: Core.foregroundPrimary.nsColor)
            } else { EmojiRenderer.draw(icon, in: bounds) }
            return
        }
        CustomIcon.folder(open: false, in: bounds, color: Core.brandBlue.nsColor)
    }
}
