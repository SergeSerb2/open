import AppKit
import SwiftUI
import OpenDesign
import OpenCommands

typealias SettingsStyle = SettingsTokens.Redesign

struct OpenSettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color(nsColor: SettingsStyle.card.nsColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: SettingsStyle.hairline.nsColor), lineWidth: 1))
    }
}

struct OpenSettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).tracking(0.22)
                .foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor)).padding(.leading, 4)
            OpenSettingsCard { content }
        }.padding(.top, 24)
    }
}

struct OpenSettingsRow<Accessory: View>: View {
    let root: SettingsViewModel
    let id: String
    let title: String
    var help = ""
    var changed = false
    var last = false
    var reset: (() -> Void)?
    var helpAction: (() -> Void)? = nil
    var checkbox: Binding<Bool>? = nil
    @ViewBuilder var accessory: Accessory
    @State private var hovered = false
    @State private var pulse = false
    @Environment(\.settingsPage) private var page
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    private var accent: Color { Color(nsColor: SettingsStyle.accessibleAccent(root.settingsAccentSource, dark: scheme == .dark)) }
    private var rowContent: some View {
        HStack(spacing: 12) {
            if let checkbox {
                Toggle(title, isOn: checkbox).labelsHidden().toggleStyle(.checkbox).accessibilityLabel(title)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .regular)).foregroundStyle(Color(nsColor: enabled ? SettingsStyle.text.nsColor : SettingsStyle.secondary.nsColor)).fixedSize(horizontal: false, vertical: true)
                if !help.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(help).fixedSize(horizontal: false, vertical: true)
                        if let helpAction { Button("Learn more", action: helpAction).buttonStyle(.plain).foregroundStyle(accent).fixedSize() }
                    }.font(.system(size: 11.5)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if changed, let reset, hovered || focused {
                Button("↺ Reset", action: reset).buttonStyle(.plain)
                    .font(.system(size: 11.5)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
                    .accessibilityLabel("Reset " + title).fixedSize()
            }
            accessory
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(minHeight: help.isEmpty ? 44 : 60)
        .overlay(alignment: .leading) { if changed { Circle().fill(accent).frame(width: 4, height: 4).padding(.leading, 5).accessibilityHidden(true) } }
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Color(nsColor: SettingsStyle.hairline.nsColor)).frame(height: 1).padding(.leading, 14) } }
        .background(pulse ? Color(nsColor: SettingsStyle.sunStart.nsColor).opacity(0.24) : Color.clear)
        .contentShape(Rectangle()).background(SettingsHoverRegion(hovered: $hovered).allowsHitTesting(false))
    }
    var body: some View {
        rowContent
        .focusable(changed).focused($focused).focusEffectDisabled()
        .overlay { if focused { RoundedRectangle(cornerRadius: 7).stroke(accent.opacity(0.35), lineWidth: 3).padding(1.5) } }
        .onChange(of: focused) { _, value in
            if value { root.focusedSettingID = id }
            else if root.focusedSettingID == id { root.focusedSettingID = nil }
        }
        .onDisappear { if root.focusedSettingID == id { root.focusedSettingID = nil } }
        .accessibilityElement(children: .contain).accessibilityLabel(title)
        .accessibilityValue(changed ? "Changed from default" : "Default")
        .accessibilityHint(help).accessibilityIdentifier(id).id(id)
        .task(id: page?.revision ?? root.arrivalRevision) {
            guard (page == nil ? root.arrivalID : page?.target) == id else { return }
            pulse = true
            withAnimation(.easeOut(duration: SettingsStyle.arrivalDuration)) { pulse = false }
        }
    }
}

