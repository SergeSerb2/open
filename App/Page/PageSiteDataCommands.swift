import AppKit
import OSLog
import OpenEngine
import OpenFeatures
import OpenWeb

/// View's site clears use the focused page's context, including its private
/// context. Never resolve the context through the parent Profile.
@MainActor
enum PageSiteDataCommands {
  private static let logger = Logger(subsystem: "io.github.sergeserb2.open", category: "SiteData")
  // Weak identity keys cannot retain closed pages or block a new page whose
  // allocation reuses an old page's address while an engine callback is pending.
  private static let clearingPages = NSHashTable<OEWebContent>(options: [.weakMemory, .objectPointerPersonality])

  private static func origin(of url: URL?) -> URL? {
    guard let url, PageTools.isSitePage(url),
      var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
    if parts.port == (parts.scheme == "https" ? 443 : 80) { parts.port = nil }
    parts.path = "/"; parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
    return parts.url
  }

  static func clearAndRefresh(_ page: OEWebContent, kinds: WebSiteDataKinds) {
    guard let host = page.delegate as? EngineWebContentHost, !host.closed,
      page.isLive, let origin = origin(of: page.url), !clearingPages.contains(page) else { return }
    clearingPages.add(page)
    let profile = EngineWebProfile(page.context)
    #if OPEN_AUTOMATION
    let probeKey = ObjectIdentifier(page)
    PageSiteDataProbe.began(probeKey)
    #endif
    Task { @MainActor [weak page, weak host] in
      defer { if let page { clearingPages.remove(page) } }
      do {
        try await profile.clearSiteData(origin: origin, kinds: kinds)
        #if OPEN_AUTOMATION
        await PageSiteDataProbe.cleared(probeKey)
        #endif
        // isLive stays true until Chromium acknowledges close. The shell host
        // marks closed immediately, before that asynchronous acknowledgement.
        // Hash and pushState changes within the same origin still refresh.
        guard let page, let host, !host.closed, page.delegate === host,
          page.isLive, Self.origin(of: page.url) == origin else {
          logger.info("Site-data clear refresh skipped: page closed or origin changed.")
          return
        }
        #if OPEN_AUTOMATION
        PageSiteDataProbe.refreshed(probeKey)
        #endif
        if kinds.contains(.cache) { page.reloadIgnoringCache() }
        else { page.reload() }
      } catch {
        // Do not log the origin, page URL or engine error's user data.
        logger.error("Site-data clear failed or was canceled; refresh skipped.")
        if let page, let host { showFailure(on: page, host: host) }
      }
    }
  }

  private static func showFailure(on page: OEWebContent, host: EngineWebContentHost) {
    guard !host.closed, page.delegate === host, let owner = host.owner else { return }
    let content = ToastContent(title: "Site data could not be cleared.", coalescingKey: "site-data-clear-failure")
    if let controller = owner.controller { controller.toasts.show(content); return }
    // Little Open uses the existing standalone toast overlay, also used by
    // autofill failures. Keep feedback on the originating surface.
    guard let view = page.view.window?.contentView else { return }
    if owner.autofillToastCenter == nil {
      let overlay = ToastOverlayView(frame: view.bounds)
      overlay.autoresizingMask = [.width, .height]; view.addSubview(overlay)
      owner.autofillToastCenter = ToastCenter(overlay: overlay) { [weak view] in
        let name = view?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        return .defaultTheme(system: name == .aqua ? .light : .dark)
      }
    }
    owner.autofillToastCenter?.show(content)
  }
}
