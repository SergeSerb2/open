import AppKit
import OpenWeb
import OpenDesign

public struct ExtensionsMenuEntry: Codable, Equatable, Sendable {
    public var title: String
    public var extensionID: String?
    public var command: String?
    public var enabled: Bool
    public var separator: Bool
    public var iconSize: Int?
    public init(title: String = "", extensionID: String? = nil, command: String? = nil, enabled: Bool = true, separator: Bool = false, iconSize: Int? = nil) {
        self.title = title; self.extensionID = extensionID; self.command = command
        self.enabled = enabled; self.separator = separator; self.iconSize = iconSize
    }
}
@MainActor public enum ExtensionsMenuBuilder {
    public enum Kind { case bar, overflow(visiblePinned: Int), littleOpen }
    public static func model(actions: [ExtensionActionInfo], kind: Kind) -> [ExtensionsMenuEntry] {
        guard ExtensionsUIContext.accepts(actions) else { return [] }
        let ordered = ExtensionsUIContext.ordered(actions), pinned = ordered.filter(\.isPinned), rest = ordered.filter { !$0.isPinned }
        func entries(_ list: [ExtensionActionInfo]) -> [ExtensionsMenuEntry] {
            list.map { ExtensionsMenuEntry(title: $0.name, extensionID: $0.id, enabled: $0.isEnabled, iconSize: $0.menuIcon == nil ? nil : 16) }
        }
        var result: [ExtensionsMenuEntry]
        switch kind {
        case .bar: result = entries(ordered)
        case .overflow(let visible):
            result = entries(Array(pinned.dropFirst(max(0, visible))))
            if !result.isEmpty && !rest.isEmpty { result.append(.init(separator: true)) }
            result += entries(rest)
        case .littleOpen:
            result = entries(pinned)
            if !result.isEmpty && !rest.isEmpty { result.append(.init(separator: true)) }
            result += entries(rest)
        }
        if !result.isEmpty { result.append(.init(separator: true)) }
        result += [.init(title: "Manage Extensions…", command: "manage-extensions"), .init(title: "Add Extension…", command: "add-extension")]
        return result
    }
    public static func menu(actions: [ExtensionActionInfo], kind: Kind, run: @escaping (String, ExtensionRunSource) -> Void,
                            command: @escaping (String) -> Void) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        guard ExtensionsUIContext.accepts(actions) else { return menu }
        let lookup = Dictionary(uniqueKeysWithValues: actions.prefix(512).map { ($0.id, $0) })
        for entry in model(actions: actions, kind: kind) {
            if entry.separator { menu.addItem(.separator()); continue }
            let item = ActionMenuItem(title: entry.title) {
                if let id = entry.extensionID { run(id, .menuEntry) }
                else if let id = entry.command { command(id) }
            }
            item.isEnabled = entry.enabled
            if let id = entry.extensionID, let icon = lookup[id]?.menuIcon {
                item.image = NSImage(cgImage: icon.cgImage, size: CGSize(width: 16, height: 16))
            }
            menu.addItem(item)
        }
        return menu
    }
    public static func relabel(_ title: String) -> String {
        // Engine #532 brands this upstream label as Open. Keep the ellipsis:
        // selecting the item still opens our removal confirmation sheet.
        if ["Remove from Chrome", "Remove from Chrome…", "Remove from Chromium", "Remove from Chromium…", "Remove from Open"].contains(title) { return "Remove from Open…" }
        if title == "Pin to Toolbar" || title == "Pin to toolbar" { return "Pin" }
        if title == "Unpin from Toolbar" || title == "Unpin from toolbar" { return "Unpin" }
        // Only Chromium's own labels are rebranded. Every other title can carry an
        // extension's name or its own chrome.contextMenus items ("Chrome Tools"),
        // which must stay exactly as the extension wrote them.
        return title
    }
    /// Bound total decoded nodes, depth and UTF-8 title length before NSMenu allocation.
    public static func accepts(_ items: [ExtensionMenuItem]) -> Bool {
        var count = 0, commands = Set<Int>()
        func valid(_ list: [ExtensionMenuItem], _ depth: Int) -> Bool {
            guard depth <= 16, list.count <= 1024 else { return false }
            for item in list {
                count += 1
                guard count <= 1024, item.title.utf8.count <= 4096 else { return false }
                if !item.isSeparator && item.submenu.isEmpty {
                    guard commands.insert(item.command).inserted else { return false }
                }
                guard item.submenu.isEmpty || valid(item.submenu, depth + 1) else { return false }
            }
            return true
        }
        return valid(items, 0)
    }
    /// The returned menu retains its single-use session through native tracking.
    public static func contextMenu(_ source: any ExtensionMenu) -> NSMenu? {
        let items = source.items
        guard accepts(items) else { source.cancel(); return nil }
        let session = MenuSession(source)
        func build(_ list: [ExtensionMenuItem]) -> SessionMenu {
            let menu = SessionMenu(); menu.session = session; menu.autoenablesItems = false
            for value in list {
                if value.isSeparator { menu.addItem(.separator()); continue }
                let item = ActionMenuItem(title: relabel(value.title)) { session.select(value.command) }
                item.isEnabled = value.isEnabled; item.state = value.isChecked ? .on : .off
                if !value.submenu.isEmpty { item.submenu = build(value.submenu) }
                menu.addItem(item)
            }
            return menu
        }
        let menu = build(items); menu.delegate = session; return menu
    }
}
@MainActor private final class ActionMenuItem: NSMenuItem {
    private let perform: () -> Void
    init(title: String, perform: @escaping () -> Void) {
        self.perform = perform; super.init(title: title, action: #selector(invoke), keyEquivalent: ""); target = self
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }
    @objc private func invoke() { perform() }
}
@MainActor private final class SessionMenu: NSMenu { var session: MenuSession? }
@MainActor private final class MenuSession: NSObject, NSMenuDelegate {
    private let source: any ExtensionMenu
    private var answered = false
    init(_ source: any ExtensionMenu) { self.source = source }
    func select(_ command: Int) {
        guard !answered else { return }; answered = true; source.select(command: command)
    }
    func cancel() { guard !answered else { return }; answered = true; source.cancel() }
    func menuDidClose(_ menu: NSMenu) {
        // AppKit may send menuDidClose before dispatching the chosen item's action.
        DispatchQueue.main.async { [self] in cancel() }
    }
    isolated deinit { if !answered { source.cancel() } }
}
