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
    public var commands: [CommandDefinition] { CommandRegistry.active.filter { command in
        (query.isEmpty || ([command.title, command.id] + command.aliases).contains { $0.localizedCaseInsensitiveContains(query) }) && (!basics || !command.aliases.isEmpty || store.bindings[command.id] != nil)
    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    public func beginRecording(_ id: String, append: Bool = false) { guard CommandRegistry.byID[id]?.isCustomizable == true else { return }; selectedCommandID = id; appendRecording = append; recordingCommandID = id; statusText = "Press a shortcut. Escape cancels; Delete clears." }
    public func cancelRecording() { recordingCommandID = nil; statusText = "Recording cancelled." }
    public func record(_ shortcut: OpenCommands.KeyboardShortcut, for id: String, append: Bool = false) {
        guard let command = CommandRegistry.byID[id], command.isCustomizable, !command.isReserved else { return }
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
            ShortcutSegments(model:model).frame(width:380,height:35)
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
                    if model.selectedCommandID?.hasPrefix("go-to-tab-") == true {
                        Text("When shortcuts conflict").font(.system(size:11))
                        Picker("When shortcuts conflict",selection:Binding(get:{model.root.string("open.shortcuts.defaultPriority")},set:{model.root.set($0,for:"open.shortcuts.defaultPriority")})) {Text("Open wins").tag("browser");Text("Website wins").tag("site");Text("Website first, Open on double-press").tag("site-then-browser")}.labelsHidden()
                        PreferenceToggle(title:"Include Favorites in ordering.",key:"open.shortcuts.includeFavoritesInTabNumbering",root:model.root).font(.system(size:11))
                        PreferenceToggle(title:"Switch to ninth tab.",key:"open.shortcuts.switchToNinthEnabled",root:model.root).font(.system(size:11))
                    }
                    if !model.banner.isEmpty {SettingsError(text:model.banner).font(.system(size:11));Button("Revert"){model.revert()}}
                    if model.recordingCommandID != nil {Text("Press your shortcut…").font(.system(size:11));KeyRecorder(model:model).frame(height:1)}
                    if !model.statusText.isEmpty {Text(model.statusText).font(.system(size:11)).foregroundStyle(.secondary)}
                    Spacer(minLength:0)
                    HStack(spacing:6) {Spacer(minLength:0);Button("Reset All Shortcuts"){model.resetAll(confirmed:false)}.controlSize(.mini)
                        Menu {Button("Revert Unsaved Changes"){model.revert()};Button("Shortcut Help"){model.root.actions.openHelp(topic:"shortcuts")}} label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).fixedSize()
                    }
                }.frame(width:200,height:450,alignment:.topLeading)
            }
        }.frame(maxWidth:.infinity, maxHeight:.infinity,alignment:.top)
        .confirmationDialog("Reset all shortcuts to their defaults?",isPresented:$model.confirmsReset){Button("Reset All Shortcuts",role:.destructive){model.resetAll(confirmed:true)}}
    }
    private func row(_ command:CommandDefinition)->some View {
        HStack(spacing:8) {
            Text(command.title).font(.system(size:12)).lineLimit(2);Spacer(minLength:0)
            Button {model.selectedCommandID=command.id;model.beginRecording(command.id,append:NSApp.currentEvent?.modifierFlags.contains(.shift) == true)} label:{
                Text(model.recordingCommandID == command.id ? "Type…" : keyText(command)).font(Font(SettingsTokens.keycap.font)).frame(width:63,height:23).background(Color(nsColor:SettingsTokens.button.nsColor),in:RoundedRectangle(cornerRadius:4))
            }.buttonStyle(.plain).disabled(!command.isCustomizable)
        }.frame(height:48).tag(command.id).listRowInsets(.init(top:0,leading:10,bottom:0,trailing:10)).contentShape(Rectangle())
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

private struct ShortcutSegments:NSViewRepresentable {
    let model:ShortcutsViewModel
    func makeCoordinator()->Coordinator {Coordinator(model)}
    func makeNSView(context:Context)->Segments {
        let control=Segments(labels:["Start with the basics","Learn the Essential Shortcuts"],trackingMode:.selectOne,target:context.coordinator,action:#selector(Coordinator.select(_:)))
        control.setWidth(174,forSegment:0);control.setWidth(206,forSegment:1);control.setAccessibilityLabel("Shortcuts");return control
    }
    func updateNSView(_ control:Segments,context:Context){control.selectedSegment=model.basics ? 0:1;control.needsDisplay=true}
    @MainActor final class Coordinator:NSObject {
        let model:ShortcutsViewModel
        init(_ model:ShortcutsViewModel){self.model=model}
        @objc func select(_ sender:NSSegmentedControl){model.basics=sender.selectedSegment == 0}
    }
    @MainActor final class Segments:NSSegmentedControl {
        override var isFlipped:Bool {true}
        override var intrinsicContentSize:NSSize {NSSize(width:380,height:35)}
        override func draw(_ dirtyRect:NSRect) {
            SettingsTokens.button.nsColor.setFill();NSBezierPath(roundedRect:bounds,xRadius:6,yRadius:6).fill()
            let selected=selectedSegment == 0 ? NSRect(x:0,y:0,width:174,height:35):NSRect(x:174,y:0,width:206,height:35)
            SettingsTokens.selectedTab.nsColor.setFill();NSBezierPath(roundedRect:selected,xRadius:6,yRadius:6).fill()
            for (index,width) in [CGFloat(174),206].enumerated() {
                let title=label(forSegment:index) ?? "";let attributes:[NSAttributedString.Key:Any]=[.font:SettingsTokens.tabLabel.font,.foregroundColor:NSColor.labelColor]
                let size=(title as NSString).size(withAttributes:attributes);let x:CGFloat=index == 0 ? 0:174
                (title as NSString).draw(at:.init(x:x+(width-size.width)/2,y:(35-size.height)/2),withAttributes:attributes)
            }
        }
    }
}
