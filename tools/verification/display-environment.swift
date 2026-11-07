import AppKit
import CryptoKit

// Read display metadata only. This helper creates no window and sends no event.
_ = NSApplication.shared
guard let screen = NSScreen.main, [1.0, 2.0].contains(screen.backingScaleFactor),
      let profile = screen.colorSpace?.iccProfileData, profile.count <= 4_194_304 else {
    fputs("verification: main display has no supported scale/ICC profile\n", stderr)
    exit(1)
}
let scale = Int(screen.backingScaleFactor)
let digest = SHA256.hash(data: profile).map { String(format: "%02x", $0) }.joined()
let value: [String: Any] = ["key": "scale-\(scale)-icc-\(digest)", "backingScale": scale,
                           "iccSHA256": digest]
print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
