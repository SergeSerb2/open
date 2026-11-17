import AppKit
import OpenDesign
import OpenModel

public enum IconTarget: String, Sendable { case space, tab, folder, profile }
public enum IconPickerPage: Int, Sendable { case emoji, icons }

@MainActor
public final class IconPickerView: NSView, NSSearchFieldDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate {
    public static let size = CGSize(width: 246, height: 300)
    public static let columns = 7
    public let pages = NSSegmentedControl(labels: ["Emoji", "Icons"], trackingMode: .selectOne, target: nil, action: nil)
    public let search = NSSearchField()
    public let collection = NSCollectionView()
    public let scroll = NSScrollView()
    public let remove = NSButton(title: "Remove icon", target: nil, action: nil)
    public let message = NSTextField(labelWithString: "Loading emoji…")
    public private(set) var page: IconPickerPage
    public private(set) var entries: [EmojiEntry] = []
    public private(set) var visibleEntries: [EmojiEntry] = []
    public private(set) var focusedIndex: Int?
    public private(set) var highlightedCategory = 0
    public var onPick: (@MainActor (SpaceIcon?) -> Void)?
    public var onTones: (@MainActor (EmojiEntry, NSView) -> Void)?
    public var onEscape: (@MainActor () -> Void)?
    private let current: SpaceIcon?
    private var categoryButtons: [NSButton] = []
    private let categories = NSView()
    private let categoryHairline = CALayer()
    private let flow = NSCollectionViewFlowLayout()
    private var searchTask: Task<Void, Never>?
    private var scrollObserver: NSObjectProtocol?
    private let hasIcon: Bool

