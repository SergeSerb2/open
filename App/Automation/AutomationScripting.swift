#if OPEN_AUTOMATION
import AppKit
import OpenScripting

/// TCC fallback for e2e only. NSAppleScript sends actual Apple events to its own
/// host application, through the bundled dictionary and normal Cocoa handlers.
/// Never changes macOS consent or substitutes wrapper/bridge calls for Apple events.
extension AutomationController {
  private static let scriptingQueue = DispatchQueue(label: "app.open.automation.applescript")

  func runAppleScript(_ args: [String: Any]) async throws -> Any {
    guard let body = args["body"] as? String, body.utf8.count <= 1_048_576 else {
      throw Failure(message: "AppleScript body must be text of at most 1048576 UTF-8 bytes")
    }
    let host = ScriptHost.shared
    let model = host.modelProvider, bridge = host.engineBridge, makeWindow = host.makeWindow, littleTab = host.littleTab
    switch args["unavailable"] as? String {
    case "model": host.modelProvider = nil
    case "engine": host.engineBridge = nil
    case "window": host.makeWindow = nil
    case "little": host.littleTab = nil
    case nil: break
    default: throw Failure(message: "unknown scripting unavailability fixture")
    }
    defer { host.modelProvider = model; host.engineBridge = bridge; host.makeWindow = makeWindow; host.littleTab = littleTab }
    let bundle = Bundle.main.bundlePath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let source = "using terms from application \"\(bundle)\"\ntell current application\n\(body)\nend tell\nend using terms from"
    let data: Data = await withCheckedContinuation { done in
      Self.scriptingQueue.async {
        var error: NSDictionary?
        let value = NSAppleScript(source: source)?.executeAndReturnError(&error)
        let response: [String: Any] = ["number": error?[NSAppleScript.errorNumber] as? Int ?? 0,
          "message": error?[NSAppleScript.errorMessage] as? String ?? "",
          "text": value?.stringValue ?? ""]
        done.resume(returning: (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{}".utf8))
      }
    }
    return try JSONSerialization.jsonObject(with: data)
  }
}
#endif
