import AppKit
import OpenModel
import OpenDesign

/// Developer Mode's content panel (Arc `ContentPanel`): a bar over the page for a Developer Mode site.
/// Evidence: capture session 3 `s7/12-devoff/d-devmode-on` (a 40 pt bar at the top of the content card; an "i" at
/// x 22, the full URL in a monospaced face from x 41.5; four right groups at 28 pt pitch: link | window screenshot,
/// camera | console, network, inspect | extensions, split view), and Arc strings `ContentPanel/ContentPanelView.swift`
/// "Developer console button", "Toggle Network Panel", "Inspect element button", "Extensions button",
/// "Site settings button" / "View Site Settings". Hover, pressed and light-theme looks: GUESS — capture PB3-a.
public enum DeveloperPanelAction: String, CaseIterable, Sendable {
    case siteSettings, copyURL, windowScreenshot, capture, console, network, inspect, extensions, splitMenu
}

public enum DeveloperPanelMetrics {
    public static let height: CGFloat = 40
    static let infoCenterX: CGFloat = 22
    static let urlX: CGFloat = 41.5
    static let buttonSize: CGFloat = 28
    /// Button centers measured from the card's right edge, in group order.
    static let rightCenters: [(DeveloperPanelAction, CGFloat)] = [
        (.splitMenu, 19), (.extensions, 46.7), (.inspect, 91.5), (.network, 119.3), (.console, 147.3),
        (.capture, 191.7), (.windowScreenshot, 219.7), (.copyURL, 275.5),
    ]
    /// Thin separators between the groups (midpoints of the measured gaps).
    static let separators: [CGFloat] = [69.1, 169.5, 247.6]
}

@MainActor
public final class DeveloperContentPanelView: NSView {
    public var onAction: ((DeveloperPanelAction, NSView) -> Void)?
    public var urlString = "" { didSet { if urlString != oldValue { urlLabel.stringValue = urlString; needsLayout = true } } }
    /// The bar's fill; the ink follows its brightness.
    public var fill: NSColor = .white { didSet { if fill != oldValue { applyColors() } } }
    /// The network button shows its pressed state while the list is open.
    public var networkShown = false { didSet { if networkShown != oldValue { buttons[.network]?.state = networkShown ? .on : .off; applyColors() } } }
    private let urlLabel = NSTextField(labelWithString: "")
    private var buttons: [DeveloperPanelAction: NSButton] = [:]
    private var separatorLayers: [CALayer] = []

    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        urlLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        urlLabel.lineBreakMode = .byTruncatingMiddle; urlLabel.cell?.usesSingleLineMode = true
        urlLabel.setAccessibilityLabel("Page URL")
        addSubview(urlLabel)
        let specs: [(DeveloperPanelAction, String, String)] = [
            (.siteSettings, "info", "View Site Settings"), (.copyURL, "link", "Copy Current URL"),
            (.windowScreenshot, "photo.on.rectangle", "Capture Window Screenshot"), (.capture, "camera", "Capture"),
            (.console, "apple.terminal", "Developer Console"), (.network, "globe", "Toggle Network Panel"),
            (.inspect, "scope", "Inspect Element"), (.extensions, "puzzlepiece.extension", "Extensions"),
            (.splitMenu, "square.split.2x1", "Split View Menu"),
        ]
        for (action, symbol, title) in specs {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: self, action: #selector(press(_:)))
            button.isBordered = false; button.bezelStyle = .regularSquare; button.imagePosition = .imageOnly
            button.setButtonType(action == .network ? .pushOnPushOff : .momentaryChange)
            button.symbolConfiguration = .init(pointSize: action == .siteSettings ? 13 : 15, weight: .regular)
            button.toolTip = title; button.setAccessibilityLabel(title); button.identifier = .init("developer-" + action.rawValue)
            addSubview(button); buttons[action] = button
        }
        for _ in DeveloperPanelMetrics.separators { let line = CALayer(); layer?.addSublayer(line); separatorLayers.append(line) }
        setAccessibilityElement(true); setAccessibilityRole(.toolbar); setAccessibilityLabel("Developer Mode")
        applyColors()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func press(_ sender: NSButton) {
        guard let action = buttons.first(where: { $0.value === sender })?.key else { return }
        onAction?(action, sender)
    }
    public func button(_ action: DeveloperPanelAction) -> NSView? { buttons[action] }

