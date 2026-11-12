import AppKit
import OpenDesign
import OpenLiveData
import OpenModel

/// Native Recents card for a Pinned or Favorite Linear, Notion, Figma, or Confluence tab
/// (docs/re/live-data.md §3.4). Rows come from the Profile's own history, filled once when the
/// card opens; there is no network and no timer. Strings are Arc facts (LD §3.4). Geometry
/// follows the measured folder card (240 wide, 45 pt rows) — GUESS, capture pending (F2 item 10):
/// header height, header type, "+" button size, and the empty-text layout.
@MainActor
public final class RecentsPreviewView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    public let context: SidebarContext
    public let tab: Tab
    public let site: RecentsSite
    public let tableView = FolderPreviewTable()
    public let newButton = RecentsNewButton()
    private let header = TextLabel()
    private let separator = NSView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private var loops: [ObservationLoop] = []
    private var loadTask: Task<Void, Never>?
    public private(set) var pages: [RecentPage] = []
    /// True once the history read finished (rows or empty text shown).
    public private(set) var isLoaded = false
    /// Opens a row or the "+" target; the App shows it as a Peek of `tab` (LD §3.3 "Links").
    public var onOpen: (@MainActor (URL) -> Void)?
    /// Called after a load changes the card's fitting height.
    public var onResize: (@MainActor () -> Void)?

    /// Header 40 pt (GUESS — capture pending), rows as the folder card (measured 45).
    public static let headerHeight: CGFloat = 40
    public static let emptyHeight: CGFloat = 64

    public init(context: SidebarContext, tab: Tab, site: RecentsSite) {
        self.context = context; self.tab = tab; self.site = site
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = HoverPreviewMetrics.radius; layer?.cornerCurve = .continuous; layer?.masksToBounds = true
        header.font = .systemFont(ofSize: 13, weight: .semibold); header.baseline = 25
        header.color = { Core.foregroundPrimary.nsColor }; header.text = { RecentsSite.header }
        header.setAccessibilityElement(true); header.setAccessibilityRole(.staticText); header.setAccessibilityLabel(RecentsSite.header)
        newButton.toolTip = site.newLabel
        newButton.setAccessibilityLabel(site.newLabel)
        newButton.onPress = { [weak self] in self?.openNew() }
        separator.wantsLayer = true
        let column = NSTableColumn(identifier: .init("recents")); tableView.addTableColumn(column)
        tableView.headerView = nil; tableView.rowHeight = HoverPreviewMetrics.rowHeight; tableView.intercellSpacing = .zero
        tableView.style = .plain; tableView.backgroundColor = .clear; tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none; tableView.allowsEmptySelection = true
        tableView.delegate = self; tableView.dataSource = self
        tableView.target = self; tableView.action = #selector(openClickedRow)
        tableView.onOpen = { [weak self] in self?.openSelected() }
        tableView.onEscape = { [weak context] in context?.existingHoverPreviews?.dismiss() }
        tableView.setAccessibilityLabel(RecentsSite.header)
        scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay; scroll.documentView = tableView
        emptyLabel.font = .systemFont(ofSize: 13); emptyLabel.alignment = .center
        emptyLabel.textColor = Core.foregroundSecondary.nsColor; emptyLabel.stringValue = site.emptyText
        emptyLabel.isHidden = true
        for view in [header, newButton, separator, scroll, emptyLabel] { addSubview(view) }
        loops.append(ObservationLoop(read: { [weak self] in
            guard let self else { return }; _ = self.context.systemAppearance; _ = self.context.focusedSpace?.theme
        }) { [weak self] in self?.applyAppearance() })
        applyAppearance()
        frame.size = fittingSize
        load()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { loops.forEach { $0.cancel() }; loadTask?.cancel() }
    public override var isFlipped: Bool { true }

    public override var fittingSize: NSSize {
        let m = HoverPreviewMetrics.self
        let body = pages.isEmpty ? Self.emptyHeight : CGFloat(min(pages.count, m.maxVisibleRows)) * m.rowHeight + m.bottomPadding
        return CGSize(width: m.folderWidth, height: Self.headerHeight + body)
    }

    /// One history read per card (the card is made on hover, so nothing runs before).
    private func load() {
        guard let source = context.recentPagesSource,
              let profile = context.focusedSpace?.profileID ?? context.model.profiles.first?.id else { finish([]); return }
        let site = site, aliases = context.glanceHostAliases
        loadTask = Task { [weak self] in
            let rows = await source(profile, site.historyPhrases(aliases: aliases))
            guard !Task.isCancelled else { return }
            self?.finish(RecentPages.select(rows, site: site, aliases: aliases))
        }
    }
    private func finish(_ next: [RecentPage]) {
        pages = next; isLoaded = true
        emptyLabel.isHidden = !pages.isEmpty
        emptyLabel.setAccessibilityLabel(site.emptyText)
        tableView.reloadData()
        needsLayout = true
        onResize?()
    }

    private func applyAppearance() {
        let appearance = context.focusedSpace.map(context.appearance(for:)) ?? context.systemAppearance
        self.appearance = appearance.nsAppearance
        layer?.backgroundColor = PreviewColors.background.cgColor(appearance)
        layer?.borderWidth = appearance == .dark ? 1 : 0
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        separator.layer?.backgroundColor = (appearance == .dark ? NSColor.white : NSColor.black).withAlphaComponent(0.10).cgColor
        var ink = NSColor.secondaryLabelColor
        appearance.nsAppearance.performAsCurrentDrawingAppearance { ink = Core.foregroundSecondary.nsColor.usingColorSpace(.sRGB) ?? ink }
        newButton.ink = ink
        emptyLabel.textColor = Core.foregroundSecondary.nsColor
        header.needsDisplay = true; tableView.needsDisplay = true
    }

    public override func layout() {
        super.layout()
        let h = Self.headerHeight
        header.frame = CGRect(x: 14, y: 0, width: max(0, bounds.width - 60), height: h)
        newButton.frame = CGRect(x: bounds.width - 10 - 24, y: (h - 24) / 2, width: 24, height: 24)
        separator.frame = CGRect(x: 0, y: h - 1, width: bounds.width, height: 1)
        scroll.frame = CGRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h - 4))
        tableView.tableColumns.first?.width = bounds.width
        let text = emptyLabel.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: bounds.width - 40, height: 200)).height ?? 18
        emptyLabel.frame = CGRect(x: 20, y: h + (Self.emptyHeight - text) / 2, width: max(0, bounds.width - 40), height: text)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { pages.count }
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("recents-page"), owner: self) as? FolderPreviewCell ?? FolderPreviewCell()
        cell.identifier = .init("recents-page"); cell.favicon.context = context; cell.favicon.tab = tab
        let page = pages[row]
        cell.title.text = { page.title }
        cell.subtitle.text = { FolderPreviewCell.ago(page.lastVisit) }
        cell.setAccessibilityElement(true); cell.setAccessibilityRole(.button); cell.setAccessibilityLabel(page.title)
        return cell
    }
    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FolderPreviewRow() }

    /// Opens row `index` through the same path as a click (automation and keyboard use it).
    public func open(row index: Int) {
        guard pages.indices.contains(index) else { return }
        let url = pages[index].url
        context.existingHoverPreviews?.dismiss()
        onOpen?(url)
    }
    @objc private func openClickedRow() { open(row: tableView.clickedRow) }
    private func openSelected() { open(row: max(tableView.selectedRow, 0)) }
    @objc public func openNew() {
        context.existingHoverPreviews?.dismiss()
        onOpen?(site.newURL)
    }
}

/// The card's "+" (SF Symbol "plus", drawn in the card's own ink so it follows the Space's
/// appearance, not the system's). 24 pt hit area, 13 pt glyph (GUESS — capture pending).
@MainActor
public final class RecentsNewButton: NSView {
    var onPress: (@MainActor () -> Void)?
    var ink: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    private var hovered = false
    private var tracking: NSTrackingArea?
    public override var isFlipped: Bool { true }
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .button }
    public override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func draw(_ dirtyRect: NSRect) {
        if hovered {
            ink.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        guard let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium).applying(.init(paletteColors: [ink]))) else { return }
        let size = symbol.size
        symbol.draw(in: CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    public override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    public override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    public override func mouseDown(with event: NSEvent) {}
    public override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
}
