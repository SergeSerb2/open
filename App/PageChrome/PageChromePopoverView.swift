import AppKit

/// Native popovers own plain keys instead of forwarding them into the page.
/// Command keys continue through OEApplication and the owning window router.
@MainActor
class PageChromePopoverView: NSView {
  var onReturn: (() -> Void)?
  var onEscape: (() -> Void)?
  override var acceptsFirstResponder: Bool { true }
  override func keyDown(with event: NSEvent) {
    if event.modifierFlags.intersection([.command,.control,.option]).isEmpty {
      if event.keyCode == 53 { onEscape?(); return }
      if event.keyCode == 36 || event.keyCode == 76 { onReturn?(); return }
    }
    super.keyDown(with: event)
  }
}