struct OpenSettingsButtonStyle: ButtonStyle {
    var attention = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color(nsColor: attention ? SettingsStyle.sunText.nsColor : SettingsStyle.text.nsColor))
            .padding(.horizontal, attention ? 14 : 11).frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: attention ? 8 : 7).fill(attention
                    ? LinearGradient(colors: [Color(nsColor: SettingsStyle.sunStart.nsColor), Color(nsColor: SettingsStyle.sunEnd.nsColor)], startPoint: .top, endPoint: .bottom)
                    : LinearGradient(colors: [Color(nsColor: SettingsStyle.control.nsColor)], startPoint: .top, endPoint: .bottom))
            }
            .overlay(RoundedRectangle(cornerRadius: attention ? 8 : 7).stroke(Color(nsColor: SettingsStyle.controlLine.nsColor), lineWidth: 1))
            .opacity(!enabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
    }
}

struct OpenSettingsSwitchStyle: ToggleStyle {
    var accent: Color
    var label: String
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? accent : Color(nsColor: SettingsStyle.control.nsColor))
                Capsule().stroke(Color(nsColor: SettingsStyle.controlLine.nsColor), lineWidth: 1)
                Circle().fill(Color(nsColor: SettingsStyle.white.nsColor)).frame(width: 17, height: 17)
                    .shadow(color: Color(nsColor: SettingsStyle.shadow.nsColor), radius: 1, y: 1).padding(.horizontal, 2.5)
            }.frame(width: 36, height: 22)
        }.buttonStyle(.plain).opacity(enabled ? 1 : 0.45)
            .accessibilityElement(children: .ignore).accessibilityLabel(label)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
            .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
    }
}

struct OpenPreferenceRow: View {
    let root: SettingsViewModel
    let id: String
    let title: String
    let key: String
    var help = ""
    var last = false
    @Environment(\.colorScheme) private var scheme
    private var expected: Bool { SettingsDefaults.values[key] as? Bool ?? false }
    var body: some View {
        OpenSettingsRow(root: root, id: id, title: title, help: help, changed: root.bool(key) != expected, last: last,
            reset: { root.set(expected, for: key) }) {
            Toggle(title, isOn: Binding(get: { root.bool(key) }, set: { root.set($0, for: key) }))
                .toggleStyle(OpenSettingsSwitchStyle(accent: Color(nsColor: SettingsStyle.accessibleAccent(root.settingsAccentSource, dark: scheme == .dark)), label: title))
        }
    }
}

struct OpenSettingsSegments: View {
    let title: String
    @Binding var selection: String
    let options: [(String, String)]
    var body: some View {
        HStack(spacing: 0) { ForEach(options, id: \.1) { label, value in
            Button { selection = value } label: {
                Text(label).font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).frame(height: 24)
                    .foregroundStyle(Color(nsColor: selection == value ? SettingsStyle.text.nsColor : SettingsStyle.secondary.nsColor))
                    .background { if selection == value { RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: SettingsStyle.card.nsColor)).shadow(color: Color(nsColor: SettingsStyle.shadow.nsColor), radius: 1, y: 1) } }
            }.buttonStyle(.plain).accessibilityLabel(title + ": " + label).accessibilityAddTraits(selection == value ? [.isSelected] : [])
        } }.padding(2).frame(height: 28).background(Color(nsColor: SettingsStyle.control.nsColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: SettingsStyle.controlLine.nsColor), lineWidth: 1))
    }
}

