import Foundation
import Observation
import SwiftUI
import AppKit
import OpenCommands
import OpenDesign

@MainActor @Observable public final class ShortcutsViewModel {
    unowned let root: SettingsViewModel
    public private(set) var store: KeyBindingStore
    private var saved: KeyBindingStore
    public var query = ""
    public var filter = "all"
    public var category = "all"
    public var findByKeys = false
    public var findShortcut: OpenCommands.KeyboardShortcut?
    // Filtering preserves this order. Re-sorting the same command metadata in
    // the list, height calculation and empty-state branch delayed first layout.
    private static let orderedCommands = CommandRegistry.active.sorted {
        let left = $0.title == "Automatic" ? "Use Automatic Appearance" : $0.title
        let right = $1.title == "Automatic" ? "Use Automatic Appearance" : $1.title
        return left.localizedStandardCompare(right) == .orderedAscending
    }
    public static func category(for command: CommandDefinition) -> String {
        if command.id.contains("split") { return "Split View" }
        if command.menuPath?.first == "Tabs" || ["new-tab", "close-tab", "next-tab", "previous-tab"].contains(command.id) { return "Tabs" }
        return command.menuPath?.first ?? "Other"
    }
    public var categoryNames: [String] {
        let names = Set(CommandRegistry.active.map { Self.category(for: $0) })
        return ["Tabs", "Spaces", "Split View"].filter { names.contains($0) } + names.subtracting(["Tabs", "Spaces", "Split View"]).sorted()
    }
    public func count(for filter: String) -> Int { CommandRegistry.active.filter { matches($0, filter: filter) }.count }
    private func matches(_ command: CommandDefinition, filter: String) -> Bool {
        switch filter {
        case "changed": return store.bindings[command.id] != nil
        case "unassigned": return store.effectiveShortcuts(for: command).isEmpty
        case "conflicts": return unexpected.contains { $0.commandIDs.contains(command.id) }
        default: return true
        }
    }
    public func find(_ shortcut: OpenCommands.KeyboardShortcut) { findShortcut = shortcut; findByKeys = false; query = "" }
    public func conflictText(for id: String) -> String? {
        let others = unexpected.filter { $0.commandIDs.contains(id) }.flatMap(\.commandIDs).filter { $0 != id }
        guard !others.isEmpty else { return nil }
        return "Also used by “" + others.map { CommandRegistry.byID[$0]?.title ?? "reserved key" }.joined(separator: "”, “") + "”. Choose one to keep."
    }
    public func keepShortcut(for id: String) {
        let others = Set(unexpected.filter { $0.commandIDs.contains(id) }.flatMap(\.commandIDs)).subtracting([id])
        guard others.allSatisfy({ CommandRegistry.byID[$0]?.isCustomizable == true && CommandRegistry.byID[$0]?.isReserved == false }) else { return }
        for other in others { store.setOverride(.init(shortcuts: [], priority: store.bindings[other]?.priority), for: other) }
        saveDraft()
    }
    public func canKeepShortcut(for id: String) -> Bool {
        let others = Set(unexpected.filter { $0.commandIDs.contains(id) }.flatMap(\.commandIDs)).subtracting([id])
        return !others.isEmpty && others.allSatisfy { CommandRegistry.byID[$0]?.isCustomizable == true && CommandRegistry.byID[$0]?.isReserved == false }
    }
    public func importBindings(from url: URL) {
        // An import replaces every binding, like Reset All, so it also resolves an unreadable saved file.
        do { store = try KeyBindingStore.load(from: url); loadFailed = false; saveDraft() }
        catch { statusText = "Could not read key bindings. Your saved shortcuts were kept." }
    }
    public func exportBindings(to url: URL) {
        do { try saved.save(to: url); statusText = "Exported." }
        catch { statusText = "Could not export key bindings." }
    }
    public var recordingCommandID: String?
    public var appendRecording = false
    public var selectedCommandID: String?
    public private(set) var conflicts: [ShortcutConflict] = [] {
        didSet { unexpected = ConflictChecker.unexpected(conflicts) }
    }
    public private(set) var unexpected: [ShortcutConflict] = []
    public var statusText = ""
    public var confirmsReset = false
    private var loadFailed = false
    public var fileURL: URL { root.root.appendingPathComponent("State/keybindings.json") }
    public init(root: SettingsViewModel) {
        self.root = root
        let url = root.root.appendingPathComponent("State/keybindings.json")
        do { let loaded = FileManager.default.fileExists(atPath: url.path) ? try KeyBindingStore.load(from: url) : .empty; store = loaded; saved = loaded }
        catch { store = .empty; saved = .empty; loadFailed = true; statusText = "Could not read key bindings. Resolve the file error before saving." }
        conflicts = ConflictChecker.check(overrides: store)
        unexpected = ConflictChecker.unexpected(conflicts)
    }
    public var banner: String { unexpected.map { conflict in
        let names = conflict.commandIDs.map { CommandRegistry.byID[$0]?.isReserved == true ? "reserved key" : CommandRegistry.byID[$0]?.title ?? $0 }
        return "\(conflict.shortcut.symbolDisplay) is used by \(names.joined(separator: " and ")). Clear one shortcut to save."
    }.joined(separator: "\n") }
    public var statusMessage:String {recordingCommandID != nil || banner.isEmpty ? statusText:banner}
    public var extensionConflicts: [ExtensionShortcutConflict] {
        // Read after each keybinding save and selected-profile change; the App owns conflict policy.
        _ = store
        return Array(root.actions.extensionShortcutConflicts(profileID: root.selectedProfileID).prefix(256))
    }
    public func openExtensionShortcuts() { root.actions.openURL(URL(string: "chrome://extensions/shortcuts")!, profileID: root.selectedProfileID) }
    public var commands: [CommandDefinition] { Self.orderedCommands.filter { command in
        (query.isEmpty || ([displayTitle(command), command.id] + command.aliases).contains { $0.localizedCaseInsensitiveContains(query) })
        && matches(command, filter: filter)
        && (category == "all" || Self.category(for: command) == category)
        && (findShortcut == nil || store.effectiveShortcuts(for: command).contains(findShortcut!))
    } }
    public func displayTitle(_ command:CommandDefinition)->String {command.title == "Automatic" ? "Use Automatic Appearance":command.title}
    public func beginRecording(_ id: String, append: Bool = false) { guard CommandRegistry.byID[id]?.isCustomizable == true else { return }; selectedCommandID = id; appendRecording = append; recordingCommandID = id; statusText = "Press a shortcut. Escape cancels; Delete clears." }
    public func cancelRecording() { recordingCommandID = nil; statusText = "Recording cancelled." }
    public func record(_ shortcut: OpenCommands.KeyboardShortcut, for id: String, append: Bool = false) {
        guard let command = CommandRegistry.byID[id], command.isCustomizable, !command.isReserved else { return }
        let key=shortcut.key.lowercased()
        let functionNumber=key.hasPrefix("f") ? Int(key.dropFirst()) : nil
        let bareSpecial=["left","right","up","down"].contains(key) || functionNumber.map{(1...35).contains($0)} == true
        guard !shortcut.modifiers.intersection([.command,.control,.option]).isEmpty || bareSpecial else {
            recordingCommandID=id; statusText="Use ⌘, ⌃, or ⌥ with a key."; return
        }
        selectedCommandID = id
        var keys = append ? store.effectiveShortcuts(for: command) : []; if !keys.contains(shortcut) { keys.append(shortcut) }
        let priority: ShortcutPriority?
        if let existing = store.bindings[id] { priority = existing.priority }
        else { priority = ShortcutPriority(rawValue: root.string("open.shortcuts.defaultPriority")) ?? .browserFirst }
        store.setOverride(KeyBindingOverride(shortcuts: keys, priority: priority), for: id); recordingCommandID = nil; saveDraft()
    }
    public func clear(_ id: String) { guard let command = CommandRegistry.byID[id], command.isCustomizable, !command.isReserved else { return }; store.setOverride(.init(shortcuts: [], priority: store.bindings[id]?.priority), for: id); recordingCommandID = nil; saveDraft() }
    public func reset(_ id: String) { guard let command = CommandRegistry.byID[id], command.isCustomizable, !command.isReserved else { return }; store.setOverride(nil, for: id); saveDraft() }
    public func priority(_ value: ShortcutPriority, for id: String) {
        guard let command = CommandRegistry.byID[id], command.isCustomizable, !command.isReserved else { return }
        store.setOverride(.init(shortcuts: store.effectiveShortcuts(for: command), priority: value), for: id); saveDraft()
    }
    public func revert() { store = saved; conflicts = ConflictChecker.check(overrides: store); statusText = "Reverted." }
    public func resetAll(confirmed: Bool) { guard confirmed else { confirmsReset = true; return }; loadFailed = false; store = .empty; saveDraft() }
    private func saveDraft() {
        conflicts = ConflictChecker.check(overrides: store)
        guard unexpected.isEmpty else { statusText = "Fix the conflicts to save."; return }
        guard !loadFailed else { return }
        do { try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true); try store.save(to: fileURL); saved = store; root.actions.keyBindingsDidChange(store: store); statusText = "Saved." }
        catch { statusText = "Could not save key bindings. \(error.localizedDescription)" }
    }
}
public struct ShortcutsPane: View {
    @Bindable var model: ShortcutsViewModel
    @Environment(\.colorScheme) private var scheme
    private var accent: Color { Color(nsColor: SettingsStyle.accessibleAccent(model.root.settingsAccentSource, dark: scheme == .dark)) }
    public init(model: ShortcutsViewModel) { self.model = model }
    public var body: some View {
        let commands = model.commands
        VStack(alignment: .leading, spacing: 10) {
            SettingsShortcutTools(model: model, query: model.query, filter: model.filter,
                category: model.category, categories: model.categoryNames,
                counts: ["all", "changed", "unassigned", "conflicts"].map { model.count(for: $0) },
                finding: model.findByKeys, found: model.findShortcut?.symbolDisplay, accent: NSColor(accent))
                .frame(height: 70)
            SettingsShortcutsList(model: model, commands: commands, revision: model.store, recording: model.recordingCommandID, findByKeys: model.findByKeys, selection: model.selectedCommandID)
                .frame(height: listHeight(commands)).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: SettingsStyle.hairline.nsColor), lineWidth: 1))
            let notice = commands.isEmpty ? "No shortcuts found. Try another name or filter." : model.statusMessage
            if !notice.isEmpty { SettingsInlineMessage(text: notice) }
            if !model.unexpected.isEmpty { Button("Revert Unsaved Changes") { model.revert() } }
            if !model.extensionConflicts.isEmpty { ExtensionConflictNotice(conflicts: model.extensionConflicts, action: { model.openExtensionShortcuts() }) }
            HStack { Button("Learn the Essential Shortcuts") { model.root.actions.openEssentialShortcuts() }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(accent).id("shortcuts/essential"); Spacer() }
            overlapPolicy
        }.sheet(isPresented: $model.confirmsReset) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Reset all shortcuts?").font(.system(size: 22, weight: .semibold))
                Text("Your custom shortcuts and priorities will return to their defaults.")
                HStack {
                    Button("Cancel") { model.confirmsReset = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Reset all shortcuts", role: .destructive) { model.resetAll(confirmed: true); model.confirmsReset = false }.keyboardShortcut(.defaultAction).accessibilityLabel("Reset All Shortcuts")
                }
            }.padding(24).frame(width: 460).settingsSheet()
        }
    }
    private var overlapPolicy: AnyView {
        AnyView(OpenSettingsGroup("When shortcuts overlap") {
                OpenSettingsRow(root: model.root, id: "shortcuts/priority", title: "When shortcuts conflict", changed: model.root.string("open.shortcuts.defaultPriority") != "browser", last: true, reset: { model.root.set("browser", for: "open.shortcuts.defaultPriority") }) {
                    OpenSettingsPop(title: "When shortcuts conflict", value: Binding(get: { model.root.string("open.shortcuts.defaultPriority") }, set: { model.root.set($0, for: "open.shortcuts.defaultPriority") }), options: [("Open wins", "browser"), ("Website wins", "site"), ("Website first, Open on double-press", "site-then-browser")])
                }
            })
    }
    private func listHeight(_ commands: [CommandDefinition]) -> CGFloat {
        var height: CGFloat = 0
        for command in commands {
            let row: CGFloat = model.conflictText(for: command.id) != nil || command.scope == .global ? 60 : 44
            if height + row > 352 { break }
            height += row
        }
        return max(44, height)
    }

}
private struct KeyRecorder: NSViewRepresentable {
    let model: ShortcutsViewModel
    func makeNSView(context: Context) -> CaptureView { CaptureView(model: model) }
    func updateNSView(_ view: CaptureView, context: Context) { if model.recordingCommandID != nil { view.window?.makeFirstResponder(view) } }
    @MainActor final class CaptureView: NSView {
        let model: ShortcutsViewModel
        init(model: ShortcutsViewModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }
        override func keyDown(with event: NSEvent) {
            guard let id = model.recordingCommandID else { return }
            if event.keyCode == 53 { model.cancelRecording() }
            else if event.keyCode == 51 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty { model.clear(id) }
            else if let shortcut = OpenCommands.KeyboardShortcut.from(event: event) { model.record(shortcut, for: id, append: model.appendRecording) }
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool { keyDown(with: event); return true }
    }
}

/// Settings ▸ Shortcuts callout (CC-29, CC-30): Arc's "Start with the basics" is a callout with one
/// button that opens the Essential Keyboard Shortcuts window, not a filter. Same frame as before
/// (359 × 35, radius 6, `SettingsTokens.button`).
struct ShortcutsCallout: View {
    let model: ShortcutsViewModel
    var body: some View {
        HStack(spacing: 8) {
            Text("Start with the basics").font(Font(SettingsTokens.tabLabel.font)).foregroundStyle(.primary)
                .padding(.leading, 12)
            Spacer(minLength: 4)
            Button { model.root.actions.openEssentialShortcuts() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "command.circle.fill")
                    Text("Learn the Essential Shortcuts")
                }
                .font(Font(SettingsTokens.tabLabel.font)).foregroundStyle(.white)
                .padding(.horizontal, 10).frame(height: 27)
                .background(Color(nsColor: SettingsTokens.segmentAccent.nsColor), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain).padding(.trailing, 4)
            .accessibilityLabel("Learn the Essential Shortcuts")
        }
        .frame(width: 359, height: 35)
        .background(Color(nsColor: SettingsTokens.button.nsColor), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// The existing pane hosts AppKit notice lines and a link; extension commands never become list rows.
private struct ExtensionConflictNotice: NSViewRepresentable {
    var conflicts: [ExtensionShortcutConflict]
    var action: @MainActor () -> Void
    func makeNSView(context: Context) -> ExtensionConflictNoticeView { ExtensionConflictNoticeView() }
    func updateNSView(_ view: ExtensionConflictNoticeView, context: Context) { view.update(conflicts, action: action) }
}
@MainActor private final class ExtensionConflictNoticeView: NSStackView {
    private var notices: [String] = []
    private var action: (@MainActor () -> Void)?
    init() { super.init(frame: .zero); orientation = .vertical; alignment = .leading; spacing = 6 }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(_ conflicts: [ExtensionShortcutConflict], action: @escaping @MainActor () -> Void) {
        self.action = action
        let lines = conflicts.map(\.notice)
        guard lines != notices else { return }
        notices = lines
        for view in arrangedSubviews { removeArrangedSubview(view); view.removeFromSuperview() }
        for line in lines {
            let label = NSTextField(wrappingLabelWithString: line)
            label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 200
            label.setAccessibilityLabel(line)
            addArrangedSubview(label)
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        }
        if !lines.isEmpty {
            let button = NSButton(title: "Extension Shortcuts…", target: self, action: #selector(openShortcuts))
            button.isBordered = false; button.contentTintColor = SettingsTokens.link.nsColor
            button.font = .systemFont(ofSize: 11); button.alignment = .left
            addArrangedSubview(button)
        }
    }
    @objc private func openShortcuts() { action?() }
}

/// Labelled native menu; all actions use the existing shortcut model.
struct ShortcutsMoreMenu: NSViewRepresentable {
    let model: ShortcutsViewModel
    func makeNSView(context: Context) -> ShortcutsMoreMenuButton { ShortcutsMoreMenuButton(model: model) }
    func updateNSView(_ view: ShortcutsMoreMenuButton, context: Context) { view.model = model }
}
@MainActor final class ShortcutsMoreMenuButton: NSPopUpButton {
    var model: ShortcutsViewModel
    init(model: ShortcutsViewModel) {
        self.model = model
        super.init(frame: .zero, pullsDown: true)
        isBordered = false
        setAccessibilityLabel("More shortcut actions")
        let menu = NSMenu()
        menu.addItem(withTitle: "More", action: nil, keyEquivalent: "")
        font = .systemFont(ofSize: 13, weight: .medium)
        for (title, selector) in [("Import…", #selector(importKeys)), ("Export…", #selector(exportKeys)), ("Revert…", #selector(revert)), ("Shortcut help", #selector(help)), ("Extension shortcuts…", #selector(extensions))] {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: ""); item.target = self
        }
        self.menu = menu
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func importKeys() { let panel = NSOpenPanel(); panel.canChooseDirectories = false; if panel.runModal() == .OK, let url = panel.url { model.importBindings(from: url) } }
    @objc private func exportKeys() { let panel = NSSavePanel(); panel.nameFieldStringValue = "Open-shortcuts.json"; if panel.runModal() == .OK, let url = panel.url { model.exportBindings(to: url) } }
    @objc private func revert() { model.revert() }
    @objc private func help() { model.root.actions.openHelp(topic: "shortcuts") }
    @objc private func extensions() { model.openExtensionShortcuts() }
}
