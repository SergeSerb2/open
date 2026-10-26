import AppKit
import Foundation
import OpenModel

// Verbs use the named object, never CommandDispatcher. The wrapper responds-to selectors
// live here; system NSCreateCommand / NSCountCommand remain in the dictionary (§6.7).
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
        return ScriptHost.shared.tabWrapper(for: tab)
    }

    static func makeTab(inWindow windowID: WindowID, atIndex index: Int?, properties: [String: Any]) -> ScriptTab? {
        guard let model = ScriptRead.model() else { return nil }
        guard let state = model.windows.first(where: { $0.id == windowID }) else { ScriptFailure.missing("window", windowID.rawValue.uuidString); return nil }
        guard model.space(id: state.focusedSpaceID) != nil else { ScriptFailure.missing("space", state.focusedSpaceID.rawValue.uuidString); return nil }
        guard let url = parsedURL(properties["URL"] as? String ?? "about:blank") else { return nil }
        let tab = model.newTab(in: state.focusedSpaceID, url: url, at: nil)
        model.selectNode(windowID: state.id, spaceID: state.focusedSpaceID, nodeID: tab.id)
        return ScriptHost.shared.tabWrapper(for: tab)
    }

    static func makeLittleTab(properties: [String: Any]) -> ScriptTab? {
        guard let model = ScriptRead.model() else { return nil }
        guard let url = parsedURL(properties["URL"] as? String ?? "about:blank") else { return nil }
        guard let id = ScriptHost.shared.makeLittleTab?(url), let tab = model.tab(id: id) else {
            ScriptFailure.report(ScriptError.littleUnavailable, "Little windows are not available yet.")
            return nil
        }
        return ScriptHost.shared.tabWrapper(for: tab)
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
        return ScriptHost.shared.windowWrapper(for: state)
    }

    static func makeSpace() {
        ScriptFailure.report(ScriptError.makeSpaceUnsupported, "Making a new space is not supported. Create a Space in the sidebar.")
    }

    // §6.7 / Step 6: A9 decides whether ScriptMakeCommand must replace NSCreateCommand
    // to return the real wrapper's objectSpecifier after insertion replaces the blank object.
    // A14 decides whether ScriptCountCommand must replace NSCountCommand for application tabs.
    // Do not add either command class before running those real Apple-event checks.
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
