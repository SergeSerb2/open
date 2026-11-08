import Foundation
import Security
import OpenEngine
import OpenWeb

extension EngineWebProfile {
  func changedSiteSettings(origin: URL) -> [WebSiteSetting] {
    context.changedSiteSettings(origin: origin).compactMap { value in
      WebSiteSettingState(rawValue: value.state).map { WebSiteSetting(kind: value.kind, state: $0) }
    }
  }

  @discardableResult
  func setSiteSetting(_ state: WebSiteSettingState, kind: String, origin: URL) -> Bool {
    context.setSiteSetting(kind, state: state.rawValue, origin: origin)
  }

  func clearSiteData(origin: URL, kinds: WebSiteDataKinds) async throws {
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
      context.clearSiteData(origin: origin, types: OESiteDataType(rawValue: kinds.rawValue)) { error in
        if let error { done.resume(throwing: error) }
        else { done.resume() }
      }
    }
  }
}

extension OEWebContent {
  public var securityLevel: WebSecurityLevel { WebSecurityLevel(rawValue: engineSecurityLevel) ?? .neutral }
  public var certificateChain: [SecCertificate] { engineCertificateChain as? [SecCertificate] ?? [] }
}