    private var ink: NSColor {
        let rgb = fill.usingColorSpace(.sRGB) ?? fill
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance < 0.62 ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.62)
    }
    private func applyColors() {
        layer?.backgroundColor = fill.cgColor
        let ink = ink
        urlLabel.textColor = ink
        for (action, button) in buttons { button.contentTintColor = action == .network && networkShown ? ink : ink.withAlphaComponent(ink.alphaComponent * 0.95) }
        buttons[.network]?.layer?.backgroundColor = networkShown ? ink.withAlphaComponent(0.16).cgColor : nil
        buttons[.network]?.layer?.cornerRadius = 6
        for line in separatorLayers { line.backgroundColor = ink.withAlphaComponent(0.14).cgColor }
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, mid = bounds.height / 2, size = DeveloperPanelMetrics.buttonSize
        buttons[.network]?.wantsLayer = true
        buttons[.siteSettings]?.frame = CGRect(x: DeveloperPanelMetrics.infoCenterX - size / 2, y: mid - size / 2, width: size, height: size)
        var leftmostRight = w
        for (action, fromRight) in DeveloperPanelMetrics.rightCenters {
            let frame = CGRect(x: w - fromRight - size / 2, y: mid - size / 2, width: size, height: size)
            buttons[action]?.frame = frame; leftmostRight = min(leftmostRight, frame.minX)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (line, fromRight) in zip(separatorLayers, DeveloperPanelMetrics.separators) {
            line.frame = CGRect(x: w - fromRight, y: mid - 10, width: 1, height: 20)
        }
        CATransaction.commit()
        let urlWidth = max(0, leftmostRight - 12 - DeveloperPanelMetrics.urlX)
        urlLabel.frame = CGRect(x: DeveloperPanelMetrics.urlX, y: mid - 8, width: urlWidth, height: 16)
    }
}

// MARK: - Network list

/// Requests of one page, from DevTools protocol `Network.*` events. Bounded; the oldest entries drop first.
@MainActor
public final class NetworkLog {
    public struct Entry: Equatable, Sendable {
        public var id: String
        public var url: String
        public var method: String
        public var type: String
        public var status: Int?
        public var size: Int?
        public var start: Double
        public var end: Double?
        public var failed: String?
        public var name: String { URL(string: url).map { $0.lastPathComponent.isEmpty || $0.path == "/" ? ($0.host() ?? url) : $0.lastPathComponent } ?? url }
        public var durationMS: Double? { end.map { max(0, ($0 - start) * 1000) } }
    }
    /// At most this many requests per page; a URL is cut at 2,048 characters.
    public static let maxEntries = 1_000
    public static let maxURLLength = 2_048
    public private(set) var entries: [Entry] = []
    private var index: [String: Int] = [:]
    /// The top frame's ID, learnt from `Page.frameNavigated` without a parent.
    private var mainFrameID: String?
    public var onChange: (() -> Void)?
    public init() {}

    public func clear() { entries.removeAll(); index.removeAll(); onChange?() }

    /// One DevTools protocol event. Unknown methods are ignored.
    public func handle(_ method: String, _ p: [String: Any]) {
        switch method {
        case "Page.frameNavigated":
            if let frame = p["frame"] as? [String: Any], frame["parentId"] == nil { mainFrameID = frame["id"] as? String }
        case "Network.requestWillBeSent":
            guard let id = p["requestId"] as? String, let request = p["request"] as? [String: Any],
                  let url = request["url"] as? String else { return }
            // A new top-level document starts a new list (DevTools' default, "Preserve log" off). Chromium sends the
            // document request before `Page.frameNavigated`, so the clear happens here: a navigation request
            // (requestId == loaderId) of type Document in the top frame, not a redirect hop of the same request.
            if (p["type"] as? String) == "Document", id == (p["loaderId"] as? String), p["redirectResponse"] == nil,
               mainFrameID == nil || (p["frameId"] as? String) == mainFrameID {
                entries.removeAll(); index.removeAll()
            }
            let entry = Entry(id: id, url: String(url.prefix(Self.maxURLLength)), method: (request["method"] as? String) ?? "GET",
                              type: (p["type"] as? String) ?? "Other", start: (p["timestamp"] as? Double) ?? 0)
            if let i = index[id] { entries[i] = entry } // a redirect reuses the request ID
            else {
                if entries.count >= Self.maxEntries {
                    entries.removeFirst(entries.count - Self.maxEntries + 1)
                    index = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.id, $0) })
                }
                index[id] = entries.count; entries.append(entry)
            }
            onChange?()
        case "Network.responseReceived":
            guard let id = p["requestId"] as? String, let i = index[id], let response = p["response"] as? [String: Any] else { return }
            entries[i].status = (response["status"] as? NSNumber)?.intValue
            if let type = p["type"] as? String { entries[i].type = type }
            onChange?()
        case "Network.loadingFinished":
            guard let id = p["requestId"] as? String, let i = index[id] else { return }
            entries[i].size = (p["encodedDataLength"] as? NSNumber)?.intValue
            entries[i].end = p["timestamp"] as? Double
            onChange?()
        case "Network.loadingFailed":
            guard let id = p["requestId"] as? String, let i = index[id] else { return }
            entries[i].failed = (p["canceled"] as? Bool) == true ? "(canceled)" : String(((p["errorText"] as? String) ?? "(failed)").prefix(120))
            entries[i].end = p["timestamp"] as? Double
            onChange?()
        default: return
        }
    }

    public var summary: String {
        let bytes = entries.compactMap(\.size).reduce(0, +)
        let count = entries.count == 1 ? "1 request" : "\(entries.count) requests"
        return count + " · " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + " transferred"
    }
}

