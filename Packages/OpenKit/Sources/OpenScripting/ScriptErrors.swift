import AppKit
import Foundation

/// Script-facing failure numbers from plan §8. The helpers apply them to the current
/// Cocoa command or KVC setter and guard the main-thread specifier boundary.
public enum ScriptError {
    public static let objectNotFound = 1000
    public static let invalidURL = 1001
    public static let invalidValue = 1002
    public static let invalidMove = 1003
    public static let writeOnly = 1004
    public static let notReady = 1005
    public static let engineUnavailable = 1006
    public static let useMakeAndClose = 1007
    public static let modeSetOnce = 1008
    public static let makeSpaceUnsupported = 1009
    public static let incognitoUnavailable = 1010
    public static let littleUnavailable = 1011
    public static let noWindow = 1012
    public static let javascriptFailed = 1013
    public static let javascriptTimedOut = 1014
}

extension NSScriptCommand {
    @MainActor
    @discardableResult
    func fail(_ number: Int, _ message: String) -> Any? {
        scriptErrorNumber = number
        scriptErrorString = message
        return nil
    }
}

@MainActor
enum ScriptFailure {
    static func report(_ number: Int, _ message: String) {
        if let command = NSScriptCommand.current() {
            command.fail(number, message)
        } else {
            ScriptHost.shared.lastSetterError = (number, message)
            #if DEBUG
            // Do not log values: even an invalid URL can contain private data.
            FileHandle.standardError.write(Data("OpenScripting: ScriptErrors KVC failure \(number)\n".utf8))
            #endif
        }
    }

    static func missing(_ noun: String, _ id: String) {
        report(ScriptError.objectNotFound, "The \(noun) \(id) does not exist.")
    }
}

/// NSObject's specifier override is nonisolated. Check before entering the actor boundary.
enum ScriptThread {
    static var isMainThread: Bool {
        guard Thread.isMainThread else {
            #if DEBUG
            FileHandle.standardError.write(Data("OpenScripting: off-main scripting call ignored\n".utf8))
            #endif
            return false
        }
        return true
    }
}
