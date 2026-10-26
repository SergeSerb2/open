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
    public var basics = true
    public var recordingCommandID: String?
    public var appendRecording = false
    public private(set) var conflicts: [ShortcutConflict] = []
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
    }
    public var unexpected: [ShortcutConflict] { ConflictChecker.unexpected(conflicts) }
    public var banner: String { unexpected.map { conflict in
        let names = conflict.commandIDs.map { CommandRegistry.byID[$0]?.isReserved == true ? "reserved key" : CommandRegistry.byID[$0]?.title ?? $0 }
        return "\(conflict.shortcut.symbolDisplay) is used by \(names.joined(separator: " and ")). Clear one shortcut to save."
    }.joined(separator: "\n") }
    public var commands: [CommandDefinition] { CommandRegistry.active.filter { command in
        (query.isEmpty || ([command.title, command.id] + command.aliases).contains { $0.localizedCaseInsensitiveContains(query) }) && (!basics || !command.aliases.isEmpty || store.bindings[command.id] != nil)
    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    public func beginRecording(_ id: String, append: Bool = false) { guard CommandRegistry.byID[id]?.isCustomizable == true else { return }; appendRecording = append; recordingCommandID = id; statusText = "Press a shortcut. Escape cancels; Delete clears." }
    public func cancelRecording() { recordingCommandID = nil; statusText = "Recording cancelled." }
    public func record(_ shortcut: OpenCommands.KeyboardShortcut, for id: String, append: Bool = false) {
        guard let command = CommandRegistry.byID[id], command.isCustomizable, !command.isReserved else { return }
        var keys = append ? store.effectiveShortcuts(for: command) : []; if !keys.contains(shortcut) { keys.append(shortcut) }
        let priority = store.bindings[id]?.priority ?? ShortcutPriority(rawValue: root.string("open.shortcuts.defaultPriority")) ?? .browserFirst
        store.setOverride(KeyBindingOverride(shortcuts: keys, priority: priority), for: id); recordingCommandID = nil; saveDraft()
    }
    public func clear(_ id: String) { guard CommandRegistry.byID[id]?.isCustomizable == true else { return }; store.setOverride(.init(shortcuts: [], priority: store.bindings[id]?.priority), for: id); recordingCommandID = nil; saveDraft() }
    public func reset(_ id: String) { guard CommandRegistry.byID[id]?.isCustomizable == true else { return }; store.setOverride(nil, for: id); saveDraft() }
    public func priority(_ value: ShortcutPriority, for id: String) {
        guard let command = CommandRegistry.byID[id], command.isCustomizable else { return }
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
    public init(model: ShortcutsViewModel) { self.model = model }
    public var body: some View {
        Picker("Learn shortcuts", selection: $model.basics) { Text("Start with the basics").tag(true); Text("Learn the Essential Shortcuts").tag(false) }.pickerStyle(.segmented)
        TextField("Search shortcuts", text: $model.query).textFieldStyle(.roundedBorder)
        SettingsGroup("") {
            HStack { Text("When shortcuts conflict"); Spacer(); Picker("Priority for new bindings", selection: Binding(get: { model.root.string("open.shortcuts.defaultPriority") }, set: { model.root.set($0, for: "open.shortcuts.defaultPriority") })) { Text("Open wins").tag("browser"); Text("Website wins").tag("site"); Text("Website first, Open on double-press").tag("site-then-browser") }.labelsHidden() }
            PreferenceToggle(title: "Include Favorites in Go to Tab numbering", key: "open.shortcuts.includeFavoritesInTabNumbering", root: model.root)
            PreferenceToggle(title: "Switch to ninth tab", key: "open.shortcuts.switchToNinthEnabled", root: model.root)
        }
        if !model.banner.isEmpty { SettingsGroup("") { SettingsError(text: model.banner); Button("Revert") { model.revert() } } }
        if model.recordingCommandID != nil { KeyRecorder(model: model).frame(height: 34).overlay(Text("Press your shortcut…").allowsHitTesting(false)) }
        List {
            Section("Default Shortcuts") { ForEach(model.commands.filter { model.store.bindings[$0.id] == nil }) { row($0) } }
            Section("Custom Shortcuts") { ForEach(model.commands.filter { model.store.bindings[$0.id] != nil }) { row($0) } }
        }.frame(height: 185)
        ForEach(model.conflicts.filter(\.isKnownArcDuplicate), id: \.self) { Text("Known shared shortcut: \($0.commandIDs.compactMap { CommandRegistry.byID[$0]?.title }.joined(separator: " / "))").font(.caption).foregroundStyle(.secondary) }
        HStack { Button("Reset All Shortcuts") { model.resetAll(confirmed: false) }; Spacer(); Text(model.statusText).font(.caption).foregroundStyle(.secondary) }
            .confirmationDialog("Reset all shortcuts to their defaults?", isPresented: $model.confirmsReset) { Button("Reset All Shortcuts", role: .destructive) { model.resetAll(confirmed: true) } }
    }
    private func row(_ command: CommandDefinition) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(command.title); Spacer(); Text(command.scope.rawValue).font(.caption2).foregroundStyle(.secondary)
                Text(model.store.effectiveShortcuts(for: command).map(\.symbolDisplay).joined(separator: "  ")).font(Font(Typography.keycap.font)).padding(4).background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            if command.isCustomizable { HStack {
                Button("Record") { model.beginRecording(command.id, append: NSApp.currentEvent?.modifierFlags.contains(.shift) == true) }
                Button("Clear") { model.clear(command.id) }; Button("Reset") { model.reset(command.id) }
                Spacer(); Picker("Priority", selection: Binding(get: { model.store.effectivePriority(for: command) }, set: { model.priority($0, for: command.id) })) { Text("Browser").tag(ShortcutPriority.browserFirst); Text("Site").tag(ShortcutPriority.siteFirst); Text("Site, then Browser").tag(ShortcutPriority.siteThenBrowserOnDoublePress) }.labelsHidden().fixedSize()
            }.controlSize(.small) }
        }.padding(.vertical, 4)
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