struct OpenSettingsPop<Value: Hashable>: View {
    let title: String
    @Binding var value: Value
    let options: [(String, Value)]
    var profile = false
    var accent: NSColor? = nil
    private var width: CGFloat {
        let label = options.first(where: { $0.1 == value })?.0 ?? "Choose"
        return ceil((label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width) + (profile ? 55 : 32)
    }
    var body: some View {
        SettingsNativeChoice(title: title, value: $value, options: options, profile: profile, accent: accent)
            .frame(width: width, height: profile ? 28 : 26)
    }
}

private struct SettingsNativeChoice<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var value: Value
    let options: [(String, Value)]
    let profile: Bool
    let accent: NSColor?
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> SettingsChoiceButton {
        let button = SettingsChoiceButton(frame: .zero, pullsDown: false)
        button.isBordered = false; button.autoenablesItems = false
        button.target = context.coordinator; button.action = #selector(Coordinator.choose(_:))
        button.setAccessibilityLabel(title)
        return button
    }
    func updateNSView(_ button: SettingsChoiceButton, context: Context) {
        context.coordinator.parent = self
        if button.itemTitles != options.map(\.0) { button.removeAllItems(); button.addItems(withTitles: options.map(\.0)) }
        if let index = options.firstIndex(where: { $0.1 == value }) { button.selectItem(at: index) }
        button.isEnabled = enabled; button.profile = profile; button.accent = accent; button.needsDisplay = true
    }
    @MainActor final class Coordinator: NSObject {
        var parent: SettingsNativeChoice
        init(_ parent: SettingsNativeChoice) { self.parent = parent }
        @objc func choose(_ sender: NSPopUpButton) {
            guard parent.options.indices.contains(sender.indexOfSelectedItem) else { return }
            parent.value = parent.options[sender.indexOfSelectedItem].1
        }
    }
}

@MainActor private final class SettingsChoiceButton: NSPopUpButton {
    var profile = false
    var accent: NSColor?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: profile ? 14 : 7, yRadius: profile ? 14 : 7)
        (profile ? SettingsStyle.card.nsColor : SettingsStyle.control.nsColor).setFill(); shape.fill()
        SettingsStyle.controlLine.nsColor.setStroke(); shape.lineWidth = 1; shape.stroke()
        let text = selectedItem?.title ?? "Choose"
        let color = SettingsStyle.text.nsColor.withAlphaComponent(isEnabled ? 1 : 0.45)
        (text as NSString).draw(at: .init(x: profile ? 29 : 10, y: profile ? 6 : 5), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: color])
        if profile { (accent ?? SettingsStyle.accent.nsColor).setFill(); NSBezierPath(ovalIn: .init(x: 5, y: 5, width: 18, height: 18)).fill() }
        SettingsStyle.secondary.nsColor.setStroke()
        let arrow = NSBezierPath(); arrow.lineWidth = 1.2; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
        arrow.move(to: .init(x: bounds.width - 15, y: bounds.midY - 1)); arrow.line(to: .init(x: bounds.width - 12, y: bounds.midY + 2)); arrow.line(to: .init(x: bounds.width - 9, y: bounds.midY - 1)); arrow.stroke()
        if window?.firstResponder === self { (accent ?? SettingsStyle.accent.nsColor).withAlphaComponent(0.35).setStroke(); let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: profile ? 14 : 7, yRadius: profile ? 14 : 7); ring.lineWidth = 3; ring.stroke() }
    }
}

struct SettingsKeycaps: View {
    let shortcut: OpenCommands.KeyboardShortcut
    var conflict = false
    var body: some View {
        HStack(spacing: 3) { ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
            Text(key).font(.system(size: 11.5, weight: .medium)).padding(.horizontal, 5).frame(minWidth: 22, minHeight: 22)
                .background(Color(nsColor: SettingsStyle.key.nsColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: conflict ? SettingsStyle.sunEnd.nsColor : SettingsStyle.keyLine.nsColor), lineWidth: 1))
                .overlay(alignment: .bottom) { RoundedRectangle(cornerRadius: 1).fill(Color(nsColor: SettingsStyle.keyLine.nsColor)).frame(height: 1).padding(.horizontal, 3) }
        } }.accessibilityElement(children: .ignore).accessibilityLabel(shortcut.symbolDisplay)
    }
    private var keys: [String] {
        var result: [String] = []
        if shortcut.modifiers.contains(.control) { result.append("⌃") }
        if shortcut.modifiers.contains(.option) { result.append("⌥") }
        if shortcut.modifiers.contains(.shift) { result.append("⇧") }
        if shortcut.modifiers.contains(.command) { result.append("⌘") }
        let key = OpenCommands.KeyboardShortcut.displayKey(shortcut.key)
        result.append(key.count == 1 ? key.uppercased() : key); return result
    }
}

