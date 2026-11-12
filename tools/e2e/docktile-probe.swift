// Loads the built App's real Dock tile plug-in (the bundle the Dock loads while Open is not running) and asks it
// which image it would draw. Prints JSON: {"loaded", "principal", "image": [w, h] or null}.
// Usage: docktile-probe <Open.app path>
import AppKit
import Foundation

@main struct DockTileProbe {
  static func main() {
    var out: [String: Any] = ["loaded": false, "principal": "", "image": NSNull()]
    defer {
      let data = (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{}".utf8)
      FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
    }
    guard CommandLine.arguments.count == 2 else { return }
    let app = URL(fileURLWithPath: CommandLine.arguments[1])
    let infoURL = app.appendingPathComponent("Contents/Info.plist")
    guard let info = NSDictionary(contentsOf: infoURL), let name = info["NSDockTilePlugIn"] as? String,
          let bundle = Bundle(url: app.appendingPathComponent("Contents/PlugIns").appendingPathComponent(name)),
          bundle.load(), let principal = bundle.principalClass as? NSObject.Type else { return }
    out["loaded"] = true
    out["principal"] = NSStringFromClass(principal)
    out["infoKey"] = name
    let selector = NSSelectorFromString("selectedIcon")
    guard principal.responds(to: selector),
          let image = principal.perform(selector)?.takeUnretainedValue() as? NSImage else { return }
    let rep = image.representations.first
    out["image"] = [rep?.pixelsWide ?? Int(image.size.width), rep?.pixelsHigh ?? Int(image.size.height)]
  }
}
