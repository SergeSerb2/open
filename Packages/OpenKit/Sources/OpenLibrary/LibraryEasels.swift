import AppKit

/// One Easel in Library › Easels (every Easel document of the data root, also those whose
/// Space or row is gone: docs/re/easels.md "Deleting a Space keeps its Easels").
public struct LibraryEaselItem: Sendable, Equatable {
    public var id: String
    public var title: String
    public var modifiedAt: Date
    public var objectCount: Int
    public init(id: String, title: String, modifiedAt: Date, objectCount: Int) {
        self.id = id; self.title = title; self.modifiedAt = modifiedAt; self.objectCount = objectCount
    }
}

/// The App's Easel side of the Library (EZ). The Library draws; the App reads files, opens,
/// deletes and exports.
@MainActor
public protocol LibraryEaselsProvider: AnyObject {
    /// Reads the Easel list (file work off the main thread).
    func libraryEasels() async -> [LibraryEaselItem]
    /// Opens the Easel in the window (its row, or a new row in the focused Space).
    func openEasel(id: String)
    /// Deletes the Easel permanently (rows without an Archive entry, the folder to the Trash).
    func deleteEasel(id: String)
    /// Export All Easels: a save sheet on `window`, then the archive. `done` runs after.
    func exportAllEasels(from window: NSWindow?, done: @escaping @MainActor (Bool) -> Void)
    /// A small picture of the canvas, at most `pixels` on its long side.
    func easelThumbnail(id: String, pixels: CGFloat, completion: @escaping @MainActor (NSImage?) -> Void)
}

/// "Your Easels are yours to keep" (docs/re/easels.md, Library › Easels). Arc's body line names
/// Arc; Open's keeps the facts without the brand.
@MainActor
final class LibraryEaselsCard: NSView {
    static let titleText = "Your Easels are yours to keep"
    static let bodyText = "Save all your Easels as web pages you can open anywhere, share, or host yourself."
    let title = LibraryField(labelWithString: titleText)
    let body = LibraryField(wrappingLabelWithString: bodyText)
    let button = LibraryControl(title: "Export All Easels →")
    var onExport: (() -> Void)?
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 12; layer?.cornerCurve = .continuous
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        body.font = .systemFont(ofSize: 13); body.maximumNumberOfLines = 4
        button.baseAlpha = 0.09; button.labelSize = 13
        button.onPress = { [weak self] in self?.onExport?() }
        button.identifier = .init("library.easels.exportAll")
        identifier = .init("library.easels.card")
        for view in [title, body, button] { addSubview(view) }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func tint(foreground: NSColor, overlay: NSColor) {
        layer?.backgroundColor = foreground.withAlphaComponent(0.045).cgColor
        title.textColor = foreground; body.textColor = foreground.withAlphaComponent(0.68)
        button.foreground = foreground; button.overlay = overlay
    }
    /// Height for `width` (title, wrapped body, button).
    func height(for width: CGFloat) -> CGFloat {
        let bodyHeight = ceil(body.attributedStringValue.boundingRect(with: CGSize(width: width - 28, height: 200),
                                                                      options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        return 14 + 20 + 4 + max(17, bodyHeight) + 10 + 28 + 14
    }
    override func layout() {
        super.layout()
        let w = bounds.width - 28
        title.frame = CGRect(x: 14, y: 14, width: w, height: 20)
        let bodyHeight = max(17, ceil(body.attributedStringValue.boundingRect(with: CGSize(width: w, height: 200),
                                                                             options: [.usesLineFragmentOrigin, .usesFontLeading]).height))
        body.frame = CGRect(x: 14, y: 38, width: w, height: bodyHeight)
        let bw = (button.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width + 24
        button.frame = CGRect(x: 14, y: 38 + bodyHeight + 10, width: bw, height: 28)
    }
}

@MainActor
extension LibraryPanelView {
    var easelsCardHeight: CGFloat { easelsCard.height(for: 281) }

    /// Easels load through the provider, like the other sections' external state.
    func startEaselsProvider(_ host: LibrarySectionHost) {
        host.providerGeneration += 1
        let generation = host.providerGeneration
        host.provider = Task { @MainActor [weak self, weak host] in
            guard let self, let host else { return }
            defer { if generation == host.providerGeneration { host.provider = nil } }
            let started = ProcessInfo.processInfo.systemUptime
            let items = await self.easelsProvider?.libraryEasels() ?? []
            guard !Task.isCancelled, host.providerGeneration == generation else { return }
            self.easelItems = items
            host.phaseMilliseconds["provider"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            host.loaded = true; host.dirty = true
            if self.section == .easels, self.contentActive {
                self.skeletonTask?.cancel(); self.skeletonTask = nil; self.loadingSkeleton.isHidden = true
                self.renderRows()
            }
        }
    }

    /// Reloads the Easels list (after a delete, an import, or a new Easel).
    public func reloadEasels() {
        guard let host = hosts[.easels] else { return }
        host.provider?.cancel(); host.provider = nil; host.providerGeneration += 1
        host.loaded = false; host.dirty = true
        if section == .easels, contentActive { refreshData() }
    }

    func easelSources() -> [LibraryRowSource] {
        easelItems.map { item in
            let subtitle = "Easel · \(item.objectCount == 1 ? "1 item" : "\(item.objectCount) items") · \(item.modifiedAt.formatted(date: .abbreviated, time: .omitted))"
            return LibraryRowSource(id: item.id, date: item.modifiedAt, text: item.title, prepareText: {
                LibraryRowText(title: item.title, subtitle: subtitle)
            }) { [unowned self] prepared in
                let id = item.id
                let open: () -> Void = { [weak self] in self?.easelsProvider?.openEasel(id: id) }
                // Arc: a Library card's context menu has one item, "Delete" (docs/re/easels.md).
                return LibraryRowItem(id: id, title: item.title, subtitle: prepared?.subtitle ?? subtitle, kind: "easel",
                    image: symbol("scribble.variable"),
                    loadImage: { [weak self] done in self?.easelsProvider?.easelThumbnail(id: id, pixels: 96, completion: done) },
                    activate: open,
                    actions: [.init(title: "Delete", run: { [weak self] in
                        self?.confirm("Are you sure you want to delete this Easel?", message: "Doing so will delete the Easel permanently.") { [weak self] in
                            self?.easelsProvider?.deleteEasel(id: id); self?.reloadEasels()
                        }
                    })])
            }
        }
    }

    func exportAllEasels() {
        guard let provider = easelsProvider else { return }
        easelsCard.button.isEnabled = false
        provider.exportAllEasels(from: window) { [weak self] _ in self?.easelsCard.button.isEnabled = true }
    }

    var easelsState: [String: Any] {
        func rect(_ view: NSView) -> [CGFloat] { let f = convert(view.bounds, from: view); return [f.minX, f.minY, f.width, f.height] }
        return ["cardVisible": !easelsCard.isHidden, "cardFrame": easelsCard.isHidden ? [] : rect(easelsCard),
                "cardTitle": easelsCard.title.stringValue, "cardBody": easelsCard.body.stringValue,
                "exportTitle": easelsCard.button.title, "exportEnabled": easelsCard.button.isEnabled,
                "providerSet": easelsProvider != nil, "items": easelItems.count]
    }
    /// Export All, as the card button's click (automation).
    @discardableResult public func pressExportAllEasels() -> Bool {
        guard !easelsCard.isHidden, easelsCard.button.isEnabled else { return false }
        easelsCard.button.performClick(nil); return true
    }
}
