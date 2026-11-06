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
    public var recordingCommandID: String?
    public var appendRecording = false
    public var selectedCommandID: String?
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
    public var statusMessage:String {recordingCommandID != nil || banner.isEmpty ? statusText:banner}
    public var extensionConflicts: [ExtensionShortcutConflict] {
        // Read after each keybinding save and selected-profile change; the App owns conflict policy.
        _ = store
        return Array(root.actions.extensionShortcutConflicts(profileID: root.selectedProfileID).prefix(256))
    }
    public func openExtensionShortcuts() { root.actions.openURL(URL(string: "chrome://extensions/shortcuts")!, profileID: root.selectedProfileID) }
    public var commands: [CommandDefinition] { CommandRegistry.active.filter { command in
        (query.isEmpty || ([displayTitle(command), command.id] + command.aliases).contains { $0.localizedCaseInsensitiveContains(query) })
    }.sorted { displayTitle($0).localizedStandardCompare(displayTitle($1)) == .orderedAscending } }
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
    @Bindable var model:ShortcutsViewModel
    public init(model:ShortcutsViewModel) {self.model=model}
    public var body:some View {
        VStack(spacing:30) {
            ShortcutsCallout(model:model).frame(width:359,height:35)
            HStack(alignment:.top,spacing:16) {
                VStack(spacing:0) {
                    HStack {Image(systemName:"magnifyingglass").foregroundStyle(.secondary);TextField("Type a feature name or shortcut",text:$model.query).textFieldStyle(.plain)}.padding(.horizontal,10).frame(height:38)
                    Divider()
                    List(selection:$model.selectedCommandID) {
                        let defaults=model.commands.filter{model.store.bindings[$0.id] == nil}
                        let custom=model.commands.filter{model.store.bindings[$0.id] != nil}
                        if !defaults.isEmpty {Section("Default Shortcuts") {ForEach(defaults){row($0)}}}
                        if !custom.isEmpty {Section("Custom Shortcuts") {ForEach(custom){row($0)}}}
                    }.listStyle(.plain).environment(\.defaultMinListRowHeight,48)
                }.frame(width:340,height:450).background(Color(nsColor:SettingsTokens.fill.nsColor),in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(Color(nsColor:SettingsTokens.border.nsColor)))
                VStack(alignment:.leading,spacing:12) {
                    HStack(spacing:8) {Image(systemName:"command");Image(systemName:"return")}.font(.system(size:25)).foregroundStyle(Color(nsColor:SettingsTokens.link.nsColor)).frame(height:50)
                    Text("Custom Shortcuts").font(.system(size:13,weight:.semibold))
                    Text("Change shortcuts for your favorite actions, and choose whether Open or a website takes priority.").font(.system(size:11)).foregroundStyle(.secondary)
                    if model.selectedCommandID.flatMap({CommandRegistry.byID[$0]})?.isCustomizable == true {
                        Text("When shortcuts conflict").font(.system(size:11))
                        Picker("When shortcuts conflict",selection:Binding(get:{model.root.string("open.shortcuts.defaultPriority")},set:{model.root.set($0,for:"open.shortcuts.defaultPriority")})) {Text("Open wins").tag("browser");Text("Website wins").tag("site");Text("Website first, Open on double-press").tag("site-then-browser")}.labelsHidden().controlSize(.regular)
                    }
                    if model.selectedCommandID?.hasPrefix("go-to-tab-") == true {
                        PreferenceToggle(title:"Include Favorites in ordering.",key:"open.shortcuts.includeFavoritesInTabNumbering",root:model.root).font(.system(size:11))
                        PreferenceToggle(title:"Switch to ninth tab.",key:"open.shortcuts.switchToNinthEnabled",root:model.root).font(.system(size:11))
                    }
                    if model.recordingCommandID == nil && !model.banner.isEmpty {SettingsError(text:model.statusMessage).font(.system(size:11));Button("Revert"){model.revert()}}
                    if model.recordingCommandID != nil {KeyRecorder(model:model).frame(height:1)}
                    if (model.recordingCommandID != nil || model.banner.isEmpty) && !model.statusMessage.isEmpty {Text(model.statusMessage).font(.system(size:11)).foregroundStyle(.secondary)}
                    if !model.extensionConflicts.isEmpty {
                        ExtensionConflictNotice(conflicts: model.extensionConflicts, action: { model.openExtensionShortcuts() })
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength:0)
                    HStack(spacing:6) {Spacer(minLength:0);Button("Reset All Shortcuts"){model.resetAll(confirmed:false)}.controlSize(.mini)
                        ShortcutsMoreMenu(model:model).frame(width:22,height:18)
                    }
                }.frame(width:200,height:450,alignment:.topLeading)
            }
        }.frame(maxWidth:.infinity, maxHeight:.infinity,alignment:.top)
        .confirmationDialog("Reset all shortcuts to their defaults?",isPresented:$model.confirmsReset){Button("Reset All Shortcuts",role:.destructive){model.resetAll(confirmed:true)}}
    }
    private func row(_ command:CommandDefinition)->some View {
        HStack(spacing:8) {
            Text(model.displayTitle(command)).font(.system(size:13)).lineLimit(2);Spacer(minLength:0)
            Button {model.selectedCommandID=command.id;model.beginRecording(command.id,append:NSApp.currentEvent?.modifierFlags.contains(.shift) == true)} label:{
                Text(model.recordingCommandID == command.id ? "Type…" : keyText(command)).font(Font(SettingsTokens.keycap.font)).frame(width:63,height:23).background(Color(nsColor:SettingsTokens.button.nsColor),in:RoundedRectangle(cornerRadius:4))
            }.buttonStyle(.plain).disabled(!command.isCustomizable)
        }.frame(height:48).tag(command.id).listRowInsets(.init(top:0,leading:17.5,bottom:0,trailing:10)).contentShape(Rectangle())
        .contextMenu {
            if command.isCustomizable {Button("Record Shortcut"){model.beginRecording(command.id)};Button("Clear"){model.clear(command.id)};Button("Reset"){model.reset(command.id)}
                Menu("When shortcuts conflict") {
                    Button("Open wins"){model.priority(.browserFirst,for:command.id)}
                    Button("Website wins"){model.priority(.siteFirst,for:command.id)}
                    Button("Website first, Open on double-press"){model.priority(.siteThenBrowserOnDoublePress,for:command.id)}
                }
            }
        }
    }
    private func keyText(_ command:CommandDefinition)->String {let keys=model.store.effectiveShortcuts(for:command);return keys.isEmpty ? "---":keys.map(\.symbolDisplay).joined(separator:" ")}
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

/// Preserve the pane's native menu titles and order; build on demand with the current model.
private struct ShortcutsMoreMenu: NSViewRepresentable {
    let model: ShortcutsViewModel
    func makeNSView(context: Context) -> ShortcutsMoreMenuButton { ShortcutsMoreMenuButton(model: model) }
    func updateNSView(_ view: ShortcutsMoreMenuButton, context: Context) { view.model = model }
}
@MainActor private final class ShortcutsMoreMenuButton: NSPopUpButton {
    var model: ShortcutsViewModel
    init(model: ShortcutsViewModel) {
        self.model = model
        super.init(frame: .zero, pullsDown: true)
        isBordered = false
        setAccessibilityLabel("More shortcut actions")
        let menu = NSMenu()
        menu.addItem(withTitle: "", action: nil, keyEquivalent: "").image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More shortcut actions")
        for (title, selector) in [("Revert Unsaved Changes", #selector(revert)), ("Shortcut Help", #selector(help)), ("Extension Shortcuts", #selector(extensions))] {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: ""); item.target = self
        }
        self.menu = menu
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func revert() { model.revert() }
    @objc private func help() { model.root.actions.openHelp(topic: "shortcuts") }
    @objc private func extensions() { model.openExtensionShortcuts() }
}
