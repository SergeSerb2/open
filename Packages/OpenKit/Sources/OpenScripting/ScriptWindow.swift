import AppKit
import Foundation
import OpenModel

/// Window KVC reads use the current model and AppKit chrome. Its specifier is application → window ID.
@MainActor
@objc(ScriptWindow)
public final class ScriptWindow: NSObject {
    public let stateID: WindowID
    var state: BrowserWindowState? { ScriptHost.shared.model?.windows.first { $0.id == stateID } }
    var nsWindow: NSWindow? { ScriptHost.shared.windowForState?(stateID) }
    init(state: BrowserWindowState) { stateID = state.id; super.init() }

    @discardableResult
    func liveState() -> BrowserWindowState? {
        guard ScriptRead.model() != nil else { return nil }
        guard let state else { ScriptFailure.missing("window", stateID.rawValue.uuidString); return nil }
        return state
    }

    @objc public dynamic var id: String { _ = liveState(); return stateID.rawValue.uuidString }
    @objc public dynamic var title: String { guard liveState() != nil else { return "Open" }; return nsWindow?.title ?? "Open" }
    @objc public dynamic var orderedIndex: Int {
        get {
            guard liveState() != nil else { return 0 }
            return NSApplication.shared.appleScriptWindows.firstIndex { $0.stateID == stateID }.map { $0 + 1 } ?? 0
        }
        set {
            guard liveState() != nil else { return }
            guard newValue == 1 else {
                ScriptFailure.report(ScriptError.useMakeAndClose, "Only set index to 1 (bring to front) is supported.")
                return
            }
            nsWindow?.makeKeyAndOrderFront(nil)
        }
    }
    @objc public dynamic var hasCloseBox: Bool { guard liveState() != nil else { return false }; return nsWindow?.styleMask.contains(.closable) ?? true }
    @objc public dynamic var isMiniaturizable: Bool { guard liveState() != nil else { return false }; return nsWindow?.styleMask.contains(.miniaturizable) ?? true }
    @objc public dynamic var isMiniaturized: Bool {
        get { guard liveState() != nil else { return false }; return nsWindow?.isMiniaturized ?? false }
        set { guard liveState() != nil else { return }; if newValue { nsWindow?.miniaturize(nil) } else { nsWindow?.deminiaturize(nil) } }
    }
    @objc public dynamic var isResizable: Bool { guard liveState() != nil else { return false }; return nsWindow?.styleMask.contains(.resizable) ?? true }
    @objc public dynamic var isVisible: Bool {
        get { guard liveState() != nil else { return false }; return nsWindow?.isVisible ?? false }
        set { guard liveState() != nil else { return }; if newValue { nsWindow?.orderFront(nil) } else { nsWindow?.orderOut(nil) } }
    }
    @objc public dynamic var isZoomable: Bool { guard liveState() != nil else { return false }; return nsWindow?.styleMask.contains(.resizable) ?? true }
    @objc public dynamic var isZoomed: Bool {
        get { guard liveState() != nil else { return false }; return nsWindow?.isZoomed ?? false }
        set { guard liveState() != nil, let window = nsWindow else { return }; if newValue != window.isZoomed { window.zoom(nil) } }
    }
    @objc public dynamic var isIncognito: Bool {
        get { mode == "incognito" }
        set { guard liveState() != nil else { return }; rejectModeChange() }
    }
    @objc public dynamic var mode: String {
        get { guard liveState() != nil else { return "normal" }; return ScriptHost.shared.windowModes[stateID] ?? "normal" }
        set { guard liveState() != nil else { return }; rejectModeChange() }
    }
    private func rejectModeChange() {
        ScriptFailure.report(ScriptError.modeSetOnce, "mode can be set only once during creation of the window.")
    }

    @objc public dynamic var activeSpace: ScriptSpace? {
        guard let state = liveState(), let space = ScriptHost.shared.model?.space(id: state.focusedSpaceID) else { return nil }
        return ScriptHost.shared.spaceWrapper(for: space)
    }
    @objc public dynamic var activeTab: ScriptTab? {
        guard let state = liveState(), let model = ScriptHost.shared.model,
              let selected = state.selectedNodeBySpace[state.focusedSpaceID], let node = model.node(id: selected),
              let tab = ScriptRead.selectedTab(in: node) else { return nil }
        return ScriptHost.shared.tabWrapper(for: tab)
    }
    @objc public dynamic var appleScriptSpaces: [ScriptSpace] {
        guard liveState() != nil, let model = ScriptHost.shared.model else { return [] }
        return model.spaces.map { ScriptHost.shared.spaceWrapper(for: $0) }
    }
    @objc public dynamic var appleScriptTabs: [ScriptTab] {
        guard let state = liveState(), let model = ScriptHost.shared.model else { return [] }
        let spaceTabs = model.spaces.flatMap { ScriptRead.flatten($0.pinned) + ScriptRead.flatten($0.today) }
        let space = model.space(id: state.focusedSpaceID) ?? model.spaces.first
        guard let space else { return [] }
        let favorites = model.profile(id: space.profileID)?.favorites ?? []
        return (spaceTabs + favorites).map { ScriptHost.shared.tabWrapper(for: $0) }
    }
    @objc public func countOfAppleScriptTabs() -> Int { appleScriptTabs.count }
    @objc public func objectInAppleScriptTabsAtIndex(_ index: Int) -> ScriptTab? { ScriptRead.at(index, in: appleScriptTabs, noun: "tab") }
    @objc public func valueInAppleScriptTabsWithUniqueID(_ id: String) -> ScriptTab? {
        ScriptRead.byID(id, in: appleScriptTabs, noun: "tab", uuid: { $0.tabID.rawValue })
    }
    @objc public func countOfAppleScriptSpaces() -> Int { appleScriptSpaces.count }
    @objc public func objectInAppleScriptSpacesAtIndex(_ index: Int) -> ScriptSpace? { ScriptRead.at(index, in: appleScriptSpaces, noun: "space") }
    @objc public func valueInAppleScriptSpacesWithUniqueID(_ id: String) -> ScriptSpace? {
        ScriptRead.byID(id, in: appleScriptSpaces, noun: "space", uuid: { $0.spaceID.rawValue })
    }
    @objc(insertInAppleScriptTabs:atIndex:) public func insertInAppleScriptTabs(_ tab: ScriptTab, at index: Int) {
        guard liveState() != nil else { return }
        _ = ScriptCreation.makeTab(inWindow: stateID, atIndex: index, properties: tab.creationProperties)
    }
    @objc(removeFromAppleScriptTabsAtIndex:) public func removeFromAppleScriptTabs(at index: Int) {
        guard let tab = objectInAppleScriptTabsAtIndex(index), let model = ScriptHost.shared.model else { return }
        _ = tab.objectSpecifier
        model.closeTab(id: tab.tabID)
        ScriptHost.shared.tabWrappers[tab.tabID] = nil
    }
    public override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let cls = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: cls, containerSpecifier: nil,
                                   key: "appleScriptWindows", uniqueID: stateID.rawValue.uuidString)
    }
}
