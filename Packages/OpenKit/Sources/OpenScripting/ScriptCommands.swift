import AppKit
import Foundation
import OpenModel

// Verbs use the named object, never CommandDispatcher. The wrapper responds-to selectors
// live here; make/count subclasses close the system-command gaps described in §6.7.
@MainActor
enum ScriptTarget {
    private static func resolve<T>(_ command: NSScriptCommand, receiver: T?) -> T? {
        if let specifier = command.directParameter as? NSScriptObjectSpecifier {
            let value = specifier.objectsByEvaluatingSpecifier
            if let value = value as? T { return value }
            if let values = value as? [T], let receiver, values.contains(where: { ($0 as AnyObject) === (receiver as AnyObject) }) { return receiver }
            return nil
        }
        if let direct = command.directParameter { return direct as? T }
        if let value = command.evaluatedReceivers as? T { return value }
        return receiver
    }

    static func tab(from command: NSScriptCommand, receiver: ScriptTab? = nil) -> ScriptTab? {
        guard ScriptHost.shared.model != nil else { command.fail(ScriptError.notReady, "Open is not ready."); return nil }
        guard let wrapper: ScriptTab = resolve(command, receiver: receiver), wrapper.tab != nil else {
            command.fail(ScriptError.objectNotFound, "The tab \(receiver?.tabID.rawValue.uuidString ?? command.directParameter.map { String(describing: $0) } ?? "") does not exist.")
            return nil
        }
        return wrapper
    }
    static func space(from command: NSScriptCommand, receiver: ScriptSpace? = nil) -> ScriptSpace? {
        guard ScriptHost.shared.model != nil else { command.fail(ScriptError.notReady, "Open is not ready."); return nil }
        guard let wrapper: ScriptSpace = resolve(command, receiver: receiver), wrapper.space != nil else {
            command.fail(ScriptError.objectNotFound, "The space \(receiver?.spaceID.rawValue.uuidString ?? command.directParameter.map { String(describing: $0) } ?? "") does not exist.")
            return nil
        }
        return wrapper
    }
    static func window(from command: NSScriptCommand, receiver: ScriptWindow? = nil) -> ScriptWindow? {
        guard ScriptHost.shared.model != nil else { command.fail(ScriptError.notReady, "Open is not ready."); return nil }
        guard let wrapper: ScriptWindow = resolve(command, receiver: receiver), wrapper.state != nil else {
            command.fail(ScriptError.objectNotFound, "The window \(receiver?.stateID.rawValue.uuidString ?? command.directParameter.map { String(describing: $0) } ?? "") does not exist.")
            return nil
        }
        return wrapper
    }

    static func bridge(_ command: NSScriptCommand) -> (any ScriptEngineBridge)? {
        guard let bridge = ScriptHost.shared.engineBridge else {
            command.fail(ScriptError.engineUnavailable, "The page engine is not ready.")
            return nil
        }
        return bridge
    }

    static func bringForward(_ state: BrowserWindowState) {
        // Scratch probes have model windows but no NSWindow. Do not activate another app.
        guard let window = ScriptHost.shared.windowForState?(state.id) else { return }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }
}

