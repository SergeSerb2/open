import AppKit
import Foundation
import OpenModel

/// H1 supplies the current live model, window mappings, creation hooks, and engine bridge.
/// Pull-based wrapper caches retain identity; the App observer purges external removals.
@MainActor
public final class ScriptHost {
    public static let shared = ScriptHost()
    private init() { ScriptGetCommand.install() }

    public var modelProvider: (() -> BrowserModel?)?
    public var engineBridge: (any ScriptEngineBridge)?
    public var windowStateID: ((NSWindow) -> WindowID?)?
    public var windowForState: ((WindowID) -> NSWindow?)?
    public var makeLittleTab: ((URL?) -> ItemID?)?
    public var makeWindow: ((Bool) -> WindowID?)?
    public var model: BrowserModel? { modelProvider?() }
    public var lastSetterError: (number: Int, message: String)?
    /// `execute` runs only while this answers true. The App's View ▸ Developer
    /// item stores the same defaults key (plans/page-platform.md §4.10.2).
    public var allowsJavaScriptFromAppleEvents: () -> Bool = {
        UserDefaults.standard.bool(forKey: ScriptHost.allowJavaScriptFromAppleEventsKey)
    }
    public nonisolated static let allowJavaScriptFromAppleEventsKey = "open.developer.allowJavaScriptFromAppleEvents"
    public nonisolated static let javaScriptFromAppleEventsOffMessage =
        "JavaScript from Apple Events is off. Turn it on in View ▸ Developer."
    public var windowModes: [WindowID: String] = [:]

    // Strong caches preserve identity. The App model observer purges external removals.
    var windowWrappers: [WindowID: ScriptWindow] = [:]
    var spaceWrappers: [SpaceID: ScriptSpace] = [:]
    var tabWrappers: [ItemID: ScriptTab] = [:]

    public func windowWrapper(for state: BrowserWindowState) -> ScriptWindow {
        if let wrapper = windowWrappers[state.id] { return wrapper }
        let wrapper = ScriptWindow(state: state)
        windowWrappers[state.id] = wrapper
        return wrapper
    }

    public func spaceWrapper(for space: Space) -> ScriptSpace {
        if let wrapper = spaceWrappers[space.id] { return wrapper }
        let wrapper = ScriptSpace(space: space)
        spaceWrappers[space.id] = wrapper
        return wrapper
    }

    public func tabWrapper(for tab: Tab) -> ScriptTab {
        if let wrapper = tabWrappers[tab.id] { return wrapper }
        let wrapper = ScriptTab(tab: tab)
        tabWrappers[tab.id] = wrapper
        return wrapper
    }

    /// Called by the App-owned observer for changes made outside scripting.
    public func purgeRemovedWrappers() {
        guard let model else {
            windowWrappers.removeAll()
            spaceWrappers.removeAll()
            tabWrappers.removeAll()
            windowModes.removeAll()
            return
        }
        windowWrappers = windowWrappers.filter { id, _ in model.windows.contains { $0.id == id } }
        spaceWrappers = spaceWrappers.filter { model.space(id: $0.key) != nil }
        tabWrappers = tabWrappers.filter { model.tab(id: $0.key) != nil }
        windowModes = windowModes.filter { id, _ in model.windows.contains { $0.id == id } }
    }
}

@MainActor
enum ScriptRead {
    static func model() -> BrowserModel? {
        guard let model = ScriptHost.shared.model else {
            ScriptFailure.report(ScriptError.notReady, "Open is not ready.")
            return nil
        }
        return model
    }

    static func flatten(_ nodes: [SidebarNode]) -> [Tab] {
        nodes.flatMap { node in
            switch node {
            case .tab(let tab): return [tab]
            case .folder(let folder): return flatten(folder.children)
            case .split(let split): return split.panes
            }
        }
    }

    static func selectedTab(in node: SidebarNode) -> Tab? {
        switch node {
        case .tab(let tab): return tab
        case .folder(let folder): return flatten(folder.children).first
        case .split(let split): return split.panes.first { $0.id == split.focusedPaneID } ?? split.panes.first
        }
    }

    static func section(of id: ItemID, model: BrowserModel) -> NodeParent? {
        var parent = model.parent(of: id)
        while let current = parent {
            switch current {
            case .spacePinned, .spaceToday, .favorites: return current
            case .folder(let id), .splitPane(let id): parent = model.parent(of: id)
            }
        }
        return nil
    }

    static func spaceID(of id: ItemID, model: BrowserModel) -> SpaceID? {
        switch section(of: id, model: model) {
        case .spacePinned(let id)?, .spaceToday(let id)?: return id
        default: return nil
        }
    }

    static func preferredWindow() -> BrowserWindowState? {
        let host = ScriptHost.shared
        guard let model = host.model else { return nil }
        if let keyWindow = NSApplication.shared.keyWindow, let id = host.windowStateID?(keyWindow),
           let state = model.windows.first(where: { $0.id == id }) { return state }
        return NSApplication.shared.appleScriptWindows.first?.state
    }

    static func at<T>(_ index: Int, in list: [T], noun: String) -> T? {
        guard list.indices.contains(index) else {
            ScriptFailure.missing(noun, String(index + 1))
            return nil
        }
        return list[index]
    }

    static func byID<T>(_ text: String, in list: [T], noun: String, uuid: (T) -> UUID) -> T? {
        guard let id = UUID(uuidString: text), let value = list.first(where: { uuid($0) == id }) else {
            ScriptFailure.missing(noun, text)
            return nil
        }
        return value
    }
}
