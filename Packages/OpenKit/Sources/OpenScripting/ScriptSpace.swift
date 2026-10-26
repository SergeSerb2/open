import AppKit
import Foundation
import OpenModel

/// Space KVC tabs flatten Pinned then Today. Specifiers use the key/first window as their container;
/// without a window they fall back to a name specifier, as required by plan §5.4.
@MainActor
@objc(ScriptSpace)
public final class ScriptSpace: NSObject {
    public let spaceID: SpaceID
    var space: Space? { ScriptHost.shared.model?.space(id: spaceID) }
    private var lastSpecifier: NSScriptObjectSpecifier?
    private let initialTitle: String
    init(space: Space) { spaceID = space.id; initialTitle = space.title; super.init() }

    @discardableResult
    func liveSpace() -> Space? {
        guard ScriptRead.model() != nil else { return nil }
        guard let space else { ScriptFailure.missing("space", spaceID.rawValue.uuidString); return nil }
        return space
    }
    @objc public dynamic var id: String { _ = liveSpace(); return spaceID.rawValue.uuidString }
    @objc public dynamic var title: String { liveSpace()?.title ?? "" }
    @objc public dynamic var appleScriptTabs: [ScriptTab] {
        guard let space = liveSpace() else { return [] }
        return (ScriptRead.flatten(space.pinned) + ScriptRead.flatten(space.today)).map { ScriptHost.shared.tabWrapper(for: $0) }
    }
    @objc public func countOfAppleScriptTabs() -> Int { appleScriptTabs.count }
    @objc public func objectInAppleScriptTabsAtIndex(_ index: Int) -> ScriptTab? { ScriptRead.at(index, in: appleScriptTabs, noun: "tab") }
    @objc public func valueInAppleScriptTabsWithUniqueID(_ id: String) -> ScriptTab? {
        ScriptRead.byID(id, in: appleScriptTabs, noun: "tab", uuid: { $0.tabID.rawValue })
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
        // Keep the non-Sendable Foundation value within this synchronous call.
        nonisolated(unsafe) var result: NSScriptObjectSpecifier?
        MainActor.assumeIsolated { result = makeObjectSpecifier() }
        return result
    }

    private func makeObjectSpecifier() -> NSScriptObjectSpecifier? {
        if space == nil, let lastSpecifier { return lastSpecifier }
        guard let cls = NSScriptClassDescription(for: ScriptWindow.self) else { return lastSpecifier }
        let specifier: NSScriptObjectSpecifier
        if let window = ScriptRead.preferredWindow(), let container = ScriptHost.shared.windowWrapper(for: window).objectSpecifier {
            specifier = NSUniqueIDSpecifier(containerClassDescription: cls, containerSpecifier: container,
                                            key: "appleScriptSpaces", uniqueID: spaceID.rawValue.uuidString)
        } else {
            specifier = NSNameSpecifier(containerClassDescription: cls, containerSpecifier: nil,
                                        key: "appleScriptSpaces", name: space?.title ?? initialTitle)
        }
        lastSpecifier = specifier
        return specifier
    }
}