@MainActor
enum ScriptCreation {
    static func parsedURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme != nil || url.host != nil else {
            ScriptFailure.report(ScriptError.invalidURL, "\"\(text)\" is not a valid URL.")
            return nil
        }
        return url
    }

    static func makeTab(inSpace spaceID: SpaceID, atIndex index: Int?, properties: [String: Any]) -> ScriptTab? {
        guard let model = ScriptRead.model() else { return nil }
        guard model.space(id: spaceID) != nil else { ScriptFailure.missing("space", spaceID.rawValue.uuidString); return nil }
        guard let url = parsedURL(properties["URL"] as? String ?? "about:blank") else { return nil }
        // §5.7 always appends to Today, regardless of a flattened insertion index.
        let tab = model.newTab(in: spaceID, url: url, at: nil)
        if let window = ScriptRead.preferredWindow() {
            model.focusSpace(windowID: window.id, spaceID: spaceID)
            model.selectNode(windowID: window.id, spaceID: spaceID, nodeID: tab.id)
        }
        return record(ScriptHost.shared.tabWrapper(for: tab))
    }

    static func makeTab(inWindow windowID: WindowID, atIndex index: Int?, properties: [String: Any]) -> ScriptTab? {
        guard let model = ScriptRead.model() else { return nil }
        guard let state = model.windows.first(where: { $0.id == windowID }) else { ScriptFailure.missing("window", windowID.rawValue.uuidString); return nil }
        guard model.space(id: state.focusedSpaceID) != nil else { ScriptFailure.missing("space", state.focusedSpaceID.rawValue.uuidString); return nil }
        guard let url = parsedURL(properties["URL"] as? String ?? "about:blank") else { return nil }
        let tab = model.newTab(in: state.focusedSpaceID, url: url, at: nil)
        model.selectNode(windowID: state.id, spaceID: state.focusedSpaceID, nodeID: tab.id)
        return record(ScriptHost.shared.tabWrapper(for: tab))
    }

    static func makeLittleTab(properties: [String: Any]) -> ScriptTab? {
        guard let model = ScriptRead.model() else { return nil }
        guard let url = parsedURL(properties["URL"] as? String ?? "about:blank") else { return nil }
        guard let id = ScriptHost.shared.makeLittleTab?(url), let tab = model.tab(id: id) else {
            ScriptFailure.report(ScriptError.littleUnavailable, "Little windows are not available yet.")
            return nil
        }
        return record(ScriptHost.shared.tabWrapper(for: tab))
    }

    static func makeWindow(properties: [String: Any]) -> ScriptWindow? {
        guard ScriptRead.model() != nil else { return nil }
        let incognito = properties["mode"] as? String == "incognito"
        guard let id = ScriptHost.shared.makeWindow?(incognito),
              let state = ScriptHost.shared.model?.windows.first(where: { $0.id == id }) else {
            ScriptFailure.report(incognito ? ScriptError.incognitoUnavailable : ScriptError.noWindow,
                                 incognito ? "Incognito windows are not available in this build." : "There is no browser window.")
            return nil
        }
        ScriptHost.shared.windowModes[id] = incognito ? "incognito" : "normal"
        return record(ScriptHost.shared.windowWrapper(for: state))
    }

    static func makeSpace() {
        ScriptFailure.report(ScriptError.makeSpaceUnsupported, "Making a new space is not supported. Create a Space in the sidebar.")
    }

    private static func record<T: NSObject>(_ object: T) -> T {
        (NSScriptCommand.current() as? ScriptMakeCommand)?.createdObject = object
        return object
    }
}

/// Keep Cocoa's property decoding and insertion-location handling, but return the
/// model object created by the insertion accessor, never its temporary placeholder.
@MainActor
@objc(ScriptMakeCommand)
public final class ScriptMakeCommand: NSCreateCommand {
    fileprivate var createdObject: NSObject?

    public override func performDefaultImplementation() -> Any? {
        guard ScriptThread.isMainThread else { return nil }
        nonisolated(unsafe) let command = self
        nonisolated(unsafe) var result: Any?
        MainActor.assumeIsolated { result = command.makeObject() }
        return result
    }

    private func makeObject() -> Any? {
        createdObject = nil
        // There is deliberately no application.spaces relationship in the dictionary.
        if createClassDescription == NSScriptClassDescription(for: ScriptSpace.self) {
            ScriptCreation.makeSpace()
            return nil
        }
        // The locked sdef omits the built-in "at" parameter. Cocoa keeps its
        // descriptor in the Apple event but drops it from arguments. Restore it
        // for NSCreateCommand without changing the dictionary's terms or codes.
        if arguments?["Location"] == nil,
           let descriptor = appleEvent?.paramDescriptor(forKeyword: 0x696e7368) {
            guard let location = insertionLocation(from: descriptor) else { return nil }
            var restored = arguments ?? [:]
            restored["Location"] = location
            arguments = restored
        }
        _ = super.performDefaultImplementation()
        guard scriptErrorNumber == 0 else { return nil }
        guard let specifier = createdObject?.objectSpecifier else {
            return fail(ScriptError.objectNotFound, "The created object has no scripting specifier.")
        }
        return specifier
    }

