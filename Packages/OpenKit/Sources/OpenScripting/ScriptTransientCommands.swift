import AppKit
import Foundation
import OpenModel

/// Cocoa normally refuses receiver reads through the write-only application tabs
/// relationship. Resolve only unique-ID references; never expose that collection.
@MainActor
enum ScriptTransientTarget {
    static func reference(in specifier: NSScriptObjectSpecifier?) -> (NSUniqueIDSpecifier, String)? {
        var current = specifier
        while let value = current {
            if value.key == "appleScriptTabs", value.container == nil,
               let unique = value as? NSUniqueIDSpecifier, let id = unique.uniqueID as? String {
                return (unique, id)
            }
            current = value.container
        }
        return nil
    }
}

@MainActor
@objc(ScriptTransientTabCommand)
public final class ScriptTransientTabCommand: NSScriptCommand {
    public override var evaluatedReceivers: Any? {
        guard ScriptThread.isMainThread else { return nil }
        nonisolated(unsafe) let command = self
        nonisolated(unsafe) var result: Any?
        var transient = false
        MainActor.assumeIsolated {
            if let (_, id) = ScriptTransientTarget.reference(in: command.receiversSpecifier) {
                transient = true
                result = NSApplication.shared.valueInAppleScriptTabsWithUniqueID(id)
            }
        }
        return transient ? result : super.evaluatedReceivers
    }
}

/// Keep NSSetCommand for normal model/window writes. A transient URL setter must
/// resolve its target before Cocoa applies the collection's write-only read guard.
@MainActor
@objc(ScriptSetCommand)
public final class ScriptSetCommand: NSSetCommand {
    public override var evaluatedReceivers: Any? {
        guard ScriptThread.isMainThread else { return nil }
        nonisolated(unsafe) let command = self
        nonisolated(unsafe) var result: Any?
        var transient = false
        MainActor.assumeIsolated {
            if let (_, id) = ScriptTransientTarget.reference(in: command.receiversSpecifier) {
                transient = true
                result = NSApplication.shared.valueInAppleScriptTabsWithUniqueID(id)
            }
        }
        return transient ? result : super.evaluatedReceivers
    }

    public override func performDefaultImplementation() -> Any? {
        guard ScriptThread.isMainThread else { return nil }
        nonisolated(unsafe) let command = self
        nonisolated(unsafe) var result: Any?
        MainActor.assumeIsolated { result = command.setProperty() }
        return result
    }

    private func setProperty() -> Any? {
        // NSSetCommand splits the property off receiversSpecifier. Keep the
        // original event's complete path when identifying a transient write.
        let requested = appleEvent?.paramDescriptor(forKeyword: 0x2d2d2d2d)
            .flatMap { NSScriptObjectSpecifier(descriptor: $0) }
            ?? directParameter as? NSScriptObjectSpecifier ?? receiversSpecifier
        guard let (reference, id) = ScriptTransientTarget.reference(in: requested) else {
            return super.performDefaultImplementation()
        }
        guard let tab = NSApplication.shared.valueInAppleScriptTabsWithUniqueID(id) else { return nil }
        guard let property = requested as? NSPropertySpecifier, property.container === reference,
              property.key == "URL" else {
            return fail(ScriptError.makeSpaceUnsupported, "Setting this property is not supported for Little Open tabs.")
        }
        guard let value = evaluatedArguments?["Value"] as? String
            ?? appleEvent?.paramDescriptor(forKeyword: 0x64617461)?.stringValue else {
            return fail(ScriptError.invalidValue, "URL needs a text value.")
        }
        tab.URL = value
        return nil
    }
}
