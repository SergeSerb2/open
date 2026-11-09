import AppKit
import OpenEngine
import OpenFeatures
import OpenModel

/// Page commands of the page-platform plan (§4.2, §4.3, §7.1): the Copy URL family with its toasts
/// and Share, the Shared Quotes offer, and the zoom toast. Runs on the key window's factory.
extension EngineWebContentHostFactory {
  /// A selection longer than this cannot become an exact `#:~:text=` link (§4.2.4 rule 3).
  static let quoteTextLimit = 300
  static let quoteOfferSubtitle = "Share a link directly to this text instead?"
  static let quoteLinkTitle = "Copied Quote Link"
  static let quoteButton = ToastContent.Accessory.button(symbol: "quote.bubble.fill", accessibilityLabel: "Copy Quote Link")

  /// The focused page's URL (the top Peek page while a Peek shows).
  private var pageURL: URL? { selectedContent?.url ?? selectedTab?.url }

  /// Writes a link as both `public.url` and plain text (§4.2.2 step 2).
  private func writeLink(_ url: URL) {
    let board = NSPasteboard.general
    board.clearContents()
    board.declareTypes([.URL, .string], owner: nil)
    (url as NSURL).write(to: board)
    board.setString(url.absoluteString, forType: .string)
  }

  // MARK: copy-url (Cmd+Shift+C)

  @discardableResult
  func copyURL() -> Bool {
    guard let url = pageURL else { return false }
    let (clean, removed) = URLCleaner.clean(url)
    writeLink(clean)
    showCopyToast(clean, removed: removed, offerQuote: true)
    return true
  }

  // MARK: copy-url-markdown (Cmd+Opt+Shift+C)

  @discardableResult
  func copyURLMarkdown() -> Bool {
    guard let url = pageURL else { return false }
    let (clean, removed) = URLCleaner.clean(url)
    let raw = (selectedContent?.title).flatMap { $0.isEmpty ? nil : $0 } ?? selectedTab?.displayTitle ?? ""
    let title = raw.isEmpty ? (clean.host() ?? clean.absoluteString) : raw
    let board = NSPasteboard.general
    board.clearContents(); board.setString(URLCleaner.markdownLink(title: title, url: clean), forType: .string)
    showCopyToast(clean, removed: removed, offerQuote: false)
    return true
  }

  /// "Copied Current URL" / "Copied a clean link without trackers" with Share (PG-1.10). With Shared
  /// Quotes on and text selected, the same toast offers the quote link (§4.2.2 step 4).
  private func showCopyToast(_ clean: URL, removed: [String], offerQuote: Bool) {
    guard let toasts = controller?.toasts else { return }
    let content = ToastContent(title: URLCleaner.toastTitle(removed: removed), accessory: ToastContent.shareButton)
    let offer = QuoteOffer()
    let handle = toasts.show(content) { [weak self, offer] handle in
      guard let self else { return }
      if offer.isShown { _ = self.copyURLQuote(); handle.dismiss() } else { self.shareFromToast(clean, handle: handle) }
    }
    guard offerQuote, Self.sharedQuotesEnabled, let page = selectedContent else { return }
    // The engine keeps the page's selection state (EP-3, OEWebContentChangeSelection): the offer
    // needs no page round trip, so it is decided at once, well inside the 150 ms budget (§4.2.2).
    let selected = page.hasSelection
    #if OPEN_AUTOMATION
    lastQuoteOffer = ["elapsed": 0.0, "selected": selected, "shown": selected]
    #endif
    guard selected else { return }
    offer.isShown = true
    handle.update(ToastContent(title: content.title, subtitle: Self.quoteOfferSubtitle, accessory: Self.quoteButton))
  }

  /// Settings ▸ Advanced "Enable Shared Quotes" (default on, §5).
  static var sharedQuotesEnabled: Bool { UserDefaults.standard.object(forKey: "open.advanced.enableSharedQuotes") as? Bool ?? true }

  // MARK: copy-url-quote (Cmd+Ctrl+Shift+C)