    private func insertionLocation(from descriptor: NSAppleEventDescriptor) -> NSPositionalSpecifier? {
        // "at <container>" is an object specifier; relative/beginning/end forms
        // are insertion-location records containing kobj and kpos.
        let reference = descriptor.forKeyword(0x6b6f626a)
        let object = reference ?? descriptor
        guard let specifier = NSScriptObjectSpecifier(descriptor: object) else { return nil }
        let position: NSPositionalSpecifier.InsertionPosition
        switch descriptor.forKeyword(0x6b706f73)?.enumCodeValue {
        case 0x62656620: position = .before
        case 0x61667465: position = .after
        case 0x62676e67: position = .beginning
        default: position = .end
        }
        return NSPositionalSpecifier(position: position, objectSpecifier: specifier)
    }
}

/// The implicit core/getd command checks dictionary access before calling a
/// getter. Override its default implementation to supply Open's 1004 for application tabs.
/// Registration reuses the existing system command; Open.sdef stays unchanged.
@MainActor
@objc(ScriptGetCommand)
public final class ScriptGetCommand: NSGetCommand {
    static func install() {
        let registry = NSScriptSuiteRegistry.shared()
        guard let original = registry.commandDescription(withAppleEventClass: 0x636f7265, andAppleEventCode: 0x67657464),
              let description = NSScriptCommandDescription(suiteName: original.suiteName, commandName: original.commandName,
                  dictionary: ["AppleEventClassCode": "core", "AppleEventCode": "getd", "CommandClass": "ScriptGetCommand",
                               "ResultAppleEventCode": "****", "Type": "NSObject"]) else { return }
        registry.register(description)
    }

    public override func performDefaultImplementation() -> Any? {
        guard ScriptThread.isMainThread else { return nil }
        nonisolated(unsafe) let command = self
        nonisolated(unsafe) var result: Any?
        MainActor.assumeIsolated { result = command.getObjects() }
        return result
    }

    private func getObjects() -> Any? {
        // Cocoa also omits get's implicit direct parameter for a custom command
        // class. Restore its object specifier before NSGetCommand evaluates it.
        if directParameter == nil, let descriptor = appleEvent?.paramDescriptor(forKeyword: 0x2d2d2d2d) {
            directParameter = NSScriptObjectSpecifier(descriptor: descriptor)
        }
        var specifier = directParameter as? NSScriptObjectSpecifier ?? receiversSpecifier
        while let current = specifier {
            if current.key == "appleScriptTabs", current.container == nil {
                return fail(ScriptError.writeOnly, "Application tabs are write-only. Use tabs of a window or space.")
            }
            specifier = current.container
        }
        return super.performDefaultImplementation()
    }
}

@MainActor
@objc(ScriptCountCommand)
public final class ScriptCountCommand: NSCountCommand {
    public override func performDefaultImplementation() -> Any? {
        guard ScriptThread.isMainThread else { return nil }
        nonisolated(unsafe) let command = self
        nonisolated(unsafe) var result: Any?
        MainActor.assumeIsolated { result = command.countObjects() }
        return result
    }

    private func countObjects() -> Any? {
        let specifier = directParameter as? NSScriptObjectSpecifier ?? receiversSpecifier
        if specifier?.key == "appleScriptTabs", specifier?.container == nil {
            return fail(ScriptError.writeOnly, "Application tabs are write-only. Use tabs of a window or space.")
        }
        return super.performDefaultImplementation()
    }
}

extension ScriptTab {
    @objc public func select(_ command: NSScriptCommand) -> Any? {
        guard let target = ScriptTarget.tab(from: command, receiver: self), let model = ScriptHost.shared.model else { return nil }
        guard let window = ScriptRead.preferredWindow() else { return command.fail(ScriptError.noWindow, "There is no browser window.") }
        let spaceID = ScriptRead.spaceID(of: target.tabID, model: model) ?? window.focusedSpaceID
        guard model.space(id: spaceID) != nil else { return command.fail(ScriptError.noWindow, "There is no browser window.") }
        if window.focusedSpaceID != spaceID { model.focusSpace(windowID: window.id, spaceID: spaceID) }
        model.selectNode(windowID: window.id, spaceID: spaceID, nodeID: target.tabID)
        ScriptTarget.bringForward(window)
        return nil
    }

