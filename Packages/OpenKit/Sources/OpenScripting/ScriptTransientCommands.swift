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

    static func install() {
        for (eventClass, eventID) in [("core", "clos"), ("CrSe", "lect"), ("CrSu", "Back"),
            ("CrSu", "Fwd "), ("CrSu", "Rlod"), ("CrSu", "stop"), ("CrSu", "ExJa")] {
            register(eventClass, eventID, className: "ScriptTransientTabCommand")
        }
        register("core", "setd", className: "ScriptSetCommand")
    }

    private static func code(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
    private static func text(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, encoding: .macOSRoman) ?? "****"
    }
    private static func register(_ eventClass: String, _ eventID: String, className: String) {
        let registry = NSScriptSuiteRegistry.shared()
        guard let original = registry.commandDescription(withAppleEventClass: code(eventClass), andAppleEventCode: code(eventID)) else { return }
        // Retain the bundled dictionary's exact argument types, names and codes.
        var arguments: [String: Any] = [:]
        for name in original.argumentNames {
            arguments[name] = ["AppleEventCode": text(original.appleEventCodeForArgument(withName: name)),
                "Type": original.typeForArgument(withName: name) ?? "NSObject",
                "Optional": original.isOptionalArgument(withName: name)]
        }
        var definition: [String: Any] = ["AppleEventClassCode": eventClass, "AppleEventCode": eventID,
            "CommandClass": className, "Arguments": arguments]
        if let type = original.returnType {
            definition["Type"] = type
            definition["ResultAppleEventCode"] = text(original.appleEventCodeForReturnType)
        }
        if let replacement = NSScriptCommandDescription(suiteName: original.suiteName,
            commandName: original.commandName, dictionary: definition) { registry.register(replacement) }
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
    public override func performDefaultImplementation() -> Any? {
        guard ScriptThread.isMainThread else { return nil }
        nonisolated(unsafe) let command = self
        nonisolated(unsafe) var result: Any?
        MainActor.assumeIsolated { result = command.setProperty() }
        return result
    }

    private func setProperty() -> Any? {
        let requested = directParameter as? NSScriptObjectSpecifier ?? receiversSpecifier
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
