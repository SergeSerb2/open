import AppKit
import Foundation
import OpenModel

// Application KVC keys. Name, version, and isActive remain AppKit-owned.
extension NSApplication {
    @objc public dynamic var appleScriptWindows: [ScriptWindow] {
        guard let model = ScriptHost.shared.model else { return [] }
        guard let stateID = ScriptHost.shared.windowStateID else {
            // Pre-App fallback required by plan §5.2 for the scratch probes.
            return model.windows.map { ScriptHost.shared.windowWrapper(for: $0) }
        }
        return windows.compactMap { window in
            guard let id = stateID(window), let state = model.windows.first(where: { $0.id == id }) else { return nil }
            return ScriptHost.shared.windowWrapper(for: state)
        }
    }

    // Swift KVC returns []; Apple-event reads fail. NSCreateCommand also reads this
    // collection during insertion, so creation must remain exempt from the read guard.
    @objc public dynamic var appleScriptTabs: [ScriptTab] {
        if let command = NSScriptCommand.current(), !(command is NSCreateCommand) {
            command.fail(ScriptError.writeOnly, "Application tabs are write-only. Use tabs of a window or space.")
        }
        return []
    }
    @objc public func countOfAppleScriptTabs() -> Int { appleScriptTabs.count }

    @objc public func countOfAppleScriptWindows() -> Int { appleScriptWindows.count }
    @objc public func objectInAppleScriptWindowsAtIndex(_ index: Int) -> ScriptWindow? {
        ScriptRead.at(index, in: appleScriptWindows, noun: "window")
    }
    @objc public func valueInAppleScriptWindowsWithUniqueID(_ id: String) -> ScriptWindow? {
        ScriptRead.byID(id, in: appleScriptWindows, noun: "window", uuid: { $0.stateID.rawValue })
    }

    @objc(insertInAppleScriptTabs:atIndex:) public func insertInAppleScriptTabs(_ tab: ScriptTab, at index: Int) {
        _ = ScriptCreation.makeLittleTab(properties: tab.creationProperties)
    }
    @objc public func insertInAppleScriptTabs(_ tab: ScriptTab) {
        _ = ScriptCreation.makeLittleTab(properties: tab.creationProperties)
    }
    @objc(insertInAppleScriptWindows:atIndex:) public func insertInAppleScriptWindows(_ window: ScriptWindow, at index: Int) {
        _ = ScriptCreation.makeWindow(properties: window.creationProperties)
    }
    @objc public func insertInAppleScriptWindows(_ window: ScriptWindow) {
        _ = ScriptCreation.makeWindow(properties: window.creationProperties)
    }
    @objc(removeFromAppleScriptWindowsAtIndex:) public func removeFromAppleScriptWindows(at index: Int) {
        ScriptFailure.report(ScriptError.useMakeAndClose, "Use make new window and close window.")
    }
    @objc public func handleQuitScriptCommand(_ command: NSScriptCommand) -> Any? {
        NSApplication.shared.terminate(nil)
        return nil
    }
}
