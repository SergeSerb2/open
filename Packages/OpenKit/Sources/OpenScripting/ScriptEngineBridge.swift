import Foundation
import OpenModel

/// App-owned engine adapter. Conversion and the ten-second JavaScript timeout belong to H2.
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
