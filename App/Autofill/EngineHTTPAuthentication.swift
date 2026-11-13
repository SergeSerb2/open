#if OPEN_HTTP_AUTH && OPEN_HTTP_AUTH_ENGINE
import AppKit
import OpenEngine

// OPEN_HTTP_AUTH_ENGINE is enabled only against an adopted framework that
// exports OEAuthenticationRequest. The scaffold can compile without that API.
extension OEAuthenticationRequest: HTTPAuthRequest {
  var origin: String { originURL?.absoluteString ?? host }
  var isAnswered: Bool { !isPending }
  func accept(username: String, password: String) {
    self.continue(username: username, password: password)
  }
}

extension EngineWebContentHostFactory {
  func webContent(_ page: OEWebContent, handleAuthenticationRequest request: OEAuthenticationRequest) -> Bool {
    guard !isClosing, let window, request.isPending else { return false }
    if httpAuth == nil {
      httpAuth = HTTPAuthPresenter(window: window, isFocused: { [weak self] pageID in
        guard let self, let content = self.standaloneSurface?.surfacePage ?? self.selectedContent else { return false }
        return pageID == AnyHashable(content.identifier)
      }, text: { request in
        // C13-AUTH: realm is absent. This message is the captured copy even
        // for the loopback HTTP challenge; it is not a TLS status calculation.
        let host = (request as? OEAuthenticationRequest)?.host ?? ""
        return HTTPAuthSheetText(title: "Sign in to \(host)",
          body: "Your connection to this site is private.",
          username: "Username", password: "Password", accept: "Sign in", cancel: "Cancel")
      })
    }
    httpAuth?.enqueue(request, page: AnyHashable(page.identifier))
    return true
  }

  func webContent(_ page: OEWebContent, didCancelAuthenticationRequest request: OEAuthenticationRequest) {
    httpAuth?.withdraw(request)
  }
}
#endif
