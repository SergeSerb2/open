import Foundation

/// One row of the menu table extracted from `docs/re/menus-and-hotkeys.md`.
/// `inScope` is false for Arc items Open v1 drops on purpose (Easels, Notes,
/// Arc Max, Send to Dia, account items). Those rows may be missing from the
/// built menu; every other missing, extra, or different row is a failure.
public struct ExpectedMenuItem: Sendable, Codable, Hashable {
    /// Menu path without the item title, joined with " > ". Empty for the Open menu.
    public var path: String
    public var title: String
    /// Shortcut display such as `Cmd+Shift+T`. Empty when the item has no keys.
    public var shortcut: String
    public var inScope: Bool

    public init(path: String, title: String, shortcut: String = "", inScope: Bool = true) {
        self.path = path
        self.title = title
        self.shortcut = shortcut
        self.inScope = inScope
    }
}

/// Loads the machine-readable menu table bundled with OpenCommands.
/// The table is a hand extraction of the Full menu tree in
/// `docs/re/menus-and-hotkeys.md`, with Arc names renamed to Open names
/// (About Arc becomes About Open) and out-of-scope rows flagged. Further
/// product renames are applied only in the comparison, preserving the table.
public enum ExpectedMenu {
    public static func load() throws -> [ExpectedMenuItem] {
        guard let url = Bundle.module.url(forResource: "expected-menu", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([ExpectedMenuItem].self, from: Data(contentsOf: url))
    }

    /// Intentional product names for the remaining in-scope Arc menu titles.
    /// Global and reserved command titles have no built menu row to compare.
    public static let titleRenames: [(id: String, arcTitle: String, openTitle: String)] = [
        ("new-little-open-window", "New Little Arc Window", "New Little Open Window"),
        ("little-open-global", "Show Little Arc (Global)", "Show Little Open (Global)"),
        ("open-in-current-space", "Open Little Arc or Peek in…", "Open Little Open or Peek in…"),
        ("export-notes", "Export Arc Notes", "Export Notes"),
    ]

    /// Extra built titles the comparison allows: system and dynamic rows that
    /// have no fixed row in the nib table.
    public static let allowedExtraTitles: Set<String> = [
        "Services", "Websites, Easels, and Notes will use:",
    ]

    /// The table copies Arc's menu glyphs ("Cmd++", "Cmd+:"); Open names the base key with Shift
    /// ("Cmd+Shift+=", `KeyboardShortcut.normalized`). This maps a table display to Open's form.
    public static func baseKeyDisplay(_ display: String) -> String {
        let key: String, names: [Substring]
        if display.hasSuffix("++") {
            key = "+"; names = display.dropLast(2).split(separator: "+")
        } else {
            let parts = display.split(separator: "+", omittingEmptySubsequences: false)
            guard let last = parts.last, !last.isEmpty else { return display }
            key = String(last); names = parts.dropLast()
        }
        guard let base = KeyboardShortcut.shiftedBaseKeys[key] else { return display }
        var modifiers: ShortcutModifiers = [.shift]
        for name in names {
            switch name {
            case "Cmd": modifiers.insert(.command)
            case "Ctrl": modifiers.insert(.control)
            case "Opt": modifiers.insert(.option)
            case "Shift": break
            default: return display
            }
        }
        return KeyboardShortcut(key: base, modifiers: modifiers).display
    }

    public static func isAllowedExtra(path: String, title: String) -> Bool {
        if allowedExtraTitles.contains(title) { return true }
        if path == "Spaces", title.hasPrefix("") { return false }
        return false
    }
}

/// Result of one menu comparison.
public struct MenuComparison: Sendable {
    public var missing: [ExpectedMenuItem]
    public var extra: [(path: String, title: String, shortcut: String)]
    public var different: [(item: ExpectedMenuItem, builtShortcut: String)]
    public var allowedMissing: [ExpectedMenuItem]
    public var renamed: [(item: ExpectedMenuItem, title: String)]

    public var unexpectedCount: Int { missing.count + extra.count + different.count }
}

public enum MenuComparator {
    /// Compares built rows (from `MenuBuilder.flatten`) with the expected table.
    /// Hidden alternate carriers match the same expected row through their
    /// command's full shortcut list, so they never count as extra.
    public static func compare(
        built: [(path: String, title: String, shortcut: String, commandID: String?, hidden: Bool)],
        expected: [ExpectedMenuItem]
    ) -> MenuComparison {
        var renamed: [(item: ExpectedMenuItem, title: String)] = []
        let expected = expected.map { item in
            guard let rename = ExpectedMenu.titleRenames.first(where: { rename in
                rename.arcTitle == item.title && built.contains(where: {
                    $0.commandID == rename.id && $0.title == rename.openTitle && $0.path == item.path
                })
            }) else { return item }
            let title = rename.openTitle
            renamed.append((item, title))
            var mapped = item
            mapped.title = title
            return mapped
        }

        // Index built visible rows by (path, title). Dynamic rows (payload ids) skip the check.
        // Hidden rows (Arc's hidden key carriers, e.g. Duplicate) satisfy an expected row; only
        // visible rows can be extra.
        var builtByKey: [String: String] = [:]
        var builtRows: [(path: String, title: String, shortcut: String)] = []
        for row in built {
            if let id = row.commandID, id.hasPrefix("go-to-"), row.path == "Spaces" || row.path == "Tabs" {
                // Dynamic Space and tab rows have no fixed expected row.
                if row.commandID != nil, row.title != CommandRegistry.byID[row.commandID ?? ""]?.title {
                    continue
                }
            }
            let key = "\(row.path)\u{1}\(row.title)"
            if builtByKey[key] == nil { builtByKey[key] = row.shortcut }
            if !row.hidden, !builtRows.contains(where: { $0.path == row.path && $0.title == row.title }) {
                builtRows.append((row.path, row.title, row.shortcut))
            }
        }

        var missing: [ExpectedMenuItem] = []
        var allowedMissing: [ExpectedMenuItem] = []
        var different: [(item: ExpectedMenuItem, builtShortcut: String)] = []
        for item in expected {
            let key = "\(item.path)\u{1}\(item.title)"
            guard let builtShortcut = builtByKey[key] else {
                if item.inScope { missing.append(item) } else { allowedMissing.append(item) }
                continue
            }
            let expectedShortcut = ExpectedMenu.baseKeyDisplay(item.shortcut)
            if item.inScope, !item.shortcut.isEmpty, builtShortcut != expectedShortcut {
                // A command with alternates shows its first key; accept any default.
                if let command = CommandRegistry.active.first(where: { $0.title == item.title }),
                   command.defaultShortcuts.map(\.display).contains(expectedShortcut) {
                    continue
                }
                different.append((item, builtShortcut))
            }
        }

        let expectedKeys = Set(expected.map { "\($0.path)\u{1}\($0.title)" })
        let extra = builtRows.filter { row in
            !expectedKeys.contains("\(row.path)\u{1}\(row.title)") && !ExpectedMenu.isAllowedExtra(path: row.path, title: row.title)
        }
        return MenuComparison(missing: missing, extra: extra, different: different, allowedMissing: allowedMissing, renamed: renamed)
    }
}
