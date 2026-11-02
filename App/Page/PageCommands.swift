import AppKit
import OpenEngine
import OpenFeatures
import OpenModel

/// Page commands of the page-platform plan (§4.2, §4.3, §7.1): the Copy URL family with its toasts
/// and Share, the Shared Quotes offer, and the zoom toast. Runs on the key window's factory.
extension EngineWebContentHostFactory {
  /// The quote offer waits this long for the page's selection; a later answer is dropped (§4.2.2).
  static let quoteOfferBudget: TimeInterval = 0.150
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
    let escaped = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[")
      .replacingOccurrences(of: "]", with: "\\]")
    let board = NSPasteboard.general
    board.clearContents(); board.setString("[\(escaped)](\(clean.absoluteString))", forType: .string)
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
    guard offerQuote, UserDefaults.standard.object(forKey: "open.advanced.enableSharedQuotes") as? Bool ?? true,
          let page = selectedContent else { return }
    let started = CACurrentMediaTime()
    let id = UUID()
    pageTasks[id] = Task { @MainActor [weak self, weak page, handle] in
      defer { self?.pageTasks[id] = nil }
      guard let self, let page, !self.isClosing, self.app.engineReady else { return }
      self.app.noteAsyncEngineCall("quoteOffer")
      // Interim until EP-2: the main frame's selection through the page's own `getSelection()`.
      let text = (try? await page.evaluateJavaScript("String(getSelection())")) as? String ?? ""
      let elapsed = CACurrentMediaTime() - started
      #if OPEN_AUTOMATION
      self.lastQuoteOffer = ["elapsed": elapsed, "selected": !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                             "shown": false]
      #endif
      // A late answer (after the budget, or after the toast left) is dropped.
      guard !Task.isCancelled, !self.isClosing, elapsed <= Self.quoteOfferBudget, handle.isVisible,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      offer.isShown = true
      handle.update(ToastContent(title: content.title, subtitle: Self.quoteOfferSubtitle, accessory: Self.quoteButton))
      #if OPEN_AUTOMATION
      self.lastQuoteOffer["shown"] = true
      #endif
    }
  }

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
      // Interim until EP-2: main-frame selection only, and an exact `#:~:text=` directive without
      // prefix or suffix context (an ambiguous sentence scrolls to its first match).
      let raw = (try? await page.evaluateJavaScript("String(getSelection())")) as? String ?? ""
      guard !Task.isCancelled, !self.isClosing else { return }
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, text.count <= Self.quoteTextLimit, let link = Self.quoteLink(URLCleaner.clean(url).url, text: text) else {
        self.copyURL(); return
      }
      self.writeLink(link)
      self.controller?.toasts.show(ToastContent(title: Self.quoteLinkTitle, symbol: "quote.bubble.fill"))
    }
    return true
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

  // MARK: Share from the toast

  /// The system share picker for the cleaned URL, anchored to the toast's button. The toast stays
  /// while the picker is open. One picker per window (the sidebar's Share uses the same one).
  func shareFromToast(_ url: URL, handle: ToastHandle) {
    guard !isClosing, let button = handle.accessoryButton, button.window != nil else { return }
    sidebarSharePicker?.close()
    let picker = NSSharingServicePicker(items: [url])
    sidebarSharePicker = picker; picker.delegate = self
    shareToastHandle?.hold(false); shareToastHandle = handle
    handle.hold(true)
    #if OPEN_AUTOMATION
    let anchor = controller.map { $0.contentView.convert(button.bounds, from: button) } ?? .zero
    sidebarShareRequest = ["url": url.absoluteString, "node": "toast",
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