    @objc public func goBack(_ command: NSScriptCommand) -> Any? {
        guard let target = ScriptTarget.tab(from: command, receiver: self), let tab = target.tab else { return nil }
        guard tab.live.canGoBack else { return nil }
        ScriptTarget.bridge(command)?.goBack(tabID: target.tabID)
        return nil
    }
    @objc public func goForward(_ command: NSScriptCommand) -> Any? {
        guard let target = ScriptTarget.tab(from: command, receiver: self), let tab = target.tab else { return nil }
        guard tab.live.canGoForward else { return nil }
        ScriptTarget.bridge(command)?.goForward(tabID: target.tabID)
        return nil
    }
    @objc public func reload(_ command: NSScriptCommand) -> Any? {
        guard let target = ScriptTarget.tab(from: command, receiver: self) else { return nil }
        ScriptTarget.bridge(command)?.reload(tabID: target.tabID)
        return nil
    }
    @objc public func stopLoading(_ command: NSScriptCommand) -> Any? {
        guard let target = ScriptTarget.tab(from: command, receiver: self), let tab = target.tab else { return nil }
        guard tab.live.isLoading else { return nil }
        ScriptTarget.bridge(command)?.stopLoading(tabID: target.tabID)
        return nil
    }
    @objc public func executeJavascript(_ command: NSScriptCommand) -> Any? {
        guard let target = ScriptTarget.tab(from: command, receiver: self) else { return nil }
        guard let script = command.arguments?["javascript"] as? String, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return command.fail(ScriptError.invalidValue, "execute needs a javascript string.")
        }
        guard let bridge = ScriptTarget.bridge(command) else { return nil }
        do {
            return try bridge.executeJavaScript(tabID: target.tabID, script: script) as NSString
        } catch ScriptEngineError.timedOut {
            return command.fail(ScriptError.javascriptTimedOut, "JavaScript did not finish in 10 seconds.")
        } catch ScriptEngineError.noLiveContent {
            return command.fail(ScriptError.engineUnavailable, "The page engine is not ready.")
        } catch ScriptEngineError.javascriptError(let message) {
            let firstLine = String(message.prefix { !$0.isNewline }.prefix(300))
            return command.fail(ScriptError.javascriptFailed, "JavaScript error: " + firstLine)
        } catch {
            // Never expose an arbitrary Swift error or the script source.
            return command.fail(ScriptError.javascriptFailed, "JavaScript error: JavaScript execution failed.")
        }
    }
    @objc public func close(_ command: NSScriptCommand) -> Any? {
        guard let target = ScriptTarget.tab(from: command, receiver: self), let model = ScriptHost.shared.model else { return nil }
        _ = target.objectSpecifier
        model.closeTab(id: target.tabID)
        ScriptHost.shared.tabWrappers[target.tabID] = nil
        return nil
    }
}

extension ScriptSpace {
    @objc public func focus(_ command: NSScriptCommand) -> Any? {
        guard let target = ScriptTarget.space(from: command, receiver: self), let model = ScriptHost.shared.model else { return nil }
        guard let window = ScriptRead.preferredWindow() else { return command.fail(ScriptError.noWindow, "There is no browser window.") }
        model.focusSpace(windowID: window.id, spaceID: target.spaceID)
        ScriptTarget.bringForward(window)
        return nil
    }
}

extension ScriptWindow {
    @objc public func close(_ command: NSScriptCommand) -> Any? {
        guard let target = ScriptTarget.window(from: command, receiver: self) else { return nil }
        guard let window = target.nsWindow else { return command.fail(ScriptError.noWindow, "There is no browser window.") }
        window.close() // The App close observer owns removal of BrowserWindowState.
        return nil
    }
}
