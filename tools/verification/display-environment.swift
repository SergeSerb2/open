import AppKit
import CryptoKit

// Read display metadata only. The helper never orders a window or sends an event.
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
guard let main = NSScreen.main else { fputs("verification: no main display\n", stderr); exit(1) }
// Match the render harness host: never order it on screen. Read its actual screen,
// rather than the requested synthetic render scale (which can be 1 on a 2x panel).
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                      styleMask: .borderless, backing: .buffered, defer: false, screen: main)
window.isReleasedWhenClosed = false
defer { window.close() }
guard let screen = window.screen, [1.0, 2.0].contains(screen.backingScaleFactor),
      let profile = screen.colorSpace?.iccProfileData, profile.count <= 4_194_304 else {
    fputs("verification: main display has no supported scale/ICC profile\n", stderr)
    exit(1)
}
guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
      let mode = CGDisplayCopyDisplayMode(number.uint32Value),
      (1...16384).contains(mode.width), (1...16384).contains(mode.height),
      (1...32768).contains(mode.pixelWidth), (1...32768).contains(mode.pixelHeight),
      mode.refreshRate.isFinite, mode.refreshRate > 0, mode.refreshRate <= 1000 else {
    fputs("verification: unsupported display mode\n", stderr); exit(1)
}
let refresh = Int((mode.refreshRate * 1000).rounded())
let modeKey = "mode-\(mode.width)x\(mode.height)-pixels-\(mode.pixelWidth)x\(mode.pixelHeight)-mhz-\(refresh)"
let modeInfo: [String: Any] = ["points": "\(mode.width)x\(mode.height)",
                             "pixels": "\(mode.pixelWidth)x\(mode.pixelHeight)", "refreshMilliHz": refresh]
let scale = Int(screen.backingScaleFactor)
let digest = SHA256.hash(data: profile).map { String(format: "%02x", $0) }.joined()
let value: [String: Any] = ["key": "scale-\(scale)-icc-\(digest)-\(modeKey)", "backingScale": scale,
                           "iccSHA256": digest, "mode": modeInfo]
print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
