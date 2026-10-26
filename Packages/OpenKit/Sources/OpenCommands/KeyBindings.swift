import Foundation

/// One user override for one command. Stored in the key bindings file.
public struct KeyBindingOverride: Sendable, Codable, Hashable {
    /// Replacement shortcuts. An empty list clears the command's keys.
    public var shortcuts: [KeyboardShortcut]
    /// Winner when the keys also belong to a web page. Nil keeps the command default.
    public var priority: ShortcutPriority?

    public init(shortcuts: [KeyboardShortcut], priority: ShortcutPriority? = nil) {
        self.shortcuts = shortcuts
        self.priority = priority
    }
}

/// User key binding overrides. File shape follows Arc `StorableKeyBindings`:
/// command id maps to its shortcut list. Open adds `priority` per binding.
///
/// Example file:
/// ```json
/// { "version": 1,
///   "bindings": { "new-tab": { "shortcuts": [{ "key": "t", "modifiers": ["command"] }],
///                              "priority": "browser" } } }
/// ```
public struct KeyBindingStore: Sendable, Codable, Hashable {
    public var version: Int
    public var bindings: [String: KeyBindingOverride]

    public init(version: Int = 1, bindings: [String: KeyBindingOverride] = [:]) {
        self.version = version
        self.bindings = bindings
    }

    public static let empty = KeyBindingStore()

    /// Effective shortcuts for a command: the override when one exists, else the defaults.
    public func effectiveShortcuts(for command: CommandDefinition) -> [KeyboardShortcut] {
        if let override = bindings[command.id] { return override.shortcuts }
        return command.defaultShortcuts
    }

    /// Effective priority for a command.
    public func effectivePriority(for command: CommandDefinition) -> ShortcutPriority {
        bindings[command.id]?.priority ?? command.priority
    }

    /// Sets or clears one override. A nil value restores the defaults.
    public mutating func setOverride(_ override: KeyBindingOverride?, for commandID: String) {
        if let override { bindings[commandID] = override } else { bindings.removeValue(forKey: commandID) }
    }

    public func load(from url: URL) throws -> KeyBindingStore {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(KeyBindingStore.self, from: data)
    }

    public static func load(from url: URL) throws -> KeyBindingStore {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(KeyBindingStore.self, from: data)
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: [.atomic])
    }

    /// Command IDs in the file that name no known command.
    public var unknownCommandIDs: [String] {
        bindings.keys.filter { CommandRegistry.byID[$0] == nil }.sorted()
    }
}

/// One shortcut conflict found by `ConflictChecker`.
public struct ShortcutConflict: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        /// Two active commands share a key in overlapping scopes.
        case duplicate
        /// An active command takes a key that a reserved command owns.
        case reservedKeyReuse = "reserved-key-reuse"
    }

    public var shortcut: KeyboardShortcut
    public var commandIDs: [String]
    public var kind: Kind

    public var description: String {
        "\(kind.rawValue): \(shortcut.display) used by \(commandIDs.joined(separator: ", "))"
    }

    /// True for the pairs Arc itself ships and Open resolves by focus or responder chain.
    /// Every other conflict is unexpected and must fail the dump check.
    public var isKnownArcDuplicate: Bool {
        let pair = Set(commandIDs)
        return pair == ["new-folder", "new-incognito-window"]
            || pair == ["little-open-global", "new-little-open-window"]
            || pair == ["show-fonts", "new-tab"]
    }
}

/// Reports duplicate shortcuts across all scopes.
public enum ConflictChecker {
    /// Checks effective bindings (defaults plus overrides when given).
    /// Reserved commands never count as duplicates of each other. An active
    /// command that takes a reserved key reports `reservedKeyReuse`.
    public static func check(
        commands: [CommandDefinition] = CommandRegistry.all,
        overrides: KeyBindingStore = .empty
    ) -> [ShortcutConflict] {
        var owners: [KeyboardShortcut: [(id: String, scope: CommandScope, reserved: Bool)]] = [:]
        for command in commands {
            let shortcuts = command.isReserved ? command.defaultShortcuts : overrides.effectiveShortcuts(for: command)
            for shortcut in shortcuts {
                owners[shortcut, default: []].append((command.id, command.scope, command.isReserved))
            }
        }
        var conflicts: [ShortcutConflict] = []
        for (shortcut, list) in owners {
            let active = list.filter { !$0.reserved }
            let reservedOwners = list.filter(\.reserved)
            // Active command takes a reserved key.
            for owner in active where !reservedOwners.isEmpty {
                conflicts.append(ShortcutConflict(
                    shortcut: shortcut,
                    commandIDs: ([owner.id] + reservedOwners.map(\.id)).sorted(),
                    kind: .reservedKeyReuse
                ))
            }
            // Two active commands share a key in overlapping scopes.
            for first in active.indices {
                for second in active.indices where second > first {
                    let a = active[first], b = active[second]
                    guard a.id != b.id, a.scope.overlaps(b.scope) else { continue }
                    // One entry per shortcut even when three commands collide.
                    if !conflicts.contains(where: { $0.shortcut == shortcut && $0.kind == .duplicate }) {
                        let ids = active.filter { $0.scope.overlaps(a.scope) || $0.scope.overlaps(b.scope) }.map(\.id)
                        conflicts.append(ShortcutConflict(shortcut: shortcut, commandIDs: Set(ids).sorted(), kind: .duplicate))
                    }
                }
            }
        }
        return conflicts.sorted { $0.description < $1.description }
    }

    /// Conflicts that must fail a build or a settings save.
    public static func unexpected(_ conflicts: [ShortcutConflict]) -> [ShortcutConflict] {
        conflicts.filter { !$0.isKnownArcDuplicate }
    }
}