    public init(target: IconTarget, current: SpaceIcon?) {
        self.current = current; hasIcon = current != nil
        page = target == .folder ? .icons : .emoji
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        pages.selectedSegment = page.rawValue; pages.target = self; pages.action = #selector(changePage)
        pages.setAccessibilityLabel("Icon type")
        search.placeholderString = "Search"; search.delegate = self
        search.maximumRecents = 0; search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Search emoji")
        flow.itemSize = CGSize(width: 28, height: 28)
        flow.minimumInteritemSpacing = 5; flow.minimumLineSpacing = 2
        flow.sectionInset = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        collection.collectionViewLayout = flow
        collection.register(PickerItem.self, forItemWithIdentifier: PickerItem.identifier)
        collection.dataSource = self; collection.delegate = self
        collection.backgroundColors = [.clear]; collection.isSelectable = false
        scroll.documentView = collection; scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCategory() }
        }
        remove.isBordered = false; remove.font = .systemFont(ofSize: 11)
        remove.contentTintColor = .secondaryLabelColor; remove.alignment = .left
        remove.target = self; remove.action = #selector(removeIcon); remove.isHidden = !hasIcon
        message.font = .systemFont(ofSize: 12); message.textColor = .secondaryLabelColor; message.alignment = .center
        for view in [pages, search, scroll, categories, remove, message] { addSubview(view) }
        let symbols = ["face.smiling", "leaf", "fork.knife", "sportscourt", "airplane", "lightbulb", "heart", "flag"]
        let names = ["Smileys & People", "Animals & Nature", "Food & Drink", "Activities", "Travel & Places", "Objects", "Symbols", "Flags"]
        for (index, symbol) in symbols.enumerated() {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: names[index])!, target: self, action: #selector(selectCategory(_:)))
            button.isBordered = false; button.tag = index; button.toolTip = names[index]; button.setAccessibilityLabel(names[index])
            categories.addSubview(button); categoryButtons.append(button)
        }
        categories.wantsLayer = true
        categories.layer?.addSublayer(categoryHairline)
        applyPage()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }; searchTask?.cancel() }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func layout() {
        super.layout()
        pages.frame = CGRect(x: 8, y: 8, width: 230, height: 24)
        search.frame = CGRect(x: 8, y: 40, width: 230, height: 24)
        let bottom: CGFloat = hasIcon ? 28 : 0
        let categoryHeight: CGFloat = page == .emoji ? 28 : 0
        let top: CGFloat = page == .emoji ? 70 : 40
        scroll.frame = CGRect(x: 0, y: top, width: 246, height: 300 - top - bottom - categoryHeight)
        categories.frame = CGRect(x: 0, y: 300 - bottom - 28, width: 246, height: 28)
        remove.frame = CGRect(x: 10, y: 273, width: 120, height: 22)
        message.frame = CGRect(x: 10, y: top + 35, width: 226, height: 22)
        for (index, button) in categoryButtons.enumerated() {
            button.frame = CGRect(x: 7 + CGFloat(index) * 29, y: 3, width: 27, height: 24)
        }
        categoryHairline.frame = CGRect(x: 0, y: 27, width: 246, height: 1)
        categoryHairline.backgroundColor = NSColor.separatorColor.cgColor
    }
    public func load(_ index: EmojiIndex) {
        entries = index.entries; filter()
    }
    public func loadFailed() { message.stringValue = "Emoji could not load"; message.isHidden = page != .emoji }
    public func stop() {
        searchTask?.cancel(); searchTask = nil
        for item in collection.visibleItems() { (item as? PickerItem)?.cell.stop() }
    }
    public func selectPage(_ page: IconPickerPage) { self.page = page; pages.selectedSegment = page.rawValue; applyPage() }
    @objc private func changePage() { selectPage(IconPickerPage(rawValue: pages.selectedSegment) ?? .emoji) }
    private func applyPage() {
        searchTask?.cancel(); page = IconPickerPage(rawValue: pages.selectedSegment) ?? .emoji
        search.isHidden = page != .emoji; categories.isHidden = page != .emoji
        flow.minimumLineSpacing = page == .icons ? 5 : 2
        focusedIndex = nil; filter(); needsLayout = true; layoutSubtreeIfNeeded()
    }
    @objc private func removeIcon() { onPick?(nil) }
    public func controlTextDidChange(_ obj: Notification) {
        if search.stringValue.count > 128 { search.stringValue = String(search.stringValue.prefix(128)) }
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            self?.filter(); self?.searchTask = nil
        }
    }
    private func filter() {
        let words = search.stringValue.lowercased().split(whereSeparator: \.isWhitespace)
        visibleEntries = words.isEmpty ? entries : entries.filter { entry in
            words.allSatisfy { entry.name.localizedStandardContains(String($0)) || entry.value.contains($0) }
        }
        focusedIndex = nil
        message.stringValue = entries.isEmpty ? "Loading emoji…" : "No emoji found"
        message.isHidden = page != .emoji || !visibleEntries.isEmpty
        collection.reloadData(); collection.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero); updateCategory()
    }
    public func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        page == .icons ? NamedSpaceIcons.order.count : visibleEntries.count
    }
    public func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: PickerItem.identifier, for: indexPath) as! PickerItem
        let index = indexPath.item
        let value: SpaceIcon
        let label: String
        if page == .icons { let id = NamedSpaceIcons.order[index]; value = .named(id); label = id }
        else { let entry = visibleEntries[index]; value = .emoji(entry.value); label = entry.name }
        item.cell.value = value; item.cell.selected = value == current; item.cell.ring = index == focusedIndex
        item.cell.setAccessibilityLabel(label); item.cell.toolTip = label
        item.cell.setAccessibilityValue(value == current ? "Selected" : "")
        item.cell.onPick = { [weak self] in self?.onPick?(value) }
        item.cell.onTones = nil
        if page == .emoji && visibleEntries[index].tones.count > 1 {
            item.cell.onTones = { [weak self, weak cell = item.cell] in
            guard let self, let cell, self.page == .emoji, self.visibleEntries.indices.contains(index) else { return }
            self.onTones?(self.visibleEntries[index], cell)
            }
        }
        item.cell.needsDisplay = true
        return item
    }
    @objc private func selectCategory(_ sender: NSButton) {
        if !search.stringValue.isEmpty { search.stringValue = ""; filter() }
        guard let index = visibleEntries.firstIndex(where: { $0.category == sender.tag }) else { return }
        collection.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .top)
        highlightedCategory = sender.tag; highlightCategory()
    }
    private func updateCategory() {
        guard page == .emoji,
              let first = collection.indexPathsForVisibleItems().min(by: { $0.item < $1.item }),
              visibleEntries.indices.contains(first.item) else { return }
        highlightedCategory = visibleEntries[first.item].category; highlightCategory()
    }
    private func highlightCategory() {
        for button in categoryButtons {
            button.contentTintColor = button.tag == highlightedCategory ? .labelColor : .tertiaryLabelColor
            button.setAccessibilityValue(button.tag == highlightedCategory ? "Selected" : "")
        }
    }
    /// Called by the panel's event path, also while the search field owns focus.
    @discardableResult public func handleKey(_ event: NSEvent) -> Bool {
        // The panel sees keys before the input method: while the search field composes (IME),
        // Escape, Return, and the arrows belong to the composition.
        if (search.currentEditor() as? NSTextView)?.hasMarkedText() == true { return false }
        if event.keyCode == 53 { onEscape?(); return true }
        let count = page == .icons ? NamedSpaceIcons.order.count : visibleEntries.count
        if [123, 124, 125, 126].contains(event.keyCode) {
            guard count > 0 else { return true }
            let delta = [123: -1, 124: 1, 125: 7, 126: -7][Int(event.keyCode)]!
            focusedIndex = focusedIndex.map { min(count - 1, max(0, $0 + delta)) } ?? 0
            collection.reloadData()
            collection.scrollToItems(at: [IndexPath(item: focusedIndex!, section: 0)], scrollPosition: .nearestHorizontalEdge)
            return true
        }
        if event.keyCode == 36, let index = focusedIndex, index < count {
            onPick?(page == .icons ? .named(NamedSpaceIcons.order[index]) : .emoji(visibleEntries[index].value)); return true
        }
        if page == .emoji, !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        if page == .emoji, let chars = event.characters, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
           window?.firstResponder !== search.currentEditor() {
            window?.makeFirstResponder(search); search.currentEditor()?.insertText(chars)
            return true
        }
        return false
    }
    public override func keyDown(with event: NSEvent) { if !handleKey(event) { super.keyDown(with: event) } }
    public func controlFrame(_ name: String, index: Int = 0) -> CGRect? {
        switch name {
        case "emoji": return CGRect(x: 10, y: 8, width: 110, height: 24)
        case "icons": return CGRect(x: 126, y: 8, width: 110, height: 24)
        case "search": return search.frame
        case "remove": return remove.isHidden ? nil : remove.frame
        case "item": return itemFrame(at: index)
        default:
            if name.hasPrefix("category-"), let index = Int(name.dropFirst(9)), categoryButtons.indices.contains(index) {
                return convert(categoryButtons[index].bounds, from: categoryButtons[index])
            }
            return nil
        }
    }
    public func itemFrame(at index: Int) -> CGRect? {
        guard let frame = collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return nil }
        return convert(frame, from: collection)
    }
}