  /// The cleaned page URL with a text fragment of the selection (§4.2.4). No selection, or one too long
  /// for an exact link: Copy URL (lead Q11).
  @discardableResult
  func copyURLQuote() -> Bool {
    guard let url = pageURL else { return false }
    guard let page = selectedContent else { return copyURL() }
    let id = UUID()
    pageTasks[id] = Task { @MainActor [weak self, weak page] in
      defer { self?.pageTasks[id] = nil }
      guard let self, let page, !self.isClosing, self.app.engineReady else { return }
      self.app.noteAsyncEngineCall("quoteSelection")
      // EP-2: the focused frame's selection and Chromium's text-fragment generator (prefix and
      // suffix context where the sentence is not unique).
      let (raw, engineLink) = await withCheckedContinuation { (done: CheckedContinuation<(String, URL?), Never>) in
        page.requestSelection { text, link in done.resume(returning: (text, link)) }
      }
      guard !Task.isCancelled, !self.isClosing else { return }
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      let clean = URLCleaner.clean(url).url
      // Rule 2: the generator's directive on the cleaned URL. Rule 3: no directive (generator error
      // or a child frame) and at most 300 characters: an exact `#:~:text=`. Else Copy URL.
      let link = engineLink.flatMap { Self.withFragment(of: $0, on: clean) }
        ?? (text.count <= Self.quoteTextLimit ? Self.quoteLink(clean, text: text) : nil)
      guard !text.isEmpty, let link else { self.copyURL(); return }
      self.writeLink(link)
      self.controller?.toasts.show(ToastContent(title: Self.quoteLinkTitle, symbol: "quote.bubble.fill"))
    }
    return true
  }

  /// `clean` with the fragment of the engine's link (the page's own fragment plus `:~:text=…`).
  static func withFragment(of link: URL, on clean: URL) -> URL? {
    guard let fragment = URLComponents(url: link, resolvingAgainstBaseURL: false)?.percentEncodedFragment,
          fragment.contains(":~:text="),
          var components = URLComponents(url: clean, resolvingAgainstBaseURL: false) else { return nil }
    components.percentEncodedFragment = fragment
    return components.url
  }

  /// `url#:~:text=<text>`: the text percent-encoded for a text directive (`-`, `,`, `&` included).
  static func quoteLink(_ url: URL, text: String) -> URL? {
    var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    allowed.insert(charactersIn: "._~")
    guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed),
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    components.percentEncodedFragment = ":~:text=" + encoded
    return components.url
  }

  @discardableResult
  func sharePage() -> Bool {
    guard !isClosing, let url = pageURL, let container = controller?.container else { return false }
    sidebarSharePicker?.close()
    shareToastHandle?.hold(false); shareToastHandle = nil
    let clean = URLCleaner.clean(url).url
    let picker = NSSharingServicePicker(items: [clean])
    sidebarSharePicker = picker; picker.delegate = self
    #if OPEN_AUTOMATION
    sidebarShareRequest = ["url": clean.absoluteString, "node": "page", "requested": true,
      "servicesRequested": false, "closed": false]
    #endif
    picker.show(relativeTo: container.bounds, of: container, preferredEdge: .maxY)
    return true
  }

  // MARK: Share from the toast

  /// The system share picker for the cleaned URL, anchored to the toast's button. The toast stays
  /// while the picker is open. One picker per window (the sidebar's Share uses the same one).
  func shareFromToast(_ url: URL, handle: ToastHandle) {
    guard !isClosing, let button = handle.accessoryButton, button.window != nil else { return }
    sidebarSharePicker?.close()
    let clean = URLCleaner.clean(url).url
    let picker = NSSharingServicePicker(items: [clean])
    sidebarSharePicker = picker; picker.delegate = self
    shareToastHandle?.hold(false); shareToastHandle = handle
    handle.hold(true)
    #if OPEN_AUTOMATION
    let anchor = controller.map { $0.contentView.convert(button.bounds, from: button) } ?? .zero
    sidebarShareRequest = ["url": clean.absoluteString, "node": "toast",
      "anchor": [anchor.minX, anchor.minY, anchor.width, anchor.height], "requested": true,
      "servicesRequested": false, "closed": false]
    #endif
    picker.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
  }

  // MARK: Zoom (§4.3)

  /// Chromium's preset steps through CEF, then the percent toast ("110%", PG-3.1). `zoom-actual-size`
  /// also resets the pinch scale (EP-5, inside `resetZoom`).
  @discardableResult
  func zoomPage(_ id: String) -> Bool {
    guard let page = selectedContent else { return false }
    switch id {
    case "zoom-in": page.zoomIn()
    case "zoom-out": page.zoomOut()
    default: page.resetZoom()
    }
    let percent = Int((100 * pow(1.2, page.zoomLevel)).rounded())
    controller?.toasts.show(ToastContent(title: "\(percent)%", coalescingKey: "zoom"))
    return true
  }
}

/// Whether a copy toast switched to the quote offer (its button then copies the quote link).
@MainActor
final class QuoteOffer {
  var isShown = false
}
