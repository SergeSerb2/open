import AppKit
import Foundation

/// The app implements this once. Menu items and the router call it.
/// Validation reads the command's enabled-state key, never the title.
@MainActor
public protocol CommandDispatcher: AnyObject {
    /// Runs one command by stable id. Dynamic ids use `go-to-space:<id>` form:
    /// the builder emits item ids such as `dynamic-space` with a payload.
    func performCommand(_ id: String)
    /// Dynamic form: `performCommand(_:payload:)` receives the Space or tab id.
    /// Default implementation forwards to `performCommand`.
    func performCommand(_ id: String, payload: String?)
    /// Answers one enabled-state key for one command. Return true to enable.
    func isCommandEnabled(_ id: String, enabledKey: String) -> Bool
}

public extension CommandDispatcher {
    func performCommand(_ id: String, payload: String?) { performCommand(id) }
    func isCommandEnabled(_ id: String, enabledKey: String) -> Bool { true }
}

/// Dispatcher that enables everything and does nothing. For dump and previews.
@MainActor
public final class NullDispatcher: CommandDispatcher {
    public private(set) var performed: [String] = []
    public init() {}
    public func performCommand(_ id: String) { performed.append(id) }
    public func performCommand(_ id: String, payload: String?) { performed.append(payload.map { "\(id):\($0)" } ?? id) }
    public func isCommandEnabled(_ id: String, enabledKey: String) -> Bool { true }
}

/// One Space row for the dynamic Spaces section.
public struct SpaceMenuEntry: Sendable, Hashable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

/// One tab row for the dynamic numbered section.
public struct TabMenuEntry: Sendable, Hashable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

/// Click target shared by every built item. One instance per menu build;
/// the menu retains it through each item's `target`.
@MainActor
final class MenuCommandTarget: NSObject, NSMenuItemValidation {
    weak var dispatcher: (any CommandDispatcher)?
    var enabledKeys: [String: String] = [:] // item identifier string -> enabled key

    @objc func openCommandAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let id = info["command"] else { return }
        dispatcher?.performCommand(id, payload: info["payload"])
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let info = menuItem.representedObject as? [String: String],
              let id = info["command"] else { return true }
        let key = enabledKeys[ObjectIdentifier(menuItem).debugDescription] ?? CommandRegistry.byID[id]?.enabledKey ?? EnabledKey.always
        return dispatcher?.isCommandEnabled(id, enabledKey: key) ?? true
    }
}

