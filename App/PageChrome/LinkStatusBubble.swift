import AppKit
import OpenDesign
import OpenEngine
import OpenModel
import OpenSidebar

/// Arc's link status bubble (S2 04/0021, 0033; page-platform.md, interaction-states.md): hovering a
/// link shows its URL without the scheme in a capsule at the bottom-left of that page's own area,
/// 10 pt from its left edge and 12 pt above its bottom edge, 23 pt tall, in the Space's tooltip
/// fill (`#0A0D4F` in the default theme) with light text. No AX element in Arc; Open gives it none.
///
/// The view changes only when the engine reports a new status text (`OEWebContentChangeStatusText`):
/// nothing runs per frame and an idle page does no work.
@MainActor
final class LinkStatusBubble: NSView {
  enum Metrics {
    static let height: CGFloat = 23
    static let leadingInset: CGFloat = 10
    static let bottomInset: CGFloat = 12
    /// Text padding inside the capsule. guess (no AX frame; ink fits the tooltip's 11 pt rule).
    static let padding: CGFloat = 9
    /// The capsule never takes more than this share of its page's width. guess.
    static let maxWidthShare: CGFloat = 2.0 / 3.0
    /// Fade out once the pointer leaves the link. guess (no capture of the exit).
    static let fadeOut: CFTimeInterval = 0.12
  }

  private let label = NSTextField(labelWithString: "")
  private(set) var text = ""
  /// The tab whose page the bubble describes.
  private(set) var tabID: ItemID?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerCurve = .continuous
    layer?.cornerRadius = Metrics.height / 2
    label.font = Typography.tooltip.font
    label.lineBreakMode = .byTruncatingMiddle
    label.maximumNumberOfLines = 1
    label.cell?.truncatesLastVisibleLine = true
    addSubview(label)
    setAccessibilityElement(false)
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// The URL as Arc shows it: no `http(s)://`.
  static func display(_ status: String) -> String {
    let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
    for scheme in ["https://", "http://"] where trimmed.lowercased().hasPrefix(scheme) {
      return String(trimmed.dropFirst(scheme.count))
    }
    return trimmed
  }

  /// Shows `text` for `tabID` at the bottom-left of `area` (parent coordinates).
  func show(_ text: String, tabID: ItemID, in area: CGRect, style: SpaceThemeStyle) {
    self.tabID = tabID
    if self.text != text { self.text = text; label.stringValue = text }
    label.textColor = style.tooltipText.nsColor
    layer?.backgroundColor = style.tooltipFill.cgColor
    let font = label.font ?? Typography.tooltip.font
    let textWidth = ceil(label.cell?.cellSize.width ?? (text as NSString).size(withAttributes: [.font: font]).width)
    let limit = max(0, min(area.width - 2 * Metrics.leadingInset, (area.width * Metrics.maxWidthShare).rounded(.down)))
    let width = min(limit, textWidth + 2 * Metrics.padding)
    let y = superview?.isFlipped == true ? area.maxY - Metrics.bottomInset - Metrics.height : area.minY + Metrics.bottomInset
    let target = CGRect(x: area.minX + Metrics.leadingInset, y: y, width: width, height: Metrics.height).integral
    CATransaction.begin(); CATransaction.setDisableActions(true)
    frame = target
    let labelHeight = ceil(label.cell?.cellSize.height ?? 15)
    label.frame = CGRect(x: Metrics.padding - 2, y: ((Metrics.height - labelHeight) / 2).rounded(),
                         width: max(0, width - 2 * Metrics.padding + 4), height: labelHeight)
    layer?.removeAnimation(forKey: "fade")
    layer?.opacity = 1
    isHidden = width < 2 * Metrics.padding
    CATransaction.commit()
  }

  /// Hides the bubble; `animated` fades it (pointer left the link), otherwise it goes at once.
  func hide(animated: Bool) {
    tabID = nil
    guard !isHidden else { return }
    guard animated, let layer else { isHidden = true; return }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = layer.presentation()?.opacity ?? layer.opacity; fade.toValue = 0
    fade.duration = Metrics.fadeOut; fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.tabID == nil else { return }
        self.isHidden = true; self.layer?.opacity = 1
      }
    }
    layer.opacity = 0
    layer.add(fade, forKey: "fade")
    CATransaction.commit()
  }

  #if OPEN_AUTOMATION
  func automationState(area: CGRect?) -> [String: Any] {
    func rect(_ r: CGRect?) -> [CGFloat] { r.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [] }
    let window = superview.map { _ in convert(bounds, to: nil) }
    let pageArea = area.flatMap { a in superview.map { $0.convert(a, to: nil) } }
    return ["visible": !isHiddenOrHasHiddenAncestor && superview != nil && tabID != nil, "text": text,
            "tab": tabID?.description ?? "", "frame": rect(window), "pageArea": rect(pageArea),
            "labelFrame": rect(label.convert(label.bounds, to: nil)),
            "labelNeeds": ceil(label.cell?.cellSize.width ?? 0), "truncated": (label.cell?.cellSize.width ?? 0) > label.bounds.width + 0.5]
  }
  #endif
}

extension EngineWebContentHostFactory {
  /// The page area that shows `tabID` in this window: its pane slot, or the Peek panel.
  func linkStatusTarget(_ tabID: ItemID) -> (parent: NSView, area: CGRect)? {
    guard let controller else { return nil }
    if controller.hasPeekController, controller.peekController.isShown,
       let host = controller.peekController.stack.last?.host as? EngineWebContentHost, host.tabID == tabID {
      let panel = controller.peekController.overlay.panel
      return (panel, panel.convert(host.view.bounds, from: host.view))
    }
    guard let slot = controller.container.slots.first(where: { !$0.isHidden && $0.tabID == tabID }),
          let viewport = slot.contentHostView, slot.isDrawingPage else { return nil }
    var area = slot.convert(viewport.bounds, from: viewport)
    // A shrinking Split pane holds its larger page until its motion ends: stay inside the final pane.
    if slot.isHoldingPage { area = area.intersection(slot.settledPageFrame) }
    return (slot, area.intersection(slot.bounds))
  }

  /// `OEWebContentChangeStatusText` (or fullscreen) for a page of this window.
  func linkStatusChanged(_ host: EngineWebContentHost) {
    let text = LinkStatusBubble.display(host.content.statusText)
    // HTML fullscreen (video) never shows the bubble.
    guard !text.isEmpty, !host.content.isFullscreen, let target = linkStatusTarget(host.tabID) else {
      if linkStatus?.tabID == host.tabID || linkStatus?.tabID == nil { linkStatus?.hide(animated: !text.isEmpty || !host.content.isFullscreen) }
      return
    }
    let bubble = linkStatus ?? LinkStatusBubble(frame: .zero)
    linkStatus = bubble
    if bubble.superview !== target.parent || target.parent.subviews.last !== bubble {
      bubble.removeFromSuperview(); target.parent.addSubview(bubble)
    }
    guard let context = controller?.context, let space = context.focusedSpace else { bubble.hide(animated: false); return }
    bubble.show(text, tabID: host.tabID, in: target.area, style: context.style(for: space))
  }

  #if OPEN_AUTOMATION
  func linkStatusAutomationState() -> [String: Any] {
    guard let bubble = linkStatus else { return ["visible": false, "text": ""] }
    return bubble.automationState(area: bubble.tabID.flatMap { linkStatusTarget($0)?.area })
  }
  #endif
}
