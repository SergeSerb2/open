import AppKit
import Foundation
import OpenCommands
import OpenSuggest

// commands-dump: end-to-end check for OpenCommands.
// Builds the real NSMenu tree in a headless NSApplication, prints it,
// runs the conflict checker, applies sample overrides, and compares the
// menu with the table extracted from docs/re/menus-and-hotkeys.md.
// Exit code is non-zero when the checker or the comparison finds an
// unexpected problem.

nonisolated(unsafe) var failures = 0
func fail(_ message: String) {
    print("FAIL: \(message)")
    failures += 1
}

if CommandLine.arguments.contains("--markdown") {
    print("| id | Title | Shortcut | Scope | Menu path |")
    print("|---|---|---|---|---|")
    for command in CommandRegistry.all where !command.isReserved {
        let shortcut = command.shortcutDisplay.isEmpty ? "—" : command.shortcutDisplay
        print("| `\(command.id)` | \(command.title) | \(shortcut) | \(command.scope.rawValue) | \(command.menuPathDisplay) |")
    }
    print("")
    print("Reserved (out-of-scope keys):")
    for command in CommandRegistry.all where command.isReserved {
        print("- `\(command.id)` \(command.title): \(command.shortcutDisplay.isEmpty ? "—" : command.shortcutDisplay)")
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    let dispatcher = NullDispatcher()
    let spaces = [SpaceMenuEntry(id: "space-work", title: "Work"), SpaceMenuEntry(id: "space-personal", title: "Personal")]
    let tabs = [TabMenuEntry(id: "tab-1", title: "Example"), TabMenuEntry(id: "tab-2", title: "Docs")]

    // 1. Build and print the real menu tree.
    let menu = MenuBuilder.buildMainMenu(dispatcher: dispatcher, spaces: spaces, tabs: tabs)
    app.mainMenu = menu
    print("== Menu tree ==")
    func printMenu(_ current: NSMenu, _ depth: Int) {
        for entry in current.items {
            let indent = String(repeating: "  ", count: depth)
            if entry.isSeparatorItem {
                print("\(indent)---")
            } else if let submenu = entry.submenu {
                print("\(indent)\(entry.title) >")
                printMenu(submenu, depth + 1)
            } else {
                let shortcut = entry.keyEquivalent.isEmpty ? "" :
                    "  [\(KeyboardShortcut(key: MenuBuilderKeyName(entry.keyEquivalent), modifiers: ShortcutModifiers.from(eventFlags: entry.keyEquivalentModifierMask)).display)]"
                let hidden = entry.isHidden ? " (hidden carrier)" : ""
                print("\(indent)\(entry.title)\(shortcut)\(hidden)")
            }
        }
    }
    printMenu(menu, 0)

    let rows = MenuBuilder.flatten(menu)
    let visible = rows.filter { !$0.hidden }
    print("counts: commands=\(CommandRegistry.all.count) active=\(CommandRegistry.active.count) reserved=\(CommandRegistry.all.count - CommandRegistry.active.count) menuItems=\(rows.count) visible=\(visible.count) shortcuts=\(CommandRegistry.active.reduce(0) { $0 + $1.defaultShortcuts.count })")

    // The picker is a hidden key carrier; it has no visible row in expected-menu.json.
    // The expectation table removes Cmd+E from Use Selection to Find; allowed-missing stays 11.
    if let picker = menu.items.first(where: { $0.title == "Extensions" })?.submenu?.items.first(where: { $0.identifier?.rawValue == "open-extensions-picker" }) {
        if !picker.isHidden || !picker.allowsKeyEquivalentWhenHidden || picker.keyEquivalent != "e" || picker.keyEquivalentModifierMask != .command { fail("extension picker hidden shortcut carrier") }
        picker.menu?.update(); menu.update()
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "e", charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14),
           picker.menu?.performKeyEquivalent(with: event) != true || dispatcher.performed.last != "open-extensions-picker" { fail("Cmd+E did not dispatch the hidden picker; enabled=\(picker.isEnabled), received=\(dispatcher.performed)") }
    } else { fail("missing hidden extensions picker") }
    if KeyboardRouter().route(shortcut: .cmd("e"), context: RoutingContext()) != .browserCommand("open-extensions-picker") { fail("Cmd+E router owner") }
    if CommandRegistry.byID["use-selection-to-find"]?.defaultShortcuts.isEmpty != true || CommandRegistry.byID["extension-shortcuts"]?.menuPath != nil { fail("extension command registry defaults") }

    if !Set(CommandRegistry.makeSuggestActions().map(\.id)).isSuperset(of: ["open-extensions-picker", "extension-shortcuts"]) { fail("extension commands missing from command-bar adapter") }

    // 2. Conflict checker on default bindings.
    print("== Conflicts (defaults) ==")
    let conflicts = ConflictChecker.check()
    for conflict in conflicts {
        print("  \(conflict)\(conflict.isKnownArcDuplicate ? " (known default duplicate, resolved by focus)" : "")")
    }
    let unexpected = ConflictChecker.unexpected(conflicts)
    if unexpected.isEmpty {
        print("  no unexpected conflicts")
    } else {
        for conflict in unexpected { fail("unexpected conflict: \(conflict)") }
    }

    // 3. Sample overrides: move New Tab to Ctrl+T and clear Zoom In keys.
    print("== Overrides ==")
    let sampleJSON = """
    { "version": 1,
      "bindings": {
        "new-tab": { "shortcuts": [{ "key": "t", "modifiers": ["control"] }], "priority": "browser" },
        "zoom-in": { "shortcuts": [] }
      } }
    """
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("commands-dump-overrides.json")
    try! sampleJSON.write(to: tempURL, atomically: true, encoding: .utf8)
    let overrides = try! KeyBindingStore.load(from: tempURL)
    print("  loaded overrides for: \(overrides.bindings.keys.sorted().joined(separator: ", "))")
    if !overrides.unknownCommandIDs.isEmpty { fail("unknown override ids: \(overrides.unknownCommandIDs)") }
    let rebuilt = MenuBuilder.buildMainMenu(dispatcher: dispatcher, spaces: spaces, tabs: tabs, overrides: overrides)
    let before = Dictionary(uniqueKeysWithValues: MenuBuilder.flatten(menu).filter { !$0.hidden }.map { ("\($0.path)|\($0.title)", $0.shortcut) })
    let after = Dictionary(uniqueKeysWithValues: MenuBuilder.flatten(rebuilt).filter { !$0.hidden }.map { ("\($0.path)|\($0.title)", $0.shortcut) })
    var changed = 0
    for key in Set(before.keys).union(after.keys).sorted() where before[key] != after[key] {
        print("  changed \(key): \(before[key] ?? "-") -> \(after[key] ?? "-")")
        changed += 1
    }
    if changed == 0 { fail("overrides changed no menu item") }
    let overrideConflicts = ConflictChecker.unexpected(ConflictChecker.check(overrides: overrides))
    for conflict in overrideConflicts { fail("override conflict: \(conflict)") }
    if overrideConflicts.isEmpty { print("  no unexpected conflicts after overrides") }

    // Routing smoke check through the real helper (no window shown).
    let router = KeyboardRouter()
    let route1 = router.route(shortcut: .cmd("t"), context: RoutingContext())
    print("  route Cmd+T window -> \(route1)")
    if route1 != .browserCommand("new-tab") { fail("router Cmd+T gave \(route1)") }
    let route2 = router.route(shortcut: .cmd("t"), context: RoutingContext(isAppActive: false))
    print("  route Cmd+T inactive -> \(route2)")

    // Suggest adapter: the command bar registry comes from this registry.
    print("== Suggest adapter ==")
    let suggestActions = CommandRegistry.makeSuggestActions()
    print("  suggest actions=\(suggestActions.count) (OpenSuggest seed=\(ActionRegistry.arcDefaults.actions.count))")
    let suggestIDs = Set(suggestActions.map(\.id))
    if suggestIDs.count != suggestActions.count { fail("duplicate suggest action ids") }
    let adapterRegistry = CommandRegistry.makeSuggestRegistry()
    print("  adapter registry actions=\(adapterRegistry.actions.count)")
    let adapterIDs = Set(adapterRegistry.actions.map(\.id))
    let seedIDs = Set(ActionRegistry.arcDefaults.actions.map(\.id))
    let missingSeedIDs = seedIDs.subtracting(adapterIDs).sorted()
    print("  seed coverage=\(seedIDs.intersection(adapterIDs).count)/\(seedIDs.count)")
    for id in missingSeedIDs { fail("seed action not in adapter: \(id)") }

    // Global hotkey smoke: register, read back, unregister. Print only; a
    // busy system key is an environment fact, not a code failure.
    print("== Global hotkey ==")
    let hotkey = GlobalHotkeyService()
    do {
        try hotkey.register(shortcut: KeyboardShortcut(key: "n", modifiers: [.command, .option])) {}
        print("  registered Cmd+Opt+N: isRegistered=\(hotkey.isRegistered)")
        hotkey.unregister()
        print("  after unregister: isRegistered=\(hotkey.isRegistered)")
        if hotkey.isRegistered { fail("global hotkey still registered after unregister") }
    } catch {
        print("  register failed (environment): \(error)")
    }

    // Router double-press: first press to the page, second quick press to the browser.
    print("== Router priority ==")
    var bindingStore = KeyBindingStore()
    bindingStore.setOverride(KeyBindingOverride(shortcuts: [.cmd("r")], priority: .siteThenBrowserOnDoublePress), for: "reload")
    let webContext = RoutingContext(isWebContentFocused: true)
    let first = router.route(shortcut: .cmd("r"), context: webContext, overrides: bindingStore)
    let second = router.route(shortcut: .cmd("r"), context: webContext, overrides: bindingStore)
    print("  double-press reload: first=\(first) second=\(second)")
    if first != .webContent || second != .browserCommand("reload") { fail("double-press routing gave \(first) then \(second)") }

    // 4. Compare with the extracted menu table.
    print("== Comparison with docs/re/menus-and-hotkeys.md table ==")
    do {
        let expected = try ExpectedMenu.load()
        let comparison = MenuComparator.compare(built: rows, expected: expected)
        print("  renamed (by design): \(comparison.renamed.count)")
        for rename in comparison.renamed {
            print("    \(rename.item.path) > \(rename.item.title) → \(rename.title)")
        }
        for item in comparison.missing { print("  missing: \(item.path) > \(item.title) [\(item.shortcut)]") }
        for row in comparison.extra { print("  extra: \(row.path) > \(row.title) [\(row.shortcut)]") }
        for diff in comparison.different { print("  different: \(diff.item.path) > \(diff.item.title) expected [\(diff.item.shortcut)] built [\(diff.builtShortcut)]") }
        for item in comparison.allowedMissing { print("  allowed-missing (out of scope): \(item.path) > \(item.title)") }
        print("  missing=\(comparison.missing.count) extra=\(comparison.extra.count) different=\(comparison.different.count) allowedMissing=\(comparison.allowedMissing.count)")
        if comparison.unexpectedCount > 0 { fail("menu comparison found \(comparison.unexpectedCount) unexpected differences") }
    } catch {
        fail("expected menu load failed: \(error)")
    }

    // 5. Runtime titles (commandbar-completion §4.6.4, CC-32): the static titles above stay the
    // reference ("Show/Hide Toolbar"); a dispatcher's `menuTitle(for:)` renames the item when the
    // menu validates, and a dispatcher without it keeps the registry title.
    print("== Runtime menu titles ==")
    @MainActor final class TitleDispatcher: CommandDispatcher {
        var toolbar = false, sidebarHidden = false
        func performCommand(_ id: String) {}
        func menuTitle(for id: String) -> String? {
            switch id {
            case "toggle-toolbar": toolbar ? "Hide Toolbar" : "Show Toolbar"
            case "toggle-sidebar": sidebarHidden ? "Show Sidebar" : "Hide Sidebar"
            default: nil
            }
        }
    }
    @MainActor func validatedTitle(_ id: String, in built: NSMenu) -> String? {
        @MainActor func find(_ m: NSMenu) -> NSMenuItem? {
            for i in m.items {
                if (i.representedObject as? [String: String])?["command"] == id { return i }
                if let sub = i.submenu, let hit = find(sub) { return hit }
            }
            return nil
        }
        guard let item = find(built) else { return nil }
        _ = (item.target as? NSMenuItemValidation)?.validateMenuItem(item)
        return item.title
    }
    let titles = TitleDispatcher()
    let titled = MenuBuilder.buildMainMenu(dispatcher: titles, spaces: spaces, tabs: tabs)
    let staticTitle = validatedTitle("toggle-toolbar", in: menu)
    let shown = validatedTitle("toggle-toolbar", in: titled)
    titles.toolbar = true; titles.sidebarHidden = true
    let hidden = validatedTitle("toggle-toolbar", in: titled), sidebar = validatedTitle("toggle-sidebar", in: titled)
    print("  toggle-toolbar: static=\(staticTitle ?? "-") off=\(shown ?? "-") on=\(hidden ?? "-"); toggle-sidebar hidden=\(sidebar ?? "-")")
    if staticTitle != "Show/Hide Toolbar" { fail("a dispatcher without menuTitle changed the static title: \(staticTitle ?? "-")") }
    if shown != "Show Toolbar" || hidden != "Hide Toolbar" || sidebar != "Show Sidebar" { fail("menuTitle hook did not rename the View items") }

    // 6. Runtime menu state (page-platform §7.1): a dispatcher's `menuState(for:)` sets the title,
    // the checkmark, and hidden when the menu validates; a hidden item is also disabled.
    print("== Runtime menu state ==")
    @MainActor final class StateDispatcher: CommandDispatcher {
        var states: [String: CommandMenuState] = [:]
        func performCommand(_ id: String) {}
        func menuState(for id: String) -> CommandMenuState? { states[id] }
    }
    @MainActor func validated(_ id: String, in built: NSMenu) -> (title: String, state: NSControl.StateValue, hidden: Bool, enabled: Bool)? {
        @MainActor func find(_ m: NSMenu) -> NSMenuItem? {
            for i in m.items {
                if (i.representedObject as? [String: String])?["command"] == id { return i }
                if let sub = i.submenu, let hit = find(sub) { return hit }
            }
            return nil
        }
        guard let item = find(built), let target = item.target as? NSMenuItemValidation else { return nil }
        let enabled = target.validateMenuItem(item)
        return (item.title, item.state, item.isHidden, enabled)
    }
    let stateful = StateDispatcher()
    let stateMenu = MenuBuilder.buildMainMenu(dispatcher: stateful, spaces: spaces, tabs: tabs)
    let plain = validated("appearance-dark", in: stateMenu)
    stateful.states = ["appearance-dark": CommandMenuState(isChecked: true), "cast": CommandMenuState(isHidden: true),
                       "toggle-developer-mode": CommandMenuState(title: "Turn on Developer Mode for this site")]
    let checked = validated("appearance-dark", in: stateMenu), cast = validated("cast", in: stateMenu)
    let renamed = validated("toggle-developer-mode", in: stateMenu)
    stateful.states["appearance-dark"] = CommandMenuState(isChecked: false); stateful.states["cast"] = CommandMenuState(isHidden: false)
    let unchecked = validated("appearance-dark", in: stateMenu), shownCast = validated("cast", in: stateMenu)
    print("  appearance-dark: plain=\(plain?.state == .on ? "on" : "off") checked=\(checked?.state == .on ? "on" : "off") unchecked=\(unchecked?.state == .on ? "on" : "off"); cast hidden=\(cast?.hidden == true) enabled=\(cast?.enabled == true) shownAgain=\(shownCast?.hidden == false); developer title=\(renamed?.title ?? "-")")
    if plain?.state != .off || checked?.state != .on || unchecked?.state != .off { fail("menuState checkmark was not applied") }
    if cast?.hidden != true || cast?.enabled != false || shownCast?.hidden != false || shownCast?.enabled != true { fail("menuState hidden was not applied or a hidden item stayed enabled") }
    if renamed?.title != "Turn on Developer Mode for this site" { fail("menuState title was not applied") }

    print(failures == 0 ? "commands-dump OK" : "commands-dump FAILED: \(failures) problem(s)")
}

if failures > 0 { exit(1) }

/// Local copy of the builder key-name map for print output.
func MenuBuilderKeyName(_ equivalent: String) -> String {
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