/// Builds the full Arc-order menu bar: Open, File, Edit, View, Spaces, Tabs,
/// Archive, Extensions, Window, Help. Order follows `docs/re/menus-and-hotkeys.md`.
/// The builder is the only place that turns registry entries into `NSMenuItem`s,
/// so overrides restyle every item from one path.
@MainActor
public enum MenuBuilder {
    public static func buildMainMenu(
        dispatcher: any CommandDispatcher,
        spaces: [SpaceMenuEntry] = [],
        tabs: [TabMenuEntry] = [],
        overrides: KeyBindingStore = .empty,
        switchToNinth: Bool = false
    ) -> NSMenu {
        let target = MenuCommandTarget()
        target.dispatcher = dispatcher
        let main = NSMenu()
        main.autoenablesItems = true
        for menu in [
            buildOpenMenu(target: target, overrides: overrides),
            buildFileMenu(target: target, overrides: overrides),
            buildEditMenu(target: target, overrides: overrides),
            buildViewMenu(target: target, overrides: overrides),
            buildSpacesMenu(target: target, spaces: spaces, overrides: overrides),
            buildTabsMenu(target: target, tabs: tabs, overrides: overrides, switchToNinth: switchToNinth),
            buildArchiveMenu(target: target, overrides: overrides),
            buildExtensionsMenu(target: target, overrides: overrides),
            buildWindowMenu(target: target, overrides: overrides),
            buildHelpMenu(target: target, overrides: overrides),
        ] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        // Keep the target alive with the menu.
        objc_setAssociatedObject(main, &targetKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return main
    }

    private static var targetKey: UInt8 = 0

    // MARK: - Item helpers

    private static func item(
        _ commandID: String,
        target: MenuCommandTarget,
        overrides: KeyBindingStore,
        title overrideTitle: String? = nil,
        payload: String? = nil
    ) -> NSMenuItem {
        guard let command = CommandRegistry.byID[commandID] else {
            return NSMenuItem(title: overrideTitle ?? commandID, action: nil, keyEquivalent: "")
        }
        let shortcuts = overrides.effectiveShortcuts(for: command)
        let item = NSMenuItem(
            title: overrideTitle ?? command.title,
            action: #selector(MenuCommandTarget.openCommandAction(_:)),
            keyEquivalent: shortcuts.first?.keyEquivalent ?? ""
        )
        if let native = SystemCommandActions.selectors[commandID] {
            item.action = NSSelectorFromString(native); item.target = nil
            item.tag = SystemCommandActions.tags[commandID] ?? 0
        } else { item.target = target }
        item.keyEquivalentModifierMask = shortcuts.first?.keyEquivalentModifierMask ?? []
        var info: [String: String] = ["command": commandID]
        if let payload { info["payload"] = payload }
        item.representedObject = info
        item.identifier = NSUserInterfaceItemIdentifier(commandID)
        return item
    }

    /// Alternate key carriers for a command: hidden items that hold the extra
    /// key equivalents (arc stores them as duplicate menu items). The router
    /// also matches them, so they fire even while hidden.
    private static func carriers(
        _ commandID: String,
        target: MenuCommandTarget,
        overrides: KeyBindingStore,
        into menu: NSMenu
    ) {
        guard let command = CommandRegistry.byID[commandID] else { return }
        let shortcuts = overrides.effectiveShortcuts(for: command)
        for shortcut in shortcuts.dropFirst() {
            let carrier = item(commandID, target: target, overrides: overrides)
            carrier.keyEquivalent = shortcut.keyEquivalent
            carrier.keyEquivalentModifierMask = shortcut.keyEquivalentModifierMask
            carrier.isHidden = true
            menu.addItem(carrier)
        }
    }

    private static func add(_ menu: NSMenu, _ ids: [String], target: MenuCommandTarget, overrides: KeyBindingStore) {
        for id in ids {
            menu.addItem(item(id, target: target, overrides: overrides))
            carriers(id, target: target, overrides: overrides, into: menu)
        }
    }

    private static func submenuItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    // MARK: - Menus

    private static func buildOpenMenu(target: MenuCommandTarget, overrides: KeyBindingStore) -> NSMenu {
        let menu = NSMenu(title: "Open")
        add(menu, ["about-open", "set-default-browser"], target: target, overrides: overrides)
        menu.addItem(.separator())
        add(menu, ["settings", "check-for-updates", "import-from-browser"], target: target, overrides: overrides)
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        menu.addItem(submenuItem("Services", services))
        NSApp?.servicesMenu = services
        menu.addItem(.separator())
        add(menu, ["hide-open", "hide-others", "show-all"], target: target, overrides: overrides)
        menu.addItem(.separator())
        add(menu, ["quit-open"], target: target, overrides: overrides)
        return menu
    }

    private static func buildFileMenu(target: MenuCommandTarget, overrides: KeyBindingStore) -> NSMenu {
        let menu = NSMenu(title: "File")
        add(menu, ["new-tab", "open-command-bar", "new-window", "new-incognito-window", "new-little-open-window", "blank-window"], target: target, overrides: overrides)
        menu.addItem(.separator())
        add(menu, ["archive-tab", "close-window", "restore-last-closed-tab"], target: target, overrides: overrides)
        menu.addItem(.separator())
        add(menu, ["print", "save-page-as", "share-page", "capture-page", "capture-full-page", "capture-portrait"], target: target, overrides: overrides)
        menu.addItem(.separator())
        add(menu, ["new-profile", "new-boost", "edit-boost", "new-legacy-boost", "boost-gallery"], target: target, overrides: overrides)
        return menu
    }

    private static func buildEditMenu(target: MenuCommandTarget, overrides: KeyBindingStore) -> NSMenu {
        let menu = NSMenu(title: "Edit")
        add(menu, ["undo", "redo"], target: target, overrides: overrides)
        menu.addItem(.separator())
        add(menu, ["cut", "copy", "paste", "paste-and-match-style", "delete", "select-all"], target: target, overrides: overrides)
        menu.addItem(.separator())
        add(menu, ["copy-url", "copy-url-markdown", "copy-url-quote"], target: target, overrides: overrides)
        menu.addItem(.separator())

        let find = NSMenu(title: "Find")
        add(find, ["find", "find-next", "find-previous", "find-and-replace", "use-selection-to-find", "jump-to-selection"], target: target, overrides: overrides)
        menu.addItem(submenuItem("Find", find))

        let spelling = NSMenu(title: "Spelling and Grammar")
        add(spelling, ["show-spelling", "check-spelling", "check-spelling-while-typing", "check-grammar", "correct-spelling-automatically"], target: target, overrides: overrides)
        menu.addItem(submenuItem("Spelling and Grammar", spelling))

        let substitutions = NSMenu(title: "Substitutions")
        add(substitutions, ["show-substitutions", "smart-copy-paste", "smart-quotes", "smart-dashes", "smart-links", "text-replacement", "data-detectors"], target: target, overrides: overrides)
        menu.addItem(submenuItem("Substitutions", substitutions))

        let transformations = NSMenu(title: "Transformations")
        add(transformations, ["make-upper-case", "make-lower-case", "capitalize"], target: target, overrides: overrides)
        menu.addItem(submenuItem("Transformations", transformations))

        let speech = NSMenu(title: "Speech")
        add(speech, ["start-speaking", "stop-speaking"], target: target, overrides: overrides)
        menu.addItem(submenuItem("Speech", speech))

        let font = NSMenu(title: "Font")
        add(font, ["show-fonts", "font-bold", "font-italic", "font-underline"], target: target, overrides: overrides)
        NSFontManager.shared.setFontMenu(font)
        let format = NSMenu(title: "Format")
        format.addItem(submenuItem("Font", font))
        menu.addItem(submenuItem("Format", format))
        menu.addItem(.separator())
        add(menu, ["emoji-and-symbols"], target: target, overrides: overrides)
        return menu
    }

    private static func buildViewMenu(target: MenuCommandTarget, overrides: KeyBindingStore) -> NSMenu {
        let menu = NSMenu(title: "View")
        add(menu, ["toggle-sidebar", "toggle-toolbar", "toggle-full-screen"], target: target, overrides: overrides)
        menu.addItem(.separator())
        add(menu, ["reload", "force-reload", "stop-loading", "clear-cache-and-refresh", "clear-cookies-and-refresh"], target: target, overrides: overrides)
        menu.addItem(.separator())
        add(menu, ["zoom-in", "zoom-out", "zoom-actual-size"], target: target, overrides: overrides)
        menu.addItem(.separator())
        add(menu, ["add-split-view", "close-split-pane", "expand-current-split", "separate-from-split-view"], target: target, overrides: overrides)
        menu.addItem(.separator())
        add(menu, ["reveal-current-tab", "expand-pinned-section", "collapse-pinned-section", "cast", "exit-modal"], target: target, overrides: overrides)
        menu.addItem(.separator())

        let appearance = NSMenu(title: "Appearance")
        let header = NSMenuItem(title: "Websites will use:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        appearance.addItem(header)
        add(appearance, ["appearance-automatic", "appearance-light", "appearance-dark"], target: target, overrides: overrides)
        menu.addItem(submenuItem("Appearance", appearance))

        let developer = NSMenu(title: "Developer")
        add(developer, ["developer-tools", "javascript-console", "view-source", "inspect-elements", "network-inspector", "toggle-developer-mode", "allow-js-apple-events"], target: target, overrides: overrides)
        menu.addItem(submenuItem("Developer", developer))
        return menu
    }

    private static func buildSpacesMenu(target: MenuCommandTarget, spaces: [SpaceMenuEntry], overrides: KeyBindingStore) -> NSMenu {
        let menu = NSMenu(title: "Spaces")
        add(menu, ["next-space", "previous-space"], target: target, overrides: overrides)
        menu.addItem(.separator())
        add(menu, ["new-space", "manage-spaces", "rename-space", "edit-theme", "change-profile"], target: target, overrides: overrides)
        if !spaces.isEmpty {
            menu.addItem(.separator())
            for (index, space) in spaces.enumerated() {
                let number = index + 1
                let dynamic = NSMenuItem(
                    title: space.title,
                    action: #selector(MenuCommandTarget.openCommandAction(_:)),
                    keyEquivalent: number <= 9 ? String(number) : ""
                )
                dynamic.target = target
                dynamic.keyEquivalentModifierMask = [.control]
                dynamic.representedObject = ["command": "go-to-space-\(min(number, 9))", "payload": space.id]
                dynamic.identifier = NSUserInterfaceItemIdentifier("dynamic-space-\(space.id)")
                menu.addItem(dynamic)
            }
        }
        return menu
    }

    private static func buildTabsMenu(target: MenuCommandTarget, tabs: [TabMenuEntry], overrides: KeyBindingStore, switchToNinth: Bool) -> NSMenu {
        let menu = NSMenu(title: "Tabs")
        // new-tab lives in File; Tabs shows the same command (Arc lists it in both).
        menu.addItem(item("new-tab", target: target, overrides: overrides))
        carriers("new-tab", target: target, overrides: overrides, into: menu)
        menu.addItem(.separator())
        add(menu, ["pin-unpin-tab", "duplicate-tab", "rename-tab", "reveal-tab-in-sidebar", "reset-tab", "reset-all-tabs-in-space"], target: target, overrides: overrides)
        menu.addItem(.separator())
        add(menu, ["next-tab", "previous-tab", "cycle-tab-forward", "cycle-tab-backward", "tab-switcher-forward", "tab-switcher-backward"], target: target, overrides: overrides)
        add(menu, ["go-to-last-tab"], target: target, overrides: overrides)
        menu.addItem(.separator())
        add(menu, ["new-folder", "expand-all-folders", "collapse-all-folders", "clear-unpinned-tabs"], target: target, overrides: overrides)
        menu.addItem(.separator())
        add(menu, ["peek-email", "join-meeting", "open-in-current-space"], target: target, overrides: overrides)
        if !tabs.isEmpty {
            menu.addItem(.separator())
            for (index, tab) in tabs.enumerated() {
                let number = index + 1
                let dynamic = NSMenuItem(
                    title: tab.title,
                    action: #selector(MenuCommandTarget.openCommandAction(_:)),
                    keyEquivalent: number <= 8 ? String(number) : ""
                )
                if switchToNinth ? number == 9 : index == tabs.count - 1 { dynamic.keyEquivalent = "9" }
                dynamic.target = target
                dynamic.keyEquivalentModifierMask = [.command]
                dynamic.representedObject = ["command": "go-to-tab-\(min(number, 9))", "payload": tab.id]
                dynamic.identifier = NSUserInterfaceItemIdentifier("dynamic-tab-\(tab.id)")
                menu.addItem(dynamic)
            }
        }
        return menu
    }

    private static func buildArchiveMenu(target: MenuCommandTarget, overrides: KeyBindingStore) -> NSMenu {
        let menu = NSMenu(title: "Archive")
        add(menu, ["go-back", "go-forward"], target: target, overrides: overrides)
        menu.addItem(.separator())
        add(menu, ["view-history", "view-archive", "clear-archive"], target: target, overrides: overrides)
        return menu
    }

    private static func buildExtensionsMenu(target: MenuCommandTarget, overrides: KeyBindingStore) -> NSMenu {
        let menu = NSMenu(title: "Extensions")
        add(menu, ["manage-extensions", "add-extension"], target: target, overrides: overrides)
        return menu
    }

    private static func buildWindowMenu(target: MenuCommandTarget, overrides: KeyBindingStore) -> NSMenu {
        let menu = NSMenu(title: "Window")
        add(menu, ["minimize-window", "zoom-window"], target: target, overrides: overrides)
        menu.addItem(.separator())
        add(menu, ["view-downloads", "view-library", "view-media", "view-boosts"], target: target, overrides: overrides)
        menu.addItem(.separator())
        add(menu, ["bring-all-to-front"], target: target, overrides: overrides)
        NSApp?.windowsMenu = menu
        return menu
    }

    private static func buildHelpMenu(target: MenuCommandTarget, overrides: KeyBindingStore) -> NSMenu {
        let menu = NSMenu(title: "Help")
        add(menu, ["help-center", "getting-started", "keyboard-shortcuts-edu", "release-notes", "contact-team"], target: target, overrides: overrides)
        menu.addItem(.separator())
        let troubleshooting = NSMenu(title: "Troubleshooting")
        add(troubleshooting, ["task-manager", "record-trace", "cancel-trace", "copy-open-info", "reveal-open-data"], target: target, overrides: overrides)
        menu.addItem(submenuItem("Troubleshooting", troubleshooting))
        NSApp?.helpMenu = menu
        return menu
    }

    // MARK: - Dump support

    /// Every visible and hidden item as (path, title, shortcut display), in menu order.
    /// `path` joins menu titles with " > ". Hidden alternate carriers carry "(hidden)".
    public static func flatten(_ menu: NSMenu) -> [(path: String, title: String, shortcut: String, commandID: String?, hidden: Bool)] {
        var rows: [(path: String, title: String, shortcut: String, commandID: String?, hidden: Bool)] = []
        func walk(_ current: NSMenu, _ prefix: String) {
            for entry in current.items {
                if entry.isSeparatorItem { continue }
                let path = prefix.isEmpty ? entry.title : "\(prefix) > \(entry.title)"
                if let submenu = entry.submenu {
                    walk(submenu, path)
                } else {
                    let info = entry.representedObject as? [String: String]
                    let shortcut: String
                    if entry.keyEquivalent.isEmpty {
                        shortcut = ""
                    } else {
                        let mods = ShortcutModifiers.from(eventFlags: entry.keyEquivalentModifierMask)
                        shortcut = KeyboardShortcut(key: shortcutKeyName(entry.keyEquivalent), modifiers: mods).display
                    }
                    rows.append((path: prefix, title: entry.title, shortcut: shortcut, commandID: info?["command"], hidden: entry.isHidden))
                }
            }
        }
        walk(menu, "")
        return rows
    }

    private static func shortcutKeyName(_ equivalent: String) -> String {
        switch equivalent {
        case " ": return "space"
        case "\t": return "tab"
        case "\r": return "return"
        case "\u{1B}": return "escape"
        case "\u{F702}": return "left"
        case "\u{F703}": return "right"
        case "\u{F700}": return "up"
        case "\u{F701}": return "down"
        default: return equivalent
        }
    }
}

/// Native actions are registry metadata. They retain AppKit's nil-target
/// validation and responder search, including Chromium's text responder.
@MainActor
public enum SystemCommandActions {
    public static let selectors: [String: String] = [
        "about-open": "orderFrontStandardAboutPanel:",
        "quit-open": "terminate:", "hide-open": "hide:",
        "hide-others": "hideOtherApplications:", "show-all": "unhideAllApplications:",
        "close-window": "performClose:", "minimize-window": "performMiniaturize:",
        "zoom-window": "performZoom:", "bring-all-to-front": "arrangeInFront:",
        "toggle-full-screen": "toggleFullScreen:",
        "cut": "cut:", "copy": "copy:", "paste": "paste:",
        "paste-and-match-style": "pasteAsPlainText:", "delete": "delete:",
        "select-all": "selectAll:", "undo": "undo:", "redo": "redo:",
        "find": "performFindPanelAction:", "find-next": "performFindPanelAction:",
        "find-previous": "performFindPanelAction:", "use-selection-to-find": "performFindPanelAction:",
        "find-and-replace": "performTextFinderAction:", "jump-to-selection": "centerSelectionInVisibleArea:",
        "show-spelling": "showGuessPanel:", "check-spelling": "checkSpelling:",
        "check-spelling-while-typing": "toggleContinuousSpellChecking:",
        "check-grammar": "toggleGrammarChecking:",
        "correct-spelling-automatically": "toggleAutomaticSpellingCorrection:",
        "show-substitutions": "orderFrontSubstitutionsPanel:",
        "smart-copy-paste": "toggleSmartInsertDelete:", "smart-quotes": "toggleAutomaticQuoteSubstitution:",
        "smart-dashes": "toggleAutomaticDashSubstitution:", "smart-links": "toggleAutomaticLinkDetection:",
        "text-replacement": "toggleAutomaticTextReplacement:", "data-detectors": "toggleAutomaticDataDetection:",
        "make-upper-case": "uppercaseWord:", "make-lower-case": "lowercaseWord:", "capitalize": "capitalizeWord:",
        "start-speaking": "startSpeaking:", "stop-speaking": "stopSpeaking:",
        "show-fonts": "orderFrontFontPanel:", "font-bold": "addFontTrait:",
        "font-italic": "addFontTrait:", "font-underline": "underline:",
        "emoji-and-symbols": "orderFrontCharacterPalette:"
    ]
    public static let tags = ["find": 1, "find-next": 2, "find-previous": 3,
                              "use-selection-to-find": 7, "find-and-replace": 12, "font-bold": 2, "font-italic": 1]
    public static func command(for shortcut: KeyboardShortcut, overrides: KeyBindingStore) -> String? {
        CommandRegistry.active.first { selectors[$0.id] != nil && overrides.effectiveShortcuts(for: $0).contains(shortcut) }?.id
    }
    public static func sender(for id: String) -> NSMenuItem? {
        guard let selector = selectors[id] else { return nil }
        let item = NSMenuItem(title: CommandRegistry.byID[id]?.title ?? id,
                              action: NSSelectorFromString(selector), keyEquivalent: "")
        item.target = nil; item.tag = tags[id] ?? 0; item.identifier = .init(id)
        return item
    }
    public static func isEnabled(_ id: String) -> Bool {
        guard let item = sender(for: id), let action = item.action,
              let target = NSApp?.target(forAction: action, to: nil, from: item) else { return false }
        if let target = target as? NSMenuItemValidation { return target.validateMenuItem(item) }
        if let target = target as? NSUserInterfaceValidations { return target.validateUserInterfaceItem(item) }
        return true
    }
    @discardableResult public static func perform(_ id: String) -> Bool {
        guard let item = sender(for: id), let action = item.action else { return false }
        return NSApp?.sendAction(action, to: nil, from: item) == true
    }
}
