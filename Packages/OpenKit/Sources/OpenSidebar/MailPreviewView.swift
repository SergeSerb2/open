import AppKit
import OpenDesign
import OpenLiveData
import OpenModel

/// Native Gmail card for a Pinned or Favorite Gmail tab (live-data §3.3): "Unread" header with
/// "+" (New Email), unread rows (subject, sender · time), Arc's empty and signed-out texts.
/// Data comes once per card from the App's mail source (Gmail Atom feed in a hidden page of the
/// Profile; memory only). Same family and measured row height as the Recents card; header,
/// row count and the signed-out layout: GUESS — capture pending (F2 item 9).
@MainActor
public final class MailPreviewView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    public enum Phase: String { case loading, mail, empty, signedOut, failed }
    public let context: SidebarContext
    public let tab: Tab
    public let account: Int
    public let tableView = FolderPreviewTable()
    public let newButton = RecentsNewButton()
    private let header = TextLabel()
    private let separator = NSView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private var loops: [ObservationLoop] = []
    private var loadTask: Task<Void, Never>?
    public private(set) var mail: [UnreadMail] = []
    public private(set) var phase: Phase = .loading
    public var isLoaded: Bool { phase != .loading }
    public var onOpen: (@MainActor (URL) -> Void)?
    public var onResize: (@MainActor () -> Void)?

    public init(context: SidebarContext, tab: Tab, account: Int) {
        self.context = context; self.tab = tab; self.account = account
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = HoverPreviewMetrics.radius; layer?.cornerCurve = .continuous; layer?.masksToBounds = true
        header.font = .systemFont(ofSize: 13, weight: .semibold); header.baseline = 25
        header.color = { Core.foregroundPrimary.nsColor }; header.text = { GmailGlance.header }
        header.setAccessibilityElement(true); header.setAccessibilityRole(.staticText); header.setAccessibilityLabel(GmailGlance.header)
        newButton.toolTip = GmailGlance.newLabel; newButton.setAccessibilityLabel(GmailGlance.newLabel)
        newButton.onPress = { [weak self] in self?.openNew() }
        separator.wantsLayer = true
        let column = NSTableColumn(identifier: .init("mail")); tableView.addTableColumn(column)
        tableView.headerView = nil; tableView.rowHeight = HoverPreviewMetrics.rowHeight; tableView.intercellSpacing = .zero
        tableView.style = .plain; tableView.backgroundColor = .clear; tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none; tableView.allowsEmptySelection = true
        tableView.delegate = self; tableView.dataSource = self
        tableView.target = self; tableView.action = #selector(openClickedRow)
        tableView.onOpen = { [weak self] in self?.open(row: max(self?.tableView.selectedRow ?? 0, 0)) }
        tableView.onEscape = { [weak context] in context?.existingHoverPreviews?.dismiss() }
        tableView.setAccessibilityLabel(GmailGlance.header)
        scroll.drawsBackground = false; scroll.borderType = .noBorder; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay; scroll.documentView = tableView
        messageLabel.font = .systemFont(ofSize: 13); messageLabel.alignment = .center; messageLabel.isHidden = true
        for view in [header, newButton, separator, scroll, messageLabel] { addSubview(view) }
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
        let body = mail.isEmpty ? RecentsPreviewView.emptyHeight : CGFloat(min(mail.count, m.maxVisibleRows)) * m.rowHeight + m.bottomPadding
        return CGSize(width: m.folderWidth, height: RecentsPreviewView.headerHeight + body)
    }

    /// The text shown instead of rows, if any.
    public var message: String? {
        switch phase {
        case .empty: GmailGlance.emptyText
        case .signedOut, .failed: GmailGlance.signedOutText
        case .loading, .mail: nil
        }
    }

    private func load() {
        guard let source = context.mailGlanceSource,
              let profile = context.focusedSpace?.profileID ?? context.model.profiles.first?.id else { finish(.failed); return }
        let feed = GmailGlance.feedURL(for: tab.url, account: account), host = tab.url.host ?? GmailGlance.host
        loadTask = Task { [weak self] in
            let result = await source(profile, feed, host)
            guard !Task.isCancelled else { return }
            self?.finish(result)
        }
    }
    private func finish(_ result: MailGlanceResult) {
        switch result {
        case .mail(let rows): mail = Array(rows.prefix(GmailGlance.limit)); phase = mail.isEmpty ? .empty : .mail
        case .signedOut: mail = []; phase = .signedOut
        case .failed: mail = []; phase = .failed
        }
        messageLabel.stringValue = message ?? ""; messageLabel.isHidden = message == nil
        messageLabel.setAccessibilityLabel(message)
        tableView.reloadData(); needsLayout = true
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
        messageLabel.textColor = ink
        header.needsDisplay = true; tableView.needsDisplay = true
    }

    public override func layout() {
        super.layout()
        let h = RecentsPreviewView.headerHeight
        header.frame = CGRect(x: 14, y: 0, width: max(0, bounds.width - 60), height: h)
        newButton.frame = CGRect(x: bounds.width - 10 - 24, y: (h - 24) / 2, width: 24, height: 24)
        separator.frame = CGRect(x: 0, y: h - 1, width: bounds.width, height: 1)
        scroll.frame = CGRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h - 4))
        tableView.tableColumns.first?.width = bounds.width
        let text = messageLabel.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: bounds.width - 40, height: 200)).height ?? 18
        messageLabel.frame = CGRect(x: 20, y: h + (RecentsPreviewView.emptyHeight - text) / 2, width: max(0, bounds.width - 40), height: text)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { mail.count }
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("mail-row"), owner: self) as? FolderPreviewCell ?? FolderPreviewCell(titleWeight: .regular)
        cell.identifier = .init("mail-row"); cell.favicon.context = context; cell.favicon.tab = tab
        let item = mail[row]
        cell.title.text = { item.title }
        cell.subtitle.text = { [item.author, item.date.map { FolderPreviewCell.ago($0) } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ") }
        cell.setAccessibilityElement(true); cell.setAccessibilityRole(.button); cell.setAccessibilityLabel(item.title)
        return cell
    }
    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FolderPreviewRow() }

    /// Opens row `index` as a Peek (Arc: preview links open as Peeks, LD §3.3).
    public func open(row index: Int) {
        guard mail.indices.contains(index) else { return }
        let url = mail[index].url
        context.existingHoverPreviews?.dismiss()
        onOpen?(url)
    }
    @objc private func openClickedRow() { open(row: tableView.clickedRow) }
    public func openNew() {
        context.existingHoverPreviews?.dismiss()
        onOpen?(GmailGlance.composeURL(for: tab.url, account: account))
    }
}
