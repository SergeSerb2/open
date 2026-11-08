import AppKit
import Foundation
import OpenModel

/// Tab KVC resolves the live model or transient Little Open provider on every read.
/// Little Open specifiers use application → tab ID, without exposing a readable collection.
@MainActor
@objc(ScriptTab)
public final class ScriptTab: NSObject {
    public let tabID: ItemID
    let isLittleTab: Bool
    var tab: Tab? { ScriptHost.shared.model?.tab(id: tabID) }
    private var lastSpecifier: NSScriptObjectSpecifier?
    private var isCreationPlaceholder = false
    private var pendingTitle = ""
    private var pendingLocation = "unpinned"
    var pendingURL: String?
    var creationProperties: [String: Any] { pendingURL.map { ["URL": $0] } ?? [:] }
    init(tab: Tab) { tabID = tab.id; isLittleTab = false; super.init() }
    init(littleTabID: ItemID) { tabID = littleTabID; isLittleTab = true; super.init() }
    public override init() {
        tabID = ItemID()
        isLittleTab = false
        isCreationPlaceholder = true
        super.init()
    }

    @discardableResult
    func exists() -> Bool {
        if isLittleTab {
            if ScriptHost.shared.littleTab?.exists(tabID) == true { return true }
        } else {
            guard ScriptRead.model() != nil else { return false }
            if tab != nil { return true }
        }
        ScriptFailure.missing("tab", tabID.rawValue.uuidString)
        return false
    }
    var canGoBack: Bool { isLittleTab ? ScriptHost.shared.littleTab?.canGoBack(tabID) ?? false : tab?.live.canGoBack ?? false }
    var canGoForward: Bool { isLittleTab ? ScriptHost.shared.littleTab?.canGoForward(tabID) ?? false : tab?.live.canGoForward ?? false }
    func supportsModelContainment(_ operation: String) -> Bool {
        guard isLittleTab else { return true }
        ScriptFailure.report(ScriptError.makeSpaceUnsupported, "\(operation) is not supported for Little Open tabs; they have no Space or browser window container.")
        return false
    }
    @objc public dynamic var id: String { _ = exists(); return tabID.rawValue.uuidString }
    @objc public dynamic var title: String {
        get {
            if isCreationPlaceholder { return pendingTitle }
            guard exists() else { return "" }
            return isLittleTab ? ScriptHost.shared.littleTab?.title(tabID) ?? "" : tab?.displayTitle ?? ""
        }
        set {
            // Cocoa applies creation properties before insertion. The page owns the real title.
            if isCreationPlaceholder { pendingTitle = newValue; return }
            guard exists() else { return }
            ScriptFailure.report(ScriptError.invalidValue, "title is read-only.")
        }
    }
    @objc public dynamic var URL: String {
        get {
            if isCreationPlaceholder { return pendingURL ?? "about:blank" }
            guard exists() else { return "" }
            return (isLittleTab ? ScriptHost.shared.littleTab?.url(tabID) : tab?.url)?.absoluteString ?? ""
        }
        set {
            if isCreationPlaceholder { pendingURL = newValue; return }
            guard exists(), let url = ScriptCreation.parsedURL(newValue) else { return }
            guard let bridge = ScriptHost.shared.engineBridge else {
                ScriptFailure.report(ScriptError.engineUnavailable, "The page engine is not ready.")
                return
            }
            bridge.navigate(tabID: tabID, to: url)
        }
    }
    @objc public dynamic var loading: Bool {
        guard exists() else { return false }
        return isLittleTab ? ScriptHost.shared.littleTab?.loading(tabID) ?? false : tab?.live.isLoading ?? false
    }
    @objc public dynamic var location: String {
        get {
            if isCreationPlaceholder { return pendingLocation }
            guard exists(), supportsModelContainment("location"), let model = ScriptHost.shared.model else { return "" }
            switch ScriptRead.section(of: tabID, model: model) {
            case .favorites?: return "topApp"
            case .spacePinned?: return "pinned"
            default: return "unpinned"
            }
        }
        set {
            if isCreationPlaceholder { pendingLocation = newValue; return }
            guard exists(), supportsModelContainment("location"), let model = ScriptHost.shared.model else { return }
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
        if isLittleTab {
            guard let cls = NSScriptClassDescription(for: NSApplication.self) else { return lastSpecifier }
            let specifier = NSUniqueIDSpecifier(containerClassDescription: cls, containerSpecifier: nil,
                key: "appleScriptTabs", uniqueID: tabID.rawValue.uuidString)
            lastSpecifier = specifier
            return specifier
        }
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
