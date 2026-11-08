import AppKit
import Foundation
import OpenModel

/// Space id/title and appleScriptTabs flatten Pinned then Today. Tab IDs follow location
/// moves; enumeration stays scoped. Specifiers use a key/first window or retain the last valid container.
@MainActor
@objc(ScriptSpace)
public final class ScriptSpace: NSObject {
    public let spaceID: SpaceID
    var space: Space? { ScriptHost.shared.model?.space(id: spaceID) }
    private var lastSpecifier: NSScriptObjectSpecifier?
    private var isCreationPlaceholder = false
    private var pendingTitle = ""
    init(space: Space) { spaceID = space.id; super.init() }
    public override init() {
        spaceID = SpaceID()
        isCreationPlaceholder = true
        super.init()
    }

    @discardableResult
    func liveSpace() -> Space? {
        guard ScriptRead.model() != nil else { return nil }
        guard let space else { ScriptFailure.missing("space", spaceID.rawValue.uuidString); return nil }
        return space
    }
    @objc public dynamic var id: String { _ = liveSpace(); return spaceID.rawValue.uuidString }
    @objc public dynamic var title: String {
        get { isCreationPlaceholder ? pendingTitle : liveSpace()?.title ?? "" }
        set {
            if isCreationPlaceholder { pendingTitle = newValue; return }
            ScriptFailure.report(ScriptError.invalidValue, "title is read-only.")
        }
    }
    @objc public dynamic var appleScriptTabs: [ScriptTab] {
        guard let space = liveSpace() else { return [] }
        return (ScriptRead.flatten(space.pinned) + ScriptRead.flatten(space.today)).map { ScriptHost.shared.tabWrapper(for: $0) }
    }
    @objc public func countOfAppleScriptTabs() -> Int { appleScriptTabs.count }
    @objc public func objectInAppleScriptTabsAtIndex(_ index: Int) -> ScriptTab? { ScriptRead.at(index, in: appleScriptTabs, noun: "tab") }
    @objc public func valueInAppleScriptTabsWithUniqueID(_ id: String) -> ScriptTab? {
        guard !ScriptRead.rejectsLittleTabContainment(id) else { return nil }
        // A held tab specifier keeps its original Space container across a location
        // move (A12). Resolve its stable ID from the live model; enumeration stays
        // scoped to this Space. Never return a cached wrapper for a closed tab.
        if liveSpace() != nil, let uuid = UUID(uuidString: id),
           let tab = ScriptHost.shared.model?.tab(id: ItemID(rawValue: uuid)) {
            return ScriptHost.shared.tabWrapper(for: tab)
        }
        return ScriptRead.byID(id, in: appleScriptTabs, noun: "tab", uuid: { $0.tabID.rawValue })
    }
    @objc(insertInAppleScriptTabs:atIndex:) public func insertInAppleScriptTabs(_ tab: ScriptTab, at index: Int) {
        guard liveSpace() != nil else { return }
        _ = ScriptCreation.makeTab(inSpace: spaceID, atIndex: index, properties: tab.creationProperties)
    }
    @objc(removeFromAppleScriptTabsAtIndex:) public func removeFromAppleScriptTabs(at index: Int) {
        guard let tab = objectInAppleScriptTabsAtIndex(index), let model = ScriptHost.shared.model else { return }
        _ = tab.objectSpecifier
        model.closeTab(id: tab.tabID)
        ScriptHost.shared.tabWrappers[tab.tabID] = nil
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
        guard !isCreationPlaceholder else { return nil }
        if space == nil, let lastSpecifier { return lastSpecifier }
        guard let cls = NSScriptClassDescription(for: ScriptWindow.self) else { return lastSpecifier }
        let specifier: NSScriptObjectSpecifier
        if let window = ScriptRead.preferredWindow(), let container = ScriptHost.shared.windowWrapper(for: window).objectSpecifier {
            specifier = NSUniqueIDSpecifier(containerClassDescription: cls, containerSpecifier: container,
                                            key: "appleScriptSpaces", uniqueID: spaceID.rawValue.uuidString)
        } else {
            // Application has no spaces key. Never manufacture an unresolvable container.
            return lastSpecifier
        }
        lastSpecifier = specifier
        return specifier
    }
}
