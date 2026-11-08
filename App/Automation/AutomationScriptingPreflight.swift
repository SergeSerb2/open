#if OPEN_AUTOMATION
import AppKit
import OpenScripting

/// Exercise Cocoa's actual core/setd decoder in the App before creating any
/// windows or starting Chromium. The launcher supplies an isolated data root.
@MainActor
enum AutomationScriptingPreflight {
  static func run(app: AppDelegate, receipt: URL) -> Never {
    NSApp.delegate = nil
    NSApp.setActivationPolicy(.prohibited)
    NSApp.finishLaunching()
    app.installScripting()
    // Model windows remain scriptable while no native windows exist.
    ScriptHost.shared.windowStateID = nil
    guard let model = app.model, let space = model.spaces.first else { exit(2) }
    let tab = model.newTab(in: space.id, url: URL(string: "about:blank")!)
    let bundle = Bundle.main.bundlePath.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let source = """
    using terms from application "\(bundle)"
      tell current application
        set t to tab id "\(tab.id.rawValue.uuidString)" of window 1
        set location of t to "pinned"
        set resultText to location of t
        try
          set URL of t to "invalid text"
          error "URL setter did not reject invalid input"
        on error msg number n
          if n is not 1001 then error msg number n
        end try
        try
          set index of window 1 to 2
          error "window setter did not reject invalid index"
        on error msg number n
          if n is not 1007 then error msg number n
        end try
        try
          set URL of tab id "00000000-0000-0000-0000-000000000000" to "about:blank"
          error "transient setter did not reject a stale reference"
        on error msg number n
          if n is not 1000 then error msg number n
        end try
        return resultText
      end tell
    end using terms from
    """
    DispatchQueue.global().async {
      var error: NSDictionary?
      let text = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue ?? ""
      let number = error?[NSAppleScript.errorNumber] as? Int ?? 0
      let message = error?[NSAppleScript.errorMessage] as? String ?? ""
      DispatchQueue.main.async {
        let windows = NSApp.windows.count
        let passed = number == 0 && text == "pinned" && windows == 0
        let result: [String: Any] = ["ok": passed, "number": number, "message": message,
          "text": text, "nativeWindows": windows, "sender": "self NSAppleScript"]
        do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: receipt) }
        catch { exit(2) }
        exit(passed ? 0 : 1)
      }
    }
    NSApp.run()
    exit(2)
  }
}
#endif