@MainActor private final class PickerItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("OpenIconPickerCell")
    var cell: PickerCell { view as! PickerCell }
    override func loadView() { view = PickerCell(frame: CGRect(x: 0, y: 0, width: 28, height: 28)) }
    override func prepareForReuse() { super.prepareForReuse(); cell.stop(); cell.onPick = nil; cell.onTones = nil }
}

@MainActor private final class PickerCell: NSView {
    var value: SpaceIcon = .named("star")
    var selected = false
    var ring = false
    var hovered = false
    var onPick: (@MainActor () -> Void)?
    var onTones: (@MainActor () -> Void)?
    private var hold: Task<Void, Never>?
    private var tracking: NSTrackingArea?
    private var openedTones = false
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(true); setAccessibilityRole(.button) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        tracking = area; addTrackingArea(area); super.updateTrackingAreas()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; stop(); needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        openedTones = false
        if event.modifierFlags.contains(.control), let onTones { openedTones = true; onTones(); return }
        if onTones != nil {
            hold = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self else { return }
                self.openedTones = true; self.onTones?(); self.hold = nil
            }
        }
    }
    override func mouseUp(with event: NSEvent) {
        stop(); if !openedTones && bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?() }
    }
    override func rightMouseDown(with event: NSEvent) { onTones?() }
    override func accessibilityPerformPress() -> Bool { onPick?(); return true }
    func stop() { hold?.cancel(); hold = nil }
    override func draw(_ dirtyRect: NSRect) {
        if selected || hovered {
            (selected ? SidebarRole.rowSelected : SidebarColors.itemBackground).nsColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        if ring {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            path.lineWidth = 2; path.stroke()
        }
        switch value {
        case .named(let id), .symbol(let id):
            if let image = NSImage(systemSymbolName: (NamedSpaceIcons.symbols[id] ?? id), accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .medium)) {
                let size = image.size; let rect = CGRect(x: (28 - size.width) / 2, y: (28 - size.height) / 2, width: size.width, height: size.height)
                let tinted = image.copy() as! NSImage
                tinted.lockFocus(); SidebarRole.spaceTitle.nsColor.set(); NSRect(origin: .zero, size: size).fill(using: .sourceIn); tinted.unlockFocus()
                tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        case .emoji(let string):
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont(name: "AppleColorEmoji", size: 20) ?? NSFont.systemFont(ofSize: 20)]
            let text = NSAttributedString(string: string, attributes: attributes); let size = text.size()
            text.draw(at: CGPoint(x: (28 - size.width) / 2, y: (28 - size.height) / 2))
        }
    }
}
