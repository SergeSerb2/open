import AppKit
import OpenWeb

/// Per-window transient state only. Chromium remains the pin/order store.
@MainActor public final class ExtensionsUIContext {
    public private(set) var actions: [ExtensionActionInfo] = []
    public var popupOpenID: String?
    public var forcedVisibility: ForcedVisibility = [] { didSet { if forcedVisibility != oldValue { notify(.visibility) } } }
    public enum Change { case list, action(ExtensionActionInfo), visibility }
    private var observers: [UUID: (Change) -> Void] = [:]
    @discardableResult public func observe(_ body: @escaping (Change) -> Void) -> UUID {
        let id = UUID(); observers[id] = body; return id
    }
    public func removeObserver(_ id: UUID) { observers[id] = nil }
    private func notify(_ change: Change) { for body in Array(observers.values) { body(change) } }
    public func refreshVisibility() { notify(.visibility) }
    public struct ForcedVisibility: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let popup = Self(rawValue: 1)
        public static let contextMenu = Self(rawValue: 2)
        public static let overflowMenu = Self(rawValue: 4)
        public static let drag = Self(rawValue: 8)
    }
    /// Callbacks may replace or close views synchronously. Dispatch no further work
    /// through a view after emitting its intent. The App owns lifetime decisions.
    public var run: ((String, ExtensionRunSource, NSView) -> Void)?
    public var closePopup: (() -> Void)?
    public var contextMenu: ((String, NSView, NSEvent?) -> Void)?
    public var movePinned: ((String, Int) -> Void)?
    public var togglePin: ((String) -> Void)?
    public var overflow: (([ExtensionActionInfo], NSView) -> Void)?
    public var addExtension: (() -> Void)?
    public var manageExtensions: (() -> Void)?
    public init() {}
    /// Refuse oversized/ambiguous snapshots before building any views. 512 views max;
    /// text <=4096 UTF-8 bytes, keycaps <=8×32; no decoded unbounded object graph.
    public static func accepts(_ actions: [ExtensionActionInfo]) -> Bool {
        guard actions.count <= 512, Set(actions.map(\.id)).count == actions.count else { return false }
        return actions.allSatisfy {
            !$0.id.isEmpty && [$0.id, $0.name, $0.accessibleName, $0.tooltip, $0.badgeText ?? ""].allSatisfy { $0.utf8.count <= 4096 }
                && $0.shortcutKeys.count <= 8 && $0.shortcutKeys.allSatisfy { $0.utf8.count <= 32 }
        }
    }
    @discardableResult public func setActions(_ value: [ExtensionActionInfo]) -> Bool {
        guard Self.accepts(value) else { return false }
        if actions != value { actions = value; pageIdentityRevision += 1; notify(.list) }; return true
    }
    @discardableResult public func updateAction(_ value: ExtensionActionInfo) -> Bool {
        guard Self.accepts([value]), let i = actions.firstIndex(where: { $0.id == value.id }) else { return false }
        guard actions[i] != value else { return true }
        // An icon can arrive after the list (or change with chrome.action.setIcon): extension pages re-read it.
        // Badge and title ticks leave the revision alone, so they cost those pages nothing.
        if actions[i].name != value.name || actions[i].menuIcon != value.menuIcon { pageIdentityRevision += 1 }
        actions[i] = value; notify(.action(value)); return true
    }
    /// Changes when the list or an extension's name or menu icon changes (UX round 1 X3, review r1 #2).
    public private(set) var pageIdentityRevision = 0
    /// The extension a `chrome-extension://<id>/…` page belongs to. Hosts compare in lower case.
    public static func extensionID(ofPage url: URL?) -> String? {
        guard url?.scheme?.lowercased() == "chrome-extension", let id = url?.host()?.lowercased(), !id.isEmpty else { return nil }
        return id
    }
    /// An extension's own page names the extension, not its 32-letter ID (UX round 1 X3).
    public func extensionName(ofPage url: URL?) -> String? {
        guard let id = Self.extensionID(ofPage: url) else { return nil }
        return actions.first { $0.id == id }.map(\.name).flatMap { $0.isEmpty ? nil : $0 }
    }
    public func extensionIcon(ofPage url: URL?) -> ExtensionImage? {
        guard let id = Self.extensionID(ofPage: url) else { return nil }
        return actions.first { $0.id == id }?.menuIcon
    }
    public static func ordered(_ actions: [ExtensionActionInfo]) -> [ExtensionActionInfo] {
        actions.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.isPinned { return ($0.pinnedIndex ?? Int.max, $0.id) < ($1.pinnedIndex ?? Int.max, $1.id) }
            let result = $0.name.localizedStandardCompare($1.name)
            return result == .orderedSame ? $0.id < $1.id : result == .orderedAscending
        }
    }
}
