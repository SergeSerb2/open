import AppKit
import QuartzCore
import OpenDesign
import OpenEngine
import OpenExtensionsUI

/// One reusable panel per browser window; OpenEngine owns the page and every close.
@MainActor
final class ExtensionPopupController {
  unowned let factory: EngineWebContentHostFactory
  private(set) var panel: ExtensionPopupPanel?
  private(set) weak var browser: OEBrowser?
  private(set) var page: OEWebContent?
  private weak var requestedAnchor: NSView?
  private var requestedID: String?
  private var requestedAt: CFTimeInterval?
  private var invocationAt: CFTimeInterval?
  private weak var anchorStrip: ExtensionStripView?
  private(set) var anchorFrame = CGRect.zero
  private(set) var anchorKind = ExtensionPopupAnchorKind.contentTopLeading
  private var requestedSize = ExtensionsMetrics.popupMinimum
  private var fallback: DispatchWorkItem?
  private var observers: [any NSObjectProtocol] = []
  private(set) var readyToVisibleMilliseconds: Double?
  private(set) var openedAt: Double?
  private(set) var visibleAt: Double?
  init(factory: EngineWebContentHostFactory) { self.factory = factory }
  func prepareAnchor(_ view: NSView?, extensionID: String) {
    requestedAnchor = view; requestedID = extensionID; requestedAt = CACurrentMediaTime()
  }
  func opened(browser: OEBrowser, page: OEWebContent, action: OEExtensionAction) {
    guard let parent = factory.window else { browser.closeExtensionPopup(); return }
    if self.page != nil { detach() }
    self.browser = browser; self.page = page; page.delegate = factory
    openedAt = CACurrentMediaTime(); visibleAt = nil; readyToVisibleMilliseconds = nil
    invocationAt = requestedID == action.extensionIdentifier && browser.extensionPopupSource != .API ? requestedAt : nil
    requestedSize = ExtensionsMetrics.popupMinimum
    let panel = self.panel ?? ExtensionPopupPanel(); self.panel = panel
    panel.onCloseRequest = { [weak self] in self?.close() }
    panel.onResignKey = { [weak self] in self?.blur() }
    resolveAnchor(action.extensionIdentifier)
    panel.host(view: page.view); place(); panel.orderNotReady(parent: parent)
    observe(parent)
    let work = DispatchWorkItem { [weak self, weak page] in
      MainActor.assumeIsolated {
        guard let self, let page, self.page === page else { return }
        self.show(readyAt: nil)
      }
    }
    fallback = work; DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
  }
  private func resolveAnchor(_ id: String) {
    let ui = factory.extensions
    factory.controller?.contentView.layoutSubtreeIfNeeded()
    // Start with A4's final fallback so a missing/removed anchor can never reuse
    // the previous popup's frame.
    if let content = factory.controller?.container, let window = factory.window {
      let rect = content.convert(content.bounds, to: nil)
      anchorFrame = window.convertToScreen(CGRect(x: rect.minX + 16, y: rect.maxY - 8, width: 1, height: 1))
      anchorKind = .contentTopLeading
    }
    if browser?.extensionPopupSource != .API, requestedID == id, let view = requestedAnchor, view.window === factory.window, !view.isHiddenOrHasHiddenAncestor {
      setAnchor(view, kind: view is ExtensionActionButton ? .actionButton : .overflow)
    } else {
      // A4 order is intentional: pane, URL slot (forced visible), URL SCC, content point.
      let pane = ui.strips.first { $0.style != .urlField && $0.isFocused && !$0.isHiddenOrHasHiddenAncestor }
      if let button = pane?.buttons.first(where: { $0.action.id == id && !$0.isHiddenOrHasHiddenAncestor }) {
        setAnchor(button, kind: .paneBar)
      } else if factory.windowState.sidebarMode != .hidden, factory.controller?.sidebar.urlFieldVisible == true {
        let strip = factory.controller?.sidebar.extensionsStrip
        strip?.forcedVisibility.insert(.popup); factory.controller?.sidebar.refreshExtensionsLayout()
        if let button = strip?.buttons.first(where: { $0.action.id == id && !$0.isHiddenOrHasHiddenAncestor }) {
          setAnchor(button, kind: .urlField)
        } else if let view = factory.controller?.sidebar.siteControlsAnchor {
          ui.context.forcedVisibility.insert(.popup); factory.controller?.sidebar.refreshExtensionsLayout()
          setAnchor(view, kind: .siteControls)
        }
      }
    }
    requestedAnchor = nil; requestedID = nil; requestedAt = nil
  }
  private func setAnchor(_ view: NSView, kind: ExtensionPopupAnchorKind) {
    guard let window = view.window else { return }
    anchorFrame = window.convertToScreen(view.convert(view.bounds, to: nil)); anchorKind = kind
    anchorStrip = factory.extensions.strips.first { view.isDescendant(of: $0) || view === $0.moreButton }
    if anchorStrip?.style == .urlField { anchorStrip?.forcedVisibility.insert(.popup); anchorKind = .urlField }
  }
  private func place() {
    let screen = NSScreen.screens.first { $0.frame.intersects(anchorFrame) } ?? factory.window?.screen ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return }
    panel?.setFrame(ExtensionPopupPlacement.frame(anchor: anchorFrame, requestedSize: requestedSize, visibleFrame: visible), display: true)
  }
  func resized(_ page: OEWebContent, size: CGSize) {
    guard self.page === page else { return }; requestedSize = size; place()
  }
  func ready(_ page: OEWebContent) {
    guard self.page === page else { return }; show(readyAt: CACurrentMediaTime())
  }
  private func show(readyAt: CFTimeInterval?) {
    guard let page, let panel, !panel.isReady else { return }
    fallback?.cancel(); fallback = nil
    panel.showWhenReady(); page.focusPage()
    let now = CACurrentMediaTime(); visibleAt = now
    readyToVisibleMilliseconds = readyAt.map { (now - $0) * 1000 }
    factory.record("extensionPopupVisible", page, ["readyToVisibleMs": readyToVisibleMilliseconds ?? -1])
  }
  func close() { browser?.closeExtensionPopup() }
  private func blur() {
    guard page != nil, browser?.extensionPopupStaysOpenOnBlur != true,
          factory.pendingDialogs.isEmpty, panel?.attachedSheet == nil,
          factory.window?.attachedSheet == nil else { return }
    // AppKit changes key windows inside mouseDown and Inspect Popup. Let that
    // event finish before closing: the button records its toggle, and Chromium
    // marks the popup as inspected before the deferred keep-open check.
    let current = page
    DispatchQueue.main.async { [weak self, weak current] in
      guard let self, let current, self.page === current, self.panel?.isKeyWindow != true,
            self.browser?.extensionPopupStaysOpenOnBlur != true,
            self.factory.pendingDialogs.isEmpty, self.panel?.attachedSheet == nil,
            self.factory.window?.attachedSheet == nil else { return }
      self.close()
    }
  }
  func sidebarDidHide() {
    if anchorKind == .urlField || anchorKind == .siteControls { close() }
  }
  func closed(_ page: OEWebContent) { guard self.page === page else { return }; detach() }
  private func detach() {
    fallback?.cancel(); fallback = nil
    let panel = panel
    // Clear the state before orderOut can synchronously resign key.
    page = nil; browser = nil
    anchorStrip?.forcedVisibility.remove(.popup); anchorStrip = nil
    factory.extensions.context.forcedVisibility.remove(.popup)
    panel?.detach()
    observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
  }
  private func observe(_ parent: NSWindow) {
    let names: [Notification.Name] = [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification,
      NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification]
    for name in names {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.close() }
      })
    }
    observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.blur() }
    })
  }
  var state: [String: Any] {
    ["open": page != nil, "visible": panel?.isVisible == true && panel?.alphaValue == 1,
      "ready": panel?.isReady == true, "key": panel?.isKeyWindow == true, "window": panel?.windowNumber ?? 0,
      "frame": NSStringFromRect(panel?.frame ?? .zero), "contentSize": NSStringFromSize(panel?.contentView?.bounds.size ?? .zero),
      "anchor": NSStringFromRect(anchorFrame), "anchorKind": String(describing: anchorKind),
      "readyToVisibleMs": readyToVisibleMilliseconds ?? NSNull(),
      "clickToVisibleMs": visibleAt.flatMap { v in invocationAt.map { (v - $0) * 1000 } } ?? NSNull(),
      "openToVisibleMs": visibleAt.flatMap { v in openedAt.map { (v - $0) * 1000 } } ?? NSNull(),
      "staysOpenOnBlur": browser?.extensionPopupStaysOpenOnBlur == true]
  }
  isolated deinit { fallback?.cancel(); observers.forEach { NotificationCenter.default.removeObserver($0) } }
}
