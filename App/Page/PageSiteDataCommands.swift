import Foundation
import OSLog
import OpenEngine
import OpenWeb

/// View's site clears use the focused page's context, including its private
/// context. Never resolve the context through the parent Profile.
@MainActor
enum PageSiteDataCommands {
  private static let logger = Logger(subsystem: "io.github.sergeserb2.open", category: "SiteData")

  static func clearAndRefresh(_ page: OEWebContent, kinds: WebSiteDataKinds) {
    guard let host = page.delegate as? EngineWebContentHost, !host.closed,
      page.isLive, let url = page.url, PageTools.isSitePage(url),
      var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
    parts.path = "/"; parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
    guard let origin = parts.url else { return }
    let profile = EngineWebProfile(page.context)
    Task { @MainActor [weak page, weak host] in
      do {
        try await profile.clearSiteData(origin: origin, kinds: kinds)
        // isLive stays true until Chromium acknowledges close. The shell host
        // marks closed immediately, before that asynchronous acknowledgement.
        // Do not reload a closed page or a page that navigated during the clear.
        guard let page, let host, !host.closed, page.delegate === host,
          page.isLive, page.url == url, !Task.isCancelled else {
          logger.info("Site-data clear refresh canceled: page closed or changed.")
          return
        }
        if kinds.contains(.cache) { page.reloadIgnoringCache() }
        else { page.reload() }
      } catch {
        // Do not log the origin, page URL or engine error's user data.
        logger.error("Site-data clear failed or was canceled; refresh skipped.")
      }
    }
  }
}
