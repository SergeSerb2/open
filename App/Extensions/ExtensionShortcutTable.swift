import AppKit
import OpenCommands
import OpenEngine
import OpenSettings

/// §6.2: command snapshots are event-driven. Chromium owns their persistence.
@MainActor
final class ExtensionShortcutTable {
  struct Entry {
    let command: OEExtensionCommand
    let shortcut: KeyboardShortcut
    let conflict: String?
  }
  private(set) var entries: [Entry] = []
  private(set) var conflicts: [ExtensionShortcutConflict] = []
  private var lookup: [KeyboardShortcut: OEExtensionCommand] = [:]
  func rebuild(_ manager: OEExtensionManager, overrides: KeyBindingStore) {
    var reserved: [KeyboardShortcut: String] = [:]
    for command in CommandRegistry.active {
      for key in command.defaultShortcuts + overrides.effectiveShortcuts(for: command) where reserved[key] == nil { reserved[key] = command.id }
    }
    entries = []; conflicts = []; lookup = [:]
    let names = Dictionary(manager.installedExtensions.map { ($0.identifier, $0.name) }, uniquingKeysWith: { first, _ in first })
    for command in manager.commands.prefix(1024) {
      guard let key = Self.shortcut(command.keyEquivalent, flags: command.modifierFlags) else { continue }
      let conflict = reserved[key]
      entries.append(Entry(command: command, shortcut: key, conflict: conflict))
      if let conflict {
        conflicts.append(ExtensionShortcutConflict(extensionName: names[command.extensionIdentifier] ?? command.extensionIdentifier,
          commandDescription: command.summary, shortcut: key, openCommandID: conflict))
      } else if !command.isGlobal, lookup[key] == nil { lookup[key] = command }
    }
  }
  func handle(_ event: NSEvent, factory: EngineWebContentHostFactory) -> Bool {
    guard event.type == .keyDown, let key = KeyboardShortcut.from(event: event), let command = lookup[key],
          !factory.isClosing, !factory.app.terminationRequested, factory.window?.attachedSheet == nil,
          let browser = factory.focusedBrowser else { return false }
    if command.isActionCommand || command.name == "_execute_action" {
      factory.extensions.run(command.extensionIdentifier, source: .command); return true
    }
    return browser.executeExtensionCommand(command.name, forExtension: command.extensionIdentifier)
  }
  static func shortcut(_ rawKey: String?, flags: NSEvent.ModifierFlags) -> KeyboardShortcut? {
    guard var key = rawKey, !key.isEmpty, key.utf8.count <= 32 else { return nil }
    var modifiers = ShortcutModifiers.from(eventFlags: flags)
    // Cocoa encodes Shift in the shifted character, with no Shift bit in its flags: an uppercase letter, or for
    // digits and punctuation the US-layout shifted symbol (Chromium gives "&" for Command+Shift+7).
    if let base = Self.unshifted[key] { key = base; modifiers.insert(.shift) }
    else if key != key.lowercased() { modifiers.insert(.shift) }
    let names = [" ": "space", "\t": "tab", "\r": "return", "\n": "return", "\u{1B}": "escape",
      "\u{7F}": "delete", "\u{F702}": "left", "\u{F703}": "right", "\u{F700}": "up", "\u{F701}": "down"]
    let normalized: String
    if let token = names[key] { normalized = token }
    else if let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1, (0xF704...0xF726).contains(scalar.value) { normalized = "f\(scalar.value - 0xF704 + 1)" }
    else { normalized = key.lowercased() }
    return KeyboardShortcut(key: normalized, modifiers: modifiers)
  }
  /// US-layout shifted symbol → its key (Chromium's suggested keys use US key names).
  static let unshifted: [String: String] = [
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
  ]
  static func keycaps(_ key: String?, flags: NSEvent.ModifierFlags) -> [String] {
    guard let shortcut = shortcut(key, flags: flags) else { return [] }
    var result: [String] = []
    if shortcut.modifiers.contains(.control) { result.append("⌃") }
    if shortcut.modifiers.contains(.option) { result.append("⌥") }
    if shortcut.modifiers.contains(.shift) { result.append("⇧") }
    if shortcut.modifiers.contains(.command) { result.append("⌘") }
    result.append(KeyboardShortcut.displayKey(shortcut.key)); return result
  }
  var state: [[String: Any]] {
    entries.map { entry in
      let c = entry.command
      return ["extension": c.extensionIdentifier, "name": c.name, "summary": c.summary,
        "keyEquivalent": c.keyEquivalent, "modifierFlags": c.modifierFlags.rawValue,
        "key": entry.shortcut.key, "modifiers": entry.shortcut.modifiers.names, "shortcut": entry.shortcut.symbolDisplay,
        "global": c.isGlobal, "actionCommand": c.isActionCommand, "dropped": entry.conflict != nil,
        "openCommandID": entry.conflict ?? ""]
    }
  }
}
