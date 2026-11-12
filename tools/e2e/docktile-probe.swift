// Loads the built App's real Dock tile plug-in (the bundle the Dock loads while Open is not running) and asks it
// which image it would draw. Prints JSON: {"loaded", "principal", "image": [w, h] or null}.
// Usage: docktile-probe <Open.app path> [preferences domain]
// With a domain (an e2e run's private one), the plug-in reads that domain instead of the App's own.
import AppKit
import Foundation

@main struct DockTileProbe {
  static func main() {
    var out: [String: Any] = ["loaded": false, "principal": "", "image": NSNull()]
    defer {
      let data = (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{}".utf8)
      FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
    }
    guard (2...3).contains(CommandLine.arguments.count) else { return }
    let app = URL(fileURLWithPath: CommandLine.arguments[1])
    let infoURL = app.appendingPathComponent("Contents/Info.plist")
    guard let info = NSDictionary(contentsOf: infoURL), let name = info["NSDockTilePlugIn"] as? String,
          let bundle = Bundle(url: app.appendingPathComponent("Contents/PlugIns").appendingPathComponent(name)),
          bundle.load(), let principal = bundle.principalClass as? NSObject.Type else { return }
    out["loaded"] = true
    out["principal"] = NSStringFromClass(principal)
    out["infoKey"] = name
    let image: NSImage?
    if CommandLine.arguments.count == 3 {
      let selector = NSSelectorFromString("selectedIconInDomain:")
      guard principal.responds(to: selector) else { return }
      image = principal.perform(selector, with: CommandLine.arguments[2] as NSString)?.takeUnretainedValue() as? NSImage
    } else {
      let selector = NSSelectorFromString("selectedIcon")
      guard principal.responds(to: selector) else { return }
      image = principal.perform(selector)?.takeUnretainedValue() as? NSImage
    }
    guard let image else { return }
    let rep = image.representations.first
    out["image"] = [rep?.pixelsWide ?? Int(image.size.width), rep?.pixelsHigh ?? Int(image.size.height)]
  }
}
