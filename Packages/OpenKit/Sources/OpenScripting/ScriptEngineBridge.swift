import Foundation
import OpenModel

/// Named-tab navigation and execute contract for dictionary verbs. The App H2 adapter
/// owns value conversion and the ten-second reply deadline; this module never imports an engine.
@MainActor
public protocol ScriptEngineBridge: AnyObject {
    func navigate(tabID: ItemID, to url: URL)
    func goBack(tabID: ItemID)
    func goForward(tabID: ItemID)
    func reload(tabID: ItemID)
    func stopLoading(tabID: ItemID)
    func executeJavaScript(tabID: ItemID, script: String) throws -> String
}

public enum ScriptEngineError: Error {
    case javascriptError(String)
    case timedOut
    case noLiveContent
}