struct SettingsInlineMessage: View {
    let text: String
    var body: some View {
        if !text.isEmpty { HStack(alignment: .top, spacing: 7) { Image(systemName: "info.circle"); Text(text).fixedSize(horizontal: false, vertical: true) }
            .font(.system(size: 11.5)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: SettingsStyle.control.nsColor), in: RoundedRectangle(cornerRadius: 8)) }
    }
}

struct SettingsControlsKit: View {
    let root: SettingsViewModel
    @State private var on = true
    @State private var segment = "light"
    @FocusState private var titleFocused: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Controls").font(.system(size: 22, weight: .semibold)).focusable().focused($titleFocused).focusEffectDisabled()
            Text("Normal, hover, keyboard focus, and disabled states.").font(.system(size: 12.5)).foregroundStyle(Color(nsColor: SettingsStyle.secondary.nsColor))
            OpenSettingsCard {
                OpenSettingsRow(root: root, id: "kit/switch", title: "Switch", help: "Space colour marks the active state.", changed: true, reset: { on = false }) {
                    Toggle("Switch", isOn: $on).toggleStyle(OpenSettingsSwitchStyle(accent: Color(nsColor: SettingsStyle.accessibleAccent(root.settingsAccentSource, dark: scheme == .dark)), label: "Switch"))
                }
                OpenSettingsRow(root: root, id: "kit/segment", title: "Segmented control") { OpenSettingsSegments(title: "Appearance", selection: $segment, options: [("Light", "light"), ("Dark", "dark"), ("Match System", "automatic")]) }
                OpenSettingsRow(root: root, id: "kit/popup", title: "Pop-up") { OpenSettingsPop(title: "Appearance", value: $segment, options: [("Light", "light"), ("Dark", "dark")]) }
                OpenSettingsRow(root: root, id: "kit/button", title: "Push button") { Button("Choose…") {}.buttonStyle(OpenSettingsButtonStyle()) }
                OpenSettingsRow(root: root, id: "kit/disabled", title: "Unavailable", help: "This control is disabled.", last: true) { Button("Choose…") {}.buttonStyle(OpenSettingsButtonStyle()).disabled(true) }
            }
            HStack { SettingsKeycaps(shortcut: .cmd("t")); Spacer(); Button("Done") { root.showsControlsKit = false }.keyboardShortcut(.cancelAction).buttonStyle(OpenSettingsButtonStyle()) }
        }.padding(24).frame(width: 620).foregroundStyle(Color(nsColor: SettingsStyle.text.nsColor)).background(Color(nsColor: SettingsStyle.background.nsColor))
            .defaultFocus($titleFocused, true)
    }
}

/// A native tracking owner keeps the shipping hover state and own-window
/// automation on the same AppKit event path. It does not intercept clicks.
struct SettingsHoverRegion: NSViewRepresentable {
    @Binding var hovered: Bool
    func makeNSView(context: Context) -> Region { Region { hovered = $0 } }
    func updateNSView(_ view: Region, context: Context) { view.changed = { hovered = $0 } }
    @MainActor final class Region: NSView {
        var changed: (Bool) -> Void
        init(_ changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { changed(true) }
        override func mouseExited(with event: NSEvent) { changed(false) }
    }
}

/// Shared styling for the retained destructive and multi-step Settings sheets.
struct SettingsSheetStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(size: 13)).foregroundStyle(Color(nsColor: SettingsStyle.text.nsColor))
            .background(Color(nsColor: SettingsStyle.background.nsColor))
            .buttonStyle(OpenSettingsButtonStyle()).textFieldStyle(.roundedBorder)
    }
}
extension View {
    func settingsSheet() -> some View { modifier(SettingsSheetStyle()) }
}
