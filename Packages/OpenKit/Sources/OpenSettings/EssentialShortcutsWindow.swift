import AppKit
import SwiftUI
import OpenCommands
import OpenDesign

/// Help ▸ Essential Keyboard Shortcuts (commandbar-completion §4.5; Arc `KeyboardShortcutsEDUWindow`,
/// CC-27, CC-28). Five shortcuts in Arc's order. The window follows Arc's decoded setup; the content
/// is Open's design (no capture exists).
public enum EssentialShortcuts {
    public struct Item: Sendable, Hashable, Identifiable {
        public var title: String
        public var detail: String
        public var commandID: String
        public var id: String { commandID }
    }

    /// Arc's five items and order (CC-28). "Arc" becomes "Open"; Copy Page URL drops "without trackers"
    /// because Open's `copy-url` copies the plain URL (CC-31, plan §8 Q8).
    public static let items: [Item] = [
        Item(title: "Open a New Tab", detail: "Open the Command Bar to create a new tab", commandID: "new-tab"),
        Item(title: "Switch to a Recent Tab", detail: "Hold this to quickly switch between recent tabs", commandID: "tab-switcher-forward"),
        Item(title: "Copy Page URL", detail: "Copy the current tab's URL without trackers", commandID: "copy-url"),
        Item(title: "Add Split View", detail: "View multiple websites side-by-side", commandID: "add-split-view"),
        Item(title: "Open Little Open", detail: "Use a smaller browser window for quick searches", commandID: "new-little-open-window"),
    ]

    public static let windowTitle = "Essential Keyboard Shortcuts"

    /// One keycap per key of the command's first effective shortcut ("⌃", "Tab"); empty when cleared.
    public static func keycaps(for commandID: String, in store: KeyBindingStore) -> [String] {
        guard let command = CommandRegistry.byID[commandID], let shortcut = store.effectiveShortcuts(for: command).first else { return [] }
        var keys: [String] = []
        if shortcut.modifiers.contains(.control) { keys.append("⌃") }
        if shortcut.modifiers.contains(.option) { keys.append("⌥") }
        if shortcut.modifiers.contains(.shift) { keys.append("⇧") }
        if shortcut.modifiers.contains(.command) { keys.append("⌘") }
        let key = OpenCommands.KeyboardShortcut.displayKey(shortcut.key)
        keys.append(key.count == 1 ? key.uppercased() : key) // "T", "=", "Tab"
        return keys
    }
}

/// Tokens of the window content (Open design, plan §4.5.2).
enum EssentialShortcutsTokens {
    static let width: CGFloat = 440
    static let insetTop: CGFloat = 40, insetSide: CGFloat = 24, insetBottom: CGFloat = 24
    static let headerToList: CGFloat = 16
    static let rowHeight: CGFloat = 56
    static let keycapHeight: CGFloat = 24, keycapRadius: CGFloat = 5, keycapPadding: CGFloat = 4, keycapGap: CGFloat = 4
    /// #FDFDFE light / #161616 dark, the banner background of the command bar asset catalog (plan §4.5.2).
    static let background = DesignColor(light: RGBA(hex: 0xFDFDFE), dark: RGBA(hex: 0x161616))
    static let detail = DesignColor(light: .black(0.55), dark: .white(0.55))
}

/// The window content. Observes nothing: the controller replaces it when the bindings change.
public struct EssentialShortcutsView: View {
    let keys: [String: [String]]

    public init(store: KeyBindingStore) {
        var keys: [String: [String]] = [:]
        for item in EssentialShortcuts.items { keys[item.commandID] = EssentialShortcuts.keycaps(for: item.commandID, in: store) }
        self.keys = keys
    }

    public var body: some View {
        let t = EssentialShortcutsTokens.self
        VStack(alignment: .leading, spacing: 0) {
            Text(EssentialShortcuts.windowTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(nsColor: CommandBarColors.textPrimary.nsColor))
                .padding(.bottom, t.headerToList)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(EssentialShortcuts.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Rectangle().fill(Color(nsColor: CommandBarColors.hairlineDivider.nsColor)).frame(height: 1) }
                row(item)
            }
        }
        .padding(.top, t.insetTop).padding(.horizontal, t.insetSide).padding(.bottom, t.insetBottom)
        .frame(width: t.width, alignment: .leading)
        .background(Color(nsColor: t.background.nsColor))
    }

    private func row(_ item: EssentialShortcuts.Item) -> some View {
        let t = EssentialShortcutsTokens.self
        let caps = keys[item.commandID] ?? []
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(nsColor: CommandBarColors.textPrimary.nsColor))
                Text(item.detail).font(.system(size: 12)).foregroundStyle(Color(nsColor: t.detail.nsColor))
            }
            Spacer(minLength: 8)
            HStack(spacing: t.keycapGap) {
                if caps.isEmpty { keycap("—") } else { ForEach(Array(caps.enumerated()), id: \.offset) { keycap($0.element) } }
            }
        }
        .frame(height: t.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityValue(caps.isEmpty ? "No shortcut" : caps.joined(separator: " "))
    }

    private func keycap(_ key: String) -> some View {
        let t = EssentialShortcutsTokens.self
        return Text(key)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color(nsColor: CommandBarColors.accessoryForeground.nsColor))
            .padding(.horizontal, t.keycapPadding)
            .frame(minWidth: t.keycapHeight, minHeight: t.keycapHeight, maxHeight: t.keycapHeight)
            .background(Color(nsColor: CommandBarColors.accessoryBackground.nsColor), in: RoundedRectangle(cornerRadius: t.keycapRadius))
    }
}

/// The window (CC-27): titled, closable, miniaturizable, full-size content, not resizable; hidden title,
/// transparent title bar, not opaque, movable by its background, floating, full-screen auxiliary.
/// Esc and Cmd+W close it. It never becomes a browser window.
@MainActor
final class EssentialShortcutsPanel: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" { close(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// One shared window per app: created on first open, then reused (plan §4.5.1).
@MainActor
public final class EssentialShortcutsWindowController {
    public static let shared = EssentialShortcutsWindowController()
    public private(set) var window: NSWindow?
    private var hosting: NSHostingView<EssentialShortcutsView>?
    private var store = KeyBindingStore.empty

    public init() {}

    /// Shows the window: centered on the screen of `near` the first time, then where it was.
    public func show(near anchor: NSWindow?, store: KeyBindingStore) {
        self.store = store
        if let window {
            update(store: store)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = NSHostingView(rootView: EssentialShortcutsView(store: store))
        let size = view.fittingSize
        let w = EssentialShortcutsPanel(contentRect: CGRect(origin: .zero, size: size),
                                        styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = EssentialShortcuts.windowTitle
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isOpaque = false
        w.isMovableByWindowBackground = true
        w.level = .floating
        w.collectionBehavior = [.fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.contentView = view
        hosting = view
        if let screen = anchor?.screen ?? NSScreen.main {
            let f = screen.visibleFrame
            w.setFrameOrigin(CGPoint(x: (f.midX - size.width / 2).rounded(), y: (f.midY - size.height / 2).rounded()))
        } else {
            w.center()
        }
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    /// New key bindings: the keycaps follow at once (a cleared binding shows "—").
    public func update(store: KeyBindingStore) {
        self.store = store
        hosting?.rootView = EssentialShortcutsView(store: store)
    }

    public var isShown: Bool { window?.isVisible ?? false }
}
