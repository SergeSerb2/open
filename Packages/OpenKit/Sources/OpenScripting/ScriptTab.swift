import AppKit
import Foundation
import OpenModel

/// Tab KVC reads always resolve the current model. Specifiers prefer Space → tab ID;
/// favorites use window → tab ID. A retained closed wrapper keeps its last specifier.
@MainActor
@objc(ScriptTab)
public final class ScriptTab: NSObject {
    public let tabID: ItemID
    var tab: Tab? { ScriptHost.shared.model?.tab(id: tabID) }
    private var lastSpecifier: NSScriptObjectSpecifier?
    private var isCreationPlaceholder = false
    private var pendingTitle = ""
    private var pendingLocation = "unpinned"
    var pendingURL: String?
    var creationProperties: [String: Any] { pendingURL.map { ["URL": $0] } ?? [:] }
    init(tab: Tab) { tabID = tab.id; super.init() }
    public override init() {
        tabID = ItemID()
        isCreationPlaceholder = true
        super.init()
    }

    @discardableResult
    func liveTab() -> Tab? {
        guard ScriptRead.model() != nil else { return nil }
        guard let tab else { ScriptFailure.missing("tab", tabID.rawValue.uuidString); return nil }
        return tab
    }
    @objc public dynamic var id: String { _ = liveTab(); return tabID.rawValue.uuidString }
    @objc public dynamic var title: String {
        get { isCreationPlaceholder ? pendingTitle : liveTab()?.displayTitle ?? "" }
        set {
            // Cocoa applies creation properties before insertion. The page owns the real title.
            if isCreationPlaceholder { pendingTitle = newValue; return }
            ScriptFailure.report(ScriptError.invalidValue, "title is read-only.")
        }
    }
    @objc public dynamic var URL: String {
        get {
            if isCreationPlaceholder { return pendingURL ?? "about:blank" }
            return liveTab()?.url.absoluteString ?? ""
        }
        set {
            if isCreationPlaceholder { pendingURL = newValue; return }
            guard liveTab() != nil, let url = ScriptCreation.parsedURL(newValue) else { return }
            guard let bridge = ScriptHost.shared.engineBridge else {
                ScriptFailure.report(ScriptError.engineUnavailable, "The page engine is not ready.")
                return
            }
            bridge.navigate(tabID: tabID, to: url)
        }
    }
    @objc public dynamic var loading: Bool { liveTab()?.live.isLoading ?? false }
    @objc public dynamic var location: String {
        get {
            if isCreationPlaceholder { return pendingLocation }
            guard liveTab() != nil, let model = ScriptHost.shared.model else { return "unpinned" }
            switch ScriptRead.section(of: tabID, model: model) {
            case .favorites?: return "topApp"
            case .spacePinned?: return "pinned"
            default: return "unpinned"
            }
        }
        set {
            if isCreationPlaceholder { pendingLocation = newValue; return }
            guard liveTab() != nil, let model = ScriptHost.shared.model else { return }
            guard ["topApp", "pinned", "unpinned"].contains(newValue) else {
                ScriptFailure.report(ScriptError.invalidValue, "\"\(newValue)\" is not a location. Use topApp, pinned, or unpinned.")
                return
            }
            let current = location
            guard newValue != current else { return }
            if newValue == "topApp" {
                guard case .splitPane? = model.parent(of: tabID) else {
                    guard let spaceID = ScriptRead.spaceID(of: tabID, model: model),
                          let space = model.space(id: spaceID),
                          model.addFavorite(tabID: tabID, to: space.profileID, at: nil) else {
                        ScriptFailure.report(ScriptError.invalidMove, "The tab cannot move to favorites.")
                        return
                    }
                    return
                }
                ScriptFailure.report(ScriptError.invalidMove, "A split pane cannot move to favorites. Separate it first.")
                return
            }
            if case .favorites(let profileID)? = model.parent(of: tabID) {
                let focused = ScriptRead.preferredWindow().flatMap { model.space(id: $0.focusedSpaceID) }
                let space = focused?.profileID == profileID ? focused : model.spaces.first { $0.profileID == profileID }
                guard let space, model.removeFavorite(tabID: tabID, into: space.id) else {
                    ScriptFailure.report(ScriptError.noWindow, "There is no browser window.")
                    return
                }
                if newValue == "pinned" { model.pinTab(id: tabID) }
                else {
                    // removeFavorite inserts at the start; §5.5 requires end-of-destination.
                    model.moveNode(id: tabID, to: .spaceToday(space.id), at: nil)
                }
            } else if newValue == "pinned" { model.pinTab(id: tabID) }
            else { model.unpinTab(id: tabID) }
        }
    }
    // Foundation declares this override nonisolated. Apple-event evaluation is main-thread only.
    public override var objectSpecifier: NSScriptObjectSpecifier? {
        guard ScriptThread.isMainThread else { return nil }
        // Keep the non-Sendable Foundation value within this synchronous call.
        nonisolated(unsafe) var result: NSScriptObjectSpecifier?
        MainActor.assumeIsolated { result = makeObjectSpecifier() }
        return result
    }

    private func makeObjectSpecifier() -> NSScriptObjectSpecifier? {
        guard let model = ScriptHost.shared.model, model.tab(id: tabID) != nil else { return lastSpecifier }
        let container: NSScriptObjectSpecifier?
        let cls: NSScriptClassDescription?
        if let spaceID = ScriptRead.spaceID(of: tabID, model: model), let space = model.space(id: spaceID) {
            container = ScriptHost.shared.spaceWrapper(for: space).objectSpecifier
            cls = NSScriptClassDescription(for: ScriptSpace.self)
        } else {
            container = ScriptRead.preferredWindow().flatMap { ScriptHost.shared.windowWrapper(for: $0).objectSpecifier }
            cls = NSScriptClassDescription(for: ScriptWindow.self)
        }
        guard let cls, let container else { return lastSpecifier }
        let specifier = NSUniqueIDSpecifier(containerClassDescription: cls, containerSpecifier: container,
                                            key: "appleScriptTabs", uniqueID: tabID.rawValue.uuidString)
        lastSpecifier = specifier
        return specifier
    }
}
