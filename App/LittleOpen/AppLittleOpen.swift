import Foundation
import OpenModel

struct LittleOpenRequest {
  let url: URL
  let profileHint: ProfileID?
}

extension AppDelegate {
  /// Step 6 replaces only this seam with the real Little Open coordinator.
  func openLittleOpen(url: URL, profileHint: ProfileID?) {
    lastLittleOpenRequest = LittleOpenRequest(url: url, profileHint: profileHint)
    showLittleOpenStub()
  }
}
