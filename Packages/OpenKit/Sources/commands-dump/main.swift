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
