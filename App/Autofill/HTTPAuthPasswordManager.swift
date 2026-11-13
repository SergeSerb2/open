#if OPEN_HTTP_AUTH
import Foundation

/// A password-store result must match the complete protection space. A host
/// match alone must never fill credentials from another origin or realm.
struct HTTPAuthProtectionSpace: Equatable {
  let transport: String
  let host: String
  let port: Int
  let realm: String
  let scheme: String
  let isProxy: Bool

  @MainActor
  init?(_ request: any HTTPAuthRequest) {
    // E3 exposes the page origin separately from the proxy host/port. Until
    // the store bridge supplies a proxy protection space, never fill a proxy
    // challenge with credentials selected for its target page.
    guard !request.isProxy, [request.origin, request.realm, request.scheme].allSatisfy({
      $0.utf8.count <= HTTPAuthSheet.maximumMetadataBytes
    }), let url = URLComponents(string: request.origin),
       let transport = url.scheme?.lowercased(),
       transport == "http" || transport == "https",
       let host = url.host?.lowercased(), !host.isEmpty,
       url.user == nil, url.password == nil else { return nil }
    let scheme = request.scheme.lowercased()
    guard scheme == "basic" || scheme == "digest" else { return nil }
    let port = url.port ?? (transport == "https" ? 443 : 80)
    guard (1...65535).contains(port) else { return nil }
    self.transport = transport; self.host = host; self.port = port
    realm = request.realm; self.scheme = scheme; isProxy = request.isProxy
  }
}

/// Short-lived engine result, never copied to automation state or logs.
struct HTTPAuthSavedCredential {
  let protectionSpace: HTTPAuthProtectionSpace
  let username: String
  let password: String
}

/// Shell-side handoff for an engine-owned password lookup. E3's current
/// request/answer/cancel API does NOT implement this refinement. Do not add a
/// shell store or treat importLogins (which preserves existing entries) as an
/// implementation. The engine must also track submission success and issue
/// its existing OESavePrompt for save/update; page-load status is insufficient.
@MainActor
protocol HTTPAuthPasswordManagerRequest: HTTPAuthRequest {
  func fetchSavedCredential(completion: @escaping @MainActor (HTTPAuthSavedCredential?) -> Void)
}
#endif
