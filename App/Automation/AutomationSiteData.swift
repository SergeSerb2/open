#if OPEN_AUTOMATION
import Foundation
import Security
import CryptoKit
import OpenEngine
import OpenWeb

extension AutomationController {
  /// Exercises the OpenWeb caller path, not a separate testing implementation.
  func runSiteDataCommand(_ cmd: String, _ args: [String: Any], page: OEWebContent) async throws -> Any {
    let content: any WebContent = page
    if cmd == "security-state" {
      return ["level": content.securityLevel.rawValue,
        "certificates": content.certificateChain.map { certificate in
          let der = SecCertificateCopyData(certificate) as Data
          return ["bytes": der.count, "sha256": SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()] as [String: Any]
        }] as [String: Any]
    }
    guard let value = args["origin"] as? String, let origin = URL(string: value) else {
      throw Failure(message: "missing origin")
    }
    let profile: any WebProfile = EngineWebProfile(page.context)
    switch cmd {
    case "site-settings":
      return profile.changedSiteSettings(origin: origin).map { ["kind": $0.kind, "state": $0.state.rawValue] }
    case "site-setting":
      guard let kind = args["kind"] as? String,
        let raw = args["state"] as? String, let state = WebSiteSettingState(rawValue: raw)
      else { throw Failure(message: "missing kind or invalid state") }
      return profile.setSiteSetting(state, kind: kind, origin: origin)
    case "site-data-clear":
      guard let names = args["kinds"] as? [String], names.count <= 3,
        names.allSatisfy({ ["cookies", "cache", "storage"].contains($0) }) else {
        throw Failure(message: "kinds must contain cookies, cache or storage")
      }
      var kinds: WebSiteDataKinds = []
      if names.contains("cookies") { kinds.insert(.cookies) }
      if names.contains("cache") { kinds.insert(.cache) }
      if names.contains("storage") { kinds.insert(.storage) }
      try await profile.clearSiteData(origin: origin, kinds: kinds)
      return true
    default: throw Failure(message: "unknown site-data command")
    }
  }
}
#endif
