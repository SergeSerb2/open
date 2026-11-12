import AppKit
import OpenEasel
import OpenFeatures
import OpenModel

/// Capture → Easel (docs/re/easels.md: the capture menu lists New Easel and each Easel;
/// choosing one opens that Easel with the capture as a card). Arc opens it in a Peek-style
/// overlay; Open selects the Easel tab (lead review: LOOK E2).
extension EngineWebContentHostFactory {
  /// Easel tabs of the focused Profile, most recently active first (at most 12).
  var easelTabs: [Tab] {
    guard let profile = focusedProfile else { return [] }
    var tabs: [Tab] = []
    for space in model.spaces where space.profileID == profile.id {
      for tab in flattened(space.pinned + space.today) where EaselTab.matches(tab.url) { tabs.append(tab) }
    }
    return Array(tabs.sorted { $0.lastActiveAt > $1.lastActiveAt }.prefix(12))
  }

  func addToEaselMenu(_ result: CaptureController.Result) -> NSMenu {
    let menu = NSMenu(title: "Add to Easel")
    menu.autoenablesItems = false
    let new = EaselMenuItem("New Easel") { [weak self] in self?.addCapture(result, toEaselTab: nil) }
    menu.addItem(new)
    let easels = easelTabs
    if !easels.isEmpty { menu.addItem(.separator()) }
    for tab in easels {
      let id = tab.id
      menu.addItem(EaselMenuItem(tab.displayTitle) { [weak self] in self?.addCapture(result, toEaselTab: id) })
    }
    return menu
  }

  func showAddToEaselMenu(_ result: CaptureController.Result, anchor: NSView) {
    addToEaselMenu(result).popUp(positioning: nil, at: CGPoint(x: 0, y: anchor.bounds.maxY + 4), in: anchor)
  }

  /// Stores the capture in the Easel's images, adds a web card, selects the Easel.
  @discardableResult
  func addCapture(_ result: CaptureController.Result, toEaselTab target: ItemID?) -> Bool {
    let tabID: ItemID
    if let target, let tab = model.tab(id: target), EaselTab.matches(tab.url) { tabID = target }
    else if let created = EaselTab.create(in: self) { tabID = created }
    else { return false }
    guard let tab = model.tab(id: tabID), let documentID = EaselTab.documentID(tab.url),
          let image = app.easels.addImage(result.png, document: documentID) else { return false }
    let card = EaselWebCard(url: result.sourceURL?.absoluteString ?? "", title: result.title.isEmpty ? nil : result.title,
                            imageFile: image.file, capturedAt: result.createdAt)
    selectTabForCommand(tabID)
    let pixels = CGSize(width: result.pixelWidth, height: result.pixelHeight)
    if let host = easelHosts[tabID], !host.closed {
      host.canvas.layoutSubtreeIfNeeded()
      host.canvas.insertWebCard(card, pixelSize: pixels)
    } else {
      // Not shown (should not happen after the selection): append to the stored document.
      var doc = app.easels.load(documentID) ?? EaselDocument(id: documentID)
      let w = min(500, max(40, pixels.width / 2)), h = w * max(1, pixels.height) / max(1, pixels.width)
      doc.objects.append(EaselObject(frame: CGRect(x: 500 - w / 2, y: 120, width: w, height: h), zIndex: doc.maxZ + 1, content: .webCard(card)))
      app.easels.save(doc)
    }
    controller?.capture.closeCard()
    return true
  }
}

/// A menu row that runs a closure.
final class EaselMenuItem: NSMenuItem {
  private let run: () -> Void
  init(_ title: String, run: @escaping () -> Void) {
    self.run = run
    super.init(title: title, action: #selector(fire), keyEquivalent: "")
    target = self
  }
  required init(coder: NSCoder) { fatalError() }
  @objc private func fire() { run() }
}