/// The network list docked under the page (GUESS — capture PB3-a: placement, height and columns).
@MainActor
public final class NetworkListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    public static let height: CGFloat = 220
    public var log: NetworkLog? { didSet { oldValue?.onChange = nil; log?.onChange = { [weak self] in self?.reload() }; reload() } }
    public var onClose: (() -> Void)?
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let title = NSTextField(labelWithString: "Network")
    private let summary = NSTextField(labelWithString: "")
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Network Panel") ?? NSImage(), target: nil, action: nil)
    private let divider = NSBox()
    static let columns: [(String, String, CGFloat)] = [("name", "Name", 260), ("status", "Status", 60), ("method", "Method", 60),
                                                       ("type", "Type", 90), ("size", "Size", 80), ("time", "Time", 70)]

    public override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        divider.boxType = .separator; addSubview(divider)
        title.font = .systemFont(ofSize: 12, weight: .semibold); addSubview(title)
        summary.font = .systemFont(ofSize: 11); summary.textColor = .secondaryLabelColor; addSubview(summary)
        clearButton.bezelStyle = .accessoryBarAction; clearButton.controlSize = .small; clearButton.target = self; clearButton.action = #selector(clearList)
        clearButton.identifier = .init("developer-network-clear"); addSubview(clearButton)
        closeButton.isBordered = false; closeButton.target = self; closeButton.action = #selector(close)
        closeButton.identifier = .init("developer-network-close"); addSubview(closeButton)
        for (id, name, width) in Self.columns {
            let column = NSTableColumn(identifier: .init(id)); column.title = name; column.width = width; column.minWidth = 40
            table.addTableColumn(column)
        }
        table.style = .plain; table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 20
        table.dataSource = self; table.delegate = self; table.allowsColumnReordering = false
        table.setAccessibilityLabel("Network requests")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .noBorder
        addSubview(scroll)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Network Panel")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func clearList() { log?.clear() }
    @objc private func close() { onClose?() }
    private func reload() {
        summary.stringValue = log?.summary ?? ""
        table.reloadData()
        if let count = log?.entries.count, count > 0 { table.scrollRowToVisible(count - 1) }
    }
    public var rowCount: Int { log?.entries.count ?? 0 }

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        divider.frame = CGRect(x: 0, y: h - 1, width: w, height: 1)
        title.frame = CGRect(x: 12, y: h - 26, width: 70, height: 16)
        summary.frame = CGRect(x: 84, y: h - 26, width: max(0, w - 84 - 110), height: 16)
        clearButton.frame = CGRect(x: w - 96, y: h - 28, width: 56, height: 20)
        closeButton.frame = CGRect(x: w - 32, y: h - 28, width: 20, height: 20)
        scroll.frame = CGRect(x: 0, y: 0, width: w, height: max(0, h - 34))
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { log?.entries.count ?? 0 }
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let entry = log?.entries[safe: row], let id = tableColumn?.identifier.rawValue else { return nil }
        let cell = (tableView.makeView(withIdentifier: .init("cell-" + id), owner: nil) as? NSTextField) ?? {
            let field = NSTextField(labelWithString: ""); field.identifier = .init("cell-" + id)
            field.font = id == "name" ? .systemFont(ofSize: 11) : .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.lineBreakMode = .byTruncatingTail; return field
        }()
        let failed = entry.failed != nil || (entry.status ?? 0) >= 400
        cell.textColor = failed ? .systemRed : .labelColor
        switch id {
        case "name": cell.stringValue = entry.name; cell.toolTip = entry.url
        case "status": cell.stringValue = entry.failed ?? entry.status.map(String.init) ?? "Pending"
        case "method": cell.stringValue = entry.method
        case "type": cell.stringValue = entry.type
        case "size": cell.stringValue = entry.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—"
        default: cell.stringValue = entry.durationMS.map { String(format: "%.0f ms", $0) } ?? "—"
        }
        return cell
    }
}

private extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
