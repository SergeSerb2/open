import AppKit
import CryptoKit

// icc-header-v1 excludes only the creation date and profile ID. All tag bytes,
// including primaries, white point, TRCs and vcgt, remain in the digest.
func profileDigest(_ profile: Data) -> String? {
    guard (128...4_194_304).contains(profile.count),
          profile[36..<40] == Data("acsp".utf8) else { return nil }
    var normalized = profile
    normalized.resetBytes(in: 24..<36)
    normalized.resetBytes(in: 84..<100)
    return SHA256.hash(data: normalized).map { String(format: "%02x", $0) }.joined()
}

// File inspection is a separate CLI path. It never overrides the live screen
// used by normal verification. Read at most 4 MiB plus one refusal byte.
if CommandLine.arguments.count != 1 {
    guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--icc-digest" else {
        fputs("usage: display-environment.swift [--icc-digest FILE]\n", stderr); exit(2)
    }
    do {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: CommandLine.arguments[2]))
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 4_194_305) ?? Data()
        guard let digest = profileDigest(bytes) else {
            fputs("verification: invalid or oversized ICC profile\n", stderr); exit(1)
        }
        let value = ["iccDigestScheme": "icc-header-v1", "iccSHA256": digest,
                     "iccRawSHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
        print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
        exit(0)
    } catch {
        fputs("verification: cannot read ICC profile: \(error)\n", stderr); exit(1)
    }
}

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
      let profile = screen.colorSpace?.iccProfileData, let digest = profileDigest(profile) else {
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
let value: [String: Any] = ["key": "scale-\(scale)-icc-header-v1-\(digest)-\(modeKey)", "backingScale": scale,
                           "iccSHA256": digest, "iccDigestScheme": "icc-header-v1",
                           "iccRawSHA256": SHA256.hash(data: profile).map { String(format: "%02x", $0) }.joined(),
                           "mode": modeInfo]
print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
